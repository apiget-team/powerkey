# powerkey

**一键装好 [Claude Code](https://code.claude.com/docs) 并接上 [apiget.cc](https://apiget.cc) —— 复制一条命令，几分钟后直接能聊。**

给想体验 Claude Code + 顶级大模型、却卡在「装 CLI / 注册 / 充值 / 配中转」门槛的新手；也给老手当「中转挂了一键救急 / 切换」的工具。它是把人引到 apiget 的获客入口：教程/推广里带上你的链接和 key，读者跑一条命令就上手。

```bash
curl -fsSL https://get.apiget.cc | bash
```

这条命令会：

1. 探测环境，**装 / 升级 Claude Code 到最新**（用官方安装器）
2. 领 **$2 体验额度**（或用你拿到的 key：`--key <token>`）
3. 写入 `~/.claude/settings.json` 的 `env` 块（**合并不覆盖**，并自动清理会冲突的旧 `ANTHROPIC_*` 环境变量）
4. 默认模型 **DeepSeek V4 Pro**（不贵又好用，$2 够玩很久）；想试 Claude / Gemini，对话里输入 `/model` 切换
5. 交互终端下**直接拉起 `claude`**

> 平台：v1 支持 **macOS / Linux**（`install.sh`）。Windows（`install.ps1`，PowerShell）紧随。

## 用法

```bash
# 标准
curl -fsSL https://get.apiget.cc | bash

# 带参数（注意 -s --）
curl -fsSL https://get.apiget.cc | bash -s -- [options]
```

| 选项 | 说明 |
|---|---|
| `--dry-run` | 只演示，不安装、不写配置、不领真 key |
| `--uninstall` | 撤销 powerkey 的配置改动（还原 `settings.json` 备份、删本地状态） |
| `--no-launch` | 装完不自动拉起 `claude` |
| `--force` | 忽略本机已领记录，强制重新领取 |
| `--cn` | 强制走国内镜像源装 Claude Code（不连 github/claude.ai） |
| `--key TOKEN` | 直接用这个 apiget key（教程派发场景），跳过自动发码 |
| `--base-url URL` | 覆盖 apiget API base（默认 `https://api.apiget.cc`） |
| `--issuer URL` | 覆盖发码服务端点（默认 `https://get.apiget.cc`） |
| `--ref CODE` | 推广 / 分销归因码（带进发码请求，归功到你名下） |
| `--source NAME` | 来源标签（默认 `powerkey`） |

## 它做了什么（设计）

- **配置写进 `~/.claude/settings.json` 的 `env` 块**，不污染 shell 环境。写的键：`ANTHROPIC_BASE_URL`、`ANTHROPIC_AUTH_TOKEN`、`ANTHROPIC_MODEL`、`ANTHROPIC_DEFAULT_HAIKU_MODEL`、`CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY=1`、`DISABLE_TELEMETRY=1`。
- **合并不覆盖**：保留你 `settings.json` 里的其它字段；写前先备份到 `~/.powerkey/backups/`。
- **清理冲突**：shell 里导出的 `ANTHROPIC_*` 优先级高于 `settings.json`，会让配置不生效 —— 脚本会探测启动文件里的旧导出并（交互确认后）注释掉。
- **默认模型由发码服务下发**：客户端写服务返回的 `model`，所以以后想把默认模型换成别的（如 Gemini），改服务端一处即可，不用重发脚本。
- **防刷三层**：L0 本机已领则复用（不重领）/ L1 指纹 + IP 正常则零交互自动发 / L2 异常降级到网页自助领（绝不裸拒）。机器指纹是**本地哈希**，不外传原始标识。
- **cc-switch 共存**：检测到 cc-switch 时仍直接写 `settings.json`（CC 实际读这份，cc-switch 切换时也写它），并提示：若之后在 cc-switch 里切 provider 会覆盖本配置。

## 默认模型 & 切换

默认 `deepseek-v4-pro`。想用更强的：进入 `claude` 后输入 `/model`，因为脚本开了 `CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY`，会列出 apiget 网关上的全部模型（Claude / Gemini / GPT…）任你切。

## 国内网络（不挂梯子）

脚本与发码都走 `get.apiget.cc`（国内直连）。装 Claude Code 时：官方源（claude.ai）拉不动会**自动回退国内镜像 npmmirror**；也可显式 `--cn` 直接走镜像。没有 Node 会从 npmmirror 下一个（免 sudo、免 GitHub）。并默认关掉 Claude Code 的非必要外联（遥测/上报/非必要流量），避免国内裸机卡在够不到的地址。

```bash
curl -fsSL https://get.apiget.cc | bash -s -- --cn      # 强制国内镜像
```

## cc-switch

powerkey **不安装 cc-switch**（它直接写 `~/.claude/settings.json`，不装也能用）。但**若检测到你已装 cc-switch，会自动把 apiget 写进去**：在它的 providers 里加一个「API GET」并**设为当前**（同时直写 `settings.json`，立即可用）。重启 cc-switch 就能在列表里看到、随时切换，也不会被下次切换覆盖。

机制：写 cc-switch 的 SQLite（`~/.cc-switch/cc-switch.db` 的 `providers` 表）+ `~/.cc-switch/settings.json` 的 `current_provider_claude`，用 `python3` 内置 sqlite3（无外部依赖）。写前自动备份其 DB。Windows 上若无 python 则回退为只写 `settings.json` + 提示手动添加。

## 安全

- 全开源，走 HTTPS；`--dry-run` 可先看清楚再跑。
- `~/.claude/settings.json` 与本地状态文件均 `chmod 600`。
- 仓库**不含任何明文凭据**。派发的 key 是 apiget 网关 key，不是你的 Anthropic 账号。
- 无 telemetry / 不回传任何东西（脚本本身），并给 CC 关掉非必要流量。

## 开发 / 测试

```bash
bash -n install.sh            # 语法检查
bash test/test_install.sh     # 单元测试（配置逻辑，含 LC_ALL=C 健壮性）
bash test/test_e2e.sh         # 端到端（mock 发码 + 假 claude，不触真网）
bash install.sh --dry-run     # 本机演示
```

CI 在 GitHub Actions 上跨 Linux + macOS 跑上述测试（见 `.github/workflows/`）。

## 发码服务（issuer）

客户端向 `--issuer`（默认 `https://get.apiget.cc`）发 `POST /issue` 领取试用 key。薄服务的契约、实现与部署见 [`server/`](server/) 与 [`docs/deploy.md`](docs/deploy.md)。

## 致谢

本项目的安装/配置骨架衍生自以下 **MIT** 开源项目，详见 [`NOTICE`](NOTICE)：

- [QuantumNous/new-api-docs](https://github.com/QuantumNous/new-api-docs) — new-api 网关的 Claude Code 配置脚本（TTY/host/env 处理、跨平台 `.sh`/`.ps1` 骨架）
- [UfoMiao/zcf](https://github.com/UfoMiao/zcf) · [farion1231/cc-switch](https://github.com/farion1231/cc-switch) — `settings.json` 形态参考

## 许可

[MIT](LICENSE)。
