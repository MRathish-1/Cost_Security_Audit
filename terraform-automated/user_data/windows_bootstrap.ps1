<powershell>
# Transcript logging: Windows Server 2022's EC2Launch v2 does not reliably
# surface <powershell> block errors in the console log (see
# ISSUES_AND_FIXES.md #1). Logging to a known file makes failures visible
# via SSM even when the console log shows a clean boot.
Start-Transcript -Path "C:\ProgramData\csa-bootstrap.log" -Append

try {
    $installerPath = "C:\ps7-installer.msi"
    $ps7Url = "https://github.com/PowerShell/PowerShell/releases/download/v7.4.6/PowerShell-7.4.6-win-x64.msi"
    $pwshPath = "C:\Program Files\PowerShell\7\pwsh.exe"

    Write-Output "Downloading PowerShell 7 installer..."
    Invoke-WebRequest -Uri $ps7Url -OutFile $installerPath -UseBasicParsing

    Write-Output "Installing PowerShell 7..."
    Start-Process msiexec.exe -ArgumentList "/i", $installerPath, "/quiet", "/norestart", "ADD_PATH=1" -Wait

    if (-not (Test-Path $pwshPath)) {
        throw "pwsh.exe not found at $pwshPath after install - MSI may have failed silently."
    }
    Write-Output "PowerShell 7 confirmed at $pwshPath."

    # Install AWS Tools explicitly under PS7's module path, invoking pwsh by
    # full path rather than relying on PATH (the SSM Agent service caches
    # its PATH at startup and won't see the installer's PATH update without
    # a restart - see ISSUES_AND_FIXES.md #2).
    Write-Output "Installing AWS Tools for PowerShell under PS7..."
    & $pwshPath -Command "Install-Module -Name AWS.Tools.Installer -Force -Scope AllUsers; Install-AWSToolsModule AWS.Tools.S3,AWS.Tools.EC2 -CleanUp -Force -Scope AllUsers"

    New-Item -ItemType Directory -Path "C:\tmp" -Force | Out-Null
    Write-Output "Bootstrap complete."
}
catch {
    Write-Output "BOOTSTRAP FAILED: $($_.Exception.Message)"
}
finally {
    Stop-Transcript
}
</powershell>
