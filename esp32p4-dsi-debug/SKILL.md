---
name: esp32p4-dsi-debug
description: >
  调试 ESP32-P4 MIPI DSI 显示异常（画面斜线/错位/撕裂/反色/花屏/颜色不对）
  与 TDDI 触屏不报点的实战方法。包含 P4 DSI 时钟链的整数截断陷阱、
  时序量与速率的区分方法、porch 作为功能量（VBP 决定颜色、VFP 决定触控扫描）、
  用 VPG 自检图案切分故障域及其边界、INT_ST1 与 bridge FIFO 的读法、
  RGB888 字节序、从面板读寄存器（DSI 读通路的四个坑）、以及
  "不改 IDF 直接用 hal 私有 inline 改 host 行为"的做法。
  含两套已验证参数：VFP=166 + DPI=30MHz + lane=480（480x800），
  VBP=6 + DPI=40MHz + lane=640/800（540x810 incell）。
  Use when the user reports ESP32-P4 DSI 画面斜线 / 错位 / 竖条歪 / 分段 /
  撕裂 / 反色 / 颜色不对 / 单通道变补色 / 读不到面板寄存器 /
  DCS read / gen_rd_cmd_busy / 触屏不工作 / TDDI 无报点 / VFP / VBP /
  porch / lane bitrate / dpi clock / VID_HLINE_TIME / mipi_dsi /
  esp_lcd_panel_dpi.
---

# ESP32-P4 DSI 调试

面向"画面不对"和"触屏不动"这两类症状的排查路径。核心结论先给：

> **P4 的 DSI 时钟链有三处整数截断。绝大多数"画面斜线/错位"类问题，
> 根因是这个，不是面板、不是初始化、不是 burst 模式。**
>
> **但"颜色不对"是另一条线** —— 多半不是时钟，而是 porch（尤其 VBP）与
> 面板的匹配问题。见第十三节。

## 零、症状 → 章节

| 症状 | 先看 |
|---|---|
| 竖条被扭成斜线 / 分段 / 错位 / 撕裂 | 二 ~ 五（时钟链与 ratio） |
| 颜色不对、单通道满值变成补色、双通道满值变淡色 | **十三（porch 是功能量）** |
| 红蓝互换、白黑正常 | 八（字节序） |
| 整屏反色（白变黑） | 八（多半是 flush 里多做了一次 R/B 交换） |
| 读不到面板寄存器 / 读一次就黑屏 | **十四（DSI 读通路）** |
| 想在不动 IDF 的前提下改 host 行为 | **十五（hal 私有 inline）** |
| 画面正常但触屏不报点 | 七（VFP）+ 七·附（incell 差异） |

---

## 一、先切故障域（最省时间的一步）

**不要一上来就改参数。** 先用 DSI host 自带的 VPG（视频图案生成器）把系统切成两半：

```c
// 面板 init + disp_on 之后再调用
esp_lcd_dpi_panel_set_pattern(mipi_dsi_panel, MIPI_DSI_PATTERN_BAR_VERTICAL);
```

它内部会执行 `mipi_dsi_brg_ll_enable_dpi_output(bridge, false)`，**关掉 bridge 的 DPI 输出**，
改由 host 内部直接生成图案。

判读：

| VPG 图案 | 说明 | 故障域 |
|---|---|---|
| 干净、笔直、无扭曲 | 面板 / PHY / init 序列 / COLMOD / lane 数 / sync 极性 / **host 全套时序寄存器** 全对 | 数据来源侧（framebuffer / bridge DPI 通路 / LVGL 缓冲） |
| 也歪 / 也花 | 问题在更下游或面板本身 | PHY / 面板 |

**注意**：VPG 走 host 内部，**不经过 framebuffer 和 bridge**，所以它同时也证明了
像素格式、通道顺序之外的链路是好的。

### ⚠️ VPG 的边界：它对"颜色"不是干净的判据

VPG 只绕过了 framebuffer 和 bridge，**没有绕过 host 的打包器和 PHY**。
所以当问题出在"包怎么发出去"这一层（时序错位、porch 不匹配、lane 上字节对齐）
时，**VPG 会一样错**。

实测反例（540×810 incell，VBP 少 2 行）：VPG 八色条显示成

```
白 淡蓝 淡红 粉紫 淡绿 青 黄 黑
```

八条的**身份和顺序都对**（就是标准 8 色条），但每条的颜色全变了 —— 而且
8/8 都符合同一个"两字节平均"的规律。这时候如果按"VPG 干净 → 链路没问题"
去判，会直接错过真因。

**所以：用 VPG 判几何/是否出图，不要用 VPG 判颜色。**
颜色请走第十三节的判据表。

图案类型（`mipi_dsi_pattern_type_t`）：

