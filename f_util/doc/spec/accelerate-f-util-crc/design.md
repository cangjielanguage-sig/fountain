# Design: f_util CRC-16/CRC-64 本地码加速

## Context

**现状（已实读）**

- `CrcEngine`（`f_util/src/CrcEngine.cj`）是 `f_util` 包内的 `class`（非 `public`），用 UInt64 寄存器 + `mask` 截宽统一支撑 8/16/24/32/40/64 位；构造期现算两张 256 项字节表（MSB-first 的 `normalTable`、LSB-first 的 `reflectedTable`）。
- 只有 `refin && width == 32` 的变体生成 `t1..t3`（slicing-by-4），且只有这条路径用了 `acquireArrayRawData` 裸指针热循环（`CrcEngine.cj:129-175`）。16/64 位与所有非反射变体走 `CrcEngine.cj:176-186` 的逐字节索引循环。
- 门禁数据（D16 实测）：`cjpm test` 默认构建下带边界检查的下标约 25 ns/次；同一条逐字节索引路径 21 MB/s，换裸指针的切片路径 51~58 MB/s。据此推断 16/64 位当前在 20 MB/s 量级 —— 这是本变更要解决的基线。
- 变体表：`Crc16.all` 24 个、`Crc64.all` 6 个；每个变体自带 RevEng 检查值，`crc_check_test.cj` 已逐条核对。CRC-64 的 6 个变体按坐标分成两组：
  - 反射（`refin && refout`）：`xz`（poly `0x42F0E1EBA9EA3693`，init/xorout 全 1）、`iso`（poly `0x1B`，init/xorout 全 1）、`redis`（poly `0xAD93D23594C935A9`，init/xorout 全 0）、`jones`（同 poly，init 全 1、xorout 0）；
  - 非反射：`ecma182`（poly `0x42F0E1EBA9EA3693`，init/xorout 全 0）、`we`（同 poly，init/xorout 全 1）。
- 语言与构建事实：仓颉**没有**内联汇编、没有 SIMD 类型与 intrinsic（`f_jit/doc/asm-inline.md` §2.1 有检索结论）。但仓库已有**生成式机器码**的成熟载体：`f_util/src/code_buffer.cj` 的 `CodeBuffer`（`mmap` RW → 写入 → `mprotect` RX（W^X）→ `__clear_cache`）与 `CFunc`；CRC-32 的 `crc32_native_x86.cj` / `crc32_native_arm.cj` 已用同一套机制实现 `crc32` 与 PCLMULQDQ 路径（变更 `crc32-hw-cfunc`）。
- **分支前置**：本 worktree（`f_util_crc`）当前落后于 master，`code_buffer.cj` 与 CRC-32 生成路径尚未出现在本分支。开工前先同步 master（tasks 0.1），否则本设计引用的基座不存在。

**硬约束**

1. **零公开 API 变更**：`Crc16` / `Crc64` / `crc16*` / `crc64*` 签名、变体列表、检查值、增量语义全部不动。
2. **结果逐位不变**：任何新路径都必须和逐位参考实现（`CrcEngine_test.cj:37-69` 的 `refUpdate`）一致，任意长度、任意切分。
3. **`@When` 只能修饰声明**：平台分叉必须"整份声明各写一遍"，不能把注解贴在语句上。
4. **严格 TDD**：每一小步先写失败用例再写实现，全绿才勾任务。
5. **仓颉语法与 API 不猜**：实现期一律以 `cangjie_docs` / `std` 文档为准，尤其是 `CFunc` 的函数类型、`CPointer` 偏移与 `@When` 的 `arch` 条件。
6. **不引入 C / FFI / native 构建**：不新增 `.c`/`.h`、不改 `f_util/cjpm.toml`、不新增 `[ffi.c]`、不 `dlopen`、不新增导出符号。硬件路径只复用既有 `CodeBuffer` + `CFunc`。

**目标（按阶段，可度量）**

- **阶段一（反射域）**
  - CRC-16 表路径（slicing-by-2 / `UInt16` 表项）：≥ 40 MB/s。
  - CRC-64 表路径（slicing-by-8）：≥ 60 MB/s。
  - CRC-64 反射 4 变体（`xz` / `iso` / `redis` / `jones`）硬件路径：1 MiB ≥ 500 MB/s；**4 KiB 单次 ≤ 1.34 µs**（对标 CRC-32 生成路径的 4 KiB 帧绝对耗时）。
  - 全变体检查值、增量语义、任意切分等价性：零变化。
