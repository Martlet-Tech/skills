---
name: esp-idf-release-pack
description: >
  Package an ESP-IDF project into a shippable release bundle — n original flash
  bins (whatever the partition table actually produces, not always 3), one
  merged bin writable from 0x0, a source zip without components, a source zip
  with components, a patch for local ESP-IDF modifications (when IDF_PATH itself
  was edited, so the exact same bin can be rebuilt), and a minimal README listing
  each bin's flash offset plus the IDF patch restore steps. Also reconstructs
  IDF_PATH / IDF_TOOLS_PATH / toolchain paths from build/ when the shell
  environment is gone. Use when a user says 打包发布 / 出 release / 出固件包
  / 发布固件 / 交付包 / 整合 bin / 合并 bin / merged bin / 烧录说明 / 反推 idf 路径
  / idf 环境没了 / 换个电脑打包 / idf 改过 / idf patch / 复现同一个 bin
  / ESP-IDF release / firmware package.
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

### `ESP_ROM_ELF_DIR` 是反推不出来的（**只有要重编时才需要**）

`build/` 里**没有任何地方**记录这个变量。它只能靠 `IDF_TOOLS_PATH/tools/idf_tools.py`
的 `tools.json` 里 `esp-rom-elfs` 的推荐版本 + 实际安装目录来定：

```bash
# 推荐版本
python "$IDF_TOOLS_PATH/tools/idf_tools.py" list 2>/dev/null | grep esp-rom-elfs
# 实际安装目录（版本号可能与推荐值不同，以目录里真实存在的为准）
ls -d "$IDF_TOOLS_PATH/tools/esp-rom-elfs"/*/
```

典型值形如 `$IDF_TOOLS_PATH/tools/esp-rom-elfs/20241011`
——**注意路径里有 `tools` 这一层**，且版本号可能是 `20241011` 这种较新的值，
不要照抄别处的 `20240411`。

**只打包、不重编的话，这个变量用不到**；只有接收方要重建 bin 时才会碰上，
所以在 README 的环境变量模板里一并写清楚即可。

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

## 一点五、先查 IDF 本身有没有被改（**必做，不能跳**）

> **为什么必须在打包前做这一步**
>
> 工程能编出这个 bin，靠的是"工程源码 + 特定版本的 IDF"。如果开发时动过 IDF 里的文件
> （调试时打个日志、改个行为、把某个函数换掉），那么**光给源码包是复现不出同一个 bin 的**。
> 接收方拿到源码包，在干净的同版本 IDF 上编译，会得到一个**不一样**的固件——
> 而且往往不是明显报错，是"能跑但行为不对"，最难查。
>
> 所以：**IDF 有任何改动 → 必须产出 patch，和源码包并列，并在 README 里写清复原方法。**

### 1. 定位 IDF 仓库

`IDF_PATH` 从 `build/` 反推（见第一节）。它下面有 `.git/` 才能出 patch。

```bash
ls -d "$IDF_PATH/.git" || echo "!! IDF 不是 git 仓库，无法自动出 patch，需人工比对"
```

### 2. 过滤掉行尾噪声（**关键，否则 patch 会有上万个文件**）

> Windows 上 IDF 发行版常见现象：整个仓库的 `git status` 显示一万多文件"已修改"，
> 但实际内容一个字节都没变，只是磁盘是 CRLF、仓库是 LF。
>
> 如果直接 `git diff`，产出的 patch 会是**几十 MB、包含上万个文件**的垃圾。
> 更糟的是——即使只挑出真正的文件，**普通 `git diff` 也会把整个文件显示成"全删全增"**
> （实测 `mipi_dsi_hal.c` 会变成 `323 insertions / 258 deletions`，全文重写），
> patch 虽然可能 apply 得上，但完全不可读，换个行尾设置就容易失败。
>
> **正确做法是两步：先筛文件（本文），再出干净 diff（下一节）。**

### 2a. 筛出真实改动的文件

不要用 `git diff --name-only` 的结果直接判断——它列的是"有差异"，不是"有内容差异"，
而且 `--ignore-cr-at-eol` 对 `--name-only` **无效**（实测仍返回上万个文件）。

唯一可靠的做法是**规范化行尾后逐文件比对**：

