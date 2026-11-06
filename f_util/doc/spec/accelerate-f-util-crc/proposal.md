# Change: f_util CRC-16/CRC-64 本地码加速

## Why

1. **CRC 的 16/64 位路径还停在"逐字节 + 带边界检查的下标"上，是底座剩下的热点。**
   `CrcEngine.update` 只在 `refin && width == 32` 时启用 slicing-by-4 与裸指针热循环（`f_util/src/CrcEngine.cj:129-175`）；CRC-16（24 个变体）与 CRC-64（6 个变体）都走单表逐字节循环（`f_util/src/CrcEngine.cj:176-186`）。D16 的实测已经证明：同一条"带边界检查的下标"在 `cjpm test` 默认构建下约 25 ns/次，逐字节路径只能到 **21 MB/s**（1 MiB 47.7 ms，`f_zip/doc/spec/add-f-zip-module/tasks.md` 18.2）；换成裸指针的 32 位切片路径是 51~58 MB/s，而 16/64 位至今没有这条路。

2. **CRC-64 没有余量承受"大流量"。** 4.4 GB 单条目在 51~58 MB/s 下一次往返已要 200 s（同上 18.6）；同为 64 位的 CRC-64 若再慢 2~3 倍，xz/lzma 容器、WAL 归档、镜像校验这类用法会先撞在 CRC 上。CRC-64 的 6 个变体覆盖了两种坐标：`xz`/`iso`/`redis`/`jones` 反射，`ecma182`/`we` 非反射；只打通其中一半，另一半仍会拖慢调用方。

3. **slicing-by-8 是纯算法收益，零新依赖。** 64 位寄存器天然容纳 8 张 256 项表（16 KB/变体），一次消费 8 字节仍只需 8 次查表 —— 摊到每字节，查表次数从 1 降到 1/8。

4. **数量级差距只能靠 CLMUL，但载体不是 C。** x86_64 的 `PCLMULQDQ` 与 aarch64 的 `PMULL`/`PMULL2` 提供 64×64→128 的 carry-less 乘法，是 GB/s 级 CRC 的唯一实现路径。仓颉不提供内联汇编与 SIMD intrinsic（`f_jit/doc/asm-inline.md` §2.1 的检索结论：语言文档 `内联汇编|汇编|asm` 零命中）。早期评审曾计划"自写 C + FFI"，现已否决：那会引入 C 工具链与 native 构建依赖、要求管理导出符号与可见性、并让交叉编译矩阵多一条分支。仓库已有更轻的现成载体 —— `f_util/src/code_buffer.cj` 的 `CodeBuffer`（`mmap` RW → 写机器码 → `mprotect` RX → `__clear_cache`）与 `CFunc`，CRC-32 的生成式路径（`crc32-hw-cfunc`）已经用它落地。本变更复用同一机制：首次使用时按变体生成机器码并缓存，运行时直接调用；**零 C 源文件、零 native 构建、零新增导出符号**。

5. **常量必须可推导，不能是抄来的魔法数。** 折叠常量（`x^n mod P`、Barrett `mu`）一旦写死，换变体就得重抄一遍论文，抄错只有长数据才暴露。本次把常量生成做进 GF(2) 运算，用"常量自洽 + 三路径交叉"两类用例钉死。

6. **不改任何公开 API。** `Crc16` / `Crc64` / `CrcEngine` / `crc16*` / `crc64*` 的签名、变体列表、RevEng 检查值与增量语义全部保持；唯一变化是同一个寄存器值算得更快。

## What Changes

- **表结构泛化（内部）**：`CrcEngine` 从"固定三张 `Array<UInt64>` 切片表"改成"每变体一组切片表 + 表项位宽"。切片层数与表项类型由 `(width, refin)` 决定：
  - 32 位反射：保持 slicing-by-4 / `UInt64` 表项 —— **行为与热循环一行不改**；
  - 16 位：新增 slicing-by-2 / **`UInt16` 表项**（2 张表共 512 B/变体，24 个变体 12 KB）；
  - 64 位：新增 slicing-by-8 / `UInt64` 表项（8 张表 16 KB/变体，6 个变体 96 KB）。
  - 8/24/40 位变体保持逐字节索引不变；非反射的 16/64 位变体同样享受切片表（表从 `normalTable` 派生）。
