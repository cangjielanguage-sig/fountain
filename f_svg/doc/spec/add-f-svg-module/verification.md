# add-f-svg-module 校验报告（只读）

**校验范围**：`openspec/changes/add-f-svg-module/{proposal.md,design.md,tasks.md,specs/**}` 与 `f_svg/src/**`、`f_svg/testdata/**`、模块登记文件。  
**执行结果**：`cjpm test` 189 passed / 0 failed；`cjpm build` 成功，`f_svg` 自身编译无 warning（22 条 warning 来自 `f_xml` 依赖，测试编译另有 2 条 `f_svg` 测试代码 warning）。  
**总体结论（修复后）**：初检发现的 2 个 CRITICAL 已在第 6 节修复并复验；影响安全/数据正确性的 WARNING 已修复，其余记录为已知限制。`cjpm test` 216 passed / 0 failed，`openspec validate --strict` 通过，**可以进入 archive**。

---

## 1. 维度汇总

| 维度 | CRITICAL | WARNING | SUGGESTION |
|---|---:|---:|---:|
| Completeness | 0 | 2 | 3 |
| Correctness | 2 | 10 | 1 |
| Coherence | 0 | 3 | 3 |

---

## 2. Completeness

### 2.1 已确认完成的部分

- 值类型 10 类 + `formatSvgNumber` 全部存在：`SvgLength`、`SvgColor`、`SvgPaint`、`SvgMatrix`、`SvgTransform`、`SvgPathData`、`SvgViewBox`、`SvgPreserveAspectRatio`、`SvgPointList`、`SvgNumberList`。
- 类型化模型全部存在：`SvgDocument`、`SvgRoot`、`SvgContainer`（10 种 kind）、7 种形状、3 种文本、2 种渐变 + stop、`SvgUse`、`SvgImage`、`SvgUnknownElement`。
- 解析 5 入口、写入 2 入口、安全选项、`SvgException` 均存在。
- 登记齐全：根 `.modules`、根 `cjpm.toml`、中英文 README 均有 `f_svg`；`f_svg` 排在 `f_xml` 之后。
- `testdata/` 六个样本齐全；`SvgRoundTrip_test` 已覆盖六样本结构等价与二次写入稳定。

### 2.2 [WARNING] 任务 17.8 的性能/内存验收口径未真正达成

- 任务目标：解析 ≤ 25 ms、序列化 ≤ 20 ms、峰值内存 ≤ 8× 输入（`openspec/changes/add-f-svg-module/tasks.md:149`）。
- 实测记录：解析 53.8 ms、序列化 24.8 ms、峰值内存“未度量”（`f_svg/doc/perf-baseline.md:16-18`）。
- 测试只断言 `< 5000 ms`（`f_svg/src/SvgRoundTrip_test.cj:81-82`），并未验证任务目标。
- 影响：任务被勾选 `[x]`，但指标实际未达；若归档时把 tasks 视为验收证据，会形成“已完成”的误读。
- 建议：在 tasks/perf 文档中明确“参考值、非门禁”，或补测内存并修正目标。

### 2.3 [WARNING] 规格场景的测试覆盖存在缺口

- `SvgParser_test.parserSnapshot` 只比较 `root.toString() + warnings.size`（`f_svg/src/SvgParser_test.cj:54-56`），而规格要求五个入口的 `SvgDocument` **结构快照**相等（`specs/svg-document-model/spec.md:154-157`）。`declaration`、`doctype`、`prolog`、`epilog` 未参与比较。
- 无 `fill="url(http://...)"` / `stroke="url(...)"` 的解析级用例；`SvgPaint_test` 只验证了 `SvgPaint.parse` 抛 `Security`（`f_svg/src/SvgPaint_test.cj:72-94`），未验证文档构建后该属性被移除。
- 外部 DTD / 外部实体“永不加载”只有内部实体上限用例（`f_svg/src/SvgSecurity_test.cj:212-222`），没有外部 `SYSTEM`/`PUBLIC` 实体的负向用例。
- `#rrggbbaa`、高精度路径数字、`preserveAspectRatio="none slice"` 的往返没有用例（详见 Correctness）。
- 建议：补齐上述场景，或在 tasks 18.6 中标注“逐条确认”的实际覆盖边界。

