# Proposal

## Why

零第三方运行时依赖：不使用 libdeflate/zlib，也不写 C 垫片。用 **运行时机器码生成 + `CFunc`** 调硬件 CRC 指令，纯软件实现保留为回退。

尖刀已验证 `CFunc(CPointer<Unit>(addr))` 可调用任意地址的机器码（与 f_jit 同一手法，不依赖 f_jit）。本变更把生成器放进 `f_util`，只针对 **Linux x86_64 / aarch64**。

## What Changes

**Phase 1（低风险，先做）**

- `CodeBuffer`：`mmap` RW → 写机器码 → `mprotect` RX（W^X）→ `__clear_cache`；失败返回 `None`。
- CPU 特性探测：x86_64 用 `cpuid`/`/proc/cpuinfo` 判断 `sse4_2`/`pclmulqdq`；aarch64 用 `getauxval(AT_HWCAP) & HWCAP_CRC32`。
- 生成并接入：
  - x86_64 **CRC32C**（`crc32` 指令，直接、低风险）；
  - aarch64 **ISO-HDLC**（`crc32*`）与 **CRC32C**（`crc32c*`）。
- `Crc32.compute/update` 对相应变体走 native；结果逐位不变；公开 API 零变化。

**Phase 2（go/no-go 尖刀）**

- x86_64 **ISO-HDLC**：唯一硬件路径是 **PCLMULQDQ** 折叠（`crc32` 指令是 CRC32C，不能复用）。
- 先写尖刀：生成单块/多块折叠函数，和软件逐位对拍并计时。
- 达标（≥3× 软件、随机长度全对）才集成；不达标就停，x86 ISO 保持软件，报告写清结论。

## Non-Goals

- CRC-16/CRC-64/koopman 等长尾的硬件化；`crc32c` 之外的变体。
- 不做 C 垫片、不链接第三方库、不改线格式、不改公开 API。
- 不把生成器做成通用 JIT/汇编器，只覆盖 CRC 所需的最小指令集。

## Impact

- 代码：`f_util/src/code_buffer.cj`、`crc32_codegen_x86.cj`、`crc32_codegen_aarch64.cj`、`crc32.cj` 快路径、测试与文档。
- 构建：无新增依赖；`mmap/mprotect/__clear_cache` 走 libc，`f_util` Linux target 已链接 `-ldl`（`__clear_cache` 由编译器运行时提供）。
- 安全：代码页 W^X；`mprotect` 失败/策略拦截 → 纯软件。
- 结果：CRC 值逐位不变；目标见 design §7。
