#Requires -RunAsAdministrator
<#
.SYNOPSIS
  New Windows server: set ALTOSEC_* system variables, then run prepare-wsl2.ps1 which
  installs WSL2 Ubuntu + Docker Engine + GitHub Actions runner (all inside WSL2).

.DESCRIPTION
  Single entry point for provisioning a new Windows proxy node.
  Docker Desktop is NOT required or used — Docker Engine runs inside WSL2 Ubuntu.
  The runner registered here is a Linux runner (inside WSL2) labeled:
    self-hosted, Linux, altosec-proxy-node, <RunnerName>

  Steps performed:
    1. Prompt for required values when parameters are omitted.
    2. Set ALTOSEC_DEPLOY_DOMAIN + ALTOSEC_DEPLOY_DIR as machine-scope env vars.
    3. Open Windows Firewall for TCP 80 (ACME HTTP-01) and TCP 443 (HTTPS).
    4. Call prepare-wsl2.ps1 which handles:
         - WSL2 feature enablement (if needed — may require reboot on first run)
         - Ubuntu 24.04 WSL2 distro install
         - .wslconfig networkingMode=mirrored (real client IPs in containers)
         - systemd enabled in WSL2
         - Docker Engine install inside WSL2
         - certbot install inside WSL2
         - GitHub Actions runner registration inside WSL2 as systemd service
         - Windows Task Scheduler task to auto-start WSL2 on boot

.PARAMETER DeployDomainFqdn
  Public FQDN. If empty, prompted interactively.

.PARAMETER RunnerName
  Unique runner name on GitHub. If empty, prompted interactively.

.PARAMETER RegistrationToken
  GitHub runner registration token. If empty, prompted interactively.

.PARAMETER RepoUrl
  Default: https://github.com/alto-sec/Altosec-proxy-server

.PARAMETER RunnerRoot
  Path inside WSL2 for the runner. Default: /opt/actions-runner

.PARAMETER DeployDir
  Path inside WSL2 for deploy artefacts. Default: /opt/altosec-deploy

.PARAMETER AcmeContactEmail
  Let's Encrypt ACME contact email. If empty, prompted interactively.
  Saved only to <deploy-dir>/acme-contact-email.txt — not a system env var.

.PARAMETER WslDistro
  WSL2 distro to install/use. Default: Ubuntu-24.04
#>
[CmdletBinding()]
param(
    [string] $DeployDomainFqdn   = '',
    [string] $RunnerName         = '',
    [string] $RegistrationToken  = '',
    [string] $RepoUrl            = '',
    [string] $RunnerRoot         = '/opt/actions-runner',
    [string] $DeployDir          = '/opt/altosec-deploy',
    [string] $AcmeContactEmail   = '',
    [string] $WslDistro          = 'Ubuntu-24.04'
)

$ErrorActionPreference = 'Stop'

function Read-WithDefault {
    param([string] $Prompt, [string] $Default)
    $hint = if ($null -ne $Default -and $Default -ne '') { " [$Default]" } else { '' }
    $line = Read-Host "$Prompt$hint"
    if ([string]::IsNullOrWhiteSpace($line)) { return $Default }
    return $line.Trim()
}

# ── Prompt for required values ─────────────────────────────────────────────────

if ([string]::IsNullOrWhiteSpace($DeployDomainFqdn)) {
    $DeployDomainFqdn = Read-Host 'Public FQDN (DNS A -> this host; ALTOSEC_DEPLOY_DOMAIN)'
}
if ([string]::IsNullOrWhiteSpace($RunnerName)) {
    $RunnerName = Read-Host 'Runner name (unique on GitHub, e.g. proxy-node-01)'
}
if ([string]::IsNullOrWhiteSpace($RegistrationToken)) {
    $RegistrationToken = Read-Host 'Registration token (GitHub -> New self-hosted runner)'
}
if ([string]::IsNullOrWhiteSpace($RepoUrl)) {
    $RepoUrl = Read-WithDefault -Prompt 'Runner repo URL' -Default 'https://github.com/alto-sec/Altosec-proxy-server'
}
if ([string]::IsNullOrWhiteSpace($AcmeContactEmail)) {
    $AcmeContactEmail = Read-WithDefault -Prompt "Let's Encrypt ACME contact email" -Default 'altosecteam@gmail.com'
}