- **阶段二（正常域）**
  - CRC-64 非反射 2 变体（`ecma182` / `we`）硬件路径：1 MiB ≥ 500 MB/s；**4 KiB 单次 ≤ 1.34 µs**。
  - 6/6 变体全量回归零变化。

**Non-Goals**

- 不给 CRC-32 加 slicing-by-8，也不重写其生成式路径。
- 不做 ARMv8.1 的 `crc32cx` / `crc32hcx`（对 CRC-64 不适用）。
- 不新增公开 API、不引入第三方库、不改其它模块。
- 不做并行 CRC、不做表/常量/机器码落盘。
- 不支持非 Linux 目标的生成式路径（与 CRC-32 保持一致）。

## Decisions

### D1 硬件路径的载体是"生成式机器码 + `CFunc`"，不是 C + FFI

候选逐一看：

| 候选 | 可行性 | 结论 |
| --- | --- | --- |
| 仓颉内联汇编 | 语言无 `asm` 语法（`f_jit/doc/asm-inline.md` §2.1） | ✗ |
| 仓颉 SIMD/intrinsic | 标准库无 SIMD 类型，`@Intrinsic` 不向用户代码开放 | ✗ |
| 纯仓颉模拟 64×64 carry-less 乘法 | 可写（64 次移位异或），但比 slicing-by-8 还慢 | ✗ |
| 自写 C（intrinsics）+ `foreign` / `[ffi.c]` | 可行，但引入 C 工具链、native 构建与导出符号管理 | ✗ |
| **`CodeBuffer` 生成机器码 + `CFunc` 调用** | 仓库已有 `code_buffer.cj` 与 CRC-32 两个先例 | ✓ |

**为什么否决 C + FFI（本次评审的修订点）**：

- 构建面：`[ffi.c]` 会让 `f_util` 多一条 C 编译依赖，交叉编译矩阵（mingw / darwin / ohos）要么跟着编、要么用条件排除，二者都要维护 `cjpm.toml`。
- 符号面：C 内核必须导出 `crc64_clmul_*` 一类符号，需要 `-fvisibility=hidden` + `visibility("default")` + `nm -D` 验收，等于把"实现细节"变成动态库 ABI 的一部分。
- 回退面：C 内核缺失或编译失败时需要额外的降级路径（构建系统或运行时加载），本身就是多套代码路径。
- 生成式机器码把这三件事全部消掉：没有 C 源、没有新符号、没有构建配置；失败只是 `CodeBuffer` 返回 `None`，调用方回退表路径。

**代价必须写明**：机器码由本仓库的发射器逐字节生成，正确性风险从"C 编译器"转移到"发射器"。因此 D9 把"指令编码黄金字节 + 反汇编对照"列为独立验收项，并保留三路径等价性作为最终裁决。

### D2 表结构泛化：两组切片表 + 表项位宽，而不是一套 `Array<UInt64>`

`CrcEngine` 新增字段（内部）：

```
private let sliceWidth: Int64                       // 表项位宽：16 或 64
private let slicingDepth: Int64                     // 0 = 不切片；4 或 8
private let slices64: Array<Array<UInt64>>          // 16 位变体为空
private let slices16: Array<Array<UInt16>>          // 其它变体为空
```

- **为什么不统一成 `Array<Array<UInt64>>`**：CRC-16 用 64 位表项要 16 KB/变体（24 个变体 384 KB），且每次查表都是 8 字节载入；`UInt16` 表项把 2 张表压到 512 B/变体（合计 12 KB），整组表能常驻 L1。这与"16 位切片表"的意图一致。
- **为什么保留两组而不是用一个 `Array<Byte>` + 手工解包**：手工解包会引入每字节的移位/掩码，把表带来的收益又还回去。
- **为什么 `slicingDepth` 显式存**：热循环要按深度选择展开形态（4 字节一次 vs 8 字节一次），用字段而不是每次 `slices64.size` 判断，避免热路径上的间接读。
- 现有 `slice1..slice3` 三个字段删除，改为 `slices64[1]` / `slices64[2]` / `slices64[3]`；`slices64[0]` 与 `reflectedTable` / `normalTable` 指向同一张字节表（引用同一 `Array`，不复制内容），这样"深度 = 表张数"在热循环里读一处即可，32 位变体的表内存与改造前持平。

