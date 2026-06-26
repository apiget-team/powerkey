#!/usr/bin/env pwsh
#
# powerkey — 一键装好 Claude Code 并接上 apiget.cc（Windows / PowerShell）
# https://github.com/apiget-team/powerkey
#
#   irm https://get.apiget.cc/install.ps1 | iex
#   # 带参数：
#   & ([scriptblock]::Create((irm https://get.apiget.cc/install.ps1))) -Key sk-xxx
#
# 与 install.sh 同源同行为：装/升级 Claude Code → 领 $2 体验额度（或 -Key）→ 写
# %USERPROFILE%\.claude\settings.json 的 env 块（合并不覆盖）→ 处理冲突 env → 就绪。
#
# Derived from QuantumNous/new-api-docs `helper/claude-cli-setup.ps1` (MIT). See NOTICE.
# ⚠ Windows v1.1：逻辑对齐 install.sh，CI 做语法 parse；首次真机请做 Windows 冒烟。

[CmdletBinding()]
param(
  [switch]$DryRun,
  [switch]$Uninstall,
  [switch]$NoLaunch,
  [switch]$Force,
  [string]$Key     = $env:POWERKEY_KEY,
  [string]$BaseUrl = $env:POWERKEY_BASE_URL,
  [string]$Issuer  = $(if ($env:POWERKEY_ISSUER) { $env:POWERKEY_ISSUER } else { 'https://get.apiget.cc' }),
  [string]$Model   = $env:POWERKEY_MODEL,
  [string]$Ref     = $env:POWERKEY_REF,
  [string]$Source  = $(if ($env:POWERKEY_SOURCE) { $env:POWERKEY_SOURCE } else { 'powerkey' })
)

$ErrorActionPreference = 'Stop'

# -------- 常量 --------
$PowerkeyVersion = '0.1.0'
$DefaultBaseUrl  = 'https://api.apiget.cc'
$DefaultModel    = 'deepseek-v4-pro'
$RegisterUrl     = 'https://apiget.cc/register?ref=powerkey'
$ClaudeInstall   = 'https://claude.ai/install.ps1'
$StateDir        = Join-Path $HOME '.powerkey'
$StateFile       = Join-Path $StateDir 'state.json'
$BackupDir       = Join-Path $StateDir 'backups'
$ClaudeDir       = Join-Path $HOME '.claude'
$SettingsFile    = Join-Path $ClaudeDir 'settings.json'
$LocalBin        = Join-Path $HOME '.local\bin'

# -------- 日志 --------
function Info($m) { Write-Host "▸ $m" -ForegroundColor Cyan }
function Ok($m)   { Write-Host "✓ $m" -ForegroundColor Green }
function Warn($m) { Write-Host "! $m" -ForegroundColor Yellow }
function Die($m)  { Write-Host "✗ $m" -ForegroundColor Red; exit 1 }

if (-not $Channel) { $Channel = $Ref }   # -Ref 是 channel 别名

# -------- 工具 --------
function Test-Cmd($n) { [bool](Get-Command $n -ErrorAction SilentlyContinue) }

