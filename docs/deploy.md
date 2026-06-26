# powerkey 部署 runbook

powerkey = 客户端脚本 + 发码薄服务 + 两项 apiget 侧配置。
客户端用 `--key` 可独立跑（教程派发场景）；**自动发码**需要下面的薄服务。

## 0. 组件一览
- 客户端 `install.sh` / `install.ps1` —— 托管在 `get.apiget.cc`，用户 `curl … | bash`。
- 发码薄服务 `server/`（powerkey-issuer）—— 部署在 SG 原点，docker，单文件 Go。
- apiget 侧：① 一个「体验」总账号 ② deepseek-v4-pro 走 OpenRouter 优先（可选）。

## 1. 准备「体验」总账号  ⚠ 需用户决策：新建专用 vs 复用
建议**新建专用** trial 账号（隔离额度 / 审计）。取它的**系统访问令牌 access_token** + **user id**
（后台 API 双头 `Authorization: <access_token>` + `New-Api-User: <id>`，见
`apiget-ops/memory/reference_gateway_admin_auth_and_cred_gap.md`）。凭据存 SOPS，勿明文。
- 该账号可用分组需含 `deepseek-v4-pro`（default 组）。
- 它名下会被铸出大量子 token（每个试用一个：$2 / 不限时 / 不锁模型）；
  注意 `GetMaxUserTokens` 上限，必要时调高。

## 2. 部署发码薄服务
```bash
cd server
cp .env.example .env        # 填 UMBRELLA_ACCESS_TOKEN / UMBRELLA_USER_ID（经 SOPS）
docker build -t powerkey-issuer .
docker run -d --name powerkey-issuer \
  --network <apiget 内网>  -p 127.0.0.1:8800:8800 \
  --env-file .env  -v powerkey-data:/data  powerkey-issuer
```
- `APIGET_ADMIN_BASE` 走 docker 内网 `http://new-api:3000` 最稳。
- 冒烟：`curl -s -XPOST localhost:8800/issue -d '{"fingerprint":"smoke-xxxx","source":"powerkey"}'`
  应返回 `{"ok":true,"token":"sk-…",…}`；用后**作废该测试 token**。
- ⚠ 部署时**核实 apiget 返回体形状**（`/api/token/search` 的 `data.items[]`、
  `/api/token/:id/key` 的 `data.key`）—— issuer 解析已防御，但需实测一次确认。

## 3. 托管客户端脚本 @ get.apiget.cc
DNS `get A → BWH 93.179.125.179`（alidns profile `shengli`）。BWH 入口 Caddy 加站点块：
```
get.apiget.cc {
  handle /issue* { reverse_proxy <到 SG issuer 的隧道/内网>:8800 }
  handle        { root * /srv/powerkey; rewrite * /install.sh; file_server }
}
```
`scp install.sh` 到 BWH `/srv/powerkey/install.sh`。验证 `curl -fsSL https://get.apiget.cc | head`。
（同 duowenapi / about 静态站套路。）Windows 用户：另放 `install.ps1`，文档给 `irm https://get.apiget.cc/install.ps1 | iex`。

## 4.（可选）deepseek-v4-pro 经 OpenRouter 优先
按「便宜模型从 OR 先调」：给 apiget 配 OR 渠道 + `model_mapping deepseek-v4-pro → deepseek/deepseek-v4-pro`
（OR 已确认有该精确模型，$0.435/$0.87 per Mtok）。属 model-routing / ops 域的网关配置，与 powerkey 解耦。

## 5. 上线前 smoke（逐项过）
- [ ] issuer `/issue` 真实铸出可用 token（冒烟后作废）
- [ ] `curl get.apiget.cc | bash -s -- --dry-run` 在干净 mac/linux 跑通
- [ ] 真机：装 CC → 领码 → 写 settings.json → `claude` 首条对话 `deepseek-v4-pro` 成功（**含一次工具调用** —— CC 围绕 Claude 工具调用设计，非 Claude 模型要实测）
- [ ] `/model` 能列出网关模型并切换（已开 `CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY`）
- [ ] `deepseek-v4-pro` prod 渠道健康（别重蹈 Claude 失效）
- [ ] 「切 Claude 试用」想可用，则需有可用 claude 账号（当前 Sub2API claude 全失效）

## 凭据卫生
- issuer 的 `UMBRELLA_*` 经 SOPS 注入，绝不入库 / 不回显。
- issuer store 只存 token **id** 不存 key；复用时按 id 重新取 key —— 服务端无 key 静置。
- 日志掩码（不打印完整 key / 原始指纹）。
