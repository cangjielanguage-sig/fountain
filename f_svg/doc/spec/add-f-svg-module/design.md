# 设计：f_svg（M1）

## Context

`fountain::f_xml` 已经提供完整的 XML 1.0 能力：`XmlParser.parse` 的流/字节/文本/路径入口、`XmlDocument` / `XmlElement` / `XmlNode` DOM、`QName` 展开名比较、`XmlWriter` 的树模式与增量模式、`XmlWriterOptions`（`indent` / `cdata` / `charset` / `onInvalidChar` / `strictEntities` / `doctype`）、`XmlException` 的 1-based 行列，以及实体与深度的安全上限。

缺的是 SVG 语义：长度单位、颜色语法、画笔引用、变换矩阵、路径语法、视口映射、元素分类，以及面向不可信内容的安全策略。这些都不属于通用 XML，必须单独成层。

本设计基于仓库内 `f_svg/doc/f_svg模块设计.md`，把 M1 的决策、边界和实现约束落成可执行的方案。M1 的产出是「文档模型 + 解析 + 生成 + 安全过滤」，任何需要像素的能力都留给 M2。

## Goals / Non-Goals

**Goals**

1. SVG 1.1 静态文档的结构无损往返（`parse → write → parse` 结构等价）。
2. 常用属性的类型化访问：`SvgLength`、`SvgColor`、`SvgPaint`、`SvgTransform`、`SvgPathData`、`SvgViewBox`。
3. 形状 / 文本 / 渐变 / `use` / `image` 的独立模型类型。
4. 未知元素、未知属性、外部命名空间原样保留。
5. 面向不可信输入的默认安全过滤与规模上限，且可审计。
6. 解析 / 生成错误的行、列、元素路径定位。

**Non-Goals（M1 不做）**

- 渲染与光栅化、路径包围盒、填充规则求值。
- CSS 解析与级联（`<style>` / `style=""` 原样保留）。
- SMIL 动画、滤镜、SVGZ、`foreignObject` 内部 XHTML 语义、字体度量、流式增量输出。
- 任何对 `f_xml` 公开 API 的修改。

## 架构

```
SvgParser / SvgWriter / SvgDocument / SvgElement 及子类      公共 API
        │
SvgLength / SvgColor / SvgPaint / SvgTransform / SvgPathData   值类型
SvgViewBox / SvgPreserveAspectRatio / SvgPointList / SvgNumberList
        │
SvgTag 表驱动映射 / 属性分类与缓存 / 安全检查 / 错误定位        语义层
        │
f_xml：XmlParser / XmlDocument / XmlElement / QName / XmlWriter
        │
f_base：BaseException / StringGenerator
```

三条数据流：

- 解析：`InputStream | bytes | String | Path | XmlDocument` → `f_xml` DOM → `SvgBuilder` 单次 DFS → `SvgDocument`。
- 构造：`SvgRoot` / 具体元素 + setter → `SvgDocument`。
- 生成：`SvgDocument` → 构造 `XmlDocument` → `f_xml::XmlWriter` → `OutputStream | String`。

## Decisions

### D1. 独立模型 + 显式映射，不做 `XmlElement` 薄包装

`SvgElement` 持有自己的 `tag`、`namespace`、`attributes`、`children`、`parent`，通过 `toXmlElement()` 单向转成 `f_xml` 结构。

理由：公开 API 不泄漏 `QName` 之外 `f_xml` 的细节；类型化属性需要缓存与失效机制，薄包装会出现「raw 改了、缓存没改」的隐式状态；映射是写一次的成本，换来 `f_svg` 独立演进。

代价：未知内容的保留必须显式实现——由 `SvgUnknownElement` 与「未知属性留在 `attributes`」共同保证。

### D2. `attributes` 是唯一事实源，类型化值按版本缓存

`SvgElement.attributes` 保存原始字符串与 `QName`（含前缀），这是**唯一**可写状态。类型化 getter 按需解析并缓存，缓存条目挂在 `attributesVersion: Int64` 上；任何 `setAttr` / `removeAttr` 都会 `version += 1`，旧缓存整体失效。

解析阶段在构建元素的同一次 DFS 里完成已知属性的校验；类型化值不在构建期预置，而是在首次读取时解析并按 `attributesVersion` 缓存。这样每个属性在解析阶段只校验一次，未被访问的属性也不会付出类型化解析成本。

取舍说明：设计文档 §5.6 写作「类型化值存入字段」，§5.6 末注又要求「setter 写原始属性、读取时按需解析并缓存」。二者统一为「原始字符串为准、类型化为派生」，避免双份状态漂移。`SvgDocument.toXmlDocument()` 始终基于 `attributes`，因此往返不依赖缓存是否正确。

