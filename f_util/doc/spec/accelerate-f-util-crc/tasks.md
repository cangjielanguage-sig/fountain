# Tasks: f_util CRC-16/CRC-64 本地码加速

> **实施纪律**：严格 TDD —— 每条「红」先写出会失败的用例并实跑确认失败，再写「绿」。任何一步全绿前不进入下一节。
> **红线**：`Crc16` / `Crc64` / `CrcEngine` / `crc16*` / `crc64*` 的公开签名、变体列表、RevCheck 值、增量语义逐位不变；`CrcEngine` 的 32 位切片热循环与性能不回退。
> **两阶段交付**：阶段一（§1–§5，反射域 4 变体 + CRC-16）验收通过后可独立合并发布；阶段二（§6–§7，非反射域 2 变体）在阶段一合并后继续。§8–§11 为两阶段共用的收尾。
> **顺序理由**：先做纯仓颉的表路径（§1–§3、§6），它们无平台依赖、能独立交付；常量生成器（§4、§7.1）是折叠核的前置，先能自证正确再谈机器码；机器码发射器与折叠核（§5、§7.3）风险最高，放在各自阶段末尾，且失败可整体回退到表路径。

## 0. 前置（同步与承重假设 spike，不写产品代码）

- [x] 0.1 **基线确认**：确认分支上已有 `f_util/src/code_buffer.cj`、`crc32_native_x86.cj` / `crc32_native_arm.cj` / `crc32_native_stub.cj` 与 `crc32_codegen_test.cj`
  > 本 worktree 基线为 `origin/sts/1.3.x`（dc4f595b，已含 CRC-32 生成式硬件路径）。这些文件目前只在 sts 线上，master 的 `c40ceb81` 尚未同步；若分支被改回 master 基线，必须先把 sts 的 `09d02e8b` / `a66dbd4e` 合入，否则 §5 无从复用，不靠自造 `CodeBuffer` 绕过。
- [x] 0.2 读透既有生成式路径：`CodeBuffer.alloc/write/seal/rawPointer`、`CFunc<(UInt32, CPointer<Byte>, UInt64) -> UInt32>` 的调用形态、`ArrayList<CodeBuffer>` 保活与 `Mutex` 缓存
  > 结论写进 `design.md` D7/D8 的注：本变更只把函数签名换成 `(UInt64, CPointer<Byte>, UInt64) -> UInt64`，其余照搬。
- [ ] 0.3 最小 spike：生成一个只做 `return crc + 1` 的 5~10 字节函数，跑通 `alloc → write → seal → CFunc`；再故意让 `mprotect` 失败，确认返回 `None` 且不崩
  > 这一步只验证"机器码能生成、能调用、能失败回退"，不涉及折叠算法。
- [x] 0.4 CPU 特性探测实测：x86_64 看 `/proc/cpuinfo` 的 `pclmulqdq`；aarch64 看 `getauxval(AT_HWCAP)` 的 `HWCAP_ASIMD`（`1 << 1`）与 `HWCAP_PMULL`（`1 << 4`），并记录本机结果
  > 本机不具备时，§5/§7 的硬件等价性用例只能靠 `F_UTIL_CRC_HW=off` 与 CI 覆盖，需在 5.x/7.x 的注里写明"未在本机验证硬件路径"。
- [ ] 0.5 指令编码夹具：用 `llvm-mc` 或 `aarch64-linux-gnu-as` 生成 `PMULL` / `PMULL2` / `VEOR` / `LDR q` / `REV64` / `MOVZ` / `MOVK` / `INS` / `RET` 与 `PCLMULQDQ` / `PXOR` / `MOVDQU` / `MOVABS` / `MOVQ` / `PUNPCKLQDQ` / `PSHUFB` / `RET` 的字节序列，存成测试夹具
  > 夹具只是开发期产物，不进构建；目的是让发射器的每条指令都有独立断言，而不是等整个内核跑错再排查。
- [x] 0.6 确认构建形态：`f_util/cjpm.toml` 无改动，`cjpm build` 与 `cjpm test` 仅靠仓颉源码即可通过
  > 这是本变更与旧方案的分界线：如果这里需要改 `cjpm.toml`，说明方案跑偏了，停下来改设计。

