#!/usr/bin/env bash
#
# powerkey 安装器单元测试 —— 不触网、不安装 Claude Code。
# 通过 POWERKEY_SOURCE_ONLY=1 source 进函数，在隔离 HOME 里单测配置逻辑。
#
#   bash test/test_install.sh
#   LC_ALL=C bash test/test_install.sh   # 顺便验证 C locale 健壮性

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

# 隔离环境，避免污染真实 HOME
TMPHOME="$(mktemp -d)"
export HOME="$TMPHOME"
trap 'rm -rf "$TMPHOME"' EXIT

# 先 source（注意：install.sh 也定义了 ok()，故测试 helper 必须在 source 之后定义，避免被覆盖）
export POWERKEY_SOURCE_ONLY=1
# shellcheck disable=SC1090
. "$SCRIPT_DIR/install.sh"

# -------- 测试 helper（source 之后定义，名字不与 install.sh 冲突） --------
_pass=0; _fail=0
_ok() { printf '  \033[32m✓\033[0m %s\n' "$1"; _pass=$((_pass+1)); }
_no() { printf '  \033[31m✗\033[0m %s\n' "$1"; _fail=$((_fail+1)); }
t_has()    { if grep -qF "$3" "$2" 2>/dev/null; then _ok "$1"; else _no "$1"; fi; }
t_hasnt()  { if grep -qF "$3" "$2" 2>/dev/null; then _no "$1"; else _ok "$1"; fi; }
t_eq()     { if [ "$2" = "$3" ]; then _ok "$1"; else _no "$1 (got '$2' want '$3')"; fi; }
t_empty()  { if [ -z "$2" ]; then _ok "$1"; else _no "$1 (got '$2')"; fi; }
t_run()    { local d="$1"; shift; if "$@" >/dev/null 2>&1; then _ok "$d"; else _no "$d"; fi; }

echo "[json_get]"
J='{"ok":true,"token":"sk-abc","model":"deepseek-v4-pro"}'
t_eq    "ok=true"   "$(json_get "$J" ok)"    "true"
t_eq    "token"     "$(json_get "$J" token)" "sk-abc"
t_empty "缺键返回空" "$(json_get "$J" nope)"

echo "[machine_fingerprint]"
FP1="$(machine_fingerprint)"; FP2="$(machine_fingerprint)"
if [ -n "$FP1" ]; then _ok "非空"; else _no "非空"; fi
t_eq "两次稳定一致" "$FP1" "$FP2"
if printf '%s' "$FP1" | grep -Eq '^[0-9a-f]+$'; then _ok "纯 hex"; else _no "纯 hex"; fi

echo "[apply_settings — 合并不覆盖]"
mkdir -p "$HOME/.claude"
printf '{\n  "theme": "dark",\n  "env": {"FOO": "bar"}\n}\n' > "$HOME/.claude/settings.json"
TOKEN="sk-test-123"; BASE_URL="https://api.apiget.cc"; MODEL="deepseek-v4-pro"; DRY_RUN=0
apply_settings >/dev/null 2>&1
SF="$HOME/.claude/settings.json"
t_has   "保留已有 theme"        "$SF" '"theme"'
t_has   "保留已有 env.FOO"      "$SF" '"FOO"'
t_has   "写入 base_url"         "$SF" 'api.apiget.cc'
t_has   "写入 token"           "$SF" 'sk-test-123'
t_has   "写入 model"           "$SF" 'deepseek-v4-pro'
t_has   "写入 gateway 模型发现"  "$SF" 'CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY'
t_run   "结果是合法 JSON"       python3 -c "import json,sys;json.load(open('$SF'))"

echo "[do_uninstall — 还原备份]"
do_uninstall >/dev/null 2>&1
t_hasnt "还原后不含 token"  "$SF" 'sk-test-123'
t_has   "还原后保留 theme"  "$SF" '"theme"'
t_has   "还原后保留 FOO"    "$SF" '"FOO"'

