# UnrealSync: local Unreal Engine project regeneration and build after Git changes.
# Windows PowerShell 5.1+. This file is installed as <repo>/.unrealsync/UnrealSync.ps1.
[CmdletBinding()]
param(
    [ValidateSet('Auto', 'Full')][string]$Mode = 'Auto',
    [string]$OldRevision = '',
    [string]$NewRevision = '',
    [string]$EngineRoot = '',
    [ValidateSet('', 'Standard', 'Deep')][string]$CleanupProfile = '',
    [switch]$CleanPluginArtifacts,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
$RepoRoot = (& git rev-parse --show-toplevel 2>$null | Select-Object -First 1)
if ($LASTEXITCODE -ne 0 -or -not $RepoRoot) { throw 'Run UnrealSync from a Git working tree.' }
$RepoRoot = [IO.Path]::GetFullPath($RepoRoot)
Set-Location -LiteralPath $RepoRoot
$ConfigPath = Join-Path $RepoRoot '.unrealsync.json'
if (-not (Test-Path -LiteralPath $ConfigPath)) { throw "Configuration missing: $ConfigPath" }
$Config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
$ProjectRelative = [string]$Config.ProjectFile
if (-not $ProjectRelative) { throw 'Set ProjectFile in .unrealsync.json.' }

function Resolve-RepoPath([string]$Relative) {
    if ([IO.Path]::IsPathRooted($Relative)) { throw "Expected repository-relative path: $Relative" }
    $full = [IO.Path]::GetFullPath((Join-Path $RepoRoot ($Relative -replace '/', '\')))
    if (-not $full.StartsWith(($RepoRoot.TrimEnd('\') + '\'), [StringComparison]::OrdinalIgnoreCase)) {
        throw "Path must stay inside Git repository: $Relative"
    }
    return $full
}
$ProjectFile = Resolve-RepoPath $ProjectRelative
if (-not (Test-Path -LiteralPath $ProjectFile) -or [IO.Path]::GetExtension($ProjectFile) -ine '.uproject') {
    throw "Project not found: $ProjectFile"
}
$ProjectRoot = Split-Path -Path $ProjectFile -Parent
$ProjectName = [IO.Path]::GetFileNameWithoutExtension($ProjectFile)
$GitState = (& git rev-parse --git-path unrealsync 2>$null | Select-Object -First 1)
if ($LASTEXITCODE -ne 0 -or -not $GitState) { throw 'Cannot resolve Git metadata storage.' }
if (-not [IO.Path]::IsPathRooted($GitState)) { $GitState = Join-Path $RepoRoot $GitState }
$StateDir = [IO.Path]::GetFullPath($GitState)
New-Item -ItemType Directory -Force -Path $StateDir | Out-Null
$LogFile = Join-Path $StateDir 'latest.log'
$StatusFile = Join-Path $StateDir 'status.json'
$BackupFiles = @()
$IsDeferred = $false
$Notifications = ($Config.Notifications -ne $false)
$CleanupKind = if ($CleanupProfile) { $CleanupProfile } elseif ($Config.CleanupProfile) { [string]$Config.CleanupProfile } else { 'Standard' }
if ($CleanupKind -notin @('Standard', 'Deep')) { throw "Invalid CleanupProfile: $CleanupKind" }
Set-Content -LiteralPath $LogFile -Value "UnrealSync $(Get-Date -Format o)" -Encoding UTF8

function Log([string]$Message) {
    $line = "[UnrealSync] $Message"
    Write-Host $line
    Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8
}
function Status([string]$State, [string]$Detail) {
    ([ordered]@{ Project = $ProjectName; State = $State; Timestamp = (Get-Date -Format o); Detail = $Detail; LogPath = $LogFile } |
        ConvertTo-Json -Depth 3) | Set-Content -LiteralPath $StatusFile -Encoding UTF8
}
function Notify([string]$State) {
    if (-not $Notifications -or $env:UNREALSYNC_NOTIFICATIONS -match '^(0|off|false)$') { return }
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { return }
    $scriptFile = Join-Path $PSScriptRoot 'UnrealSyncNotify.ps1'
    if (-not (Test-Path -LiteralPath $scriptFile)) { return }
    try {
        $exe = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
        if (-not (Test-Path -LiteralPath $exe)) { return }
        $safeName = $ProjectName.Replace('"', '')
        $args = @('-NoProfile', '-NonInteractive', '-STA', '-ExecutionPolicy', 'Bypass',
                  '-WindowStyle', 'Hidden', '-File', ('"' + $scriptFile + '"'),
                  '-State', $State, '-ProjectName', ('"' + $safeName + '"'))
        Start-Process -FilePath $exe -ArgumentList $args -WindowStyle Hidden -ErrorAction Stop | Out-Null
    } catch { Write-Warning "Windows notification unavailable: $($_.Exception.Message)" }
}
function Rel([string]$FullPath) {
    return ($FullPath.Substring($RepoRoot.Length).TrimStart('\','/') -replace '\', '/')
}
function Assert-Safe([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return }
    $item = Get-Item -LiteralPath $Path -Force
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Refusing cleanup of junction/symlink: $Path"
    }
    $rel = Rel $Path
    $tracked = @(& git ls-files --cached -- $rel)
    if ($LASTEXITCODE -ne 0) { throw "Cannot inspect tracked files: $rel" }
    if ($tracked.Count -gt 0) { throw "Refusing to delete Git-tracked data under: $rel" }
    # Avoid traversing directory junctions during Remove-Item -Recurse.
    if ($item.PSIsContainer) {
        $links = @(Get-ChildItem -LiteralPath $Path -Force -Recurse -Attributes ReparsePoint -ErrorAction Stop |
            Select-Object -First 1)
        if ($links.Count -gt 0) { throw "Refusing cleanup containing a junction/symlink: $rel" }
    }
}
function Backup-Settings {
    $folder = Join-Path $ProjectRoot 'Saved\Config'
    if (-not (Test-Path -LiteralPath $folder)) { return }
    $backup = Join-Path $StateDir ('source-control-backup-' + (Get-Date -Format 'yyyyMMddHHmmssffff'))
    foreach ($f in @(Get-ChildItem -LiteralPath $folder -Filter 'SourceControlSettings.ini' -File -Recurse)) {
        $relative = $f.FullName.Substring($ProjectRoot.Length).TrimStart('\','/')
        $dest = Join-Path $backup $relative
        New-Item -ItemType Directory -Force -Path (Split-Path $dest -Parent) | Out-Null
        Copy-Item -LiteralPath $f.FullName -Destination $dest -Force
        $script:BackupFiles += [pscustomobject]@{ Original = $f.FullName; Backup = $dest }
        Log "Backed up source-control config: $relative"
    }
}
function Restore-Settings {
    foreach ($f in $script:BackupFiles) {
        New-Item -ItemType Directory -Force -Path (Split-Path $f.Original -Parent) | Out-Null
        Copy-Item -LiteralPath $f.Backup -Destination $f.Original -Force
    }
}
function Invoke-Native([string]$Executable, [string[]]$Arguments) {
    Log ("Executing {0} {1}" -f $Executable, ($Arguments -join ' '))
    $oldPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        & $Executable @Arguments 2>&1 | ForEach-Object {
            $line = $_.ToString()
            Write-Host $line
            Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8
        }
        $exitCode = $LASTEXITCODE
    } finally { $ErrorActionPreference = $oldPreference }
    if ($exitCode -ne 0) { throw "Command failed (exit $exitCode): $Executable" }
}
function Resolve-Engine([string]$Association) {
    if ($EngineRoot) { return $EngineRoot }
    if ($env:UE_ENGINE_ROOT) { return $env:UE_ENGINE_ROOT }
    if ($Association -match '^\d+\.\d+(\.\d+)?$') {
        $install = Join-Path 'C:\Program Files\Epic Games' "UE_$Association"
        if (Test-Path -LiteralPath $install) { return $install }
    }
    if ($Association) {
        $registry = 'HKCU:\Software\Epic Games\Unreal Engine\Builds'
        if (Test-Path $registry) {
            $match = (Get-ItemProperty -Path $registry).PSObject.Properties |
                Where-Object { $_.Name -eq $Association } | Select-Object -First 1
            if ($match) { return [string]$match.Value }
        }
    }
    # When project is embedded in an engine source tree, walk up to find Engine/.
    $ancestor = $ProjectRoot
    while ($ancestor) {
        if (Test-Path (Join-Path $ancestor 'Engine\Build\BatchFiles\Build.bat')) { return $ancestor }
        $parent = Split-Path $ancestor -Parent
        if ($parent -eq $ancestor) { break }
        $ancestor = $parent
    }
    throw "Cannot resolve UE installation for EngineAssociation '$Association'. Set UE_ENGINE_ROOT or -EngineRoot."
}

try {
    Log "Project: $ProjectName ($((Rel $ProjectFile)))"
    Status 'Checking' 'Validating watched file changes.'
    if ($Mode -eq 'Auto') {
        if (-not $OldRevision -or -not $NewRevision) {
            throw 'Auto mode requires two Git revisions. Use -Mode Full for manual runs.'
        }
        $changed = @(& git diff --no-renames --name-only $OldRevision $NewRevision --)
        if ($LASTEXITCODE -ne 0) { throw 'Git revision comparison failed.' }
        $patterns = @($Config.WatchPatterns)
        if ($patterns.Count -eq 0) { throw 'WatchPatterns cannot be empty.' }
        $relevant = @($changed | Where-Object {
            $path = $_ -replace '\', '/'
            $matched = $false
            foreach ($pattern in $patterns) {
                if ($path -like [string]$pattern) { $matched = $true; break }
            }
            $matched
        })
        if ($relevant.Count -eq 0) {
            Log 'No watched files changed; no rebuild needed.'
            Status 'Skipped' 'No watched files changed.'
            Notify 'Skipped'
            exit 0
        }
        Log "Watched file changes: $($relevant.Count)"
        foreach ($path in $relevant) { Log "Changed: $path" }
    }

    if (Get-Process -Name 'UnrealEditor','UnrealEditor-Win64-DebugGame' -ErrorAction SilentlyContinue) {
        $IsDeferred = $true
        throw 'Unreal Editor is running. Close it and rerun UnrealSync -Mode Full.'
    }

    $json = Get-Content -LiteralPath $ProjectFile -Raw | ConvertFrom-Json
    $engine = [IO.Path]::GetFullPath((Resolve-Engine ([string]$json.EngineAssociation)).TrimEnd('\','/'))
    $buildBat = Join-Path $engine 'Engine\Build\BatchFiles\Build.bat'
    $ubt = Join-Path $engine 'Engine\Binaries\DotNET\UnrealBuildTool\UnrealBuildTool.exe'
    $generateBat = Join-Path $engine 'GenerateProjectFiles.bat'
    if (-not (Test-Path -LiteralPath $buildBat)) { throw "Build.bat not found: $buildBat" }

    $target = [string]$Config.EditorTarget
    if (-not $target) {
        $targetFiles = @(Get-ChildItem -LiteralPath (Join-Path $ProjectRoot 'Source') -Filter '*Editor.Target.cs' -File -ErrorAction SilentlyContinue)
        if ($targetFiles.Count -eq 1) { $target = $targetFiles[0].Name -replace '\.Target\.cs$', '' }
        if ($targetFiles.Count -gt 1) { throw 'Multiple Editor targets found; set EditorTarget in .unrealsync.json.' }
    }
    Log "Engine: $engine"
    Log "Editor target: $(if ($target) {$target} else {'none (Blueprint-only project)'})"
    Log "Cleanup profile: $CleanupKind"

    $cleanup = @(
        (Join-Path $ProjectRoot 'Binaries'),
        (Join-Path $ProjectRoot 'Intermediate'),
        (Join-Path $ProjectRoot '.vs')
    )
    $rootFiles = @(Get-ChildItem -LiteralPath $ProjectRoot -File -Force)
    $cleanup += @($rootFiles | Where-Object { $_.Extension -ieq '.sln' } | ForEach-Object { $_.FullName })
    if ($CleanupKind -eq 'Deep') {
        $cleanup += (Join-Path $ProjectRoot 'Saved'), (Join-Path $ProjectRoot 'DerivedDataCache')
        foreach ($file in @($rootFiles | Where-Object { $_.Extension -ieq '.vsconfig' -or $_.Name -ieq '.vsconfig' })) {
            $tracked = @(& git ls-files --cached -- (Rel $file.FullName))
            if ($LASTEXITCODE -ne 0) { throw 'Git inspection of .vsconfig failed.' }
            if ($tracked.Count -gt 0) { Log "Preserving Git-tracked configuration: $($file.Name)" }
            else { $cleanup += $file.FullName }
        }
    }
    if ($CleanPluginArtifacts -or $Config.CleanPluginArtifacts -eq $true) {
        $pluginRoot = Join-Path $ProjectRoot 'Plugins'
        if (Test-Path -LiteralPath $pluginRoot) {
            foreach ($plugin in @(Get-ChildItem -LiteralPath $pluginRoot -Filter '*.uplugin' -File -Recurse)) {
                $cleanup += (Join-Path $plugin.DirectoryName 'Binaries'), (Join-Path $plugin.DirectoryName 'Intermediate')
            }
        }
    }
    $cleanup = @($cleanup | Select-Object -Unique)
    foreach ($p in $cleanup) { Assert-Safe $p }

    if ($DryRun) {
        Log 'DRY RUN: no files removed or project compiled.'
        foreach ($p in $cleanup) { if (Test-Path -LiteralPath $p) { Log "Would delete: $(Rel $p)" } }
        Status 'DryRun' 'Validation completed; nothing was deleted.'
        exit 0
    }

    Status 'Running' 'Cleaning generated files and rebuilding.'
    Notify 'Started'
    if ($CleanupKind -eq 'Deep') { Backup-Settings }
    try {
        foreach ($p in $cleanup) {
            if (Test-Path -LiteralPath $p) {
                Log "Deleting: $(Rel $p)"
                Remove-Item -LiteralPath $p -Force -Recurse -ErrorAction Stop
            }
        }
    } finally {
        if ($CleanupKind -eq 'Deep') { Restore-Settings }
    }

    Log 'Regenerating project files...'
    if (Test-Path -LiteralPath $ubt) {
        Invoke-Native $ubt @('-ProjectFiles', "-Project=$ProjectFile", '-Game', '-Progress')
    } elseif (Test-Path -LiteralPath $generateBat) {
        Invoke-Native $generateBat @("-Project=$ProjectFile", '-Game')
    } else {
        throw "UnrealBuildTool and GenerateProjectFiles.bat are missing from engine: $engine"
    }
    if ($target) {
        $platform = if ($Config.Platform) { [string]$Config.Platform } else { 'Win64' }
        $configuration = if ($Config.BuildConfiguration) { [string]$Config.BuildConfiguration } else { 'Development' }
        Log "Building $target ($platform $configuration)..."
        Invoke-Native $buildBat @($target, $platform, $configuration, "-Project=$ProjectFile", '-WaitMutex')
    } else {
        Log 'No Editor target found: project-file generation complete; C++ build skipped.'
    }
    Status 'Succeeded' 'Project generation and configured build completed successfully.'
    Log 'SUCCESS: UnrealSync completed successfully.'
    Notify 'Succeeded'
    exit 0
} catch {
    $detail = $_.Exception.Message
    if ($IsDeferred) {
        Log "DEFERRED: $detail"
        Status 'Deferred' $detail
        Notify 'Deferred'
    } else {
        Log "FAILED: $detail"
        Status 'Failed' $detail
        Notify 'Failed'
    }
    Log "See log: $LogFile"
    exit 1
}