> **门禁**：0.1–0.6 结论落地前不写 §5 的任何发射器代码 —— 否则会写出"调不通/编不进"的机器码。

## 1. 表结构泛化（纯重构，行为与性能都不变）

- [x] 1.1 绿（先补护栏）：确认 `CrcEngine_test.cj` 既有的"32 位变体 1 MiB 吞吐 ≥ 30 MB/s"门禁用例可复现当前 51~58 MB/s 基线并留档
  > 这是重构期的性能护栏：任何一步让 32 位掉到 30 MB/s 以下就必须回退该步。
- [ ] 1.2 绿：`CrcEngine` 把 `slice1/slice2/slice3` 换成 `slices64: Array<Array<UInt64>>` + `slicingDepth: Int64`，32 位反射路径读 `slices64[1]` / `slices64[2]` / `slices64[3]`；热循环代码逐字保留
- [x] 1.3 验收：`cd f_util && cjpm test` 全绿（含 `crc_check_test` 全变体）。32 位实走生成式硬件路径，实测 8.6 GB/s；表路径护栏用例仍 ≥ 30 MB/s
- [x] 1.4 绿：新增 `slices16: Array<Array<UInt16>>` + `slicing16`、`slices64` + `slicing64` 字段；构造期开销与对象大小变化随 §2/§3 实测可接受
  > 对象大小变化要记录：`CrcEngine` 实例从 2 表 + 3 表变成 2 表 + 动态数组，`Crc16`/`Crc64` 每个静态 `let` 各持一个实例。

## 2. 阶段一：CRC-16 slicing-by-2 + `UInt16` 表项

- [x] 2.1 红：`CrcEngine_test.cj` 新增 16 位等价性用例 —— `Crc16.modbus`（反射）与 `Crc16.ccittFalse`（非反射）在长度 `0,1,2,3,4,5,7,8,15,16,17,255,256,257,4095,4096,4097,65537` 上与逐位参考实现逐位一致
  > 先跑一次确认**当前实现是通过的**（逐字节路径本来正确），然后故意把切片表填错（如 `t1` 误用 `t0`）确认用例能抓住 —— 证明用例有效后再改回来。这是"红"的正确形态：不是让现有实现失败，而是让**错误实现**失败。
- [x] 2.2 红：边界数据用例 —— 全 `0x00`、全 `0xFF`、单字节 `0x80` / `0x01`、以及 4 字节对齐但内容随机的数据，验证表项截断到 16 位不丢高位
- [x] 2.3 绿：构造期生成 `t0..t1`（`Array<UInt16>`，由 `reflectedTable` / `normalTable` 派生后 `& 0xFFFF`）
- [x] 2.4 绿：反射 16 位热循环 —— 一次 2 字节 word + 2 次表查；尾巴走原逐字节路径
- [x] 2.5 绿：非反射 16 位热循环 —— 同一 word 组装，按 MSB-first 选择表索引
- [x] 2.6 绿：热循环同样用 `acquireArrayRawData` 取裸指针（32 位路径已证明默认构建下下标访问约 25 ns/次），`try/finally` 成对 release
- [x] 2.7 验收（`P1-1` / `P1-4`）：`Crc16.all` 24 个变体检查值全绿；`F_UTIL_PERF=1` 下 1 MiB `crc16` 实测 ≥ 40 MB/s，把实测值写进本任务注

## 3. 阶段一：CRC-64 反射 4 变体的表路径

- [x] 3.1 红：`CrcEngine_test.cj` 新增 64 位等价性用例 —— `Crc64.xz` / `iso` / `redis` / `jones` 跑 §2.1 同一长度集合；同样先造一个"故意错位"的表验证用例有效
- [x] 3.2 红：8 字节边界用例 —— 长度 `7,8,9,15,16,17` 与"切在 8 字节内部"的分段调用
- [x] 3.3 绿：构造期生成反射 64 位的 `t0..t7`（`UInt64`），`slicingDepth = 8`、`sliceWidth = 64`；派生仍走统一 `buildSliceTable`
- [x] 3.4 绿：反射 64 位热循环（小端 word），尾巴走逐字节路径
- [x] 3.5 验收（`P1-1` / `P1-4`）：`Crc64.all` 6 个变体检查值全绿（非反射 2 个此时仍走逐字节路径，结果必须正确）；`F_UTIL_PERF=1` 下 1 MiB `Crc64.xz` 表路径 ≥ 60 MB/s（对照基线 ~20 MB/s）

