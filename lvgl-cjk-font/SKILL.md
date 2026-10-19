---
name: lvgl-cjk-font
description: >
  Make Chinese (CJK) text render correctly in LVGL — fixes missing glyphs shown
  as tofu boxes, wrong/missing font sizes, and flash-size blowups. Generates
  custom lv_font_conv bitmap fonts containing only the characters the UI
  actually uses, at the sizes the design needs. Use when a user says 中文显示成
  方块 / 缺字 / 乱码 / 字体太小 / 字号不对 / LVGL 中文 / 中文字库 / lv_font_conv /
  CJK font / font not rendering, or when porting an HTML/web design to LVGL that
  contains Chinese copy.
---

# LVGL 中文字体

## 什么时候用

- LVGL 界面上中文显示成 **方块 / 问号 / 空白**（缺字）
- 中文只能显示很小（16px），设计里 24/32/40px 的标题层级丢失
- 移植网页设计稿到 LVGL，里面有大段中文
- 想加中文但不知道要不要 `LV_FONT_SIMSUN_16_CJK`

## 根因

LVGL 的字体是**编译期固定的静态点阵**，字号和字符集在生成时就定死了。所以：

- 内置的 `lv_font_simsun_14_cjk` / `lv_font_simsun_16_cjk` **只有 14/16px 两档**，
  且**覆盖不全**（实测「识」「别」「请」都缺）
- 想显示 40px 中文 → 必须生成 40px 的字库，没有别的办法
- 用 `lv_obj_set_style_transform_scale` 缩放 16px 字库只是把方块放大，不能补字

## 三条路线

| 方案 | 适用 | 代价 |
|---|---|---|
| **`lv_font_conv`（首选）** | 文案固定、资源受限的嵌入式 UI | 加字要重新生成 |
| 在线转换器 lvgl.io/tools/fontconverter | 不想装 Node | 同样的产物，手工操作 |
| `lv_tiny_ttf` / FreeType | 文案不固定、能放得下 TTF | 运行时解析，占 RAM/CPU，要带 TTF 文件 |

默认走 `lv_font_conv`。它把 TTF 转成 C 数组，`--symbols` 只收用到的字，
一个 40px 中文 75 字 + ASCII 的字库大约 60~80 KB。

## 标准流程

### 1. 提取字符（只从字符串字面量，跳过注释）

注释里的中文和框线符号不该进字库，否则白占空间：

```python
import io, re
src = io.open(path, encoding="utf-8").read()
src = re.sub(r"/\*.*?\*/", "", src, flags=re.S)   # 去块注释
src = re.sub(r"//[^\n]*", "", src)                 # 去行注释
chars = sorted({c for lit in re.findall(r'"((?:[^"\\]|\\.)*)"', src)
                  for c in lit if ord(c) > 127})
```

### 2. 生成字库

```bash
npx --yes lv_font_conv@1.5.2 \
  --font "C:/Windows/Fonts/simhei.ttf" \
  --size 40 --bpp 4 \
  --format lvgl \
  --no-compress --no-kerning \
  --lv-include lvgl.h \
  -r 0x20-0x7F \
  --symbols "$SYM" \
  -o main/fonts/ui_font_40.c
```

每个设计字号都要单独跑一次（16 / 18 / 22 / 28 / 40 …）。

### 3. 加进构建

```cmake
idf_component_register(
    SRCS
        "ui.c"
        "fonts/ui_font_16.c"
        "fonts/ui_font_22.c"
        "fonts/ui_font_40.c"
        ...
)
```

### 4. 声明并使用

```c
LV_FONT_DECLARE(ui_font_40);           /* 变量名 = 输出文件名 */
#define F_CJK_40 (&ui_font_40)

lv_obj_set_style_text_font(label, F_CJK_40, 0);
```

不需要改 `lv_conf.h` 的 `LV_FONT_CUSTOM_DECLARE`——`LV_FONT_DECLARE` 就够。

### 5. 关掉内置 CJK，省几百 KB

`sdkconfig`（或 menuconfig → LVGL → Font usage）：

```
# CONFIG_LV_FONT_SIMSUN_16_CJK is not set
```

## 关键参数（都是踩过的）

| 参数 | 为什么必须 |
|---|---|
| `--lv-include lvgl.h` | **不加会编译失败**。默认生成 `#include "lvgl/lvgl.h"`，而 IDF 组件把 lvgl 根目录直接加进 include path，找不到 `lvgl/lvgl.h` |
| `--no-compress` | 默认压缩，需要 `LV_USE_FONT_COMPRESSED`；没开就链接失败 |
| `--no-kerning` | 中文没有字距调整，省体积 |
| `--bpp 4` | 4bit 抗锯齿；1bpp 锯齿明显，8bpp 体积翻倍 |
| `-r 0x20-0x7F` | 带上 ASCII，否则数字/英文也要单独找字体 |
| `--symbols "$SYM"` | **1.5.2 没有 `--symbols-file`**，只能传字符串 |

传中文符号串时 shell 编码容易出错，先把字符写进临时文件再 `SYM=$(cat file)`。

## 常见坑

- **加了新文案又出现方块** → 字库没重新生成。写个脚本把「提取 + 生成」串起来，
  改完文案跑一次（见 `scripts/gen_fonts.py`）。
- **编译报 `lvgl/lvgl.h: No such file`** → 忘了 `--lv-include lvgl.h`
- **`--symbols-file` 报 unrecognized arguments** → 版本不支持，用 `--symbols`
- **字库体积爆炸** → 用了 `-r 0x4E00-0x9FFF`（两万多字）。永远只收用到的字
- **字体选择**：UI 用**黑体**（`simhei.ttf` / 思源黑体）比宋体清晰；
  数字/拉丁优先用 Montserrat，字形更规整
- **中文和 Montserrat 混排**：中文用定制字库，数字/时钟用 Montserrat，
  按控件分别 `lv_obj_set_style_text_font`

## 字号建议（720×1280 竖屏参考）

| 字号 | 用途 |
|---|---|
| 40 | 主状态标题 |
| 28 | 人员姓名 / 大标题 |
| 22 | 品牌标题、副标题 |
| 18 | 正文：状态栏、位置、日期、列表项 |
| 16 | 页脚、辅助小字 |

## 验收

1. 编译通过，`idf.py size` 里字库占几百 KB 以内
2. 屏幕上中文**全部**能显示，没有方块
3. 大标题的字号与设计稿一致
4. 换几屏不同文案扫一遍，确认没有漏字

## 脚本

`scripts/gen_fonts.py` —— 通用版：扫描源码里的字符串、提取字符、
按给定字号批量生成。

```bash
# 只看会收哪些字
python gen_fonts.py --src main/ui_access_control.c --dry-run

# 生成
python gen_fonts.py --src main/ui_access_control.c --sizes 16,18,22,28,40
```

`--src` 要**只指向 UI 源文件**，不要扫整个 `main/`——驱动里的日志字符串
（"触控复位失败"之类）永远不会显示，收进字库只是白占 flash。