- `PATTERN_BAR_VERTICAL` / `PATTERN_BAR_HORIZONTAL` —— 彩条，验颜色
- `PATTERN_BER_VERTICAL` —— 8 级灰度竖条，用于看几何是否笔直
- `PATTERN_NONE` —— 关掉，恢复正常通路

**坑**：用了 pattern 就**必须**使用 `PATTERN_NONE` 或不再调用，才能让 `draw_bitmap` 上屏。
忘了关会得到"画什么都没反应"的假象。

---

## 二、时钟链：三处整数截断（**核心章节**）

P4 的 DPI 时钟不是直接设的，是从 `PLL_F240M` 分频出来的，中间三次整数运算：

### 第 1 处：DPI 目标频率宏（如果你的工程按帧率反算）

很多工程这样写：

```c
#define DPI_CLK_MHZ  (H+HSW+HBP+HFP) * (V+VSW+VBP+VFP) * 60 / 1000000
```

**C 的整数除法直接截断。** `576*984*60/1e6 = 34.007` → `34`。

### 第 2 处：分频器（IDF 内部，改不了）

`esp_lcd_panel_dpi.c`：

```c
uint32_t dpi_div = mipi_dsi_hal_host_dpi_calculate_divider(hal, 240, panel_config->dpi_clock_freq_mhz);
```

`mipi_dsi_hal.c`：

```c
uint32_t div = clk_src_mhz / expect_dpi_clk_mhz;   // 整数除法
hal->dpi_clock_freq_mhz = clk_src_mhz / div;       // ★ uint32, 再截断一次
```

真实时钟是 `240/div`，但**存进 `hal->dpi_clock_freq_mhz` 的是截断后的整数**。

| 目标宏值 | div = 240/目标 | **真实时钟** | **存进结构体的** | 误差 |
|---|---|---|---|---|
| 28 | 8 | 30.0000 | 30 | 0 |
| 29 | 8 | 30.0000 | 30 | 0 |
| **34** | **7** | **34.2857** | **34** | **+0.84%** |

### 第 3 处：行时序换算（每个分段独立截断）

`mipi_dsi_hal.c`：

```c
float dpi2lane_clk_ratio = (float)hal->lane_bit_rate_mbps / hal->dpi_clock_freq_mhz / 8;
mipi_dsi_host_ll_dpi_set_horizontal_timing(hal->host,
        hsw * ratio, hbp * ratio, active * ratio, hfp * ratio);
```

**用的是第 2 处那个截断过的整数**，而且四个分段各自取整后才相加。

### 后果

```
行时间 = hline / byteclk = HTOTAL / dpi_clock_freq_mhz（存储值）
```

**行时间只取决于那个整数。** 所以 VFP=166 时：

```
名义 576/34      = 16.9412 us
实际像素行 576/34.2857 = 16.8000 us
永久 +0.84% 误差 —— 与 lane 速率完全无关，改 lane 消不掉
```

累积到 800 行约错开 6~7 行，表现为**竖条被扭成若干段斜线**。

---

## 三、最关键的判据：整数边界突变

实测（本工程真实数据，VFP 单轴扫描）：

| VFP | 总行 | 宏值 | div | 真实 DPI | 是否精确 |
|---|---|---|---|---|---|
| 21 | 839 | 28 | 8 | 30.0000 | ✓ |
| **22** | **840** | **29** | **8** | **30.0000** | ✓ |
| 166 | 984 | 34 | 7 | 34.2857 | ✗ |

**21 和 22 的真实 DPI 时钟完全一样（都是 30.0000）**，因为 `240/28` 和 `240/29`
经整数除法后**都得到 div=8**。

所以 21 好、22 坏这个断点，**是纯算术产物，不是任何物理量**。

> **判据：物理系统不会在 21 和 22 之间突然坏掉。整数边界会。**
> 看到响应在"整数感"的位置突变，先怀疑算术，不要怀疑物理。

这条能直接推广：PLL 分频、DMA 长度、对齐、字节宽度，凡是涉及整数除法的黑盒，
都先问一句"这里有没有取整"。

---

## 四、把旋钮分成两类：时序量 vs 速率

调试时最容易犯的错是在这两类之间**混着改**，导致无法归因。

| 类别 | 具体参数 | 能不能随便改 |
|---|---|---|
| **时序量** | HSYNC / HBP / HFP / VSYNC / VBP / VFP、`VID_HLINE_TIME`、porch | **不要改**。改了会破坏与面板初始化序列的匹配，也破坏行内比例 |
| **速率** | `lane_bitrate`、`byteclk`、`ratio` | 可以改，这是唯一应该动的维度 |

> **例外 —— porch 不是"装饰"**：上表"不要改"针对的是**几何类**问题（改 hline 会让每行
> 固定错位，是换一种坏法）。但进 porch 的 VBP/VFP 同时是**功能量**：
> VFP 不够则触控扫描不完（第七节），VBP 错位会让面板解包错位、颜色全错（第十三节）。
> 正确姿势是：**porch 跟面板数据手册对齐**，对齐之后不再拿它当调几何的旋钮。

