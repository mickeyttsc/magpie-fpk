#!/bin/bash
# 把 Magpie 的 Web 界面 key 同步进 fnOS 的桌面入口 URL。
#
# 为什么需要它：magpie web 对没有 cookie 的浏览器一律 401 落到登录页；而 fnOS 桌面
# 图标打开的是 PostgreSQL 表 trim_sac.entry 里 url.path 这一段（安装/升级时由
# app/ui/config 解析写入，值为 "/"）。只有把 path 写成 "/?k=<key>"，点图标才直达界面。
#
# 运行时机：install_callback / upgrade_callback / config_callback。
# 这些 hook 由应用中心以 root 拉起时才能写 PG；不是 root 就只记录并跳过，
# 不影响安装与启动（用户仍可在登录页粘一次 key，cookie 记 400 天）。
#
# 用法：bash sync-entry-url.sh <install|upgrade|config>

set -u
STAGE="${1:-manual}"
APPNAME="magpie"

# ── 定位数据目录（不写死卷号）────────────────────────────────────────────
resolve_var() {
    local appdir vol v
    appdir="$(readlink -f "/var/apps/${APPNAME}/target" 2>/dev/null || true)"
    [ -z "$appdir" ] && appdir="$(readlink -f "/var/apps/${APPNAME}" 2>/dev/null || true)"
    case "$appdir" in
        /vol[0-9]*/@appcenter/*) vol="$(printf '%s' "$appdir" | cut -d/ -f2)" ;;
    esac
    if [ -z "${vol:-}" ]; then
        for v in /vol[0-9]*; do
            [ -d "${v}/@appdata/${APPNAME}" ] && vol="${v#/}" && break
        done
    fi
    [ -z "${vol:-}" ] && vol="vol2"
    printf '/%s/@appdata/%s' "$vol" "$APPNAME"
}

VAR="$(resolve_var)"
KEY_FILE="${VAR}/web.key"
mkdir -p "$VAR" 2>/dev/null || true

echo "--- sync-entry-url: stage=$STAGE var=$VAR"

# ── 取 key：以 ui/config 里图标入口的 ?k= 为准（= PG 里的 path），其次 web.key ──
UI_CONF="/var/apps/${APPNAME}/target/ui/config"
KEY="$(grep -o '?k=[A-Za-z0-9._~-]*' "$UI_CONF" 2>/dev/null | head -1 | sed 's/^?k=//')"
if [ -z "$KEY" ]; then
    [ -s "$KEY_FILE" ] && KEY="$(tr -d ' \r\n' < "$KEY_FILE" 2>/dev/null)"
fi
if [ -z "$KEY" ]; then
    KEY="${wizard_web_key:-${WIZARD_WEB_KEY:-}}"
    KEY="$(printf '%s' "$KEY" | tr -d ' \r\n')"
    case "$KEY" in
        *[!A-Za-z0-9._~-]*) KEY="" ;;
    esac
    { [ ${#KEY} -ge 16 ] && [ ${#KEY} -le 64 ]; } || KEY=""
fi
if [ -z "$KEY" ]; then
    echo "--- SKIP: ui/config 与 web.key 都取不到 key"
    exit 0
fi
printf '%s\n' "$KEY" > "$KEY_FILE" 2>/dev/null
chown "${APPNAME}:${APPNAME}" "$KEY_FILE" 2>/dev/null || true
chmod 600 "$KEY_FILE" 2>/dev/null || true
echo "--- key: ${KEY}"

# ── 写 PG（只有 root 能 su postgres）────────────────────────────────────
if [ "$(id -u)" != "0" ]; then
    echo "--- SKIP: 当前非 root（uid=$(id -u)），无法写 trim_sac.entry"
    echo "--- 图标入口需手动修：见 MAGPIE-ENTRY-README"
    exit 0
fi

command -v psql >/dev/null 2>&1 || { echo "--- SKIP: 无 psql"; exit 0; }

PORT="$(
    grep -o '"port"[[:space:]]*:[[:space:]]*"[0-9]*"' "/var/apps/${APPNAME}/target/ui/config" 2>/dev/null \
        | grep -o '[0-9]\+' | head -1
)"
[ -n "$PORT" ] || PORT="3430"

SQL_FILE="$(mktemp /tmp/magpie-entry-XXXXXX.sql)"
{
    printf "update entry set url='{\"protocol\":\"http\",\"port\":\"%s\",\"path\":\"/?k=%s\"}', update_time=now() where app_name='magpie' and service_name='magpie.main';\n" "$PORT" "$KEY"
    printf "select app_name, service_name, url from entry where app_name='magpie';\n"
} > "$SQL_FILE"
chmod 644 "$SQL_FILE"

su - postgres -c "psql -d trim_sac -f '${SQL_FILE}'" 2>&1 | tail -6
rm -f "$SQL_FILE"
exit 0