**32 位变体的热循环一行不改**：仍走 `CrcEngine.cj:129-175` 那一段裸指针代码，只是表从 `slice1/slice2/slice3` 改成 `slices64[1]` / `slices64[2]` / `slices64[3]`。这保证 D16 已经验证过的 51~58 MB/s 不会因为重构回退。

### D3 CRC-16：slicing-by-2，`UInt16` 表项

**口径修正（实施时发现）**：16 位寄存器只有 2 字节窗口，`c ^ word32` 的四表公式会把寄存器初值当成数据、丢掉 `x^16` 因子，数学上不成立；若强行覆盖 4 字节需要 6 张交叉表，收益与 2 字节切片相同。因此改为 **slicing-by-2**。表项仍是 16 位，符合评审口径。

推导沿用 `buildSliceTable`（`t[k] = (prev[k] >> 8) ^ base[prev[k] & 0xFF]`），派生后按 16 位截断。

反射热循环：

```
word = b0 | b1<<8
c    = c ^ word
c    = t1[c & 0xFF] ^ t0[(c >> 8) & 0xFF]
```

正常域（MSB-first）热循环：

```
word = (b0 << 8) | b1
c    = c ^ word
c    = t1[(c >> 8) & 0xFF] ^ t0[c & 0xFF]
```

- **表**：2 张 256 项 `UInt16`，**512 B/变体**，24 个变体共 **12 KB**（整组常驻 L1）。
- **收益**：每字节查表次数从 1 降到 1/2，配合裸指针热循环预期 ≥ 40 MB/s。
- 尾巴（< 2 字节）走原逐字节路径，一行不改。
- 非反射 16 位变体同样启用（用 `normalTable` 派生，热循环走 MSB-first 版本）；两条热循环各自成方法，不在循环里判 `refin`。

### D4 CRC-64：slicing-by-8，8 张 `UInt64` 表

标准 slicing-by-8：`t0..t7`，一次消费 8 字节。

```
word = 小端组装 8 字节
c ^= word
c = t7[c&0xFF] ^ t6[(c>>8)&0xFF] ^ … ^ t0[(c>>56)&0xFF]
```

- 16 KB/变体 × 6 个 64 位变体 = 96 KB，一次性静态分配。
- 反射变体由 `reflectedTable` 派生（小端 word），非反射变体由 `normalTable` 派生（大端 word，`c ^= word` 后按 MSB-first 取索引）。两条热循环各自成方法。
- **为什么不 lazy 生成**：现有构造函数就是饿汉式（`CrcEngine.cj:62-103`），改成懒加载要引入 `std.sync` 与双检锁，把"表构造"这个纯函数变成有状态路径，收益（96 KB）不值这个复杂度；96 KB 对一个服务端框架可忽略。
- 尾巴（< 8 字节）与不足部分走逐字节路径。
- 阶段一只需反射 64 位的 8 张表即可验收；非反射 64 位的 8 张表属阶段二，但字段与派生函数在阶段一就已就位。

### D5 折叠布局、两种坐标与常量集合

**核心事实：反射变体先做 64 位位反转，再与正常域变体共用同一套折叠核与同一组常量。** 位反转把 LSB-first 的反射多项式映射成 MSB-first 的正常多项式，因此两个域只在"入口/出口是否 `RBIT`、数据是否再做逐字节位反转"上不同，折叠公式与常量完全一致。

#### 反射域（`xz` / `iso` / `redis` / `jones`）

- 入口 `crc` 做 `RBIT x0, x0`，出口结果再做一次 `RBIT`。
- 每个 16 字节块先 `RBIT v.16b`（逐字节位反转），再 `REV64 v.16b, v.16b` + `EXT v.16b, v.16b, v.16b, #8`（16 字节整体反序），得到多项式系数序。
- 之后与正常域完全相同。

#### 正常域（`ecma182` / `we`）

- 入口/出口不做 `RBIT`。
- 每个 16 字节块只做 `REV64` + `EXT #8` 的字节序反转。

#### 折叠布局：单块 16 字节

```
首块（含入口注入）：acc = clmul(crc, P) ^ B0
后续块：          acc = clmul(acc.lo, x^128) ^ clmul(acc.hi, x^192) ^ B
收尾：            t   = clmul(acc.lo, P) ^ clmul(acc.hi, x^128)
                  crc = barrett(t)
```