关键恒等式：

```
ratio    = lane_bitrate / dpi_clock_real / 8
hline    = HTOTAL * ratio
byteclk  = lane_bitrate / 8
=> hline / byteclk = HTOTAL / dpi_clock_real
```

**行时间与 lane 速率无关**，所以改 lane **不会改变任何时序量**，
只改变两件事：`byteclk`（取数快慢）和 `ratio` 的取整情况。

**这就是为什么"只改速率"是安全的实验方向。**

### 反例：单独改 `VID_HLINE_TIME`

有人会想"那我直接把 hline 拉长，给行末留余量"。**不要这么做。**

IDF 的 LL 封装把 hline 强制为四段之和：

```c
dev->vid_hline_time.vid_hline_time = active_width + hsw + hbp + hfp;
```

绕过它单独写 hline，会让整行变长但有效像素位置不变，结果**每行产生一个固定的
水平错位**（实测：+5% 的 hline 导致每行左移 16~32px，全部连续歪斜、看不出分段）。
这是"换了一种错法"，不是修复。

### 正确做法：让 ratio 成为精确整数

`ratio` 必须能被四个分段整除，否则 `active`、`hbp`、`hfp` 各自截断，
行内节拍不再等比。

**取 ratio = 2.0 就能做到零截断**，条件是：

```
lane_bitrate = 2 * dpi_clock_real * 8 = 16 * dpi_clock_real
```

例如 `dpi = 30MHz → lane = 480`，此时：

```
hsa  12*2 = 24
hbp  42*2 = 84
act 480*2 = 960
hfp  42*2 = 84
hline = 1152，byteclk = 60MHz
行时间 = 1152/60 = 19.2us = 576/30MHz  精确相等
```

而且 `dpi=30` 本身必须是 240 的整数分频（`div=8`），否则第 2 处截断又在作怪。

---

## 五、一套已验证可用的参数

以 480×800、2 lane、RGB888、30MHz 级 DPI 为例：

```c
#define HSYNC 12
#define HBP   42
#define HFP   42
#define VSYNC 4
#define VBP   14
#define VFP   166        // 原厂值，TDDI 触屏需要；见第七节

#define DPI_CLK_MHZ          30    // ★ 固定值，不要用帧率反算公式
#define LANE_BITRATE_MBPS    480   // ★ 固定值 = 16 * 30，使 ratio = 2.000000
```

实际生效：

```
div = 240/30 = 8，真实 DPI = 30.0000，存储 = 30   ← 零截断
ratio = 480/30/8 = 2.000000                        ← 零截断
hline = 1152，byteclk = 60MHz，行时间 = 19.2us     ← 与像素行精确相等
帧率 = 30e6/(576*984) = 52.93 Hz
垂直消隐 = (4+14+166) * 576/30MHz = 3.533 ms
```

帧率比 60Hz 低，这是钉死整数分频的代价。**如果面板要求 ≥55Hz**，可改
`DPI=40MHz`（`div=240/40=6`，精确），`ratio=2` 需 `lane=640`，帧率 70.57Hz，
消隐 2.650ms（仍够触屏）。

**注意**：`DPI=32` 或 `DPI=34` 这类值**不行**，因为 `240/32=7` 余 16，
真实时钟变成 `240/7=34.2857`，又回到截断问题。**只有 240 的约数才安全**：
`24, 30, 40, 48, 60`（对应 div `10, 8, 6, 5, 4`）。

### 第二套：540×810 incell TDDI（RGB888，2 lane）

```c
#define HSW  10
#define HBP 120
#define HFP 120
#define VSW  13
#define VBP   6        // ★ 8 会颜色全错，6 才对（第十三节）
#define VFP 110

#define DPI_CLK_MHZ        40     // 240/6 = 40.0000，零截断
#define LANE_NUM            2
#define LANE_MBPS         640     // ratio = 640/40/8 = 2.0（实测 800 也正常，ratio 2.5）
```

```
HTOTAL = 790，VTOTAL = 939
帧率 = 40e6/(790*939) = 53.92 Hz
垂直消隐 = 129 行 * 19.75us = 2.548 ms
```

两套参数说明同一件事：**DPI 取 240 的约数、ratio 取整数**是通用的；
而 **VBP/VFP 只能由面板给**，各面板不同，不能照抄。

---

## 六、诊断手段（按信息量排序）

### 1. 回读实际生效的行时序寄存器

`IDF` 的 `_act` 影子寄存器**不可信**——实测 `vid_mode_cfg_act`、`vid_hsa_time_act`
等全部读作 **0**，连 `vid_mode_type_act` 都是 0，而视频输出明明是正常的。
说明这组 RO 寄存器在该 IP 上没实现或没接线。

**只能读 R/W 值**：

