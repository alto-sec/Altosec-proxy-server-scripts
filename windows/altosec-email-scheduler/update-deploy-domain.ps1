#Requires -RunAsAdministrator
<#
.SYNOPSIS
  운영 중 배포 FQDN 변경: ALTOSEC_DEPLOY_DOMAIN 시스템 변수 + GitHub Actions Runner 서비스 재시작.

.DESCRIPTION
  TLS + 공개 FQDN 배포 전용(ALTOSEC_DEPLOY_DOMAIN). 메인 서버가 http://IP 만 쓰는 HTTP-only 배포에는 필요 없음.
  비공개 GHCR 정책: TLS·pull·compose 는 GitHub Actions Deploy 로 수행.
  파라미터 없이 실행(예: iex(irm raw URL))하면 Read-Host 로 새 FQDN 을 묻는다.

.PARAMETER NewFqdn
  새 공개 FQDN. 비우면 대화형 입력.
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

다음 단계 (필수): GitHub → Actions → Deploy (self-hosted Windows) → workflow_dispatch
  • 비공개 GHCR: 이 잡만 docker login + pull + start-with-tls.ps1 + compose 를 수행합니다.

'@
