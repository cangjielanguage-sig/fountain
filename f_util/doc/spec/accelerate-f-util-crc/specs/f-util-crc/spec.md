# Spec Delta

## Purpose

为 `fountain::f_util` 既有的 CRC 引擎（`CrcEngine` / `Crc16` / `Crc64` / 顶层 `crc16*` / `crc64*`）补一份规格，约束它的**实现路径**：允许换表结构、加切片深度、加一条生成式 CLMUL 折叠核，**不允许**改变任何计算结果、参数口径与公开签名。

> 已实现能力的行为契约在本文件里被**钉死**，而不是新定义：24 个 CRC-16 变体与 6 个 CRC-64 变体、RevEng 检查值、`initRegister → update → finish` 的增量语义都是既有事实（`f_util/src/crc16.cj`、`f_util/src/crc64.cj`、`f_util/src/crc_check_test.cj`）。本 delta 只增加「优化后的等价性」「常量可推导性」「生成式硬件路径可回退」与「吞吐/4 KiB 绝对耗时下限」四类约束。

## ADDED Requirements

### Requirement: 全变体检查值与参数口径不变

`CrcEngine` / `Crc16` / `Crc64` SHALL 对 `"123456789"` 保持各变体的 RevEng 标准检查值（`checkValue`）；任何实现路径的变化 SHALL NOT 改变多项式、寄存器初值、输入反射 `refin`、输出反射 `refout`、结果异或 `xorout` 与位宽。

`Crc16.all` 与 `Crc64.all` 的成员、顺序与名字 SHALL 保持不变。

#### Scenario: 逐个变体检查值不变

- **WHEN** 对 `"123456789"` 依次计算 `Crc16.all`（24 个）与 `Crc64.all`（6 个）中的每个变体
- **THEN** 每个结果都等于该变体的标准检查值（如 `CRC-16/MODBUS → 0x4B37`、`CRC-64/XZ → 0x995DC9BBDF1939FA`、`CRC-64/REDIS → 0xE9C6D914C4B8D9CA`）
- **AND** `crc_check_test.cj` 的现有断言一条都不需要改
- **验收点**：`P1-1`（阶段一覆盖 CRC-16 与 4 个反射 64 位变体）、`P2-5`（阶段二补齐 6/6）

#### Scenario: 顶层函数仍指向原变体

- **WHEN** 调用 `crc16` / `crc64` 及其 `String` / `ToString` 重载
- **THEN** 结果分别等于 `Crc16.modbus.compute` / `Crc64.redis.compute`
- **AND** 空输入仍等于 `finish(initRegister())`
- **验收点**：`P1-1`（`crc64()` 指向的 `redis` 属阶段一）

### Requirement: 增量语义与任意切分等价

`initRegister()` → `update(crc, data)` → `finish(crc)` 的语义 SHALL 保持不变：`update` 操作的是**未收尾**的寄存器值，`finish` 才按需反射与异或。

对任意切分点序列，分段 `update` 的结果 SHALL 与一次 `update` 整段完全相同 —— 包括切在 4 字节切片边界、8 字节切片边界、64 字节折叠块内部的情形。

#### Scenario: 任意长度两路一致

- **WHEN** 对长度 `0,1,2,3,4,5,7,8,15,16,17,63,64,65,127,128,129,255,256,257,4095,4096,4097,65537` 的数据分别计算
- **THEN** 每条实现路径（逐字节、切片、生成式折叠）给出的寄存器值都与测试内的逐位参考实现逐位相同
- **AND** 长度不整除切片宽度时尾巴被正确处理，不丢字节也不重复消费
- **验收点**：`P1-1`（阶段一的变体）、`P2-1`（阶段二的两个非反射变体）

#### Scenario: 分段累计与一次累计等价

- **WHEN** 把同一段数据按 `1+3+5`、切片宽度的整数倍、`切片宽度 × n + 1`、逐字节、以及跨 64 字节折叠块边界切分后多次调用 `update`
- **THEN** 所有切分方式得到的最终寄存器值相同
- **AND** 与一次 `update` 整段的结果相同；入口寄存器非零时同样成立
- **验收点**：`P1-1`、`P2-1`

### Requirement: CRC-16 的 16 位切片表

位宽为 16 的变体 SHALL 使用 **slicing-by-2** 路径，切片表表项 SHALL 为 16 位（`UInt16`），由字节表派生后按位宽截断。**表项是 16 位，不是 32/64 位；16 位寄存器窗口只有 2 字节，4 字节一次的四表公式不成立。**