- **单块而非 4 通道**：实测 1 MiB 7450 MB/s、4 KiB 777 ns，已远超门禁；4 通道会把内核从 196 B 抬到 400 B 以上，收益落在门禁之外。
- **常量不内联**，由 `Crc64Hw` 以指针传入（`[P, x^128, x^192, mu]` 四个 `UInt64`）。代码页与 poly 无关，3 个 poly 共用同一段机器码。

#### 常量集合（每组 4 个 `UInt64`，全部由 `CrcGf` 现算）

| 常量 | 定义 | 用途 |
| --- | --- | --- |
| `P` | 多项式（正常域坐标） | 首块注入与收尾 |
| `x^128 mod P` | 折叠低半区 |
| `x^192 mod P` | 折叠高半区 |
| `mu` | `⌊x^128 / P⌋` 的低 64 位 | Barrett 约减 |

**3 组 = 3 个 poly，覆盖 6 个变体与两个域：**

| 组 | poly | 使用变体 | 域 |
| --- | --- | --- | --- |
| G1 | `0x42F0E1EBA9EA3693` | `xz` | 反射（rbit） |
| G2 | `0x000000000000001B` | `iso` | 反射（rbit） |
| G3 | `0xAD93D23594C935A9` | `redis` / `jones` | 反射（rbit） |
| G1 | `0x42F0E1EBA9EA3693` | `ecma182` / `we` | 正常（无 rbit） |

> 反射与正常共用 G1：位反转之后两者的多项式相同，**没有"第 4 组常量"**。这是与原设计（3+1 组）的差异，已由 6 变体逐位对拍验证。

`init` 与 `xorout` 由 `CrcEngine.initRegister` / `finish` 处理，**不进入折叠核**，所以内核只认 `(poly, refin)`。

#### 入口状态注入与尾部

- 首块注入 `acc = clmul(crc, P) ^ B0`；反射变体的 `crc` 先 `RBIT`。
- 生成函数只处理 `len & ~15`（16 字节整数倍，且 ≥ 16）；尾部最多 15 字节由 `CrcEngine` 的表路径消费。
- **不做 `data[0..aligned]` 的前缀切片**：仓颉 `Array` 切片会产生新数组，4 KiB 前缀复制足以吃掉 4 KiB 绝对耗时预算。`Crc64Hw.update` 接收完整数组 + 前缀长度，`acquireArrayRawData` 后把裸指针与 `aligned` 直接交给 CFunc。

### D6 分派：三态开关 + 长度阈值

```
hw = Crc64Hw.available() && variant.supportsHw && len >= HW_MIN_LEN
```

- `variant.supportsHw` 用参数判定：`width == 64 && refin == refout`，且 `poly` 落在已支持集合 `{0x42F0E1EBA9EA3693, 0x1B, 0xAD93D23594C935A9}` 内。不按名字判定；同 poly 的自定义变体同样受益。
- 变体键是 `(poly & mask, refin)`，与名字、init、xorout 无关。新增 poly 只需在 `CrcGf` 侧补一组常量，代码页不改。
- `HW_MIN_LEN = 256`（实测确定：4 KiB 单次 777 ns、1 MiB 7450 MB/s，拐点低于 256；低于阈值时折叠的 prologue（状态注入、收尾约减、一次 CFunc 过桥）摊不薄）。
- 三态由环境变量 `F_UTIL_CRC_HW` 控制：`auto`（默认）/ `on`（无硬件时直接跳过该用例并打印原因，不失败）/ `off`（强制表路径）。为与 CRC-32 既有开关共存：`0`/`off` 视为 off，`1`/`on` 视为 on，未设或其它值视为 auto。**这是给测试与排障用的，不改变默认行为，也不是公开 API。**
- 分派只发生在 `CrcEngine.update` 的 64 位分支；16 位、8/24/40 位与 `refin != refout` 的自定义变体一律走表路径。

### D7 构建形态与代码页生命周期（零构建依赖）

**构建面：一行不改。**