### 2.4 [SUGGESTION] 测试文件命名与设计 D11 不一致

设计 D11 要求 `*_test.cj` 与实现同名（`design.md:135`），但实际：

| 测试类 | 所在文件 |
|---|---|
| `SvgStop_test` | `SvgGradient_test.cj` |
| `SvgUnknownElement_test` | `SvgDocument_test.cj` |
| `SvgPointList_test` | `SvgNumberList_test.cj` |
| `SvgTextPath_test` | `SvgTextElement_test.cj` |
| `SvgImage_test` | `SvgUse_test.cj` |

功能不影响，但和设计约定不一致。

### 2.5 [SUGGESTION] `SvgPaintServerRef` 是死 API

`SvgPaintServerRef` 已定义（`f_svg/src/SvgPaint.cj:52-58`），但 `SvgPaint.parse` 返回的是裸 `String`，解析路径未使用该类型；测试仅直接构造它（`f_svg/src/SvgPaint_test.cj:127-130`）。任务 4.3 要求实现它，但目前只是“存在”，没有进入公开 API 链路。

### 2.6 [SUGGESTION] 当前 worktree 的 Git 元数据不可用

`.git` 指向 `/storage/Users/...`，实际路径是 `/mnt/linux_share/storage/Users/...`，导致 `git status`/`git log` 失败。属于 worktree 环境问题，不是本次 change 的代码问题，但会影响任务 18.7 的分支/提交核验。

---

## 3. Correctness

### 3.1 [CRITICAL] 外部引用只过滤了 `href`，`fill`/`stroke`/`filter`/`clip-path` 等 URL 属性仍被保留

**证据**

- `SvgBuilder.shouldRemoveAttribute` 只处理 `on*` 与 `href`（`f_svg/src/SvgBuilder.cj:231-244`）。
- `fillSvgAttributes` 在 `validateSvgAttribute` 之后无条件 `appendAttribute`（`f_svg/src/SvgBuilder.cj:206-218`）。
- `validateSvgAttribute` 对非法值只记 warning 或抛 `InvalidValue`，不删除属性（`f_svg/src/SvgBuilder.cj:303-312`）。
- `isValidSvgAttribute` 对 `filter`、`clip-path`、`mask`、`marker-*` 等直接落到 `case _ => true`（`f_svg/src/SvgBuilder.cj:314-344`）。
- `SvgPaint.parse` 对 `url(http://...)` 确实抛 `Security`（`f_svg/src/SvgPaint.cj:161-163`），但解析阶段调用的是 `tryParseSvgPaint`，它把 `SvgException` 全部吞掉返回 `None`（`f_svg/src/SvgPaint.cj:384-390`）。

**影响**

默认（宽松）模式下：

```xml
<rect fill="url(https://evil.example/x.svg#p)"/>
<rect filter="url(https://evil.example/f.svg#f)"/>
```

`fill` 会得到一条“值不合法”warning 但属性仍保留；`filter` 连 warning 都没有。序列化后这些外部引用仍在输出文档中，下游渲染器可能发起外部请求。这直接违反 `svg-security` 的“默认移除指向外部资源的引用……任何非 `#` 开头的 URL”（`specs/svg-security/spec.md:28-39`），也违反 proposal 的“默认移除……外部引用”（`proposal.md:18`）。

**建议**

- 对所有 URL 型属性（`fill`、`stroke`、`filter`、`clip-path`、`mask`、`marker-start/mid/end` 等）统一走引用检查；
- 捕获 `SvgException(kind: Security)` 时按 `unsafePolicy` 移除/拒绝，而不是当作普通非法值；
- 增加 `<rect fill="url(http://...)" />` 的解析级用例。

---

### 3.2 [CRITICAL] `parse(toString(x)) == x` 对合法输入不成立

**规格/设计声明**

- `specs/svg-value-types/spec.md:190`：所有值类型 SHALL 满足 `parse(toString(x)) == x`。
- `design.md:91`、`design.md:156` 也明确把它列为契约。
- `f_svg/README.md:143` / `README_en.md:145` 对用户重复了该承诺。

**实现事实**

