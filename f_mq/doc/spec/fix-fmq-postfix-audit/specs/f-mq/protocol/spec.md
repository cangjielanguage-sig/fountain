# f-mq/protocol（delta）

## ADDED Requirements

### Requirement: 载荷读取的类型闸门与转换严格性

`MQProtocol.asPayload<T>(message)` SHALL 与 `MQProtocol.decodePayload<T>(...)` 使用同一套类型闸门与
转换标志，二者对外语义 MUST 对称：

1. 先按运行时类型精确匹配：`message.data` 为自描述对象时，其 `typeInfo.qualifiedName` SHALL 等于
   `TypeInfo.of<T>().qualifiedName`；`T` 为标量或字符串时，`data` MUST NOT 是自描述对象，
   且转换结果 SHALL 与 `T` 的类型一致。任一不满足 SHALL 返回 `None<T>`。
2. 类型闸门通过后，**对象目标** SHALL 用严格标志（字面量 `0`：不夹带任何 `IGNORE_*` 位）解码，
   MUST NOT 使用 `SILENCE`；字段缺失、字段改名或字段类型漂移 SHALL 返回 `None<T>`，
   MUST NOT 产出「字段全默认」的对象。**标量目标**沿用 `DEFAULT_DATA_FLAG`，只做同类数值宽度转换
   （`f_data` 中 `DEFAULT_DATA_FLAG == SILENCE`，跨类兜底已在第 1 条闸门挡掉，因此不构成宽松解析）。
3. 整个读取过程 MUST NOT 抛异常；损坏字节、空载荷与类型不符统一返回 `None<T>`。
4. `T` 为标量或字符串时，只有对应的 `Data` 子类型才算匹配：`asPayload<String>(DataString("x"))`
   SHALL 返回 `Some("x")`，MUST NOT 恒返回 `None`；跨类型数值兜底（如 `DataInt` → `String`）
   MUST NOT 发生。

`asInternal`、`asResult`、`asConsumeResult` 等派生访问器 SHALL 复用同一实现，不得各自维护类型判断。

#### Scenario: 字符串与标量命中

- **WHEN** `message.data` 为 `DataString("x")`、`DataInt(7)`、`DataBool(true)`
- **THEN** `asPayload<String>`、`asPayload<Int64>`、`asPayload<Bool>` 分别返回对应的 `Some` 值

#### Scenario: 标量不匹配对象

- **WHEN** 对标量载荷调用 `asPayload<MQResult>`
- **THEN** 返回 `None<MQResult>`，不构造默认对象

#### Scenario: 对象不匹配标量

- **WHEN** 对 `MQResult` 对象载荷调用 `asPayload<String>`
- **THEN** 返回 `None<String>`

#### Scenario: 字段漂移严格失败

- **WHEN** 载荷是旧版本对象（少一个字段）或字段类型已改变
- **THEN** `asPayload<T>` 返回 `None<T>`，且不返回任何「字段取默认值」的实例

#### Scenario: 与 decodePayload 对称

- **WHEN** 同一段字节分别经 `asPayload<T>`（包装为 `Message`）与 `decodePayload<T>` 读取
- **THEN** 两者同时为 `Some` 或同时为 `None`，值相等

### Requirement: 组名、标签与主题的字符集约束

订阅组名、tags 元素与主题路径的字符校验 SHALL 按 Unicode 标量值判定，MUST NOT 只按 UTF-8 字节
比较 `<= 0x20`。至少 SHALL 拒绝：

- C0 控制字符 `U+0000`–`U+001F` 与 `U+007F`（DEL）；
- 全部 Unicode 空白，含 `U+0020`、`U+00A0`、`U+1680`、`U+2000`–`U+200A`、`U+2028`、`U+2029`、
  `U+202F`、`U+205F`、`U+3000`；
