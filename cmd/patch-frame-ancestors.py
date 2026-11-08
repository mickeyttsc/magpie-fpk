#!/usr/bin/env python3
"""Magpie 二进制等长补丁：把插件页 CSP 的 frame-ancestors 'self' 放宽成 frame-ancestors *。

为什么需要（2026-11 实测结论）：
  magpie 给社区插件页（/_magpie/plugin/<token>/index.html）写的响应头是
      Content-Security-Policy: sandbox allow-scripts; ...; frame-ancestors 'self'
  frame-ancestors 校验的是【整条祖先链】。从 fnOS 桌面点图标时，嵌套是三层：
      fnOS 桌面(非 self) → iframe magpie 主界面(无 CSP) → iframe 插件页
  祖先链上出现非 self 的源 → 浏览器直接拒绝渲染该帧，界面只剩灰底 + 「🚫/破损文档」
  占位符。主界面因为没发 CSP 所以一切正常，只有插件页受害。
  上游把这段策略写成常量，没有开关（二进制里 3 处：插件页 / 页面服务 / 服务错误页）。

补丁本身：'self' → '*' 并把腾出的 4 字节补成空格，字节数完全不变，不移动任何偏移。
  'self' 是 6 字节，'*' 是 1 字节，差 5；原串 21 字节 → 新串 21 字节（17 + 4 空格）。
  CSP 的 frame-ancestors *  表示允许任意源嵌入。

安全性：不变的部分仍然生效 —— CSP sandbox allow-scripts（隔离为不透明源）、
  default-src 'none'、connect-src 'none'、img-src 限自身与 data:。插件页依旧没有
  网络、没有 magpie API、没有 cookie；外面嵌它也只能看到静态骨架（握手要父窗口应答）。
  放宽的仅是「谁能嵌这一页」。

幂等：已打过（找不到 'self' 串、能找到 '*' 形式）就原样退出 0；找不到任何目标串时
  以退出码 0 + 提示跳过（上游改了常量不该让 magpie 启不来）。

用法：
  patch-frame-ancestors.py <magpie 二进制路径> [--check]

⚠️ magpie 二进制会被自身自动更新替换，所以每次 start 都要重打（cmd/main 已调用）。
"""

import sys

OLD = b"frame-ancestors 'self'"
NEW = b"frame-ancestors *     "
assert len(OLD) == len(NEW) == 22, "等长是这套补丁的前提"


def main(argv):
    if len(argv) < 2:
        print("usage: patch-frame-ancestors.py <binary> [--check]", file=sys.stderr)
        return 2
    path = argv[1]
    check = "--check" in argv[2:]

    with open(path, "rb") as f:
        data = f.read()

    n_old = data.count(OLD)
    n_new = data.count(NEW)

    if n_old == 0:
        if n_new:
            print("patch-frame-ancestors: already patched (%d site(s))" % n_new)
        else:
            print("patch-frame-ancestors: no target string found, skipped")
        return 0
    if check:
        print("patch-frame-ancestors: NOT patched (%d site(s))" % n_old)
        return 1

    patched = data.replace(OLD, NEW)
    if len(patched) != len(data):
        print("patch-frame-ancestors: length changed, aborting", file=sys.stderr)
        return 1

    try:
        with open(path, "r+b") as f:
            f.truncate(0)
            f.write(patched)
    except OSError as err:
        # 进程正在跑时是 ETXTBSY：不阻断启动，下次 start（先 stop 再 start）会补上
        print("patch-frame-ancestors: cannot write %s: %s" % (path, err))
        return 0
    print("patch-frame-ancestors: patched %d site(s) (size unchanged: %d bytes)" % (n_old, len(patched)))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