```bash
python - "$IDF_PATH" <<'PY'
import subprocess, os, sys
idf = sys.argv[1]

# 只扫源码相关目录和扩展名, 不要全仓库扫(太慢, 且文档/CI 的改动通常不影响 bin)
roots = ['components', 'tools']
exts  = ('.c', '.h', '.cpp', '.hpp', '.cc', '.py', '.cmake', '.txt', '.S', '.s')

out = subprocess.run(['git', '-C', idf, 'diff', '--name-only', '--'] + roots,
                     capture_output=True, text=True, encoding='utf-8', errors='ignore')
files = [f for f in out.stdout.split('\n') if f.strip() and f.endswith(exts)]

real = []
for f in files:
    p = os.path.join(idf, f)
    if not os.path.exists(p):
        real.append((f, 'DELETED'));  continue
    r = subprocess.run(['git', '-C', idf, 'show', 'HEAD:' + f], capture_output=True)
    if r.returncode != 0:
        real.append((f, 'UNTRACKED'));  continue
    a = r.stdout.replace(b'\r\n', b'\n')
    b = open(p, 'rb').read().replace(b'\r\n', b'\n')
    if a != b:
        real.append((f, 'len %d -> %d' % (len(a), len(b))))

print('候选:', len(files), ' 真实改动:', len(real))
for f, why in real:
    print('  %-72s %s' % (f, why))
PY
```

**扫完要人工看一眼分类**，有两类结果**不能进 patch**：

| 情况 | 处理 |
|---|---|
| `DELETED` 且原文件是 `mode 120000`（符号链接） | **不要进 patch**。Windows 解压不落地软链，不是人为改动；盲目纳入会让接收方 `git apply` 时误删文件 |
| 只在 `examples/`、`docs/` 下的改动 | 一般不影响 bin，确认后可排除 |

判断是不是软链接：

```bash
git -C "$IDF_PATH" ls-files -s -- <file>    # 首列 120000 就是符号链接
```

还要单独看一眼**未跟踪文件**（新增源码不会被 `git diff` 列出）：

```bash
git -C "$IDF_PATH" status --porcelain -- components tools | grep '^??' | grep -E '\.(c|h|cpp|py|cmake)$'
```

**辅助判断**：如果开发时留过日志标记（比如自定义 TAG），直接搜更快更准：

```bash
grep -rl "<你的自定义TAG>" "$IDF_PATH/components" --include=*.c --include=*.h
```

### 2b. 出干净 diff（**必须加 `-c core.autocrlf=true`**）

这是最容易漏的一步。对已经筛出来的文件逐个出 diff 时：

```bash
# ✗ 错的: 得到整个文件重写 (323+/258-)
git -C "$IDF_PATH" diff -- <file>

# ✓ 对的: 得到真正的最小 hunk (67+/2-)
git -C "$IDF_PATH" -c core.autocrlf=true diff -- <file>
```

`--ignore-cr-at-eol` 对**内容输出**也有效（同样得到 67+/2-），但它对 `--name-only` 无效，
所以**筛文件仍然必须用 2a 的逐文件比对**，两者不能互相替代。

判断 patch 是否干净，看 hunk 规模：

```bash
# 每个文件的增删行数, 应该都是小数字
git -C "$IDF_PATH" -c core.autocrlf=true diff --numstat -- <files...>
```

如果一个文件显示几百增删、而你只改了十几行，说明行尾还混在里面，**不要交这个 patch**。

### 3. 产出 patch

只对**真实改动的文件**出 diff，不要整个仓库出。**注意必须加 `-c core.autocrlf=true`**，
否则每个文件都会变成全文重写：

```bash
python - "<IDF_PATH>" "<out>/idf-modifications.patch" "<files.txt>" <<'PY'
import subprocess, sys, os
idf, dst, listfile = sys.argv[1], sys.argv[2], sys.argv[3]
files = [l.strip() for l in open(listfile) if l.strip()]   # 上一步筛出来的清单

chunks = []
for f in files:
    # ★ -c core.autocrlf=true 是关键: 不加会得到整文件重写的脏 diff
    r = subprocess.run(['git', '-C', idf, '-c', 'core.autocrlf=true',
                        'diff', '--no-color', '--no-ext-diff', '--', f],
                       capture_output=True)
    if r.stdout:
        chunks.append(r.stdout)

with open(dst, 'wb') as fp:
    fp.write(b''.join(chunks))
print('patch 写出:', dst, os.path.getsize(dst), '字节, 覆盖', len(files), '个文件')
PY
```

**出完必须自检 hunk 规模**，这是判断 patch 干净与否的唯一硬指标：

```bash
# 每个文件的 +行数 / -行数，应都是小数字
git -C "$IDF_PATH" -c core.autocrlf=true diff --numstat -- <files...>

# 或直接数 patch 里的增删行
grep -c '^+[^+]' "$OUT/idf-modifications.patch"
grep -c '^-[^-]' "$OUT/idf-modifications.patch"
```

参考：实测一个只改了十几行的文件，干净 patch 是 `+67/-2`；不干净是 `+323/-258`。
**看到增删数接近文件总行数，就是脏的，重做。**