该路径对反射与非反射 16 位变体都 SHALL 成立；不足 2 字节的尾部走逐字节路径。切片表 SHALL NOT 改变 `update` 的输入输出类型。

#### Scenario: 反射与非反射 16 位变体一致

- **WHEN** 对 `Crc16.modbus`（反射）与 `Crc16.ccittFalse`（非反射）计算上述长度集合的数据
- **THEN** 结果与逐位参考实现逐位相同
- **AND** 与关闭切片（逐字节）路径的结果逐位相同
- **验收点**：`P1-1`

#### Scenario: 表项位宽不引入截断错误

- **WHEN** 对含全 `0xFF`、全 `0x00`、单字节 `0x80` / `0x01` 的边界数据计算任意 16 位变体
- **THEN** 中间累加量不因表项为 16 位而丢高位
- **AND** 结果与参考实现一致
- **验收点**：`P1-1`

### Requirement: CRC-64 的 slicing-by-8 表驱动路径

位宽为 64 的变体 SHALL 使用 **slicing-by-8** 路径（8 张 256 项 `UInt64` 表，一次消费 8 字节）；反射变体由反射表派生，非反射变体由正常表派生。不足 8 字节的尾部走逐字节路径。

`refin && width == 32` 的既有 slicing-by-4 路径 SHALL 保持其热循环与裸指针口径不变（结果与性能都不回退）。

#### Scenario: 反射 4 变体的 8 字节边界与尾巴（阶段一）

- **WHEN** 对长度为 `7,8,9,15,16,17` 的数据计算 `Crc64.xz` / `Crc64.iso` / `Crc64.redis` / `Crc64.jones`
- **THEN** 结果与逐位参考实现逐位相同
- **AND** 尾巴不被跳过也不被重复消费
- **验收点**：`P1-1`

#### Scenario: 非反射 2 变体的 8 字节边界与尾巴（阶段二）

- **WHEN** 对长度为 `7,8,9,15,16,17` 的数据计算 `Crc64.ecma182` / `Crc64.we`
- **THEN** 结果与逐位参考实现逐位相同
- **AND** 尾巴不被跳过也不被重复消费
- **验收点**：`P2-1`

#### Scenario: 32 位变体性能不回退

- **WHEN** 在 `F_UTIL_PERF=1` 下测 1 MiB `crc32`
- **THEN** 吞吐不低于改造前的实测区间（51~58 MB/s）的保守下限 30 MB/s
- **验收点**：`P1-4`

### Requirement: 折叠常量必须由多项式推导

生成式硬件路径使用的全部折叠常量（`x^n mod P`、Barrett 商 `mu`、域内多项式）SHALL 在构造期由多项式经 GF(2) 运算生成，SHALL NOT 以硬编码魔术数的形式出现在源码中。

常量 SHALL 按 poly 分组，共 3 组，覆盖 6 个变体与两个域；每组为 `[P, x^128 mod P, x^192 mod P, mu]` 四个 64 位字。生成器 SHALL 提供 `xPowModP(n)` 与 `barrettMu` 两个可独立验证的原语。

#### Scenario: 常量自洽

- **WHEN** 对任意受支持的多项式 `P` 求 `xPowModP(0)`、`xPowModP(64)` 与逐次 `mulX`
- **THEN** `xPowModP(0) == 1`、`xPowModP(64) == P`、`xPowModP(n+1) == mulX(xPowModP(n))`
- **验收点**：`P1-2`（G1~G3，覆盖两个域）

#### Scenario: Barrett 商可复算

- **WHEN** 用长除法现算 `⌊x^128 / P⌋` 并与 `barrettMu` 比较
- **THEN** 两者逐位相等
- **验收点**：`P1-2`、`P2-2`

#### Scenario: 折叠恒等式

- **WHEN** 对随机 128 位值 `v` 执行"乘常量后 Barrett 约减"，并与"把 `v` 当多项式系数做 `mod P`"的参考实现比较
- **THEN** 两者相等
- **验收点**：`P1-2`、`P2-2`

#### Scenario: 组间独立与组内共享

- **WHEN** 比较 G1/G2/G3 的常量集，并检查 `redis`/`jones`、`ecma182`/`we` 使用的内核句柄
- **THEN** 三个组的常量两两不同（防止 poly 串组）
- **AND** `redis`/`jones` 共享 G3、`ecma182`/`we` 共享 G1 的同一份生成代码，差异只来自 `init`/`xorout`
- **验收点**：`P1-2`、`P2-2`

**常量分组（实现口径）**