```c
uint32_t hsa   = dev->vid_hsa_time.vid_hsa_time;
uint32_t hbp   = dev->vid_hbp_time.vid_hbp_time;
uint32_t hline = dev->vid_hline_time.vid_hline_time;
// 反推 ratio：hsa/HSYNC_px, hbp/HBP_px, hline/HTOTAL 应三者相等
```

**判据**：三个反推值一致 → `ratio` 正确；不一致 → 某个分段被截断了。

### 2. INT_ST1 错误寄存器

`DSI_HOST_INT_ST1_REG (0x00C0)`，**读后自动清除**，必须高频轮询 + 累计：

| 位 | 名称 | TRM 含义 |
|---|---|---|
| 7 | `dpi_pld_wr_err` | DPI 像素行存储期间 payload FIFO 变满、数据损坏 |
| 19 | `dpi_buff_pld_under` | 读取 payload 构建 DSI 包时发生下溢 |
| 4/3/2 | crc / ecc_multi / ecc_single | 链路层错误 |

**实测经验**：画面正常的和异常的两组配置，`dpi_pld_wr_err` **都是约每行一次**
（命中率 23%，折算 0.7 次/行），`dpi_buff_pld_under` **始终为 0**，
crc/ecc **全 0**。

> **结论：`dpi_pld_wr_err` 是每行结束时的伴生信号，不能作为故障判据。**
> 看到它不要当成"找到了原因"。

### 3. FIFO 状态（RO 实时值，可高频采样）

```
DSI_HOST_VID_PKT_STATUS_REG (0x168)
  bit2  dpi_pld_w_empty    bit3  dpi_pld_w_full
  bit16 dpi_buff_pld_empty bit17 dpi_buff_pld_full

DSI_BRG_FIFO_FLOW_STATUS_REG (0x0014)
  raw_buf_depth[13:0]      bridge FIFO 当前深度（满值 1024）
```

实测水位（正常 vs 异常）：

| 指标 | 异常配置 | 正常配置 |
|---|---|---|
| `dpi_pld_w_full` | 0% | 0% |
| `dpi_pld_w_empty` | 6% | 17% |
| `dpi_buff_pld_full` | 62% | 47% |
| `brg_depth` min/avg/max | 767/882/1020 | 767/882/1020 |

**`brg_depth` min 恒为 767**，正好等于 IDF 设的 `empty_threshold = 1024-256 = 768`。
说明 DMA 供数及时、bridge 不饿。**`brg_depth` 从不贴 0 → 排除带宽/供数不足。**

**注意**：FIFO 水位差异是"结果"不是"原因"——两侧速率一变水位必然变，
不要用"水位不同"来解释画面好坏。

### 4. 采样任务别打死看门狗

高频轮询寄存器时务必 `taskYIELD()`：

```c
while (elapsed < 100000) {
    for (int i = 0; i < 512; i++) dsi_ll_fifo_sample();
    taskYIELD();                 // ★ 不加会饿死 IDLE，每秒一个 task_wdt
    elapsed = esp_timer_get_time() - t0;
}
```

纯轮询 10 万次/100ms 就足以触发看门狗。

---

## 七、TDDI 触屏：VFP 是硬约束

TDDI（触控集成在显示驱动 IC 里）的**触控扫描必须插在垂直消隐期内完成**。
本类面板实测需要 **2.541 ms**。

```
触控扫描窗口 = (VSYNC + VBP + VFP) * HTOTAL / dpi_clock
```

480×800 / 30MHz 下，每行 19.2 us：

| VFP | 消隐行数 | 窗口 | 触屏 |
|---|---|---|---|
| 16 | 34 | 0.65 ms | ✗ |
| 22 | 40 | 0.77 ms | ✗ |
| 114 | 132 | 2.53 ms | 临界 |
| **140** | **158** | **3.03 ms** | ✓ |
| **166** | **184** | **3.53 ms** | ✓ |

**实测结论：VFP ≥ 140 触屏才好使。** 这是硬约束，不能靠软件绕过。

**症状**：VFP 太小时，I2C 能读到器件、能 ACK，但**永远读到固定的一串无效字节**
（如 `00 79 84 F9 00...`），从不出现正常的 `0x5A` 包首，INT 恒为低。

> 所以"画面正常但触屏不动"时，**先看 VFP**，不要先怀疑 I2C 地址或驱动。

### 附：incell 面板（触摸与显示同 die）的额外差异

外挂触摸 IC（上面这套经验）与 incell TDDI 在工程上差别不小：

