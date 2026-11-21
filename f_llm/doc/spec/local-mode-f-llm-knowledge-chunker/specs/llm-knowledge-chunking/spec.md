# llm-knowledge-chunking

## ADDED Requirements

### Requirement: 知识切块按字符滑窗

`KnowledgeChunker.split` SHALL 以 Unicode 字符（rune）为单位计算窗口与重叠，MUST NOT 在字符内部切断；中文等多字节文档切块 MUST NOT 抛异常。`maxChars` MUST 大于 0，`overlap` MUST 落在 `[0, maxChars)`，非法参数 MUST 抛 `IllegalArgumentException`；空内容 MUST 返回空列表。

#### Scenario: 中文长文档按字符切块

- **WHEN** 1000 个汉字的知识文档以 `maxChars=400`、`overlap=50` 切块
- **THEN** 返回多个 chunk，首块为前 400 个汉字，且不抛异常

#### Scenario: 非法参数被拒绝

- **WHEN** `maxChars=0` 或 `overlap=maxChars`
- **THEN** 抛 `IllegalArgumentException`，不返回任何 chunk

### Requirement: 全文 rune 缓冲按内容字节门限分档

`KnowledgeChunker.split` SHALL 按内容 UTF-8 字节数选择全文 `ArrayList<Rune>` 的分配方式：

- 当 `content.size` 大于 0 且不超过 **2 MiB**（2,097,152 字节）时，rune 缓冲 SHALL 使用 local 分配（`@ local!`），在当前函数返回时随 local region 整体释放；
- 当 `content.size` 超过 2 MiB 时，rune 缓冲 SHALL 使用普通堆分配，不得进入 local 分配；
- 内容为空时 MUST 保持早退，不构造 rune 缓冲并返回空列表。

2 MiB 门限由 **8 MiB local 预算 ÷ 4 字节/Rune** 推导，对应最坏情况 ASCII（1 rune/字节）的 8 MiB 原始元素占用。门限判定 MUST 只读 `content.size`，MUST NOT 先展开 rune 或做可能溢出的乘法。

门限常量、字节级 predicate 与判定结果 SHALL 可被同包测试直接查询，不得依赖构造整篇大文档来观察。

#### Scenario: 门限以下走 local

- **WHEN** 内容为 1 MiB ASCII
- **THEN** rune 缓冲使用 local 分配，且切块结果与堆分配逐元素一致

#### Scenario: 恰好等于门限

- **WHEN** 内容为 2 MiB ASCII（rune 缓冲原始占用约 8 MiB）
- **THEN** rune 缓冲使用 local 分配

#### Scenario: 超过门限走堆

- **WHEN** 内容为 2 MiB + 1 字节 ASCII
- **THEN** rune 缓冲使用普通堆分配，不占用 local region

#### Scenario: 多字节内容按字节门限

- **WHEN** 内容为 699,050 个汉字（2,097,150 字节，门限内）或 699,051 个汉字（2,097,153 字节，2 MiB + 1）
- **THEN** 前者走 local，后者走堆；两者输出均正确

#### Scenario: 空内容

- **WHEN** `content` 为空字符串
- **THEN** 返回空列表，不构造 rune 缓冲，门限 predicate 返回 false

### Requirement: 分档不改变切块输出与公开 API

local / 堆分档 SHALL 只影响 rune 缓冲的分配位置，不得改变任何可观察输出：同一内容、同一 `maxChars` / `overlap` 下，两条路径返回的 `ArrayList<String>` MUST 长度相同且逐元素相等。

`KnowledgeChunker.split(content, maxChars!, overlap!)` 的公开签名、默认值、异常语义与返回类型 MUST 保持不变；`chunks`、`StringBuilder` 与 chunk `String` MUST 保持普通堆分配，不得进入 local region。

#### Scenario: ASCII 等价

- **WHEN** 同一 ASCII 内容分别以 `splitImpl(..., true)` 与 `splitImpl(..., false)` 切块
- **THEN** 两个列表长度相同且每个 chunk 相等

#### Scenario: 中文与 emoji 等价

- **WHEN** 中文、emoji 与混合内容分别以两种档位切块
- **THEN** 对应 chunk 逐元素相等，不出现半个字符

#### Scenario: 窗口与重叠矩阵等价

- **WHEN** `maxChars` 取 1 / 2 / 4 / 400、`overlap` 取 0 / 1 / 50（合法组合）时分别跑两档
- **THEN** 每组的 local / 堆输出逐元素相等

#### Scenario: 公开 API 回归

- **WHEN** 调用公开 `KnowledgeChunker.split` 并运行既有 `KnowledgeChunkerTest`
- **THEN** 签名与默认值不变，既有 5 条切块用例与知识检索用例全部通过

#### Scenario: 返回容器保持堆分配（基准手工验证）

- **WHEN** 在基准进程内对门限以下的输入调用 `split`，并同时记录 `getAllocatedLocalObjectSize()` 与 `getAllocatedHeapSize()`
- **THEN** local 峰值只反映 rune 缓冲（约 8 MiB），`chunks` 与 `StringBuilder` 的堆增量单独计入；该场景由 `f_llm/doc/perf-baseline.md` 记录，不作 CI 断言
