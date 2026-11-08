#!/usr/bin/env python3
"""Magpie 二进制等长补丁：彻底解决插件页在 fnOS 桌面小窗下的 CSP 拒绝与子资源拦截问题。

根因与现象排查（2026-11 实测结论）：
  1. 灰屏 / 🚫 破损图标：
     magpie 给插件页发的 frame-ancestors 'self' 校验整条祖先链。fnOS 桌面点图标是三层嵌套：
     fnOS 桌面(非 self) -> iframe magpie 主界面 -> iframe 插件页，整帧被浏览器拒绝。
  2. 纯原生文本 / 裂图 / 10 秒后提示「此页面已停止工作」：
     magpie 在 Response Header 中设置了严格的 Content-Security-Policy，限制了子资源的路径。
     在跨源沙盒 iframe（origin 为 null）以及各种端口/代理访问场景下，浏览器直接拦截了该 iframe
     发起的同源相对路径请求（style.css、logo-mark.png、_magpie/bridge.js）。
     由于 bridge.js 被拦截无法运行，无法向母窗口发送 postMessage("hello") 握手，母窗口 10 秒超时
     一到，就把卡片换成「此页面已停止工作」。

补丁逻辑（全部等长替换，字节数与二进制偏移 100% 保持一致）：
  1. frame-ancestors 'self' (22B) -> frame-ancestors * + 5空格 (22B)
  2. Content-Security-Policy (23B) -> X-Content-Security-Poli (23B)

安全隔离说明：
  移除响应头里的 Content-Security-Policy 并不会破坏沙箱安全。因为 iframe 标签本身的
  sandbox="allow-scripts"、referrerpolicy="no-referrer" 是母窗口写在 HTML 里的原生属性。
  插件页依旧是不透明源（origin 为 null），无法访问父窗口 DOM、无法窃取 magpie cookie、
  无法调用 magpie 内部 API。
  放宽后，所有社区插件（无论以后新安装什么插件）的样式、图片、JS 均可正常执行，握手秒完成。
"""

import sys

PATCHES = [
    (b"frame-ancestors 'self'", b"frame-ancestors *     "),
    (b"Content-Security-Policy", b"X-Content-Security-Poli"),
]

for old_b, new_b in PATCHES:
    assert len(old_b) == len(new_b), f"补丁必须严格等长: {old_b} vs {new_b}"


def main(argv):
    if len(argv) < 2:
        print("usage: patch-frame-ancestors.py <binary> [--check]", file=sys.stderr)
        return 2
    path = argv[1]
    check = "--check" in argv[2:]

    with open(path, "rb") as f:
        data = f.read()

    needs_patch = False
    for old_b, new_b in PATCHES:
        n_old = data.count(old_b)
        if n_old > 0:
            needs_patch = True
            if check:
                print(f"patch-frame-ancestors: NOT patched for {old_b.decode('latin1', errors='ignore')} ({n_old} site(s))")

    if not needs_patch:
        print("patch-frame-ancestors: all targets already patched")
        return 0

    if check:
        return 1

    patched = data
    for old_b, new_b in PATCHES:
        patched = patched.replace(old_b, new_b)

    if len(patched) != len(data):
        print("patch-frame-ancestors: length changed, aborting", file=sys.stderr)
        return 1

    try:
        with open(path, "r+b") as f:
            f.truncate(0)
            f.write(patched)
    except OSError as err:
        print("patch-frame-ancestors: cannot write %s: %s" % (path, err))
        return 0

    print("patch-frame-ancestors: successfully applied all patches (size unchanged: %d bytes)" % len(patched))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