> **门禁**：§2 与 §3 全绿后，表路径已可作为"硬件路径永远失败"的兜底交付物。

## 4. 阶段一：GF(2) 常量生成器（G1–G3，反射域）

- [x] 4.1 红：`CrcGf_test.cj` —— `xPowModP(0) == 1`、`xPowModP(64) == P`、`xPowModP(n+1) == mulX(xPowModP(n))`（n 取 0..200 全跑）
- [x] 4.2 红：`barrettMu` 与长除法现算的 `⌊x^128 / P⌋` 逐位相等（长除法的参考实现独立写一份，不复用生成器的辅助函数）
- [x] 4.3 红：折叠恒等式 —— 随机 128 位 `v`，"乘常量 + Barrett 约减" 等于 "按多项式取模" 的参考结果（各 200 组确定性伪随机）
- [x] 4.4 绿：`CrcGf` —— 128 位值类型（`hi/lo: UInt64`）、`mulX`、`xPowModP`、`barrettMu`、`foldConstants(poly, reflected)`
- [x] 4.5 绿：生成 G1（`0x42F0E1EBA9EA3693`）、G2（`0x1B`）、G3（`0xAD93D23594C935A9`）三组反射域常量；G3 被 `redis` 与 `jones` 共享，缓存键为 `(poly, true)`
- [x] 4.6 验收（`P1-2`）：`CrcGf_test` 全绿；打印三组常量，人工核对 `xz` 与公开资料的 CRC-64/XZ 常量一致（作为"生成器没错"的第二证据，不作为唯一证据）；断言 G1/G2/G3 互不相同

## 5. 阶段一：反射域生成式折叠核（`PMULL` / `PCLMULQDQ`）

- [x] 5.1 红：`CrcEngine_test.cj` 的 `crc64HwMatchesSoftwareForXz` —— `setNativeEnabled(false)` 下 6 个变体与逐位参考一致（先证明开关本身有效）
  > 实际落在 `CrcEngine_test.cj` 而非独立的 `crc64_codegen_test.cj`：机器码是静态字节数组，没有发射器，等价性用例才是唯一运行期闸门。
- [x] 5.2 红：`crc64HwSegmentedMatchesOneShot` —— 4097 字节按 `1+3+5`、`16+16`、`15+17`、`255+257` 四种切分，与一次累计逐位一致
- [x] 5.3 红：同进程交替调用 —— 每个长度都先走硬件再关开关走表路径，交替 6 变体 × 8 长度，结果一致、无缓存污染
- [x] 5.4 绿：x86_64 编码 —— 离线编码器生成 `PCLMULQDQ` / `PXOR` / `MOVDQU` / `MOVABS` / `MOVQ` / `PUNPCKLQDQ` / `PSHUFB` / `RET` 静态字节，`objdump -D -b binary -m i386:x86-64` 逐条核对
- [x] 5.5 绿：aarch64 编码 —— `PMULL` / `PMULL2` / `VEOR` / `LDR q` / `RBIT` / `REV64` / `EXT` / `INS` / `RET`，`as -march=armv8-a+crypto` 汇编后 `objcopy` 取 `.text`，`objdump -d` 核对
- [x] 5.6 绿：反射域折叠核 —— **单块 16 字节**折叠 + 1 次收尾折叠 + Barrett 约减；常量以指针传入 `[P, x^128, x^192, mu]`（不内联）；只处理 `len & ~15`，`len < 16` 直接返回
  > 原计划的 4 通道 × 128 位 lane 未采用：单块实测 7450 MB/s / 777 ns 已远超门禁，4 通道会把内核从 196 B 抬到 400 B 以上却无收益。反射域实现为"入口/出口 `RBIT` + 正常域折叠"，与原设计"反射域常量 + 小端 lane"不同，见 design D5。
