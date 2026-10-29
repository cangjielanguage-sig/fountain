# Spec Delta — f-xml-dtd-entities

## ADDED Requirements

### Requirement: 内部子集实体声明

内部子集 `<!DOCTYPE name [ … ]>` 的实体声明 SHALL 按下表处理：

| 语法 | 行为 |
|---|---|
| `<!ENTITY name "值">` / `'值'` | 支持；值里的引用**延迟到使用时展开**，声明时只存原文 |
| `<!ENTITY % name "值">` | 支持，只能在 DTD 内部以 `%name;` 使用 |
| `<!ENTITY name SYSTEM "uri">` | 声明可识别，**引用即报错**，SHALL NOT 读文件 |
| `<!ENTITY % name SYSTEM "uri">` | 同上 |
| 同一实体重复声明 | 第一个生效，不报错 |

#### Scenario: 普通实体展开

- **WHEN** `<!DOCTYPE a [<!ENTITY e "v">]><a>&e;</a>`
- **THEN** 文本为 `v`

#### Scenario: 实体值嵌套引用

- **WHEN** `<!ENTITY a "x"><!ENTITY b "&a;y">`，正文 `&b;`
- **THEN** 文本为 `xy`

#### Scenario: 前向引用在使用时已声明则成功

- **WHEN** `<!ENTITY b "&a;y"><!ENTITY a "x">`，正文 `&b;`
- **THEN** 文本为 `xy`（声明 `b` 时不解析 `&a;`，等 `&b;` 被使用时 `a` 已声明）

#### Scenario: 使用时仍未声明才报错

- **WHEN** `<!ENTITY b "&a;y">`，正文 `&b;`，且全文没有声明 `a`
- **THEN** 抛 `XmlException`（WFC: Entity Declared），消息含实体名 `a` 与行列号

#### Scenario: 外部实体引用即报错且不开文件

- **WHEN** `<!ENTITY x SYSTEM "file:///etc/passwd">`，正文 `&x;`
- **THEN** 抛 `XmlException`；SHALL NOT 打开该文件

#### Scenario: 首个声明生效

- **WHEN** 同一实体声明两次（值不同）
- **THEN** 使用第一个值，不报错

### Requirement: DTD 声明语法良构校验

内部子集的 `<!ENTITY>` / `<!ELEMENT>` / `<!ATTLIST>` / `<!NOTATION>` SHALL 解析并校验**声明
语法**（良构性，WFC）；非法声明 SHALL 抛 `XmlException`，消息含声明类型与行列号。逐条语法
矩阵见 `design.md` §6.7。SHALL NOT 校验有效性（VC）、SHALL NOT 注入默认属性值；`TYPE="invalid"`
仍 SHALL 解析成功。

#### Scenario: 四类合法声明全部通过

- **WHEN** 内部子集含 `<!ELEMENT a (b|c)*>`、`<!ATTLIST a x (p|q) #FIXED "p" y ID #IMPLIED>`、
  `<!NOTATION n PUBLIC "pub-id">`、`<!ENTITY e "v">`
- **THEN** 解析成功

#### Scenario: 声明内含 `>` 与引号不提前结束

- **WHEN** 内部子集含 `<!ELEMENT a (b*)>`、`<!ATTLIST a x CDATA "1>2">`
- **THEN** 不报错，且内部的 `>` 与引号不导致声明提前结束

#### Scenario: 非法内容模型报错

- **WHEN** 内部子集含 `<!ELEMENT a ((b) ?)>`
- **THEN** 抛 `XmlException`，消息含 `ELEMENT` 与行列号

#### Scenario: 非法属性类型报错

- **WHEN** 内部子集含 `<!ATTLIST a x NUTOKEN #IMPLIED>`
- **THEN** 抛 `XmlException`，消息含 `ATTLIST` 与 `NUTOKEN`

#### Scenario: NOTATION 缺外部标识符报错

- **WHEN** 内部子集含 `<!NOTATION n>`
- **THEN** 抛 `XmlException`，消息含 `NOTATION`

### Requirement: 内部子集拒绝条件段

XML 1.0 §3.4 的 `intSubset` 产生式不含 `conditionalSect`，因此内部子集里出现
`<![INCLUDE[ … ]]>` 或 `<![IGNORE[ … ]]>` SHALL 抛 `XmlException`，消息含「条件段只能出现在
外部子集」与行列号。SHALL NOT 提供「按标志位选分支」的路径；外部子集永不加载，M1 没有合法
入口能到达条件段。

