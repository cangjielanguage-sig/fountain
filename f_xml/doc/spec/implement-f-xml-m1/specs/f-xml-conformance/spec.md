# Spec Delta — f-xml-conformance

## ADDED Requirements

### Requirement: 套件版本锁定

验收基准 SHALL 是 W3C XML Conformance Test Suite **20130923**（`xmlts20130923.tar.gz`），
SHA-256 SHALL 为 `9b61db9f5dbffa545f4b8d78422167083a8568c59bd1129f94138f936cf6fc1f`。
校验和 SHALL 由 `f_xml/tools/xmlconf_gen.py` 在下载阶段校验；不匹配 SHALL 以非 0 退出并打印
期望值 / 实际值，SHALL NOT 继续解压或生成清单。

切换基准套件版本 SHALL 视作一次「验收基准变更」，需要同时更新 `cases.json`、`unsupported.json`、
`f_xml/doc/xmlconf-unsupported.md` 与本 spec 记录的断言数。

#### Scenario: 校验和不匹配时中止

- **WHEN** 下载内容与记录的 SHA-256 不符
- **THEN** 生成脚本非 0 退出并输出期望 / 实际校验和，不产出 `cases.json`

### Requirement: 套件与派生清单不入库

xmlconf 压缩包、解压结果、`cases.json`、`unsupported.json` SHALL NOT 进入版本库；运行时 SHALL
落在 `f_xml/.cache/xmlconf/`（`.gitignore` 覆盖）。版本库 SHALL 只保留三样：
`f_xml/tools/xmlconf_gen.py`、`f_xml/tools/known-issues.json`、`f_xml/doc/xmlconf-unsupported.md`。

运行时缓存 SHALL 按序解析：环境变量 `F_XML_XMLCONF_CACHE` → `<module>/.cache/xmlconf/`。
两者都不存在时用例 SHALL **fail**，SHALL NOT `skip`，消息 SHALL 含
`python3 f_xml/tools/xmlconf_gen.py`。

#### Scenario: 仓库内没有套件

- **WHEN** 对版本库执行 `git ls-files`
- **THEN** 不出现 `xmlts20130923`、`testdata/xmlconf`、`cases.json`、`unsupported.json` 路径

#### Scenario: 缓存路径被忽略

- **WHEN** 执行 `git check-ignore -v f_xml/.cache/xmlconf/suite`
- **THEN** 命中 `.gitignore` 的 `.cache/` 规则

#### Scenario: 缓存缺失且离线时 fail

- **WHEN** 无缓存、无网络，运行 `cjpm test`
- **THEN** 相关用例 fail，消息提示先运行 `f_xml/tools/xmlconf_gen.py`；不出现 skip

#### Scenario: 有缓存时离线可跑

- **WHEN** 缓存已就绪、无网络，运行 `cjpm test`
- **THEN** harness 正常输出 `pass / fail / unsupported`，不发起任何网络请求

### Requirement: 扁平清单

测试运行时 SHALL 只读缓存目录中的 `cases.json`（`<cache>/cases.json`），SHALL NOT 解析 catalog。
清单条目字段固定为：

```json
{"id":"o-p01pass2","type":"valid","uri":"oasis/p01pass2.xml","edition":null,"entities":"none","sections":"2.2 [1]"}
```

生成脚本 `f_xml/tools/xmlconf_gen.py` SHALL 入库，SHALL 能从 31 个 catalog 重新产出
`cases.json` 与 `unsupported.json`；判定口径（`EDITION` 排除规则、外部实体判定规则）SHALL 写在
脚本注释里。

理由：聚合 catalog 用 `SYSTEM` 外部实体引入子 catalog，而 `f_xml` 永不加载外部实体——
用它自己解析只会得到空树。这不是缺陷，正是设计边界。

#### Scenario: 不解析 catalog

- **WHEN** 运行 `cjpm test`
- **THEN** 测试进程不读取任何 `.dtd` / `.ent` / catalog 文件

#### Scenario: 清单可重现

- **WHEN** 用脚本从原始套件重新生成
- **THEN** `cases.json` 与 `unsupported.json` 与缓存中的版本逐字节一致；输出不含时间戳 /
  主机名 / 绝对路径

### Requirement: 可跑集过滤

可跑集 SHALL 由两条规则确定：

1. `EDITION` 包含 `1`/`2`/`3`/`4` 之一的用例 SHALL 排除（第 5 版改了 `Char` 产生式）。
2. 测试文件出现 `<!ENTITY … SYSTEM|PUBLIC>` 的用例 SHALL 排除（95 条）。只使用内部实体的
   323 条中，228 条 SHALL 纳入可跑集。

排除项 SHALL 写入 `unsupported.json`，每条带原因（`edition` / `external-entity`）。

#### Scenario: 总数与断言数吻合

- **WHEN** 统计可跑集
- **THEN** 总计 2586、`unsupported` 408、可跑 2178、断言 2154；`not-wf` 1155 / `valid` 763 /
  `invalid` 236 / `error` 24（不判定）

#### Scenario: 内部实体用例纳入

- **WHEN** 一条用例声明了内部实体且无 `SYSTEM` / `PUBLIC`
- **THEN** 它出现在可跑集中，不在 `unsupported.json` 里

#### Scenario: EDITION 是集合运算

- **WHEN** `EDITION="1 2 3 4"`
- **THEN** 排除；`EDITION="5"` 或省略 → 纳入

### Requirement: TYPE 的期望映射