- 不新增 `f_util/native/`、不新增 `[ffi.c]`、不 `dlopen`、不链接第三方库；`f_util/cjpm.toml` 保持原样。
- 复用 `f_util/src/code_buffer.cj`：`CodeBuffer.alloc(n)` → `write(bytes, 0)` → `seal()`。`seal()` 内部是 `mprotect(PROT_READ|PROT_EXEC)` + `__clear_cache`，失败返回 `false`。
- 新增三个与 CRC-32 同构的文件：
  - `crc64_native_x86.cj`：`@When[os == "Linux" && arch == "x86_64"] class Crc64Hw`；
  - `crc64_native_arm.cj`：`@When[os == "Linux" && arch == "aarch64"] class Crc64Hw`；
  - `crc64_native_stub.cj`：`@When[os != "Linux" || (arch != "aarch64" && arch != "x86_64")] class Crc64Hw`（全 `None`/`false`）。
  三份 `@When` 互斥且**并集覆盖全部目标**：Linux 上的 riscv64 / loongarch64 落到 stub，不会因为缺 `Crc64Hw` 定义而编译失败（CRC-32 的 stub 当初只判 `os != "Linux"`，本变更一并修正）。
- **复用既有 `foreign` 声明**：aarch64 的 `getauxval` 已在 `crc32_native_arm.cj` 中以 `@When[os == "Linux" && arch == "aarch64"]` 声明，`crc64_native_arm.cj` 直接复用，**不重复声明**（同一包内重复声明会冲突）。
- 代码页常驻进程生命周期，**不 `munmap`**：`CFunc` 指向它，提前释放会悬空。每个 `Crc64Hw` 用一个 `ArrayList<CodeBuffer>` 保活（与 `Crc32Hw.codes` 同一口径）。

**失败面只有一处**：`mmap`/`mprotect` 被 SELinux/seccomp 拦截，`CodeBuffer` 返回 `None`，自动回退表路径；不存在额外的构建降级路径。

### D8 代码页安全、ABI 与内存

- **W^X**：`mmap` 只申请 RW，写完再 `mprotect` RX；不使用 RWX，不把可写页留在进程里。
- **ABI 固定**：`CFunc<(UInt64, CPointer<Byte>, UInt64, CPointer<UInt64>) -> UInt64>`，参数依次是未收尾寄存器、数据指针、**16 的整数倍长度**、常量指针；返回未收尾寄存器。核内先判 `len < 16` 直接返回，避免误用越界。
- **只读**：生成代码只读 `ptr[0..len)`，不写、不分配、不回调仓颉、不访问全局。
- **裸指针窗口**：`acquireArrayRawData<Byte>(data)` → `unsafe { f(...) }` → `finally releaseArrayRawData`，窗口内只有一次 CFunc 调用。
- **线程安全**：CFunc 本身不可变；能力探测与代码页生成在 `Mutex` 内做一次，之后只读。同一 `(poly, 域)` 的并发首次调用由 `Mutex` 串行化，不会生成两份冲突的代码页。
- **测试钩子**：`setNativeEnabled(false)` 立即回退；`resetForTest()` 清空缓存与代码页，供三态用例重置。二者都是 `internal`，不进入公开 API。
- **不新增导出符号**：机器码不是 ELF 符号；`libf_util.so` 的导出集合与改造前一致（本变更不产生任何 `.c` 目标文件）。

### D9 测试策略：编码黄金字节 + 三路径交叉 + 常量自洽 + 强制开关

**A. 指令编码（离线核对，不建在线夹具）**

- 本变更的机器码是**静态字节数组 + 逐条指令注释**，没有运行时发射器，因此不建 `crc64_codegen_test.cj` 的字节夹具（原计划的发射器路线已放弃，见 D11）。
- 字节由离线汇编器 / 编码器生成后，用 `objdump -D -b binary -m i386:x86-64`（x86_64）与 `objdump -d`（aarch64 目标文件）逐条反汇编核对，核对结果写进源码注释。
- 等价性用例（B）才是运行期唯一闸门：任何字节错误都会在 6 变体 × 22 长度的对拍中暴露，而不是靠夹具自证。

**B. 等价性（主力）**

以 `refUpdate`（逐位、不建表）为第一基准，以逐字节表路径为第二基准，对 `Crc16.all` / `Crc64.all` 的每个变体跑长度 `0,1,2,3,4,5,7,8,15,16,17,63,64,65,127,128,129,255,256,257,4095,4096,4097,65537`。任意切分：`1+3+5`、4/8 的整数倍、`8n+1`、逐字节、在 64 字节折叠块**内部**切开。