| 项 | 外挂 IC（如 ILITEK） | incell TDDI（如 AXS15260） |
|---|---|---|
| 复位 | 独立 RESX | **与显示同一颗 die**：复位 TP = 复位整颗芯片，之后显示寄存器要重配 |
| 时序要求 | — | TP 复位必须在 LCD 复位之后；TP 寄存器读写必须放在显示初始化**之后**，且与 `11h/29h` 间隔 >100ms |
| INT | 有数据才拉低 | 常见**每帧一个脉冲**（空闲也在打），所以要按"读回来是不是有效帧"过滤 |
| 读长度 | 按协议包长 | 按**实际点数**算：头 2 字节 + 每点 6 字节。按最大 5 点读 32 字节会把相邻寄存器读进来，表现为"周期性重复的垃圾帧" |

**无效帧的判据**：`buf[1] >> 4 != 0` 直接丢（原厂驱动同款判断）。
**不要**用"把点数夹紧到合法范围"的方式处理——那只是把无效帧伪装成合法帧，
会打出 `X=4095 Y=4095` 这种满量程假点。

**结构上**：INT 下降沿 → ISR 只给信号量 → 任务里读字节 → 队列 → 前台解析。
不要照抄原厂"在中断回调里做 I2C 读"的写法（它自己的注释都写着会丢中断）。

---

## 八、RGB888 字节序：硬件要 BGR

P4 TRM 43.4.1 表 43.4-1 明确规定 RGB888 的内存排列：

```
Addr+0 = B0    Addr+1 = G0    Addr+2 = R0
```

**最低字节是蓝，不是红。** 所以手写 framebuffer 时必须按 B,G,R 落盘：

```c
p[0] = B;  p[1] = G;  p[2] = R;      // 正确
```

反了会得到**只有 R 和 B 互换**的画面（黄↔青、红↔蓝；白/绿/紫/黑因对称不变）。

### `rgb_ele_order` 在 DSI 路径下无效

`esp_lcd_panel_dev_config_t.rgb_ele_order` 这个字段**在 DSI 驱动里没有任何代码读取**
（`esp_lcd_panel_dpi.c` 里搜不到）。它只对 SPI 面板驱动生效（用来生成 MADCTL）。
**不要指望它来切通道顺序。**

### LVGL 已经是 BGR，不要多此一举

```c
// lvgl__lvgl/src/misc/lv_color.h
typedef struct { uint8_t blue; uint8_t green; uint8_t red; } lv_color_t;
```

**LVGL 的内存布局天然是 B,G,R，正好与硬件一致。**
如果在 `flush_cb` 里"贴心"地做一次 R/B 对调，画面会**整体反色**。

这是一个真实的踩坑：调试测试图时因手写 RGB 需要交换，就把交换塞进了公共的
`flush_cb`，结果测试图对了、LVGL 反了。**正确做法是让每个数据源自己负责字节序，
公共通路保持透传。**

---

## 九、IDF 侧可能需要打的补丁

> **先看第十五节。** 多数"IDF 不给这个能力"的情况**不需要改 IDF**——
> 直接包含 `hal/*_ll.h` 里的 `static inline` 就能调。改源码是最后手段。

本类面板的初始化命令用 DCS 短包发送时，某些固件不认。IDF 默认走：

```c
mipi_dsi_hal_host_gen_write_dcs_command(...);
```

需要改成 GENERIC 长包发送（把 cmd 拼进 payload 头部）：

```c
int payload_size = 1 + param_size;
uint8_t *payload = malloc(payload_size);
payload[0] = lcd_cmd;
memcpy(payload + 1, param, param_size);
mipi_dsi_hal_host_gen_write_generic(hal, vc, payload, payload_size);
```

改动位于 `components/esp_lcd/dsi/esp_lcd_panel_io_dbi.c`，
并且需要在 `components/hal/mipi_dsi_hal.c` + 头文件里新增
`mipi_dsi_hal_host_gen_write_generic()` 实现。

**这类改动必须记录下来**——否则换台机器用干净 IDF 编出来的固件行为不一样，
而且不报错，最难查。

---

## 十、已排除的方向（不要再试）

以下都实测过，**对本类"画面斜线"无效**：

| 方向 | 实测结果 |
|---|---|
| burst → non-burst 视频模式 | 画面毫无变化 |
| `VID_NUM_CHUNKS` = 0 / 1 / 2 | `dpi_pld_wr_err` 命中率 23.31% / 23.33% / 23.29%，无差异 |
| 启用 BLLP 空包 (`VID_NULL_SIZE`) | 未改善 |
| 单独拉长 `VID_HLINE_TIME` | 变成每行固定错位，是另一种坏法 |
| 提高 lane 速率（余量 1.5x / 2x） | 与画面好坏无关（行时间不由 lane 决定） |
| 查 DMA / 带宽不足 | `brg_depth` 从不贴 0，无证据 |
| 改 `_act` 影子寄存器 | 全读 0，无意义 |

---

## 十一、排查顺序建议

