#!/usr/bin/env python3
"""Magpie 二进制与自动更新守护监听器 (magpie-watcher.py)

解决的核心问题：
  用户希望开启并允许 magpie 自身的正常自动更新（或前端点击更新）。
  然而 magpie 自动下载新版本落盘（在 bin/.magpie-update/ 或 bin/ 目录下作为 .new / 替换原程序）时，
  新下载的上游官方二进制是未打补丁的原版，会导致插件页在 fnOS 小窗中再次出现 CSP 拒帧或 10 秒停止工作。

本监听器的职责：
  随 magpie 服务常驻后台运行，每隔 2~3 秒巡检一次相关目录：
  1. 一旦检测到后台下载好的新版本预暂存文件（如 .magpie-update/ 下的文件或 magpie.new），
     立即给该文件打上等长补丁！这样 magpie 在执行 moveIn/重命名替换时，换进去的就已经是打了补丁的新版！
  2. 一旦检测到正在运行的主二进制 bin/magpie 的 mtime 或文件发生变化（说明刚完成热重启或热更新），
     若尚未打补丁，则立即自动应用等长补丁。
  3. 占用资源极低（每次 stat / 检查几个字节，无感知），让自动更新和补丁完美共存！
"""

import os
import sys
import time

PATCHES = [
    (b"frame-ancestors 'self'", b"frame-ancestors *     "),
    (b"Content-Security-Policy", b"X-Content-Security-Poli"),
]


def patch_file(path):
    if not os.path.isfile(path) or os.path.islink(path):
        return False
    try:
        size = os.path.getsize(path)
        # magpie 官方二进制大于 20MB
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

        with open(path, "r+b") as f:
            f.seek(0)
            f.write(patched)
            f.truncate(len(patched))
            f.flush()
            os.fsync(f.fileno())

        print(f"[magpie-watcher] Successfully auto-patched: {path} ({size} bytes)", flush=True)
        return True
    except Exception as e:
        return False


def main():
    if len(sys.argv) < 2:
        print("Usage: magpie-watcher.py <magpie_bin_dir>", file=sys.stderr)
        return 1

    bin_dir = os.path.abspath(sys.argv[1])
    main_bin = os.path.join(bin_dir, "magpie")
    update_dir = os.path.join(bin_dir, ".magpie-update")

    # 首次启动先扫一次
    patch_file(main_bin)

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

        except Exception:
            pass

        time.sleep(2)


if __name__ == "__main__":
    sys.exit(main())