#### Scenario: 内部子集条件段报错

- **WHEN** 内部子集含 `<![INCLUDE[ <!ENTITY e "v"> ]]>`
- **THEN** 抛 `XmlException`，消息含「条件段」与行列号

#### Scenario: 内部子集的 INCLUDE 条件段报错

- **WHEN** `<!DOCTYPE a [<![INCLUDE[<!ENTITY e "x">]]>]><a>&e;</a>`
- **THEN** 抛 `XmlException`，消息含「条件段只能出现在外部子集」与行列号

#### Scenario: 内部子集的 IGNORE 条件段报错

- **WHEN** `<!DOCTYPE a [<!ENTITY e "x"><![IGNORE[<!ELEMENT a ((b) ?)>]]>]><a>&e;</a>`
- **THEN** 抛 `XmlException`（不因「在 IGNORE 里」而放行），消息含条件段与行列号

### Requirement: 外部子集不加载

外部子集（`SYSTEM` / `PUBLIC` 指向的 `.dtd`）SHALL NOT 加载，SHALL NOT 发起任何网络请求。

#### Scenario: 外部子集不发请求

- **WHEN** `<!DOCTYPE a SYSTEM "http://127.0.0.1:1/x.dtd"><a/>`
- **THEN** 解析成功（外部子集不加载），且没有建立任何连接

### Requirement: 展开位置

实体引用 SHALL 按下表决定是否展开；不展开的位置 SHALL 保留字面量 `&name;`：

| 位置 | 是否展开 |
|---|---|
| 元素内容 | 展开（递归） |
| 属性值 | 展开 |
| CDATA | 不展开（`&name;` 是字面量） |
| 注释 / PI | 不展开 |
| 实体值内部 | 使用时展开（声明时只存原文）；此时仍未声明才报错 |

#### Scenario: CDATA 内不展开

- **WHEN** `<!ENTITY e "v">`，正文 `<a><![CDATA[&e;]]></a>`
- **THEN** 文本为 `&e;`

#### Scenario: 注释内不展开

- **WHEN** 正文 `<!-- &e; -->`
- **THEN** 注释内容为 ` &e; `

### Requirement: 单实体替换文本良构

内部一般实体的替换文本 SHALL 匹配 XML 1.0 的 `content` 产生式（WFC: Parsed Entity）。
展开内部实体时 SHALL 校验其标签**在实体内部配平**：

- 实体里开始的元素 SHALL 在实体内部结束，SHALL NOT 把开始标签留在实体外去配对；
- SHALL NOT 出现孤立的结束标签（实体里多一个 `</x>`、或关掉实体外的元素）；
- SHALL NOT 借实体把同一个元素拆成「实体里开、实体外关」或反向。

违规 SHALL 抛 `XmlException`，消息 SHALL 含**实体名**与展开点的行列号。这条校验与 DTD 内容模型
无关——不需要任何 `<!ELEMENT>` 声明，`<!ENTITY e "<b>">` 配 `<a>&e;</a>` 就已经不良构。
属性值位置使用实体时，替换文本 SHALL NOT 含 `<`（既有规则，与本条并列）。

#### Scenario: 实体里的开始标签未闭合

- **WHEN** `<!DOCTYPE a [<!ENTITY e "<b>">]><a>&e;</a>`
- **THEN** 抛 `XmlException`，消息含实体名 `e` 与行列号

#### Scenario: 实体里的孤立结束标签

- **WHEN** `<!DOCTYPE a [<!ENTITY e "</a>">]><a>&e;</a>`
- **THEN** 抛 `XmlException`，消息含实体名 `e`

#### Scenario: 实体内部配平的标签合法

- **WHEN** `<!DOCTYPE a [<!ENTITY e "<b>x</b>">]><a>&e;</a>`
- **THEN** 解析成功，`a` 下有一个 `b` 子元素，文本为 `x`

#### Scenario: 属性值位置的替换文本含小于号

- **WHEN** `<!DOCTYPE a [<!ENTITY e "<b>">]><a x="&e;"/>`
- **THEN** 抛 `XmlException`，消息含属性名 `x` 与实体名 `e`

#### Scenario: 参数实体不受此约束

