#!/usr/bin/env pwsh
#
# powerkey install.ps1 行为单测 —— 不触网、不装 Claude Code。
# 经 POWERKEY_SOURCE_ONLY=1 dot-source 进函数，在隔离临时目录里单测：
#   1) Set-Settings 合并不覆盖（保留已有 settings.json 键）
#   2) Invoke-Uninstall 只移除 powerkey 写入的键（保留用户键）
#
#   pwsh ./test/test_install.ps1
#
# 注：本机无 pwsh，无法本地验证；CI（windows）会跑。

$ErrorActionPreference = 'Stop'
$env:POWERKEY_SOURCE_ONLY = '1'
. "$PSScriptRoot/../install.ps1"   # SOURCE_ONLY=1 → 只加载函数，不跑主流程

$script:pass = 0; $script:fail = 0
function T-Ok($m) { Write-Host "  [pass] $m" -ForegroundColor Green; $script:pass++ }
function T-No($m) { Write-Host "  [fail] $m" -ForegroundColor Red;   $script:fail++ }
function T-True($m, $cond) { if ($cond) { T-Ok $m } else { T-No $m } }

# 隔离路径：dot-source 后这些是脚本作用域变量；PowerShell 动态作用域下，被 source 的函数读取时会看到这里的重赋值
$tmp              = Join-Path ([IO.Path]::GetTempPath()) ("pk-pstest-" + [guid]::NewGuid())
$ClaudeDir        = Join-Path $tmp '.claude'
$SettingsFile     = Join-Path $ClaudeDir 'settings.json'
$BackupDir        = Join-Path $tmp 'backups'
$StateFile        = Join-Path $tmp 'state.json'
$CcSwitchDir      = Join-Path $tmp '.cc-switch'
$CcSwitchDb       = Join-Path $CcSwitchDir 'cc-switch.db'
$CcSwitchSettings = Join-Path $CcSwitchDir 'settings.json'
New-Item -ItemType Directory -Force -Path $ClaudeDir | Out-Null

Write-Host '[Set-Settings — 合并不覆盖]'
# 预置已有 settings.json：顶层 theme + env.FOO
'{ "theme": "dark", "env": { "FOO": "bar" } }' | Set-Content -Path $SettingsFile -Encoding UTF8
Set-Settings 'https://api.apiget.cc' 'sk-ps-123' 'deepseek-v4-pro'
$o = Get-Content $SettingsFile -Raw | ConvertFrom-Json
T-True 'Set-Settings 保留 theme'     ($o.theme -eq 'dark')
T-True 'Set-Settings 保留 env.FOO'   ($o.env.FOO -eq 'bar')
T-True 'Set-Settings 写入 base_url'  ($o.env.ANTHROPIC_BASE_URL -eq 'https://api.apiget.cc')
T-True 'Set-Settings 写入 token'     ($o.env.ANTHROPIC_AUTH_TOKEN -eq 'sk-ps-123')
T-True 'Set-Settings 写入 model'     ($o.env.ANTHROPIC_MODEL -eq 'deepseek-v4-pro')

Write-Host '[Invoke-Uninstall — 只移除 powerkey 键]'
# 删掉备份逼出「按键移除」分支（而非整文件还原），以直接验证「只移除 powerkey 键、保留用户键」
Remove-Item (Join-Path $BackupDir '*') -Force -Recurse -ErrorAction SilentlyContinue
Invoke-Uninstall   # cc-switch / claude.json / anthropic-env / state 均无 → 安全空操作
$o2 = Get-Content $SettingsFile -Raw | ConvertFrom-Json
T-True 'uninstall 保留 theme'              ($o2.theme -eq 'dark')
T-True 'uninstall 保留 env.FOO'            ($o2.env.FOO -eq 'bar')
T-True 'uninstall 移除 ANTHROPIC_AUTH_TOKEN' ($null -eq $o2.env.ANTHROPIC_AUTH_TOKEN)
T-True 'uninstall 移除 ANTHROPIC_BASE_URL'   ($null -eq $o2.env.ANTHROPIC_BASE_URL)
T-True 'uninstall 移除 DISABLE_TELEMETRY'    ($null -eq $o2.env.DISABLE_TELEMETRY)

Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
Write-Host ''
Write-Host "PS test: PASS=$script:pass  FAIL=$script:fail"
if ($script:fail -gt 0) { exit 1 }