- [x] 5.7 绿：`Crc64Hw` 仓颉侧 —— 三份 `@When`（aarch64 / x86_64 / stub）；能力探测（x86 `pclmulqdq`+`ssse3`，aarch64 `getauxval` 的 `PMULL`）；`Mutex` 缓存；`ArrayList<CodeBuffer>` 保活；`setNativeEnabled` / `resetForTest`
- [x] 5.8 绿：`CrcEngine.update` 分派 —— `hw 可用 && width==64 && refin && poly 受支持 && len >= 256`；不切前缀，尾部最多 15 字节走表路径
- [x] 5.9 验收（`P1-3` / `P1-5`）：4 个反射变体与表路径逐位一致；`objdump` 确认代码页含 `pmull/pmull2`（aarch64）与 `pclmulqdq`（x86 编码）；`cjpm.toml` 无改动
- [x] 5.10 验收（`P1-4`）：aarch64 实测 1 MiB 7450.5 MB/s、4 KiB 单次 777.03 ns；6 变体全部与表路径逐位一致
- [x] 5.11 验收（`P1-5`）：`@When` 并在 Linux/aarch64 与 Linux/x86_64 外回落 stub（**注：stub 当前只判 `os != "Linux"`，见 12.2**）

> **阶段一门禁**：5.1–5.11 全绿 → 按 §11 合并阶段一。未达标不得进入 §6。

## 6. 阶段二：CRC-64 非反射 2 变体的表路径

- [x] 6.1 红：`slicingBy8MatchesReferenceForAllCrc64Variants` 覆盖 6 变体 × 22 长度（含 `crc != 0` 入口）
- [x] 6.2 红：8 字节边界与字节序 —— 长度含 `7,8,9,15,16,17,63,64,65`；`slicingBy2EdgeBytesMatchReference` 覆盖 `0x80` / `0x01` 敏感模式
- [x] 6.3 绿：构造期生成 `t0..t7`（由 `normalTable` 派生），非反射热循环按 MSB-first 组装 word
- [x] 6.4 验收（`P2-1`）：`Crc64.all` 6 变体检查值全绿；`ecma182` / `we` 表路径单测归入 9.5

## 7. 阶段二：正常域折叠核

- [x] 7.1 红（口径收敛）：**不设独立 G4** —— 反射域先 `RBIT`，位反转后与正常域共用同一组 poly 常量；`reflectConstantsAreConsistent` 断言 G1/G2/G3 两两不同
- [x] 7.2 红：`ecma182` / `we` 在 256..65537 与非 16 整数倍输入上与表路径逐位一致
- [x] 7.3 绿：正常域核 —— 每 16 字节 `REV64` + `EXT #8`（aarch64）/ `PSHUFB`（x86_64），无入口/出口 `RBIT`
- [x] 7.4 绿：`Crc64Hw.updateNormal` 独立入口，`CrcEngine.update` 按 `refin` 分派；`ecma182` / `we` 共享同一内核与 G1
- [x] 7.5 验收（`P2-3`）：两变体三态一致（由 9.6 的 `crc64HwThreeStateMatchesReference` 覆盖）
- [x] 7.6 验收（`P2-4`）：`ecma182` 6964 MB/s / WE 6867 MB/s；4 KiB 835 / 853 ns

> **阶段二门禁**：7.1–7.6 全绿 → 按 §11 合并阶段二。

## 8. 文档与既有表述修正

- [x] 8.1 `f_zip/doc/spec/add-f-zip-module/design.md` D16 与 `tasks.md` §18 的"红线：不引 FFI / 硬件指令"改写为"不引 C / FFI / native 链接；硬件加速走 `f_util` 既有的生成式机器码（`CodeBuffer` + `CFunc`）。CRC-32 见 `crc32-hw-cfunc`，CRC-16/64 见 `f_util/doc/spec/accelerate-f-util-crc/`"，保留原实测数据不动
- [x] 8.2 `f_util/README.md` / `README_en.md` 的 CRC 段落补：CRC-64 的 6 个变体在支持 CLMUL 的平台上自动走生成式硬件路径，结果不变；顶层 `crc64()` 指向的 `redis` 已包含在阶段一
- [x] 8.3 `f_util/README.md` 补 16/64 位的表结构变化与生成式路径说明（不改 API 表述）
- [x] 8.4 `design.md` 的 Open Questions 逐条收敛（本次 update 完成：256 阈值、777 ns / 7450 MB/s、aarch64 真机结论）
- [x] 8.5 `proposal.md` 的预期性能数字替换为实测值，`Impact` 内存数字复核为 12 KB + 96 KB + <0.5 KB 代码页（本次 update 完成）

