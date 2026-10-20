---
name: esp-idf-release-pack
description: >
  Package an ESP-IDF project into a shippable release bundle — n original flash
  bins (whatever the partition table actually produces, not always 3), one
  merged bin writable from 0x0, a source zip without components, a source zip
  with components, and a minimal README listing each bin's flash offset. Also
  reconstructs IDF_PATH / IDF_TOOLS_PATH / toolchain paths from build/ when the
  shell environment is gone. Use when a user says 打包发布 / 出 release / 出固件包
  / 发布固件 / 交付包 / 整合 bin / 合并 bin / merged bin / 烧录说明 / 反推 idf 路径
  / idf 环境没了 / 换个电脑打包 / ESP-IDF release / firmware package.
---

# ESP-IDF 发布包

把一个 ESP-IDF 工程打成可以直接交付的包：**固件包（n+1 个文件）+ 两份源码包 + 一份极简 README**。

不依赖本地脚本，全部用 IDF 自带工具现算现做。**关键是：环境变量没了也能干**——`build/` 目录里藏着完整的环境信息。

---

## 一、先反推环境（本 skill 的核心）

换电脑、重开终端、CI 容器里，`IDF_PATH` 之类的变量通常都没了。但 `build/` 是上次编译时留下的，里面的绝对路径足以还原整套环境。

### 定位 build 目录

不要假设它叫 `build`，有人用 `build-esp32p4` 之类：

```bash
BUILD=$(for d in build*/; do [ -f "$d/project_description.json" ] && echo "${d%/}" && break; done)
[ -z "$BUILD" ] && echo "没有 build 目录，先 idf.py build"
```

### 从哪读

| 文件 | 能拿到什么 |
|---|---|
| `$BUILD/project_description.json` | **`idf_path`**、`target`、`project_name`、`app_bin`、`project_version`、`c_compiler` |
| 同上，字段 **`c_compiler`** | 交叉编译器绝对路径 → 反推 `IDF_TOOLS_PATH` |
| `$BUILD/CMakeCache.txt` 的 **`_Python3_EXECUTABLE`** | **最可靠的 python 解释器路径**（比 glob 猜好，见下） |
| `$BUILD/flasher_args.json` | **`flash_files`**：偏移 → bin 的映射（n 个 bin 都在这） |
| `$BUILD/flash_args` | 同上，纯文本版（`idf.py merge-bin` 吃这个） |

### 反推规则

```
IDF_PATH        = project_description.json 的 idf_path
IDF_TOOLS_PATH  = c_compiler 里第一个 "/tools/" 之前的部分
                  .../esp/tools-5.5.1/tools/riscv32-esp-elf/esp-14.2.0_20241119/.../gcc.exe
                  └──────── IDF_TOOLS_PATH ────────┘
IDF_PYTHON_ENV  = CMakeCache.txt 的 _Python3_EXECUTABLE 往上两级
                  .../python_env/idf5.5_py3.11_env/Scripts/python.exe → .../idf5.5_py3.11_env
```

**工具链目录名随 target 变**：`riscv32-esp-elf`（esp32p4 / c6 / c3 / h2）、`xtensa-esp-elf`（esp32 / s2 / s3）。
所以**不要**把 `riscv32-esp-elf` 写进模式匹配——用 `${CC%%/tools/*}`，任何 target 都成立。

**python env 别用 glob 猜**：一台机器上经常同时存在 `idf5.5_py3.11_env` 和 `idf5.5_py3.12_env`，
`ls -d ... | head -1` 是掷骰子。`CMakeCache.txt` 里的 `_Python3_EXECUTABLE` 是编译时**实际用的那个**。

### 导出环境

**bash（Git Bash / Linux / macOS）**

```bash
BUILD=$(for d in build*/; do [ -f "$d/project_description.json" ] && echo "${d%/}" && break; done)

IDF_PATH=$(python -c "import json;print(json.load(open('$BUILD/project_description.json'))['idf_path'])")
CC=$(python -c "import json;print(json.load(open('$BUILD/project_description.json'))['c_compiler'])")
IDF_TOOLS_PATH=${CC%%/tools/*}
PYEXE=$(grep -m1 '^_Python3_EXECUTABLE:INTERNAL=' "$BUILD/CMakeCache.txt" | cut -d= -f2)
IDF_PYTHON_ENV_PATH=$(dirname "$(dirname "$PYEXE")")

export IDF_PATH IDF_TOOLS_PATH IDF_PYTHON_ENV_PATH
export PATH="$IDF_PYTHON_ENV_PATH/Scripts:$IDF_PATH/tools:$PATH"
unset MSYSTEM MSYSCON
```