echo "[detect_conflicting_env — 探测 rc 冲突]"
printf 'export ANTHROPIC_BASE_URL=https://example\n' > "$HOME/.bashrc"
OUT="$( DRY_RUN=1; detect_conflicting_env 2>&1 )"
if printf '%s' "$OUT" | grep -q 'ANTHROPIC_\|启动文件'; then _ok "探测到 rc 中的冲突变量"; else _no "探测到 rc 中的冲突变量"; fi

echo "[configure_cc_switch — 写进 cc-switch DB + 设当前]"
mkdir -p "$HOME/.cc-switch"
python3 - <<'PY'
import sqlite3, os
p = os.path.expanduser("~/.cc-switch/cc-switch.db")
con = sqlite3.connect(p)
con.execute("CREATE TABLE providers (id TEXT NOT NULL, app_type TEXT NOT NULL, name TEXT NOT NULL, settings_config TEXT NOT NULL, website_url TEXT, category TEXT, created_at INTEGER, sort_index INTEGER, notes TEXT, icon TEXT, icon_color TEXT, meta TEXT NOT NULL DEFAULT '{}', is_current BOOLEAN NOT NULL DEFAULT 0, in_failover_queue BOOLEAN NOT NULL DEFAULT 0, PRIMARY KEY (id, app_type))")
con.execute("INSERT INTO providers (id,app_type,name,settings_config,is_current) VALUES ('default','claude','Default','{}',1)")
con.commit(); con.close()
PY
TOKEN="sk-ccs-777"; BASE_URL="https://api.apiget.cc"; MODEL="deepseek-v4-pro"; DRY_RUN=0
configure_cc_switch >/dev/null 2>&1
if python3 - <<'PY'
import sqlite3, os, sys
r = sqlite3.connect(os.path.expanduser("~/.cc-switch/cc-switch.db")).execute("SELECT settings_config,is_current FROM providers WHERE id='apiget' AND app_type='claude'").fetchone()
sys.exit(0 if r and r[1]==1 and 'sk-ccs-777' in r[0] and 'deepseek-v4-pro' in r[0] else 1)
PY
then _ok "apiget provider 写入(is_current=1 + token + model)"; else _no "apiget provider 写入"; fi
if python3 - <<'PY'
import sqlite3, os, sys
r = sqlite3.connect(os.path.expanduser("~/.cc-switch/cc-switch.db")).execute("SELECT is_current FROM providers WHERE id='default'").fetchone()
sys.exit(0 if r and r[0]==0 else 1)
PY
then _ok "旧 default 置为非当前"; else _no "旧 default 置为非当前"; fi
t_has "settings.json 写 current_provider_claude" "$HOME/.cc-switch/settings.json" 'current_provider_claude'
t_has "settings.json 值为 apiget" "$HOME/.cc-switch/settings.json" 'apiget'

echo "[无 python3/jq 兜底矩阵 — json_get sed / apply_settings node|printf]"
# 注：command -v 无法被「不可执行 shim」屏蔽（实测会跳过继续找到真的），且 macOS /usr/bin 自带 python3/jq，
# 故用可控的 has_cmd 覆盖确定性地隐藏命令——直接逼出 json_get 的 sed 兜底与 apply_settings 的 node|printf 兜底
# （这正是当初 json_get 无引号值解析 bug 出没的那类路径）。
_HIDDEN=""
_real_has_cmd() { command -v "$1" >/dev/null 2>&1; }
has_cmd() { case " ${_HIDDEN} " in *" $1 "*) return 1 ;; esac; _real_has_cmd "$1"; }

