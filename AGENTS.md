# AGENTS.md — Powerkey

独立仓 `apiget-team/powerkey`，接受分支 `main`。产品包含 Bash/PowerShell 安装器与薄 issuer；产品自身支持的客户端和云工作台使用 Codex 是两个独立范围。

- 读取 `/srv/workbench/AGENTS.md`；业务运行记录从 control 登记的 ops reference 按需查阅。只在独立任务工作树修改。
- 常规验证：`bash -n install.sh`、`bash test/test_install.sh`、`LC_ALL=C bash test/test_install.sh`、`bash test/test_e2e.sh`；使用脚本自己的 mock issuer。
- Issuer 在 `server/` 按其 `go.mod` 选择 Go，使用 `go test ./...`、`go vet ./...` 和 `CGO_ENABLED=0 go build ./...`。PowerShell 用 fixture 与 CI 验证。
- 安装器测试不得改云开发用户的真实 CLI 配置或领取真实 key；需要真实装机/发码时按任务已有授权、目标与恢复方案操作。
- Bash 变量紧邻多字节文本使用 `${name}`，保留 `LC_ALL=C` 回归。凭据、试用 key、真实 .env 和用户配置不入库、不进输出。
- 静态下载入口仍存在的记录不能证明 issuer 可用。本次源码迁入不重开 issuer，不安装 Claude，也不维护双 CLI 治理规则。
