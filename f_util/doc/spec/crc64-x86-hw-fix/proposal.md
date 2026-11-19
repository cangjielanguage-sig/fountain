# Proposal

## Why

`accelerate-f-util-crc` 在 `sts/1.3.x` 落地后，x86_64 的 CRC-64 生成式折叠核（`crc64_native_x86.cj` 的 `REF_CODE` / `NORM_CODE`）**从未在 x86 真机执行过**（源码注释已写明）。在 WSL Ubuntu 24.04 / x86_64 上实测：

- `CrcEngine_test` 默认（auto）**6 个用例失败**：`crc64HwMatchesSoftwareForXz`、`crc64HwSegmentedMatchesOneShot`、`crc64HwThreeStateMatchesReference`、`otherWidthsAndNonReflectedMatchReference`、`slicingBy8MatchesReferenceForAllCrc64Variants`、`slicingBy8SegmentedUpdatesMatchOneShot`；
- `F_UTIL_CRC_HW=off` 后，表路径用例全部通过（15 PASS / 1 FAIL，唯一失败是三态用例内部强制 `on`），说明**软件/表路径正确，问题只在 x86_64 机器码**；
- 硬件输出出现 `0xF0F0F0F0F0F0F0F0`，正是 x86 常量里的 `maskF0`。

根因已定位：反汇编 `REF_CODE` 可见它把常量按 **16 字节向量**加载/使用，但 `CrcGf.reflectX86Constants` 返回的是 **8 字节连续布局**。例如：

- `xmm4 = [rcx+0x0]` 实际是 `P|K128`；
- `xmm5 = [rcx+0x10]` 实际是 `K192|mu`；
- `xmm9 = [rcx+0x50]` 实际是 `revIdx`，却被当作 `mask0F` 使用；
- `xmm8 = [rcx+0x40]` 实际是 `maskF0`，却被当作 LUT 使用。

这不是“某个常量写错”，而是整段机器码的常量契约与生成器不一致。

## What Changes

- 用**新的单块 16 字节折叠核**替换 `crc64_native_x86.cj` 的 `REF_CODE`（495 字节）与 `NORM_CODE`（221 字节）：
  - ABI 不变：`(UInt64 crc, Byte* data, UInt64 len, UInt64* consts) -> UInt64`，`len` 为 16 的整数倍；
  - 常量契约与现有 `CrcGf.reflectX86Constants` 完全一致：`P/K128/K192/mu` 各 8 字节，LUT/mask0F/maskF0/revIdx 各 16 字节；
  - 反射核：入口 64 位位反转 → 逐块 bit-reverse + 16 字节反转 → 正常域折叠 → Barrett → 出口位反转；
  - 正常核：逐块 16 字节反转 → 折叠 → Barrett；不做入口/出口位反转。
- 不修改 `CrcGf`、`CrcEngine`、公开 API、`cjpm.toml`、构建链；表路径与回退逻辑保持原样。
- 新增一个聚焦回归测试（XZ 256 字节）先 Red，再以新核转 Green；既有 6 个失败用例作为集成 Red/Green 闸门。

## Non-Goals

- 不改 CRC-32 / aarch64 路径；
- 不重写 CRC-64 表路径；
- 不引入 C/FFI/第三方库；
- 不改变 CRC-64 的公开语义与输出。

## Impact

- 代码：仅 `f_util/src/crc64_native_x86.cj`（字节数组 + 注释）与 `f_util/src/CrcEngine_test.cj`（新增回归用例）。
- 结果：x86_64 CRC-64 硬件路径与表路径逐位一致；生成失败/`F_UTIL_CRC_HW=off` 仍回退表路径。
- 性能：目标保持 1 MiB ≥500 MB/s、4 KiB ≤1.34 µs（由 `F_UTIL_PERF=1` 门控用例验收）。
