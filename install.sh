#!/usr/bin/env bash
#
# powerkey — 一键装好 Claude Code 并接上 apiget.cc，直接能用
# https://github.com/apiget-team/powerkey
#
#   curl -fsSL https://get.apiget.cc | bash
#   curl -fsSL https://get.apiget.cc | bash -s -- [options]
#
# 做的事：探测环境 → 装/升级 Claude Code（官方源失败自动回退国内镜像）→ 领 $2 体验额度
#         → 写 ~/.claude/settings.json（合并不覆盖、清理冲突旧 env、关非必要外联）
#         → 处理 cc-switch → 就绪（交互终端下自动拉起 claude）
#
# Options:
#   --dry-run        只演示，不安装、不写配置、不领真 key
#   --uninstall      撤销 powerkey 的配置改动（还原备份、删本地状态）
#   --no-launch      装完不自动拉起 claude
#   --force          忽略本地已领记录，强制重新领取
#   --cn             强制走国内镜像源装 Claude Code（不连 github/claude.ai）
#   --key TOKEN      直接用这个 apiget key（教程派发场景），跳过自动发码
#   --base-url URL   覆盖 apiget API base（默认 https://api.apiget.cc）
#   --issuer URL     覆盖发码服务端点（默认 https://get.apiget.cc）
#   --ref CODE       推广/分销归因码（带进发码请求）
#   --source NAME    来源标签（默认 powerkey）
#   -h, --help       显示帮助
#
# ----------------------------------------------------------------------------
# Derived from QuantumNous/new-api-docs `helper/claude-cli-setup.sh` (MIT) — the
# TTY-safe IO helpers (read_tty/read_secret_tty/sh_single_quote), extract_host,
# ensure_scheme, read_env_from_rcs and the overall interactive flow originate there.
# The ~/.claude/settings.json `env` shape is informed by UfoMiao/zcf (MIT) and
# farion1231/cc-switch (MIT). Full attribution in NOTICE. powerkey additions:
# Claude Code auto-install (+ China npmmirror fallback), settings.json writer,
# trial-key issuer call, deepseek default, conflicting-env cleanup, --dry-run/
# --uninstall, TTY auto-launch.
# ----------------------------------------------------------------------------

set -u
umask 077

# -------- 常量 --------
POWERKEY_VERSION="0.1.0"
DEFAULT_ISSUER="https://get.apiget.cc"
DEFAULT_BASE_URL="https://api.apiget.cc"
DEFAULT_MODEL="deepseek-v4-pro"        # 兜底；权威 model 由发码服务返回（服务端可改）
REGISTER_URL="https://apiget.cc/register?ref=powerkey"
CLAUDE_INSTALL_URL="https://claude.ai/install.sh"
NPM_CN_REGISTRY="https://registry.npmmirror.com"               # 国内 npm 镜像
NODE_CN_MIRROR="https://registry.npmmirror.com/-/binary/node"  # 国内 Node 二进制镜像
NODE_VER="v22.11.0"                                            # 国内装 Node 时用（LTS，可升）

STATE_DIR="${HOME}/.powerkey"
STATE_FILE="${STATE_DIR}/state.json"
BACKUP_DIR="${STATE_DIR}/backups"
LOCAL_NODE_DIR="${STATE_DIR}/node"
CLAUDE_DIR="${HOME}/.claude"
SETTINGS_FILE="${CLAUDE_DIR}/settings.json"
LOCAL_BIN="${HOME}/.local/bin"
CC_SWITCH_DIR="${HOME}/.cc-switch"
CC_SWITCH_DB="${CC_SWITCH_DIR}/cc-switch.db"
CC_SWITCH_SETTINGS="${CC_SWITCH_DIR}/settings.json"

TOKEN=""
QUOTA_USD="2"

# -------- 日志（无 TTY / NO_COLOR 自动去色） --------
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
  C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_RED=$'\033[31m'; C_CYAN=$'\033[36m'
else
  C_RESET=""; C_BOLD=""; C_DIM=""; C_GREEN=""; C_YELLOW=""; C_RED=""; C_CYAN=""
fi
log()  { printf '%s\n' "$*"; }
info() { printf '%s▸%s %s\n' "$C_CYAN" "$C_RESET" "$*"; }
ok()   { printf '%s✓%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn() { printf '%s!%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
err()  { printf '%s✗%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; }
die()  { err "$*"; exit 1; }

# -------- 通用工具（多数源自 MIT 基底） --------
has_cmd() { command -v "$1" >/dev/null 2>&1; }
trim() { printf "%s" "${1:-}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'; }
sh_single_quote() { printf "'%s'" "$(printf "%s" "${1:-}" | sed "s/'/'\\''/g")"; }

# 交互判定：curl|bash 下 stdin 是管道，须借 /dev/tty 重连控制终端
is_interactive() { [ -t 1 ] && [ -r /dev/tty ]; }
read_tty()        { local p="${1:-}" in=""; is_interactive && { read -r -p "$p" in </dev/tty || true; }; printf "%s" "${in:-}"; }
read_secret_tty() { local p="${1:-}" in=""; is_interactive && { read -r -s -p "$p" in </dev/tty || true; echo >&2; }; printf "%s" "${in:-}"; }

extract_host() { local u="${1:-}"; u="${u#http://}"; u="${u#https://}"; printf "%s" "${u%%/*}"; }
ensure_scheme() { case "${1:-}" in http://*|https://*) printf "%s" "$1";; *) printf "https://%s" "$1";; esac; }

usage() {
  cat <<'EOF'
powerkey — 一键装好 Claude Code 并接上 apiget.cc

  curl -fsSL https://get.apiget.cc | bash
  curl -fsSL https://get.apiget.cc | bash -s -- [options]

Options:
  --dry-run        只演示，不安装、不写配置、不领真 key
  --uninstall      撤销 powerkey 的配置改动（还原备份、删本地状态）
  --no-launch      装完不自动拉起 claude
  --force          忽略本地已领记录，强制重新领取
  --cn             强制走国内镜像源装 Claude Code（不连 github/claude.ai）
  --key TOKEN      直接用这个 apiget key，跳过自动发码
  --base-url URL   覆盖 apiget API base（默认 https://api.apiget.cc）
  --issuer URL     覆盖发码服务端点（默认 https://get.apiget.cc）
  --ref CODE       推广/分销归因码
  --source NAME    来源标签（默认 powerkey）
  -h, --help       显示帮助
EOF
}

# -------- 参数 --------
DRY_RUN=0; DO_UNINSTALL=0; NO_LAUNCH=0; FORCE=0; CN=0
ISSUER="$DEFAULT_ISSUER"; BASE_URL=""; MODEL=""; SUPPLIED_KEY=""
SOURCE_TAG="powerkey"; REF=""; CHANNEL=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run)   DRY_RUN=1 ;;
    --uninstall) DO_UNINSTALL=1 ;;
    --no-launch) NO_LAUNCH=1 ;;
    --force)     FORCE=1 ;;
    --cn)        CN=1 ;;
    --key)       SUPPLIED_KEY="${2:-}"; shift ;;
    --base-url)  BASE_URL="${2:-}"; shift ;;
    --issuer)    ISSUER="${2:-}"; shift ;;
    --ref)       REF="${2:-}"; shift ;;
    --source)    SOURCE_TAG="${2:-}"; shift ;;
    --channel)   CHANNEL="${2:-}"; shift ;;
    -h|--help)   usage; exit 0 ;;
    *)           warn "未知选项：$1（--help 看用法）" ;;
  esac
  shift