### D3. 命名空间按 URI 判定，写侧交给 `f_xml`

- 元素归属看 `QName.uri`，前缀任意；无命名空间的子元素继承父元素的 SVG 命名空间。
- `xlink:href` 按 XLink URI 识别，读取时同时接受 `href` 与 `xlink:href`。
- 写入时根元素 `QName.uri = SVG`，`f_xml::XmlWriter` 会自动输出 `xmlns`；带前缀的未知命名空间按 `QName(prefix, uri)` 自动输出 `xmlns:p`（已确认 `XmlWriter` 的声明逻辑按前缀+URI 输出）。
- `xmlns` 声明不进入模型属性表，避免与 `f_xml` 的命名空间作用域重复。

### D4. 安全过滤在构建期完成

过滤发生在 `SvgBuilder` 把 `XmlElement` 转成模型节点的过程中，而不是建模后再修剪。这样：

- 被移除的内容不会短暂存在于模型里；
- 每条告警都能带上当前 `elementPath()` 与属性名；
- `Reject` 策略可以在最早位置中止。

默认 `Remove` 而不是整份拒绝：SVG 常用于展示用户上传内容，因一个 `<script>` 让整份文档失败会迫使调用方关闭全部过滤。

### D5. 上限硬失败，不随 `strict` 降级

`maxElements` / `maxDepth` 与 `f_xml` 的 `maxElementDepth` 形成双保险；实体上限透传 `EntityLimits`。超限一律 `SvgException(kind: Limit)`。宽松模式只降级「值不合法 / 标签不认识」，绝不降级安全上限。

### D6. 值类型规范化优先于保真

值类型的 `toString` 输出规范形式（最短数字、标准颜色写法、标准命令序列），并对规范形式可表示的值满足 `parse(toString(x)) == x`。原始属性字符串仍保存在 `attributes`，所以「保真往返」看 `attributes`，「语义往返」看值类型。两者互不替代。

已知不保真边界：`|v| < 1e-6` 归零、超过 6 位小数被舍入；`SvgColor` 的 alpha 可由 `0..255` 字节精确表示时输出 `#rrggbbaa`，否则输出 `rgba()`。

`formatSvgNumber` 固定规则：无科学计数法、最多 6 位小数、`-0.0 → 0`、`|v| < 1e-6` 归零、非有限值抛 `InvalidValue`。

### D7. 变换按 `A × B × C` 合成

`transform="A B C"` 的矩阵为 `A × B × C`，点按列向量右乘——最后书写的变换最先作用于坐标。这是 SVG 1.1 的定义，容易与 CSS `transform` 的直觉相反，必须在实现与测试中同时钉死。

### D8. 路径词法用手写扫描器，不用正则

路径数字语法允许符号分隔（`M1-2`）、小数连写（`0.5.5`）、指数、弧标志位连写（`0 0110 10`）。正则难以同时保证「不接受双逗号」「不吞掉下一条命令」这些约束，且回溯成本不可控。实现为单遍字符扫描 + 状态机，加入位置信息便于报错。

### D9. 生成走 `XmlDocument` 中转，M1 接受双份内存

`SvgWriter` 先构造 `XmlDocument`，再调用 `f_xml::XmlWriter.write(doc)`。转义、命名空间、缩进、编码全部复用 `f_xml` 的既有实现，不重复造轮子。代价是模型树与 XML 树短暂共存，M1 接受（目标文档 < 5 MB）。流式输出需要 `f_xml::XmlWriter` 增加 `comment` / `cdata` 增量方法，属于跨模块 API 变更，留到 M2 单独评审。

### D10. 错误统一包装

`f_xml::XmlException` 在 `SvgParser` 边界包装为 `SvgException(kind: Syntax)`，保留原始消息与 1-based 行列。`SvgException` 继承 `f_base::BaseException`，额外携带 `kind`、`line`、`column`、`elementPath`。`elementPath` 由 `SvgBuilder` 维护。

### D11. 文件布局按「一类一文件」对齐 `f_xml`

