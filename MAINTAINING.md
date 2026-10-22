# magpie-fpk · 维护文档

> 面向维护者（构建 / 发布 / 门禁）。用户向说明见 [README.md](README.md)。

## 版本号规则

`<上游版本>-<封装迭代号>`，如 `0.1.1318-1`。上游版本变化时迭代号归 `1`；仅封装层变化时迭代号 +1。

## 上游锚点

- [yetone/magpie](https://github.com/yetone/magpie) → `config/upstream/magpie.env`（`MAGPIE_VERSION` + `MAGPIE_SHA256`，由 auto-update 自动更新）
- 载荷资产：`magpie-cli-linux-amd64`（静态链接 Go 二进制，零运行时依赖，`ldd` 必须报 `not a dynamic executable`）
- 图标：`assets/icon_512.png`，取自上游 `build/darwin/magpie.icns` 里的 `ic10`（1024×1024 PNG 块），按其 alpha 边界等比裁到 512。**不要用 `build/icon/magpie.svg`** —— 那是菜单栏 tray 标记，没有圆角方块底，当 App 图标会显得单薄。

## 本地构建与验证

```bash
bash scripts/build-fpk.sh dist
bash scripts/verify-fpk-gates.sh dist/magpie-<版本>.fpk
python3 scripts/validate-gh-workflows.py .github/workflows   # 改 workflow 后先跑
bash scripts/scan-secrets.sh --all                            # 提交前自查
```

## 发布

- 稳定版：tag `v<版本>`（如 `v0.1.1318-1`），附件 `magpie-<版本>.fpk`
- 滚动版：tag `latest`（prerelease），附件 `magpie.fpk`

`build.yml` 是 Release 的唯一归属方；`auto-update.yml` 只 bump 不发布。

## 封装层的三个关键契约（改前必读）

### 1. Web 界面安全访问契约

- 安装向导（`wizard/install`）支持用户自设 Web 访问口令（留空则首次运行自动生成随机口令）。
- 图标入口 `app/ui/config` 的 `url` 为 `/`。用户首次打开桌面图标时在登录框粘贴口令完成登录，浏览器会自动保存 400 天 Cookie，后续无需反复输入。
- 口令及完整直达链接同时落盘到应用数据目录的 `access-info.txt` 与 `web.key`。

### 2. 用户数据必须在包外

`HOME` 与 `XDG_CONFIG_HOME` / `XDG_CACHE_HOME` / `XDG_DATA_HOME` / `XDG_STATE_HOME` 全部重定向到 `$TRIM_PKGHOME`（`/vol<N>/@apphome/magpie/`）。magpie 把供应商、密钥、订阅登录态都写在这些路径下，不重定向就会落到系统 home，升级即丢。

`web.key` 落在 `$TRIM_PKGVAR/web.key`，属 `$TRIM_PKGVAR`（`/vol<N>/@appdata/magpie/`），与 `access-info.txt`、日志同级。

### 3. 端口与就绪判据

- `3430` = Web 界面（manifest `service_port`，也是桌面图标 iframe 的端口）
- `3425` = 网关（`MAGPIE_ADDR=0.0.0.0:3425`），给 Agent / 客户端调用

就绪判据**不能**用裸 `curl /`：不带 key 恒 401。`cmd/main` 的 `service_ready()` 打的是 `/?k=<key>`，接受 200 / 303（首次 303 下发 cookie，之后 200）。

## 本机构建 → 装机 → 归档

1. 抬 `manifest` 的 `version`，写 `changelog`（只写用户能感知的变化）。
2. `bash scripts/build-fpk.sh dist`，末尾自动跑门禁。
3. 包先落到用户可见路径再走应用中心：

```bash
# 先落到「应用中心能读到、你也有权限」的目录（示例，换成你自己的下载/备份目录）：
cp dist/magpie-<ver>.fpk "<你的可写目录>/"
# 若该目录属主机用户而非应用用户，应用用户不可写 → 走 SSH sudo cp + chown
```

4. 升级走应用中心守护进程 RPC（`scripts/upgrade-local.sh` 是本机现成脚本）：

```bash
bash scripts/upgrade-local.sh "<你的可写目录>/magpie-<ver>.fpk"
```

⚠️ `appcenter-cli install-fpk` 对**已装**应用静默短路（退出码 0，什么都不做）；`install-local` 是卸载重装，会毁数据。升级只走 RPC。

5. 验三样：`appcenter-cli status magpie` = running；`ss -ltn` 两个端口都在；`/?k=<key>` 返 303/200 且 `/v1/models` 本机 200、局域网无 key 401。

## 开发者 / 打包者

- 开发者（上游）：yetone
- 打包者：Mickey（[mickeyttsc/magpie-fpk](https://github.com/mickeyttsc/magpie-fpk)）