done
[ -n "$REF" ] && [ -z "$CHANNEL" ] && CHANNEL="$REF"   # --ref 是 --channel 的别名
# 归一化用户覆盖的 URL（补 scheme、去尾斜杠），避免 ANTHROPIC_BASE_URL 配错
[ -n "$BASE_URL" ] && { BASE_URL="$(ensure_scheme "$BASE_URL")"; BASE_URL="${BASE_URL%/}"; }
[ -n "$ISSUER" ]   && { ISSUER="$(ensure_scheme "$ISSUER")"; ISSUER="${ISSUER%/}"; }

# -------- 工具 --------
detect_os()   { case "$(uname -s 2>/dev/null || echo unknown)" in Darwin) echo darwin;; Linux) echo linux;; *) echo unknown;; esac; }
detect_arch() { uname -m 2>/dev/null | tr 'A-Z' 'a-z' || echo unknown; }
sha256_hex()  { if has_cmd shasum; then shasum -a 256 | awk '{print $1}'; elif has_cmd sha256sum; then sha256sum | awk '{print $1}'; else cksum | awk '{print $1}'; fi; }

# 机器指纹：稳定且不外传原始标识（只发哈希），用于防刷 L0/L1
machine_fingerprint() {
  local raw="" os; os="$(detect_os)"
  if [ "$os" = darwin ]; then
    raw="$(ioreg -rd1 -c IOPlatformExpertDevice 2>/dev/null | awk -F'"' '/IOPlatformUUID/{print $4}')"
  elif [ "$os" = linux ]; then
    if   [ -r /etc/machine-id ];          then raw="$(cat /etc/machine-id 2>/dev/null)"
    elif [ -r /var/lib/dbus/machine-id ]; then raw="$(cat /var/lib/dbus/machine-id 2>/dev/null)"; fi
  fi
  [ -n "$raw" ] || raw="$(hostname 2>/dev/null)-${USER:-user}"
  printf '%s' "powerkey:${raw}:${USER:-user}" | sha256_hex
}

json_get() { # $1=json $2=key（顶层）
  if has_cmd python3; then
    PK_J="$1" PK_K="$2" python3 - <<'PY' 2>/dev/null
import json, os
try:
    d = json.loads(os.environ["PK_J"]); v = d.get(os.environ["PK_K"])
    print("" if v is None else (v if isinstance(v, str) else json.dumps(v)))
except Exception: print("")
PY
  elif has_cmd jq; then printf '%s' "$1" | jq -r --arg k "$2" '.[$k] // empty' 2>/dev/null
  else
    # 无 python3/jq 的 sed 兜底：先取带引号字符串值；取不到再取无引号值（布尔/数字，如 "ok":true / "quota_usd":2）
    local _v
    _v="$(printf '%s' "$1" | sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" | head -n1)"
    [ -n "$_v" ] || _v="$(printf '%s' "$1" | sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\([^\",}[:space:]]*\).*/\1/p" | head -n1)"
    printf '%s' "$_v"
  fi
}

# -------- 步骤 --------
print_banner() {
  log ""
  log "${C_BOLD}${C_CYAN}powerkey${C_RESET}  —  一键装 Claude Code · 接 apiget.cc"
  log "${C_DIM}v${POWERKEY_VERSION}$([ "$DRY_RUN" = 1 ] && printf ' (dry-run)')$([ "$CN" = 1 ] && printf ' (cn)')${C_RESET}"
  log ""
}

preflight() {
  has_cmd curl || die "需要 curl，请先安装后重试。"
  local os; os="$(detect_os)"
  [ "$os" = unknown ] && die "本脚本支持 macOS / Linux。Windows 请用 install.ps1。"
  has_cmd python3 || has_cmd jq || warn "未检测到 python3 或 jq：将用安装后的 Node 合并 settings.json（仍建议装 python3 获最稳路径）。"
  info "环境：$os/$(detect_arch)$([ "$CN" = 1 ] && printf '（国内镜像模式）')"
}

