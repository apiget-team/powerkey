#!/usr/bin/env pwsh
#
# powerkey — 一键装好 Claude Code 并接上 apiget.cc（Windows / PowerShell）
# https://github.com/apiget-team/powerkey
#
#   irm https://get.apiget.cc/install.ps1 | iex
#   # 带参数（含国内镜像 -Cn）：
#   & ([scriptblock]::Create((irm https://get.apiget.cc/install.ps1))) -Cn
#
# 与 install.sh 同源同行为：装/升级 Claude Code（官方源失败自动回退国内镜像 npmmirror）→
# 领 $2 体验额度（或 -Key）→ 写 %USERPROFILE%\.claude\settings.json 的 env 块（合并不覆盖、
# 清冲突 env、关非必要外联）→ 就绪。
#
# Derived from QuantumNous/new-api-docs `helper/claude-cli-setup.ps1` (MIT). See NOTICE.
# ⚠ Windows v1.1：逻辑对齐 install.sh，CI 做语法 parse + npmmirror 真装冒烟；其余以真机为准。

[CmdletBinding()]
param(
  [switch]$DryRun,
  [switch]$Uninstall,
  [switch]$NoLaunch,
  [switch]$Force,
  [switch]$Cn      = ($env:POWERKEY_CN -eq '1'),
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
$NpmCnRegistry   = 'https://registry.npmmirror.com'
$NodeCnMirror    = 'https://registry.npmmirror.com/-/binary/node'
$NodeVer         = 'v22.11.0'
$StateDir        = Join-Path $HOME '.powerkey'
$StateFile       = Join-Path $StateDir 'state.json'
$BackupDir       = Join-Path $StateDir 'backups'
$NodeDir         = Join-Path $StateDir 'node'
$ClaudeDir       = Join-Path $HOME '.claude'
$SettingsFile    = Join-Path $ClaudeDir 'settings.json'
$LocalBin        = Join-Path $HOME '.local\bin'
$CcSwitchDir     = Join-Path $HOME '.cc-switch'
$CcSwitchDb      = Join-Path $CcSwitchDir 'cc-switch.db'
$CcSwitchSettings = Join-Path $CcSwitchDir 'settings.json'

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
  foreach ($p in @((Join-Path $LocalBin 'claude.exe'), (Join-Path $LocalBin 'claude.cmd'))) {
    if (Test-Path $p) { return $p }
  }
  return $null
}

# -------- 步骤 --------
function Show-Banner {
  Write-Host ''
  Write-Host 'powerkey  —  一键装 Claude Code · 接 apiget.cc' -ForegroundColor Cyan
  Write-Host "v$PowerkeyVersion$(if ($DryRun) { ' (dry-run)' })$(if ($Cn) { ' (cn)' })" -ForegroundColor DarkGray
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

# 没有 Node 时从国内镜像装（解压到 ~/.powerkey/node，加入本次+User PATH）
function Install-NodeCn {
  if (Test-Cmd npm) { return }
  $arch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'x64' }
  $name = "node-$NodeVer-win-$arch"
  $url  = "$NodeCnMirror/$NodeVer/$name.zip"
  Info "未检测到 Node，正从国内镜像装 Node ${NodeVer}…"
  New-Item -ItemType Directory -Force -Path $NodeDir | Out-Null
  $zip = Join-Path $NodeDir "$name.zip"
  Invoke-WebRequest -Uri $url -OutFile $zip -TimeoutSec 180
  Expand-Archive -Path $zip -DestinationPath $NodeDir -Force
  Remove-Item $zip -ErrorAction SilentlyContinue
  $bin = Join-Path $NodeDir $name
  $env:PATH = "$bin;$env:PATH"
  $userPath = [Environment]::GetEnvironmentVariable('PATH', 'User')
  if ($userPath -notlike "*$bin*") { [Environment]::SetEnvironmentVariable('PATH', "$bin;$userPath", 'User') }
  if (-not (Test-Cmd npm)) { Die 'Node 装好但 npm 不可用。' }
  Ok "Node ${NodeVer} 已装到 ${NodeDir}。"
}

# 经国内镜像装 Claude Code（不连 github/claude.ai）
function Install-ClaudeCn {
  Install-NodeCn
  Info '经国内镜像（npmmirror）安装 Claude Code…'
  npm install -g '@anthropic-ai/claude-code@latest' --registry $NpmCnRegistry
  if ($LASTEXITCODE -ne 0) { Die '国内镜像安装 Claude Code 失败。' }
}

