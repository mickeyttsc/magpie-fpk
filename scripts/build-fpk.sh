#!/usr/bin/env bash
# 构建 Magpie 飞牛 fpk 安装包
#
# 用法：bash scripts/build-fpk.sh [输出目录]
#
# 载荷来源（钉版本 + sha256 校验，固定值入库 config/upstream/magpie.env）：
#   1. 主程序：yetone/magpie 官方 magpie-cli-linux-amd64（静态链接 Go 二进制，无运行时依赖）
#   骨架：cmd/ config/ wizard/ app/（app.tgz 内容），图标由 assets/icon_512.png 复制。
#
# 版本号来源：仓库根 manifest 的 version 字段（auto-update 负责 bump），格式 <上游版本>-<封装迭代号>。
set -e

APPNAME="magpie"
PKGNAME="magpie"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

OUT_DIR="${1:-.}"
mkdir -p "$OUT_DIR"

VERSION="$(grep '^version' manifest | awk -F'=' '{print $2}' | tr -d ' ')"
if ! printf '%s' "$VERSION" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+-[0-9]+$'; then
    echo "::error:: manifest version 非法：'$VERSION'（期望形如 0.1.1318-1）"
    exit 1
fi

# ── 读固定版本与校验值 ──
pin() { grep -E "^$1=" "$2" | head -1 | cut -d= -f2 | tr -d ' '; }
MAGPIE_VERSION="$(pin MAGPIE_VERSION config/upstream/magpie.env)"
MAGPIE_SHA256="$(pin MAGPIE_SHA256 config/upstream/magpie.env)"
[ -n "$MAGPIE_VERSION" ] && [ -n "$MAGPIE_SHA256" ] || { echo "::error:: config/upstream/magpie.env 不完整"; exit 1; }
printf '%s' "$MAGPIE_SHA256" | grep -qE '^[0-9a-f]{64}$' || { echo "::error:: MAGPIE_SHA256 格式非法"; exit 1; }

echo "=== Magpie FPK 构建 ==="
echo "FPK 版本:    $VERSION"
echo "上游主程序:  v$MAGPIE_VERSION"

WORK="$(mktemp -d)"
BUILD_ROOT="$WORK/pkg"
mkdir -p "$BUILD_ROOT/app/bin" "$BUILD_ROOT/app/ui/images" \
         "$BUILD_ROOT/cmd" "$BUILD_ROOT/config" "$BUILD_ROOT/wizard"

# ── 1. 下载上游二进制并校验 ──
ASSET="magpie-cli-linux-amd64"
URL="https://github.com/yetone/magpie/releases/download/v${MAGPIE_VERSION}/${ASSET}"
echo "下载: $URL"
curl -fSL --retry 3 --max-time 900 -o "$WORK/$ASSET" "$URL"
ACTUAL="$(sha256sum "$WORK/$ASSET" | awk '{print $1}')"
if [ "$ACTUAL" != "$MAGPIE_SHA256" ]; then
    echo "::error:: $ASSET sha256 校验失败"
    echo "  期望(固定值): $MAGPIE_SHA256"
    echo "  实际:         $ACTUAL"
    echo "  上游可能替换了同版本资产，或下载被篡改。构建中止。"
    exit 1
fi
echo "✅ 主程序 sha256 校验通过: $ACTUAL"
chmod 755 "$WORK/$ASSET"

# 二进制可执行性 + 版本自检（能跑起来、版本对得上才算数）
BIN_BANNER="$("$WORK/$ASSET" --version 2>&1 | head -1 || true)"
case "$BIN_BANNER" in
    *"$MAGPIE_VERSION"*) echo "✅ 二进制自检通过: $BIN_BANNER" ;;
    *) echo "::error:: 二进制版本自检失败（期望输出含 '$MAGPIE_VERSION'）"; printf '%s\n' "$BIN_BANNER"; exit 1 ;;
esac
BINARY_SHA256="$(sha256sum "$WORK/$ASSET" | awk '{print $1}')"
echo "Binary SHA256: $BINARY_SHA256"

# 静态链接断言：要求零动态依赖（否则 fnOS 上可能缺库起不来）
if command -v ldd >/dev/null 2>&1; then
    LDD_OUT="$(ldd "$WORK/$ASSET" 2>&1 || true)"
    case "$LDD_OUT" in
        *"not a dynamic executable"*|*"not found"*|"") : ;;
        *) echo "::error:: 二进制存在动态依赖，不符合静态链接预期"; printf '%s\n' "$LDD_OUT"; exit 1 ;;
    esac
fi

# ── 2. 组装 fpk 目录 ──
# 内层 app.tgz 内容：bin/ ui/ config/（无 app/ 前缀，无 ./ 前缀）
cp "$WORK/$ASSET" "$BUILD_ROOT/app/bin/magpie"
chmod 755 "$BUILD_ROOT/app/bin/magpie"

cp "app/ui/config" "$BUILD_ROOT/app/ui/config"