**PowerShell**（bash 通道清不掉 `MSYSTEM` 时用这个）

```powershell
$BUILD = (Get-ChildItem build*/project_description.json | Select-Object -First 1).Directory.Name
$d = Get-Content "$BUILD/project_description.json" -Raw | ConvertFrom-Json
$env:IDF_PATH = $d.idf_path
$env:IDF_TOOLS_PATH = ($d.c_compiler -split '/tools/')[0]
$py = (Select-String -Path "$BUILD/CMakeCache.txt" -Pattern '^_Python3_EXECUTABLE:INTERNAL=(.+)$').Matches.Groups[1].Value
$env:IDF_PYTHON_ENV_PATH = Split-Path (Split-Path $py)
$env:PATH = "$env:IDF_PYTHON_ENV_PATH/Scripts;$env:IDF_PATH/tools;$env:PATH"
Remove-Item Env:MSYSTEM -ErrorAction SilentlyContinue
```

### 三个必踩的坑

1. **`MSYSTEM` 必须清掉**，否则 `idf.py` 打印一行 `MSys/Mingw is no longer supported` 就退出，
   **退出码还是 0**。有些环境（IDE 的 bash 通道）会给每个子进程重新注入 `MSYSTEM`，
   `unset` / `env -u` 都拦不住——**这种情况直接换 PowerShell 通道**。
2. **不要 `idf.py set-target`**。目标平台已经在 sdkconfig 里，重新 set-target 会清空 `build/`、
   把 sdkconfig 改回默认，等于毁掉这次的产物。
3. **任何 `idf.py` 调用之后都要确认产物真的存在**。idf.py 的很多子命令会先打印
   "xxx will be created" 再执行，失败也可能 exit 0。

---

## 二、输出结构

```
release/<序号>. <一句话说明>/
├── firmware/                          ← 固件包
│   ├── <project>-<YYYYMMDD>-<hash>.bin        ← 整合 bin，从 0x0 写
│   ├── bootloader.bin                          ┐
│   ├── partition-table.bin                     │ n 个原始 bin
│   ├── <project>.bin                           │ （n 由分区表决定，
│   └── ... （用户自定义分区的额外 bin）          ┘  可能是 3 个，也可能 5 个）
├── src-full-<YYYYMMDD>.zip            ← 源码包（带 managed_components）
├── src-lite-<YYYYMMDD>.zip            ← 源码包（不带 managed_components）
└── README.md                          ← 极简烧录说明
```

**命名规则**

- **序号**：看 `release/` 下已有的 `N. xxx` 目录，取最大 N + 1
- **说明**：取 HEAD commit 摘要（`git log -1 --pretty=%s`），太长截断到 20 字
- **文件名**：`<project_name>-<YYYYMMDD>-<git短哈希>`，例 `mipi_dsi_panel-20261020-848e214`

短哈希取法（**别用 `git_revision`，那是 IDF 自己的版本**）：

```bash
git -C <project> rev-parse --short HEAD
# 或者从 project_version 里抠：int-ok-261019-7-g848e214 -> 848e214
```

---

## 三、执行步骤

### 0. 确认 build 是这一版编出来的

```bash
ls -l "$BUILD"/*.bin "$BUILD/flasher_args.json"
```

- `build/` 不存在 → 先 `idf.py build`
- 源码比 bin 新 → 提醒用户「build 可能是旧的」，**让用户决定是否重编，不要自己替他重编**

### 1. 读偏移表

**来源是 `flasher_args.json` 的 `flash_files`**，不要写死 `0x10000`：

```bash
python -c "
import json; d=json.load(open('$BUILD/flasher_args.json'))
for off, f in sorted(d['flash_files'].items(), key=lambda x:int(x[0],16)):
    print(off, f)
"
```

