#Requires -RunAsAdministrator
<#
.SYNOPSIS
  Altosec Email Scheduler 전용: Windows 러너 설치·등록.

.DESCRIPTION
  대상 앱 레포: https://github.com/alto-sec/Altosec-email-scheduler
  공개 raw(프록시와 동일 저장소, 하위 폴더만 분리):
    alto-sec/Altosec-proxy-server-scripts/windows/altosec-email-scheduler/bootstrap-email-scheduler-runner.ps1
  프록시 부트스트랩은 같은 레포의 windows/bootstrap-new-windows-runner.ps1 — 경로가 다르므로 섞이지 않음.

  비공개 GHCR 정책: 컨테이너 기동은 이 레포의 GitHub Deploy 워크플로를 실행한다.
  파라미터 없이 실행(예: iex(irm raw URL))하면 필수 값은 Read-Host 로 묻는다.

  프록시(Altosec-proxy-server) 러너와 같은 PC에 두면:
  - Runner 폴더는 반드시 다름 (기본 C:\actions-runner-email-scheduler). C:\actions-runner 에 프록시 .runner 가 있어도 이 스크립트는 다른 경로를 쓴다.
  - Deploy 폴더 기본 C:\altosec-deploy-email (프록시 C:\altosec-deploy 와 분리).

  HTTP-only (메인 서버가 http://IP:포트 로만 호출): -HttpOnly 또는 ALTOSEC_BOOTSTRAP_HTTP_ONLY=1

.PARAMETER HttpOnly
  도메인·Let's Encrypt 없이 배포 (IP/HTTP 전용).

.PARAMETER DeployDomainFqdn
  공개 FQDN (TLS 배포 시). HttpOnly 이면 무시.

.PARAMETER RunnerName
  러너 고유 이름.

.PARAMETER RegistrationToken
  GitHub 등록 토큰 (이 레포 Settings → Actions → Runners → New).

.PARAMETER RepoUrl
  기본 https://github.com/alto-sec/Altosec-email-scheduler

.PARAMETER RunnerRoot
  기본 C:\actions-runner-email-scheduler

.PARAMETER DeployDir
  기본 C:\altosec-deploy-email

.PARAMETER AcmeContactEmail
  TLS 시 Let's Encrypt 연락처. 배포 폴더의 acme-contact-email.txt 로만 저장.
#>
[CmdletBinding()]
param(
    [string] $DeployDomainFqdn = '',
    [string] $RunnerName = '',
    [string] $RegistrationToken = '',
    [string] $RepoUrl = '',
    [string] $RunnerRoot = '',
    [string] $DeployDir = '',
    [string] $AcmeContactEmail = '',
    [switch] $HttpOnly
)

$ErrorActionPreference = 'Stop'

if ($env:ALTOSEC_BOOTSTRAP_HTTP_ONLY -match '^(1|true|yes|on)$') {
    $HttpOnly = $true
}

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

if (-not $HttpOnly -and [string]::IsNullOrWhiteSpace($DeployDomainFqdn)) {
    $DeployDomainFqdn = Read-Host 'Public FQDN (DNS A -> this host; ALTOSEC_DEPLOY_DOMAIN)'
}
if ([string]::IsNullOrWhiteSpace($RunnerName)) {
    $RunnerName = Read-Host 'Runner name (unique on GitHub)'
}
if ([string]::IsNullOrWhiteSpace($RegistrationToken)) {
    $RegistrationToken = Read-Host 'Registration token (GitHub -> New self-hosted runner)'
}

if ([string]::IsNullOrWhiteSpace($RepoUrl)) {
    $RepoUrl = Read-WithDefault -Prompt 'Runner repo URL' -Default 'https://github.com/alto-sec/Altosec-email-scheduler'
}
if ([string]::IsNullOrWhiteSpace($RunnerRoot)) {
    $RunnerRoot = Read-WithDefault -Prompt 'Runner install folder' -Default 'C:\actions-runner-email-scheduler'
}
if ([string]::IsNullOrWhiteSpace($DeployDir)) {
    $DeployDir = Read-WithDefault -Prompt 'Deploy extract folder (ALTOSEC_DEPLOY_DIR)' -Default 'C:\altosec-deploy-email'
}
if (-not $HttpOnly -and [string]::IsNullOrWhiteSpace($AcmeContactEmail)) {
    $AcmeContactEmail = Read-WithDefault -Prompt "Let's Encrypt ACME contact email (saved to deploy folder only, not system env)" -Default 'altosecteam@gmail.com'
}

if (-not $HttpOnly) {
    if ([string]::IsNullOrWhiteSpace($DeployDomainFqdn)) { throw 'FQDN is required (or use -HttpOnly for IP/HTTP-only deploy).' }
    $AcmeContactEmail = $AcmeContactEmail.Trim()
    if ([string]::IsNullOrWhiteSpace($AcmeContactEmail)) { throw 'ACME contact email is required for TLS deploy.' }
    if ($AcmeContactEmail -match '(?i)@example\.(com|org|net)$') {
        throw "Let's Encrypt rejects @example.com / .org / .net for ACME contacts. Use a real mailbox."
    }
}
if ([string]::IsNullOrWhiteSpace($RunnerName)) { throw 'Runner name is required.' }
if ([string]::IsNullOrWhiteSpace($RegistrationToken)) { throw 'Registration token is required.' }
$RunnerName = $RunnerName.Trim()

if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    throw 'Docker CLI 가 없습니다. Docker Desktop 설치·기동 후 docker version 으로 확인하세요.'
}

