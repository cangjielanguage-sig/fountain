# fmq 队列存储（delta）

## ADDED Requirements

### Requirement: 段末尾位点归一化

任何「起点位置」SHALL 在开流前归一化，MUST NOT 把「位点恰好等于段有效长度」当成段内剩余字节：

- 若 `position.seq` 对应段存在且 `position.offset >= meta.size`，SHALL 视为「该段已读完」，
  起点改为**编号大于 `position.seq` 的最小现存段**的 `0` 偏移；
- 若不存在后继段，SHALL 返回空流 / `None`，并按「队列已排空」处理，MUST NOT 报损坏；
- 归一化 MUST NOT 产生负的剩余字节：`remaining = meta.size - offset - PREFIX_SIZE` 为负时
  SHALL 先归一化而不是进入 `corrupt`；
- 归一化 SHALL 对所有开流路径（记录流 `openRecordsFrom`、`resolveStart` 与 `stats` 的扫描路径）
  一致生效；
- 归一化是「正常读完」而非异常，日志级别为 DEBUG/WARN（仅在偏移严格大于段大小时 WARN），
  MUST NOT 每轮 `consume` 记 ERROR。

消费侧在开流后发现实际起点与请求位置不同时，SHALL 把 `committed` 前移到实际起点并落盘（已有行为），
使下一轮不再重复归一化。

#### Scenario: 段末尾后继续消费

- **WHEN** 段 1 有效长度 64，两条记录被确认后 `committed = (1, 64)`，随后追加一条触发轮转到段 2
- **THEN** 下一次 `next()` 返回段 2 的记录，不报 `corrupt`，`committed` 推进到段 2

#### Scenario: 段封口后排空

- **WHEN** 段 1 已读满且不再写入，段 2 尚不存在
- **THEN** `next()` 返回 `None`（空队列），不记 ERROR

#### Scenario: 重启后新段已有数据

- **WHEN** 重启后段 2 已有记录，`committed` 仍是 `(1, 64)`
- **THEN** 首次消费从段 2 第 1 条开始，无损坏日志

#### Scenario: 统计不再报错

- **WHEN** 在上述状态下调用 `stats`
- **THEN** 返回正确的 backlog（段 2 的记录数），不抛 `INTERNAL`

### Requirement: 记录与段上限的联动约束

单条记录上限 SHALL 与段上限联动，MUST NOT 只校验 64 MiB 常量：

- `effectiveMaxRecord = min(MAX_RECORD_SIZE, maxFileSize - PREFIX_SIZE)`；
- `QueueLog` 构造时若 `maxFileSize <= PREFIX_SIZE` SHALL 抛 `IllegalArgumentException`；
- `append(record)` 在 `record.size == 0` 或 `record.size > effectiveMaxRecord` 时 SHALL 抛
  `IllegalArgumentException`（含实际大小与上限），MUST NOT 先轮转再按整条 `mcopy`；
- `f_io.SegmentedLog.append` SHALL 在写入前做防御性检查：`data.size > maxFileSize` 时抛
  `LogRecordTooLargeException`，MUST NOT 越过 mmap 长度写入；
- `MQConfig.validate` SHALL 拒绝 `segmentedLogMaxSize <= 0`（已有），并 SHALL 在
  `segmentedLogMaxSize <= MAX_RECORD_SIZE + PREFIX_SIZE` 时启动期记 WARN，明确「超过
  `maxFileSize - 4` 的消息会被拒绝」。

`QueueLog.append` 的拒绝 SHALL 发生在任何磁盘写入之前，保证失败不产生半条记录。

#### Scenario: 记录等于上限

- **WHEN** `maxFileSize = 1 MiB`，追加一条 `1 MiB - 4` 字节记录
- **THEN** 成功，独占一个段，读取可完整还原

#### Scenario: 记录超过段上限

- **WHEN** `maxFileSize = 1 MiB`，追加一条 `2 MiB` 记录
- **THEN** 抛 `IllegalArgumentException`，段文件长度不增长，无越界写

#### Scenario: 空记录被拒绝

- **WHEN** `append([])`
- **THEN** 抛 `IllegalArgumentException`，不写入 4 字节零头

#### Scenario: 段容量过小

- **WHEN** 以 `maxFileSize = 4` 构造 `QueueLog`
- **THEN** 构造抛 `IllegalArgumentException`

#### Scenario: 底层防御

- **WHEN** 直接向 `SegmentedLog.append` 传入大于 `maxFileSize` 的数据
- **THEN** 抛 `LogRecordTooLargeException`，进程不崩溃

### Requirement: 队列侧的受支持面

