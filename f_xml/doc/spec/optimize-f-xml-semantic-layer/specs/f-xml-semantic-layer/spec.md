# Spec Delta — f-xml-semantic-layer

## Purpose

在不改公开 API、不改事件序列、不改错误语义的前提下，把**语义层**（名字、属性值、文本的
累积与事件构造）从「每个 token 一套新对象」改为「复用缓冲 + 名字驻留 + 块级批量扫描」，
使默认运行时下事件模式 10 MB 事件解析 `min(5) < 1000 ms`、`VmHWM(50 MB) < 256 MB`。

本 delta 新增 `f-xml-semantic-layer` 这个 capability，覆盖四类可观测约束
（驻留、缓冲复用、批量扫描、事件侧复用）、一条门禁（性能与内存）与一条不变量
（语义等价）。字符层的既有契约见 `complete-f-xml-m1-followups/specs/f-xml-char-layer/spec.md`，
本变更不修改它；`LineWindow` 的块视图是 `internal` 增量，不进入公开契约。

## ADDED Requirements

### Requirement: 名字驻留

解析器 SHALL 在扫描名字（元素名、属性名、实体名、PI target）时对**同一字面名**复用同一个
`String` 实例，SHALL NOT 每次命中都重新构造 `String`。

驻留判定 SHALL 由「增量计算的 hash + 码点长度 + **逐 rune 比对**」三者共同决定；
比对 SHALL 是完整的码点序列比对（实现上比较两侧同一编码器产出的 UTF-8 字节序列，
字节相等与码点序列相等互为充要），SHALL NOT 只凭 hash 判定相等。

驻留表 SHALL 同时保存**已切分**的 `prefix` 与 `local`，命中路径 SHALL NOT 再按 `:` 切片
（`text[0..i]` / `text[i+1..]` 每次分配两个 `String`）。

#### Scenario: 重复名字只构造一次 String

- **WHEN** 解析一份含 10 万个 `<item id="1" a="v">` 的文档
- **THEN** 驻留表的 `misses` 等于不同字面名个数（如 3），`hits` 随出现次数增长

#### Scenario: 同 hash 不同名字不误判

- **WHEN** 两个不同名字被构造成相同的 hash（用例直接构造或注入 hash）
- **THEN** 二者分别驻留成两个不同 `String`，解析结果的 `local` 与原文逐字符一致

#### Scenario: 非 ASCII 与组合字符名字

- **WHEN** 文档含 `名字`、`a&#x300;` 形态的组合字符名与 `日本:語` 这类带前缀的名字
- **THEN** 命中的 `String` 与首次插入的逐码点相同；带前缀时 `prefix` / `local` 切分正确

### Requirement: 驻留表有界与计数

驻留表 SHALL 有界：条目数 SHALL 有显式上限，超过上限后 SHALL 停止插入并降级为「不驻留」
（仍然正确，只是不再复用），SHALL NOT 随文档大小无限增长。

驻留表 SHALL 暴露 `internal` 计数（命中 / 未命中 / 插入 / 唯一名字数），供测试做结构性
断言；计数 SHALL NOT 参与任何业务判断，也 SHALL NOT 进入公开 API。

#### Scenario: 驻留表有界

- **WHEN** 文档含超过表上限的不同名字（用例把上限调到极小值）
- **THEN** 解析仍然成功，超限后不再插入，`insertions` 停在上限，内存不随名字数继续增长

### Requirement: 扫描缓冲复用

词法器 SHALL 为名字、属性值、文本各持有**一条**可复用缓冲，在每次扫描开始时清空复用，
SHALL NOT 为每个 token 新建 `StringGenerator`（或等价容器）。

复用缓冲 SHALL 在多次 `nextEvent()` 之间保持同一实例；若底层容器的 `reset()` 不保留容量，
SHALL 使用 `f_xml` 内部自有的字节累积器（倍增、只增不减），SHALL NOT 修改 `f_base`。

`StringGenerator` 仍是文本累积的唯一实现（沿用字符层 spec 的「不用 `StringBuilder`、
不用 `String +` 循环」约束）；复用的只是**实例**，不是 API。

DTD / 注释 / PI 等冷路径若保留每次新建，SHALL 在 `design.md` 的白名单里逐条登记理由。

#### Scenario: 连续 token 不串内容

- **WHEN** 依次解析 `<a x="1">t1</a><b y="2">t2</b>`、再解析一份名字与值交替出现的文档
- **THEN** 每个事件的文本 / 属性值与输入逐字符一致，不出现上一 token 的残留

#### Scenario: token 数量不改变缓冲实例数

- **WHEN** 解析 1 KB 与 10 MB 的同类文档（内部计数断言）
- **THEN** 复用缓冲的实例数恒定（名字 / 值 / 文本各 1），不随 token 数增长

### Requirement: 文本与属性值批量扫描

文本与属性值的扫描 SHALL 在 `LineWindow` 的活动码点块上整段进行：找到下一个停止字符后
一次性读取该段并一次性推进游标，SHALL NOT 在段内逐字符调用 `peekCp` / `advanceCp`。

停止字符集合：

- 文本：`<`（0x3C）、`&`（0x26）、`]`（0x5D，用于 `]]>` 判定）；
- 属性值：当前引号、`&`、`<`，以及 `0x0A` / `0x09` / `0x0D`（要归一成 `0x20`）。

ASCII 段 SHALL 走「码点即字节」直写；遇到非 ASCII 码点、XML 1.0 不允许的控制字符或
块内剩余不足时，SHALL 退回逐字符路径，以保证校验与报错位置逐字符不变。