# 图标：四槽位统一 512×512（fnOS 桌面实际拉 icon_64 槽位内容，塞小图会放大发虚）
[ -f "assets/icon_512.png" ] || { echo "::error:: 缺 assets/icon_512.png"; exit 1; }
cp "assets/icon_512.png" "$BUILD_ROOT/app/ui/images/icon_64.png"
cp "assets/icon_512.png" "$BUILD_ROOT/app/ui/images/icon_256.png"
cp "assets/icon_512.png" "$BUILD_ROOT/ICON.PNG"
cp "assets/icon_512.png" "$BUILD_ROOT/ICON_256.PNG"


# 生命周期脚本（按目录整体拷贝，新增 hook 自动带上）
for f in cmd/*; do
    [ -f "$f" ] || continue
    cp "$f" "$BUILD_ROOT/cmd/$(basename "$f")"
    chmod 755 "$BUILD_ROOT/cmd/$(basename "$f")"
done
[ -f "$BUILD_ROOT/cmd/main" ] || { echo "::error:: 缺 cmd/main"; exit 1; }

# ── Web 界面门禁 key 处理 ──
# 现在的方案采用上游标准行为：安装向导中由用户自行设置口令（留空则首次运行自动生成随机口令）。
# 图标入口 url 固定为 /（小窗），用户首次访问在登录框输入口令即可（浏览器保持 400 天）。
# 不再向 ui/config 注入写死的 ?k=。


# 外层 config / wizard
cp "config/privilege" "$BUILD_ROOT/config/privilege"
cp "config/resource" "$BUILD_ROOT/config/resource"
for w in install upgrade config; do
    cp "wizard/$w" "$BUILD_ROOT/wizard/$w"
done

# 上游许可证（若存在）
if [ -f "$WORK/LICENSE" ]; then
    cp "$WORK/LICENSE" "$BUILD_ROOT/app/config/upstream-LICENSE.txt"
fi

# manifest：从仓库 manifest 生成（changelog 更新为动态内容；checksum 留空由后处理填）
{
    grep -v '^changelog' manifest | grep -v '^checksum'
    printf 'changelog             = 跟随上游 Magpie v%s（sha256 %s）；Web 界面 http://<NAS-IP>:3430，网关 http://<NAS-IP>:3425。fnOS 封装版本 %s。\n' \
        "$MAGPIE_VERSION" "$(printf '%s' "$MAGPIE_SHA256" | cut -c1-12)" "$VERSION"
    printf 'checksum              =\n'
} > "$BUILD_ROOT/manifest"

# ── 3. 打包（fnpack 优先，tar+gzip 兜底）──
FNPACK=""
for cand in fnpack "$ROOT/fnpack"; do
    if command -v "$cand" >/dev/null 2>&1 || [ -x "$cand" ]; then FNPACK="$cand"; break; fi
done

TMP_FPK="$WORK/out.fpk"
if [ -n "$FNPACK" ]; then
    echo "使用 fnpack 构建：$FNPACK"
    (cd "$BUILD_ROOT" && "$FNPACK" build)
    [ -f "$BUILD_ROOT/${APPNAME}.fpk" ] || { echo "::error:: fnpack 未生成 ${APPNAME}.fpk"; ls -la "$BUILD_ROOT"; exit 1; }
    cp "$BUILD_ROOT/${APPNAME}.fpk" "$TMP_FPK"
else
    echo "未找到 fnpack，使用 tar+gzip 兜底构建"
    (
        cd "$BUILD_ROOT"
        APP_ENTRIES="$(cd app && ls -A)"
        [ -n "$APP_ENTRIES" ] || { echo "::error:: app/ 目录为空"; exit 1; }
        # shellcheck disable=SC2086
        tar --owner=root --group=root --mtime='@0' -cf - -C app ${APP_ENTRIES} | gzip -n > app.tgz
        FIRST_ENTRY="$(tar tzf app.tgz | head -1)"
        case "$FIRST_ENTRY" in
            app/*|./*|app|.)
                echo "::error:: 内层 app.tgz 首条为 '${FIRST_ENTRY}'，带前缀"
                exit 1
                ;;
        esac
        SUM="$(md5sum app.tgz | awk '{print $1}')"
        sed "s/^checksum[[:space:]]*=.*/checksum              = ${SUM}/" manifest > manifest.tmp && mv manifest.tmp manifest
        echo "$SUM" > manifest.checksum
        tar --owner=root --group=root --mtime='@0' -cf - manifest manifest.checksum cmd config wizard ICON.PNG ICON_256.PNG app.tgz | gzip -n > "${APPNAME}.fpk"
        rm -f app.tgz manifest.checksum
    )
    cp "$BUILD_ROOT/${APPNAME}.fpk" "$TMP_FPK"
fi

# ── 4. 后处理：重置属主 / 正规化权限 / 补 manifest.checksum / 去软链 ──
python3 - "$TMP_FPK" "$TMP_FPK" <<'PY'
import tarfile, hashlib, io, os, tempfile, shutil, gzip, sys