```
画面斜线 / 错位 / 分段
  ├─ 1. 先出 VPG 图案，切故障域（第一节）
  │     └─ VPG 干净 → 问题在 bridge 的 DPI 写入侧
  ├─ 2. 检查 DPI 时钟是否 240 的整数分频（第二节）
  │     └─ 不是（如 34.2857）→ 钉死成 24/30/40/48 之一
  ├─ 3. 检查 ratio 是否精确整数（第四节）
  │     └─ 取 lane = 16 * dpi，使 ratio = 2.0
  ├─ 4. 回读 hsa/hbp/hline，反推 ratio 三者是否一致
  └─ 5. 以上都对，再怀疑面板 / PHY / 初始化序列

触屏不动
  ├─ 1. 读到的包首是不是 0x5A（不是 → 触控从未扫描）
  ├─ 2. VFP 是否 ≥ 140（消隐窗口 ≥ 2.541ms）★ 最常见
  └─ 3. I2C 地址（常见 0x41，注意不是出厂默认 0x55）

颜色不对
  ├─ 1. 别先猜通道顺序。按第十三节的四组观测归类（单通道×3 + 白 + 黑）
  ├─ 2. "单通道满值→补色、双通道满值→淡色、白黑正常"
  │     → 位级交织：查 porch，先动 VBP ★ 本类最常见
  ├─ 3. 红↔蓝互换、绿/白/黑不变 → 字节序（第八节）
  ├─ 4. 整屏反相（白变黑）→ flush 里多做了一次 R/B 交换
  └─ 5. 以上都不是 → 再查 color format / lane / burst / 拷贝路径
```

---

## 十二、坑速查

| 坑 | 说明 |
|---|---|
| 用帧率反算 DPI 时钟 | 整数除法截断，产生 0.8% 级永久误差 |
| `dpi_clock_freq_mhz` 被截断 | `240/div` 存成 uint32，真实值丢失 |
| ratio 用截断后的时钟算 | 四段各自取整，行内节拍不等比 |
| 以为改 lane 会改行时间 | `hline/byteclk = HTOTAL/dpi_real`，与 lane 无关 |
| 单独改 `VID_HLINE_TIME` | 每行固定水平错位，另一种坏法 |
| 信 `_act` 影子寄存器 | 实测全为 0，未实现 |
| 把 `dpi_pld_wr_err` 当病因 | 正常配置下也每行一次，是伴生信号 |
| VPG 忘了关 | `PATTERN_NONE` 不调用，`draw_bitmap` 不上屏 |
| 手写 framebuffer 按 RGB | 硬件要 BGR，R/B 会互换 |
| LVGL 再做一次 R/B 交换 | LVGL 已是 BGR，交换导致整体反色 |
| 指望 `rgb_ele_order` | DSI 路径不读这个字段 |
| VFP 太小 | 触屏扫描窗口不足，I2C 能通但不报点 |
| 高频轮询不加 yield | 触发 task_wdt，污染采样数据 |
| 改了 IDF 没记录 | 换机器编出来的固件行为不同，且不报错 |
| 用 VPG 判颜色 | VPG 只绕过 framebuffer/bridge，没绕过打包器；porch 错时它一样错 |
| 颜色错就先查字节序/格式 | 本类真因常是 VBP 与面板不匹配，改格式全无效 |
| 用颜色名字当证据 | "粉"和"紫"分不清；用"单通道/双通道/白/黑"四组结构判 |
| 读请求按 HS 发（默认值） | 写走 LP、读走 HS，面板收不到，`gen_rd_cmd_busy` 永久为 1 |
| 在初始化表中途读寄存器 | 读挂了剩下半张表全丢，屏必黑，且不可恢复 |
| 指望 `TO_CNT_CFG` 超时解脱 | 那是竞争检测计数器，TRM 明写"不产生中断" |
| 以为 `reset_register()` 会复位 host | 它只复位 `reg_rst_en_dsi_brg`（bridge） |
| 无效帧"夹紧点数" | 把无效帧伪装成合法帧，会打出满量程假点；应整帧丢弃 |

---

## 十三、porch 是功能量：VBP 决定颜色

上一版把 porch 整块归进"时序量，不要随便改"（第四节）。那条对**几何问题**成立，
但不能推广：porch 不只是"给行末留余量"，它决定面板的行为状态。

### 实测：VBP 8 → 6，颜色从错变对

540×810 incell TDDI，RGB888，burst，2 lane。`VBP=8` 时 LVGL 画纯红绿蓝得到：

```
红 → 青      绿 → 粉      蓝 → 黄      白 → 白      黑 → 黑
```

只把 `VBP` 从 8 改成 6，其它参数一个没动，**全部正常**。（面板厂 FAE 给的数字。）

### 判据：从"颜色错成什么样"反推故障类别

不要用颜色名字（"粉"还是"紫"）当证据，用**结构**判：

