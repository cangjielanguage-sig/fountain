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

- [x] 5.1 红：`crc64_codegen_test.cj` —— `F_UTIL_CRC_HW=off` 下 `xz` / `iso` / `redis` / `jones` 与参考实现一致（先证明开关本身有效）
- [x] 5.2 红：`auto` 与 `on` 下 4 个反射变体结果与 `off` 完全一致；`on` 在无能力环境 SKIP 并打印原因
- [x] 5.3 红：同进程交替调用用例 —— 硬件路径与表路径交替 200 次（长度跨越阈值），4 个变体结果与参考实现一致
- [x] 5.4 绿：发射器骨架 + x86_64 编码 —— `PCLMULQDQ` / `PXOR` / `MOVDQU` / `MOVABS` / `MOVQ` / `PUNPCKLQDQ` / `RET`；每条指令先过 §0.5 的黄金字节断言
- [x] 5.5 绿：aarch64 编码 —— `PMULL` / `PMULL2` / `VEOR` / `LDR q` / `MOVZ` / `MOVK` / `INS` / `RET`；同样逐条黄金字节断言
- [ ] 5.6 绿：反射域 4 通道折叠核 —— 4×16 字节 lane 折叠 + 3 次收尾折叠 + Barrett 约减；常量按 `[K_lo, K_hi]` 成对装进 128 位寄存器（`PMULL`/`PCLMULQDQ` 各取低/高半区），以立即数内联；只处理 `len & ~63`，`len < 64` 直接返回
  > 入口状态注入的半区选择（`crc` 放 lane0 低 64 位）与 `K` 的指数起点不靠推理拍板：先按 `design.md` D5 写，等价性用例失败就整组前移一格，直到 5.1–5.3 全绿。
- [x] 5.7 绿：`Crc64Hw` 仓颉侧 —— `crc64_native_x86.cj` / `crc64_native_arm.cj` / `crc64_native_stub.cj` 三份 `@When` 声明；能力探测（x86 `pclmulqdq`，aarch64 `ASIMD` + `PMULL`，`getauxval` 复用 `crc32_native_arm.cj` 的既有声明、不重复声明）；`Mutex` 缓存 `(poly, true) → CFunc`；`ArrayList<CodeBuffer>` 保活；`setNativeEnabled` / `resetForTest`
- [x] 5.8 绿：`CrcEngine.update` 的 64 位反射分派 —— `hw 可用 && width==64 && refin==refout && len >= HW_MIN_LEN` 时调用折叠核；**不切 `data[0..aligned]` 前缀**，直接把完整数组与前缀长度交给 `Crc64Hw.update`，尾部最多 63 字节走表路径
- [x] 5.9 验收（`P1-3` / `P1-5`）：4 个反射变体在 `auto|on|off` 下逐位一致；`objdump -D -b binary` 反汇编一份代码页，确认含 `pmull`（aarch64）或 `pclmulqdq`（x86_64）；`cjpm.toml` 无改动
- [x] 5.10 验收（`P1-4`）：aarch64 实测 1 MiB 7424 MB/s、4 KiB 单次 779 ns；6 变体全部与表路径逐位一致
- [x] 5.11 验收（`P1-5`）：非 Linux / 非目标 arch 的构建不出现未解析符号；`F_UTIL_CRC_HW=off` 全绿

> **阶段一门禁**：5.1–5.11 全绿 → 按 §11 合并阶段一。未达标不得进入 §6。

## 6. 阶段二：CRC-64 非反射 2 变体的表路径

- [ ] 6.1 红：`CrcEngine_test.cj` 新增 `Crc64.ecma182` / `Crc64.we` 的等价性用例（§2.1 同一长度集合，含 `crc != 0` 入口）
- [ ] 6.2 红：8 字节边界与字节序用例 —— 长度 `7,8,9,15,16,17,63,64,65`；数据含 `0x80`、`0x01` 等字节序敏感模式
- [ ] 6.3 绿：构造期生成非反射 64 位的 `t0..t7`（由 `normalTable` 派生），复用 §3.3 的派生函数；非反射热循环按 MSB-first 组装 word
- [ ] 6.4 验收（`P2-1`）：`Crc64.all` 6 个变体检查值全绿；`ecma182` / `we` 表路径 1 MiB ≥ 60 MB/s

## 7. 阶段二：正常域常量与生成式折叠核

- [ ] 7.1 红：`CrcGf_test.cj` —— 第 4 组 G4（正常域 `0x42F0E1EBA9EA3693`）的常量自洽；断言 G4 与 G1 不同（同 poly、不同坐标）
- [ ] 7.2 红：`crc64_codegen_test.cj` —— `ecma182` / `we` 在 `auto|on|off` 下逐位一致；覆盖 8 字节字边界、64 字节折叠块边界与 `crc != 0` 入口
- [ ] 7.3 绿：正常域折叠核 —— 数据每个 64 位字先做 `REV64`（aarch64）/ `PSHUFB`（x86_64，固定反序掩码），`crc` 注入 lane0 高 64 位；常量用 G4
- [ ] 7.4 绿：`Crc64Hw` 的缓存键扩展到 `(poly, false)`；`CrcEngine.update` 的分派对 `refin == refout == false` 的 64 位变体启用；`ecma182` / `we` 共享同一 G4 内核
- [ ] 7.5 验收（`P2-3`）：2 个非反射变体三态一致；反汇编确认正常域代码页含 `rev64`/`pshufb` 与 CLMUL 指令
- [ ] 7.6 验收（`P2-4`）：2 个非反射变体 1 MiB ≥ 500 MB/s、4 KiB ≤ 1.34 µs；6 个变体的 4 KiB 全部 ≤ 1.34 µs
- [ ] 7.7 验收（`P2-5`）：6/6 变体在 `auto|on|off` 下与参考实现逐位一致；`F_UTIL_CRC_HW=off` 全绿；非目标平台回退正确