# 探测/清理会覆盖 settings.json 的 shell ANTHROPIC_* 导出（shell env 优先级高于 settings.json）
detect_conflicting_env() {
  local vars="ANTHROPIC_BASE_URL ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN ANTHROPIC_MODEL ANTHROPIC_DEFAULT_HAIKU_MODEL" v live="" rc rc_hits=""
  for v in $vars; do eval "[ -n \"\${$v:-}\" ]" && live="$live $v"; done
  for rc in "$HOME/.bashrc" "$HOME/.zshrc" "$HOME/.bash_profile" "$HOME/.zprofile" "$HOME/.profile"; do
    [ -f "$rc" ] || continue
    grep -Eq '^[[:space:]]*(export[[:space:]]+)?(ANTHROPIC_BASE_URL|ANTHROPIC_API_KEY|ANTHROPIC_AUTH_TOKEN|ANTHROPIC_MODEL|ANTHROPIC_DEFAULT_HAIKU_MODEL)=' "$rc" 2>/dev/null && rc_hits="$rc_hits $rc"
  done
  [ -z "$live" ] && [ -z "$rc_hits" ] && return 0
  warn "检测到已有 ANTHROPIC_* 环境变量——其优先级高于 settings.json，会让本次配置不生效："
  [ -n "$live" ]    && warn "  当前 shell 已导出：${live# }（须 unset 或重开终端）"
  [ -n "$rc_hits" ] && warn "  写在启动文件：${rc_hits# }"
  if [ -n "$rc_hits" ] && [ "$DRY_RUN" = 0 ] && is_interactive; then
    local a; a="$(read_tty "把这些启动文件里的旧 ANTHROPIC_* 行注释掉？（已先备份）[y/N] ")"
    case "$a" in
      y|Y|yes|YES)
        mkdir -p "$BACKUP_DIR"
        for rc in $rc_hits; do
          cp "$rc" "$BACKUP_DIR/$(basename "$rc").bak.$(date +%Y%m%d%H%M%S 2>/dev/null || echo bak)" 2>/dev/null || true
          if has_cmd python3; then
            PK_RC="$rc" python3 - <<'PY' 2>/dev/null || true
import re, os
p=os.environ["PK_RC"]
pat=re.compile(r'^\s*(export\s+)?(ANTHROPIC_BASE_URL|ANTHROPIC_API_KEY|ANTHROPIC_AUTH_TOKEN|ANTHROPIC_MODEL|ANTHROPIC_DEFAULT_HAIKU_MODEL)=')
out=[("# powerkey-disabled: "+l) if (pat.match(l) and not l.lstrip().startswith("#")) else l
     for l in open(p, encoding="utf-8", errors="replace")]
open(p,"w",encoding="utf-8").write("".join(out))
PY
          else
            sed -i.bak -E 's/^([[:space:]]*(export[[:space:]]+)?(ANTHROPIC_BASE_URL|ANTHROPIC_API_KEY|ANTHROPIC_AUTH_TOKEN|ANTHROPIC_MODEL|ANTHROPIC_DEFAULT_HAIKU_MODEL)=)/# powerkey-disabled: \1/' "$rc" 2>/dev/null && rm -f "$rc.bak" 2>/dev/null || true
          fi
        done
        ok "已注释旧 env 行（备份在 ${BACKUP_DIR}），新开终端生效。"
        ;;
      *) warn "已跳过。若配置不生效，请手动移除上述变量后重开终端。" ;;
    esac
  elif [ -n "$rc_hits" ]; then
    warn "  → 请手动注释/删除这些行，或在交互终端重跑以自动处理。"
  fi
  [ -n "$live" ] && warn "  → 当前终端：unset${live} 后重开终端。"
}

claude_path() { command -v claude 2>/dev/null || { [ -x "$LOCAL_BIN/claude" ] && echo "$LOCAL_BIN/claude"; }; }

# 确保 ~/.local/bin 在 PATH（原生安装 / npm --prefix 都装到这里）；并写进 rc 供新终端
ensure_local_bin_path() {
  case ":${PATH}:" in *":${LOCAL_BIN}:"*) ;; *) export PATH="${LOCAL_BIN}:$PATH" ;; esac
  local rc="${HOME}/.zshrc"; [ -f "${HOME}/.bashrc" ] && rc="${HOME}/.bashrc"
  if ! grep -q 'powerkey-path' "$rc" 2>/dev/null; then
    printf '\n# powerkey-path\nexport PATH="$HOME/.local/bin:$PATH"\n' >> "$rc" 2>/dev/null || true
  fi
}

# 没有 Node 时，从国内镜像下一个（免 sudo、免 GitHub），软链 node/npm 进 ~/.local/bin
ensure_node_cn() {
  # 已有 npm 且 Node 主版本 ≥18 才跳过；旧 Node 会让 CC 启动 EBADENGINE/SyntaxError，需引导新 Node
  if has_cmd npm && has_cmd node; then
    local _maj; _maj="$(node -v 2>/dev/null | sed 's/^v//' | cut -d. -f1)"
    case "$_maj" in
      ''|*[!0-9]*) : ;;
      *) [ "$_maj" -ge 18 ] && return 0; warn "Node 版本过低（$(node -v 2>/dev/null)，需 ≥18），改用国内镜像 Node ${NODE_VER}…" ;;
    esac
  fi
  local os arch nodeos nodearch dir pkg url
  os="$(detect_os)"; arch="$(detect_arch)"
  case "$os" in darwin) nodeos=darwin ;; linux) nodeos=linux ;; *) die "不支持的系统自动装 Node。" ;; esac
  case "$arch" in x86_64|amd64) nodearch=x64 ;; aarch64|arm64) nodearch=arm64 ;; *) die "不支持的架构自动装 Node：${arch}。" ;; esac
  dir="node-${NODE_VER}-${nodeos}-${nodearch}"; pkg="${dir}.tar.gz"; url="${NODE_CN_MIRROR}/${NODE_VER}/${pkg}"
  info "未检测到 Node，正从国内镜像装 Node ${NODE_VER}…"
  mkdir -p "$LOCAL_NODE_DIR" "$LOCAL_BIN"
  curl -fsSL --max-time 180 "$url" -o "${LOCAL_NODE_DIR}/${pkg}" || die "下载 Node 失败：$url"
  tar -xzf "${LOCAL_NODE_DIR}/${pkg}" -C "$LOCAL_NODE_DIR" || die "解压 Node 失败。"
  rm -f "${LOCAL_NODE_DIR}/${pkg}"
  ln -sf "${LOCAL_NODE_DIR}/${dir}/bin/node" "${LOCAL_BIN}/node"
  ln -sf "${LOCAL_NODE_DIR}/${dir}/bin/npm"  "${LOCAL_BIN}/npm"
  ln -sf "${LOCAL_NODE_DIR}/${dir}/bin/npx"  "${LOCAL_BIN}/npx"
  export PATH="${LOCAL_NODE_DIR}/${dir}/bin:${LOCAL_BIN}:$PATH"
  has_cmd npm || die "Node 装好但 npm 不可用。"
  ok "Node ${NODE_VER} 已装到 ${LOCAL_NODE_DIR}。"
}

