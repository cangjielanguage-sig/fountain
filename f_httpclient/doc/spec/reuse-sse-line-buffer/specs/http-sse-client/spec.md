# http-sse-client

## Purpose

定义 `f_httpclient` SSE 读取器在「行读取」上的结构性约束：`SseReader` 用实例字段的字节缓冲逐行累积，
缓冲按需增长且上界为 `maxLineBytes`；复用不得改变任何一行内容、超限判定或公开 API。

## ADDED Requirements

### Requirement: 行读取复用实例字节缓冲

`SseReader.readLine` MUST 使用实例字段的字节缓冲与已写长度累积一行，MUST NOT 每行新建 `ArrayList<Byte>` 或按行分配的集合；缓冲 MUST 在实例内复用。

缓冲 MUST 按需增长，容量 MUST NOT 超过 `max(maxLineBytes, 0)`（初始容量 `min(256, max(0, maxLineBytes))`），MUST NOT 在构造时按 `maxLineBytes` 一次性预分配。构造 String 时 MUST 只读 `[0, lineLen)`；行结束或抛错后 MUST 复位 `lineLen`。`SseReader` 仍是单消费者、非线程安全对象。

#### Scenario: 短行连续读取

- **WHEN** 响应体中连续出现 1000 条短注释行或短 `data:` 行
- **THEN** 每一行内容都正确，且行缓冲在首次分配后被重复使用（不随行数增长而反复分配）

#### Scenario: 长短行交替

- **WHEN** 先读入一条远长于初始容量的行，紧接着读入一条短行
- **THEN** 短行内容只包含它自己的字节，不包含上一条长行遗留在缓冲尾部的任何字节

#### Scenario: 跨块补齐一行

- **WHEN** 一行的字节被拆到多次底层 `read` 返回（例如每次只返回 7 字节）
- **THEN** 该行内容与一次性读入时逐字节相同

#### Scenario: 超过初始容量的长行

- **WHEN** 单行长度大于初始容量但不超过 `maxLineBytes`
- **THEN** 读取成功，返回内容逐字节正确，缓冲容量增长到足以容纳该行

### Requirement: 行与字段语义逐字节不变

行缓冲的引入 MUST 对调用方完全透明：对同一输入流，`next()` 返回的事件序列与字段值与改造前逐字节相同。

1. 行分隔 MUST 仍为 `\n`，行尾 `\r` MUST 只在 `\n` 结束的行上剥除；
2. 以 EOF 结束的半行 MUST 仍按残留内容返回，且 MUST NOT 剥除其末尾的 `\r`；
3. `:` 开头的注释行 MUST 仍整行丢弃；空行 MUST 仍作为事件结束；
4. `data` 多行 MUST 仍以 `\n` 拼接；字段值 MUST 仍只去掉一个前导空格；未知字段 MUST 仍忽略；
5. 单行长度恰好等于 `maxLineBytes` 时 MUST 读取成功；长度达到 `maxLineBytes + 1` 时
   MUST 抛 `SseLineTooLongException`，抛错类型与判定时机 MUST 保持不变；
6. 流正常结束 MUST 返回 `None`；`close()` 后再次读取 MUST 返回 `None`；
7. 空闲超时 MUST 仍抛 `SseTimeoutException`。

#### Scenario: CRLF 且 `\r` 与 `\n` 分属不同块

- **WHEN** 底层 `read` 先返回以 `\r` 结尾的块、下一次返回以 `\n` 开头的块
- **THEN** 该行与使用同一行 `\n` 结尾时解析结果一致

#### Scenario: EOF 半行保留 `\r`

- **WHEN** 流在 `data: a\r` 之后结束，没有 `\n`
- **THEN** 返回的事件数据为 `a\r`（与改造前一致，不剥除 `\r`）

#### Scenario: 超长行边界

- **WHEN** 一行长度为 `maxLineBytes` 恰好、另一行长度为 `maxLineBytes + 1`
- **THEN** 前者读取成功，后者抛 `SseLineTooLongException`

#### Scenario: 既有用例不变

- **WHEN** 运行 `SseReader_test.cj` 的既有 8 条用例
- **THEN** 用例源码一字不改且全部通过

### Requirement: 行缓冲的验证与分配基准

本变更 MUST 提供可重复执行的验证：

1. 单元测试 MUST 覆盖短行、长行、跨块、CRLF 跨块、长短交替、`maxLineBytes` 边界、EOF 半行与既有回归；
2. MUST 提供 `F_HTTPCLIENT_SSE_BENCH=1` 门控基准：短行摊销分配（`-O2` 下 `<= 96 B/行`，且优于每行新建集合 2×）、8 KiB 长行与端到端事件（只打印）；
3. 未设置门控时 MUST 打印 `SKIP:`；分配量按 `(alloc + freed)` 中位数；MUST NOT 断言耗时。

#### Scenario: 基准门控关闭

- **WHEN** 未设置 `F_HTTPCLIENT_SSE_BENCH=1` 运行 `cjpm test`
- **THEN** 基准用例输出 `SKIP:`，测试套件不因基准耗时受影响

#### Scenario: 短行分配上界

- **WHEN** 设置 `F_HTTPCLIENT_SSE_BENCH=1`，在 `-O2` 参考构建下对只含注释行的流连续读取 20000 行
- **THEN** 摊销分配 `<= 96 B/行`，且严格小于每行新建集合的对照组的一半；`-O0` 构建只记录不判定

### Requirement: 公开 API 不变

`SseReader` 的公开构造参数、`next()` / `close()` / `isClosed()` 签名与默认值 MUST 保持不变；
`SseEvent`、`SseException` 家族与 `HttpResponse.sseReader(...)` MUST 保持不变；
本变更 MUST NOT 新增公开符号或配置项。

#### Scenario: 契约检查

- **WHEN** 审查 `f_httpclient/src/sse/SseReader.cj` 的 diff
- **THEN** 只出现私有常量、私有字段、私有辅助函数与 `readLine` 函数体的改动，无 `public` 符号变化