队列包 SHALL 只保留有生产路径或明确测试用途的符号：

- `QueueLog.openFrom` 无生产调用方，SHALL 删除（生产统一走 `openRecordsFrom`）。
- `SegmentMissingException` 若无人抛出/捕获，SHALL 删除；读取端改用「损坏结局 / 空流」表达。
- `scanAfter`、`countAll` 若仅测试使用，SHALL 下沉到测试工具，或让 `stats` 真正复用它们后再保留。
- `MQMetaSnapshot.tombstoneFloor` 若无人读取，SHALL 删除（见 `fmq/metadata-cluster`）。

#### Scenario: 无仅测试使用的生产 API

- **WHEN** 检索队列包中仅被 `_test.cj` 调用的 `protected`/`public` 方法
- **THEN** 结果为空，或该方法已被文档标注为「测试观测 API」并有用例

## MODIFIED Requirements

### Requirement: 追加返回位置且单调

`append(record)` SHALL 返回该记录在段内的起始位置 `(segmentedIndex, segmentedOffset)`，
同一段内偏移严格递增；记录 SHALL NOT 跨段：剩余空间不足时先轮转，再在新段从 `0` 开始完整写入。
`append` SHALL 拒绝空记录与超过 `effectiveMaxRecord` 的记录（见「记录与段上限的联动约束」），
MUST NOT 写入后由读取端解释为结束标记。

#### Scenario: 段内与跨段位置

- **WHEN** 连续追加多条记录，直至发生一次轮转
- **THEN** 段内偏移递增，跨段位置为 `(新段号, 0)`

#### Scenario: 每条记录可立即读回

- **WHEN** 追加后立即按返回位置读取
- **THEN** 读回的字节与写入完全一致

#### Scenario: 空记录不落盘

- **WHEN** 试图追加零长度记录
- **THEN** 抛异常，段有效长度不变

### Requirement: 按位置顺序读取与有界快照

`openRecordsFrom(position)` SHALL 从指定位置开始按写入顺序读出后续记录，跳过段内预分配
空洞；返回的流 SHALL 是创建时刻的段与长度快照，之后新 append 的数据不出现在该流中。
起始位置 SHALL 先经「段末尾位点归一化」处理。起始位置所在段已被删除时：若存在编号更大的段，
SHALL 从最接近的更大段起点继续；若不存在，SHALL 返回空流并记 WARN（同一位置重复不可读 SHALL
限流，每秒最多一条）。调用方 MUST NOT 把「段缺失」解释为「积压为 0」而不留痕。

#### Scenario: 从中间位置读

- **WHEN** 写入 5 条后从第 3 条的位置开流
- **THEN** 依次读出第 3、4、5 条

#### Scenario: 不读预分配区

- **WHEN** 段文件按 `maxFileSize` 预分配，读取到该段最后一条记录
- **THEN** 流结束，不会解出零填充的伪记录

#### Scenario: 快照语义

- **WHEN** 打开流并读尽后再 append 一条
- **THEN** 旧流读不到新记录；用新位置重开后能读到

#### Scenario: 位置已失效

- **WHEN** 起始位置所在的段已被 TTL 清理删除
- **THEN** 不抛 `IllegalArgumentException`：从最接近的更大段继续；若不存在则返回空流并记 WARN

#### Scenario: 起始段落在空洞

- **WHEN** 起点段号为 5，现存段为 1、7、8
- **THEN** 从段 7 起点继续，并记 WARN（含原位置与实际起点）

#### Scenario: 全部段被删除

- **WHEN** 起点段与所有更晚的段都不存在
- **THEN** 返回空流，记 WARN；统计层不得输出 `backlog = 0` 而不报错

#### Scenario: 段末尾不被当作空洞

- **WHEN** 起点为 `(1, 段1有效长度)`，段 1 之后存在段 2
- **THEN** 从段 2 起点继续，日志级别不高于 WARN，不出现「损坏」

#### Scenario: 重复不可读限流

- **WHEN** 同一位置连续 100 轮都因段缺失而不可读
- **THEN** 日志不超过约 100 条/秒的上限（实现按秒限流），消费结果不变

### Requirement: 记录边界格式与文档化

每条队列记录在段内 SHALL 以 `[4 字节大端无符号长度][记录字节]` 存放；长度只表示后续记录字节数，
不包含 4 字节头。读取端 SHALL 以该长度确定单条边界，记录 SHALL NOT 跨段。
读取端 SHALL 在分配缓冲前校验：`1 <= length <= effectiveMaxRecord` 且
`length <= 当前段剩余有效字节`；任一不满足 SHALL 视为损坏，停止读取并记 ERROR（含段号、偏移、
声明长度、剩余字节），MUST NOT 按声明长度分配缓冲。
长度为 0 SHALL 视为**损坏**（不是干净结束）：置 `corrupted = true`、记 ERROR、停止读取；
MUST NOT 静默返回「已读完」。
该格式与上界 SHALL 写入 `design.md` 与模块设计文档，并注明：升级时不得改变前缀宽度或字节序，
否则旧段无法按边界读取。