# 经国内镜像（npmmirror）装 Claude Code 到 ~/.local（无 sudo、不连 github/claude.ai）
cc_install_cn() {
  ensure_node_cn
  info "经国内镜像（npmmirror）安装 Claude Code…"
  npm install -g @anthropic-ai/claude-code@latest --registry="$NPM_CN_REGISTRY" --prefix "$HOME/.local" \
    || die "国内镜像安装 Claude Code 失败。"
}

# 官方源装 Claude Code（海外路径）；失败/未生成 claude 则回退国内镜像
cc_install_native_or_cn() {
  local tmp; tmp="$(mktemp)"
  # 国内 claude.ai 常返「区域不可用」HTML（302→HTML）：别把 HTML 当脚本 bash（会喷 syntax error + 整页 HTML）；
  # 检测到 HTML 直接当失败、干净回退 npmmirror。
  if curl -fsSL --max-time 25 "$CLAUDE_INSTALL_URL" -o "$tmp" && [ -s "$tmp" ] \
     && ! head -c 256 "$tmp" | grep -qiE '<!doctype|<html|unavailable in region|app-unavailable' \
     && bash "$tmp"; then
    rm -f "$tmp"; ensure_local_bin_path
    [ -n "$(claude_path)" ] && return 0
    warn "官方源装完但未找到 claude，回退国内镜像…"
  else
    rm -f "$tmp"; warn "官方源不可用（国内网络/区域限制，claude.ai 不可达），改用国内镜像 npmmirror…"
  fi
  cc_install_cn
}

ensure_claude_code() {
  export PATH="$LOCAL_BIN:$PATH"
  local existing; existing="$(claude_path)"
  if [ -n "$existing" ]; then
    info "已装 Claude Code（$("$existing" --version 2>/dev/null | head -n1)），尝试升级…"
    [ "$DRY_RUN" = 1 ] && { ok "[dry-run] 跳过升级"; return 0; }
    if [ "$CN" = 1 ]; then cc_install_cn || warn "升级未成功，沿用现有版本。"
    else "$existing" update >/dev/null 2>&1 || warn "升级未成功，沿用现有版本。"; fi
    ok "Claude Code 就绪。"; return 0
  fi
  info "未检测到 Claude Code，安装最新版…"
  if [ "$DRY_RUN" = 1 ]; then ok "[dry-run] 将安装 Claude Code（CN=${CN}：1=国内镜像 npmmirror；0=官方源失败再回退国内镜像）"; return 0; fi
  if [ "$CN" = 1 ]; then cc_install_cn; else cc_install_native_or_cn; fi
  ensure_local_bin_path
  local _cb; _cb="$(claude_path)"
  [ -n "$_cb" ] || warn "已安装但 PATH 未含 claude；新开终端，或把 ${LOCAL_BIN} 加入 PATH。"
  # 装后冒烟：确认二进制真能跑（防 npmmirror 平台二进制不全等静默坏）
  if [ -n "$_cb" ] && ! "$_cb" --version >/dev/null 2>&1; then
    warn "claude 已装但 --version 跑不通（镜像可能缺平台二进制）；可重试，或把 --cn 与官方源互换一次。"
  fi
  ok "Claude Code 安装完成。"
}

# 发码服务契约（薄服务，部署在 $ISSUER 后）：
#   POST {ISSUER}/issue  req {fingerprint,os,arch,source,channel,client_version}
#   resp 成功 {ok:true,token,base_url,model,quota_usd}
#   resp 降级 {ok:false,fallback_url,reason,message}
issue_request() {
  local fp os arch payload
  fp="$(machine_fingerprint)"; os="$(detect_os)"; arch="$(detect_arch)"
  if has_cmd python3; then
    payload="$(PK_FP="$fp" PK_OS="$os" PK_ARCH="$arch" PK_SRC="$SOURCE_TAG" PK_CH="$CHANNEL" PK_VER="$POWERKEY_VERSION" python3 - <<'PY'
import json, os
print(json.dumps({"fingerprint":os.environ["PK_FP"],"os":os.environ["PK_OS"],"arch":os.environ["PK_ARCH"],
                  "source":os.environ["PK_SRC"],"channel":os.environ["PK_CH"],"client_version":os.environ["PK_VER"]}))
PY
)"
  else
    payload="{\"fingerprint\":\"$fp\",\"os\":\"$os\",\"arch\":\"$arch\",\"source\":\"$SOURCE_TAG\",\"channel\":\"$CHANNEL\",\"client_version\":\"$POWERKEY_VERSION\"}"
  fi
  curl -fsS -X POST "${ISSUER%/}/issue" -H "Content-Type: application/json" \
    -H "User-Agent: powerkey/${POWERKEY_VERSION}" --data "$payload" --max-time 30
}

save_state() {
  mkdir -p "$STATE_DIR"; chmod 700 "$STATE_DIR" 2>/dev/null || true
  if has_cmd python3; then
    PK_F="$STATE_FILE" PK_FP="$(machine_fingerprint)" PK_T="$TOKEN" PK_B="$BASE_URL" PK_M="$MODEL" python3 - <<'PY' 2>/dev/null || true
import json, os
json.dump({"fingerprint":os.environ["PK_FP"],"token":os.environ["PK_T"],"base_url":os.environ["PK_B"],"model":os.environ["PK_M"],"v":1}, open(os.environ["PK_F"],"w"))
PY
  else printf '{"token":"%s","base_url":"%s","model":"%s","v":1}\n' "$TOKEN" "$BASE_URL" "$MODEL" > "$STATE_FILE"; fi
  chmod 600 "$STATE_FILE" 2>/dev/null || true
}