**C. 常量自洽（保证"生成"不是"编"）**

- `xPowModP(0) == 1`，`xPowModP(n+1) == mulX(xPowModP(n))`；
- `xPowModP(64) == P`（多项式定义自检）；
- `barrettMu` 与用长除法现算的 `⌊x^128 / P⌋` 逐位相等；
- 折叠恒等式：对随机 128 位 `v`，`barrett(clmul(v.lo, k) ^ v.hi)` 等于"把 `v` 当作多项式系数做 `mod P`"的参考结果；
- 组间独立性：G1/G2/G3 的常量两两不同（防止 poly 串组）；`redis`/`jones` 共享 G3、`ecma182`/`we` 共享 G1 时，内核句柄相同、结果只差 init/xorout。

**D. 强制开关**

- `F_UTIL_CRC_HW=off`：所有用例走表路径，全绿。
- `F_UTIL_CRC_HW=on`：硬件不可用时 SKIP 并打印原因（不失败）；可用时全绿。
- 硬件路径与表路径在同一进程内交替调用，结果必须一致（考验常量/代码页缓存的不可变性）。

**E. 回退**

- 非目标平台：`Crc64` 结果仍正确（靠 `@When` 空实现；本地用 `F_UTIL_CRC_HW=off` 覆盖逻辑分支）。
- `CodeBuffer.alloc` / `seal` 失败：用测试钩子 `forceAllocFailureForTest(true)` 模拟 `None`，确认 `update` 走表路径、结果正确且不抛异常。

**F. 性能门禁（`F_UTIL_PERF=1` 门控，默认 SKIP 并打印原因）**

沿用现有 `throughputAtLeastThirtyMegabytesPerSecond` 的形态（`CrcEngine_test.cj:211-229`），新增：

- 1 MiB 吞吐：CRC-16 表路径 ≥ 40 MB/s；CRC-64 表路径 ≥ 60 MB/s；**6 个 64 位变体**的硬件路径各 ≥ 500 MB/s；
- **4 KiB 绝对耗时（仅硬件路径）**：**6 个变体逐一**测 4 KiB 单次调用（含 `acquireArrayRawData` + CFunc 过桥），门限 **≤ 1.34 µs**，与 CRC-32 生成路径的 4 KiB 帧绝对耗时同口径。表路径不设绝对耗时门禁（其判据仍是 MB/s）。
- 实测值回填本文件、`proposal.md` 与 spec。

### D10 与 D16 的关系（文档一致性）

`f_zip/doc/spec/add-f-zip-module/design.md` 的 D16 与 `tasks.md` §18 写着"红线：不引 FFI / 硬件指令"，并附了一句"CRC32C 的 SSE4.2 / ARMv8 `crc32` 另议"。本变更**不引 FFI、不引 C**，但确实使用硬件指令（`PMULL` / `PCLMULQDQ`）；而且 CRC-32 的生成式硬件路径（`crc32-hw-cfunc`）已经落地，"不引硬件指令"这句在事实上已经过期。

改写口径（tasks §8 单列）：

> "不引 C / FFI / native 链接；硬件加速走 `f_util` 既有的生成式机器码（`CodeBuffer` + `CFunc`）。CRC-32 见 `crc32-hw-cfunc`，CRC-16/64 见 `f_util/doc/spec/accelerate-f-util-crc/`。"

保留 D16 的全部实测数据（21 / 47.7 ms、51~58 MB/s、4.4 GB 200 s 等）不动。

### D11 备选方案与放弃理由

| 备选 | 放弃原因 |
| --- | --- |
| 自写 C + FFI | 引入 C 工具链、native 构建与导出符号管理；交叉编译矩阵多一条分支；回退阶梯本身是三套路径（详见 D1） |
| 预编译 `.o` 提交进仓库 | 二进制入库、跨发行版 glibc 兼容、审计困难 |
| 只做 slicing-by-8，不做硬件 | 表路径天花板 ~8×（20 → 150 MB/s 量级），到不了 GB/s |
| 只支持反射域 4 变体 | `ecma182` / `we` 是 ZIP/归档之外最常见的非反射口径，不做等于一半入口仍慢 |
| 用 `std.crypto` 的现成实现 | 标准库/扩展库没有 CRC 折叠，且引入新的包依赖与版本耦合 |
| 只支持 x86_64 | 融合开发环境与 ohos 目标都有 aarch64；PMULL 是 ARMv8 加密扩展的常见能力（需 FEAT_PMULL），不写等于放弃一半场景 |
| 让用户显式调用 `crc64XzFast()` | 违反"不改公开 API"，且把选择成本推给用户；默认自动分派更符合底座定位 |

