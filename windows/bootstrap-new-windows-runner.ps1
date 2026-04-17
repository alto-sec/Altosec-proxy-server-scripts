#Requires -RunAsAdministrator
<#
.SYNOPSIS
  New Windows server: open firewall, then run prepare-wsl2.ps1 which installs
  WSL2 Ubuntu + Docker Engine + GitHub Actions runner (all inside WSL2).

.DESCRIPTION
  Single entry point for provisioning a new Windows proxy node.
  Docker Desktop is NOT required — Docker Engine runs inside WSL2 Ubuntu.
  The runner registered here is a Linux runner (inside WSL2) labeled:
    self-hosted, Linux, altosec-proxy-node, <RunnerName>

  TLS is handled by the upstream nginx reverse proxy.
  This server runs plain HTTP on port 80.

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

.PARAMETER WslDistro
  WSL2 distro to install/use. Default: Ubuntu-24.04
#>
[CmdletBinding()]
param(
    [string] $RunnerName        = '',
    [string] $RegistrationToken = '',
    [string] $RepoUrl           = '',
    [string] $RunnerRoot        = '/opt/actions-runner',
    [string] $DeployDir         = '/opt/altosec-deploy',
    [string] $WslDistro         = 'Ubuntu-24.04'
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

if ([string]::IsNullOrWhiteSpace($RunnerName)) {
    $RunnerName = Read-Host 'Runner name (unique on GitHub, e.g. proxy-node-01)'
}
if ([string]::IsNullOrWhiteSpace($RegistrationToken)) {
    $RegistrationToken = Read-Host 'Registration token (GitHub -> New self-hosted runner)'
}
if ([string]::IsNullOrWhiteSpace($RepoUrl)) {
    $RepoUrl = Read-WithDefault -Prompt 'Runner repo URL' -Default 'https://github.com/alto-sec/Altosec-proxy-server'
}

if ([string]::IsNullOrWhiteSpace($RunnerName))        { throw 'RunnerName is required.' }
if ([string]::IsNullOrWhiteSpace($RegistrationToken)) { throw 'RegistrationToken is required.' }

# ── Step 1: Windows Firewall rules ─────────────────────────────────────────────

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
    Write-Host "  [+] Created firewall rule '$Name' (TCP $Port inbound)."
}

Ensure-FirewallRule -Name 'AltosecProxyHTTP80' -DisplayName 'Altosec proxy HTTP from nginx (TCP 80 inbound)' -Port 80

# ── Step 2: Run prepare-wsl2.ps1 ──────────────────────────────────────────────

Write-Host '=== Calling prepare-wsl2.ps1 (WSL2 + Docker Engine + runner) ==='

$prepareScript = $null

if ($PSScriptRoot) {
    $candidate = Join-Path $PSScriptRoot 'prepare-wsl2.ps1'
    if (Test-Path $candidate) { $prepareScript = $candidate }
}

if (-not $prepareScript) {
    $rawUrl  = 'https://raw.githubusercontent.com/alto-sec/Altosec-proxy-server-scripts/main/windows/prepare-wsl2.ps1'
    $tmpPath = Join-Path $env:TEMP 'prepare-wsl2.ps1'
    Write-Host "Downloading prepare-wsl2.ps1 from $rawUrl ..."
    Invoke-WebRequest -Uri $rawUrl -OutFile $tmpPath -UseBasicParsing
    $prepareScript = $tmpPath
}

$splat = @{
    RunnerName        = $RunnerName
    RegistrationToken = $RegistrationToken
    RepoUrl           = $RepoUrl
    DeployDir         = $DeployDir
    RunnerRoot        = $RunnerRoot
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
Write-Host ''
Write-Host 'Next: confirm the runner shows Idle in GitHub -> Settings -> Actions -> Runners,'
Write-Host 'then trigger the Deploy workflow.'