obtain_token() {
  # 用户直接给了 key（教程派发场景）
  if [ -n "$SUPPLIED_KEY" ]; then
    TOKEN="$SUPPLIED_KEY"
    [ -n "$BASE_URL" ] || BASE_URL="$DEFAULT_BASE_URL"; [ -n "$MODEL" ] || MODEL="$DEFAULT_MODEL"
    ok "使用你提供的 key。"; return 0
  fi
  # L0：本机已领则复用（除非 --force）
  if [ "$FORCE" = 0 ] && [ -f "$STATE_FILE" ]; then
    local old t; old="$(cat "$STATE_FILE" 2>/dev/null)"; t="$(json_get "$old" token)"
    if [ -n "$t" ]; then
      TOKEN="$t"; [ -n "$BASE_URL" ] || BASE_URL="$(json_get "$old" base_url)"; [ -n "$MODEL" ] || MODEL="$(json_get "$old" model)"
      ok "复用本机已领的体验额度（--force 可重领）。"; return 0
    fi
  fi
  if [ "$DRY_RUN" = 1 ]; then
    TOKEN="sk-DRYRUN-xxxxxxxxxxxx"; [ -n "$BASE_URL" ] || BASE_URL="$DEFAULT_BASE_URL"; [ -n "$MODEL" ] || MODEL="$DEFAULT_MODEL"
    ok "[dry-run] 将向 ${ISSUER%/}/issue 领 \$${QUOTA_USD} 体验额度（此处用假 token）。"; return 0
  fi
  info "向 apiget 领取 \$${QUOTA_USD} 体验额度…"
  local resp; resp="$(issue_request)" || resp=""
  if [ -z "$resp" ]; then warn "发码服务暂不可达。可稍后重试，或网页自助领取：$REGISTER_URL"; exit 2; fi
  local okf; okf="$(json_get "$resp" ok)"
  if [ "$okf" != "true" ] && [ "$okf" != "1" ]; then
    local fb msg; fb="$(json_get "$resp" fallback_url)"; msg="$(json_get "$resp" message)"
    [ -n "$msg" ] && warn "$msg"; log "自助领取：${fb:-$REGISTER_URL}"; exit 2
  fi
  TOKEN="$(json_get "$resp" token)"; [ -n "$TOKEN" ] || { warn "服务未返回 token。自助领取：$REGISTER_URL"; exit 2; }
  [ -n "$BASE_URL" ] || BASE_URL="$(json_get "$resp" base_url)"; [ -n "$BASE_URL" ] || BASE_URL="$DEFAULT_BASE_URL"
  [ -n "$MODEL" ] || MODEL="$(json_get "$resp" model)"; [ -n "$MODEL" ] || MODEL="$DEFAULT_MODEL"
  local q; q="$(json_get "$resp" quota_usd)"; [ -n "$q" ] && QUOTA_USD="$q"
  save_state; ok "已领到 \$${QUOTA_USD} 体验额度。"
}

# 合并写入 settings.json 的 env 块（保留其它字段；先备份）。
# 关掉 CC 非必要外联（遥测/上报/非必要流量）—— 国内裸机防卡的关键。
apply_settings() {
  if [ "$DRY_RUN" = 1 ]; then
    info "[dry-run] 将写入 $SETTINGS_FILE 的 env："
    log "    ANTHROPIC_BASE_URL=$BASE_URL"
    log "    ANTHROPIC_AUTH_TOKEN=${TOKEN%%-*}-****"
    log "    ANTHROPIC_MODEL=$MODEL ; ANTHROPIC_DEFAULT_HAIKU_MODEL=$MODEL"
    log "    CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY=1 ; API_TIMEOUT_MS=600000"
    log "    DISABLE_TELEMETRY=1 ; DISABLE_ERROR_REPORTING=1 ; CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 ; DISABLE_AUTOUPDATER=1"
    return 0
  fi
  mkdir -p "$CLAUDE_DIR"
  if [ -f "$SETTINGS_FILE" ]; then mkdir -p "$BACKUP_DIR"; cp "$SETTINGS_FILE" "$BACKUP_DIR/settings.json.bak.$(date +%Y%m%d%H%M%S 2>/dev/null || echo bak)" 2>/dev/null || true; fi
  if has_cmd python3; then
    PK_F="$SETTINGS_FILE" PK_B="$BASE_URL" PK_T="$TOKEN" PK_M="$MODEL" python3 - <<'PY' || die "写入 settings.json 失败。"
import json, os
p=os.environ["PK_F"]
newenv={"ANTHROPIC_BASE_URL":os.environ["PK_B"],"ANTHROPIC_AUTH_TOKEN":os.environ["PK_T"],
        "ANTHROPIC_MODEL":os.environ["PK_M"],"ANTHROPIC_DEFAULT_HAIKU_MODEL":os.environ["PK_M"],
        "CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY":"1","API_TIMEOUT_MS":"600000","DISABLE_TELEMETRY":"1",
        "DISABLE_ERROR_REPORTING":"1","CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC":"1","DISABLE_AUTOUPDATER":"1"}
data={}
if os.path.exists(p):
    try: data=json.load(open(p)) or {}
    except Exception: data={}
if not isinstance(data,dict): data={}
env=data.get("env") if isinstance(data.get("env"),dict) else {}
env.update(newenv); data["env"]=env
json.dump(data, open(p,"w"), indent=2, ensure_ascii=False); open(p,"a").write("\n")
PY
  elif has_cmd jq; then
    local ne tmp; tmp="$(mktemp)"
    ne="$(jq -n --arg b "$BASE_URL" --arg t "$TOKEN" --arg m "$MODEL" '{ANTHROPIC_BASE_URL:$b,ANTHROPIC_AUTH_TOKEN:$t,ANTHROPIC_MODEL:$m,ANTHROPIC_DEFAULT_HAIKU_MODEL:$m,CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY:"1",API_TIMEOUT_MS:"600000",DISABLE_TELEMETRY:"1",DISABLE_ERROR_REPORTING:"1",CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC:"1",DISABLE_AUTOUPDATER:"1"}')"
    if [ -f "$SETTINGS_FILE" ]; then jq --argjson ne "$ne" '.env = ((.env // {}) + $ne)' "$SETTINGS_FILE" > "$tmp" || die "jq 合并 settings.json 失败（JSON 损坏？）。"
    else printf '%s' "$ne" | jq '{env: .}' > "$tmp"; fi
    mv "$tmp" "$SETTINGS_FILE"
  elif has_cmd node; then
    PK_F="$SETTINGS_FILE" PK_B="$BASE_URL" PK_T="$TOKEN" PK_M="$MODEL" node -e '
const fs=require("fs"),p=process.env.PK_F;
const ne={ANTHROPIC_BASE_URL:process.env.PK_B,ANTHROPIC_AUTH_TOKEN:process.env.PK_T,ANTHROPIC_MODEL:process.env.PK_M,ANTHROPIC_DEFAULT_HAIKU_MODEL:process.env.PK_M,CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY:"1",API_TIMEOUT_MS:"600000",DISABLE_TELEMETRY:"1",DISABLE_ERROR_REPORTING:"1",CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC:"1",DISABLE_AUTOUPDATER:"1"};
let d={}; try{d=JSON.parse(fs.readFileSync(p,"utf8"))||{}}catch(e){}
if(typeof d!=="object"||!d)d={};
d.env=Object.assign((typeof d.env==="object"&&d.env)?d.env:{},ne);
fs.writeFileSync(p, JSON.stringify(d,null,2)+"\n");
' || die "node 合并 settings.json 失败。"
  else
    [ -f "$SETTINGS_FILE" ] && die "已有 settings.json，需 python3 / jq / node 之一才能安全合并。请装其一后重试。"
    printf '{\n  "env": {\n    "ANTHROPIC_BASE_URL": "%s",\n    "ANTHROPIC_AUTH_TOKEN": "%s",\n    "ANTHROPIC_MODEL": "%s",\n    "ANTHROPIC_DEFAULT_HAIKU_MODEL": "%s",\n    "CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY": "1",\n    "API_TIMEOUT_MS": "600000",\n    "DISABLE_TELEMETRY": "1",\n    "DISABLE_ERROR_REPORTING": "1",\n    "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1",\n    "DISABLE_AUTOUPDATER": "1"\n  }\n}\n' "$BASE_URL" "$TOKEN" "$MODEL" "$MODEL" > "$SETTINGS_FILE"
  fi
  chmod 600 "$SETTINGS_FILE" 2>/dev/null || true
  ok "已写入 ${SETTINGS_FILE}（合并保留你的其它设置）。"
}

