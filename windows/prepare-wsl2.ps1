<#
.SYNOPSIS
  Prepare a Windows host to run Altosec proxy nodes via WSL2 Docker Engine.

.DESCRIPTION
  Replaces the Docker Desktop requirement. This script:
    1. Verifies WSL2 is available (enables it via DISM if needed — requires reboot on first-time setup).
    2. Installs Ubuntu 24.04 WSL2 distro if no suitable distro is present.
    3. Writes ~/.wslconfig with networkingMode=mirrored (real client IPs visible inside containers).
    4. Enables systemd inside WSL2 (/etc/wsl.conf boot.systemd=true).
    5. Shuts down and restarts WSL2 so the new settings take effect.
    6. Runs scripts/linux/bootstrap-node.sh INSIDE WSL2 (installs Docker Engine,
       GitHub Actions runner, systemd services — the same script used on native Linux).
    7. Creates a Windows Task Scheduler task that starts WSL2 Ubuntu on system boot,
       so Docker and the runner come up automatically after a Windows restart.

  TLS is handled by the upstream nginx reverse proxy. This server runs plain HTTP on port 80.
  After this script completes the node is fully provisioned. The GitHub Actions Deploy workflow
  handles all subsequent docker pull / compose operations.

.PARAMETER RunnerName
  Unique name for the GitHub Actions runner (shown in Settings -> Actions -> Runners).

.PARAMETER RegistrationToken
  GitHub runner registration token (expires in minutes — get it immediately before running).
  GitHub -> repo -> Settings -> Actions -> Runners -> New self-hosted runner -> copy token.

.PARAMETER RepoUrl
  GitHub repo URL. Default: https://github.com/alto-sec/Altosec-proxy-server

.PARAMETER DeployDir
  Path inside WSL2 where deploy artefacts live. Default: /opt/altosec-deploy

.PARAMETER RunnerRoot
  Path inside WSL2 where the runner is installed. Default: /opt/actions-runner

.PARAMETER WslDistro
  WSL2 distro name to use. Default: Ubuntu-24.04 (installed if not present).

.PARAMETER SkipWslInstall
  Skip WSL2 feature enablement / distro install — assume WSL2 is already set up.

.EXAMPLE
  .\scripts\windows\prepare-wsl2.ps1 `
    -RunnerName        my-proxy-node-01 `
    -RegistrationToken <token>
#>
[CmdletBinding()]
param(
    [string] $RunnerName         = '',
    [string] $RegistrationToken  = '',
    [string] $RepoUrl            = '',
    [string] $DeployDir          = '/opt/altosec-deploy',
    [string] $RunnerRoot         = '/opt/actions-runner',
    [string] $WslDistro          = 'Ubuntu-24.04',
    [switch] $SkipWslInstall
)

# Use 'Continue' (PowerShell default) instead of 'Stop'.
# Ubuntu 24.04 WSL2 with systemd writes "Failed to start systemd user session for root"
# to stderr on every wsl invocation. With 'Stop', PowerShell converts any native-command
# stderr into a terminating NativeCommandError — even when 2>$null is used.
# We use explicit exit-code checks and throw where needed instead.
$ErrorActionPreference = 'Continue'

function Read-WithDefault {
    param([string] $Prompt, [string] $Default)
    $hint = if ($Default) { " [$Default]" } else { '' }
    $line = Read-Host "$Prompt$hint"
    if ([string]::IsNullOrWhiteSpace($line)) { return $Default }
    return $line.Trim()
}

# ── Interactive prompts for required values ────────────────────────────────────

if ([string]::IsNullOrWhiteSpace($RunnerName)) {
    $RunnerName = Read-Host 'Runner name (unique on GitHub, e.g. proxy-node-01)'
}
if ([string]::IsNullOrWhiteSpace($RegistrationToken)) {
    $RegistrationToken = Read-Host 'GitHub runner registration token'
}
if ([string]::IsNullOrWhiteSpace($RepoUrl)) {
    $RepoUrl = Read-WithDefault -Prompt 'Repo URL' -Default 'https://github.com/alto-sec/Altosec-proxy-server'
}

$RunnerName = $RunnerName.Trim()

if (-not $RunnerName)        { throw 'RunnerName is required.' }
if (-not $RegistrationToken) { throw 'RegistrationToken is required.' }

# ── Step 1: WSL2 feature + distro ─────────────────────────────────────────────