| 组 | poly | 使用变体 | 域 |
| --- | --- | --- | --- |
| G1 | `0x42F0E1EBA9EA3693` | `xz`；`ecma182`、`we`（共享） | 反射 / 正常各一份用法，常量同一组 |
| G2 | `0x000000000000001B` | `iso` | 反射 |
| G3 | `0xAD93D23594C935A9` | `redis`、`jones`（共享） | 反射 |

反射域先做 64 位位反转，位反转后与正常域共用同一组常量，因此没有独立的"正常域常量组"。

### Requirement: 生成式 CLMUL 折叠核的等价性

在支持 aarch64 `PMULL`/`PMULL2` 或 x86_64 `PCLMULQDQ` 的 Linux 平台上，受支持的 CRC-64 变体 SHALL 在数据长度达到实现定义的阈值时走生成式折叠路径。该路径 SHALL 与表路径对同一输入给出**逐位相同**的寄存器值，包括入口寄存器非零、长度为折叠块整数倍与不整除两种情形。

硬件路径 SHALL 由三态开关控制（`auto` 默认 / `on` 强制 / `off` 强制关闭），开关只影响路径选择，不影响结果。

#### Scenario: 反射 4 变体三态结果一致（阶段一）

- **WHEN** 分别在 `F_UTIL_CRC_HW=auto|on|off` 下对 `xz` / `iso` / `redis` / `jones` 计算同一组数据
- **THEN** 三次得到的检查值与寄存器值完全相同
- **AND** `off` 下必然不经过折叠核；`auto` 下在具备能力的平台必然经过
- **验收点**：`P1-3`

#### Scenario: 非反射 2 变体三态结果一致（阶段二）

- **WHEN** 分别在 `F_UTIL_CRC_HW=auto|on|off` 下对 `ecma182` / `we` 计算同一组数据
- **THEN** 三次得到的检查值与寄存器值完全相同
- **AND** 覆盖 8 字节字边界、64 字节折叠块边界与 `crc != 0` 入口
- **验收点**：`P2-3`

#### Scenario: 无能力时强制开启不视为失败

- **WHEN** 在缺少 PMULL/PCLMULQDQ 的环境下设置 `F_UTIL_CRC_HW=on`
- **THEN** 用例 SKIP 并打印原因，不判失败
- **AND** 实际结果仍由表路径给出且正确
- **验收点**：`P1-5`、`P2-3`

#### Scenario: 同进程交替调用

- **WHEN** 在同一进程内对硬件路径与表路径交替调用（含长度跨越阈值的输入）
- **THEN** 每条结果都与参考实现一致
- **AND** 常量缓存与代码页缓存不引入跨调用状态污染
- **验收点**：`P1-3`、`P2-3`

#### Scenario: 阈值以下与 16 字节不整除输入

- **WHEN** 输入长度小于实现阈值 `HW_MIN_LEN = 256`、或 `len % 16 != 0`
- **THEN** 低于阈值时整段走表路径；达到阈值时折叠核只消费 `len & ~15` 前缀，剩余尾部由表路径消费
- **AND** 整体寄存器值与逐位参考实现一致，不丢字节、不重复消费
- **验收点**：`P1-1`、`P2-1`

### Requirement: 折叠核载体与分阶段覆盖

折叠核 SHALL 通过 `CodeBuffer`（`mmap` RW → 写码 → `mprotect` RX → `__clear_cache`）生成，并通过 `CFunc` 调用；SHALL NOT 引入 `.c` 源文件、`[ffi.c]`、`dlopen` 或新增导出符号。

- **阶段一**：`xz` / `iso` / `redis` / `jones` 四个反射变体 SHALL 走反射域折叠核（数据小端载入，`crc` 注入 lane0 低半区）。
- **阶段二**：`ecma182` / `we` 两个非反射变体 SHALL 走正常域折叠核（数据按 64 位字字节反转，`crc` 注入 lane0 高半区）。

#### Scenario: 双域代码页指令可验证

- **WHEN** 反汇编阶段一与阶段二生成的代码页
- **THEN** 阶段一反射核含 `pmull` / `pmull2`（aarch64）或 `pclmulqdq`（x86_64）
- **AND** 阶段二正常核额外含 `rev64`（aarch64）或 `pshufb`（x86_64）的字节反转序列
- **验收点**：`P1-3`、`P2-3`

### Requirement: 能力缺失时透明回退

当平台不支持生成式路径（非 Linux、或 arch 不是 x86_64 / aarch64）、`CodeBuffer` 分配或 `mprotect` 失败、或 CPU 缺少所需指令时，`update` SHALL 静默回退到表路径，结果不变、不抛异常、不打印日志。