- **切片表派生规则统一**：沿用现有 `buildSliceTable`（`t[k] = (prev[k] >> 8) ^ base[prev[k] & 0xFF]`，`f_util/src/CrcEngine.cj:105-111`）逐级派生，16 位变体派生后按位宽截断到 `UInt16`。
- **新增 `CrcGf`（内部）**：GF(2) 128 位算术 —— `mulX`、`xPowModP(n)`、`barrettMu`、`foldConstants(poly, reflected)`。所有折叠常量由多项式**在构造期生成**，不在源码里出现魔术数。
- **新增 `Crc64Hw`（内部，生成式机器码）**，替代原计划的 C 内核：
  - 复用 `f_util/src/code_buffer.cj`：`CodeBuffer.alloc` → `write` → `seal`（W^X）→ `CFunc<(UInt64, CPointer<Byte>, UInt64) -> UInt64>`；
  - aarch64 用 `PMULL` / `PMULL2` + `VEOR`；x86_64 用 `PCLMULQDQ` + `PXOR`；两者语义相同：4 通道 128 位折叠 + 收尾折叠 + Barrett 约减；
  - 折叠核只处理 `len & ~63`（64 字节整数倍），不足的尾部由仓颉侧表路径消费。
- **折叠常量按 `(poly, 域)` 生成 3+1 组**：3 个反射域常量组（`0x42F0E1EBA9EA3693` → `xz`；`0x1B` → `iso`；`0xAD93D23594C935A9` → `redis`/`jones` 共享）+ 1 个正常域常量组（`0x42F0E1EBA9EA3693` → `ecma182`/`we` 共享）。6 个变体共用 4 份常量、4 份生成代码。
- **特性探测与三态开关**：aarch64 读 `getauxval(AT_HWCAP)` 的 `HWCAP_PMULL`（并检查 `HWCAP_ASIMD`），x86_64 查 `pclmulqdq`（CPU 特性表，辅以 `cpuid` 口径）；结果缓存一次。`F_UTIL_CRC_HW=auto|on|off` 供测试强制三态，默认 `auto`，并与 CRC-32 既有开关语义对齐（`0`/`off` 关闭，`1`/`on` 强制，未设/其它值 `auto`）。
- **分派**：`update` 在 `hw 可用 && 变体受支持 && len >= HW_MIN_LEN` 时走硬件核，否则走表路径。**6 个 64 位变体全部受支持**：反射 4 个走反射域折叠核，非反射 2 个走正常域折叠核；16 位与 8/24/40 位保持表路径。
- **构建**：**不改 `f_util/cjpm.toml`、不新增 `native/`、不引入 `[ffi.c]`、不 `dlopen`**。Linux x86_64 / aarch64 各有一份生成式实现，其余目标用 `@When` 空实现整份缺席；CodeBuffer 本身已带 `@When[os == "Linux"]`。
- **测试**：新增 `CrcGf_test.cj`（常量自洽）、`crc64_codegen_test.cj`（编码黄金字节 + 三态与回退 + 全变体交叉），扩写 `CrcEngine_test.cj`（16/64 位任意长度与任意切分的三路径交叉）、`F_UTIL_PERF=1` 门控的性能用例。
- **文档**：`f_util/README.md` / `README_en.md` 的 CRC 段落补"CRC-64 的 6 个变体在支持 CLMUL 的平台上走生成式硬件路径，结果不变"；同步修正 `f_zip/doc/spec/add-f-zip-module/design.md` D16 与 `tasks.md` §18 里"不引 FFI / 硬件指令"的表述（本变更不引 FFI，但确实使用硬件指令，见 Impact）。
- **分两阶段交付**：
  - **阶段一（反射域）**：表结构泛化 + CRC-16 slicing-by-2 + CRC-64 反射 4 变体（表路径 + 反射域折叠核）。独立可合并、可发布。
  - **阶段二（正常域）**：CRC-64 非反射 2 变体（表路径 + 正常域折叠核）。阶段二完成后 6/6 变体全加速。

