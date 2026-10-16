# Installs UnrealSync into any Windows Unreal Engine Git working tree.
# Usage: .\Install-UnrealSync.ps1 -RepositoryPath 'D:\Projects\MyGame'
#        .\Install-UnrealSync.ps1 -RepositoryPath 'D:\MonoRepo' -ProjectFile 'Games/MyGame/MyGame.uproject' -CleanupProfile Deep
[CmdletBinding()]
param(
    [string]$RepositoryPath = '.',
    [string]$ProjectFile = '',
    [ValidateSet('Standard', 'Deep')][string]$CleanupProfile = 'Standard',
    [switch]$Force
)
$ErrorActionPreference = 'Stop'
$Root = [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $RepositoryPath).Path)
$RepoRoot = (& git -C $Root rev-parse --show-toplevel 2>$null | Select-Object -First 1)
if ($LASTEXITCODE -ne 0 -or -not $RepoRoot) { throw 'RepositoryPath must be inside a Git working tree.' }
$RepoRoot = [IO.Path]::GetFullPath($RepoRoot)

if ($ProjectFile) {
    $Uproject = if ([IO.Path]::IsPathRooted($ProjectFile)) {
        [IO.Path]::GetFullPath($ProjectFile)
    } else { [IO.Path]::GetFullPath((Join-Path $RepoRoot $ProjectFile)) }
} else {
    $candidates = @(Get-ChildItem -LiteralPath $RepoRoot -Filter '*.uproject' -File)
    if ($candidates.Count -ne 1) {
        throw 'Expected one .uproject at repository root. Specify -ProjectFile for nested/multiple projects.'
    }
    $Uproject = $candidates[0].FullName
}
if (-not $Uproject.StartsWith(($RepoRoot.TrimEnd('\') + '\'), [StringComparison]::OrdinalIgnoreCase)) {
    throw 'ProjectFile must be within the selected Git repository.'
}
if (-not (Test-Path -LiteralPath $Uproject) -or [IO.Path]::GetExtension($Uproject) -ine '.uproject') {
    throw "Unreal .uproject missing: $Uproject"
}
$RelativeProject = $Uproject.Substring($RepoRoot.Length).TrimStart('\','/') -replace '\','/'
$ProjectDirectory = Split-Path -Path $RelativeProject -Parent
$Prefix = if ($ProjectDirectory) { ($ProjectDirectory -replace '\','/') + '/' } else { '' }

# Existing hook managers must not be silently overwritten.
$current = (& git -C $RepoRoot config --local --get core.hooksPath 2>$null | Select-Object -First 1)
if ($current -and ($current -replace '\','/') -ne '.githooks') {
    throw "Existing core.hooksPath is '$current'. Integrate manually instead of replacing it."
}
$HooksDir = Join-Path $RepoRoot '.githooks'
foreach ($name in @('post-merge','post-rewrite')) {
    $target = Join-Path $HooksDir $name
    if (Test-Path -LiteralPath $target) {
        $first = Get-Content -LiteralPath $target -TotalCount 2
        if (($first -join "`n") -notmatch 'Managed by UnrealSync') {
            throw "Existing hook is not managed by UnrealSync: $target. Integrate manually."
        }
    }
}

$ToolDir = Join-Path $RepoRoot '.unrealsync'
$Configuration = Join-Path $RepoRoot '.unrealsync.json'
if ((Test-Path -LiteralPath $Configuration) -and -not $Force) {
    Write-Warning 'Existing .unrealsync.json preserved. Pass -Force only if you intentionally want to replace its settings.'
}
New-Item -ItemType Directory -Path $ToolDir, $HooksDir -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'src\UnrealSync.ps1') -Destination $ToolDir -Force
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'src\UnrealSyncNotify.ps1') -Destination $ToolDir -Force
foreach ($name in @('post-merge', 'post-rewrite')) {
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot "hooks\$name") -Destination $HooksDir -Force
}

if (-not (Test-Path -LiteralPath $Configuration) -or $Force) {
    $watch = @(
        "${Prefix}Source/*", "${Prefix}Plugins/*.uplugin",
        "${Prefix}Plugins/*.cs", "${Prefix}Config/DefaultEngine.ini",
        "${Prefix}*.uproject", '.unrealsync/*', '.unrealsync.json'
    )
    $settings = [ordered]@{
        ProjectFile = $RelativeProject
        EditorTarget = ''
        CleanupProfile = $CleanupProfile
        Platform = 'Win64'
        BuildConfiguration = 'Development'
        Notifications = $true
        CleanPluginArtifacts = $false
        WatchPatterns = $watch
    }
    $settings | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $Configuration -Encoding UTF8
}
& git -C $RepoRoot config --local core.hooksPath .githooks
if ($LASTEXITCODE -ne 0) { throw 'Failed to configure core.hooksPath.' }
Write-Host "UnrealSync installed into: $RepoRoot" -ForegroundColor Green
Write-Host "Project: $RelativeProject"
Write-Host 'Commit .unrealsync/, .githooks/, and .unrealsync.json to share with your team.'
Write-Host 'Do not commit .git/unrealsync/ (runtime logs and local backups).'
Write-Host 'Run a preview from repo root:'
Write-Host '  powershell -NoProfile -ExecutionPolicy Bypass -File .\.unrealsync\UnrealSync.ps1 -Mode Full -DryRun'