if (-not $SkipWslInstall) {
    Write-Host '=== Step 1: WSL2 feature and Ubuntu distro ==='

    # Check if WSL2 is already functional.
    $wslCheck = $null
    try { $wslCheck = & wsl -l -v 2>&1 } catch { }
    $wslReady = ($null -ne $wslCheck) -and ($LASTEXITCODE -eq 0)

    if (-not $wslReady) {
        Write-Host 'Enabling WSL2 via DISM (requires administrator)...'
        dism.exe /Online /Enable-Feature /FeatureName:Microsoft-Windows-Subsystem-Linux /All /NoRestart | Out-Null
        dism.exe /Online /Enable-Feature /FeatureName:VirtualMachinePlatform /All /NoRestart | Out-Null
        Write-Warning @'
WSL2 features were just enabled. A REBOOT is required before continuing.
After rebooting, re-run this script. WSL2 will be ready on the next run.
'@
        exit 0
    }

    # Set WSL default version to 2.
    & wsl --set-default-version 2 | Out-Null

    # Check if the target distro is already registered via the Windows registry.
    # Avoids running a command inside the distro (which triggers systemd user-session
    # warnings on Ubuntu 24.04 with systemd enabled, causing NativeCommandError).
    $lxssKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss'
    $distroExists = $false
    if (Test-Path $lxssKey) {
        $distroExists = ($null -ne (
            Get-ChildItem $lxssKey -ErrorAction SilentlyContinue |
            Get-ItemProperty -ErrorAction SilentlyContinue |
            Where-Object { $_.DistributionName -eq $WslDistro }
        ))
    }

    if (-not $distroExists) {
        Write-Host "Installing WSL2 distro: $WslDistro ..."
        & wsl --install -d $WslDistro --no-launch
        if ($LASTEXITCODE -ne 0) {
            throw "wsl --install -d $WslDistro failed (exit $LASTEXITCODE). Ensure Windows Update is current and Virtualization is enabled in BIOS."
        }
        Write-Host "Distro $WslDistro installed."

        # Wait for distro to be usable (first-boot provisioning).
        Write-Host 'Waiting for distro to finish first-boot setup (up to 120 s)...'
        $deadline = (Get-Date).AddSeconds(120)
        while ((Get-Date) -lt $deadline) {
            $test = & wsl -d $WslDistro -- echo ready 2>&1
            if ("$test" -match 'ready') { break }
            Start-Sleep -Seconds 5
        }
    } else {
        Write-Host "$WslDistro is already installed."
    }
} else {
    Write-Host 'SkipWslInstall: assuming WSL2 is already configured.'
}

# ── Step 2: .wslconfig — networkingMode=mirrored ──────────────────────────────

Write-Host '=== Step 2: .wslconfig networkingMode=mirrored ==='

$wslCfgPath = Join-Path $env:USERPROFILE '.wslconfig'
$desiredLine = 'networkingMode=mirrored'

if (-not (Test-Path $wslCfgPath)) {
    Set-Content $wslCfgPath -Value "[wsl2]`r`n$desiredLine`r`n" -Encoding UTF8
    Write-Host "  [+] Created $wslCfgPath with $desiredLine"
} else {
    $lines = Get-Content $wslCfgPath
    if ($lines -match '^\s*networkingMode\s*=\s*mirrored') {
        Write-Host "  [=] .wslconfig already has $desiredLine"
    } elseif ($lines -match '^\s*networkingMode\s*=') {
        $lines = $lines -replace '^\s*networkingMode\s*=.*$', $desiredLine
        Set-Content $wslCfgPath -Value $lines -Encoding UTF8
        Write-Host "  [+] Updated networkingMode in .wslconfig"
    } else {
        $wsl2Idx = ($lines | Select-String -Pattern '^\s*\[wsl2\]' -CaseSensitive:$false).LineNumber
        if ($wsl2Idx) {
            $before = $lines[0..($wsl2Idx - 1)]
            $after  = if ($wsl2Idx -lt $lines.Count) { $lines[$wsl2Idx..($lines.Count - 1)] } else { @() }
            $lines  = $before + $desiredLine + $after
        } else {
            $lines  = $lines + '' + '[wsl2]' + $desiredLine
        }
        Set-Content $wslCfgPath -Value $lines -Encoding UTF8
        Write-Host "  [+] Added $desiredLine to .wslconfig"
    }
}

# ── Step 3: Enable systemd in WSL2 ────────────────────────────────────────────

Write-Host '=== Step 3: Enable systemd in WSL2 ==='

# Modify /etc/wsl.conf directly via the Windows \\wsl$ filesystem mount.
# This avoids running bash inside the distro at this stage — Ubuntu 24.04 with
# systemd already enabled can produce stderr warnings that interfere with scripting.
# Accessing \\wsl$\<distro> auto-starts the distro if it is not already running.

$wslConfWin = "\\wsl$\$WslDistro\etc\wsl.conf"
$cfg = ''
if (Test-Path $wslConfWin) {
    $cfg = Get-Content $wslConfWin -Raw -ErrorAction SilentlyContinue
    if (-not $cfg) { $cfg = '' }
}

