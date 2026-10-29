# xmlconf 20130923 基线（P2.5 / Gate A 现状）

> 由 `cjpm test` 的 `XmlconfHarness_test.fullSuite` 实测。缓存由
> `python3 f_xml/tools/xmlconf_gen.py` 生成，套件与派生 JSON 不入库。

## 1. 可跑集规模（与 `design.md` §9.1 完全一致）

| 项 | 数量 |
|---|---|
| 套件用例总数 | 2586 |
| unsupported（edition 313 + external-entity 95） | 408 |
| 可跑集 | 2178 |
| 参与判定的断言（`error` 不判定） | 2154 |
| `TYPE` 分布 | not-wf 1155 / valid 763 / invalid 236 / error 24 |

## 2. 首次实测结果

```
xmlconf: pass=1696 fail=458 unsupported=408 observed=24 known=0
```

`fail = 458`，**Gate A 未通过**。失败分类如下（`f_xml/.cache/xmlconf/failures.txt`）：

| 分类 | 条数 |
|---|---|
| not-wf 被接受（DTD 语法校验类） | 385 |
| XML 1.1 文档（M3 范围，M1 明确拒绝） | 59 |
| valid/invalid 失败 | 14 |

## 3. 分类说明

### 3.1 not-wf 被接受（384 条）：需要 DTD 语法校验

这些用例的「不良构」出在 DTD 声明本身：`<!ATTLIST>` 的非法属性类型（`NUTOKEN`）、
`<!ELEMENT>` 的内容模型语法（`((a) ?)` 这种非法的空白摆放）、条件段的嵌套规则、
`<!ENTITY>` 的声明顺序等。

`design.md` §1「非目标」明确写了 **不做 DTD 校验（`<!ELEMENT>` / `<!ATTLIST>` 合法性）**，
所以这些用例按设计就不该被检出。要让 `fail = 0`，必须新增一个 DTD 语法校验器——
这是本变更范围之外的新能力，需要用户确认是否纳入。

### 3.2 XML 1.1 文档（59 条）：M1 明确不支持

`f-xml-stream-parser` 规定 `version="1.1"` 抛
`XmlException("XML 1.1 尚未支持（M3）")`，而这些用例的 `TYPE` 是 `valid`。
两者互斥：只要保留「1.1 报错」，这 59 条就必然 fail。

### 3.3 valid / invalid 失败（15 条）：已确认的处理口径

| 用例 | 原因 | 处置 |
|---|---|---|
| `o-p04pass1`、`o-p05pass1` | 非命名空间语料里的多冒号名字 | 记入 `tools/known-issues.json` |
| `sa02`、`sa03`、`sa04`、`not-sa04`、`valid-sa-115` | 实体值引用了**稍后**声明的实体 | 按 `f-xml-dtd-entities`「前向引用报错」处理，不修改 |
| `valid-sa-012`、`x-ibm-1-0.5-valid-P04/P05-*` | XML 1.0 允许的多冒号 / 空前缀名字 | 与命名空间感知处理器冲突，保持报错 |
| `not-sa03`、`rmt-e3e-13` | 外部子集里声明的实体 | `standalone` 语义相关，保持现状 |

## 4. 结论

**Gate A（`fail == 0` & `pass == 2154`）当前不满足**，缺口 = 458 = 384（DTD 语法校验）
+ 59（XML 1.1）+ 15（命名空间 / 前向引用口径）。前两类都不是实现缺陷，而是**范围决策**：
需要在「补 DTD 校验器 + 放开 XML 1.1」和「维持 M1 非目标」之间做选择。
