$ErrorActionPreference = 'Stop'

$TempPath = 'C:\Windows\Temp'
$LogFile  = Join-Path $TempPath 'deploy.log'

# --- DX CyberProtect target release ---
$TargetVer = '1.0.1'
$MsiUrl    = "https://raw.githubusercontent.com/dycheto/agent/main/DX-CyberProtect_v$TargetVer.msi"
$MsiPath   = Join-Path $TempPath "DX-CyberProtect_v$TargetVer.msi"

# --- Wazuh agent installer (unchanged) ---
$InstallScriptUrl  = 'https://raw.githubusercontent.com/dycheto/agent/main/install-agent.ps1'
$InstallScriptPath = Join-Path $TempPath 'install-agent.ps1'

function Write-Log {
    param([string]$Message)
    Add-Content -Path $LogFile -Value "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') - $Message"
}

function Test-InstalledSoftware {
    param([string]$DisplayName)

    $Paths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )

    foreach ($Path in $Paths) {
        $Item = Get-ItemProperty $Path -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -eq $DisplayName }

        if ($Item) { return $true }
    }

    return $false
}

function Get-InstalledVersion {
    param([string]$DisplayName)

    $Paths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )

    foreach ($Path in $Paths) {
        $Item = Get-ItemProperty $Path -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -eq $DisplayName } |
            Select-Object -First 1

        if ($Item) { return $Item.DisplayVersion }
    }

    return $null
}

function Stop-DxProcess {
    $procs = Get-Process -Name 'DX-CyberProtect' -ErrorAction SilentlyContinue
    if (-not $procs) {
        Write-Log 'No running DX-CyberProtect.exe found.'
        return
    }

    Write-Log "Stopping $($procs.Count) DX-CyberProtect.exe process(es)."
    foreach ($p in $procs) {
        try {
            $p.Kill()
            $null = $p.WaitForExit(10000)
        }
        catch {
            Write-Log "Failed to kill PID $($p.Id): $($_.Exception.Message)"
        }
    }

    # Belt-and-suspenders in case a new instance respawned via Run key
    Start-Process -FilePath 'taskkill.exe' `
        -ArgumentList '/IM DX-CyberProtect.exe /F /T' `
        -WindowStyle Hidden -Wait -ErrorAction SilentlyContinue | Out-Null
}

function Install-DxCyberProtect {
    Write-Log "Downloading DX CyberProtect MSI from $MsiUrl"
    Invoke-WebRequest -UseBasicParsing -Uri $MsiUrl -OutFile $MsiPath

    Write-Log 'Installing/upgrading DX CyberProtect silently.'
    $msi = Start-Process -FilePath 'msiexec.exe' `
        -ArgumentList "/i `"$MsiPath`" /qn /norestart REBOOT=ReallySuppress" `
        -Wait -PassThru
    Write-Log "DX CyberProtect MSI exit code: $($msi.ExitCode)"
    return $msi.ExitCode
}

try {
    Write-Log '--- Bootstrap started ---'

    $InstalledVer   = Get-InstalledVersion -DisplayName 'DX CyberProtect'
    $WazuhInstalled = Test-InstalledSoftware -DisplayName 'Wazuh Agent'

    Write-Log "DX CyberProtect installed version: $InstalledVer (target $TargetVer)"
    Write-Log "Shield Agent installed: $WazuhInstalled"

    # ---- DX CyberProtect: install or upgrade as needed ----
    if (-not $InstalledVer) {
        Write-Log 'DX CyberProtect is missing. Performing fresh install.'
        Install-DxCyberProtect | Out-Null
    }
    elseif ($InstalledVer -ne $TargetVer) {
        Write-Log "DX CyberProtect version mismatch ($InstalledVer != $TargetVer). Upgrading."
        Stop-DxProcess
        Start-Sleep -Seconds 2
        Install-DxCyberProtect | Out-Null
    }
    else {
        Write-Log "DX CyberProtect already at target version $TargetVer. Skipping."
    }

    # ---- Wazuh Agent: unchanged logic ----
    if (-not $WazuhInstalled) {
        Write-Log 'Shield Agent is missing. Downloading install-agent.ps1.'
        Invoke-WebRequest -UseBasicParsing -Uri $InstallScriptUrl -OutFile $InstallScriptPath

        Write-Log 'Running install-agent.ps1.'
        $ps = Start-Process -FilePath 'powershell.exe' `
            -ArgumentList "-ExecutionPolicy Bypass -File `"$InstallScriptPath`"" `
            -WindowStyle Hidden -Wait -PassThru
        Write-Log "install-agent.ps1 exit code: $($ps.ExitCode)"
    }
    else {
        Write-Log 'Shield Agent already installed. Skipping install-agent.ps1.'
    }

    Write-Log 'Cleaning up downloaded files.'
    Remove-Item -Path $MsiPath -Force -ErrorAction SilentlyContinue
    Remove-Item -Path $InstallScriptPath -Force -ErrorAction SilentlyContinue

    Write-Log '--- Bootstrap completed ---'
}
catch {
    Write-Log "Bootstrap failed: $($_.Exception.Message)"
    exit 1
}