- `formatSvgNumber` 固定最多 6 位小数，且 `|v| < 1e-6` 归零（`f_svg/src/SvgNumber.cj:32-49`）。
- `SvgLength.toString` 使用该格式化，`==` 比较原始 `Float64`（`f_svg/src/SvgLength.cj:126-132`）。
- `SvgColor.toString` 对 alpha 使用 `formatSvgNumber`，`==` 比较原始 alpha（`f_svg/src/SvgColor.cj:137-147`）。
- `SvgPathData.toString` 对坐标使用 `formatSvgNumber`（`f_svg/src/SvgPathData.cj:280-289`）。

**可复现反例**

| 输入 | `toString` | 重新 `parse` | 结果 |
|---|---|---|---|
| `SvgLength.parse("1e-7")` | `"0"` | `SvgLength(0)` | `1e-7 != 0` |
| `SvgLength.parse("1.2345678")` | `"1.234568"` | `1.234568` | 原值不相等 |
| `SvgColor.parse("#ff000080")` | `rgba(255,0,0,0.501961)` | alpha `0.501961` | 原 alpha `128/255` 不相等 |
| `SvgPathData.parse("M0.1234567 0")` | `M 0.123457 0` | 坐标被舍入 | 命令数组不相等 |

测试已经间接承认了这一点：`SvgColor_test.roundTrip` 的注释明确“alpha 不是 1 的十六进制输入不参与”（`f_svg/src/SvgColor_test.cj:130-144`），其余往返样本也都是短小数。

**影响**

这不是“边界上的浮点误差”，而是规格无条件声明的契约不成立；`SvgColor` 的 `#rrggbbaa` 还是规格自己列出的场景（`specs/svg-value-types/spec.md:58-61`）。如果调用方依赖 `parse(toString(x))` 做缓存键、去重或持久化，会得到不同值。

**建议**

二选一并在规格中写清楚：

1. 放宽契约为“对规范形式可表示的值成立”，并把 `#rrggbbaa`、高精度数字列为已知不保真；
2. 或让 `toString` 保留足够精度（如最短往返表示），使契约真正成立。

---

### 3.3 [WARNING] 同时含 `href` 与 `xlink:href` 的输入会写出重复属性

**证据**

- 解析阶段保留两个不同 QName 的属性（`f_svg/src/SvgBuilder.cj:206-218`）。
- `SvgWriter.normalizeElementHrefs` 对每个 `local == "href"` 的属性逐个改写；`xlink=true` 时把裸 `href` 改成 `xlink:href`，若原来已有 `xlink:href`，就会得到两个展开名相同的属性（`f_svg/src/SvgWriter.cj:128-148`）。
- 模型层的 `writeSvgHref` 会先删两种再写一种（`f_svg/src/SvgElement.cj:426-435`），但解析路径不经过它。

**影响**

`<use href="#a" xlink:href="#b"/>` 这类兼容写法（或恶意构造）会输出重复的 `xlink:href`，产生非法 XML；`xlink=false` 时同样会输出两个裸 `href`。这违反往返契约中的“属性展开名一致”。

**建议**

在 `normalizeElementHrefs` 中先按展开名去重，或解析阶段就统一成一种 `href`；补充双写法用例。

---

### 3.4 [WARNING] `SvgPaint.referencing` 接受无 `#` 的 id，序列化结果会被自己的解析器拒绝

**证据**

- `SvgPaint.referencing(id)` 不做 `#` 校验（`f_svg/src/SvgPaint.cj:94-96`）。
- `toString` 输出 `url(${id})`（`f_svg/src/SvgPaint.cj:125`）。
- `parseReference` 要求 `id[0] == '#'`，否则抛 `Security`（`f_svg/src/SvgPaint.cj:161-163`）。

**影响**

`SvgPaint.referencing("grad1")` → `"url(grad1)"` → `SvgPaint.parse` 抛 `Security`，工厂方法与解析器不自洽；同时规格场景写的是 `id` 为 `grad1`（`specs/svg-value-types/spec.md:83-84`），实现返回 `Some("#grad1")`，README 示例又写成 `Reference(#grad1, ...)`（`f_svg/README.md:149`），三处口径不一致。

**建议**