def sanitize_app_tgz(data):
    in_buf = io.BytesIO(data)
    in_tar = tarfile.open(fileobj=in_buf, mode='r:gz')
    out_buf = io.BytesIO()
    out_tar = tarfile.open(fileobj=out_buf, mode='w:gz', compresslevel=9)
    removed = 0
    kept = 0
    for m in in_tar.getmembers():
        if m.issym() or m.islnk():
            removed += 1
            continue
        m.uid = 0
        m.gid = 0
        m.uname = 'root'
        m.gname = 'root'
        if m.isdir():
            m.mode = 0o755
        else:
            m.mode = 0o755 if (m.mode & 0o111) else 0o644
        m.mode &= ~0o7000
        try:
            f = in_tar.extractfile(m)
        except Exception as e:
            print(f"WARN: extract {m.name} failed: {e}", file=sys.stderr)
            continue
        if m.isreg() and f is None:
            print(f"WARN: no data for {m.name}", file=sys.stderr)
            continue
        out_tar.addfile(m, f)
        kept += 1
    out_tar.close()
    print(f"  app.tgz: removed {removed} links, kept {kept} members")
    return out_buf.getvalue()

src, dst = sys.argv[1], sys.argv[2]
tmp = tempfile.mkdtemp()
try:
    outer = tarfile.open(src, 'r:gz')
    app_data = outer.extractfile('app.tgz').read()
    names = outer.getnames()
    for m in outer.getmembers():
        if m.name == 'app.tgz':
            continue
        try:
            outer.extract(m, tmp, filter='fully_trusted')
        except TypeError:
            outer.extract(m, tmp)
    outer.close()

    new_app = sanitize_app_tgz(app_data)
    checksum = hashlib.md5(new_app).hexdigest()

    manifest_path = os.path.join(tmp, 'manifest')
    with open(manifest_path, 'rb') as f:
        content = f.read().replace(b'\r\n', b'\n')
    lines = content.decode('utf-8').splitlines(keepends=True)
    wrote = False
    with open(manifest_path, 'w', encoding='utf-8', newline='\n') as f:
        for line in lines:
            if line.startswith('checksum'):
                f.write(f'checksum              = {checksum}\n')
                wrote = True
            else:
                f.write(line)
        if not wrote:
            f.write(f'checksum              = {checksum}\n')

    with open(os.path.join(tmp, 'manifest.checksum'), 'w', encoding='utf-8', newline='\n') as f:
        f.write(checksum + '\n')

    out = io.BytesIO()
    out_tar = tarfile.open(fileobj=out, mode='w')
    order = ['manifest', 'manifest.checksum']
    other = sorted([n for n in names if n not in ('manifest', 'manifest.checksum', 'app.tgz')])
    order.extend(other)
    order.append('app.tgz')

    for name in order:
        if name == 'app.tgz':
            info = tarfile.TarInfo(name='app.tgz')
            info.size = len(new_app)
            info.mode = 0o644
            info.uid = 0
            info.gid = 0
            out_tar.addfile(info, io.BytesIO(new_app))
        else:
            full = os.path.join(tmp, name)
            if os.path.isdir(full):
                info = tarfile.TarInfo(name=name)
                info.type = tarfile.DIRTYPE
                info.mode = 0o755
                info.uid = 0
                info.gid = 0
                out_tar.addfile(info)
            elif os.path.isfile(full):
                out_tar.add(full, arcname=name)
    out_tar.close()
    with gzip.open(dst, 'wb', compresslevel=9) as gz:
        gz.write(out.getvalue())
    print(f"  postprocess OK: {dst}")
    print(f"  checksum(md5 of app.tgz): {checksum}")
finally:
    shutil.rmtree(tmp, ignore_errors=True)
PY

# ── 5. 输出到目标文件名 ──
FPK_OUT="$OUT_DIR/${PKGNAME}-${VERSION}.fpk"
cp -f "$TMP_FPK" "$FPK_OUT"

FPK_MD5="$(md5sum "$FPK_OUT" | awk '{print $1}')"
FPK_SHA256="$(sha256sum "$FPK_OUT" | awk '{print $1}')"
INNER_MD5="$(tar xzf "$FPK_OUT" -O app.tgz | md5sum | awk '{print $1}')"

echo ""
echo "=== Build Complete ==="
echo "FPK file:  $FPK_OUT"
echo "Size:      $(ls -lh "$FPK_OUT" | awk '{print $5}')"
echo "MD5:       $FPK_MD5"
echo "SHA256:    $FPK_SHA256"
echo "Binary SHA256: $BINARY_SHA256"
echo "Checksum self-check md5(app.tgz): $INNER_MD5"
echo ""
echo "Package contents:"
tar tzf "$FPK_OUT" | head -20

# ── 6. 门禁（与 CI 共用同一份脚本）──
if [ -f scripts/verify-fpk-gates.sh ]; then
    bash scripts/verify-fpk-gates.sh "$FPK_OUT"
fi

rm -rf "$WORK" 2>/dev/null || true