#### Scenario: 格式写入设计文档

- **WHEN** 查阅本变更 `design.md` 与 `fmq/doc/详细设计.md`
- **THEN** 能找到「4 字节大端长度 + 记录字节」、`effectiveMaxRecord` 的推导与兼容约束

#### Scenario: 长度不含头部

- **WHEN** 写入一条 10 字节记录
- **THEN** 段内占用 14 字节，前 4 字节解码为 10

#### Scenario: 零长度视为损坏

- **WHEN** 段中出现长度为 0 的前缀
- **THEN** 停止读取、`corrupted = true`、记 ERROR；不返回空记录、不把后续字节当成新记录

#### Scenario: 超大声明长度

- **WHEN** 段头声明的长度为 `0xFFFFFFFF`
- **THEN** 读取停止，记 ERROR，进程内存不增长（不分配 4 GiB）

#### Scenario: 超过段剩余

- **WHEN** 声明长度小于上限但大于本段剩余有效字节
- **THEN** 读取停止并记 ERROR，不跨段拼接、不读入下一段

#### Scenario: 跨段不拼接

- **WHEN** 当前段剩余空间不足以容纳「4 字节头 + 记录」
- **THEN** 先轮转，再在新段完整写入

### Requirement: 损坏记录与不可读记录的可观测性

读取链路 SHALL 区分三种结局，MUST NOT 都折成 `None`：

1. 记录可读 → 返回记录与位置；
2. 段不存在（TTL 清理/目录删除）→ 走「段缺失恢复」，可继续消费；
3. 段存在但记录损坏 → 返回「损坏」结局，记 ERROR（含主题、队列、段号、偏移、原因），
   `corrupted = true`。

消费侧遇到「损坏」SHALL NOT 把该位置标记为已决、MUST NOT 推进 `committed`、MUST NOT 计入
「不可读跳过」；本轮返回 `None` 并保持错误可见，等待运维删除/修复该段后由「段缺失恢复」接管。
「不可读跳过」只用于段缺失导致的记录消失。

同一位置的重复不可读 SHALL 限流记录；游标 SHALL 把「记录不可读」「记录损坏」与「正常已决」
用独立计数器/日志标记区分。

#### Scenario: 段被清理导致不可读

- **WHEN** 重投时目标段已被删除
- **THEN** 走段缺失恢复（跳到后继段），记 WARN（含位置），累加不可读计数

#### Scenario: 损坏段停止读取

- **WHEN** 读取中遇到非法长度头（含零长度）
- **THEN** 记 ERROR，本轮返回空，后续消费不崩溃；统计查询返回错误而不是 0

#### Scenario: 损坏不被静默确认

- **WHEN** 段仍在但记录头损坏，组游标扫描到该位置
- **THEN** 该位置不进入已决集合，`committed` 不前进，日志含段号与偏移

#### Scenario: 两种结局不混用

- **WHEN** 同一位置先因段缺失不可读、后因段恢复但内容损坏
- **THEN** 两次的日志与计数器分类不同

### Requirement: 读流恢复语义一致

「起始段缺失」在开流与读中两个阶段 SHALL 采用同一判定：所有段都不存在时视为空队列并返回
`None`（记 WARN）；仍存在其它段时跳到最近的后继段继续；段存在但读取抛错/损坏时 SHALL 继续抛出
或返回损坏结局。同一状态下 MUST NOT 出现「首次打开返回空、读到一半抛异常」的分歧。
「位点段被删除」的唯一权威语义是：**跳到编号更大的最近现存段起点并记 WARN**；
MUST NOT 回退到更老的段（避免重投已确认数据），也 MUST NOT 假装段仍存在继续解析。

#### Scenario: 开流时全段缺失

- **WHEN** 起始段不存在且当前无任何段
- **THEN** 返回 `None`，记 WARN

#### Scenario: 读中全段缺失

- **WHEN** 读到一半段被删除，且当前无任何段
- **THEN** 结束本轮并返回 `None`，不向调用方抛原始异常

#### Scenario: 段仍在但记录损坏

- **WHEN** 段文件存在，记录长度头非法
- **THEN** 返回损坏结局（或抛可识别异常），不得伪装成「段被删除」
