# magpie-fpk

把 [yetone/magpie](https://github.com/yetone/magpie) 打成**飞牛 fnOS（fnOS）应用中心的 fpk 安装包**，并跟随上游自动出包。

- 开发者（上游）：[yetone](https://github.com/yetone)
- 打包者（本 fork）：Mickey · [mickeyttsc/magpie-fpk](https://github.com/mickeyttsc/magpie-fpk)

## magpie 是什么

给所有 AI 编程 Agent 统一选模型：Claude Code 跑 Kimi、Codex 跑 DeepSeek、Gemini CLI 跑 GLM，一个界面里切。背后是跑在本机的网关，同时兼容 OpenAI / Anthropic / Gemini 三种协议并互相转换。

装好之后：

| 用途 | 地址 |
|---|---|
| Web 管理界面 | `http://<NAS-IP>:3430`（桌面图标直达，无需输入密钥） |
| 网关（OpenAI 兼容） | `http://<NAS-IP>:3425` `/v1` |
| 网关（Anthropic / Gemini） | 同端口 `3425`，按各自协议路径调用 |

客户端用的网关 key 在界面 **Gateway** 页逐个创建、可随时吊销，不要共用。

## 安装

飞牛应用中心 → 手动安装 → 选择下面任一个 fpk：

| 渠道 | 地址 | 说明 |
|---|---|---|
| 滚动最新版 | <https://github.com/mickeyttsc/magpie-fpk/releases/download/latest/magpie.fpk> | 每次构建覆盖，永远最新 |
| 固定版本 | [Releases](https://github.com/mickeyttsc/magpie-fpk/releases) 页附件 `magpie-<版本>.fpk` | 可回滚、可追溯 |

产物文件名：`magpie-<上游版本>-<封装迭代号>.fpk`，如 `magpie-0.1.1318-1.fpk`。
版本号规则：上游版本变化 → 迭代号重置为 `-1`；仅封装层改动 → 迭代号 +1。

## 与上游的差异（只动封装层）

| 项 | 上游原版 | 本包 |
|---|---|---|
| 运行形态 | 菜单栏 App / TUI / CLI / Docker | 应用中心 fpk，常驻后台服务 + 桌面 iframe 图标 |
| Web 界面 | 每次启动随机 key，需要手动粘一次 | key 固化进图标入口 URL，点图标直达 |
| 数据位置 | `~/.config/magpie` 等 | `/vol<N>/@apphome/magpie/`（升级/重装不丢） |
| 主程序 | `magpie-cli-linux-amd64` | 同一个二进制，sha256 固定值校验 |

主程序**不做任何修改**：包内 `bin/magpie` 就是上游 release 产物，构建时按 `config/upstream/magpie.env` 里的 sha256 逐个字节校验。

## 构建（本地）

```bash
bash scripts/build-fpk.sh dist
bash scripts/verify-fpk-gates.sh dist/magpie-<版本>.fpk
python3 scripts/validate-gh-workflows.py .github/workflows   # 改 workflow 后先跑
```

想用自己的 Web 界面 key（默认用 `config/web-key.env`）：

```bash
MAGPIE_WEB_KEY=my-own-key-2026 bash scripts/build-fpk.sh dist
```

⚠️ Release 附件是公开下载的，包内 `ui/config` 里的 key 谁都能解包读出来，**不要把它当能对公网暴露的秘密**。需要真正的访问控制，请在外层反代上做认证。

## 自动跟随上游

`.github/workflows/auto-update.yml` 长驻轮询上游 release（每 5 分钟一次 tick，跑满 5.5 小时后自续跑），发现新版本就 bump `config/upstream/magpie.env` 与 `manifest` 的版本号并提交，随后触发 `build.yml` 构建与发布。全链路无人工断点。

维护细节见 [MAINTAINING.md](MAINTAINING.md)。