**patch 必须是 `git diff` 格式**（带 `diff --git a/... b/...` 头），这样接收方能直接 `git apply`。
同时确认 patch 是纯 LF（`CRLF 计数 = 0`），避免把行尾问题带给接收方。

记录 IDF 的基线版本，写进 README——patch 只能打在**同一个基线**上：

```bash
git -C "$IDF_PATH" rev-parse HEAD          # 完整 commit
git -C "$IDF_PATH" describe --tags 2>/dev/null || git -C "$IDF_PATH" log -1 --pretty=%s
```

### 4. 验证 patch 能否还原（**必做**）

不能只看"patch 文件生成了"就完事。在临时副本上真的打一遍：

```bash
# 用 git worktree / 临时 clone 造一份干净的基线, 在副本里验证, 绝不动开发用的 IDF
TMP=$(mktemp -d)
git -C "$IDF_PATH" worktree add --detach "$TMP/idf-check" HEAD
git -C "$TMP/idf-check" apply --check "$OUT/idf-modifications.patch" && echo "patch 可用"
git -C "$TMP/idf-check" apply         "$OUT/idf-modifications.patch"
# 打完 patch 后应与开发机的 IDF 内容一致 (忽略行尾)
git -C "$IDF_PATH" worktree remove --force "$TMP/idf-check"
rm -rf "$TMP"
```

`apply --check` 失败通常是两个原因：基线不同（不是同一个 IDF commit），或 patch 里混进了行尾噪声。

**打完 patch 一定要逐字节比对**，`apply` 成功不等于内容对：

```bash
python - "<IDF_PATH>" "<worktree>" "<files.txt>" <<'PY'
import sys, os
idf, wt, listfile = sys.argv[1], sys.argv[2], sys.argv[3]
files = [l.strip() for l in open(listfile) if l.strip()]
allok = True
for f in files:
    a = open(os.path.join(wt,  f), 'rb').read().replace(b'\r\n', b'\n')
    b = open(os.path.join(idf, f), 'rb').read().replace(b'\r\n', b'\n')
    ok = (a == b); allok &= ok
    print('%-60s %s' % (os.path.basename(f), '一致' if ok else '★不一致'))
print('全部一致:', allok)
PY
```

**必须全部"一致"才算通过。** 只跑到 `apply --check` 通过是不够的。

### 5. 一致性判定表

| IDF 状态 | 要不要 patch | 说明 |
|---|---|---|
| 干净（无改动） | 不要 | 只给源码包 + IDF 版本号即可 |
| 只有行尾差异 | **不要** | 内容一致，产 patch 反而误导（上万个文件） |
| 有真实内容改动 | **必须** | 否则复现不出同一个 bin |
| IDF 不是 git 仓库 | 人工处理 | 让用户手工备份被改文件，README 里点名 |

---

## 二、输出结构

```
release/<YYYYMMDD-HHMMSS>_<project_name>/
├── firmware/                          ← 固件包
│   ├── <project>-<YYYYMMDD>-<hash>.bin        ← 整合 bin，从 0x0 写
│   ├── bootloader.bin                          ┐
│   ├── partition-table.bin                     │ n 个原始 bin
│   ├── <project>.bin                           │ （n 由分区表决定，
│   └── ... （用户自定义分区的额外 bin）          ┘  可能是 3 个，也可能 5 个）
├── src-full-<YYYYMMDD>.zip            ← 源码包（带 managed_components）
├── src-lite-<YYYYMMDD>.zip            ← 源码包（不带 managed_components）
├── idf-modifications.patch            ← 仅当 IDF 有真实改动时出现
└── README.md                          ← 极简烧录说明（含 patch 复原步骤）
```

**`idf-modifications.patch` 只在 IDF 有真实改动时才放**。IDF 干净时不要放空 patch 或全零 patch，
那会让接收方误以为需要额外操作。

**命名规则**