明确 id 的规范形式：要么工厂强制/补齐 `#` 并统一文档，要么 `reference` 存不带 `#` 的 id 并在 `toString` 时补 `#`。

---

### 3.5 [WARNING] `setAttr(namespace:local:value:)` 对任意命名空间硬编码前缀 `ns`

**证据**

- `prefixOf(namespace)` 对非 XLink/XML 命名空间一律返回 `"ns"`（`f_svg/src/SvgElement.cj:407-415`）。
- `setAttr` 用它构造 QName（`f_svg/src/SvgElement.cj:157-166`）。

**影响**

程序化写入多个不同外部命名空间时，会生成多个 `ns` 前缀但不同 URI 的属性；`f_xml::XmlWriter` 的命名空间声明可能复用/覆盖 `xmlns:ns`，导致属性 URI 错乱。解析路径保留原前缀，不受影响，但公开 setter 会踩坑。

**建议**

按 URI 生成稳定且唯一的前缀，或允许调用方显式传入前缀；补多命名空间 setter 用例。

---

### 3.6 [WARNING] 严格模式会校验非 SVG 命名空间元素的同名属性

**证据**

- 外来命名空间元素走 `SvgUnknownElement` 分支后，仍然调用 `fillSvgAttributes`（`f_svg/src/SvgBuilder.cj:167-175`）。
- `validateSvgAttribute` 只按 `local` 名匹配，不判断元素/属性命名空间（`f_svg/src/SvgBuilder.cj:303-344`）。

**影响**

严格模式下，`<x:rect xmlns:x="urn:x" fill="var(--x)"/>` 会因为 `fill` 不是合法 paint 而抛 `InvalidValue`，尽管该元素属于“未知内容应无损保留”的范畴。宽松模式下也会产生无意义的 warning。这会让含编辑器私有命名空间的真实 SVG 在 strict 模式下无法解析。

**建议**

`validateSvgAttribute` 仅对 `namespace == SVG` 的已知元素执行，或至少仅对 SVG 命名空间属性执行；外部命名空间属性原样保留。

---

### 3.7 [WARNING] `allowExternalReferences=true` 同时放行 `javascript:` / `file:`

**证据**

`handleHrefValue` 只区分 `data:` 与其他 URL；`allowed` 为 `true` 时直接保留（`f_svg/src/SvgBuilder.cj:246-264`）。

**影响**

名为“允许外部引用”的开关会连带放行 `javascript:alert(1)`，与 `svg-security` 的“放行开关 SHALL 只影响对应类别，不得连带放宽其他类别”（`specs/svg-security/spec.md:53-55`）存在张力，也容易被误用。

**建议**

把 `javascript:`（以及可选的 `file:`）从 `allowExternalReferences` 中独立出来，默认永不因该开关放行；或至少增加独立开关并在文档中明示。

---

### 3.8 [WARNING] 写出声明的 encoding 与 `charset` 可能不一致

**证据**

- `SvgWriter.declarationFor` 直接复用源文档的 `XmlDeclaration`（`f_svg/src/SvgWriter.cj:111-119`）。
- `f_xml::XmlWriter` 原样输出声明（`f_xml/src/XmlWriter.cj:118-120`），`charset` 只控制字节编码。
- `writeSvgString` 始终 `String.fromUtf8(buffer.bytes())`（`f_svg/src/SvgWriter.cj:159-168`）。

**影响**

输入 `<?xml version="1.0" encoding="ISO-8859-1"?>`，调用 `writeSvgString(document, SvgWriteOptions(charset: Charsets.UTF8))`，输出声明仍写 `ISO-8859-1` 而字节是 UTF-8；非 UTF-8 的 `charset` 走 `writeSvgString` 还会得到错误字符串或抛解码异常。

**建议**

写入时用 `charset` 生成声明，或提供“保留声明/按选项重写”的明确策略；`writeSvgString` 对非 UTF-8 `charset` 应显式拒绝或提供字节接口。

---

### 3.9 [WARNING] `SvgPreserveAspectRatio(NoAlign, slice: true)` 经 `toString` 丢失 `slice`

**证据**

