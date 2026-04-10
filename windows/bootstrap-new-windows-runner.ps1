#Requires -RunAsAdministrator
<#
.SYNOPSIS
  New Windows server: verify Docker, set ALTOSEC_* system variables, open firewall TCP 80, install and register GitHub self-hosted runner, configure Local System + docker-users (SYSTEM).

.DESCRIPTION
  Private GHCR policy: container startup is handled exclusively by the GitHub Deploy workflow.
  When run without parameters (e.g. via iex(irm raw URL)), required values are prompted interactively via Read-Host.

.PARAMETER DeployDomainFqdn
  Public FQDN. If empty, prompted interactively.

.PARAMETER RunnerName
  Unique runner name on GitHub. If empty, prompted interactively.

.PARAMETER RegistrationToken
  GitHub runner registration token. If empty, prompted interactively.

.PARAMETER RepoUrl
  Default: https://github.com/alto-sec/Altosec-proxy-server (press Enter to keep)

.PARAMETER RunnerRoot
  Default: C:\actions-runner

.PARAMETER DeployDir
  Default: C:\altosec-deploy

.PARAMETER AcmeContactEmail
  Let's Encrypt ACME contact email (not stored as a system env var). If empty, prompted interactively. Saved only to acme-contact-email.txt in the deploy root.
#>
[CmdletBinding()]
param(
    [string] $DeployDomainFqdn = '',
    [string] $RunnerName = '',
    [string] $RegistrationToken = '',
    [string] $RepoUrl = '',
    [string] $RunnerRoot = '',
    [string] $DeployDir = '',
    [string] $AcmeContactEmail = ''
)

$ErrorActionPreference = 'Stop'

function Read-WithDefault {
    param(
        [string] $Prompt,
        [string] $Default
    )
    $hint = if ($null -ne $Default -and $Default -ne '') { " [$Default]" } else { '' }
    $line = Read-Host "$Prompt$hint"
    if ([string]::IsNullOrWhiteSpace($line)) { return $Default }
    return $line.Trim()
}

if ([string]::IsNullOrWhiteSpace($DeployDomainFqdn)) {
    $DeployDomainFqdn = Read-Host 'Public FQDN (DNS A -> this host; ALTOSEC_DEPLOY_DOMAIN)'
}
if ([string]::IsNullOrWhiteSpace($RunnerName)) {
    $RunnerName = Read-Host 'Runner name (unique on GitHub)'
}
if ([string]::IsNullOrWhiteSpace($RegistrationToken)) {
    $RegistrationToken = Read-Host 'Registration token (GitHub -> New self-hosted runner)'
}

if ([string]::IsNullOrWhiteSpace($RepoUrl)) {
    $RepoUrl = Read-WithDefault -Prompt 'Runner repo URL' -Default 'https://github.com/alto-sec/Altosec-proxy-server'
}
if ([string]::IsNullOrWhiteSpace($RunnerRoot)) {
    $RunnerRoot = Read-WithDefault -Prompt 'Runner install folder' -Default 'C:\actions-runner'
}
if ([string]::IsNullOrWhiteSpace($DeployDir)) {
    $DeployDir = Read-WithDefault -Prompt 'Deploy extract folder (ALTOSEC_DEPLOY_DIR)' -Default 'C:\altosec-deploy'
}
if ([string]::IsNullOrWhiteSpace($AcmeContactEmail)) {
    $AcmeContactEmail = Read-WithDefault -Prompt "Let's Encrypt ACME contact email (saved to deploy folder only, not system env)" -Default 'altosecteam@gmail.com'
}

if ([string]::IsNullOrWhiteSpace($DeployDomainFqdn)) { throw 'FQDN is required.' }
if ([string]::IsNullOrWhiteSpace($RunnerName)) { throw 'Runner name is required.' }
if ([string]::IsNullOrWhiteSpace($RegistrationToken)) { throw 'Registration token is required.' }
$RunnerName = $RunnerName.Trim()
$AcmeContactEmail = $AcmeContactEmail.Trim()
if ([string]::IsNullOrWhiteSpace($AcmeContactEmail)) { throw 'ACME contact email is required.' }
if ($AcmeContactEmail -match '(?i)@example\.(com|org|net)$') {
    throw "Let's Encrypt rejects @example.com / .org / .net for ACME contacts. Use a real mailbox."
}

[Environment]::SetEnvironmentVariable('ALTOSEC_DEPLOY_DOMAIN', $DeployDomainFqdn.Trim(), 'Machine')
[Environment]::SetEnvironmentVariable('ALTOSEC_DEPLOY_DIR', $DeployDir.Trim(), 'Machine')
Write-Host "Set machine env: ALTOSEC_DEPLOY_DOMAIN=$($DeployDomainFqdn.Trim()) ALTOSEC_DEPLOY_DIR=$($DeployDir.Trim())"

if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    throw 'Docker CLI not found. Install and start Docker Desktop, then verify with: docker version'
}

