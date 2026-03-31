#Requires -RunAsAdministrator
<#
.SYNOPSIS
  Update the deployment FQDN on a running server: set ALTOSEC_DEPLOY_DOMAIN system variable and restart the GitHub Actions Runner service.

.DESCRIPTION
  Private GHCR policy: TLS, pull, and compose operations are handled exclusively by the GitHub Actions Deploy workflow_dispatch.
  When run without parameters (e.g. via iex(irm raw URL)), the new FQDN is prompted interactively via Read-Host.

.PARAMETER NewFqdn
  New public FQDN. If empty, prompted interactively.
#>
[CmdletBinding()]
param(
    [string] $NewFqdn = ''
)

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($NewFqdn)) {
    $NewFqdn = Read-Host 'New public FQDN (DNS A -> this server)'
}

$v = $NewFqdn.Trim().ToLowerInvariant()
if ([string]::IsNullOrWhiteSpace($v)) { throw 'FQDN is required.' }

[Environment]::SetEnvironmentVariable('ALTOSEC_DEPLOY_DOMAIN', $v, 'Machine')
Write-Host "Machine ALTOSEC_DEPLOY_DOMAIN=$v"

Get-Service 'actions.runner*' | Restart-Service
Write-Host 'Runner service restarted.'

Write-Host @'

Next step (required): GitHub -> Actions -> Deploy (self-hosted Windows) -> workflow_dispatch
  * Private GHCR: this job is the only path for docker login + pull + start-with-tls.ps1 + compose up.

'@
