# mcp-truncate-utf8

## Purpose

定义 `f_mcp` 大结果文本截断的可观察契约与内存约束：截断结果按 UTF-8 rune 对齐、字节数不超过 `limit`，且与旧的全量 rune 数组实现逐字节一致；实现只做惰性单遍扫描，额外内存与输出同阶，不与输入文本长度同阶。

## ADDED Requirements

### Requirement: 截断结果与旧实现逐字节一致

`McpServer.truncateUtf8(text, limit)` MUST 保持既有可观察语义：

1. `limit <= 0` 时 MUST 返回空串；
2. `limit >= text.size`（`text.size` 为 UTF-8 字节数）时 MUST 返回与 `text` 内容相同的文本；
3. 其它情况下 MUST 返回 `text` 的按 rune 对齐的前缀，其 UTF-8 字节数 MUST `<= limit`；
4. 对任意合法 UTF-8 输入与任意 `limit`，结果 MUST 与「先把全文展开为 `Array<Rune>`、再逐 rune 累加字节数」的旧实现逐字节一致；
5. 结果 MUST 是合法 UTF-8，MUST NOT 出现半个码点，MUST NOT 抛异常。

#### Scenario: 混合语料边界等价

- **WHEN** 对 ASCII / 2 字节 / 3 字节 / 4 字节 rune 混排的语料，取 `limit = 0, 1, 2, 3, 4, 5, 7, size-1, size, size+1` 与中间值截断
- **THEN** 每个 `limit` 下的结果都与旧的全量 rune 数组算法逐字节相同

#### Scenario: 中文边界

- **WHEN** 文本含中文，`limit` 落在某个 3 字节字符中间
- **THEN** 截断在字符边界结束，响应为合法 UTF-8，`tools/call` 不返回 `-32603`

#### Scenario: 放得下就原样返回

- **WHEN** `limit >= text.size`
- **THEN** 返回文本与入参内容相同，且不产生与文本长度同阶的额外分配

#### Scenario: 非法 limit

- **WHEN** `limit = 0` 或负数
- **THEN** 返回空串

### Requirement: 截断的单遍扫描与内存上界

`truncateUtf8` MUST 满足以下结构性约束：

1. 只做一次从左到右的 rune 扫描，MUST NOT 把 `text` 展开成全量 `Array<Rune>` 或其它与输入等长的副本；
2. 额外内存 MUST 与输出长度同阶（上界为 `limit`），MUST NOT 与输入文本字节数同阶；
3. 扫描 MUST 在第一个放不下的 rune 处停止，MUST NOT 读完剩余文本；
4. 进入扫描前 MUST 已知输出字节上界，缓冲 MUST 按该上界一次预留，MUST NOT 依赖几何扩容；
5. `limit <= 0` 与 `limit >= text.size` 两条快速路径 MUST 不进入扫描（分配为 O(1)）。

#### Scenario: 1 MiB 文本的分配上界

- **WHEN** 对 1 MiB ASCII 文本以 `limit = 256 KiB` 截断
- **THEN** 整次调用的堆分配量 MUST `<= 2 × limit`；同轮对照中旧算法的分配量 MUST 大于新算法的 2 倍

#### Scenario: 中途停止

- **WHEN** 文本前 1 KiB 就能填满 `limit`，其后还有 1 MiB 内容
- **THEN** 结果只含前缀，且不因为尾部内容产生额外分配或额外扫描

#### Scenario: 快速路径不复制

- **WHEN** `limit = text.size`（或更大）
- **THEN** 分配量 MUST `< text.size / 16`，证明未复制全文

#### Scenario: 合法性

- **WHEN** 任意合法 UTF-8 文本与任意 `limit`
- **THEN** 结果的 UTF-8 字节数 `<= max(limit, 0)`，是入参按 rune 对齐的前缀，且能通过 `String.fromUtf8` 往返