# 把 apiget 写进已装的 cc-switch（providers 表加一行 + 设为当前），让它成为可切换的正式 provider。
# cc-switch SQLite: ~/.cc-switch/cc-switch.db(providers 表, app_type=claude, settings_config=env JSON, is_current)
# + ~/.cc-switch/settings.json 的 current_provider_claude 覆盖 is_current —— 两处都设。用 python3 内置 sqlite3（无外部依赖）。
configure_cc_switch() {
  cp "$CC_SWITCH_DB" "${CC_SWITCH_DB}.powerkey-bak.$(date +%Y%m%d%H%M%S 2>/dev/null || echo bak)" 2>/dev/null || true
  PK_DB="$CC_SWITCH_DB" PK_SET="$CC_SWITCH_SETTINGS" PK_B="$BASE_URL" PK_T="$TOKEN" PK_M="$MODEL" python3 - <<'PY'
import sqlite3, json, os, time
db=os.environ["PK_DB"]; setp=os.environ["PK_SET"]
env={"ANTHROPIC_BASE_URL":os.environ["PK_B"],"ANTHROPIC_AUTH_TOKEN":os.environ["PK_T"],
     "ANTHROPIC_MODEL":os.environ["PK_M"],"ANTHROPIC_DEFAULT_HAIKU_MODEL":os.environ["PK_M"],
     "CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY":"1","API_TIMEOUT_MS":"600000","DISABLE_TELEMETRY":"1",
     "DISABLE_ERROR_REPORTING":"1","CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC":"1","DISABLE_AUTOUPDATER":"1"}
sc=json.dumps({"env":env}, ensure_ascii=False)
con=sqlite3.connect(db, timeout=5); cur=con.cursor()
cur.execute("SELECT name FROM sqlite_master WHERE type='table' AND name='providers'")
if not cur.fetchone(): raise SystemExit(3)
ts=int(time.time()*1000)
cur.execute("INSERT OR REPLACE INTO providers (id,app_type,name,settings_config,category,created_at,sort_index,meta,is_current) VALUES ('apiget','claude','API GET',?,?,?,?,?,1)", (sc,'custom',ts,0,'{}'))
cur.execute("UPDATE providers SET is_current=0 WHERE app_type='claude' AND id!='apiget'")
con.commit(); con.close()
s={}
if os.path.exists(setp):
    try: s=json.load(open(setp)) or {}
    except Exception: s={}
if not isinstance(s,dict): s={}
s["current_provider_claude"]="apiget"
os.makedirs(os.path.dirname(setp), exist_ok=True)
json.dump(s, open(setp,"w"), indent=2, ensure_ascii=False)
PY
  local rc=$?
  if [ "$rc" = 0 ]; then ok "已把 apiget 写进 cc-switch（provider + 设为当前）；重启 cc-switch 即可见可切换。"
  else warn "写 cc-switch 失败（rc=${rc}）；settings.json 已直写、claude 仍可用，可在 cc-switch 界面手动加 apiget。"; fi
}

# 检测到已装 cc-switch：脚本化配置它（加 apiget provider + 设为当前），而非只警告
handle_cc_switch() {
  { [ -e "$CC_SWITCH_DB" ] || [ -d "$CC_SWITCH_DIR" ] || [ -d "/Applications/CC Switch.app" ]; } || return 0
  info "检测到 cc-switch。"
  [ "$DRY_RUN" = 1 ] && { info "[dry-run] 将把 apiget 写进 cc-switch（provider + 设为当前）。"; return 0; }
  [ -f "$CC_SWITCH_DB" ] || { warn "cc-switch 已装但未见数据库（首次启动后才生成）；settings.json 已直写，启动 cc-switch 后可手动加 apiget。"; return 0; }
  has_cmd python3 || { warn "cc-switch 已装但无 python3，跳过写其 DB；settings.json 已直写，可在 cc-switch 界面手动加 apiget。"; return 0; }
  configure_cc_switch
}