| 观测 | 结论 |
|---|---|
| 单通道满值 → **补色**；双通道满值 → **淡色**；白/黑正常 | **位级交织** —— 每个输出通道拿到的是另外两个源字节的一部分。查 porch（尤其 VBP），或包的字节对齐 |
| 红↔蓝 互换，绿/白/黑不变 | 通道顺序（BGR vs RGB） |
| 白→黑、黑→白，所有颜色都变补色 | 整屏反相 |
| 灰阶出现台阶/偏色，颜色发暗 | 位宽（18 vs 24bit）或位打包 |

**"单通道满值变补色 + 双通道满值变淡色 + 白黑正常"这一组是位级交织的指纹**：
反相会让白变黑，通道排列会让红变蓝且不会"变淡"，都对不上。

拟合出来的规律（本类面板实测的 8 组观测全部命中）：

```
R_out = (b1 + b2) / 2      G_out = (b0 + b2) / 2      B_out = (b0 + b1) / 2
```

推论：这种状态下**纯色根本出不来**（要 R_out=1 就得 G=B=1，于是 R 被拉回 0.5），
所以靠软件预补偿救不回来，必须修时序。

### 为什么 porch 会影响颜色

burst 模式下一行的像素被打成一个包连续发完，然后回 LP 等下一个行同步。
VBP 决定面板在垂直消隐里等多久。差两行，面板的接收状态机与包的到达时刻就错位，
解包时把相邻字节当成同一个通道的高低位 —— 于是出现"两两平均"的效果。

所以排查顺序是：**先确认 porch 与面板规格匹配，再怀疑色彩链路**。

### 配色问题的排除清单（本类面板实测全部无效）

`in_color_format` 换 RGB565/RGB666、`pixel_type.raw_type`、`pixel_type.dpi_config` 0~3
四档、`rgb_ele_order`、sync 极性四种组合、clock lane HS/AUTO、burst ↔ non-burst、
`VID_NUM_CHUNKS`、`VID_NULL_SIZE`、2D-DMA 拷贝 vs 直写内部 framebuffer ——
对"位级交织"这个现象**全都没有任何影响**。

> 判断原则：如果你已经把"颜色链路"从头到尾排除干净，问题还在，
> 那说明分类维度错了。颜色不只是"字节怎么排"，还有"包什么时候到"。

### 测试图怎么设计

- **一屏一次只放一个映射**：整屏纯色轮播（红→绿→蓝→白→黑，每 2 秒一换），
  不要一屏 8 条彩条。彩条要同时判 8 个映射，相机的白平衡和人眼都会引入误差。
- 每组至少覆盖：**三个单通道满值 + 白 + 黑**。少了白/黑这两条，
  "反相"和"位级交织"分不开。
- 手写测试图时把期望值打到串口（`预期 RGB = FF0000`），和屏幕实际颜色一对一对照。

---

## 十四、从面板读寄存器（IDF 的空白区）

要证明"初始化到底生效没有"，读回面板寄存器是最硬的证据。IDF 这条路基本不可用。

### IDF 的现状

```
esp_lcd_panel_io_rx_param()
└─ panel_io_dbi_rx_param()                      esp_lcd_panel_io_dbi.c
   └─ mipi_dsi_hal_host_gen_read_dcs_command()
      └─ read_short_packet(..., MIPI_DSI_DT_DCS_READ_0, ...)   ← DT 写死 0x06
```

四个坑：

1. DT 写死 DCS Read(`0x06`)，没有 Generic Read(`0x04/0x14/0x24`)
2. 三处裸 `while`，**无超时** → 面板不响应就 task_wdt
3. `rx_param()` 恒返回 `ESP_OK`，读没读到上层不知道
4. 读完**不恢复 video mode**（`mipi_dsi_hal.c` 里关了，只有 panel init 会开）→ 画面停

### 最致命的坑：读请求有独立的速度位，默认 HS

`DSI_HOST_CMD_MODE_CFG (0x0068)`：

| 位 | 字段 | 复位值 |
|---|---|---|
| 19 | `DCS_SR_0P_TX` | 0 = **HS** |
| 12~14 | `GEN_SR_0P/1P/2P_TX` | 0 = **HS** |
| 24 | `MAX_RD_PKT_SIZE`（0x37 包的传输速度） | 0 = **HS** |

IDF 只设写方向（`DCS_SW_*_TX` / `DCS_LW_TX` / `GEN_SW_*_TX` / `GEN_LW_TX`），
**读方向从来不管**。所以"写走 LP、读走 HS"是默认状态。

面板如果只实现了 LP（LPDT）命令入口（便宜的 TDDI 基本都这样），HS 的读请求它**收不到**，
于是不回 BTA。后果不是"读不到"，而是：

```
gen_rd_cmd_busy 永久为 1
  → 那个读包永久占住命令 FIFO
  → 之后所有写命令 ESP_ERR_TIMEOUT
  → 画面黑，且软件无法恢复
```

**修法**：读之前把这几位也设成 LP，跟写命令保持一致。
本类面板实测：改完一次读通。

