# Spec Delta

## Purpose

为 `fountain::f_util` 既有的 CRC 引擎（`CrcEngine` / `Crc32` / 顶层 `crc32*`）补一份规格，约束它的**吞吐改造边界**：允许换内层循环与查表方式，**不允许**改变任何计算结果、参数口径与公开签名。

> 已实现能力的行为契约在本文件里被**钉死**，而不是新定义：`Crc32` 的 11 个变体、RevEng 检查值、`initRegister → update → finish` 的增量语义都是既有事实（`f_util/src/crc32.cj`、`f_util/src/crc_check_test.cj`）。本 delta 只增加「优化后的等价性」与「吞吐下限」两类约束。

## ADDED Requirements

### Requirement: 全变体检查值与增量语义不变

`CrcEngine` / `Crc32` SHALL 对 `"123456789"` 保持各变体的 RevEng 标准检查值（`Crc32.checkValue`）；任何吞吐优化 SHALL NOT 改变多项式、寄存器初值、输入反射 `refin`、输出反射 `refout`、结果异或 `xorout` 与位宽。

`initRegister()` → `update(crc, data)` → `finish(crc)` 的增量语义 SHALL 保持不变：`update` 操作的是**未收尾**的寄存器值，`finish` 才做按需反射与异或。

#### Scenario: 逐个变体检查值不变

- **WHEN** 对 `"123456789"` 依次计算 `Crc32.all` 中的每个变体
- **THEN** 每个结果都等于该变体的标准检查值（如 `isoHdlc → 0xCBF43926`、`crc32c → 0xE3069283`、`bzip2 → 0xFC891918`）
- **AND** `crc_check_test.cj` 的现有断言一条都不需要改

#### Scenario: 增量接口与一次算完等价

- **WHEN** 分别用 `compute(data)` 与 `finish(update(update(initRegister(), data[0..k]), data[k..]))` 计算同一段数据
- **THEN** 两者结果相等，对所有切分点 `k` 都成立
- **AND** 顶层 `crc32Init` / `crc32Update` / `crc32Finish` / `crc32` 的返回值与改造前逐位相同

### Requirement: 切片路径与逐字节路径结果逐位一致

当变体满足「`refin == true` 且位宽为 32」时，`CrcEngine.update` SHALL 允许走 slicing-by-4 路径（预生成 `t1..t3` 三张 256 项表，一次消费 4 字节，不足 4 字节的尾巴走逐字节/索引路径）。该路径 SHALL 与逐字节查表路径对**任意长度、任意内容**的输入产生相同的寄存器值。

其余变体（非反射，或位宽 8/16/24/40/64）SHALL 保持逐字节查表语义（允许改为索引遍历以去掉迭代器开销）。

#### Scenario: 任意长度两路结果一致

- **WHEN** 以测试内的逐字节参考实现为基准，对长度 `0`、`1`、`2`、`3`、`4`、`5`、`7`、`8`、`4095`、`4096` 以及随机长度的数据分别计算
- **THEN** 优化后的 `CrcEngine.update` 与参考实现的寄存器值逐位相同
- **AND** 长度不整除 4 时尾巴被正确处理，不丢字节也不重复消费

#### Scenario: 分段累计与一次累计等价

- **WHEN** 把同一段数据按 `1+3+5`、`4` 的整数倍、`4n+1` 等不同切分方式分多次调用 `update`
- **THEN** 所有切分方式得到的最终寄存器值相同
- **AND** 与一次 `update` 整段的结果相同

#### Scenario: 切片只对反射 32 位启用

- **WHEN** 对一个非反射变体（如 `Crc32.bzip2`）或非 32 位变体（`crc16` / `crc64` 对应的引擎）计算长数据
- **THEN** 结果与其逐字节参考实现一致
- **AND** 没有因为"误用切片路径"而出现偏差（这些变体的表口径与反射 32 位不同）

### Requirement: 吞吐下限

`f_util` 的 CRC-32/ISO-HDLC 计算 SHALL 在融合开发环境（Linux x86_64，`cjpm test` 默认构建）达到 **≥ 30 MB/s**（1 MiB 数据的保守下限，用于避免机器差异导致 flaky）；实测目标为 **≥ 60 MB/s**，以满足「4.4 GB 单条目一次往返 < 10 分钟」。

吞吐断言 SHALL 由环境变量门控（`F_UTIL_PERF=1` 才跑），默认 SKIP 并打印跳过原因，与 `f_zip` 的 `F_ZIP_RESOURCE` / `F_ZIP_SLOW` 口径一致。

#### Scenario: 1 MiB 吞吐达标

- **WHEN** 在 `F_UTIL_PERF=1` 下对 1 MiB 数据计算一次 `crc32`
- **THEN** 实测吞吐 ≥ 30 MB/s
- **AND** 用例打印实测 MB/s，供回填 `design.md` D16 与 `f_zip/doc/f_zip模块设计.md` §10

#### Scenario: 未设门控时跳过

- **WHEN** 未设置 `F_UTIL_PERF`
- **THEN** 吞吐用例直接返回并打印 `SKIP` 原因，不计为失败