function Get-Fingerprint {
  $raw = ''
  try { $raw = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Cryptography' -Name MachineGuid -ErrorAction Stop).MachineGuid } catch {}
  if (-not $raw) { try { $raw = (Get-CimInstance Win32_ComputerSystemProduct -ErrorAction Stop).UUID } catch {} }
  if (-not $raw) { $raw = "$env:COMPUTERNAME-$env:USERNAME" }
  $bytes = [Text.Encoding]::UTF8.GetBytes("powerkey:${raw}:$env:USERNAME")
  $sha = [Security.Cryptography.SHA256]::Create().ComputeHash($bytes)
  ($sha | ForEach-Object { $_.ToString('x2') }) -join ''
}

function Get-ClaudeExe {
  $c = Get-Command claude -ErrorAction SilentlyContinue
  if ($c) { return $c.Source }
  $p = Join-Path $LocalBin 'claude.exe'
  if (Test-Path $p) { return $p }
  return $null
}

# -------- 步骤 --------
function Show-Banner {
  Write-Host ''
  Write-Host 'powerkey  —  一键装 Claude Code · 接 apiget.cc' -ForegroundColor Cyan
  Write-Host "v$PowerkeyVersion$(if ($DryRun) { ' (dry-run)' })" -ForegroundColor DarkGray
  Write-Host ''
}

function Test-ConflictingEnv {
  $vars = 'ANTHROPIC_BASE_URL','ANTHROPIC_API_KEY','ANTHROPIC_AUTH_TOKEN','ANTHROPIC_MODEL','ANTHROPIC_DEFAULT_HAIKU_MODEL'
  $hit = @()
  foreach ($v in $vars) {
    if ([Environment]::GetEnvironmentVariable($v, 'User') -or [Environment]::GetEnvironmentVariable($v, 'Process')) { $hit += $v }
  }
  if ($hit.Count -eq 0) { return }
  Warn "检测到已有 ANTHROPIC_* 环境变量（优先级高于 settings.json，会让配置不生效）：$($hit -join ', ')"
  if (-not $DryRun) {
    foreach ($v in $hit) {
      [Environment]::SetEnvironmentVariable($v, $null, 'User')
      Remove-Item "Env:$v" -ErrorAction SilentlyContinue
    }
    Ok '已清除冲突的 User/Process 级 ANTHROPIC_* 变量。'
  }
}

function Install-ClaudeCode {
  $exe = Get-ClaudeExe
  if ($exe) {
    Info "已装 Claude Code（$(& $exe --version 2>$null)），尝试升级…"
    if ($DryRun) { Ok '[dry-run] 跳过升级'; return }
    try { & $exe update 2>$null } catch { try { irm $ClaudeInstall | iex } catch { Warn '升级未成功，沿用现有版本。' } }
    Ok 'Claude Code 就绪。'; return
  }
  Info '未检测到 Claude Code，安装最新版…'
  if ($DryRun) { Ok "[dry-run] 将执行：irm $ClaudeInstall | iex"; return }
  try { irm $ClaudeInstall | iex }
  catch {
    if (Test-Cmd npm) { Warn '原生安装失败，改用 npm…'; npm install -g '@anthropic-ai/claude-code@latest' }
    else { Die 'Claude Code 安装失败且无 npm。请装 Node 后重试，或见 https://code.claude.com/docs/en/setup' }
  }
  Ok 'Claude Code 安装完成。'
}

function Get-IssuedToken {
  if ($Key) { Ok '使用你提供的 key。'; return @{ token = $Key; base = $(if ($BaseUrl) { $BaseUrl } else { $DefaultBaseUrl }); model = $(if ($Model) { $Model } else { $DefaultModel }); quota = 2 } }

  if (-not $Force -and (Test-Path $StateFile)) {
    try {
      $st = Get-Content $StateFile -Raw | ConvertFrom-Json
      if ($st.token) { Ok '复用本机已领的体验额度（-Force 可重领）。'; return @{ token = $st.token; base = $st.base_url; model = $st.model; quota = 2 } }
    } catch {}
  }

  if ($DryRun) { Ok "[dry-run] 将向 $Issuer/issue 领 `$2 体验额度（此处用假 token）。"; return @{ token = 'sk-DRYRUN-xxxx'; base = $DefaultBaseUrl; model = $DefaultModel; quota = 2 } }

  Info '向 apiget 领取 $2 体验额度…'
  $payload = @{ fingerprint = (Get-Fingerprint); os = 'windows'; arch = $env:PROCESSOR_ARCHITECTURE; source = $Source; channel = $Channel; client_version = $PowerkeyVersion } | ConvertTo-Json
  try { $resp = Invoke-RestMethod -Uri "$($Issuer.TrimEnd('/'))/issue" -Method Post -Body $payload -ContentType 'application/json' -TimeoutSec 30 }
  catch { Warn "发码服务暂不可达。网页自助领取：$RegisterUrl"; exit 2 }
  if (-not $resp.ok) {
    if ($resp.message) { Warn $resp.message }
    $fb = if ($resp.fallback_url) { $resp.fallback_url } else { $RegisterUrl }
    Write-Host "自助领取：$fb"; exit 2
  }
  if (-not $resp.token) { Warn "服务未返回 token。自助领取：$RegisterUrl"; exit 2 }
  $base = if ($BaseUrl) { $BaseUrl } elseif ($resp.base_url) { $resp.base_url } else { $DefaultBaseUrl }
  $mdl  = if ($Model)   { $Model }   elseif ($resp.model)    { $resp.model }    else { $DefaultModel }
  New-Item -ItemType Directory -Force -Path $StateDir | Out-Null
  @{ token = $resp.token; base_url = $base; model = $mdl } | ConvertTo-Json | Set-Content -Path $StateFile -Encoding UTF8
  Ok '已领到 $2 体验额度。'
  return @{ token = $resp.token; base = $base; model = $mdl; quota = 2 }
}

# 递归把 PSCustomObject 转成 hashtable（PS 5.1 安全）
function ConvertTo-HashtableDeep($o) {
  if ($null -eq $o) { return @{} }
  if ($o -is [hashtable]) { return $o }
  $h = @{}
  foreach ($p in $o.PSObject.Properties) {
    if ($p.Value -is [PSCustomObject]) { $h[$p.Name] = ConvertTo-HashtableDeep $p.Value }
    else { $h[$p.Name] = $p.Value }
  }
  return $h
}

function Set-Settings($base, $token, $model) {
  if ($DryRun) {
    Info "[dry-run] 将写入 $SettingsFile 的 env："
    Write-Host "    ANTHROPIC_BASE_URL=$base"
    Write-Host "    ANTHROPIC_AUTH_TOKEN=$($token.Substring(0,[Math]::Min(6,$token.Length)))****"
    Write-Host "    ANTHROPIC_MODEL=$model ; ANTHROPIC_DEFAULT_HAIKU_MODEL=$model"
    return
  }
  New-Item -ItemType Directory -Force -Path $ClaudeDir | Out-Null
  $obj = @{}
  if (Test-Path $SettingsFile) {
    New-Item -ItemType Directory -Force -Path $BackupDir | Out-Null
    Copy-Item $SettingsFile (Join-Path $BackupDir ("settings.json.bak." + (Get-Date -Format yyyyMMddHHmmss))) -ErrorAction SilentlyContinue
    try { $obj = ConvertTo-HashtableDeep (Get-Content $SettingsFile -Raw | ConvertFrom-Json) } catch { $obj = @{} }
  }
  if (-not ($obj.env -is [hashtable])) { $obj.env = @{} }
  $obj.env.ANTHROPIC_BASE_URL                        = $base
  $obj.env.ANTHROPIC_AUTH_TOKEN                       = $token
  $obj.env.ANTHROPIC_MODEL                            = $model
  $obj.env.ANTHROPIC_DEFAULT_HAIKU_MODEL             = $model
  $obj.env.CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY = '1'
  $obj.env.DISABLE_TELEMETRY                          = '1'
  ($obj | ConvertTo-Json -Depth 20) | Set-Content -Path $SettingsFile -Encoding UTF8
  Ok "已写入 $SettingsFile（合并保留你的其它设置）。"
}

function Show-Ready($base, $model, $quota) {
  Write-Host ''
  Ok '就绪！'
  Write-Host "  额度：`$$quota 体验额度    默认模型：$model    中转：$base"
  Write-Host ''
  Write-Host "  想试更强的模型？对话里输入 /model 可切 Claude / Gemini 等（已开网关模型发现）。" -ForegroundColor DarkGray
  Write-Host "  想长期用 / 要更多额度？注册：$RegisterUrl" -ForegroundColor DarkGray
  Write-Host ''
}

function Invoke-Uninstall {
  Info '撤销 powerkey 的配置改动…'
  $restored = $false
  if (Test-Path $BackupDir) {
    $latest = Get-ChildItem (Join-Path $BackupDir 'settings.json.bak.*') -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($latest) { Copy-Item $latest.FullName $SettingsFile -Force; Ok "已还原 settings.json（来自 $($latest.Name)）。"; $restored = $true }
  }
  if (-not $restored -and (Test-Path $SettingsFile)) {
    try {
      $obj = ConvertTo-HashtableDeep (Get-Content $SettingsFile -Raw | ConvertFrom-Json)
      if ($obj.env -is [hashtable]) {
        foreach ($k in 'ANTHROPIC_BASE_URL','ANTHROPIC_AUTH_TOKEN','ANTHROPIC_MODEL','ANTHROPIC_DEFAULT_HAIKU_MODEL','CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY','DISABLE_TELEMETRY') { $obj.env.Remove($k) }
      }
      ($obj | ConvertTo-Json -Depth 20) | Set-Content -Path $SettingsFile -Encoding UTF8
      Ok '已移除 powerkey 写入的 env 键。'
    } catch {}
  }
  Remove-Item $StateFile -ErrorAction SilentlyContinue
  Ok '完成。（未卸载 Claude Code 本身。）'
}

# -------- main --------
Show-Banner
if ($Uninstall) { Invoke-Uninstall; exit 0 }
Test-ConflictingEnv
Install-ClaudeCode
$t = Get-IssuedToken
Set-Settings $t.base $t.token $t.model
Show-Ready $t.base $t.model $t.quota

if (-not $DryRun -and -not $NoLaunch) {
  $exe = Get-ClaudeExe
  if ($exe) { Info '启动 claude …'; & $exe } else { Write-Host '运行 claude 开始体验。' }
} else {
  Write-Host '运行 claude 开始体验。'
}
