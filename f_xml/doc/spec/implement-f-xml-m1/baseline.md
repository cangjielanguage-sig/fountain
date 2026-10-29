# xmlconf 20130923 基线（P2.5 / Gate A）

> 由 `cjpm test` 的 `XmlconfHarness_test.fullSuite` 实测。缓存由
> `python3 f_xml/tools/xmlconf_gen.py` 生成，套件与派生 JSON 不入库。
>
> **第三轮评审后只改口径与规划，尚未复跑**：§1 是修订后的目标口径，§2 是旧口径的实测记录，
> §3 是 A/B/C 三项修订落地后的缺口推算。复跑后 SHALL 用真实数字替换 §3 的推算值。

## 1. 可跑集规模（第三轮修订后口径）

| 项 | 数量 |
|---|---|
| 套件用例总数 | 2586 |
| unsupported（`edition` 313 + `external-entity` 95 + `xml-1.1` 59 + `external-subset` 48 + `namespace-name` 9） | 524 |
| 可跑集 | 2062 |
| 参与判定的断言（`error` 不判定） | 2038 |
| `TYPE` 分布 | `not-wf` 1107（1155 − 48）；`valid` / `invalid` 与 `error` 24 由生成脚本实测回填 |

第四、五条规则的动机：

- `external-subset`（48 条）：测试文件的 `<!DOCTYPE … SYSTEM|PUBLIC …>` 指向外部 DTD，不良构只写在
  那个永不加载的 `.dtd` 里。M1 不加载外部子集，就永远看不到那处错误——留在可跑集只是必然 fail。
- `namespace-name`（9 条）：`valid-sa-012`、`x-ibm-1-0.5-valid-P04-ibm04v01.xml`、
  `x-ibm-1-0.5-valid-P05-ibm05v01.xml` / `ibm05v02.xml` / `ibm05v03.xml`、`o-p04pass1`、
  `o-p05pass1`、`rmt-ns10-043`、`rmt-ns10-044`。它们在 XML 1.0 的 `Name` 下合法（多冒号 / 冒号位置），
  但违反 Namespaces 1.0 的 `QName` 约束；M1 一律做命名空间解析，两者互斥。

## 2. 旧口径实测（两条规则，可跑 2178）

```
xmlconf: pass=1696 fail=458 unsupported=408 observed=24 known=0
```

| 分类 | 条数 |
|---|---|
| not-wf 被接受（声明语法未校验） | 385 |
| XML 1.1 文档（M3 范围，M1 明确拒绝） | 59 |
| valid / invalid 失败 | 14 |

### 2.1 not-wf 被接受（385 条）：声明语法校验缺失

这些用例的「不良构」出在 DTD 声明本身：`<!ATTLIST>` 的非法属性类型（`NUTOKEN`）、
`<!ELEMENT>` 的内容模型语法（`((a) ?)` 这种非法的空白摆放）、`<!NOTATION>` 缺外部标识符等。

旧设计把 `<!ELEMENT>` / `<!ATTLIST>` / `<!NOTATION>` 定为「识别并跳过、不校验」，所以这些用例
按设计就不该被检出。**第二轮评审已把「声明语法良构校验」纳入范围**（这是良构性，不是 DTD
有效性），落在 `tasks.md` 8.11；有效性校验（内容模型与文档匹配、`ID` 唯一性、默认属性注入）
仍不做。8.11 落地后 385 条降到 **60** 条仍被接受，其中 **48 条**的不良构只存在于外部 DTD
（由第四条规则 `external-subset` 移出可跑集），其余在 8.9 / 8.12 / 8.13 落地后收敛（§3）。

### 2.2 XML 1.1 文档（59 条）：已移出可跑集

`f-xml-stream-parser` 规定 `version="1.1"` 抛 `XmlException("XML 1.1 尚未支持（M3）")`，
而这些用例的 `TYPE` 是 `valid` / `invalid`。两者互斥：只要保留「1.1 报错」，这 59 条就必然 fail。

处置：作为第三条排除规则 `xml-1.1` 写入 `unsupported.json`，不进可跑集（见
`f-xml-conformance`「可跑集过滤」与 `tasks.md` 6.2）。

### 2.3 valid / invalid 失败（14 条）：逐条处置

| 用例 | 原因 | 处置 |
|---|---|---|
| `sa02`、`sa03`、`sa04`、`not-sa04`、`valid-sa-115` | 实体值引用了**稍后**声明的实体 | 改为**延迟展开**：使用时才展开，此时已声明即成功（`tasks.md` 8.2） |
| `not-sa03`、`rmt-e3e-13` | 未声明实体（只在外部子集声明），文档带外部子集且 `standalone` 为 `no` / 缺省 | 按跳过处理并告警，不报错（`tasks.md` 8.9 修正后的第二档） |
| `valid-sa-012`、`x-ibm-1-0.5-valid-P04-ibm04v01.xml`、`P05-ibm05v01.xml`、`P05-ibm05v02.xml`、`P05-ibm05v03.xml`、`o-p04pass1`、`o-p05pass1` | XML 1.0 允许名字里出现多个冒号，与命名空间感知处理器冲突 | 全部由第五条规则 `namespace-name` 移出可跑集，**不再**登记 `known-issues` |

## 3. 第三轮规则与修正落地后的缺口推算

```
458（旧口径 fail = 385 条 not-wf 被接受 + 59 条 XML 1.1 + 14 条 valid/invalid 失败）
 − 59（规则 3：XML 1.1 用例移出可跑集）
 − 325（8.11 声明语法良构校验命中：385 − 60，余下 60 条仍被接受）
 −   7（8.2 / 8.9：5 条前向引用 + 2 条 standalone）
 −   7（规则 5：5 条命名空间冲突 + o-p04pass1 / o-p05pass1）
 −  48（规则 4：不良构只在外部 DTD）
 −  12（8.9 口径修正 + 8.12 单实体替换文本良构 + 8.13 属性值规范化）
 =   0
```

12 条残差里已点名的是 8.12 的 6 条（`sa-104` / `sa-116` / `sa-117` / `sa-119` / `sa-181` /
`sa-182`），其余 6 条在 8.9 / 8.13 落地后逐条复核归位。复跑若仍有残留，只允许登记为**真正的
套件争议**，受 Gate B 的 5 条上限约束，默认 0 条。

目标（复跑后 SHALL 达成）：

| 指标 | 目标 |
|---|---|
| `fail` | 0 |
| `pass + known` | 2038 |
| `known` | 0（上限 5） |
| `unsupported` | 524 |

## 4. 结论

**Gate A 仍待复跑确认**，但缺口已全部落到可执行项上：325 条归 DTD 声明语法校验（8.11 已实现）、
48 条归「不良构只在外部 DTD」（第四条排除规则）、59 条归 XML 1.1（第三条排除规则）、
7 条归实现口径（延迟展开 + `standalone`）、7 条归命名空间名冲突（第五条排除规则）、
12 条归 8.9 / 8.12 / 8.13 三项规范修正。`known-issues` 默认清空。
性能不属于 Gate A，也不在本变更出口内（见 `design.md` §13）。