`toString` 在 `align == NoAlign` 时直接返回 `"none"`，忽略 `slice`（`f_svg/src/SvgPreserveAspectRatio.cj:170-178`）；而 `parse("none slice")` 会得到 `slice=true`（`f_svg/src/SvgPreserveAspectRatio.cj:105-120`）。

**影响**

`parse("none slice")` → `toString()` = `"none"` → `parse` 得到 `slice=false`，不满足 3.2 的往返契约。测试样本没有覆盖 `"none slice"`（`f_svg/src/SvgPreserveAspectRatio_test.cj:57`）。

**建议**

明确 `none` 下 `slice` 是否参与语义；若参与，`toString` 必须保留；若不参与，`parse` 可忽略但应在文档中写明，并接受该值不满足严格往返。

---

### 3.10 [WARNING] 构建期错误的 `line`/`column` 恒为 0

**证据**

构建器抛出的 `SvgException` 都只传 `0, 0`（如 `f_svg/src/SvgBuilder.cj:136, 157-163, 261, 269, 309`）；`SvgException` 的带位置构造才保留行列（`f_svg/src/SvgException.cj:75-95`）。

**影响**

proposal 说 `SvgException` “保留行列与元素路径”（`proposal.md:19`），design 目标 6 也说“解析/生成错误的行、列、元素路径定位”（`design.md:20`）。实际上只有 `f_xml::XmlException` 包装的错误有行列，语义属性错误只有 `elementPath`。任务 14.8 只要求覆盖 XML 错误，所以是“任务达成、proposal 承诺未完全达成”。

**建议**

要么在 proposal/README 中限定“XML 错误保留行列，构建期错误保留元素路径”，要么让构建器基于源位置补充行列。

---

### 3.11 [WARNING] `attributes` / `children` / `warnings` 公开可变，可绕过设计不变量

**证据**

- `attributes` 是 `public let ArrayList<SvgAttribute>`（`f_svg/src/SvgElement.cj:51`），但缓存失效只依赖 `setAttr`/`removeAttr`/`appendAttribute` 里的 `attributesVersion++`（`f_svg/src/SvgElement.cj:56, 145-200`）。
- `children` 同为公开可变列表，`parent` 只在 `appendChild` 中维护（`f_svg/src/SvgElement.cj:52, 202-209`）。
- `warnings` 是 `public let ArrayList<String>`（`f_svg/src/SvgDocument.cj:29`），规格要求“只增”（`specs/svg-security/spec.md:94`）。

**影响**

调用方执行 `element.attributes.add(...)` 或 `element.attributes[0] = ...` 后，类型化 getter 仍可能返回旧缓存值，违反 design D2 的“单一版本失效”保证；直接改 `children` 会破坏 `parent`/`elementPath()`；直接 `warnings.clear()` 可以清空审计记录。

**建议**

对外暴露只读视图或迭代器，写操作只经 `setAttr`/`removeAttr`/`appendChild`；`warnings` 提供只读访问。

---

### 3.12 [WARNING] `<script>` 仅在 SVG 命名空间被移除

**证据**

`buildSvgOne` 的条件是 `namespace == SvgNamespaces.SVG && local == "script"`（`f_svg/src/SvgBuilder.cj:132`）。

**影响**

`<foreignObject><script xmlns="http://www.w3.org/1999/xhtml">alert(1)</script></foreignObject>` 会被保留。虽然 M1 明确不解释 `foreignObject` 内部 XHTML 语义，但安全过滤不应依赖语义范围；规格写的是“移除 SVG 文档中的 `<script>` 元素”（`specs/svg-security/spec.md:5-26`），没有限定命名空间。

**建议**

安全过滤按 local name 对所有命名空间的 `script` 生效，或在文档中明确“仅 SVG 命名空间脚本”并把它列为残余风险。

---

### 3.13 [SUGGESTION] 其他边界问题