## 交付阶段与验收点

| 阶段 | 范围 | 验收点 |
| --- | --- | --- |
| 阶段一 | CRC-16 24 变体；CRC-64 `xz` / `iso` / `redis` / `jones` | 4 个反射 64 位变体检查值与任意切分等价；3 组反射常量自洽；4 个变体三态一致；1 MiB ≥ 500 MB/s、4 KiB 单次 ≤ 1.34 µs；反射 4 变体表路径 ≥ 60 MB/s、CRC-16 表路径 ≥ 40 MB/s；回退路径正确 |
| 阶段二 | CRC-64 `ecma182` / `we` | 2 个非反射变体检查值与任意切分等价；3 组常量覆盖两个域（无第 4 组）；2 个变体三态一致；1 MiB ≥ 500 MB/s、4 KiB 单次 ≤ 1.34 µs；非反射 2 变体表路径 ≥ 60 MB/s；6/6 变体全量回归 |

验收点编号与 spec 各场景末尾的标注一一对应：

- **阶段一**：`P1-1` 检查值与任意切分等价；`P1-2` 三组反射常量自洽；`P1-3` 4 变体三态一致；`P1-4` 性能（表 40 / 60 MB/s、硬件 500 MB/s、4 KiB ≤ 1.34 µs）；`P1-5` 回退。
- **阶段二**：`P2-1` 2 变体表路径等价；`P2-2` 3 组常量覆盖两个域（无第 4 组）；`P2-3` 2 变体三态一致；`P2-4` 性能；`P2-5` 6/6 全量回归。

阶段一验收通过后可独立合并发布；阶段二在阶段一合并后继续。阶段二结束时 6/6 变体都具备表路径与生成式硬件路径。

## Capabilities

### New Capabilities

- `f-util-crc`: `fountain::f_util` 的 CRC 校验和引擎 —— 参数口径（width/poly/init/refin/refout/xorout）、RevEng 检查值、增量语义，以及**实现路径的等价性约束**：表驱动（slicing-by-2/4/8、16 位表项）、生成式折叠常量、生成式 CLMUL 机器码（aarch64 `PMULL` / x86_64 `PCLMULQDQ`）三者在任意长度、任意切分下必须给出逐位相同的寄存器值，且任一平台缺能力时静默回退。折叠核覆盖 6 个 CRC-64 变体的两种坐标（反射域 4 个、正常域 2 个）。

### Modified Capabilities

- 无。
  > **delta 形态说明**：本 worktree 的 `f_util/doc/spec/` 下没有 `f-util-crc` 的基线 spec。`f_util` 的 CRC 从未被规格化过，因此该 capability 以 `## ADDED Requirements` 落地 —— 等于给既有实现补一份规格，并把它原本"没写下来的不变式"钉死。语义上仍是一次"改进既有能力"。

## Impact