print_ready() {
  log ""; ok "${C_BOLD}就绪！${C_RESET}"
  log "  额度：${C_BOLD}\$${QUOTA_USD}${C_RESET} 体验额度    默认模型：${C_BOLD}${MODEL}${C_RESET}    中转：${BASE_URL}"
  log ""
  log "  ${C_DIM}已配好 apiget 中转，${C_RESET}${C_BOLD}无需登录 Anthropic 账号（别走 /login）${C_RESET}${C_DIM}，直接对话即可。${C_RESET}"
  log "  ${C_DIM}进对话后输入${C_RESET} ${C_BOLD}/status${C_RESET} ${C_DIM}确认中转已生效；${C_RESET}${C_BOLD}/model${C_RESET} ${C_DIM}可切换网关在售的其它模型（GPT / Gemini 等，已开网关模型发现）。${C_RESET}"
  log "  ${C_DIM}没自动启动？运行${C_RESET} ${C_BOLD}claude${C_RESET}${C_DIM}（若提示找不到，新开终端或 export PATH=\$HOME/.local/bin:\$PATH）。${C_RESET}"
  log "  ${C_DIM}想长期用 / 要更多额度？注册：${C_RESET}${REGISTER_URL}"
  log ""
}

# 预置 ~/.claude.json 跳过首启向导（主题/信任目录/项目向导），让用户落地即对话。
# 读-改-合并（~/.claude.json 是 CC 大状态文件，绝不覆盖）；node（装完必有）优先，python3 兜底。
skip_onboarding() {
  [ "$DRY_RUN" = 1 ] && { info "[dry-run] 将标记 ~/.claude.json 跳过首启向导（主题/信任目录）。"; return 0; }
  local cj="${HOME}/.claude.json" cwd; cwd="$(pwd)"
  mkdir -p "$BACKUP_DIR"
  [ -f "$cj" ] && cp "$cj" "$BACKUP_DIR/claude.json.bak.$(date +%Y%m%d%H%M%S 2>/dev/null||echo bak)" 2>/dev/null || true
  if has_cmd node; then
    PK_CJ="$cj" PK_CWD="$cwd" node -e '
const fs=require("fs"),p=process.env.PK_CJ,cwd=process.env.PK_CWD;
let d={}; try{d=JSON.parse(fs.readFileSync(p,"utf8"))||{}}catch(e){}
if(typeof d!=="object"||!d)d={};
d.hasCompletedOnboarding=true;
if(typeof d.projects!=="object"||!d.projects)d.projects={};
const pr=(typeof d.projects[cwd]==="object"&&d.projects[cwd])?d.projects[cwd]:{};
pr.hasTrustDialogAccepted=true; pr.hasCompletedProjectOnboarding=true; d.projects[cwd]=pr;
fs.writeFileSync(p, JSON.stringify(d,null,2));
' 2>/dev/null && { ok "已跳过首启向导（主题/信任目录），落地即对话。"; return 0; }
  fi
  if has_cmd python3; then
    PK_CJ="$cj" PK_CWD="$cwd" python3 - <<'PY' 2>/dev/null && { ok "已跳过首启向导（主题/信任目录）。"; return 0; }
import json, os
p=os.environ["PK_CJ"]; cwd=os.environ["PK_CWD"]
d={}
if os.path.exists(p):
    try: d=json.load(open(p)) or {}
    except Exception: d={}
if not isinstance(d,dict): d={}
d["hasCompletedOnboarding"]=True
pj=d.get("projects") if isinstance(d.get("projects"),dict) else {}
pr=pj.get(cwd) if isinstance(pj.get(cwd),dict) else {}
pr["hasTrustDialogAccepted"]=True; pr["hasCompletedProjectOnboarding"]=True
pj[cwd]=pr; d["projects"]=pj
json.dump(d, open(p,"w"), indent=2, ensure_ascii=False)
PY
  fi
  warn "未能预置跳过首启向导（不影响使用，首次 claude 手动选一次主题/信任目录即可）。"
}

maybe_launch() {
  [ "$DRY_RUN" = 1 ] && { info "[dry-run] 交互终端下本会在此自动运行 claude。"; return 0; }
  local cb; cb="$(claude_path)"
  if [ "$NO_LAUNCH" = 1 ] || [ -z "$cb" ]; then log "运行 ${C_BOLD}claude${C_RESET} 开始体验。"; return 0; fi
  if is_interactive; then info "启动 claude …（Ctrl-C 退出）"; exec "$cb" </dev/tty
  else log "运行 ${C_BOLD}claude${C_RESET} 开始体验。"; fi
}

