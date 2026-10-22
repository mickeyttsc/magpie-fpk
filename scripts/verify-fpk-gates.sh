#!/usr/bin/env bash
# FPK 硬门禁（CI 与本机共用同一份，避免两处漂移）
# 用法：bash scripts/verify-fpk-gates.sh <fpk 路径>
# 任何一条不过 → exit 1（构建不发版）。
set -euo pipefail

FPK="${1:?用法: verify-fpk-gates.sh <fpk>}"
fail() { echo "::error::$*"; exit 1; }

[ -f "$FPK" ] || fail "找不到 $FPK"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ── 0. 门禁自检：证明 grep 通路是活的（防管道/写法坏掉后恒真恒假）──
printf 'SENTINEL_CANARY\n' > "$TMP/canary"
grep -q SENTINEL_CANARY "$TMP/canary" || fail "门禁自检失败：grep 通路异常"

# ── 1. 外层结构 ──
tar tzf "$FPK" > "$TMP/outer.list" || fail "外层不是有效 tar.gz"
for f in manifest manifest.checksum cmd config wizard app.tgz ICON.PNG ICON_256.PNG; do
    grep -qE "^${f}(/|$)" "$TMP/outer.list" || fail "外层缺条目: $f"
done

# ── 2. checksum 自洽（manifest.checksum 与 manifest 字段都要等于 md5(app.tgz)）──
tar xzf "$FPK" -C "$TMP" app.tgz manifest manifest.checksum
SUM_ACT="$(md5sum "$TMP/app.tgz" | awk '{print $1}')"
SUM_FILE="$(tr -d ' \r\n' < "$TMP/manifest.checksum")"
[ "$SUM_FILE" = "$SUM_ACT" ] || fail "manifest.checksum($SUM_FILE) != md5(app.tgz)($SUM_ACT)"
SUM_MF="$(grep '^checksum' "$TMP/manifest" | awk -F'=' '{print $2}' | tr -d ' ')"
[ "$SUM_MF" = "$SUM_ACT" ] || fail "manifest 的 checksum 字段($SUM_MF) != md5(app.tgz)($SUM_ACT)"

# ── 3. 内层结构 ──
tar tzf "$TMP/app.tgz" > "$TMP/inner.list"
FIRST="$(head -1 "$TMP/inner.list")"
case "$FIRST" in
    app|app/*|./*|.|'') fail "内层 app.tgz 首条 '$FIRST' 带 app/ 或 ./ 前缀（装完路径全错位）" ;;
esac
for f in bin/magpie ui/config ui/images/icon_64.png ui/images/icon_256.png; do
    grep -qE "^${f}$" "$TMP/inner.list" || fail "内层缺条目: $f"
done
# 不许把运行期数据打进包（会覆盖用户数据 / 泄露密钥）
for bad in web.key access-info.txt magpie.log magpie.pid providers.json settings.json; do
    grep -qE "(^|/)${bad}$" "$TMP/inner.list" && fail "包内混入运行期文件: $bad"
done

tar xzf "$TMP/app.tgz" -C "$TMP" bin/magpie ui/config

# ── 4. 二进制：可执行 + 静态链接 + 版本自检 ──
[ -x "$TMP/bin/magpie" ] || fail "bin/magpie 不可执行"
chmod +x "$TMP/bin/magpie"
if command -v ldd >/dev/null 2>&1; then
    LDD_OUT="$(ldd "$TMP/bin/magpie" 2>&1 || true)"
    case "$LDD_OUT" in
        *"not a dynamic executable"*|*"not found"*|"") : ;;
        *) fail "bin/magpie 存在动态依赖（fnOS 上可能缺库）" ;;
    esac
fi
BIN_OUT="$("$TMP/bin/magpie" --version 2>&1 | head -1 || true)"
MF_VER="$(grep '^version' "$TMP/manifest" | awk -F'=' '{print $2}' | tr -d ' ')"
printf '%s' "$MF_VER" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+-[0-9]+$' || fail "manifest version 格式非法: $MF_VER"
UP_VER="${MF_VER%-*}"
case "$BIN_OUT" in
    *"$UP_VER"*) : ;;
    *) fail "二进制自检失败：'$BIN_OUT' 未包含上游版本 $UP_VER" ;;
esac

# ── 5. manifest 字段完整性 / 身份 / 无重复 ──
DUP="$(awk -F= '/^[a-z_]+[[:space:]]*=/{gsub(/[[:space:]]/,"",$1); print $1}' "$TMP/manifest" | sort | uniq -d)"
[ -z "$DUP" ] || fail "manifest 存在重复字段: $DUP"
for f in appname version display_name platform source maintainer maintainer_url \
         distributor distributor_url desktop_uidir desktop_applaunchname service_port ctl_stop; do
    grep -qE "^${f}[[:space:]]*=" "$TMP/manifest" || fail "manifest 缺必需字段: $f"
done
getf() { grep -E "^$1[[:space:]]*=" "$TMP/manifest" | head -1 | sed 's/.*=[[:space:]]*//' | tr -d '"' | tr -d ' '; }
[ "$(getf appname)" = "magpie" ] || fail "appname 必须为 magpie，实际=$(getf appname)"
[ "$(getf maintainer)" = "yetone" ] || fail "maintainer(开发者) 必须为上游 yetone，实际=$(getf maintainer)"
[ "$(getf distributor)" = "Mickey" ] || fail "distributor(打包者) 必须为 Mickey，实际=$(getf distributor)"
[ "$(getf desktop_applaunchname)" = "magpie.main" ] || fail "desktop_applaunchname 必须为 magpie.main"
[ "$(getf service_port)" = "3430" ] || fail "service_port 必须为 3430，实际=$(getf service_port)"
[ "$(getf platform)" = "x86" ] || fail "platform 必须为 x86"
[ "$(getf ctl_stop)" = "true" ] || fail "ctl_stop 必须为 true"