## 9. 性能门禁与实测回填

- [x] 9.1 绿（部分）：CRC-16 表路径、CRC-64 表路径、XZ 硬件路径与 4 KiB 单次已加，全部由 `F_UTIL_PERF=1` 门控
- [x] 9.2 验收：实测已回填任务注、`design.md` Open Questions 与 `proposal.md`（98.35 / 52.37 / 7450.5 MB/s，777.03 ns）
- [x] 9.3 验收：4 KiB 单次 777.03 ns ≤ 1.34 µs，门限未改
- [x] 9.4 验收：硬件 7450.5 MB/s、表路径 98.35 / 52.37 MB/s，均高于下限；门限未改
- [x] 9.5 补齐：**6 个变体逐一**实测（healthy）：6867~7433 MB/s、4 KiB 813~853 ns，全部达标
- [x] 9.6 补齐：`F_UTIL_CRC_HW=auto|on|off` 三态用例（`crc64HwThreeStateMatchesReference`，含 `off` 不进核、`auto/on` 必进的断言）

## 10. 全量回归

- [x] 10.1 `cd f_util && cjpm test` 全绿：**76/76 PASS，0 SKIP，0 FAILED**（改造前 60 条）
- [x] 10.2 `cjpm build` 无新增 warning（仅既存 `CJPM_CONFIG` deprecation）
- [x] 10.3 调用方回归：`f_protocol` 85 / `f_store` 204 / `f_zip` 145，全部 exit=0
- [ ] 10.4 交叉语言用例：本机无 `crcmod`；检查值取自 RevEng catalogue（非自比），仍缺一次独立工具交叉验证
- [x] 10.5 `git status` 确认改动只落在 `f_util/` 与 `f_util/doc/spec/accelerate-f-util-crc/`

## 11. 提交与分阶段合并

- [x] 11.1 分支：`feature/f-util-crc64`（worktree `.worktrees/f_util_crc`，基线 `origin/sts/1.3.x`）
- [x] 11.2 阶段一提交：`362a4b48`（表路径）、`3c757c05`（`CrcGf`）、`1cb0f7c5`（aarch64 核）
- [x] 11.3 阶段一合并：`5f0afc87`（`--no-ff` 回到 `sts/1.3.x`），合并后 f_util 76/76；已推送 `dc4f595b..5f0afc87`
- [x] 11.4 阶段二提交：`e461c0bd`（6 变体接线 + 正常域核）、`55984963`（x86_64 编码）
- [x] 11.5 阶段二合并：随 `5f0afc87` 一次合并完成（分支保留，等验后删除）

## 12. 收尾（verify 发现，待 apply）

- [x] 12.1 `F_UTIL_CRC_HW=auto|on|off` 三态开关：`auto` 默认、`on` 强制尝试、`off` 强制表路径；`1`/`0` 兼容旧值（`crc64HwThreeStateMatchesReference` 覆盖 6 变体 × 2 长度）
- [x] 12.2 `crc64_native_stub.cj` 的 `@When` 改为 `os != "Linux" || (arch != "aarch64" && arch != "x86_64")`，修 Linux-riscv64/loongarch64 缺 `Crc64Hw` 的编译失败
- [x] 12.3 `forceAllocFailureForTest` 钩子 + "代码页生成失败回退"用例（`crc64HwFallsBackWhenCodePageAllocationFails`）
- [x] 12.4 6 变体性能用例（1 MiB + 4 KiB 逐一，取 3 次最小值）
  > 门禁本身未改。主机降频时 3 条性能用例会红（CRC32 对照同比例下降），见 12.7。
- [x] 12.5 §8 文档三项（f_zip D16、README 中英）
- [ ] 12.6 x86_64 真机验证（用户执行）：`cjpm test --filter CrcEngine_test` 与 `F_UTIL_PERF=1`
- [x] 12.7 性能门禁口径：保持绝对门限。健康时段 6 变体 6867~7433 MB/s、4 KiB 813~853 ns，全绿；主机降频时段同比例下降（CRC32 对照 9182 → 4800），此时 3 条性能用例会红——属环境噪声，靠 `F_UTIL_PERF=1` 门控隔离，不进默认 CI