`f_util` SHALL 在这些目标上保持可构建（不出现未解析符号、不要求 C 工具链）。

#### Scenario: 非目标平台仍正确

- **WHEN** 在未启用生成式路径的目标上构建并计算 6 个 `Crc64` 变体
- **THEN** 构建成功且不需要 C 编译器
- **AND** 结果与参考实现一致
- **验收点**：`P1-5`、`P2-5`

#### Scenario: 代码页生成失败回退

- **WHEN** `CodeBuffer.alloc` 或 `seal` 返回失败（测试钩子模拟）
- **THEN** `Crc64Hw.update` 返回 `None`，`CrcEngine.update` 走表路径
- **AND** 不抛异常、不产生重复告警、结果正确
- **验收点**：`P1-5`

### Requirement: 公开 API 与构建形态不变

`Crc16` / `Crc64` / `crc16*` / `crc64*` 的公开签名、可见性、返回类型 SHALL 保持逐字不变；SHALL NOT 新增任何 `public` 声明。

`f_util` SHALL NOT 因本变更新增 C 源文件、`native/` 目录、`[ffi.c]` 配置、`dlopen` 调用或新的动态库导出符号；`libf_util.so` 的导出符号集合 SHALL 与改造前一致。

#### Scenario: 签名零变化

- **WHEN** 对比改造前后的 `f_util` 公开 API 清单
- **THEN** 差集为空
- **AND** 现有调用方（`f_protocol` / `f_store` / `f_zip`）无需改代码即可编译
- **验收点**：`P1-1`、`P2-5`

#### Scenario: 构建形态零变化

- **WHEN** 检查改造后的 `f_util/cjpm.toml`、源码目录与动态库产物
- **THEN** 没有 `[ffi.c]` 段、没有 `native/` 目录、没有新增 `.c`/`.h`
- **AND** `libf_util.so` 没有新增原生导出符号（生成代码不是 ELF 符号）
- **验收点**：`P1-5`

### Requirement: 吞吐与 4 KiB 绝对耗时下限

在融合开发环境（Linux，`cjpm test` 默认构建）下，1 MiB 单遍 SHALL 达到：

- CRC-16 表路径 ≥ 40 MB/s；
- CRC-64 表路径 ≥ 60 MB/s；
- 具备 CLMUL 能力时，6 个 CRC-64 变体的生成式硬件路径各 ≥ 500 MB/s；
- CRC-32 SHALL 维持 ≥ 30 MB/s 的既有下限。

硬件路径的 **4 KiB 单次调用绝对耗时**（含 `acquireArrayRawData` + CFunc 过桥）SHALL ≤ **1.34 µs**，与 CRC-32 生成路径的 4 KiB 帧绝对耗时同口径；6 个变体逐一测量。表路径不设绝对耗时门禁，其判据仍是 MB/s。

吞吐与绝对耗时断言 SHALL 由 `F_UTIL_PERF=1` 门控，默认 SKIP 并打印跳过原因，与 `F_UTIL_PERF` 的既有口径一致。

#### Scenario: 阶段一性能达标

- **WHEN** 在 `F_UTIL_PERF=1` 下对 1 MiB 数据计算 `Crc16.modbus`、`Crc64.xz`（表与硬件两条路径）、以及 4 个反射 64 位变体的硬件路径
- **THEN** 表路径分别 ≥ 40 / 60 MB/s，4 个反射变体硬件路径各 ≥ 500 MB/s
- **AND** 4 个变体的 4 KiB 单次耗时各 ≤ 1.34 µs
- **AND** 用例打印实测 MB/s 与 µs，供回填 `design.md` 与 `proposal.md`
- **验收点**：`P1-4`

#### Scenario: 阶段二性能达标

- **WHEN** 在 `F_UTIL_PERF=1` 下对 1 MiB 数据计算 `Crc64.ecma182` / `Crc64.we`（表与硬件两条路径）
- **THEN** 表路径 ≥ 60 MB/s，硬件路径各 ≥ 500 MB/s
- **AND** 2 个变体的 4 KiB 单次耗时各 ≤ 1.34 µs
- **验收点**：`P2-4`

#### Scenario: 未设门控时跳过

- **WHEN** 未设置 `F_UTIL_PERF`
- **THEN** 全部吞吐/绝对耗时用例直接返回并打印 `SKIP` 原因，不计为失败
- **验收点**：`P1-4`、`P2-4`
