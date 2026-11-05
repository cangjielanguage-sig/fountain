# add-f-svg-module

## Why

fountain 目前只有 `f_xml` 这一层通用 XML 能力：它能解析、遍历、写入任意 XML，但对 SVG 一无所知——`<rect width="10">` 的 `width` 只是一段字符串，`d="M0 0L10 10"` 只是一个属性值，调用方必须自己解析长度单位、颜色、变换、路径语法，还要自己判断哪些内容是危险的。

实际需求已经出现：文档站点要读写 `.assets/**.svg`，后台要接受用户上传的 SVG 并安全地存储/回写，未来的图元工具要做批量属性改写。把这些逻辑散落在业务代码里会重复且不可靠；塞进 `f_xml` 又会污染通用 XML 模块。

因此新增 `fountain::f_svg`：在 `f_xml` 之上提供 SVG 1.1 **静态文档**的类型化模型、解析与生成。M1 只解决「把文档讲清楚、改对、写回去」，不涉及像素。

## What Changes

- 新增模块 `f_svg`（包名 `fountain::f_svg`），唯一硬依赖 `fountain::f_xml` 与 `fountain::f_base`。
- 新增值类型层：`SvgLength`、`SvgColor`、`SvgPaint`、`SvgMatrix`、`SvgTransform`、`SvgPathData`、`SvgViewBox`、`SvgPreserveAspectRatio`、`SvgPointList`、`SvgNumberList`，以及规范数字格式化 `formatSvgNumber`。
- 新增类型化模型：`SvgNode`、`SvgAttribute`、`SvgElement`、`SvgRoot`、`SvgContainer`、七种形状、三种文本元素、两种渐变与 `SvgStop`、`SvgUse`、`SvgImage`、`SvgUnknownElement`、`SvgDocument`。
- 新增解析入口 `SvgParser`（`InputStream` / `bytes` / `text` / `Path` / 已解析 `XmlDocument` 五种重载），内部复用 `f_xml::XmlParser`。
- 新增生成入口 `SvgWriter` 与 `writeSvgString`，内部构造 `XmlDocument` 后交给 `f_xml::XmlWriter`。
- 新增安全策略：默认移除 `<script>`、`on*` 事件属性、外部引用与 `javascript:` 协议，并逐条写入 `SvgDocument.warnings`；元素数/深度上限硬失败。
- 新增 `SvgException`（`Syntax` / `InvalidValue` / `Unsupported` / `Security` / `Limit`），保留行列与元素路径。
- 登记发布：根 `.modules` 的 `[include]`、根 `cjpm.toml` 的 `[dependencies]`、中英文 README 的模块清单。

**明确不做（M1 边界）**：渲染/光栅化、CSS 解析与级联、SMIL 动画、滤镜、SVGZ、`foreignObject` 内部 XHTML 语义、字体度量、流式增量输出。`<style>` 与 `style=""` 原样保留但不解释。

## Impact

- **Affected specs**：`svg-value-types`（新增）、`svg-document-model`（新增）、`svg-security`（新增）。
- **Affected code**：
  - 新增 `f_svg/`（`cjpm.toml`、`src/`、`doc/`、`testdata/`、中英文 README）；
  - 修改根 `cjpm.toml`（增加 `"fountain::f_svg" = {path = "./f_svg"}`）；
  - 修改根 `.modules`（`[include]` 增加 `f_svg`）；
  - 修改根 `README.md` / `README_en.md` 的模块表。
- **不修改** `f_xml`：M1 不新增跨模块 API；`f_xml::XmlWriter` 的 `comment` / `cdata` 增量方法属于 M2 流式输出议题，单独评审。
- **不登记** `src/f_svg` 聚合根 shim（聚合根已冻结）。
- **兼容性**：纯新增，无既有行为变更；不引入任何第三方依赖。
- **验收锚点**：六个样本 `parse → write → parse` 结构等价；安全用例符合 `svg-security`；`cjpm test` 全绿且 `cjpm build` 无新增 warning。

## Non-goals

- 任何需要像素的判定（包围盒、填充规则求值、文本排版）不在 M1。
- 不把 SVG 语义下沉到 `f_xml`，也不在 `f_svg` 里重写 XML 词法器。
- 不追求字节级往返：空元素写法、引号风格、缩进、XML 声明允许不同，只要求结构等价。