## Risks / Trade-offs

| 风险 | 影响 | 缓解 |
| --- | --- | --- |
| 发射器写错指令/字节 | 非法指令或结果整体漂移 | 指令黄金字节用例 + 反汇编对照 + 三路径等价性；任一失败回退表路径 |
| 正常域字节序或 lane 注入位序写错 | `ecma182` / `we` 长数据漂移、短数据碰巧对 | 阶段二专项用例覆盖 8/64 字节边界与 `crc != 0` 入口；常量组间独立性断言 |
| `mprotect` 被 SELinux/seccomp 拦截 | 无硬件路径 | `CodeBuffer.seal()` 返回 `false` → `None` → 表路径，不抛异常 |
| CPU 特性误判 | 非法指令崩溃 | aarch64 同时检查 `HWCAP_ASIMD` 与 `HWCAP_PMULL`（`1 << 4`）；x86_64 查 `pclmulqdq`，缺失即不生成 |
| 4 KiB 前缀切片拷贝吃掉预算 | 绝对耗时门禁不达标 | D5 明确不切前缀；CFunc 接收完整数组 + 前缀长度 |
| aarch64 无本机测试机 | 机器码只在 x86 上验证 | 交叉汇编器核对编码 + `qemu-aarch64` 功能对拍；真机性能待补 |
| 代码页泄漏/悬空 | 内存浪费或崩溃 | 页面常驻、`ArrayList` 保活、不 `munmap`；`resetForTest` 只清引用不释放 |
| 144 KB 表内存 + ~8 KB 代码页 | 每进程常驻 | 可接受；若后续变体增多再考虑 lazy 或共享表 |
| 同 `(poly, 域)` 并发首次调用 | 生成两份代码页 | `Mutex` 内生成并缓存；CFunc 不可变 |
| 推翻 D16 的"硬件指令"表述造成文档漂移 | 后续维护者困惑 | tasks §8 强制同提交改文档 |

## Migration Plan

无 API 迁移、无数据迁移、无需用户改代码。

- 回退手段有三层：`F_UTIL_CRC_HW=off`（运行期）、`@When` 空实现（平台期）、删掉 `Crc64Hw` 的调用点（代码期）。没有 C 构建依赖需要回退。
- 发布口径：随 fountain 版本发布，`f_util` 仍是动态库；不新增独立产物、不新增 `.so`、不改 `cjpm.toml`。
- 阶段一可独立合并发布；阶段二在阶段一验收通过后继续，二者都遵循"全绿再合并"。

## Open Questions

1. **`HW_MIN_LEN` 的拐点** —— 已收敛：取 256。实测 4 KiB 单次 777 ns、1 MiB 7450 MB/s，折叠 prologue 在 256 B 已摊薄；更小的阈值收益落在噪声内。
2. **4 KiB 绝对耗时与 1 MiB 吞吐的关系** —— 已收敛：4 KiB 单次 **777.03 ns**（门限 1.34 µs），1 MiB **7450.5 MB/s**（门限 500 MB/s）。`acquireArrayRawData` + CFunc 过桥的固定开销约 120 ns，不构成瓶颈。
3. **aarch64 真机性能** —— 已收敛：融合开发引擎即 aarch64 真机（openEuler 24.03 SP4，CPU 含 `pmull`），上面两组数字均为真机实测；x86_64 仅有离线编码与 `objdump` 核对，性能待 x86 真机回填。
4. **性能门禁对主机负载敏感** —— 同一份二进制在健康时段实测 98 / 52 / 7450 MB/s、4 KiB 777 ns；在主机降频时段实测 55 / 28 / 3800 MB/s、4 KiB 1620 ns，CRC32 对照从 9182 降到 4800（同比例）。门限未改；若 CI 也要跑性能门禁，需固定频率或按 CRC32 基线归一化。
5. **"16 位切片表"口径已定**：表项为 16 位的 slicing-by-2（`Array<UInt16>`），不是 65536 项的 16 位索引表。24 个变体 × 2 张表 = 12 KB，与"省 cache"一致。
