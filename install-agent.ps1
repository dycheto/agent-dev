# Check for elevation
If (-NOT ([Security.Principal.WindowsPrincipal] `
    [Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {

    # Relaunch as administrator
    Start-Process powershell -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
    exit
}
$svcName = "WazuhSvc"

# Skip work if Wazuh agent is already installed and running
$existingSvc = Get-Service -Name $svcName -ErrorAction SilentlyContinue
if ($existingSvc -and $existingSvc.Status -eq 'Running') {
    Write-Host "Shield agent is already installed and running. No action needed." -ForegroundColor Green
    return
}

Write-Host "Shield agent not detected or not running. Proceeding with installation..." -ForegroundColor Yellow
#---------------------------------------------------------------------------------------------------------------------------------------
# PART 1. Installing Shield Agent
Write-Host "Downloading Shield Agent..."
# Download the installer
$wazuhInstaller = "$env:temp\wazuh-agent-4.14.3-1.msi"
Invoke-WebRequest -Uri "https://packages.wazuh.com/4.x/windows/wazuh-agent-4.14.3-1.msi" -OutFile $wazuhInstaller

# Install and wait
$installProcess = Start-Process -FilePath "msiexec.exe" `
    -ArgumentList "/i `"$wazuhInstaller`" /q WAZUH_MANAGER=cloud.diamatix.com WAZUH_REGISTRATION_PASSWORD=wDp2xEQPDrBdkQCO WAZUH_AGENT_GROUP=DX-Tracker WAZUH_MANAGER_PORT=1504 WAZUH_REGISTRATION_PORT=1505" `
    -PassThru -Wait

$timeoutSec = 180
$pollSeconds = 5
$timer = [System.Diagnostics.Stopwatch]::StartNew()
# Wait (bounded) for service to exist and reach Running
while ($timer.Elapsed.TotalSeconds -lt $timeoutSec) {
    $svc = Get-Service -Name $svcName -ErrorAction SilentlyContinue
    if (-not $svc) {
        Write-Host "Waiting for Shield service to be created..." -ForegroundColor Yellow
        Start-Sleep -Seconds $pollSeconds
        continue
    }

    if ($svc.Status -ne 'Running') {
        Write-Host "Starting Shield service (current: $($svc.Status))..." -ForegroundColor Yellow
        Start-Service -Name $svcName -ErrorAction SilentlyContinue
        $svc.Refresh()
    }

    if ($svc.Status -eq 'Running') { break }
    Start-Sleep -Seconds $pollSeconds
}

if (-not $svc -or $svc.Status -ne 'Running') {
    throw "Shield service did not reach 'Running' within $timeoutSec seconds."
}

Write-Host "Shield service started and running." -ForegroundColor Green