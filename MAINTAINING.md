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

### 1. 点图标必须免登录

上游 `magpie web` 对**没有 cookie 的浏览器一律 401**，落到「Paste the key」登录页。而 fnOS 桌面图标打开的是 PG 表 `trim_sac.entry` 里 `url.path` 这一段——该值**只在安装/升级时从包内 `app/ui/config` 解析一次**。

实测两条硬事实：

- 改已装实例的 `ui/config` 并重启应用，**不会**刷新 PG（PG 里仍是旧 path）；
- install/upgrade 回调以**应用用户**身份运行（实测 `uid=937 user=magpie`），没有 root，**改不了 PG**。

所以唯一可持续做法是：把 key 写死在包内 `ui/config` 的 `url`（`/?k=xxx`），运行期服的 key 也服从它。`cmd/main` 的 `ensure_key()` 先 `grep ui/config` 的 `?k=`，再退回 `web.key`；`build-fpk.sh` 构建时把同一个 key 同时注入 `ui/config` 与 `cmd/main` 的 `DEFAULT_WEB_KEY`；`verify-fpk-gates.sh` 第 7b 项断言两者逐字符一致，不一致直接构建失败。

⚠️ `wizard/install` 里**不要**再放自定义 key 输入框：用户填的值会与图标入口的 `?k=` 打架（门禁第 8 项会拒）。

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