- **WHEN** `<!DOCTYPE a [<!ENTITY % p "<!ENTITY e 'v'>">%p;]><a>&e;</a>`
- **THEN** 解析成功，文本为 `v`（参数实体的替换文本是 DTD 片段，不是内容）

### Requirement: 属性值规范化

属性值 SHALL 按 XML 1.0 §3.3.3 的顺序处理：

1. 字符引用与实体引用展开（递归）；
2. 空白字符归一：`#x9` / `#xA` / `#xD` 一律变 `#x20`；
3. **仅当属性类型不是 `CDATA` 时**，再去首尾空格并把内部连续空格折叠成单个 `#x20`。

SHALL NOT 先归一化再展开。解析 `<!ATTLIST>` 时 SHALL 建立「元素名 → 属性名 → `AttType`」映射
（同名重复声明取第一个），SHALL 按**元素的字面名**（`prefix:local` 原文）匹配，SHALL NOT 按展开名
匹配（DTD 不认识命名空间）。未在 `<!ATTLIST>` 中声明的属性 SHALL 按 `CDATA` 处理。

该映射 SHALL 只服务规范化，SHALL NOT 支撑有效性校验：不检查 `ID` 唯一性、不检查 `IDREF`
指向、不检查枚举取值、不注入默认值 / `#FIXED` 值。

#### Scenario: 实体值里的换行被归一

- **WHEN** `<!ENTITY e "a&#10;b">`，属性 `x="&e;"`
- **THEN** 属性值为 `a b`（换行变成空格），不是 `a\nb`

#### Scenario: 未声明类型的属性保留首尾空格

- **WHEN** `<a x=" v "/>`（无 `<!ATTLIST>` 声明，按 `CDATA`）
- **THEN** 属性值为 `" v "`

#### Scenario: 非 CDATA 类型去首尾并折叠空白

- **WHEN** `<!DOCTYPE a [<!ATTLIST a x NMTOKENS #IMPLIED>]><a x="  p   q  "/>`
- **THEN** 属性值为 `"p q"`（去首尾 + 内部连续空格折叠为一个）

#### Scenario: 声明为 CDATA 时不折叠

- **WHEN** `<!DOCTYPE a [<!ATTLIST a x CDATA #IMPLIED>]><a x="  p   q  "/>`
- **THEN** 属性值为 `"  p   q  "`（只做空白归一，不做首尾与折叠）

#### Scenario: 规范化顺序（展开先于折叠）

- **WHEN** `<!DOCTYPE a [<!ATTLIST a x NMTOKENS #IMPLIED><!ENTITY e "&#10;p&#10;">]><a x="q&e;"/>`
- **THEN** 先展开成 `q\np\n`、再把换行归一成空格、最后折叠，属性值为 `"q p"`；
  不是 `"q\np"` 也不是 `"q\n\np"`

#### Scenario: 映射按字面名匹配

- **WHEN** `<!DOCTYPE p:a [<!ATTLIST p:a x NMTOKENS #IMPLIED>]><p:a xmlns:p="u" x="  p   q  "/>`
- **THEN** 属性值为 `"p q"`（`p:a` 与声明里的字面名一致即命中，不因命名空间展开而错过）

### Requirement: 三层上限

`EntityLimits` SHALL 提供：

| 字段 | 默认 | 性质 | 超限行为（`Spill`） |
|---|---|---|---|
| `maxExpandedPerEntity` | 64 KB | 软 | 该实体展开结果转写临时文件，此后按流提供 |
| `maxExpandedTotal` | 8 MB | 软 | 整个文档转溢出模式，后续展开都走文件 |
| `maxDepth` | 16 | **硬** | 抛 `XmlException` |
| `maxDeclarations` | 1024 | **硬** | 抛 `XmlException` |
| `maxExpandedHardLimit` | 2 GB | **硬** | 抛 `XmlException` |

#### Scenario: 深度超限立即失败

- **WHEN** 实体递归 17 层，`maxDepth = 16`
- **THEN** 抛 `XmlException`，`entityLimitKind = Some(Depth)`，消息含实体名与深度

#### Scenario: 深度刚好 16 通过

- **WHEN** 实体递归正好 16 层
- **THEN** 解析成功

#### Scenario: 声明数超限

- **WHEN** 内部子集声明 1025 个实体
- **THEN** 抛 `XmlException`，`entityLimitKind = Some(Declarations)`

### Requirement: 实体计数语义