$deployRoot = $DeployDir.Trim()
[void][System.IO.Directory]::CreateDirectory($deployRoot)
$acmePath = Join-Path $deployRoot 'acme-contact-email.txt'
[System.IO.File]::WriteAllText($acmePath, $AcmeContactEmail, [System.Text.UTF8Encoding]::new($false))
Write-Host "Saved ACME contact for Deploy workflow: $acmePath (not stored in system environment variables)."

try {
    Add-LocalGroupMember -Group 'docker-users' -Member 'NT AUTHORITY\SYSTEM'
} catch {
    if ($_.Exception.Message -notmatch 'already a member') { throw }
}

$fwName = 'AltosecProxyACME80'
if (-not (Get-NetFirewallRule -Name $fwName -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -Name $fwName -DisplayName 'Altosec proxy ACME HTTP-01 (TCP 80 inbound)' `
        -Direction Inbound -Protocol TCP -LocalPort 80 -Action Allow -Profile Any | Out-Null
    Write-Host "Created firewall rule $fwName (TCP 80)."
}

$fwName443 = 'AltosecProxyHTTPS443'
if (-not (Get-NetFirewallRule -Name $fwName443 -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -Name $fwName443 -DisplayName 'Altosec proxy HTTPS (TCP 443 inbound)' `
        -Direction Inbound -Protocol TCP -LocalPort 443 -Action Allow -Profile Any | Out-Null
    Write-Host "Created firewall rule $fwName443 (TCP 443)."
}

# Docker Desktop host-networking settings + .wslconfig (WSL2 mirrored mode).
# configure-docker-desktop.ps1 handles: exposeDockerAPIOnTCP2375, hostNetworkingEnabled,
# userland-proxy=false, networkingMode=mirrored in .wslconfig, and Docker Desktop restart.
Write-Host 'Applying Docker Desktop host-networking settings...'
if ($PSScriptRoot) {
    # Running as a saved .ps1 file — sibling script is on disk
    & (Join-Path $PSScriptRoot 'configure-docker-desktop.ps1')
    if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) { throw "configure-docker-desktop.ps1 failed (exit $LASTEXITCODE)" }
} else {
    # Running via iex (irm ...) — download sibling from the same public repo
    $configureUrl = 'https://raw.githubusercontent.com/alto-sec/Altosec-proxy-server-scripts/main/windows/configure-docker-desktop.ps1'
    iex (irm -UseBasicParsing $configureUrl)
}
Write-Host 'Waiting for Docker daemon (up to 360 s)...'
# Docker Desktop needs time to boot WSL2 + the Linux daemon after a settings change.
# The 500 error means the named pipe exists but the daemon is not yet ready — just keep waiting.
Start-Sleep -Seconds 20
$deadline = (Get-Date).AddSeconds(340)
$dockerReady = $false
while ((Get-Date) -lt $deadline) {
    $out = & docker info 2>&1
    if ($LASTEXITCODE -eq 0) { Write-Host 'Docker daemon ready.'; $dockerReady = $true; break }
    Start-Sleep -Seconds 5
}
if (-not $dockerReady) { throw 'Docker Desktop did not become ready within 360 s. Start it manually and re-run.' }

if (-not (Test-Path (Join-Path $RunnerRoot 'config.cmd'))) {
    New-Item -ItemType Directory -Force -Path $RunnerRoot | Out-Null
    $rel = Invoke-RestMethod -Uri 'https://api.github.com/repos/actions/runner/releases/latest' `
        -Headers @{ 'User-Agent' = 'Altosec-Windows-Bootstrap' }
    $asset = $rel.assets | Where-Object { $_.name -match '^actions-runner-win-x64-[\d.]+\.zip$' } | Select-Object -First 1
    if (-not $asset) { throw 'Could not find actions-runner-win-x64 zip in latest release.' }
    $zip = Join-Path $env:TEMP $asset.name
    Write-Host "Downloading $($asset.name) ..."
    Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $zip
    Expand-Archive -Path $zip -DestinationPath $RunnerRoot -Force
    Remove-Item $zip -Force
}

Push-Location $RunnerRoot
if (-not (Test-Path '.\.runner')) {
    $cfg = Join-Path $RunnerRoot 'config.cmd'
    $proc = Start-Process -FilePath $cfg -WorkingDirectory $RunnerRoot -ArgumentList @(
        '--url', $RepoUrl,
        '--token', $RegistrationToken,
        '--name', $RunnerName,
        '--labels', "self-hosted,Windows,altosec-proxy-node,$RunnerName",
        '--unattended',
        '--runasservice'
    ) -Wait -PassThru -NoNewWindow
    if ($proc.ExitCode -ne 0) { throw "config.cmd failed with exit $($proc.ExitCode)" }
    Write-Host 'Runner registered as service.'
} else {
    Write-Host 'Runner already configured (.runner exists). Skipping config.cmd.'
}
Pop-Location

Get-CimInstance Win32_Service -Filter "Name LIKE 'actions.runner%'" | ForEach-Object {
    & sc.exe config $_.Name obj= LocalSystem | Out-Null
    Write-Host "Set $($_.Name) logon to Local System."
}

Get-Service 'actions.runner*' | Restart-Service
Write-Host 'Done. Confirm the runner shows Idle in GitHub -> Settings -> Runners, then trigger the Deploy workflow.'