有自定义分区（nvs / ota / spiffs / fat / 出厂参数）时这里会多出几行，**全部要收进固件包**。

#### ⚠️ `flasher_args.json` 会过期

它只在 `idf.py build` / `reconfigure` 时更新。如果中间改过分区表但没重编，
偏移是**旧的**，打出来的包烧了不亮。

**必做交叉核对**：直接解析 `partition-table.bin`，和 `flash_files` 对一遍。

```bash
python - "$BUILD" <<'PY'
import json, struct, sys, os
b = sys.argv[1]
pt = open(os.path.join(b, 'partition_table', 'partition-table.bin'), 'rb').read()
tbl = []
for i in range(0, len(pt), 32):          # 条目 32 字节/条，magic 0xAA50
    e = pt[i:i+32]
    if len(e) < 32 or struct.unpack('<H', e[0:2])[0] != 0xAA50:
        break
    off, size = struct.unpack('<II', e[4:12])
    label = e[12:28].rstrip(b'\x00').decode('ascii', 'ignore')
    tbl.append((off, size, label))
print('分区表:')
for off, size, label in tbl:
    print('  0x%05X  0x%06X  %s' % (off, size, label))
print('flash_files:', json.load(open(os.path.join(b, 'flasher_args.json')))['flash_files'])
print('\n提示: app 偏移应与分区表里 factory/ota 分区一致，不一致说明 flasher_args.json 过期')
PY
```

对不上就**停下来问用户**，不要猜。

### 2. 生成整合 bin（0x0 起写）

#### 先看 `flash_args` 第一行，这里有个必踩的坑

```bash
head -1 "$BUILD/flash_args"
```

- `--flash_size detect` → **`idf.py merge-bin` 必然失败**。
  esptool 4.x 的 `merge_bin` 只接受 `keep` 或具体容量，不认 `detect`，
  报 `invalid choice: 'detect'`。
  这个 `detect` 是 `CONFIG_ESPTOOLPY_HEADER_FLASHSIZE_UPDATE=y` 故意写的（**默认就是开的**）。
- 具体容量（`8MB`）→ 可以直接用 `idf.py merge-bin`

**推荐做法：绕过 idf.py，直接用 esptool 并显式给容量。**

```bash
OUT="$(pwd)/release/<序号>. <说明>/firmware/<project>-<date>-<hash>.bin"
python - "$BUILD" "$OUT" <<'PY'
import json, re, subprocess, sys, os
build, out = sys.argv[1], os.path.abspath(sys.argv[2])
d = json.load(open(os.path.join(build, 'flasher_args.json')))
s, ex = d['flash_settings'], d['extra_esptool_args']

size = s['flash_size']
if size == 'detect':  # merge_bin 不认 detect，换成 sdkconfig 里的真实容量
    proj = os.path.dirname(os.path.abspath(build))
    cfg = open(os.path.join(proj, 'sdkconfig'), encoding='utf-8').read()
    size = re.search(r'^CONFIG_ESPTOOLPY_FLASHSIZE="([^"]+)"', cfg, re.M).group(1)

args = [sys.executable, '-m', 'esptool', '--chip', ex['chip'], 'merge_bin',
        '-o', out,
        '--flash_mode', s['flash_mode'], '--flash_freq', s['flash_freq'], '--flash_size', size]
for off, f in sorted(d['flash_files'].items(), key=lambda x: int(x[0], 16)):
    args += [off, f]
print('flash_size =', size)
subprocess.run(args, cwd=build, check=True)
PY
```

如果坚持用 `idf.py merge-bin`（`flash_size` 不是 `detect` 时）：

```bash
idf.py -B "$BUILD" merge-bin -o "$(basename "$OUT")"
```

产物落在 **`$BUILD/` 里**，不是当前目录。**不要加 `--fill-flash-size`**，那会把文件撑到整个 flash 容量。

#### 合并完必须验证

```bash
ls -l "$OUT" || echo "!! 没生成，合并失败"
```

再核对内容（这一段能同时发现「偏移错」和「合并没铺满」）：