# (a) json_get sed 兜底：屏蔽 python3+jq —— 须同时解析「引号字符串」与「无引号布尔/数字」
_HIDDEN="python3 jq"
JN='{"ok":true,"quota_usd":2,"token":"sk-x","base_url":"https://api.apiget.cc"}'
t_eq    "sed兜底 ok=true(无引号布尔)"      "$(json_get "$JN" ok)"        "true"
t_eq    "sed兜底 quota_usd=2(无引号数字)"  "$(json_get "$JN" quota_usd)" "2"
t_eq    "sed兜底 token(引号字符串)"         "$(json_get "$JN" token)"     "sk-x"
t_eq    "sed兜底 base_url(带//字符串)"      "$(json_get "$JN" base_url)"  "https://api.apiget.cc"
t_empty "sed兜底 缺键返回空"                "$(json_get "$JN" nope)"
JX='{"ok":true,"quota_usd":2}'
t_eq    "sed兜底(task例) ok=true"          "$(json_get "$JX" ok)"        "true"
t_eq    "sed兜底(task例) quota_usd=2"      "$(json_get "$JX" quota_usd)" "2"

# (a') LC_ALL=C 变体：locale 影响 sed/正则——C locale 下复跑（不开子 shell，避免计数丢失）
_LC_SAVED="${LC_ALL-__unset__}"
export LC_ALL=C
_r_ok="$(json_get "$JX" ok)"; _r_q="$(json_get "$JX" quota_usd)"; _r_t="$(json_get "$JN" token)"
if [ "$_LC_SAVED" = "__unset__" ]; then unset LC_ALL; else export LC_ALL="$_LC_SAVED"; fi
t_eq    "sed兜底(LC_ALL=C) ok=true"        "$_r_ok" "true"
t_eq    "sed兜底(LC_ALL=C) quota_usd=2"    "$_r_q"  "2"
t_eq    "sed兜底(LC_ALL=C) token"          "$_r_t"  "sk-x"

# (b) apply_settings node 兜底：屏蔽 python3+jq、留 node —— 须 merge 新键 + preserve 旧键
_HIDDEN="python3 jq"
if _real_has_cmd node; then
  mkdir -p "$HOME/.claude"
  printf '{\n  "theme": "dark",\n  "env": {"FOO": "bar"}\n}\n' > "$SF"
  TOKEN="sk-node-1"; BASE_URL="https://api.apiget.cc"; MODEL="deepseek-v4-pro"; DRY_RUN=0
  apply_settings >/dev/null 2>&1
  t_has "node兜底 保留 theme"   "$SF" '"theme"'
  t_has "node兜底 保留 env.FOO" "$SF" '"FOO"'
  t_has "node兜底 写入 token"   "$SF" 'sk-node-1'
  t_has "node兜底 写入 model"   "$SF" 'deepseek-v4-pro'
  t_run "node兜底 合法 JSON"    python3 -c "import json;json.load(open('$SF'))"
else
  _ok "node 不可用，跳过 apply_settings node 兜底"
fi

# (c) apply_settings printf 兜底：python3+jq+node 全屏蔽 —— 无 json 工具时对全新文件写出合法 JSON
#（printf 路径对「已存在」settings.json 会安全拒绝合并并 die，是设计行为，故先删）
_HIDDEN="python3 jq node"
rm -f "$SF"
TOKEN="sk-printf-1"; BASE_URL="https://api.apiget.cc"; MODEL="deepseek-v4-pro"; DRY_RUN=0
apply_settings >/dev/null 2>&1
t_has "printf兜底 写入 token"  "$SF" 'sk-printf-1'
t_has "printf兜底 写入 model"  "$SF" 'deepseek-v4-pro'
t_has "printf兜底 写 base_url" "$SF" 'api.apiget.cc'
t_run "printf兜底 合法 JSON"   python3 -c "import json;json.load(open('$SF'))"

_HIDDEN=""   # 还原：后续测试用真实命令探测