- **目录名**：`<YYYYMMDD-HHMMSS>_<project_name>`，例 `20261022-154012_mipi_dsi_panel`

  基于**打包时刻的本地时间**，不用序号、不用 commit 摘要。原因：
  - commit 摘要常含 `:`、`/`、`\` 等 Windows 非法字符，替换后很难看（`1. 修正_ 去掉 flush_cb 里的 R`）
  - 摘要截断到 20 字往往断在词中间，可读性差
  - 时间戳天然唯一、单调递增、可排序、跨平台安全，且能直接看出这包是什么时候出的

  ```bash
  STAMP=$(date +%Y%m%d-%H%M%S)
  DIR="release/${STAMP}_${PROJECT_NAME}"
  ```

  PowerShell：

  ```powershell
  $STAMP = Get-Date -Format 'yyyyMMdd-HHmmss'
  $DIR = "release/${STAMP}_$PROJECT_NAME"
  ```

  同一秒内重复打包的概率可忽略；若目录已存在，追加 `-2`、`-3` 即可，**不要删旧包**。

  commit 信息不丢——它已经在 `README.md` 的版本行和 bin 文件名里，目录名不必重复承载。

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
OUT="$(pwd)/release/${STAMP}_${PROJECT_NAME}/firmware/<project>-<date>-<hash>.bin"
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

只写这几件事：**每个 bin 写哪个地址**、**整合 bin 怎么用**、**整片擦除命令**、
**（若 IDF 有改动）如何打 patch 复原出同一个 bin**。
芯片名、偏移、文件名**全部从 `project_description.json` 和 `flash_files` 取，不要凭记忆写**。

`README.md` 里的 IDF 版本号从 `git -C "$IDF_PATH" rev-parse HEAD` 和 `describe` 取，
不要写 `git_revision`（那是 IDF 自己的可读版本串，不是可复原的 commit）。

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

## 从源码重建（binary 一致所必需）

本包的 bin 是在**改过的 IDF** 上编译的。**不打 patch 直接编，出来的固件不一样。**

IDF 基线：

```
版本：<如 v5.5.1>
commit：<IDF_PATH 的 git rev-parse HEAD>
```

复原步骤：

```bash
# 1. 取到同一基线的 IDF
git clone -b <tag> https://github.com/espressif/esp-idf.git
cd esp-idf && git checkout <commit>

# 2. 打上本包附带的 patch（在本包目录里执行）
git apply /path/to/idf-modifications.patch

# 3. 后续按官方 install / export 流程，然后在工程目录 idf.py build
```

被修改的文件清单：

| 文件 | 改动摘要 |
|---|---|
| <components/xxx.c> | <一句话说明改了什么> |

> 若本包**没有** `idf-modifications.patch`，说明 IDF 无改动，用上面那个 commit 的干净 IDF
> 即可复现。
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
- [ ] **IDF 改动已检查**：若干净，README 里写明"无 patch，用 <commit> 即可"；
      若有改动，`idf-modifications.patch` 已产出、`git apply --check` 已通过、
      README 里写清了基线 commit + 复原命令 + 被改文件清单
- [ ] **patch 里没有行尾噪声**：文件数应等于真实改动文件数，不是上万
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
| **不检查 IDF 改动** | 开发时改过 IDF，光给源码包**复现不出同一个 bin**，且往往"能跑但行为不对" |
| **拿整个 `git diff` 当 patch** | Windows 上 IDF 常有一万多文件的行尾差异，会产出几十 MB 的垃圾 patch |
| **出 diff 不加 `-c core.autocrlf=true`** | 即使文件筛对了，**整文件也会显示成全删全增**（实测 `+323/-258` 而非 `+67/-2`），patch 不可读且易失败 |
| **用 `--ignore-cr-at-eol` 去筛文件** | 它对 `--name-only` **无效**（仍返回上万文件）；只对 diff/numstat 的内容输出有效 |
| **把 `mode 120000` 的 DELETED 写进 patch** | Windows 解压不落地软链接，不是人为改动；纳入后接收方 `git apply` 会**误删文件** |
| **只看 `apply --check` 通过就收工** | 还要逐字节比对打完后与开发机是否一致，`apply` 成功不等于内容对 |
| **patch 里写了 `git_revision`** | 那是可读版本串，不可复原；要用 `git rev-parse HEAD` 的完整 commit |
| **`ESP_ROM_ELF_DIR` 照抄别人的** | build/ 里没有记录，路径含 `tools` 一层，版本号可能是 `20241011` 而非 `20240411` |
| **目录名直接用 commit 摘要** | Windows 不允许 `:`，需替换成 `_` |

---

## 五、验收口径

交付时一次性给出：

```
release/<YYYYMMDD-HHMMSS>_<project_name>/
├── firmware/
│   ├── <project>-<date>-<hash>.bin   1.09 MB   ← 0x0 一次写入
│   ├── bootloader.bin                 23 KB    ← 0x2000
│   ├── partition-table.bin             3 KB    ← 0x8000
│   └── <project>.bin                 1.01 MB   ← 0x10000
├── src-full-<date>.zip               xx MB
├── src-lite-<date>.zip               xx KB
├── idf-modifications.patch           xx KB     ← 仅在 IDF 有改动时出现
└── README.md
```

外加一句：**"整合 bin 从 0x0 写，分文件按 README 里的地址写；换过分区表的话先 erase_flash。"**

如果 IDF 有改动，还要额外说明：**"这个 bin 是在改过的 IDF 上编的，重建前必须先打
`idf-modifications.patch`，基线 commit 写在 README 里。"**