# ── 6. ui/config 形态（protocol 显式、port 与 service_port 一致、iframe 小窗）──
grep -q '"protocol": "http"' "$TMP/ui/config" || fail "ui/config 的 protocol 未显式声明 http"
grep -q '"port": "3430"' "$TMP/ui/config" || fail "ui/config 的 port 与 service_port(3430) 不一致"
grep -q '"type": "iframe"' "$TMP/ui/config" || fail "ui/config 不是 iframe（桌面图标会跳浏览器而不是小窗）"
grep -q '"allUsers": true' "$TMP/ui/config" || fail "ui/config 未设 allUsers:true（会变成仅管理员可见）"
grep -q '"icon": "images/icon_{0}.png"' "$TMP/ui/config" || fail "ui/config 图标槽位写法被改坏"

# ── 7. cmd/main 守护契约 ──
tar xzf "$FPK" -C "$TMP" cmd/main
grep -q '_resolve_trim_paths' "$TMP/cmd/main" || fail "cmd/main 缺 TRIM 路径解析"
grep -qE 'pkill -f "\$BIN"' "$TMP/cmd/main" || fail "cmd/main 的 pkill 未路径锚定（需 pkill -f \"\$BIN\"）"
grep -q 'MAGPIE_WEB_KEY' "$TMP/cmd/main" || fail "cmd/main 未设置 MAGPIE_WEB_KEY（每次启动会换 key）"
grep -q 'KEY_FILE=' "$TMP/cmd/main" || fail "cmd/main 缺 Web 密钥持久化文件"
grep -q 'XDG_CONFIG_HOME=' "$TMP/cmd/main" || fail "cmd/main 未重定向 XDG_CONFIG_HOME（配置会落到系统 home）"
grep -q 'MAGPIE_ADDR=' "$TMP/cmd/main" || fail "cmd/main 未设置 MAGPIE_ADDR（网关端口不可控）"
grep -qE '"0\.0\.0\.0:\$\{GW_PORT\}"|GW_PORT=' "$TMP/cmd/main" || fail "cmd/main 缺网关端口配置"
grep -q '3425' "$TMP/cmd/main" || fail "cmd/main 缺网关端口 3425"

# ── 8. 向导契约 ──
tar xzf "$FPK" -C "$TMP" wizard/install
python3 -c "import json,sys; json.load(open('$TMP/wizard/install'))" || fail "wizard/install 不是合法 JSON"
grep -q 'wizard_web_key' "$TMP/wizard/install" || fail "wizard/install 缺少 wizard_web_key 自定义口令输入项"

# ── 9. 图标分辨率（icon_64 槽位实际是 512，塞小图会发虚）──
tar xzf "$TMP/app.tgz" -C "$TMP" ui/images/icon_64.png 2>/dev/null || true
ICON_SIZE="$(python3 - "$TMP/ui/images/icon_64.png" <<'PY'
import struct, sys
with open(sys.argv[1], 'rb') as f:
    head = f.read(24)
if head[:8] != b'\x89PNG\r\n\x1a\n':
    print('notpng'); raise SystemExit
w, h = struct.unpack('>II', head[16:24])
print(f'{w}x{h}')
PY
)"
[ "$ICON_SIZE" = "512x512" ] || fail "icon_64.png 不是 512x512（实际 $ICON_SIZE）"


echo "✅ 全部门禁通过: $FPK"