```bash
python - "$BUILD" "$OUT" <<'PY'
import json, os, sys
build, out = sys.argv[1], sys.argv[2]
m = open(out, 'rb').read()
print('整合 bin: %d 字节' % len(m))
for off, f in sorted(json.load(open(os.path.join(build, 'flasher_args.json')))['flash_files'].items(),
                     key=lambda x: int(x[0], 16)):
    b = open(os.path.join(build, f), 'rb').read()
    o = int(off, 16)
    print('  @0x%05X %-28s %s' % (o, os.path.basename(f),
          '一致' if m[o:o+len(b)] == b else '不一致!'))
PY
```

### 3. 组装固件包

把 `flash_files` 里每个文件按**原始文件名**复制进 `firmware/`（保持 IDF 的命名，别改名），再放整合 bin。

### 4. 写极简 README

只写三件事：**每个 bin 写哪个地址**、**整合 bin 怎么用**、**整片擦除命令**。
芯片名、偏移、文件名**全部从 `project_description.json` 和 `flash_files` 取，不要凭记忆写**。

````markdown
# <project_name> 固件包

芯片：<target> ｜ 编译：<YYYY-MM-DD> ｜ 版本：<project_version>

## 方式一：整合包（推荐）

`<merged>.bin` 已包含全部内容，**从 0x0 一次写入**即可：

```bash
esptool.py --chip <target> -p <PORT> write_flash 0x0 <merged>.bin
```

## 方式二：分文件写入

| 地址 | 文件 |
|---|---|
| <off1> | <bin1> |
| <off2> | <bin2> |

```bash
esptool.py --chip <target> -p <PORT> write_flash <off1> <bin1> <off2> <bin2>
```

## 注意

- **换了分区表就必须整片擦除**：`esptool.py --chip <target> -p <PORT> erase_flash`
- 首次烧录建议先 `erase_flash`，避免 nvs 里残留旧配置
- flash 参数：<flash_mode> / <flash_freq> / <flash_size>
````

### 5. 两份源码包

| 包 | 包含 | 排除 |
|---|---|---|
| `src-full-*.zip` | 全部源码 + `managed_components/` | `build*/`、`.git/`、`.vscode/` |
| `src-lite-*.zip` | 全部源码（不含组件） | `build*/`、`.git/`、`.vscode/`、`managed_components/` |

**`.vscode/` 一律排除**——里面的 `settings.json` / `c_cpp_properties.json` 是本机绝对路径
（IDF 路径、clangd 路径、`compile_commands.json` 路径），对接收方没用，纯泄露。

**Windows / Git Bash 通常没有 `zip` 命令**，用 python 打（也顺便控制排除规则）：

```bash
python - "<project>" "<out>/src-lite-<date>.zip" lite <<'PY'
import os, sys, zipfile
src, dst, mode = sys.argv[1], sys.argv[2], sys.argv[3]
skip_dirs = {'.git', '.vscode'}
if mode == 'lite':
    skip_dirs |= {'managed_components'}
with zipfile.ZipFile(dst, 'w', zipfile.ZIP_DEFLATED, compresslevel=9) as z:
    for root, dirs, files in os.walk(src):
        dirs[:] = [d for d in dirs if d not in skip_dirs and not d.startswith('build')]
        for f in files:
            p = os.path.join(root, f)
            z.write(p, os.path.relpath(p, src))
print('写出', dst, os.path.getsize(dst), '字节')
PY
```

> `build*/` 要按**前缀**匹配（`d.startswith('build')`），别只排 `build`——`build-esp32p4` 也得排掉。

### 6. 路径泄露扫描（必做）

源码包里常见泄露源：`.vscode/`、`dependencies.lock`（local 组件的绝对路径）、
`sdkconfig` 里的自定义路径、日志和注释里的开发机路径。

**heredoc 终止符必须独占一行**。`PY <args>...` 这种写法会让 heredoc 一直读到文件尾，
脚本静默空转、退出码还是 0——**等于没扫**：