计数 SHALL 挂在「往输出追加字符」的时刻，SHALL NOT 先把展开结果拼成完整字符串再量长度。
`maxExpandedTotal` SHALL 只统计**由实体展开产生的字符**，原文本身不计。

#### Scenario: 原文不计入总量

- **WHEN** 一份 20 MB、无任何实体引用的文档
- **THEN** 不触发 `maxExpandedTotal`（8 MB）

#### Scenario: 边展开边计数

- **WHEN** 构造 10 层 × 10 倍的膨胀实体，`maxExpandedTotal = 1 MB`、`Strict`
- **THEN** 在内存占用远小于完整展开量之前就抛错（断言抛错时 `totalExpanded < 2 MB`）

### Requirement: 溢出策略

`EntityOverflowPolicy` SHALL 有两个值，SHALL 声明 `<: Equatable` 并**显式实现**
`operator func ==`（仓颉 enum 不自动派生）：

- `Spill`（默认）：软阈值超限转溢出模式继续解析，内存恒定。
- `Strict`：软阈值超限直接抛 `XmlException`。

切换到 `FileSink` SHALL 是**单向、不回头**；一旦切换，本实体及后续所有实体都直接写文件。

溢出文件 SHALL 恒为 UTF-8（存的是已解码字符的 UTF-8 编码），读回 SHALL 按 `bufSize` 分块，
块尾不完整字节按 UTF-8 前导字节回退。溢出对下游 SHALL 完全透明：`onText` 仍看到连续文本
（允许分块）。

#### Scenario: Spill 下大展开成功

- **WHEN** 构造展开量 20 MB 的合法文档，`overflowPolicy = Spill`
- **THEN** 解析成功，文本内容与 `Strict` 下小样本路径逐字节一致

#### Scenario: 溢出后内存不随展开量增长

- **WHEN** 同上，断言展开器 `retainedBytes`（内存侧保留字节）
- **THEN** `retainedBytes` 不超过 `maxExpandedTotal` 的量级，且与总展开量无关

#### Scenario: Strict 下软阈值直接抛

- **WHEN** 单实体展开 65 KB，`overflowPolicy = Strict`
- **THEN** 抛 `XmlException`，`entityLimitKind = Some(PerEntity)`

#### Scenario: 溢出文件用完即删

- **WHEN** 溢出路径执行完毕后检查临时目录
- **THEN** 本次创建的文件已被删除

### Requirement: 属性值不支持溢出

属性值中的实体展开超过 `maxExpandedPerEntity` 时 SHALL 抛 `XmlException`，
`entityLimitKind = Some(AttributeValue)`，**即使** `overflowPolicy = Spill`。
消息 SHALL 带**属性名**、阈值与行列号。

#### Scenario: Spill 下属性值仍报错

- **WHEN** `overflowPolicy = Spill`，属性 `r="&big;"` 且 `&big;` 展开 100 KB
- **THEN** 抛 `XmlException`，消息含 `属性 'r'`、`64 KB` 与行列号

### Requirement: 临时目录解析

溢出目录 SHALL 按序解析：

1. `EntityLimits.spillDir`
2. 环境变量 `TMPDIR`
3. 系统临时目录（`env.getTempDirectory()`）
4. `env.getWorkingDirectory().join(".fountain_tmp")`（自动创建）

四级全失败 SHALL 抛 `XmlException("无法创建实体溢出文件，请显式指定 spillDir")`，
SHALL NOT 降级回内存。

#### Scenario: 显式 spillDir 优先

- **WHEN** `spillDir = Some(dir)` 且 `TMPDIR` 指向别处
- **THEN** 溢出文件落在 `dir`

#### Scenario: TMPDIR 次之

- **WHEN** `spillDir = None`，`TMPDIR` 有效
- **THEN** 溢出文件落在 `TMPDIR`

#### Scenario: 四级失败明确报错

- **WHEN** 四级都不可写
- **THEN** 抛 `XmlException`，消息含 `spillDir`

### Requirement: standalone 与未声明实体

引用**未声明**实体时，解析器 SHALL 先判断「有没有可能从本文件以外声明」，再按 `standalone`
处理：`"yes"` SHALL 报错；无外部子集且无参数实体引用时 SHALL 报错（WFC: Entity Declared）；
有外部子集或参数实体引用且 `standalone="no"`/缺省时 SHALL 跳过并写告警。三种情形见下方
Scenario，判定细节见 `design.md` §6.8。告警 SHALL 可从 `XmlPullParser.warnings()` 取到。