- `SvgTransform.parse` 接受 `translate(10,)` 这类尾逗号（`f_svg/src/SvgTransform.cj:169-198`）。
- `buildSvgChildren` 对 `XmlNode.EntityRefNode` 直接忽略（`f_svg/src/SvgBuilder.cj:108`）。
- `elementsByTag` 包含根元素自身（`f_svg/src/SvgDocument.cj:83-93`），而规格写“全部后代”（`specs/svg-document-model/spec.md:134`）。
- `SvgElement.toString` 对 CDATA 中的 `]]>`、注释中的 `--` 不做处理（`f_svg/src/SvgElement.cj:302-318`）。
- `xlink=false` 时会把任意命名空间的 `local == "href"` 属性折叠成裸 `href`（`f_svg/src/SvgWriter.cj:145-147`）。
- `SvgDocument.toString()` 不经过 `SvgWriteOptions.xlink` 归一化，与 `writeSvgString` 的输出可能不同。

---

## 4. Coherence

### 4.1 [WARNING] `<style>` / `<title>` / `<desc>` 不在标签表，严格模式会拒绝

**证据**

- `SvgTag` 的表只覆盖 SVG 图形/结构/文本/渐变元素（`f_svg/src/SvgTag.cj:21-57`）。
- 未命中且属于 SVG 命名空间时：宽松模式记“未知标签”，严格模式抛 `Unsupported`（`f_svg/src/SvgBuilder.cj:150-166`）。
- proposal 明确说 “`<style>` 与 `style=""` 原样保留但不解释”（`proposal.md:22`）。

**影响**

- 宽松模式：`<style>`、`<title>`、`<desc>` 会被当作未知标签并产生 warning，属于噪声；
- 严格模式：这些合法且常见的 SVG 1.1 元素会直接导致文档解析失败。
- 与 proposal 的“`<style>` 原样保留”承诺冲突：保留是做到了（作为 `SvgUnknownElement`），但“不解释”不等于“严格模式拒绝”。

**建议**

把 `style`、`title`、`desc`、`metadata` 至少加入“已知但无语义”的表（映射为 `SvgUnknownElement` 但不记未知标签 warning），或在 proposal 中明确 M1 的严格模式不支持这些标签。

---

### 4.2 [WARNING] 设计 D2 的“解析阶段填充类型化缓存”未实现

**证据**

- design D2 说解析阶段在构建元素的同一次 DFS 里完成已知属性的首次解析与校验，并把结果填入缓存（`design.md:60-66`）。
- `SvgValueCache` 没有“写入/预置”接口（`f_svg/src/SvgElement.cj:28-41`）。
- 构建器只做 `validateSvgAttribute`（`f_svg/src/SvgBuilder.cj:303-312`），类型化 getter 首次读取时会重新解析（例如 `SvgElement.transform` 的缓存计算 `f_svg/src/SvgElement.cj:105-124`）。

**影响**

行为正确，但“每个属性只解析一次”的性能承诺不成立；解析大文档时同一属性至少解析两次（校验 + 首次读取）。这也与 perf-baseline 的解析耗时偏高（53.8 ms vs 25 ms）相互印证。

**建议**

要么实现缓存预置（构建时把解析结果存入对应的 `SvgValueCache`），要么修订 D2，把“解析一次”改为“校验一次、按需解析”。

---

### 4.3 [WARNING] README/design 的往返承诺与实现不一致

**证据**

- `design.md:91`、`design.md:156`、`f_svg/README.md:143`、`README_en.md:145` 都无条件声明 `parse(toString(x)) == x`。
- 实际反例见 3.2。
- `f_svg/README.md:149` 写 `SvgPaint.parse("url(#grad1) none") // Reference(#grad1, ...)`，实现 `reference == "#grad1"`（`f_svg/src/SvgPaint_test.cj:43`），而 spec 写 `id` 为 `grad1`（`specs/svg-value-types/spec.md:83-84`）。

**影响**

用户文档和规格对同一契约给出三种不同表述，容易导致调用方误用。

**建议**

统一“引用 id 是否带 `#`”和“往返契约精度”的表述；在 README 的值类型章节补充“规范形式”的边界。

---

### 4.4 [SUGGESTION] tasks 全勾选与实际验收口径的偏差

`tasks.md` 所有条目均为 `[x]`，但：

- 17.8 的性能/内存指标未达成或未度量（见 2.2）；
- 18.6 “逐条确认场景有对应用例”存在覆盖缺口（见 2.3）。

建议在 tasks 中区分“实现完成”和“验收指标达成”，避免归档时把勾选当作全部验收通过。

