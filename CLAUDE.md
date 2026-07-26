# PowerKey 仓库上下文

> 本文件是本仓对所有编码代理共用的本地入口；`AGENTS.md` 以符号链接指向本文件，避免两套规则漂移。

## 起步顺序

1. 先读 `../apiget-ops/CLAUDE.md`。
2. 再读 `../apiget-ops/docs/ops/agent-lessons.md` 与 `../apiget-ops/memory/project_current_system_state.md`；入口、issuer 和部署现状只在 state 维护。
3. 按任务读取 README、安装脚本、`test/`、`server/` 和工作流。

## 仓库边界与安全

- 本仓负责 macOS/Linux Bash 安装器、Windows PowerShell 安装器及薄 issuer；API GET 网关和系统运维属于兄弟仓。
- 凭据只走 `apiget-ops` 的 SOPS+age；不读取或提交真实 `.env`、umbrella token、试用 key 或用户配置。
- 常规验证只准用 `test/test_e2e.sh` 的 mock issuer、PowerShell fixture 和 Go `httptest`。不得请求真实 `/issue`、运行 live-smoke、安装到真实用户环境或触发任何 provider 请求。
- 真实 issuer、provider、部署或用户配置变更必须由用户对本次操作明确授权。
- Bash 中变量紧邻中文或其他多字节文本时一律写 `${name}`；`bash -n` 抓不到 locale 问题，必须保留 `LC_ALL=C` 测试。

## 验证

- Bash：`bash -n install.sh`、`bash test/test_install.sh`、`LC_ALL=C bash test/test_install.sh`、`bash test/test_e2e.sh`。
- PowerShell（有 `pwsh` 时）：解析 `install.ps1`，再跑 `pwsh ./test/test_install.ps1`；Windows 行为以 CI workflow 为准。
- Issuer：在 `server/` 跑 `go test ./...`、`go vet ./...` 和 `CGO_ENABLED=0 go build ./...`；测试必须保持 mock/httptest。
- 收尾运行 `git diff --check` 和 `git status --short --branch`。
