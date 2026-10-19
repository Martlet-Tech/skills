#!/usr/bin/env python3
"""
LVGL 中文字库生成器

从源码的字符串字面量里提取所有非 ASCII 字符, 用 lv_font_conv 生成指定字号的
LVGL 字体 C 文件 (每档都带 ASCII 0x20~0x7F)。

用法示例:
    # 扫描 main/ 下所有 .c, 生成 16/18/22/28/40 五档
    python gen_fonts.py --src main --sizes 16,18,22,28,40

    # 只看会收哪些字, 不生成
    python gen_fonts.py --src main --dry-run

    # 指定字体和输出目录
    python gen_fonts.py --src main/ui.c --ttf C:/Windows/Fonts/simhei.ttf \
                        --out main/fonts --sizes 24,32

依赖:
    Node.js (npx 可联网, 首次会下载 lv_font_conv@1.5.2)
"""

import argparse
import io
import os
import re
import subprocess
import sys

DEFAULT_TTF = "C:/Windows/Fonts/simhei.ttf"
DEFAULT_NPX = "npx"
LV_FONT_CONV = "lv_font_conv@1.5.2"


def iter_sources(paths):
    """展开文件/目录, 只收 .c 和 .h"""
    for p in paths:
        if os.path.isdir(p):
            for root, _, files in os.walk(p):
                for f in files:
                    if f.endswith((".c", ".h")):
                        yield os.path.join(root, f)
        elif os.path.isfile(p):
            yield p
        else:
            print("跳过不存在的路径:", p, file=sys.stderr)


def strip_comments(src):
    """去掉 // 行注释和 /* */ 块注释"""
    src = re.sub(r"/\*.*?\*/", "", src, flags=re.S)
    src = re.sub(r"//[^\n]*", "", src)
    return src


def collect_chars(paths):
    """提取所有字符串字面量里的非 ASCII 字符"""
    chars = set()
    for path in iter_sources(paths):
        try:
            src = io.open(path, encoding="utf-8").read()
        except UnicodeDecodeError:
            print("跳过非 UTF-8 文件:", path, file=sys.stderr)
            continue
        src = strip_comments(src)
        for lit in re.findall(r'"((?:[^"\\]|\\.)*)"', src):
            chars.update(c for c in lit if ord(c) > 127)
    return "".join(sorted(chars))


def gen(size, symbols, ttf, out_dir, bpp, npx):
    out = os.path.join(out_dir, "ui_font_%d.c" % size)
    cmd = [
        npx, "--yes", LV_FONT_CONV,
        "--font", ttf,
        "--size", str(size),
        "--bpp", str(bpp),
        "--format", "lvgl",
        "--no-compress",
        "--no-kerning",
        "--lv-include", "lvgl.h",   # 关键: 默认会生成 lvgl/lvgl.h, IDF 下找不到
        "-r", "0x20-0x7F",
        "--symbols", symbols,
        "-o", out,
    ]
    print("  %2dpx -> %s" % (size, os.path.basename(out)))
    r = subprocess.run(cmd, capture_output=True, text=True, shell=True)
    if r.returncode != 0:
        print("    失败:", (r.stderr or r.stdout).strip()[-400:], file=sys.stderr)
        return False
    return True


def main():
    ap = argparse.ArgumentParser(description="生成 LVGL 中文字库")
    ap.add_argument("--src", nargs="+", default=["main"], help="源码文件或目录 (默认 main)")
    ap.add_argument("--ttf", default=DEFAULT_TTF, help="TTF/TTC 字体路径")
    ap.add_argument("--sizes", default="16,18,22,28,40", help="字号, 逗号分隔")
    ap.add_argument("--out", default="main/fonts", help="输出目录")
    ap.add_argument("--bpp", type=int, default=4, help="位深 1/2/4/8 (默认 4)")
    ap.add_argument("--npx", default=DEFAULT_NPX, help="npx 可执行文件路径")
    ap.add_argument("--dry-run", action="store_true", help="只打印字符集, 不生成")
    args = ap.parse_args()

    if not os.path.exists(args.ttf):
        print("找不到字体文件:", args.ttf, file=sys.stderr)
        return 1

    symbols = collect_chars(args.src)
    print("提取到 %d 个非 ASCII 字符:" % len(symbols))
    print(" ", symbols or "(无)")
    print()

    if args.dry_run:
        return 0

    if not symbols:
        print("没有需要生成的中文字符, 退出")
        return 0

    os.makedirs(args.out, exist_ok=True)
    sizes = [int(s) for s in args.sizes.split(",") if s.strip()]
    ok = True
    for size in sizes:
        ok &= gen(size, symbols, args.ttf, args.out, args.bpp, args.npx)

    print()
    if ok:
        print("完成。记得把 %s/*.c 加进 CMakeLists 的 SRCS," % args.out)
        print("并在代码里用 LV_FONT_DECLARE(ui_font_<size>) 声明。")
    else:
        print("有字号生成失败", file=sys.stderr)
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
