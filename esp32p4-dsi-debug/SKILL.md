---
name: esp32p4-dsi-debug
description: >
  调试 ESP32-P4 MIPI DSI 显示异常（画面斜线/错位/撕裂/反色/花屏）与
  TDDI 触屏不报点的实战方法。包含 P4 DSI 时钟链的整数截断陷阱、
  时序量与速率的区分方法、用 VPG 自检图案切分故障域、INT_ST1 与
  bridge FIFO 的读法、RGB888 字节序、以及一套已验证可用的
  VFP=166 + DPI=30MHz + lane=480 参数。Use when the user reports
  ESP32-P4 DSI 画面斜线 / 错位 / 竖条歪 / 分段 / 撕裂 / 反色 /
  颜色不对 / 触屏不工作 / TDDI 无报点 / VFP / porch / lane bitrate
  / dpi clock / VID_HLINE_TIME / mipi_dsi / esp_lcd_panel_dpi.
---

# ESP32-P4 DSI 调试

面向"画面不对"和"触屏不动"这两类症状的排查路径。核心结论先给：

> **P4 的 DSI 时钟链有三处整数截断。绝大多数"画面斜线/错位"类问题，
> 根因是这个，不是面板、不是初始化、不是 burst 模式。**

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
| 干净、笔直、无扭曲 | 面板 / PHY / init 序列 / COLMOD / lane 数 / sync 极性 / **host 全套时序寄存器** 全对 | bridge 的 DPI 写入通路 |
| 也歪 / 也花 | 问题在更下游或面板本身 | PHY / 面板 |

**注意**：VPG 走 host 内部，**不经过 framebuffer 和 bridge**，所以它同时也证明了
像素格式、通道顺序之外的链路是好的。

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