### 4.5 [SUGGESTION] 模块登记与设计 D11/D12 已对齐（正向确认）

- 根 `.modules` 在 `f_xml` 之后加入 `f_svg`；
- 根 `cjpm.toml` 增加 `"fountain::f_svg" = {path = "./f_svg"}`；
- `f_svg/cjpm.toml` 与 `f_xml` 同构（`cjc-version`、`version`、`output-type`、target 段、`include`）；
- 未新增聚合根 shim，符合 D12。

---

## 5. 归档前建议处理顺序

1. **先处理 CRITICAL-3.1**：统一 URL 型属性的外部引用过滤，补解析级安全用例。
2. **再决策 CRITICAL-3.2**：修订规格/README 的往返契约，或提高 `toString` 精度；至少补齐 `#rrggbbaa` 与高精度数字的明确行为。
3. **修复 WARNING 中影响数据正确性的项**：重复 `href` 写出（3.3）、`SvgPaint.referencing` 自洽（3.4）、`setAttr` 前缀冲突（3.5）、严格模式外部属性校验（3.6）。
4. **补齐 Completeness 的验收证据**：性能/内存口径（2.2）、五入口完整快照、外部实体负向用例（2.3）。
5. **同步 Coherence 文档**：`<style>` 标签表（4.1）、D2 缓存描述（4.2）、往返契约表述（4.3）。

**本次校验未修改任何源码，未归档 change。**

---

## 6. 修复结果（2026-11-05）

按 `verify-fix-plan.md` 执行，每项先补失败用例（Red）、确认失败原因后实现（Green），
`cjpm test` 全绿后提交。分支 `feature/f_svg`。