批量扫描 SHALL NOT 改变：`position()` 序列、错误消息、`line` / `column`、事件拆分边界
（一段文本仍然是**一个** `Text` 事件，不会因为块边界被拆成两个）。

#### Scenario: 长文本走批量路径

- **WHEN** 解析一份文本节点长 1 MB 的文档（内部计数断言）
- **THEN** 该文本段的 `peekCp` 调用次数远小于字符数，且事件数为 1 个 `Text`

#### Scenario: 块边界不拆事件

- **WHEN** 文本长度跨越 `bufSize = 4 / 8 / 16 / 8192` 的块边界
- **THEN** 仍然只产出一个 `Text` 事件，内容与整块读取逐字符一致

#### Scenario: 非法字符的报错位置不变

- **WHEN** 文本或属性值里出现 `0x01` 这类 XML 1.0 不允许的字符
- **THEN** 抛出与改动前**同一句**消息、`line` / `column` 指向该字符自身

#### Scenario: 属性值的空白归一不变

- **WHEN** 属性值跨 3 行、含 `&#10;` 与字面换行
- **THEN** 字面换行 / Tab / CR 变成空格，`&#10;` 保持换行（与改动前一致）

### Requirement: 事件侧临时容器复用

`Lexer` 与 `ParserEngine` 在一次解析内 SHALL 复用属性列表、去重集合等临时容器
（每标签 `clear()` 后重用），SHALL NOT 为每个开始标签新建 `ArrayList` 再丢弃。

`XmlEvent.StartElement` 携带的 `Array<XmlAttribute>` SHALL 是**该事件独有**的数组：
按元素个数一次分配并按索引填充，SHALL NOT 与任何复用容器共享存储。

复用 SHALL NOT 造成跨事件别名：已交付的事件在后续 `nextEvent()` 之后 SHALL 保持完整。

#### Scenario: 已交付事件不被后续事件改写

- **WHEN** 拉模式取到 `<a x="1" y="2"/>` 的 `StartElement`，保存引用后再取下一个事件
- **THEN** 保存的事件仍有 2 个属性，值与名字不变

#### Scenario: 属性数组按长度精确分配

- **WHEN** 解析含 0 / 1 / 5 个属性的元素（内部计数断言）
- **THEN** 交付数组的长度分别为 0 / 1 / 5，且没有多于元素个数的扩容痕迹

### Requirement: 性能与内存门禁（默认运行时）

在**不设置任何 GC 环境变量**（`cjHeapSize` / `cjGCInterval` / `cjRegionSize` 等均不存在）
的默认运行时下，事件模式解析 SHALL 满足：

1. 10 MB 合成文档（`bufSize = 8192`、`-O2`）`min(5 次) < 1000 ms`；
2. 50 MB 合成文档的进程峰值 `VmHWM < 256 MB`；
3. 同轮同机对照：`new_min(10 MB) ≤ 0.95 × old_min(10 MB)`。

测量 SHALL 满足：每次测量独立进程、机器空载（1 分钟负载 ≤ `0.5 × nproc`）、
同一份**不产生额外分配**的合成流基准、10 MB 与 50 MB 分进程。
一轮内 `max/min > 1.4` SHALL 判为负载污染并重测，SHALL NOT 用于判定。

#### Scenario: 10 MB 时间门禁

- **WHEN** 空载机上跑 `F_XML_PERF=1 cjpm test --filter=PerfTen_test`
- **THEN** 输出 `min < 1000`，且 5 个单次值都打印出来

#### Scenario: 50 MB 内存门禁

- **WHEN** 空载机上跑 `F_XML_PERF=1 cjpm test --filter=PerfFifty_test`（进程内只解析 50 MB）
- **THEN** `VmHWM < 262144 kB`，且与改前同轮值一起打印

#### Scenario: 环境干净

- **WHEN** 跑门禁用例前执行 `env | grep -iE '^cj(Heap|GC|Region|Large|Exemption|Allocation|Garbage|Backup|Processor|Stack)'`
- **THEN** 输出为空；用例自身 SHALL 打印该检查结果，非空时 SHALL 判门禁无效

### Requirement: 语义等价与回归护栏

本变更 SHALL 保持下列不变：

1. 公开类型、方法签名、参数名、默认值零变更；新增成员全部 `internal`；
2. 事件序列（类型、顺序、文本内容）逐字节不变，推模式 / 拉模式 / 单回调三种前端一致；
3. 错误消息文本、`line` / `column`、`entityLimitKind` 不变；
4. `InvalidByteMode.Strict` / `Replace` 两条路径的逐字符输出不变；
5. xmlconf Gate A `2038 / 0 / 524` 与五条排除规则 `313 / 95 / 59 / 47 / 10` 不变；
6. 现有 337 条仓颉用例与 4 条 Python 用例全过，一条不删、期望不改。

#### Scenario: 三种前端事件日志一致

- **WHEN** 用 `XmlPullParser`、`XmlParser.parse(eventHandler)`、单回调接口分别解析同一批文档
- **THEN** 三份事件日志逐行 `diff` 为空

#### Scenario: 公开声明零变更

- **WHEN** 对比改动前后 `grep -rn '^public ' f_xml/src`（排除 `public class *_test`）
- **THEN** 差集为空

#### Scenario: 错误位置逐条不变

- **WHEN** 跑 `ParserError_test` / `InvalidByteMode_test` / `EntitySecurity_test`
- **THEN** 全部通过，错误消息与行列号与改动前相同