> **阶段二门禁**：7.1–7.7 全绿 → 按 §11 合并阶段二。

## 8. 文档与既有表述修正

- [ ] 8.1 `f_zip/doc/spec/add-f-zip-module/design.md` D16 与 `tasks.md` §18 的"红线：不引 FFI / 硬件指令"改写为"不引 C / FFI / native 链接；硬件加速走 `f_util` 既有的生成式机器码（`CodeBuffer` + `CFunc`）。CRC-32 见 `crc32-hw-cfunc`，CRC-16/64 见 `f_util/doc/spec/accelerate-f-util-crc/`"，保留原实测数据不动
- [ ] 8.2 `f_util/README.md` / `README_en.md` 的 CRC 段落补：CRC-64 的 6 个变体在支持 CLMUL 的平台上自动走生成式硬件路径，结果不变；顶层 `crc64()` 指向的 `redis` 已包含在阶段一
- [ ] 8.3 `f_util/README.md` 若列了变体/性能说明，补上 16/64 位的表结构变化与生成式路径说明（不改 API 表述）
- [ ] 8.4 `design.md` 的 Open Questions 逐条收敛：`HW_MIN_LEN` 拐点、4 KiB 门禁实测、aarch64 真机数据必须给出结论或明确"待真机"
- [ ] 8.5 `proposal.md` 的预期性能数字替换为实测值，`Impact` 的内存数字按最终表配置复核（12 KB + 96 KB + 4 份代码页）

## 9. 性能门禁与实测回填

- [ ] 9.1 绿：`CrcEngine_test.cj` 的性能用例 —— CRC-16 表路径、CRC-64 表路径、6 个 64 位变体的硬件路径、6 个变体的 4 KiB 单次绝对耗时；全部由 `F_UTIL_PERF=1` 门控，默认 SKIP 并打印原因
- [ ] 9.2 验收：在融合引擎上跑 `F_UTIL_PERF=1 cjpm test --filter 'CrcEngine_test'`，把实测 MB/s、4 KiB 的 µs 写进任务注与 `design.md` 目标段
- [ ] 9.3 验收：4 KiB 单次未达 1.34 µs 时，记录实测与瓶颈判断（`acquireArrayRawData`、CFunc 过桥、折叠深度、未优化构建），**不为了达标改门限**；按实测回填 spec 并在评审中说明
- [ ] 9.4 验收：硬件路径未达 500 MB/s 时同口径处理；表路径未达 60/40 MB/s 时先查是否误用了带边界检查的下标

## 10. 全量回归

- [ ] 10.1 `cd f_util && cjpm test` 全绿，记录用例总数（改造前 50 条，按实际新增更新）
- [ ] 10.2 `cd f_util && cjpm build` 无新增 warning
- [ ] 10.3 调用方回归：`f_protocol`（帧校验，70 条）、`f_store`（WAL 校验，204 条）、`f_zip`（条目 CRC，135 条）各跑一遍
- [ ] 10.4 交叉语言用例：用 Python `zlib.crc32` 与 `crcmod`（或 `xz --check=crc64` 产出的容器）交叉验证 6 个 CRC-64 变体的检查值，确认不是"自己跟自己比全绿"
- [ ] 10.5 `git status` 确认改动只落在 `f_util/`、`f_zip/doc/spec/`（文档修正）与 `f_util/doc/spec/accelerate-f-util-crc/`，没有误改其它模块

## 11. 提交与分阶段合并

- [ ] 11.1 按 AGENTS.md 的分支流程：`feature/accelerate-f-util-crc`（本 worktree 若已在功能分支上则复用），开工前 `git pull` / `rebase` 同步 master
- [ ] 11.2 **阶段一提交**（建议三次）：① 表结构泛化 + CRC-16 切片 + CRC-64 反射切片（纯仓颉）；② `CrcGf` 三组反射常量；③ 反射域发射器 + `Crc64Hw` + 分派 + 文档修正
- [ ] 11.3 **阶段一合并**：5.1–5.11 全绿后 `git merge --no-ff` 回 `master`；合并后在 master 上跑一次 `f_util` 全量
- [ ] 11.4 **阶段二提交**：④ 非反射 64 位切片；⑤ G4 常量 + 正常域发射器 + 分派扩展
- [ ] 11.5 **阶段二合并**：7.1–7.7 全绿后 `git merge --no-ff` 回 `master`，删除已合并分支