```
f_svg/
  cjpm.toml
  README.md / README_en.md
  doc/f_svg模块设计.md
  src/
    f_svg.cj                 包声明与公开再导出
    SvgNamespaces.cj
    SvgException.cj
    SvgLength.cj  SvgColor.cj  SvgPaint.cj
    SvgMatrix.cj  SvgTransform.cj  SvgPathData.cj
    SvgViewBox.cj SvgPreserveAspectRatio.cj
    SvgNumber.cj  SvgPointList.cj  SvgNumberList.cj
    SvgNode.cj  SvgAttribute.cj  SvgElement.cj
    SvgRoot.cj  SvgContainer.cj
    SvgShape.cj  SvgRect.cj  SvgCircle.cj ... SvgPath.cj
    SvgTextElement.cj  SvgText.cj  SvgTspan.cj  SvgTextPath.cj
    SvgGradient.cj  SvgLinearGradient.cj ... SvgStop.cj
    SvgUse.cj  SvgImage.cj  SvgUnknownElement.cj
    SvgDocument.cj  SvgTag.cj
    SvgOptions.cj  SvgParser.cj  SvgBuilder.cj
    SvgWriter.cj
    *_test.cj                 与实现同名；同一主题的测试可合并到主实现同名文件
  testdata/
    basic-shapes.svg  text.svg  gradient.svg
    namespaces.svg    comments.svg  unsafe.svg
```

`cjpm.toml` 与 `f_xml` 保持同构：`cjc-version = "1.2.0"`、`version = "1.3.17"`、`output-type = "dynamic"`、`compile-option = "--dy-std -O2"`、各 target 的 `-ldl` 变体、`include = ["src"]`。依赖仅 `fountain::f_base` 与 `fountain::f_xml`。

### D12. 不发布聚合根 shim

根 `cjpm.toml` 只增加 `fountain::f_svg` 依赖项，不在 `src/` 下新增转发 shim——聚合根已冻结，新模块不进入。

## 关键契约

| 契约 | 说明 |
|---|---|
| 未知 ≠ 丢弃 | 仅安全策略明确要求移除的内容会被删 |
| 属性顺序稳定 | 解析按源顺序，构造按赋值顺序，序列化同序 |
| 结构等价往返 | 标签/URI/属性展开名与值/文本/子节点顺序/注释/PI/CDATA 一致 |
| 安全默认移除 | 脚本、事件属性、外部引用；逐条 warning |
| 上限硬失败 | 元素数、深度、实体上限不因宽松模式放行 |
| 值类型自洽 | 对规范形式可表示的值，`parse(toString(x)) == x`；精度边界见 D6 |
| 无 I/O | 解析器不联网、不打开外部文件或外部实体 |

## Risks / Trade-offs

| 风险 | 影响 | 缓解 |
|---|---|---|
| 类型化缓存与原始属性不一致 | 读取到过期值 | 单一 `attributesVersion` 失效；写入路径只经 `attributes`；往返测试只依赖原始属性 |
| 缩进写入产生空白文本节点 | 往返后模型多出空白 | 文档声明该行为；往返测试默认紧凑模式，缩进模式只做结构宽容比较 |
| 未知前缀在写出时被重命名 | 编辑器私有属性外观变化 | `QName` 保留前缀与 URI，`f_xml::XmlWriter` 按原前缀声明 |
| `#rrggbbaa` 等 CSS Color 4 扩展超出 SVG 1.1 | 严格消费方可能不识别 | 仅解析侧接受；`toString` 在 alpha 可由字节精确表示时输出 8 位 hex，其余输出 `rgba()` |
| 双份树内存 | 大文档峰值升高 | M1 接受；性能目标只作回归参考，不做硬门禁；流式输出列 M2 |
| 路径词法边界多 | 解析错位 | 单遍状态机 + 覆盖 §9.2 全部边界的表驱动用例 |

## Testing Strategy

- **值类型**：表驱动单元测试，覆盖设计文档 §9.2 的用例矩阵，外加 `parse(toString(x)) == x` 属性测试式循环。
- **模型**：构造、属性顺序、父子关系、`elementPath`、缓存失效。
- **解析**：标签映射、命名空间三种形态、严格/宽松、错误行列与 `elementPath`。
- **生成**：转义、`xmlns` / `xmlns:xlink`、缩进、编码、`xlink` 开关。
- **安全**：`unsafe.svg` 样本 + 上限用例。
- **端到端**：六个样本 `parse → write → parse` 结构等价；紧凑模式二次写入字节稳定；`.assets/README/module-dependencies.svg` 存在时做往返与性能冒烟，不存在时打印跳过。

所有任务按 Red-Green-Refactor 推进：先写失败用例并确认失败原因正确，再实现最小通过版本，最后重构。

## Migration / Rollout

纯新增模块，无数据迁移。发布登记顺序：`f_svg/cjpm.toml` → 根 `.modules` → 根 `cjpm.toml` → README 中英文。`f_svg` 排在 `f_xml` 之后。

## Open Questions

M1 无阻塞性未决问题。以下均属 M2：渲染后端与目标格式、CSS 解析范围、动画范围、路径包围盒精度、流式输出是否扩展 `f_xml`、`xml:space` 空白折叠、SVGZ 支持。