function Install-ClaudeCode {
  $exe = Get-ClaudeExe
  if ($exe) {
    Info "已装 Claude Code（$(& $exe --version 2>$null)），尝试升级…"
    if ($DryRun) { Ok '[dry-run] 跳过升级'; return }
    if ($Cn) { try { Install-ClaudeCn } catch { Warn '升级未成功，沿用现有版本。' } }
    else { try { & $exe update 2>$null } catch { Warn '升级未成功，沿用现有版本。' } }
    Ok 'Claude Code 就绪。'; return
  }
  Info '未检测到 Claude Code，安装最新版…'
  if ($DryRun) { Ok "[dry-run] 将安装 Claude Code（Cn=${Cn}：true=国内镜像 npmmirror；false=官方源失败再回退国内镜像）"; return }
  if ($Cn) {
    Install-ClaudeCn
  } else {
    try { irm $ClaudeInstall | iex; if (-not (Get-ClaudeExe)) { throw '官方源未生成 claude' } }
    catch { Warn "官方源安装失败（可能国内网络），改用国内镜像 npmmirror…"; Install-ClaudeCn }
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
    Write-Host "    CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY=1 ; DISABLE_TELEMETRY=1 ; DISABLE_ERROR_REPORTING=1 ; CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1"
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
  $obj.env.ANTHROPIC_BASE_URL                         = $base
  $obj.env.ANTHROPIC_AUTH_TOKEN                        = $token
  $obj.env.ANTHROPIC_MODEL                             = $model
  $obj.env.ANTHROPIC_DEFAULT_HAIKU_MODEL              = $model
  $obj.env.CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY  = '1'
  $obj.env.DISABLE_TELEMETRY                           = '1'
  $obj.env.DISABLE_ERROR_REPORTING                     = '1'
  $obj.env.CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC    = '1'
  ($obj | ConvertTo-Json -Depth 20) | Set-Content -Path $SettingsFile -Encoding UTF8
  Ok "已写入 ${SettingsFile}（合并保留你的其它设置）。"
}

# 若已装 cc-switch：把 apiget 写进它（provider + 设为当前）。需 python（含内置 sqlite3）；无则回退提示。
function Set-CcSwitch($base, $token, $model) {
  if (-not ((Test-Path $CcSwitchDb) -or (Test-Path $CcSwitchDir))) { return }
  Info '检测到 cc-switch。'
  if ($DryRun) { Info '[dry-run] 将把 apiget 写进 cc-switch（provider + 设为当前）。'; return }
  if (-not (Test-Path $CcSwitchDb)) { Warn 'cc-switch 已装但未见数据库（首次启动后才生成）；settings.json 已直写，启动后可手动加 apiget。'; return }
  $py = Get-Command python3 -ErrorAction SilentlyContinue; if (-not $py) { $py = Get-Command python -ErrorAction SilentlyContinue }
  if (-not $py) { Warn 'cc-switch 已装但无 python；跳过写其 DB，settings.json 已直写，可在 cc-switch 界面手动加 apiget。'; return }
  Copy-Item $CcSwitchDb "$CcSwitchDb.powerkey-bak.$(Get-Date -Format yyyyMMddHHmmss)" -ErrorAction SilentlyContinue
  $env:PK_DB = $CcSwitchDb; $env:PK_SET = $CcSwitchSettings; $env:PK_B = $base; $env:PK_T = $token; $env:PK_M = $model
  $script = @'
import sqlite3, json, os, time
db = os.environ["PK_DB"]; setp = os.environ["PK_SET"]
env = {"ANTHROPIC_BASE_URL": os.environ["PK_B"], "ANTHROPIC_AUTH_TOKEN": os.environ["PK_T"],
       "ANTHROPIC_MODEL": os.environ["PK_M"], "ANTHROPIC_DEFAULT_HAIKU_MODEL": os.environ["PK_M"],
       "CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY": "1", "DISABLE_TELEMETRY": "1",
       "DISABLE_ERROR_REPORTING": "1", "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1"}
sc = json.dumps({"env": env}, ensure_ascii=False)
con = sqlite3.connect(db, timeout=5); cur = con.cursor()
cur.execute("SELECT name FROM sqlite_master WHERE type='table' AND name='providers'")
if not cur.fetchone(): raise SystemExit(3)
ts = int(time.time() * 1000)
cur.execute("INSERT OR REPLACE INTO providers (id,app_type,name,settings_config,category,created_at,sort_index,meta,is_current) VALUES ('apiget','claude','API GET',?,?,?,?,?,1)", (sc, 'custom', ts, 0, '{}'))
cur.execute("UPDATE providers SET is_current=0 WHERE app_type='claude' AND id!='apiget'")
con.commit(); con.close()
s = {}
if os.path.exists(setp):
    try: s = json.load(open(setp)) or {}
    except Exception: s = {}
if not isinstance(s, dict): s = {}
s["current_provider_claude"] = "apiget"
os.makedirs(os.path.dirname(setp), exist_ok=True)
json.dump(s, open(setp, "w"), indent=2, ensure_ascii=False)
'@
  $script | & $py.Source -
  if ($LASTEXITCODE -eq 0) { Ok '已把 apiget 写进 cc-switch（provider + 设为当前）。重启 cc-switch 可见可切换。' }
  else { Warn '写 cc-switch 失败；settings.json 已直写、claude 仍可用，可在 cc-switch 界面手动加 apiget。' }
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
        foreach ($k in 'ANTHROPIC_BASE_URL','ANTHROPIC_AUTH_TOKEN','ANTHROPIC_MODEL','ANTHROPIC_DEFAULT_HAIKU_MODEL','CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY','DISABLE_TELEMETRY','DISABLE_ERROR_REPORTING','CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC') { $obj.env.Remove($k) }
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
Set-CcSwitch $t.base $t.token $t.model
Show-Ready $t.base $t.model $t.quota

if (-not $DryRun -and -not $NoLaunch) {
  $exe = Get-ClaudeExe
  if ($exe) { Info '启动 claude …'; & $exe } else { Write-Host '运行 claude 开始体验。' }
} else {
  Write-Host '运行 claude 开始体验。'
}
