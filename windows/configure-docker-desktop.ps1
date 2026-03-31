<#
.SYNOPSIS
  Configures Docker Desktop for Altosec proxy node requirements in one command.

.DESCRIPTION
  Applies the four settings required for host-networking Linux containers on Windows:
    1. Expose daemon on tcp://localhost:2375 (Settings -> General)
    2. Enable Host Networking        (Settings -> Resources -> Network)
    3. Daemon GC config              (Settings -> Docker Engine JSON)
    4. WSL2 mirrored networking      (~/.wslconfig)
  Stops Docker Desktop, patches settings files, then restarts it.
  Does NOT install Docker Desktop itself - install it first and launch it at least once.

.PARAMETER NoRestart
  Patch settings files but do not restart Docker Desktop. You must restart manually.

.PARAMETER WslConfigPath
  Path to .wslconfig file. Defaults to "$env:USERPROFILE\.wslconfig".
#>
[CmdletBinding()]
param(
    [switch] $NoRestart,
    [string] $WslConfigPath = ''
)

$ErrorActionPreference = 'Stop'

# --- Locate Docker Desktop settings file ---
$settingsStorePath = Join-Path $env:APPDATA 'Docker\settings-store.json'
$settingsJsonPath  = Join-Path $env:APPDATA 'Docker\settings.json'

if (Test-Path $settingsStorePath) {
    $activePath = $settingsStorePath
} elseif (Test-Path $settingsJsonPath) {
    $activePath = $settingsJsonPath
} else {
    throw @'
Docker Desktop settings file not found at:
  $env:APPDATA\Docker\settings-store.json
  $env:APPDATA\Docker\settings.json

Install Docker Desktop and launch it at least once so it creates its settings file, then re-run this script.
'@
}

Write-Host "Settings file: $activePath"

# --- Stop Docker Desktop ---
$ddProc = Get-Process 'Docker Desktop' -ErrorAction SilentlyContinue
if ($ddProc) {
    Write-Host 'Stopping Docker Desktop...'
    $ddProc | Stop-Process -Force
    Start-Sleep -Seconds 5
}

# Shut down WSL so new .wslconfig takes effect on next Docker Desktop start
Write-Host 'Shutting down WSL...'
& wsl --shutdown 2>$null

# --- Patch settings.json / settings-store.json ---
$raw      = Get-Content $activePath -Raw -Encoding UTF8
$settings = $raw | ConvertFrom-Json

# 1. Expose daemon on TCP 2375
$settings | Add-Member -NotePropertyName 'exposeDockerAPIOnTCP2375' -NotePropertyValue $true -Force
Write-Host '  [+] exposeDockerAPIOnTCP2375 = true'

# 2. Host Networking
$settings | Add-Member -NotePropertyName 'hostNetworkingEnabled' -NotePropertyValue $true -Force
Write-Host '  [+] hostNetworkingEnabled = true'

# 3. Docker Engine JSON — deep-merge only the keys we need, preserve others
if ($null -eq $settings.dockerEngine) {
    $settings | Add-Member -NotePropertyName 'dockerEngine' -NotePropertyValue ([PSCustomObject]@{}) -Force
}
$de = $settings.dockerEngine

if ($null -eq $de.PSObject.Properties['builder']) {
    $de | Add-Member -NotePropertyName 'builder' -NotePropertyValue ([PSCustomObject]@{}) -Force
}
if ($null -eq $de.builder.PSObject.Properties['gc']) {
    $de.builder | Add-Member -NotePropertyName 'gc' -NotePropertyValue ([PSCustomObject]@{}) -Force
}
$de.builder.gc | Add-Member -NotePropertyName 'defaultKeepStorage' -NotePropertyValue '20GB' -Force
$de.builder.gc | Add-Member -NotePropertyName 'enabled'            -NotePropertyValue $true  -Force
$de            | Add-Member -NotePropertyName 'experimental'        -NotePropertyValue $false -Force
$de            | Add-Member -NotePropertyName 'userland-proxy'       -NotePropertyValue $false -Force
Write-Host '  [+] dockerEngine.builder.gc.defaultKeepStorage = 20GB'
Write-Host '  [+] dockerEngine.builder.gc.enabled = true'
Write-Host '  [+] dockerEngine.experimental = false'
Write-Host '  [+] dockerEngine.userland-proxy = false'

$settings | ConvertTo-Json -Depth 20 | Set-Content $activePath -Encoding UTF8
Write-Host "Settings written: $activePath"

# --- Write / update .wslconfig ---
if ([string]::IsNullOrWhiteSpace($WslConfigPath)) {
    $WslConfigPath = Join-Path $env:USERPROFILE '.wslconfig'
}

$desiredLine = 'networkingMode=mirrored'

if (-not (Test-Path $WslConfigPath)) {
    # Create new file
    Set-Content $WslConfigPath -Value "[wsl2]`r`n$desiredLine`r`n" -Encoding UTF8
    Write-Host "  [+] Created .wslconfig: $WslConfigPath"
} else {
    $lines = Get-Content $WslConfigPath

    # Already set?
    if ($lines -match '^\s*networkingMode\s*=\s*mirrored\s*$') {
        Write-Host "  [=] .wslconfig already has $desiredLine — no change."
    } elseif ($lines -match '^\s*networkingMode\s*=') {
        # Different value — update in place
        $lines = $lines -replace '^\s*networkingMode\s*=.*$', $desiredLine
        Set-Content $WslConfigPath -Value $lines -Encoding UTF8
        Write-Host "  [+] Updated networkingMode in .wslconfig: $WslConfigPath"
    } else {
        # networkingMode absent — insert under [wsl2] or append section
        $wsl2Index = ($lines | Select-String -Pattern '^\s*\[wsl2\]\s*$' -CaseSensitive:$false).LineNumber
        if ($wsl2Index) {
            # Insert after [wsl2] line (LineNumber is 1-based)
            $idx    = $wsl2Index   # already points one past [wsl2] because LineNumber is 1-based and arrays are 0-based
            $before = $lines[0..($idx - 1)]
            $after  = if ($idx -lt $lines.Count) { $lines[$idx..($lines.Count - 1)] } else { @() }
            $lines  = $before + $desiredLine + $after
        } else {
            # No [wsl2] section — append
            $lines = $lines + '' + '[wsl2]' + $desiredLine
        }
        Set-Content $WslConfigPath -Value $lines -Encoding UTF8
        Write-Host "  [+] Added networkingMode to .wslconfig: $WslConfigPath"
    }
}

# --- Restart Docker Desktop ---
$ddExe = "${env:ProgramFiles}\Docker\Docker\Docker Desktop.exe"

if (-not $NoRestart) {
    if (Test-Path $ddExe) {
        Write-Host 'Starting Docker Desktop...'
        Start-Process $ddExe
        Write-Host 'Docker Desktop is starting. Wait for the tray icon before running docker commands.'
    } else {
        Write-Warning "Docker Desktop.exe not found at '$ddExe'. Start Docker Desktop manually to apply settings."
    }
} else {
    Write-Host '-NoRestart specified. Start Docker Desktop manually to apply the new settings.'
}

Write-Host ''
Write-Host 'Done. All four host-networking settings applied:'
Write-Host "  exposeDockerAPIOnTCP2375  = true  ($activePath)"
Write-Host "  hostNetworkingEnabled     = true  ($activePath)"
Write-Host "  dockerEngine GC + no-experimental + userland-proxy=false  ($activePath)"
Write-Host "  networkingMode=mirrored   ($WslConfigPath)"