#### Scenario: standalone=yes 报错

- **WHEN** `<?xml version="1.0" standalone="yes"?><!DOCTYPE a SYSTEM "x.dtd"><a>&ext;</a>`
- **THEN** 抛 `XmlException`

#### Scenario: standalone 缺省跳过不报错

- **WHEN** 同上但无 `standalone`
- **THEN** 解析成功（`ext` 的位置为空文本），且产生一条告警

#### Scenario: standalone=no 时属性值里的未声明实体被去掉

- **WHEN** `<?xml version="1.0" standalone="no"?><!DOCTYPE a SYSTEM "x.dtd"><a x="1&ext;2"/>`
- **THEN** 解析成功，属性值为 `12`，且产生一条告警（有外部子集才允许走跳过档）

#### Scenario: 没有外部子集时报错（不是跳过）

- **WHEN** `<?xml version="1.0"?><a>&ext;</a>`（无 `DOCTYPE`，也未声明 `ext`）
- **THEN** 抛 `XmlException`，消息含实体名 `ext` 与行列号；SHALL NOT 产出空文本后放过

#### Scenario: 有参数实体引用时按跳过处理

- **WHEN** `<?xml version="1.0"?><!DOCTYPE a [<!ENTITY % p "<!ENTITY e 'v'>">%p;]><a>&ext;</a>`
- **THEN** 解析成功（`ext` 位置为空文本），并产生一条告警（有参数实体引用即打开跳过档）

#### Scenario: 无外部子集但实体已声明则正常展开

- **WHEN** `<?xml version="1.0"?><!DOCTYPE a [<!ENTITY ext "v">]><a>&ext;</a>`
- **THEN** 文本为 `v`，不产生告警

### Requirement: 错误分类与降级重试

`XmlException.entityLimitKind` SHALL 为 `?EntityLimitKind`，六值：
`PerEntity`、`Total`、`Depth`、`Declarations`、`HardLimit`、`AttributeValue`。
非实体上限类错误 SHALL 为 `None`。

软阈值（`PerEntity` / `Total`）在 `Strict` 下抛出的异常 SHALL 允许调用方改用 `Spill` 重试一次；
硬限制分类（`Depth` / `Declarations` / `HardLimit`）与 `AttributeValue` 重试必然失败。

#### Scenario: 降级重试成功

- **WHEN** 先用 `Strict` 解析触发 `Some(Total)`，捕获后改用 `Spill` 重试
- **THEN** 第二次解析成功

#### Scenario: 硬限制不重试

- **WHEN** 捕获到 `Some(Depth)`
- **THEN** 同参数重试仍抛同一分类（断言分类不变）

#### Scenario: 非实体错误无分类

- **WHEN** 解析 `<a></b>`
- **THEN** `entityLimitKind == None`

### Requirement: 计数器实例级

实体上限计数器 SHALL 是**解析器实例级**，SHALL NOT 是全局状态。
两个解析器并行解析 SHALL NOT 互相占用额度。

#### Scenario: 两个解析器互不影响

- **WHEN** 两个线程各解析一份展开量接近上限的文档
- **THEN** 两份都成功，不因对方占用额度而超限

### Requirement: 恶意样本必须被拦

下列输入在 `overflowPolicy = Strict` 下 SHALL 在**硬限制内**及时中断，且中断时内存不爆：

- Billion Laughs（嵌套普通实体）
- 参数实体版 Billion Laughs（`%p;` 递归）
- 单实体超长（> `maxExpandedPerEntity`）
- 深度刚好在上限内 / 刚好超限（边界两条）
- XXE（`SYSTEM "file:///etc/passwd"`）
- 外部子集 `SYSTEM "http://…"`（不发请求）
- 超深嵌套（1 万层）
- 超长属性（单属性 100 MB）

#### Scenario: Billion Laughs 在 1 MB 展开量内被中断

- **WHEN** 解析经典 5 层 ×10 的 Billion Laughs，`Strict`
- **THEN** 抛 `XmlException`，且抛错时已展开量 < 1 MB

#### Scenario: XXE 不读文件

- **WHEN** 解析 XXE 样本，把 `file://` 指向一个存在的文件
- **THEN** 抛 `XmlException`，且该文件未被打开（用访问时间或打开计数断言）