### 几个"看起来像超时"的寄存器，其实不是

| 寄存器 | 真相 |
|---|---|
| `DSI_HOST_TO_CNT_CFG (0x0078)`（hstx/lprx） | **竞争检测**计数器，TRM 原话"不会产生中断"，清不掉 `gen_rd_cmd_busy` |
| `DSI_HOST_HS_RD_TO_CNT` / `LP_RD_TO_CNT` | 同上：链路静止时间，"不会产生中断" |
| **`DSI_HOST_PHY_TMR_RD_CFG (0x00F4)` `MAX_RD_TIME`** | **这才是读命令的看门狗**，单位 lane byte clock；IDF 给 6000（≈60µs @100MHz），偏紧 |

设了前两个以为能兜底，是常见的误判。

### 读卡死后唯一的恢复路径

`gen_rd_cmd_busy` 是只读状态位，只有"整个响应进入 FIFO"才会清。而：

- `mipi_dsi_ll_reset_register()` 实际写的是 `hp_rst_en0.reg_rst_en_dsi_brg`
  —— **只复位 bridge，不复位 host**
- `mipi_dsi_phy_ll_reset()` 只复位 PHY
- 唯一有效的是把 host 的 `pwr_up.shutdownz` 拉低再放开（TRM 43.4.3.1.2：关闭状态会
  重置所有数字逻辑），然后**重新走一遍** `esp_lcd_new_dsi_bus()` /
  `new_panel_dpi()` / 初始化表

所以工程上要把显示 bringup 写成**可重复调用的函数**：读失败就整体重建一次
（这次不带读），保证屏幕一定能起来。

### 三条规矩

1. **读只能在面板已经能应答时做**（至少 `11h` 之后）
2. **绝不能在初始化表发到一半时读** —— 读挂了剩下半张表全丢，屏必黑
3. 软件超时给到几十毫秒以上；不要指望硬件超时

### 怎么确认读到的不是垃圾

读 `0x0A`（RDDPM）。`11h`(sleep out) + `13h`(normal) + `29h`(display on) 之后应为：

```
0x9C = 1001 1100b
       bit7 booster=1   bit4 sleep_out=1   bit3 normal=1   bit2 display_on=1
```

读到 `0x00` / `0xFF` / 随机值都说明没通。想进一步证明"读的是实时状态"，
可以发 `0x28`(display off) 再读一次，`display_on` 位应跟着 1→0→1 变。

---

## 十五、不改 IDF：用 hal 的 static inline 直接改 host 行为

第九节那种"改 IDF 源码打补丁"能解决问题，但代价是：换台机器用干净 IDF 编出来的
固件行为不一样，而且不报错。

**更干净的办法**：IDF 的 `hal/*_ll.h` 全是 `static inline` 的寄存器读写封装，
编译时直接内联进你自己的编译单元。只要让组件能看到这些头文件，就能调 ——
**一行 IDF 源码都不用动**。

```cmake
idf_component_register(SRCS "dsi_ext.c"
                       INCLUDE_DIRS "include"
                       REQUIRES esp_lcd esp_mm esp_timer
                       PRIV_REQUIRES hal soc)       # ← 整个方案的开关
```

```c
#include "hal/mipi_dsi_host_ll.h"
#include "hal/mipi_dsi_brg_ll.h"

dsi_host_dev_t *host = MIPI_DSI_LL_GET_HOST(0);
dsi_brg_dev_t  *brg  = &MIPI_DSI_BRIDGE;
```

这套能覆盖到的能力（都已上板验证）：

| 能力 | IDF 的缺口 |
|---|---|
| 任意 DT 发命令（0x03/05/13/15/29/39） | `tx_param()` 把 DT 写死成 DCS |
| 真正的读（任意 DT + 超时 + 恢复 video mode） | 见第十四节 |
| 读请求速度 `DCS_SR_*_TX` | 复位 HS，IDF 不设 |
| 命令 ACK / 各类命令的 LP·HS 速度 | `io_dbi.c` 默认打开 cmd_ack，bus 超时全 0 → 会死锁 |
| 同步极性 5 个 / clock lane 状态 | `dpi_panel_init()` 写死 |
| `pixel_type.raw_type` / `dpi_config` | 永远写 0 |
| VPG 图案 | 有 API，但容易忘关 |
| 直写面板内部 framebuffer | 只能走 `draw_bitmap` 那条拷贝 |

现成实现：`martlet-tech/esp_dsi_ext`（ESP Component Registry 已发布；
本类面板就是用它把读通路调通的），或者按上面的方式自己抽一个。

**代价**：依赖私有头文件，升级 IDF 后要复查能不能编过；声明了 `PRIV_REQUIRES hal soc`
等于在构建系统里明示"我在用私有接口"。换来的好处是：多个工程共用同一份干净 IDF，
不用维护多份 patch。
