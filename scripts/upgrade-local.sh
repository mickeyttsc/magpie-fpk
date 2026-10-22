#!/bin/bash
# 精简升级：走应用中心守护进程 RPC（不经 install-fpk 的已装短路）
set -uo pipefail
APP="magpie"
FPK="${1:?用法: upgrade-magpie.sh <fpk>}"
SOCK=/var/run/com.trim.app.center.sock
rpc() { curl -s --unix-socket "$SOCK" -X POST -H 'Content-Type: application/json' -d "$2" "http://localhost$1" --max-time 60; }
jget() { python3 -c "import json,sys;d=json.load(sys.stdin);print(eval('d'+sys.argv[1]))" "$1" 2>/dev/null; }

echo "== 升级前 =="
grep '^version' "/var/apps/$APP/manifest" | awk -F= '{print $2}'
su - postgres -c "psql -d trim_sac -A -c \"select url from entry where app_name='magpie';\"" 2>&1 | tail -2

R1="$(rpc /rpc/v1/download/task "{\"packageSourceType\":\"file\",\"path\":\"$FPK\"}")"
TID="$(printf '%s' "$R1" | jget "['data']['downloadTaskId']")"
[ -n "$TID" ] || { echo "FAIL 暂存: $R1"; exit 1; }
for _ in $(seq 1 90); do
    S="$(rpc /rpc/v1/download/status "{\"downloadTaskId\":\"$TID\"}")"
    ST="$(printf '%s' "$S" | jget "['data']['status']")"
    [ "$ST" = "2" ] && break
    [ "$ST" = "1" ] || { echo "FAIL 暂存状态: $S"; exit 1; }
    sleep 1
done
NEW_VER="$(printf '%s' "$S" | jget "['data']['version']")"
PKG_TYPE="$(printf '%s' "$S" | jget "['data']['packageType']")"
echo "暂存完成: version=$NEW_VER type=$PKG_TYPE"

R2="$(rpc /rpc/v1/update/info "{\"appName\":\"$APP\",\"updateVersion\":\"$NEW_VER\",\"packageType\":\"$PKG_TYPE\",\"language\":\"zh-CN\"}")"
VOL="$(printf '%s' "$R2" | jget "['data']['wizardInfo']['installedVolumeID']")"
case "$VOL" in ''|0|None) echo "FAIL 取不到安装卷"; exit 1 ;; esac
echo "安装卷: $VOL"

R3="$(rpc /rpc/v1/update/task "{\"appName\":\"$APP\",\"updateVersion\":\"$NEW_VER\",\"packageType\":\"$PKG_TYPE\",\"systemParameters\":{\"agreedToProtocol\":true,\"installVolumeID\":$VOL,\"dataVolumeId\":$VOL,\"immediateStart\":false},\"customParameters\":[],\"language\":\"zh-CN\"}")"
TASK="$(printf '%s' "$R3" | jget "['data']['taskId']")"
[ -n "$TASK" ] || { echo "FAIL 提交: $R3"; exit 1; }
for i in $(seq 1 240); do
    S="$(rpc /rpc/v1/common/status "{\"taskId\":\"$TASK\"}")"
    ST="$(printf '%s' "$S" | jget "['data']['status']")"
    PG="$(printf '%s' "$S" | jget "['data']['progress']")"
    echo "  [$i] status=$ST progress=$PG"
    case "$ST" in
        2) break ;;
        1) sleep 2 ;;
        5) echo "守护进程不持有任务 → 按版本判定"; break ;;
        *) echo "FAIL 任务: $S"; exit 1 ;;
    esac
done

echo "== 升级后 =="
sleep 3
appcenter-cli start "$APP" >/dev/null 2>&1 || true
sleep 12
echo -n "版本: "; grep '^version' "/var/apps/$APP/manifest" | awk -F= '{print $2}'
echo -n "状态: "; appcenter-cli status "$APP"
ADMIN_DIR=""
for v in /vol[0-9]*; do [ -d "$v/@appdata/magpie" ] && ADMIN_DIR="$v/@appdata/magpie" && break; done
echo "hook.log: ${ADMIN_DIR}"
cat "${ADMIN_DIR}/hook.log" 2>/dev/null | tail -25 || true
echo "entry.url:"; su - postgres -c "psql -d trim_sac -A -c \"select url from entry where app_name='magpie';\"" 2>&1 | tail -2