```bash
python - <out>/src-lite-*.zip <out>/src-full-*.zip <<'PY'
import re, sys, zipfile
# 任何盘符路径 + 常见用户目录，不要只认几个固定的首层目录
pat = re.compile(r'(?:[A-Za-z]:[\\/][^\s"\'<>|*?\r\n]{3,}|/(?:home|Users)/[A-Za-z0-9_.-]+)')
bad = re.compile(r'^[a-z]://')   # URL 里的 "s://" 是误报
total = 0
for z in sys.argv[1:]:
    hits = []
    with zipfile.ZipFile(z) as zf:
        for n in zf.namelist():
            if n.endswith(('.bin', '.a', '.o', '.elf', '.png', '.jpg', '.zip', '.ttf')):
                continue
            try:
                raw = zf.read(n)
            except Exception:
                continue
            if b'\x00' in raw[:4096]:      # 二进制内容，当文本解码只会产生垃圾误报
                continue
            t = raw.decode('utf-8', 'ignore')
            for m in pat.finditer(t):
                s = m.group(0)
                if not bad.match(s):
                    hits.append((n, s[:80]))
    total += len(hits)
    print('== %s: %d 处' % (z, len(hits)))
    for n, s in list(dict.fromkeys(hits))[:12]:
        print('   %-42s %s' % (n, s))
print('合计', total, '处')
PY
```

**有命中就报告，不要自作主张删文件**——有些路径是源码里合法引用的
（比如 `dependencies.lock` 里 local 组件的路径）。把文件名和上下文列给用户，让他决定。

### 7. 收尾校验

- [ ] `firmware/` 里的 bin 数量 = `flash_files` 条数 + 1（整合 bin）
- [ ] 整合 bin 各段逐字节对得上（第 2 步的验证脚本）
- [ ] 整合 bin 大小 = 最大偏移 + 对应 bin 大小
- [ ] README 里的地址/文件名和 `flash_files` 逐行一致
- [ ] 两个 zip 都能打开，且都不含 `build*/`、`.git/`、`.vscode/`
- [ ] 泄露扫描已跑过，命中项已报告给用户
- [ ] 把整个 release 目录列给用户，附每个文件的大小

---

## 四、坑

| 坑 | 说明 |
|---|---|
| 写死 3 个 bin | 自定义分区会有 nvs/ota/spiffs 等额外 bin，**永远从 `flash_files` 读** |
| 工具链只匹配 riscv | xtensa 目标（esp32/s3/...）全线失效，用 `${CC%%/tools/*}` |
| `merge-bin` 报 `invalid choice: 'detect'` | `CONFIG_ESPTOOLPY_HEADER_FLASHSIZE_UPDATE=y` 导致，改显式容量 |
| 以为 merge 成功了 | idf.py 先打印 "will be created" 再执行，失败也可能 exit 0，**必须验文件** |
| `merge-bin` 产物找不到 | 写在 `build/` 里，不是当前目录 |
| 加了 `--fill-flash-size` | 文件被撑到整个 flash 容量 |
| 源码包带 `build/` 或 `.vscode/` | 泄露 IDF 路径、工具链路径、用户名、git 提交位置 |
| `dependencies.lock` 里的 local 路径 | 常指向开发机上的兄弟工程，泄露目录结构 |
| `idf.py set-target` | 会清 `build/`、重置 sdkconfig，毁掉产物 |
| `MSYSTEM` 没清 | idf.py 打一行警告就退出，退出码 0 |
| `git_revision` 当成项目版本 | 那是 **IDF 的**版本（如 `v5.5.1-dirty`），项目版本看 `project_version` |
| `flasher_args.json` 过期 | 改过分区表没重编 → 偏移是旧的，烧了不亮 |
| 改分区表但只烧 app | 必须 `erase_flash` |
| 整合 bin 从 0x1000 写 | 必须从 **0x0** |

---

## 五、验收口径

交付时一次性给出：

```
release/<序号>. <说明>/
├── firmware/
│   ├── <project>-<date>-<hash>.bin   1.09 MB   ← 0x0 一次写入
│   ├── bootloader.bin                 23 KB    ← 0x2000
│   ├── partition-table.bin             3 KB    ← 0x8000
│   └── <project>.bin                 1.01 MB   ← 0x10000
├── src-full-<date>.zip               xx MB
├── src-lite-<date>.zip               xx KB
└── README.md
```

外加一句：**"整合 bin 从 0x0 写，分文件按 README 里的地址写；换过分区表的话先 erase_flash。"**
