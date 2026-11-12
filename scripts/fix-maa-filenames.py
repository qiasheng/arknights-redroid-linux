#!/usr/bin/env python3
"""修复 MAA 目录里被错误解码的中文文件名（UTF-8 被当成 CP866）。

典型症状：
  MAA 启动时提示「检测到 419 个安装文件缺失」
  目录里出现 DependencySetup_ф╛Эш╡Цх║УхоЙшгЕ.bat
  Res/Backgrounds/Wallpapers/чЙЫчЙЫшбицГЕхМЕ1/
  resource/copilot/old/цЦ╜ф╜йх░Фх▒▒шДЪ_...

原因：ZIP 里的文件名是 UTF-8（flag 0x800），但解压器（常见于 Wine 里的
更新器/解压工具）把原始 UTF-8 字节按 CP866 解码了。文件内容没坏，只是名字坏了。

用法：
  python3 fix-maa-filenames.py                 # 只预览
  python3 fix-maa-filenames.py --apply         # 实际重命名
  python3 fix-maa-filenames.py --root ~/Games/MAA --apply

原理：对每个路径分量做 name.encode('cp866').decode('utf-8')，能成功就说明
它是「UTF-8 字节被当成 CP866」的产物。只改名字，不动内容。
"""

import argparse
import os
import sys

SKIP_TOP = {"config", "data", "debug", "cache", "platform-tools"}


def fix_name(name: str):
    if all(ord(c) < 128 for c in name):
        return None
    try:
        fixed = name.encode("cp866").decode("utf-8")
    except (UnicodeEncodeError, UnicodeDecodeError):
        return None
    if fixed == name or any(c in fixed for c in "/\\\x00"):
        return None
    return fixed


def collect(root: str):
    changes = []

    def walk(path: str):
        with os.scandir(path) as it:
            entries = list(it)
        for entry in entries:
            top = os.path.relpath(entry.path, root).split(os.sep)[0]
            if entry.is_dir(follow_symlinks=False):
                if top in SKIP_TOP:
                    continue
                walk(entry.path)
            fixed = fix_name(entry.name)
            if not fixed:
                continue
            dst = os.path.join(path, fixed)
            if os.path.exists(dst):
                print(f"跳过（目标已存在）: {entry.path} -> {dst}", file=sys.stderr)
                continue
            changes.append((entry.path, dst))

    walk(root)
    return changes


def verify(root: str):
    filelist = os.path.join(root, "filelist.txt")
    if not os.path.exists(filelist):
        print("没有 filelist.txt，跳过校验")
        return 0
    with open(filelist, encoding="utf-8", errors="replace") as f:
        expected = [line.rstrip("\r\n") for line in f if line.strip()]
    missing = [p for p in expected if not os.path.exists(os.path.join(root, p))]
    print(f"filelist 条目: {len(expected)}，缺失: {len(missing)}")
    for p in missing[:10]:
        print("  MISS", p)
    return 1 if missing else 0


def main():
    ap = argparse.ArgumentParser(description="修复 MAA 中文文件名乱码（UTF-8 → CP866）")
    ap.add_argument("--root", default=os.path.expanduser("~/Games/MAA"))
    ap.add_argument("--apply", action="store_true", help="实际重命名；不加只预览")
    args = ap.parse_args()

    root = os.path.abspath(os.path.expanduser(args.root))
    if not os.path.isdir(root):
        sys.exit(f"目录不存在: {root}")

    changes = collect(root)
    print(("将重命名" if not args.apply else "重命名") + f" {len(changes)} 项")
    for a, b in changes[:10]:
        print(f"  {os.path.relpath(a, root)} -> {os.path.relpath(b, root)}")
    if len(changes) > 10:
        print(f"  ... 其余 {len(changes) - 10} 项")

    if args.apply:
        for a, b in changes:
            os.rename(a, b)
        print("完成。")
    else:
        print("这是预览。确认无误后加 --apply。")

    return verify(root)


if __name__ == "__main__":
    sys.exit(main())
