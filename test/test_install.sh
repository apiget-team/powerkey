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

echo
echo "结果：PASS=$_pass  FAIL=$_fail"
[ "$_fail" -eq 0 ]