if ([string]::IsNullOrWhiteSpace($DeployDomainFqdn)) { throw 'FQDN is required.' }
if ([string]::IsNullOrWhiteSpace($RunnerName))        { throw 'RunnerName is required.' }
if ([string]::IsNullOrWhiteSpace($RegistrationToken)) { throw 'RegistrationToken is required.' }
$AcmeContactEmail = $AcmeContactEmail.Trim()
if ([string]::IsNullOrWhiteSpace($AcmeContactEmail))  { throw 'ACME contact email is required.' }
if ($AcmeContactEmail -match '(?i)@example\.(com|org|net)$') {
    throw "Let's Encrypt rejects @example.com / .org / .net. Use a real mailbox."
}

# ── Step 1: Machine-scope environment variables ────────────────────────────────

[Environment]::SetEnvironmentVariable('ALTOSEC_DEPLOY_DOMAIN', $DeployDomainFqdn.Trim(), 'Machine')
[Environment]::SetEnvironmentVariable('ALTOSEC_DEPLOY_DIR',    $DeployDir.Trim(),         'Machine')
Write-Host "Machine env: ALTOSEC_DEPLOY_DOMAIN=$($DeployDomainFqdn.Trim())"
Write-Host "Machine env: ALTOSEC_DEPLOY_DIR=$($DeployDir.Trim())"

# ── Step 2: Windows Firewall rules ─────────────────────────────────────────────

function Ensure-FirewallRule {
    param([string] $Name, [string] $DisplayName, [int] $Port)
    $existing = Get-NetFirewallRule -Name $Name -ErrorAction SilentlyContinue
    if ($existing) {
        if ($existing.Enabled -ne $true) {
            Enable-NetFirewallRule -Name $Name
            Write-Host "  [+] Enabled firewall rule '$Name' (TCP $Port inbound)."
        } else {
            Write-Host "  [=] Firewall rule '$Name' (TCP $Port) already active."
        }
        return
    }
    New-NetFirewallRule `
        -Name $Name -DisplayName $DisplayName `
        -Direction Inbound -Protocol TCP -LocalPort $Port `
        -Action Allow -Profile Any | Out-Null
    Write-Host "  [+] Created firewall rule '$Name' (TCP $Port inbound, all profiles)."
}

Ensure-FirewallRule -Name 'AltosecProxyACME80'   -DisplayName 'Altosec proxy ACME HTTP-01 (TCP 80 inbound)'  -Port 80
Ensure-FirewallRule -Name 'AltosecProxyHTTPS443'  -DisplayName 'Altosec proxy HTTPS (TCP 443 inbound)'        -Port 443

# ── Step 3: Run prepare-wsl2.ps1 ──────────────────────────────────────────────

Write-Host '=== Calling prepare-wsl2.ps1 (WSL2 + Docker Engine + runner) ==='

$prepareScript = $null

if ($PSScriptRoot) {
    # Running from a repo clone or image-extracted deploy dir.
    $candidate = Join-Path $PSScriptRoot 'prepare-wsl2.ps1'
    if (Test-Path $candidate) { $prepareScript = $candidate }
}

if (-not $prepareScript) {
    # Running via iex (irm ...) — download sibling from the public scripts repo.
    $rawUrl = 'https://raw.githubusercontent.com/alto-sec/Altosec-proxy-server-scripts/main/windows/prepare-wsl2.ps1'
    $tmpPath = Join-Path $env:TEMP 'prepare-wsl2.ps1'
    Write-Host "Downloading prepare-wsl2.ps1 from $rawUrl ..."
    Invoke-WebRequest -Uri $rawUrl -OutFile $tmpPath -UseBasicParsing
    $prepareScript = $tmpPath
}

$splat = @{
    DeployDomainFqdn  = $DeployDomainFqdn.Trim()
    RunnerName        = $RunnerName
    RegistrationToken = $RegistrationToken
    RepoUrl           = $RepoUrl
    DeployDir         = $DeployDir
    RunnerRoot        = $RunnerRoot
    AcmeEmail         = $AcmeContactEmail
    WslDistro         = $WslDistro
}

Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
& $prepareScript @splat
if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) {
    throw "prepare-wsl2.ps1 exited with code $LASTEXITCODE"
}

# ── Done ──────────────────────────────────────────────────────────────────────

Write-Host ''
Write-Host '=== bootstrap-new-windows-runner.ps1 complete ==='
Write-Host ''
Write-Host 'Sanity checks:'
Write-Host '  wsl -d Ubuntu-24.04 -- docker info'
Write-Host '  wsl -d Ubuntu-24.04 -- systemctl status actions.runner.*'
Write-Host '  [Environment]::GetEnvironmentVariable(''ALTOSEC_DEPLOY_DOMAIN'', ''Machine'')'
Write-Host ''
Write-Host 'Next: confirm the runner shows Idle in GitHub -> Settings -> Actions -> Runners,'
Write-Host 'then trigger the Deploy workflow (handles docker pull, TLS cert, and compose up).'