- **修改代码**：`f_util/src/CrcEngine.cj`（表结构泛化 + 分派 + 16/64 位热循环）。
- **新增代码**：`f_util/src/CrcGf.cj`、`f_util/src/crc64_native_x86.cj`、`f_util/src/crc64_native_arm.cj`、`f_util/src/crc64_native_stub.cj`；测试 `f_util/src/CrcGf_test.cj`，扩写 `f_util/src/CrcEngine_test.cj`。机器码是**静态字节数组**（aarch64 反射 196 B / 正常域 180 B，x86_64 反射 539 B / 正常域 219 B），没有运行时发射器，因此不新增 `crc64_codegen.cj` / `crc64_codegen_test.cj`。
- **复用不改**：`f_util/src/code_buffer.cj`（已存在于 master；本 worktree 开工前先同步）。
- **零公开 API 变更**：`CrcEngine` 本身就是包内 `class`（非 `public`），新增类型一律 `internal`/`private`；`Crc16` / `Crc64` / `crc16*` / `crc64*` 的签名与返回值不变。
- **无 C 依赖、无导出符号变化**：不新增 `.c`/`.h`、不改 `cjpm.toml`、不新增 `[ffi.c]`、不 `dlopen`、不链接第三方库。生成式路径只通过既有 `CodeBuffer` 调用 libc 的 `mmap`/`mprotect`/`__clear_cache`（与 CRC-32 生成路径同一口径），**`libf_util.so` 的导出符号集合不因本变更变化**。
- **静态内存**：CRC-16 新增 24 × 2 × 256 × 2 B = **12 KB**；CRC-64 新增 6 × 8 × 256 × 8 B = **96 KB**；生成代码页每平台 2 份（反射 + 正常域）合计不足 **0.5 KB**；常量 3 组 × 32 B = **96 B**。合计约 **+109 KB**，均为构造期/首次使用期一次性分配（与现有 32 位切片表同一口径）。
- **构建矩阵**：不变。mingw / darwin / ohos 等目标不生成机器码，`Crc64Hw` 空实现返回 `None`，`Crc64` 自动退回 slicing-by-8。
- **语义影响面**：所有 CRC 调用方 —— `f_protocol` 帧校验（`f_protocol/src/default/Message.cj:95` / `:128` / `:297`）、`f_store` WAL 校验（`f_store/src/WAL.cj:125`、`f_store/src/WALRecordCodec.cj:39`）、`f_zip` 条目 CRC。**只改性能不改语义**，回归口径 = `f_util` 全量 `cjpm test` + 上述模块的 CRC 相关用例。
- **修正一条既有表述**：`f_zip/doc/spec/add-f-zip-module/design.md` D16 与 `tasks.md` §18 的"不引 FFI / 硬件指令"需要改写为"不引 C/FFI/native 链接；硬件加速走 `f_util` 既有的生成式机器码（`CodeBuffer` + `CFunc`）"。落地时必须同提交改掉这两处（见 tasks §8），否则文档之间互相打脸。
- **覆盖的入口**：顶层 `crc64()` 指向 `Crc64.redis`，本变更**覆盖**它（阶段一）。README 不再需要"默认入口未加速"的免责说明。
- **实测（融合引擎 aarch64，`cjpm test` 默认构建，1 MiB）**：CRC-64/XZ 表路径 **98.35 MB/s**（改造前 ~20）；CRC-16/MODBUS 表路径 **52.37 MB/s**；CRC-64/XZ 生成式硬件路径 **7450.5 MB/s**，4 KiB 单次 **777.03 ns**；CRC-32 硬件路径 9182 MB/s（无回退）。x86_64 仅有离线编码与 `objdump` 核对，性能待真机回填。

## Out of Scope

- **CRC-32**：保持现有 slicing-by-4 与生成式硬件路径现状，本变更不重写、不回退。
- **ARMv8.1 的 `crc32cx` / `crc32hcx` 专用 CRC 指令**：它们是 32 位多项式指令，对 CRC-64 不适用；64 位统一走 PMULL 折叠。
- **多线程 / 分段并行 CRC**：`update` 的单线程语义、`1+3+5` 任意切分等价性不变。
- **公开 API 扩展**：不新增 `update(ptr, len)` 之类的重载，不暴露 `hwAvailable()` 给用户。
- **构建体系变更**：不引入 C 源、第三方库、`[ffi.c]`、`dlopen`，不改 `cjpm` 版本、不动其它模块的 `cjpm.toml`。
- **非 Linux 目标的硬件路径**：生成式实现只覆盖 Linux x86_64 / aarch64（与 CRC-32 一致）；其它目标保持纯仓颉表路径。
- **常量与表的运行期持久化/预生成文件**：表、常量与机器码一律构造期/首次使用时现算，不落盘、不生成源码。
