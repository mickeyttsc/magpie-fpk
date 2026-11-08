#!/usr/bin/env python3
"""Magpie 二进制与自动更新守护监听器 (magpie-watcher.py)

解决的核心问题：
  1. 用户开启并允许 magpie 自身的正常自动更新（或前端点击更新）。
     当 magpie 自动下载新版本落盘替换原程序时，新二进制是未打补丁的原版。
     本监听器通过原子 rename 自动对新版二进制打补丁，绕开 ETXTBSY。
  2. 当社区插件（带 page 界面）发生自更新或新安装时，可能恢复为外部相对静态资源。
     本监听器自动将 page 下的 CSS 和 Logo 图标内联化，确保沙箱 iframe 绝对不丢样式。
"""

import os
import sys
import time
import base64
import tempfile

PATCHES = [
    (b"frame-ancestors 'self'", b"frame-ancestors *     "),
    (b"Content-Security-Policy", b"X-Content-Security-Poli"),
]


def patch_file(path):
    if not os.path.isfile(path) or os.path.islink(path):
        return False
    try:
        size = os.path.getsize(path)
        if size < 10 * 1024 * 1024:
            return False

        with open(path, "rb") as f:
            data = f.read()

        needs_patch = False
        for old_b, new_b in PATCHES:
            if old_b in data:
                needs_patch = True
                break

        if not needs_patch:
            return False

        patched = data
        for old_b, new_b in PATCHES:
            patched = patched.replace(old_b, new_b)

        if len(patched) != len(data):
            return False

        d = os.path.dirname(path)
        fd, tmp = tempfile.mkstemp(prefix=".magpie-patch-", dir=d)
        try:
            with os.fdopen(fd, "wb") as f:
                f.write(patched)
                f.flush()
                os.fsync(f.fileno())
            os.chmod(tmp, os.stat(path).st_mode)
            os.replace(tmp, path)
        except OSError:
            try:
                os.unlink(tmp)
            except OSError:
                pass
            return False

        print(f"[magpie-watcher] Successfully auto-patched via rename: {path} ({size} bytes)", flush=True)
        return True
    except Exception:
        return False


def inline_plugin_pages(plugins_dir):
    if not os.path.isdir(plugins_dir):
        return
    try:
        for root, dirs, files in os.walk(plugins_dir):
            if os.path.basename(root) == 'page' and 'index.html' in files:
                index_file = os.path.join(root, 'index.html')
                style_file = os.path.join(root, 'style.css')
                logo_file = os.path.join(root, 'logo-mark.png')

                with open(index_file, 'r', encoding='utf-8', errors='ignore') as f:
                    html = f.read()

                changed = False
                if 'href="style.css"' in html or "href='style.css'" in html:
                    if os.path.isfile(style_file):
                        with open(style_file, 'r', encoding='utf-8', errors='ignore') as f:
                            css = f.read()
                        html = html.replace('<link rel="stylesheet" href="style.css">', f'<style>\n{css}\n</style>')
                        html = html.replace("<link rel='stylesheet' href='style.css'>", f'<style>\n{css}\n</style>')
                        changed = True

                if 'src="logo-mark.png"' in html or "src='logo-mark.png'" in html:
                    if os.path.isfile(logo_file):
                        with open(logo_file, 'rb') as f:
                            b64 = base64.b64encode(f.read()).decode('ascii')
                        html = html.replace('src="logo-mark.png"', f'src="data:image/png;base64,{b64}"')
                        html = html.replace("src='logo-mark.png'", f"src='data:image/png;base64,{b64}'")
                        changed = True

                if changed:
                    with open(index_file, 'w', encoding='utf-8') as f:
                        f.write(html)
                    print(f"[magpie-watcher] Auto-inlined plugin page: {root}", flush=True)
    except Exception:
        pass


def main():
    if len(sys.argv) < 2:
        print("Usage: magpie-watcher.py <magpie_bin_dir> [plugins_dir]", file=sys.stderr)
        return 1

    bin_dir = os.path.abspath(sys.argv[1])
    plugins_dir = sys.argv[2] if len(sys.argv) > 2 else "/vol2/@apphome/magpie/.config/magpie/plugins"
    main_bin = os.path.join(bin_dir, "magpie")
    update_dir = os.path.join(bin_dir, ".magpie-update")

    # 首次启动先扫一次
    patch_file(main_bin)
    inline_plugin_pages(plugins_dir)

    tick = 0
    while True:
        try:
            # 1. 扫描 bin_dir 下的潜在预更新文件
            if os.path.isdir(bin_dir):
                for name in os.listdir(bin_dir):
                    if name != "magpie" and (".new" in name or name.startswith("magpie") or name.startswith("payload")):
                        patch_file(os.path.join(bin_dir, name))

            # 2. 扫描 .magpie-update 目录（上游 stageDir 暂存目录）
            if os.path.isdir(update_dir):
                for root, _, files in os.walk(update_dir):
                    for name in files:
                        patch_file(os.path.join(root, name))

            # 3. 扫描主程序本身（若刚被替换成未打补丁的新版）
            patch_file(main_bin)

            # 4. 每 10 秒巡检一次插件目录（防止插件更新冲掉内联样式）
            tick += 1
            if tick % 5 == 0:
                inline_plugin_pages(plugins_dir)

        except Exception:
            pass

        time.sleep(2)


if __name__ == "__main__":
    sys.exit(main())
