# xmlconf 20130923 基线（P2.5 / Gate A）

> 由 `cjpm test` 的 `XmlconfHarness_test.fullSuite` 实测。缓存由
> `python3 f_xml/tools/xmlconf_gen.py` 生成，套件与派生 JSON 不入库。
>
> **第三轮修订已落地并复跑（2026-10-29）**：§1 是当前口径与实测数字，§2 保留旧口径的历史记录，
> §3 是缺口收敛的实测复核。

## 1. 当前基线（Gate A 已达成）

```
xmlconf: pass=2038 fail=0 unsupported=524 observed=24 known=0
```

| 项 | 数量 |
|---|---|
| 套件用例总数 | 2586 |
| unsupported（`edition` 313 + `external-entity` 95 + `xml-1.1` 59 + `external-subset` 47 + `namespace-name` 10） | 524 |
| 可跑集 | 2062 |
| 参与判定的断言（`error` 不判定） | 2038 |
| `TYPE` 分布（可跑集内） | `not-wf` 1106 / `valid` 705 / `invalid` 227 / `error` 24 |

第四、五条规则的动机：

- `external-subset`（**实测 47 条**）：`TYPE=not-wf`、测试文件的 `<!DOCTYPE … SYSTEM|PUBLIC …>`
  指向外部 DTD、且**测试文件自身良构**（用标准库 `xml.parsers.expat` 以「不加载外部实体 /
  不解析参数实体」的方式试解析可判定）。这种用例的不良构只写在永不加载的 `.dtd` 里，M1 不可能
  检出；已经能被本地规则拦下的 `not-wf` 用例不在本条内（排除它们只会少一条有效断言）。
- `namespace-name`（**实测 10 条**）：`valid-sa-012`、`x-ibm-1-0.5-valid-P04-ibm04v01.xml`、
  `x-ibm-1-0.5-valid-P05-ibm05v01.xml` / `ibm05v02.xml` / `ibm05v03.xml` / `ibm05v05.xml`、
  `o-p04pass1`、`o-p05pass1`、`rmt-ns10-043`、`rmt-ns10-044`。它们在 XML 1.0 的 `Name` 下合法
  （多冒号 / 冒号在首尾 / 前缀未声明），但违反 Namespaces 1.0 的 `QName` 约束；M1 一律做
  命名空间解析，两者互斥。

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
有效性），落在 `tasks.md` 8.11。有效性校验（内容模型与文档匹配、`ID` 唯一性、默认属性注入）
仍不做。

### 2.2 XML 1.1 文档（59 条）：已移出可跑集

`f-xml-stream-parser` 规定 `version="1.1"` 抛 `XmlException("XML 1.1 尚未支持（M3）")`，
而这些用例的 `TYPE` 是 `valid` / `invalid`。两者互斥：只要保留「1.1 报错」，这 59 条就必然 fail。

处置：作为第三条排除规则 `xml-1.1` 写入 `unsupported.json`，不进可跑集。

### 2.3 valid / invalid 失败（14 条）：逐条处置

| 用例 | 原因 | 处置 |
|---|---|---|
| `sa02`、`sa03`、`sa04`、`not-sa04`、`valid-sa-115` | 实体值引用了**稍后**声明的实体 | 改为**延迟展开**：使用时才展开，此时已声明即成功（`tasks.md` 8.2） |
| `not-sa03`、`rmt-e3e-13` | 未声明实体（只在外部子集声明），文档带外部子集且 `standalone` 为 `no` / 缺省 | 按跳过处理并告警，不报错（`tasks.md` 8.9 修正后的第二档） |
| `valid-sa-012`、`x-ibm-1-0.5-valid-P04-ibm04v01.xml`、`P05-ibm05v01.xml`、`P05-ibm05v02.xml`、`P05-ibm05v03.xml`、`o-p04pass1`、`o-p05pass1` | XML 1.0 允许名字里出现多个冒号，与命名空间感知处理器冲突 | 全部由第五条规则 `namespace-name` 移出可跑集，**不再**登记 `known-issues` |

## 3. 缺口收敛的实测复核

旧基线 `fail = 458` 拆成「385 条 `not-wf` 被接受 + 59 条 1.1 失败 + 14 条 `valid` / `invalid`
失败」，三条线各自收口：

```
385（not-wf 被接受）
 − 325（8.11 声明语法良构校验命中）                 = 60
 −  47（规则 4：not-wf + 外部子集 + 测试文件自身良构）
 −   2（规则 5：rmt-ns10-043 / rmt-ns10-044 的 DTD 声明名）
 −  11（B1 BOM 冲突 2 + B2 条件段 1 + B4 单实体替换文本 7 + B5 属性值规范化 1）
                                                    = 0

 59（1.1 失败） − 59（规则 3：移出可跑集）          = 0

 14（valid / invalid 失败）
 −   7（8.2 / 8.9：5 条前向引用 + 2 条 standalone）
 −   7（规则 5：sa-012 / ibm04v01 / ibm05v01 / 02 / 03 / o-p04pass1 / o-p05pass1）
                                                    = 0
```

第五条规则总计 10 条 = 上面 2 + 7 + `x-ibm-1-0.5-valid-P05-ibm05v05.xml`（它本来能通过断言，
但 `<!ENTITY Name: …>` 的本地名为空，同属 `QName` 冲突，按口径应移出可跑集）。

与第三轮估算的差异：规则 4 估算 48、实测 47（多算的那条不良构在测试文件自身）；规则 5 估算 9、
实测 10（漏登 `ibm05v05`）。两者互补，`unsupported` 总额仍是 524。

## 4. 结论

**Gate A 达成**：`fail == 0`、`pass + known == 2038`、`unsupported == 524`、
`known-issues.json` 已重置为空数组（Gate B 默认 0 条）。性能不属于 Gate A，也不在本变更出口内
（见 `design.md` §13）。