- 组名与标签的保留分隔符：`/`、`\`、`:`、`%`；组名 MUST NOT 以 `.` 开头或结尾。

超长判定 SHALL 以 UTF-8 编码后的字节数为准：组名 ≤ 255 字节，单条 tag ≤ 128 字节且数量 ≤ 64。
校验失败 SHALL 返回「非法」判定，由调用方转成 `MQException`，MUST NOT 只截断或静默放行。

#### Scenario: DEL 与 Unicode 空白被拒绝

- **WHEN** 组名为 `"g\u{7F}"`、`"g\u{00A0}"`、`"g\u{3000}"`
- **THEN** 三者均判为非法

#### Scenario: 合法非 ASCII 组名

- **WHEN** 组名为 `"订单组"`（无空白、无保留符号、≤ 255 字节）
- **THEN** 判为合法

#### Scenario: 标签边界

- **WHEN** 标签为 64 个、每个 128 字节且不含空白/控制字符
- **THEN** 判为合法；第 65 个或第 129 字节起判为非法

### Requirement: 协议工厂重载的行为覆盖

`MQProtocol` 中每个 `metaSync(...)` 重载（`MQMetaSyncRequest`、`MQTopicAssignment`、
`MQSubscribeGroupMeta`、`MQMetaTombstone`、`MQDeregisterPayload`）SHALL 保持固定契约：
命令与语义一致（`MQDeregisterPayload` 为 `DEREGISTER`，其余为 `REGISTER`），子载荷类型与入参一致。
每个重载 SHALL 至少有一个行为用例，断言命令、子载荷可解码类型与关键字段；
`factoriesUseExpectedCommands` 类的汇总用例 MUST NOT 作为唯一保护。

#### Scenario: 注销载荷重载

- **WHEN** 调用 `metaSync(MQDeregisterPayload(TOPIC, "/t"))`
- **THEN** 命令为 `DEREGISTER`，内部 `kind` 为 `metaSync`，子载荷可解出 `MQDeregisterPayload`
  且 `kind`、`topic` 与入参一致

#### Scenario: 五个重载各自可解码

- **WHEN** 依次构造五个重载并解码
- **THEN** 五个子载荷类型互不串台；任一重载把子载荷类型写错时对应用例失败

### Requirement: 协议类型的受支持面

协议包 SHALL 只暴露有生产消费者或明确测试用途的符号。
`MQDeregisterPayload.isGroup` 这类无调用方、且可由 `kind` 判定的辅助方法 SHALL 删除；
只写不读的状态访问器 SHALL 删除（服务端部分见 `fmq/server-runtime`）。
删除后 SHALL 保留等价且可读的显式判定（`kind == ...GROUP`）。
协议字段 MUST NOT 只被序列化而从不被任何合并/清理逻辑读取。

#### Scenario: 无只写字段

- **WHEN** 检索协议载荷类的字段读取点
- **THEN** 每个字段至少有一个生产读取方，或已从类中删除

#### Scenario: 删除不改变线格式语义

- **WHEN** 删除 `isGroup` 等纯辅助方法
- **THEN** `MQDeregisterPayload` 的编解码字节与删除前一致

## MODIFIED Requirements

### Requirement: 载荷按运行时类型分派

`MQProtocol` SHALL 按 `message.data` 的运行时类型给出载荷分类，至少区分：
`TopicMeta`、`GroupMeta`、`Internal`、`Record`、`Empty`、`Unknown`。
内部消息 `MQInternalMessage` 的 `kind` SHALL 只有三种：`metaSync`、`backup`、`stats`
（`MQInternalKind` 三个常量），每种对应固定子载荷类型。
规格 MUST NOT 保留「两种 kind」表述；旧场景「内部消息的两种 kind」已删除。

#### Scenario: 六类载荷分类正确

- **WHEN** 分别传入主题分配、订阅组、内部消息、记录字节、空载荷与任意其它对象
- **THEN** 分类结果依次为 `TopicMeta`、`GroupMeta`、`Internal`、`Record`、`Empty`、`Unknown`

#### Scenario: 内部消息的三种 kind

- **WHEN** 构造 `MQInternalMessage` 并分别使用 `metaSync`、`backup`、`stats` 三种 kind
- **THEN** `asInternal` 成功，子载荷可分别解出快照/墓碑、备份载荷与统计请求；未知 kind 归为 `Unknown`

#### Scenario: 不存在第四种 kind

- **WHEN** 检索 `MQInternalKind` 与协议规格
- **THEN** 只有三个常量、只有一组 kind 场景，且各自子载荷类型唯一

#### Scenario: 标量载荷不变成默认对象

- **WHEN** 用 `asPayload<T>` 读取与 `T` 不匹配的标量载荷
- **THEN** 返回 `None`，不返回默认值对象

#### Scenario: 类型不匹配时不产出半成品

- **WHEN** 载荷对象缺少 `T` 的字段或字段类型不同
- **THEN** `asPayload<T>` 返回 `None`，调用方不得拿到部分填充的实例

### Requirement: 订阅组名校验

订阅组名 SHALL 非空、UTF-8 编码 ≤ 255 字节、不含 `/`、`\`、`:`、`%`，不以 `.` 开头或结尾，
且不含任何控制字符与 Unicode 空白（判定规则见「组名、标签与主题的字符集约束」）。
默认组（空串）SHALL 继续被允许。
校验失败的组名 SHALL 由协议层返回「非法」，客户端与服务端 SHALL 转成 `MQException`/
`INVALID_GROUP`，MUST NOT 落盘。

#### Scenario: 合法组名

- **WHEN** 组名为 `g1`、`order.created`、`订单组`
- **THEN** 判为合法

#### Scenario: 非法组名

- **WHEN** 组名含 `/`、`\`、`:`、`%`、`U+007F`、`U+3000`，或以 `.` 开头/结尾，或超过 255 字节
- **THEN** 均判为非法

#### Scenario: 默认组不受影响

- **WHEN** 组名为空串
- **THEN** 判为默认组合法

### Requirement: 主题延迟字段

`MQTopicMeta` 与 `MQTopicAssignment` SHALL 以具名参数 `delayingMs: Int64` 暴露延迟，
SHALL NOT 把延迟作为位置参数。规格中的构造示例 SHALL 可直接编译，参数名、顺序与类型与源码一致。
延迟 SHALL 参与编解码往返，负值 SHALL 在构造/校验阶段被拒绝。

#### Scenario: 元数据往返

- **WHEN** `MQTopicMeta("/t", 2, delayingMs: 61000)` 编码后解码
- **THEN** `delayingMs == 61000`

#### Scenario: 分配往返

- **WHEN** `MQTopicAssignment("/t", 2, 0, [0, 1], delayingMs: 61000)` 编码后解码
- **THEN** `delayingMs == 61000`，owners 与 queueNum 不变

#### Scenario: 示例照抄可编译

- **WHEN** 把规格中的两个构造示例原样放进用例
- **THEN** 编译通过并得到上文结果

### Requirement: messageId 发布时间解析

`MQMessageRecord.publishTime` SHALL 把 messageId 中的 23 位时间戳解释为 **UTC 绝对时刻**，
与进程本地时区无关；同一 messageId 在任意时区进程中 SHALL 得到同一时刻。
规格与用例 SHALL 用绝对时刻断言（例如 `2026-10-18T18:30:00.123456789Z`），
MUST NOT 用「格式化回同一时区后等于原串」这类恒真断言。
无法解析或位数不足时 SHALL 返回 `None`（消费侧按已到期处理）。
发布时间超前当前时刻 5 分钟以上 SHALL 由消费侧按「已到期」处理（见 `fmq/consume-semantics`）。

#### Scenario: 标准 ID

- **WHEN** 解析 `20261018183000123456789` 这类 messageId
- **THEN** 得到的时刻为 `2026-10-18T18:30:00.123456789Z`

#### Scenario: 本地时区进程生成的 ID 仍是 UTC

- **WHEN** 在 `TZ=Asia/Shanghai` 的进程中构造 messageId 并解析
- **THEN** 解析结果与 UTC 进程一致，不出现 8 小时偏移

#### Scenario: 非标准 ID

- **WHEN** messageId 不足 23 位或前缀不是数字
- **THEN** 返回 `None`

#### Scenario: 未来时间戳

- **WHEN** messageId 的时间比当前时刻晚 10 分钟
- **THEN** 解析结果仍是该绝对时刻（是否立即投递由消费侧规则决定）
