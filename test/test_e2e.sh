#!/usr/bin/env bash
#
# powerkey 端到端集成测试 —— 用 mock 发码服务 + 假 claude 跑完整安装流程，
# 不触真网、不装真 Claude Code。验证：发码→写 settings.json→L0 幂等。
#
#   bash test/test_e2e.sh

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
export HOME="$WORK/home"; mkdir -p "$HOME"
BIN="$WORK/bin"; mkdir -p "$BIN"
PORT=47193
MOCK_PID=""
trap '[ -n "$MOCK_PID" ] && kill "$MOCK_PID" 2>/dev/null; rm -rf "$WORK"' EXIT

# 本地回环不走代理（本工作区 curl 默认可能走 Clash）
export NO_PROXY="127.0.0.1,localhost"; export no_proxy="127.0.0.1,localhost"

_p=0; _f=0
ok() { printf '  \033[32m✓\033[0m %s\n' "$1"; _p=$((_p+1)); }
no() { printf '  \033[31m✗\033[0m %s\n' "$1"; _f=$((_f+1)); }

# 假 claude：让 ensure_claude_code 认为已装、升级走 no-op（不触网、不真装）
cat > "$BIN/claude" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  --version) echo "9.9.9 (fake claude)";;
  *) exit 0;;
esac
EOF
chmod +x "$BIN/claude"
export PATH="$BIN:$PATH"

# mock 发码服务（返回固定 issue JSON）
cat > "$WORK/mock.py" <<'PY'
import sys, json
from http.server import BaseHTTPRequestHandler, HTTPServer
class H(BaseHTTPRequestHandler):
    def do_POST(self):
        n = int(self.headers.get('Content-Length', '0')); self.rfile.read(n)
        body = json.dumps({"ok": True, "token": "sk-issued-999",
                           "base_url": "https://api.apiget.cc",
                           "model": "deepseek-v4-pro", "quota_usd": 2}).encode()
        self.send_response(200); self.send_header('Content-Type', 'application/json')
        self.end_headers(); self.wfile.write(body)
    def log_message(self, *a): pass
HTTPServer(('127.0.0.1', int(sys.argv[1])), H).serve_forever()
PY
python3 "$WORK/mock.py" "$PORT" & MOCK_PID=$!
# 轮询等 mock 就绪（固定 sleep 1 在慢 CI / macOS 上会 race → run1 curl 30s 超时）
for _i in $(seq 1 40); do curl -fsS --max-time 2 -o /dev/null -X POST "http://127.0.0.1:$PORT/issue" --data '{}' 2>/dev/null && break; sleep 0.3; done

echo "[run 1 — 首次安装]"
bash "$SCRIPT_DIR/install.sh" --issuer "http://127.0.0.1:$PORT" --no-launch </dev/null >"$WORK/out1.txt" 2>&1
rc=$?
SF="$HOME/.claude/settings.json"
[ "$rc" = 0 ] && ok "安装器退出码 0" || { no "安装器退出码 0 (got $rc)"; cat "$WORK/out1.txt"; }
[ -f "$SF" ] && ok "生成 settings.json" || no "生成 settings.json"
grep -qF 'sk-issued-999'   "$SF" 2>/dev/null && ok "写入发码服务返回的 token"  || no "写入发码服务返回的 token"
grep -qF 'deepseek-v4-pro' "$SF" 2>/dev/null && ok "写入发码服务返回的 model"  || no "写入发码服务返回的 model"
grep -qF 'api.apiget.cc'   "$SF" 2>/dev/null && ok "写入 base_url"            || no "写入 base_url"
python3 -c "import json;json.load(open('$SF'))" 2>/dev/null && ok "settings.json 合法 JSON" || no "settings.json 合法 JSON"
[ -f "$HOME/.powerkey/state.json" ] && ok "保存本地 state（L0 幂等用）" || no "保存本地 state"

echo "[run 2 — 重跑应复用（L0 幂等）]"
bash "$SCRIPT_DIR/install.sh" --issuer "http://127.0.0.1:$PORT" --no-launch </dev/null >"$WORK/out2.txt" 2>&1
grep -q '复用本机已领' "$WORK/out2.txt" && ok "重跑复用老 token（不重领）" || { no "重跑复用老 token"; cat "$WORK/out2.txt"; }

echo "[--key 模式 — 教程派发]"
export HOME="$WORK/home2"; mkdir -p "$HOME"
bash "$SCRIPT_DIR/install.sh" --key "sk-handed-out-abc" --no-launch </dev/null >"$WORK/out3.txt" 2>&1
SF2="$HOME/.claude/settings.json"
grep -qF 'sk-handed-out-abc' "$SF2" 2>/dev/null && ok "--key 直接写入提供的 key" || no "--key 直接写入提供的 key"

echo
echo "E2E: PASS=$_p  FAIL=$_f"
[ "$_f" -eq 0 ]