echo "[do_uninstall — 完整撤销：rc / ~/.claude.json / cc-switch]"
# rc：模拟 ensure_local_bin_path 的「# powerkey-path」块 + detect_conflicting_env 注释掉的 env 行 + 用户自有行
printf 'export FOO=1\n\n# powerkey-path\nexport PATH="$HOME/.local/bin:$PATH"\n# powerkey-disabled: export ANTHROPIC_BASE_URL=https://old\nexport BAR=2\n' > "$HOME/.zshrc"
# ~/.claude.json：备份 + 当前被改写版
mkdir -p "$BACKUP_DIR"
printf '{"original":true}\n' > "$BACKUP_DIR/claude.json.bak.20000101000000"
printf '{"hasCompletedOnboarding":true,"projects":{}}\n' > "$HOME/.claude.json"
# cc-switch 状态沿用上面 configure_cc_switch 留下的（apiget is_current=1 + default + settings current=apiget）
do_uninstall >/dev/null 2>&1
t_hasnt "rc 删除 # powerkey-path 标记"        "$HOME/.zshrc" '# powerkey-path'
t_hasnt "rc 删除 powerkey 的 PATH export"      "$HOME/.zshrc" '.local/bin'
t_has   "rc 反注释还原 ANTHROPIC_BASE_URL 行"  "$HOME/.zshrc" 'export ANTHROPIC_BASE_URL=https://old'
t_hasnt "rc 不残留 powerkey-disabled 前缀"     "$HOME/.zshrc" 'powerkey-disabled'
t_has   "rc 保留用户行 FOO"                    "$HOME/.zshrc" 'export FOO=1'
t_has   "rc 保留用户行 BAR"                    "$HOME/.zshrc" 'export BAR=2'
t_has   "claude.json 还原回 original"          "$HOME/.claude.json" '"original"'
t_hasnt "claude.json 不再是改写版"             "$HOME/.claude.json" 'hasCompletedOnboarding'
if python3 - <<'PY'
import sqlite3,os,sys
r=sqlite3.connect(os.path.expanduser("~/.cc-switch/cc-switch.db")).execute("SELECT count(*) FROM providers WHERE id='apiget' AND app_type='claude'").fetchone()
sys.exit(0 if r and r[0]==0 else 1)
PY
then _ok "cc-switch 删除 apiget provider 行"; else _no "cc-switch 删除 apiget provider 行"; fi
t_hasnt "cc-switch settings 不再指向 apiget"   "$HOME/.cc-switch/settings.json" 'apiget'
t_has   "cc-switch settings 改回 default"      "$HOME/.cc-switch/settings.json" 'default'
if python3 - <<'PY'
import sqlite3,os,sys
r=sqlite3.connect(os.path.expanduser("~/.cc-switch/cc-switch.db")).execute("SELECT is_current FROM providers WHERE id='default'").fetchone()
sys.exit(0 if r and r[0]==1 else 1)
PY
then _ok "cc-switch default 重新置为当前"; else _no "cc-switch default 重新置为当前"; fi

echo "[do_uninstall — rc 清理的 awk 兜底（无 python3）]"
# 屏蔽 python3 逼出 awk 兜底（与 detect_conflicting_env 的 sed 兜底对称的撤销路径）
_HIDDEN="python3"
printf '# powerkey-path\nexport PATH="$HOME/.local/bin:$PATH"\n# powerkey-disabled: export ANTHROPIC_MODEL=foo\nexport KEEP=1\n' > "$HOME/.bashrc"
do_uninstall >/dev/null 2>&1
t_hasnt "awk兜底 删 # powerkey-path"        "$HOME/.bashrc" 'powerkey-path'
t_hasnt "awk兜底 删 PATH export"            "$HOME/.bashrc" '.local/bin'
t_has   "awk兜底 反注释 ANTHROPIC_MODEL"    "$HOME/.bashrc" 'export ANTHROPIC_MODEL=foo'
t_hasnt "awk兜底 无 powerkey-disabled 残留" "$HOME/.bashrc" 'powerkey-disabled'
t_has   "awk兜底 保留用户行 KEEP"           "$HOME/.bashrc" 'export KEEP=1'
_HIDDEN=""

echo
echo "结果：PASS=$_pass  FAIL=$_fail"
[ "$_fail" -eq 0 ]
