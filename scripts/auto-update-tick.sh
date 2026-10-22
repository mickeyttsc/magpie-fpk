#!/usr/bin/env bash
# auto-update-tick.sh — 单次上游巡检（一次「tick」）
# 只做【检测 + bump + 提交 + 触发构建】，不负责发布（Release 归属 build.yml 独占）。
# 可独立手动运行（不依赖 CI，便于本机验证）。退出码始终 0（失败不中断长驻循环）。
set -uo pipefail

MAGPIE_ENV=config/upstream/magpie.env

log() { echo "[$(date -u '+%H:%M:%S')] $*"; }

# ── 1. 探测上游 ──
LATEST="$(python3 scripts/detect-upstream.py magpie 2>/dev/null)"
if [ -z "$LATEST" ]; then
    log "WARN 未能解析可打包的 magpie 版本，本轮跳过"
    exit 0
fi
SHA="$(python3 scripts/detect-upstream.py magpie-sha "$LATEST" 2>/dev/null)"
printf '%s' "$SHA" | grep -qE '^[0-9a-f]{64}$' || { log "WARN magpie sha256 获取失败/格式非法，本轮跳过"; exit 0; }

# ── 2. 与当前记录做【版本序】比较 ──
# ⚠️ 必须比大小，不能只比「相不相等」：上游回滚、或重发一个更旧的 tag 时，
#    `[ "$LATEST" != "$CUR_ENV_VER" ]` 会把它当成「有新版本」，于是真去构建并
#    发布一个比现装更旧的包 —— 跟着装就是降级。降级一律不自动跟随，留给人判断。
ver_gt() {   # $1 比 $2 新 → 0
    local a="${1#v}" b="${2#v}"
    if [ -z "$a" ] || [ -z "$b" ]; then return 1; fi
    if [ "$a" = "$b" ]; then return 1; fi
    if [ "$(printf '%s\n%s\n' "$a" "$b" | sort -V | tail -n1)" = "$a" ]; then return 0; fi
    return 1
}

CUR_VER_FULL="$(grep '^version' manifest | cut -d= -f2 | tr -d ' ')"
if [ -z "$CUR_VER_FULL" ]; then
    log "ERROR 读不到 manifest 的 version 字段，本轮跳过（不做任何比较）"
    exit 0
fi
CUR_BASE="${CUR_VER_FULL%-*}"
CUR_BUILD="${CUR_VER_FULL##*-}"
case "${CUR_BUILD}" in ''|*[!0-9]*) CUR_BUILD=0 ;; esac
CUR_ENV_VER="$(grep '^MAGPIE_VERSION=' "$MAGPIE_ENV" | cut -d= -f2 | tr -d ' ')"

if [ "$LATEST" != "$CUR_BASE" ] && ! ver_gt "$LATEST" "$CUR_BASE"; then
    log "SKIP 上游最新 ${LATEST} 不高于已跟踪的 ${CUR_BASE}（疑似回滚/旧 tag 重发），不自动降级；如确需降级请手工改 manifest"
    exit 0
fi

CHANGED=0
[ "$LATEST" != "$CUR_ENV_VER" ] && CHANGED=1
# sha 固定值失配（上游重发了同版本资产）也算变化
grep -qF "MAGPIE_SHA256=$SHA" "$MAGPIE_ENV" || CHANGED=1

if [ "$CHANGED" != "1" ]; then
    # 幂等 ≠ 什么都不做：可能还有上一轮【未推送成功】的提交（push 失败后不再重试的坑）
    if [ -n "${GITHUB_REPOSITORY:-}" ] && git rev-parse --verify origin/main >/dev/null 2>&1; then
        AHEAD="$(git rev-list --count origin/main..HEAD 2>/dev/null || echo 0)"
        if [ "${AHEAD:-0}" -gt 0 ]; then
            log "up-to-date 但本地领先远端 ${AHEAD} 个提交 → 补推"
            git pull --rebase --autostash -q origin main 2>/dev/null || true
            if git push -q origin main 2>/dev/null; then
                log "补推成功，触发构建"
                curl -sS -o /dev/null --max-time 60 -X POST \
                    -H "Authorization: token ${GITHUB_TOKEN}" \
                    -H "Accept: application/vnd.github+json" \
                    "https://api.github.com/repos/${GITHUB_REPOSITORY}/actions/workflows/build.yml/dispatches" \
                    -d '{"ref":"main"}' 2>/dev/null || true
            else
                log "补推仍失败（下一轮重试）"
            fi
            exit 0
        fi
    fi
    log "up-to-date: magpie=${CUR_ENV_VER} fpk=${CUR_VER_FULL}"
    exit 0
fi

log "发现上游更新: magpie ${CUR_ENV_VER} -> ${LATEST}"

# ── 3. 写回版本锚点与 sha256 固定值 ──
sed -i "s/^MAGPIE_VERSION=.*/MAGPIE_VERSION=${LATEST}/" "$MAGPIE_ENV"
sed -i "s/^MAGPIE_SHA256=.*/MAGPIE_SHA256=${SHA}/" "$MAGPIE_ENV"

# 版本号规则：上游版本变化 → 迭代号重置为 -1
if [ "$LATEST" != "$CUR_BASE" ]; then
    NEW_VER="${LATEST}-1"
else
    NEW_VER="${CUR_BASE}-$((CUR_BUILD + 1))"
fi
sed -i "s/^version[[:space:]]*=.*/version               = ${NEW_VER}/" manifest
log "新 FPK 版本: ${NEW_VER}"

# ── 4. 提交并推送 ──
if ! git rev-parse --git-dir >/dev/null 2>&1; then
    log "本地模式：当前目录不是 git 仓库，跳过提交/推送（改动已写入工作区，供检查）"
    exit 0
fi

git config user.name "github-actions[bot]"
git config user.email "github-actions[bot]@users.noreply.github.com"
git add "$MAGPIE_ENV" manifest
if ! git diff --cached --quiet; then
    git commit -q -m "chore: auto-bump upstream -> magpie ${LATEST} (FPK ${NEW_VER})"
    git pull --rebase --autostash -q origin main 2>/dev/null || true
    if git push -q origin main 2>/dev/null; then
        log "已推送 bump 提交"
    else
        log "ERROR 推送失败（下一轮重试）"
        exit 0
    fi
else
    log "无实际改动可提交（可能已被其它 run 处理）"
fi

# ── 5. 立刻触发构建（长驻 job 不结束，不能等 workflow_run 接力）──
if [ -n "${GITHUB_TOKEN:-}" ] && [ -n "${GITHUB_REPOSITORY:-}" ]; then
    CODE="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 60 -X POST \
        -H "Authorization: token ${GITHUB_TOKEN}" \
        -H "Accept: application/vnd.github+json" \
        "https://api.github.com/repos/${GITHUB_REPOSITORY}/actions/workflows/build.yml/dispatches" \
        -d '{"ref":"main"}' 2>/dev/null || echo 000)"
    if [ "${CODE}" = "204" ]; then
        log "已触发 build.yml（HTTP 204）"
    else
        log "WARN 触发 build.yml 失败 HTTP ${CODE}（bump 已入库，可手动/下次重试）"
    fi
else
    log "本地模式：跳过触发 build.yml（无 GITHUB_TOKEN/GITHUB_REPOSITORY）"
fi

exit 0