if ($cfg -match '(?m)^\s*systemd\s*=\s*true') {
    Write-Host '  [=] systemd already enabled in /etc/wsl.conf'
} else {
    if ($cfg -match '(?m)^\s*systemd\s*=') {
        $cfg = $cfg -replace '(?m)^\s*systemd\s*=.*', 'systemd=true'
    } elseif ($cfg -match '(?m)^\[boot\]') {
        $cfg = $cfg -replace '(?m)(^\[boot\])', "`$1`nsystemd=true"
    } else {
        $trimmed = $cfg.TrimEnd()
        $cfg = if ($trimmed) { "$trimmed`n`n[boot]`nsystemd=true`n" } else { "[boot]`nsystemd=true`n" }
    }
    [System.IO.File]::WriteAllText($wslConfWin, $cfg)
    Write-Host '  [+] systemd=true written to /etc/wsl.conf'
}

# ── Step 4: Restart WSL2 so settings take effect ──────────────────────────────

Write-Host '=== Step 4: Restarting WSL2 ==='
& wsl --shutdown
Start-Sleep -Seconds 8

# Wake it back up (stderr from systemd user-session warning is harmless noise).
& wsl -d $WslDistro -- echo 'WSL2 restarted' 2>&1 | Out-Null
Write-Host 'WSL2 restarted.'

# ── Step 5: Run bootstrap-node.sh inside WSL2 ─────────────────────────────────

Write-Host '=== Step 5: Running bootstrap-node.sh inside WSL2 ==='

# Find the script relative to this file's location (works from repo clone and from image extract).
$scriptDir   = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$deployRoot  = (Resolve-Path (Join-Path $scriptDir "..\..")).Path
$bootstrapWin = Join-Path $deployRoot 'scripts\linux\bootstrap-node.sh'

if (-not (Test-Path $bootstrapWin)) {
    throw "bootstrap-node.sh not found at $bootstrapWin. Ensure the scripts\linux\ folder is present."
}

# Convert Windows path to WSL2 path (C:\foo\bar -> /mnt/c/foo/bar).
$bootstrapWsl = ($bootstrapWin -replace '\\', '/') -replace '^([A-Za-z]):', { "/mnt/$($_.Groups[1].Value.ToLower())" }

$bootstrapArgs = @(
    "--repo-url",    $RepoUrl,
    "--token",       $RegistrationToken,
    "--runner-name", $RunnerName,
    "--deploy-dir",  $DeployDir,
    "--runner-root", $RunnerRoot
)

$argsStr = ($bootstrapArgs | ForEach-Object { "'$_'" }) -join ' '
$cmd = "bash '$bootstrapWsl' $argsStr"

Write-Host "Running inside WSL2: $cmd"
# Default user for fresh Ubuntu-24.04 WSL is root — no need for -u root.
# Explicit -u root causes systemd user@0.service setup which can hang.
& wsl -d $WslDistro -- bash -c $cmd
if ($LASTEXITCODE -ne 0) { throw "bootstrap-node.sh failed (exit $LASTEXITCODE)" }

# ── Step 6: Windows Task Scheduler — auto-start WSL2 on boot ──────────────────

Write-Host '=== Step 6: Task Scheduler — auto-start WSL2 on Windows boot ==='

$taskName   = 'AltosecProxyWsl2Autostart'
$taskExists = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue

# Startup command: wake WSL2 distro so systemd (docker + runner) comes up automatically.
# No -u root: default user is root, and explicit -u root can hang due to systemd user session.
$action  = New-ScheduledTaskAction `
    -Execute 'wsl.exe' `
    -Argument "-d $WslDistro -- bash -c `"systemctl start docker 2>/dev/null; exit 0`""
$trigger = New-ScheduledTaskTrigger -AtStartup
$settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 5)
$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -RunLevel Highest

if ($taskExists) {
    Set-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger `
        -Settings $settings -Principal $principal | Out-Null
    Write-Host "  [=] Updated scheduled task '$taskName'."
} else {
    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger `
        -Settings $settings -Principal $principal -Force | Out-Null
    Write-Host "  [+] Created scheduled task '$taskName' (runs as SYSTEM at startup)."
}

# ── Done ──────────────────────────────────────────────────────────────────────

Write-Host ''
Write-Host '=== prepare-wsl2.ps1 complete ==='
Write-Host "  WSL2 distro          : $WslDistro"
Write-Host "  .wslconfig           : networkingMode=mirrored ($wslCfgPath)"
Write-Host "  Deploy dir (WSL2)    : $DeployDir"
Write-Host "  Runner name          : $RunnerName"
Write-Host "  Boot task            : $taskName (SYSTEM, at-startup)"
Write-Host ''
Write-Host 'Next: confirm the runner shows Idle in GitHub -> Settings -> Actions -> Runners,'
Write-Host 'then trigger the Deploy workflow (handles docker pull and compose up).'
