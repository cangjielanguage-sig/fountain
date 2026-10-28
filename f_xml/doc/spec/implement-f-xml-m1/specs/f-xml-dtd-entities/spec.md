# Spec Delta — f-xml-dtd-entities

## ADDED Requirements

### Requirement: 内部子集实体声明

内部子集 `<!DOCTYPE name [ … ]>` 的实体声明 SHALL 按下表处理：

| 语法 | 行为 |
|---|---|
| `<!ENTITY name "值">` / `'值'` | 支持，值里可嵌套引用已声明实体 |
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

#### Scenario: 前向引用报错

- **WHEN** `<!ENTITY b "&a;y"><!ENTITY a "x">`
- **THEN** 抛 `XmlException`（引用了尚未声明的实体）

#### Scenario: 外部实体引用即报错且不开文件

- **WHEN** `<!ENTITY x SYSTEM "file:///etc/passwd">`，正文 `&x;`
- **THEN** 抛 `XmlException`；SHALL NOT 打开该文件

#### Scenario: 首个声明生效

- **WHEN** 同一实体声明两次（值不同）
- **THEN** 使用第一个值，不报错

### Requirement: 其余 DTD 声明与条件段

`<!ELEMENT>` / `<!ATTLIST>` / `<!NOTATION>` SHALL 识别并跳过（跳过器须理解引号与内部 `>`），
SHALL NOT 校验其合法性。条件段 `<![INCLUDE[ … ]]>` / `<![IGNORE[ … ]]>` SHALL 按标志位选择分支。

#### Scenario: ELEMENT/ATTLIST 被正确跳过

- **WHEN** 内部子集含 `<!ELEMENT a (b*)>`、`<!ATTLIST a x CDATA "1>2">`
- **THEN** 不报错，且内部的 `>` 与引号不导致提前结束

#### Scenario: 条件段 IGNORE 分支不生效

- **WHEN** `<!ENTITY e "x"><![IGNORE[<!ENTITY e "y">]]>`，正文 `&e;`
- **THEN** 文本为 `x`

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
| 实体值内部 | 展开，只能引用已声明实体 |

#### Scenario: CDATA 内不展开

- **WHEN** `<!ENTITY e "v">`，正文 `<a><![CDATA[&e;]]></a>`
- **THEN** 文本为 `&e;`

#### Scenario: 注释内不展开

- **WHEN** 正文 `<!-- &e; -->`
- **THEN** 注释内容为 ` &e; `

### Requirement: 属性值处理顺序

属性值 SHALL 按「字符引用 + 实体引用展开 → 换行/制表归一成空格」的顺序处理。
SHALL NOT 先归一化再展开。SHALL NOT 去首尾空格（M1 不解析 `<!ATTLIST>`，一律按 CDATA 类型处理）。

#### Scenario: 实体值里的换行被归一

- **WHEN** `<!ENTITY e "a&#10;b">`，属性 `x="&e;"`
- **THEN** 属性值为 `a b`（换行变成空格），不是 `a\nb`

#### Scenario: 首尾空格保留

- **WHEN** `<a x=" v "/>`
- **THEN** 属性值为 `" v "`

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

### Requirement: standalone 与外部声明的实体

引用「只在外部子集声明」的实体时，解析器 SHALL 按下表处理 `standalone` 取值：

| `standalone` | 引用「只在外部子集声明」的实体时的行为 |
|---|---|
| `"yes"` | 报错（文档自称自包含，却引用了外部声明的东西） |
| `"no"` 或省略 | **不报错**，跳过该实体，记一条告警 |

#### Scenario: standalone=yes 报错

- **WHEN** `<?xml version="1.0" standalone="yes"?><!DOCTYPE a SYSTEM "x.dtd"><a>&ext;</a>`
- **THEN** 抛 `XmlException`

#### Scenario: standalone 缺省跳过不报错

- **WHEN** 同上但无 `standalone`
- **THEN** 解析成功（`ext` 的位置为空），且产生一条告警

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