[Environment]::SetEnvironmentVariable('ALTOSEC_DEPLOY_DIR', $DeployDir.Trim(), 'Machine')
if ($HttpOnly) {
    [Environment]::SetEnvironmentVariable('ALTOSEC_DEPLOY_HTTP_ONLY', 'true', 'Machine')
    [Environment]::SetEnvironmentVariable('ALTOSEC_DEPLOY_DOMAIN', '', 'Machine')
    Write-Host "Machine env: ALTOSEC_DEPLOY_HTTP_ONLY=true ALTOSEC_DEPLOY_DIR=$($DeployDir.Trim()) (no TLS / no FQDN)"
} else {
    [Environment]::SetEnvironmentVariable('ALTOSEC_DEPLOY_HTTP_ONLY', '', 'Machine')
    [Environment]::SetEnvironmentVariable('ALTOSEC_DEPLOY_DOMAIN', $DeployDomainFqdn.Trim(), 'Machine')
    Write-Host "Machine env: ALTOSEC_DEPLOY_DOMAIN=$($DeployDomainFqdn.Trim()) ALTOSEC_DEPLOY_DIR=$($DeployDir.Trim())"
}

$deployRoot = $DeployDir.Trim()
[void][System.IO.Directory]::CreateDirectory($deployRoot)
if (-not $HttpOnly) {
    $acmePath = Join-Path $deployRoot 'acme-contact-email.txt'
    [System.IO.File]::WriteAllText($acmePath, $AcmeContactEmail, [System.Text.UTF8Encoding]::new($false))
    Write-Host "Wrote ACME contact for Deploy workflow: $acmePath (not stored in system environment variables)."
}

try {
    Add-LocalGroupMember -Group 'docker-users' -Member 'NT AUTHORITY\SYSTEM'
} catch {
    if ($_.Exception.Message -notmatch 'already a member') { throw }
}

$fwName = 'AltosecEmailSchedulerACME80'
if (-not (Get-NetFirewallRule -Name $fwName -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -Name $fwName -DisplayName 'Altosec Email Scheduler ACME HTTP-01 (TCP 80 inbound)' `
        -Direction Inbound -Protocol TCP -LocalPort 80 -Action Allow -Profile Any | Out-Null
    Write-Host "Created firewall rule $fwName (TCP 80)."
}

if (-not (Test-Path (Join-Path $RunnerRoot 'config.cmd'))) {
    New-Item -ItemType Directory -Force -Path $RunnerRoot | Out-Null
    $rel = Invoke-RestMethod -Uri 'https://api.github.com/repos/actions/runner/releases/latest' `
        -Headers @{ 'User-Agent' = 'Altosec-EmailScheduler-RunnerBootstrap' }
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
        '--labels', 'self-hosted,Windows,altosec-proxy-node',
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
Write-Host 'Done. GitHub → Altosec-email-scheduler → Runners 에서 Idle 인지 확인한 뒤 Deploy 워크플로를 실행하세요.'
