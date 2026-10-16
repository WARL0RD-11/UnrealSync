# Runs in a separate hidden Windows PowerShell 5.1 process.
# No external PowerShell modules or elevated permissions are required.
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('Started','Succeeded','Failed','Deferred','Skipped','Test')]
    [string]$State,

    [string]$ProjectName = 'Unreal Project'
)

$ErrorActionPreference = 'Stop'

# This helper is Windows-only and intentionally never affects the build.
try {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    $title = "UnrealSync - $ProjectName"
    $message = ''
    $tipIcon = [System.Windows.Forms.ToolTipIcon]::Info

    switch ($State) {
        'Started' {
            $message = 'Rebuild started. Keep Unreal Editor closed.'
            $tipIcon = [System.Windows.Forms.ToolTipIcon]::Info
        }
        'Succeeded' {
            $message = 'Build successful. You can open the Unreal project.'
            $tipIcon = [System.Windows.Forms.ToolTipIcon]::Info
        }
        'Failed' {
            $message = 'Build failed. Check Saved\UnrealSync\latest.log before opening the project.'
            $tipIcon = [System.Windows.Forms.ToolTipIcon]::Error
        }
        'Deferred' {
            $message = 'Rebuild was blocked: Unreal Editor is running. Close it and run a manual full rebuild.'
            $tipIcon = [System.Windows.Forms.ToolTipIcon]::Warning
        }
        'Skipped' {
            $message = 'No build-affecting changes detected. No rebuild needed.'
            $tipIcon = [System.Windows.Forms.ToolTipIcon]::Info
        }
        'Test' {
            $message = 'Windows desktop notifications are available for UnrealSync.'
            $tipIcon = [System.Windows.Forms.ToolTipIcon]::Info
        }
    }

    $trayIcon = New-Object System.Windows.Forms.NotifyIcon
    try {
        $trayIcon.Icon = [System.Drawing.SystemIcons]::Application
        $trayIcon.Text = 'UnrealSync'
        $trayIcon.Visible = $true

        # The operating system controls actual display duration and presentation.
        $trayIcon.ShowBalloonTip(8000, $title, $message, $tipIcon)

        # Pump UI messages while the notification is displayed.
        $until = [DateTime]::UtcNow.AddSeconds(9)
        while ([DateTime]::UtcNow -lt $until) {
            [System.Windows.Forms.Application]::DoEvents()
            Start-Sleep -Milliseconds 100
        }
    }
    finally {
        $trayIcon.Visible = $false
        $trayIcon.Dispose()
    }
}
catch {
    # Notification failure must never interrupt builds or Git commands.
    # Use the status.json and latest.log files as the reliable source of truth.
    exit 0
}