harness SHALL 按下列映射判定每条用例：

| `TYPE` | 期望 |
|---|---|
| `valid` | 解析成功 |
| `invalid` | **解析成功**（良构但不合 DTD，我们不校验 DTD） |
| `not-wf` | 抛致命错误 |
| `error` | **不判定**，单列观察计数 |

`invalid` 当「应报错」断言会一次性错 236 条，harness SHALL NOT 这样映射。

#### Scenario: invalid 期望成功

- **WHEN** 用例 `TYPE="invalid"`
- **THEN** 解析不抛异常，判定为 pass

#### Scenario: not-wf 期望失败

- **WHEN** 用例 `TYPE="not-wf"`
- **THEN** 解析抛 `XmlException`，判定为 pass；未抛则为 fail

### Requirement: 单双引号属性

catalog 中 348 条用例的 `TYPE` 用单引号。harness / 生成脚本 SHALL 同时接受单引号与双引号。

#### Scenario: 单引号 TYPE

- **WHEN** catalog 行为 `TYPE='valid'`
- **THEN** 该用例被正确解析为 `valid`

### Requirement: 不比对 OUTPUT

首版 SHALL NOT 比对 `OUTPUT` 指向的规范化输出（432 条）。断言只覆盖良构性。
C14N 归 M3。

#### Scenario: 带 OUTPUT 的用例只判良构

- **WHEN** 用例带 `OUTPUT="out/xxx.xml"`
- **THEN** 只断言解析是否成功，不读 `.out` 文件

### Requirement: 验收门槛

验收 SHALL 同时满足下列三道 Gate：

| Gate | 标准 |
|---|---|
| A（必过） | 2154 条断言全部符合期望 |
| B（例外管理） | `f_xml/tools/known-issues.json` 每条写明理由 + 规范章节，上限 5 条；超出即不通过 |
| C（可追溯） | 每次运行输出 `pass / fail / unsupported` 三个数字，并把 `unsupported` 的 ID 清单存档 |

#### Scenario: Gate A

- **WHEN** 运行全量套件
- **THEN** `fail == 0`，`pass == 2154`，`unsupported == 408`

#### Scenario: Gate B 超限即失败

- **WHEN** `known-issues.json` 有 6 条
- **THEN** harness 直接判不通过

#### Scenario: Gate C 三数字

- **WHEN** 任意一次运行
- **THEN** 输出三数字，并写出 `unsupported` 的 ID 清单文件

### Requirement: unsupported 清单入库

408 条 `unsupported` SHALL 单列清单并写入 `f_xml/doc/xmlconf-unsupported.md`（该 md 入库），
SHALL NOT 混进通过率。机器可读的 `unsupported.json` SHALL 只存在于缓存目录，不入库。

#### Scenario: 文档与 JSON 一致

- **WHEN** 对比缓存内 `unsupported.json` 与 `f_xml/doc/xmlconf-unsupported.md`
- **THEN** 条目数与 ID 集合一致

### Requirement: 语法矩阵覆盖

除 xmlconf 外，SHALL 有用例覆盖设计文档 §12.2 A–I 的**盲区项**（标 ❌ 的）：

文档结构（尾部注释/PI、多根、无根）、元素属性（属性值规范化、重复属性、裸 `<`、非 ASCII 名字、
数字开头名字）、字符数据（高位码点、非法码点、`&nbsp;`）、CDATA（`]]`、相邻与混合）、
注释与 PI（`--`、`-` 结尾、`xml` target、`?>`）、DOCTYPE（内部子集含 `>`、参数实体、
条件段、属性值内实体）、命名空间（`xmlns=""`、嵌套重定义、属性不受默认命名空间、未声明前缀、
`xmlns` 作前缀）、编码（UTF-16 带 BOM、声明冲突、4 字节 UTF-8）、空白（首尾空格、`xml:space`）。

#### Scenario: 盲区项不得缺用例

- **WHEN** 逐条核对 §12.2 的 ❌ 行
- **THEN** 每条至少 1 个正向或负向用例

### Requirement: 组合测试

SHALL 有用例覆盖语法元素叠加（设计文档 §12.3）：CDATA 在带命名空间元素内、注释夹在元素之间、
PI 紧邻 CDATA、自闭合元素带命名空间声明、深层嵌套中某层重置命名空间。

#### Scenario: 自闭合带命名空间声明

- **WHEN** 解析 `<x:a xmlns:x="A"/>`
- **THEN** 元素 `uri = Some("A")`，且产出 Start + End 两条事件

### Requirement: 五个格式样本

SHALL 有真实文档样本：RSS / Atom、SVG、SOAP、POM、OOXML 片段。它们只用于验证「风格变体」，
SHALL NOT 作为「通用性」的唯一证据。

#### Scenario: OOXML 的 xml:space

- **WHEN** 解析含 `<w:t xml:space="preserve"> x </w:t>` 的片段
- **THEN** 文本首尾空格保留

### Requirement: 性能门槛

事件模式解析 10 MB 文档 SHALL < 1 s（开发机），RSS SHALL 不随文档规模线性增长；
DOM 模式 SHALL 记录峰值内存，但 SHALL NOT 作为门禁（DOM 本来就是 O(节点数)）。

#### Scenario: 事件模式 RSS 平稳

- **WHEN** 用事件模式解析 1 MB / 10 MB / 50 MB 三份同构文档
- **THEN** RSS 峰值差异在常数范围内