do_uninstall() {
  info "撤销 powerkey 的配置改动…"
  local restored=0 latest
  # ① settings.json：优先还原备份，否则移除 powerkey 写入的 env 键
  if [ -d "$BACKUP_DIR" ]; then
    latest="$(ls -1t "$BACKUP_DIR"/settings.json.bak.* 2>/dev/null | head -n1)"
    [ -n "${latest:-}" ] && [ -f "$latest" ] && cp "$latest" "$SETTINGS_FILE" && { ok "已还原 settings.json（来自 ${latest}）。"; restored=1; }
  fi
  if [ "$restored" = 0 ] && [ -f "$SETTINGS_FILE" ] && has_cmd python3; then
    PK_F="$SETTINGS_FILE" python3 - <<'PY' 2>/dev/null && ok "已移除 powerkey 写入的 env 键。"
import json, os
p=os.environ["PK_F"]
try: data=json.load(open(p)) or {}
except Exception: raise SystemExit(1)
env=data.get("env") or {}
for k in ("ANTHROPIC_BASE_URL","ANTHROPIC_AUTH_TOKEN","ANTHROPIC_MODEL","ANTHROPIC_DEFAULT_HAIKU_MODEL","CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY","API_TIMEOUT_MS","DISABLE_TELEMETRY","DISABLE_ERROR_REPORTING","CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC","DISABLE_AUTOUPDATER"):
    env.pop(k,None)
if env: data["env"]=env
else: data.pop("env",None)
json.dump(data, open(p,"w"), indent=2, ensure_ascii=False); open(p,"a").write("\n")
PY
  fi
  # ② ~/.claude.json：skip_onboarding 改过它——有备份就还原；无备份则留着无害的 onboarding 标记
  if [ -d "$BACKUP_DIR" ]; then
    local cjbak; cjbak="$(ls -1t "$BACKUP_DIR"/claude.json.bak.* 2>/dev/null | head -n1)"
    [ -n "${cjbak:-}" ] && [ -f "$cjbak" ] && cp "$cjbak" "${HOME}/.claude.json" 2>/dev/null && ok "已还原 ~/.claude.json（来自 ${cjbak}）。"
  fi
  # ③ shell 启动文件：删 ensure_local_bin_path 加的「# powerkey-path」块；反注释 detect_conflicting_env 注释掉的 ANTHROPIC_* 行
  local rc rc_cleaned=0
  for rc in "$HOME/.bashrc" "$HOME/.zshrc" "$HOME/.bash_profile" "$HOME/.zprofile" "$HOME/.profile"; do
    [ -f "$rc" ] || continue
    grep -qE 'powerkey-path|powerkey-disabled' "$rc" 2>/dev/null || continue
    if has_cmd python3; then
      PK_RC="$rc" python3 - <<'PY' 2>/dev/null && rc_cleaned=1
import os
p=os.environ["PK_RC"]
pfx="# powerkey-disabled: "
lines=open(p, encoding="utf-8", errors="replace").read().splitlines(keepends=True)
out=[]; i=0; n=len(lines)
while i < n:
    l=lines[i]
    if l.strip()=="# powerkey-path":
        if out and out[-1].strip()=="": out.pop()       # 去掉我们加的前置空行
        i+=1
        if i < n and ".local/bin" in lines[i]: i+=1     # 删紧跟其后的 PATH export
        continue
    if l.startswith(pfx):
        out.append(l[len(pfx):]); i+=1; continue          # 反注释：剥掉前缀还原原行
    out.append(l); i+=1
open(p,"w",encoding="utf-8").write("".join(out))
PY
    else
      # 无 python3 的 awk 兜底（POSIX，BSD/GNU 通吃）：删标记+其后的 PATH export、反注释 disabled 行
      awk '
        /^# powerkey-path$/ { m=1; next }
        m==1 { m=0; if (index($0,".local/bin")) next }
        { sub(/^# powerkey-disabled: /, ""); print }
      ' "$rc" > "$rc.pk.tmp" 2>/dev/null && mv "$rc.pk.tmp" "$rc" 2>/dev/null && rc_cleaned=1 || rm -f "$rc.pk.tmp" 2>/dev/null
    fi
  done
  [ "$rc_cleaned" = 1 ] && ok "已清理 shell 启动文件里的 powerkey 改动（# powerkey-path 块 + 反注释 ANTHROPIC_* 行）。"
  # ④ cc-switch（关键）：移除 apiget provider 行；若 current_provider_claude=apiget 则改回其它 claude provider（无则删键）。先备份 DB。
  if [ -f "$CC_SWITCH_DB" ] && has_cmd python3; then
    cp "$CC_SWITCH_DB" "${CC_SWITCH_DB}.powerkey-bak.$(date +%Y%m%d%H%M%S 2>/dev/null || echo bak)" 2>/dev/null || true
    PK_DB="$CC_SWITCH_DB" PK_SET="$CC_SWITCH_SETTINGS" python3 - <<'PY'
import sqlite3, json, os
db=os.environ["PK_DB"]; setp=os.environ["PK_SET"]
s={}
if os.path.exists(setp):
    try: s=json.load(open(setp)) or {}
    except Exception: s={}
    if not isinstance(s,dict): s={}
cur_is_apiget = (s.get("current_provider_claude")=="apiget")
other=None
con=sqlite3.connect(db, timeout=5); c=con.cursor()
c.execute("SELECT name FROM sqlite_master WHERE type='table' AND name='providers'")
if c.fetchone():
    c.execute("DELETE FROM providers WHERE id='apiget' AND app_type='claude'")
    if cur_is_apiget:
        row=c.execute("SELECT id FROM providers WHERE app_type='claude' ORDER BY sort_index, created_at LIMIT 1").fetchone()
        if row:
            other=row[0]
            c.execute("UPDATE providers SET is_current=CASE WHEN id=? THEN 1 ELSE 0 END WHERE app_type='claude'", (other,))
    con.commit()
con.close()
if cur_is_apiget:
    if other: s["current_provider_claude"]=other
    else: s.pop("current_provider_claude", None)
    d=os.path.dirname(setp)
    if d: os.makedirs(d, exist_ok=True)
    json.dump(s, open(setp,"w"), indent=2, ensure_ascii=False)
PY
    local crc=$?
    if [ "$crc" = 0 ]; then ok "已从 cc-switch 移除 apiget provider（如曾设为当前则已改回其它 provider）。"
    else warn "清理 cc-switch 失败（rc=${crc}）；可在 cc-switch 界面手动移除 apiget。"; fi
  fi
  rm -f "$STATE_FILE" 2>/dev/null || true
  ok "完成。（未卸载 Claude Code 本身；备份在 ${BACKUP_DIR}）"
}

# ----------------------------------------------------------------------------
main() {
  print_banner
  [ "$DO_UNINSTALL" = 1 ] && { do_uninstall; exit 0; }
  preflight
  detect_conflicting_env
  ensure_claude_code
  obtain_token
  apply_settings
  handle_cc_switch
  skip_onboarding
  print_ready
  maybe_launch
}

# 允许测试时 source 只加载函数（不执行）：POWERKEY_SOURCE_ONLY=1
[ "${POWERKEY_SOURCE_ONLY:-0}" = "1" ] || main