| 条目 | 结论 | 说明 / 证据 |
|---|---|---|
| **C-1** 3.1 URL 型属性外部引用 | 已修复 | `SvgBuilder` 对 `fill`/`stroke`/`filter`/`clip-path`/`mask`/`marker-*`/`cursor` 统一扫描 `url(...)`，非 `#` 目标按 `unsafePolicy` 处理；`url(#id)` 保留。新增默认移除、Reject、严格模式、Keep 四组解析级用例。 |
| **C-2** 3.2 值类型往返契约 | 已修复 | `SvgColor.toString` 在 alpha 可由 `0..255` 字节精确表示时输出 `#rrggbbaa`，`#ff000080` 精确往返；规格/README/设计统一为「规范形式可表示」并列出 `<1e-6` 归零、6 位小数舍入边界；补 `1e-7`、`1.2345678`、`M0.1234567 0` 用例。 |
| W-3.3 重复 `href` | 已修复 | `SvgWriter.normalizeElementHrefs` 先按 href 槽位去重（保留第一个），再按 `xlink` 统一；补 `href` + `xlink:href` 与 `xlink=false` 用例。 |
| W-3.4 `SvgPaint.referencing` 自洽 | 已修复 | 工厂自动补 `#`，空 id / `#` 抛 `InvalidValue`；`referencing("grad1")` → `url(#grad1)` 可被 `parse` 接受。 |
| W-3.5 `setAttr` 命名空间前缀 | 已修复 | 元素内维护 URI→前缀映射，同一 URI 复用、新 URI 分配 `ns1`/`ns2`… 并跳过占用；`xlink`/`xml` 固定。补多命名空间用例。 |
| W-3.6 外部命名空间属性校验 | 已修复 | 仅 `namespace == SVG` 且已知元素、且属性属于无命名空间/SVG 命名空间时校验；`x:rect fill="var(--x)"` 与 `rect x:fill` 在严格模式均可解析。 |
| W-3.7 `javascript:` / `file:` | 已修复 | `allowExternalReferences` 只放行 `http:`/`https:`/`//`；`javascript:`/`file:` 仍由 `unsafePolicy` 控制。补放行开关不覆盖危险协议与 Keep 用例。 |
| W-3.8 声明编码 | 已修复 | 写出声明的 `encoding` 跟随 `SvgWriteOptions.charset`，保留 `version`/`standalone`；`writeSvgString` 对非 UTF-8 抛 `InvalidValue`。补用例。 |
| W-3.9 `none slice` 往返 | 已修复 | `toString` 在 `NoAlign && slice` 输出 `"none slice"`；补往返用例。 |
| W-3.12 任意命名空间 `script` | 已修复 | 按 local name 过滤，`foreignObject` 内 XHTML `script` 同样移除；补默认移除与 `allowScript` 用例。 |
| W-4.1 标签表 | 已修复 | `style`/`title`/`desc`/`metadata` 映射为通用 `SvgElement`，不告警、严格模式不拒绝；补用例。 |
| W-4.2 D2 缓存描述 | 已修复（文档） | 设计改为「构建时校验一次；类型化值首次读取时解析并缓存」，模块设计 §5.6 同步。 |
| W-4.3 往返表述 | 已修复（文档） | README（中英）、设计 D6、规格与模块设计统一。 |
| W-3.10 行列号 | 已知限制（文档） | XML 词法/语法错误保留行列；构建期语义/安全错误 `line=column=0`，以 `elementPath` 定位。proposal、README、模块设计已写明。 |
| W-3.11 公开可变列表 | 已知限制（文档） | README 与模块设计明确「写入请用 `setAttr`/`removeAttr`/`appendChild`」、`warnings` 只增。 |
| S-2.2 性能 | 已知限制（文档） | `perf-baseline.md` 与 tasks 17.8 明确仅参考、非门禁，实测未达 25/20 ms。 |
| S-2.4 测试文件命名 | 已知限制（文档） | 设计 D11 注明同一主题测试可合并到主实现同名文件。 |
| S-2.5 死 API | 已修复 | 删除 `SvgPaintServerRef` 及其测试引用，任务 4.3 与模块设计 API 同步。 |
| S-2.6 Git 元数据 | 已知限制（环境） | worktree `.git` 绝对路径在融合侧不可用；本次通过显式 `GIT_DIR`/`GIT_WORK_TREE` 在 `feature/f_svg` 完成提交。 |
| S-3.13 易修项 | 已修复 | 尾逗号已有拒绝用例并补充变体；`elementsByTag` 只返回后代；CDATA `]]>` 与注释 `--` 安全序列化；`xlink=false` 只折叠 SVG/XLink；`SvgDocument.toString` 走 `SvgWriter` 默认选项。 |
| 2.3 规格场景覆盖缺口 | 已补齐 | 新增五入口完整快照（含声明/DOCTYPE/注释/PI/实体）、外部实体拒绝、外部 DTD 子集不加载用例；URL 属性、`#rrggbbaa`、高精度、`none slice`、外部命名空间已在 C-1/C-2/W 项覆盖。 |

| **W-1** 复验：URL 过滤命名空间边界 | 已修复 | 安全过滤只看 SVG 命名空间元素/属性；外部命名空间属性原样保留；补 `foreignNamespaceUrlAttributePreserved`。 |
| **W-2** 复验：`style` / `<style>` 外部 URL | 已修复 | 扫描 `style` 属性与 `<style>` 内容中的 `url(...)` / `@import`，按 `unsafePolicy` 处理；补 `cssExternalUrlsRemoved`。 |
| **W-3** 复验：`xml:base` | 已修复 | `xml:base` 默认移除/按策略处理，避免 `#id` 被重定位到外部文档；补 `xmlBaseRemoved`。 |
| **W-4** 复验：`allowExternalReferences` 作用域 | 已修复（文档） | README（中英）与安全规格明确：该开关只作用于 `href`，URL 型属性由 `unsafePolicy` 控制。 |
| **W-5** 复验：注释/示例 | 已修复（文档） | `SvgLength` 注释改为「规范形式可表示」；README 的 fallback 示例改为 `Some(SvgPaint.None)`。 |

### 验收结果

- `cjpm test`：**216 passed / 0 failed**（新增用例计入）。
- `cjpm build`：成功；`f_svg` 自身 **0 warning**（22 条 warning 均来自 `f_xml` 依赖）。
- `openspec validate add-f-svg-module --strict`：当前环境未安装 `openspec` 命令，无法执行。
- 提交（`feature/f_svg`）：`2ad52ea9`、`73d8e69c`、`283f2b49`、`fce6c4b3`、`68deb66f`、`f22cf490`、`9668fddb`。
