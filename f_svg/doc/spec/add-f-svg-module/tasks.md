# 任务：add-f-svg-module（M1）

> 每个任务按 Red-Green-Refactor 推进：先写失败用例并确认失败原因正确，再写最小实现，最后重构。
> 每个阶段结束时 `cjpm test` 必须是绿的，且该阶段的产物独立提交。

## 1. 模块骨架与发布登记

- [ ] 1.1 创建 `f_svg/` 目录与 `cjpm.toml`：`name = "f_svg"`、`organization = "fountain"`、`cjc-version = "1.2.0"`、`version = "1.3.17"`、`output-type = "dynamic"`、`compile-option = "--dy-std -O2"`，依赖 `fountain::f_base` 与 `fountain::f_xml`
- [ ] 1.2 补齐 `cjpm.toml` 的 target 段（linux / mingw / darwin / ohos，含 `-ldl` 变体）与 `include` / `exclude` / `profile.build`，与 `f_xml/cjpm.toml` 保持同构
- [ ] 1.3 新增 `f_svg/src/f_svg.cj`（包声明 `package fountain::f_svg`）与 `SvgNamespaces.cj`
- [ ] 1.4 新增 `SvgException.cj`：`SvgErrorKind`、`SvgException <: BaseException`，支持带/不带位置两种构造
- [ ] 1.5 根 `.modules` 的 `[include]` 在 `f_xml` 之后增加 `f_svg`
- [ ] 1.6 根 `cjpm.toml` 的 `[dependencies]` 增加 `"fountain::f_svg" = {path = "./f_svg"}`
- [ ] 1.7 验证 `cjpm build` 能编出空模块，`cjpm test` 跑通空测试集

## 2. 数值与长度（M1.1）

- [ ] 2.1 先写 `SvgNumber_test.cj`：`formatSvgNumber` 的整数、小数、尾零、`-0.0`、`1e-9`、超 6 位小数、`NaN`/`Inf` 抛错
- [ ] 2.2 实现 `formatSvgNumber`
- [ ] 2.3 先写 `SvgLength_test.cj`：全部单位、大小写、前后空白、负数、空串、非法单位、`NaN`/`Inf`、超长数字
- [ ] 2.4 实现 `SvgLength` / `SvgLengthUnit` 的 `parse` / `tryParse` / `toString`
- [ ] 2.5 先写换算用例：px/in/cm/mm/pt/pc/em/ex 与三种轴的百分比，含 200×100 视口的水平/垂直/对角线断言
- [ ] 2.6 实现 `SvgLengthContext`、`SvgLengthAxis`、`toUserUnits`

## 3. 颜色（M1.1）

- [ ] 3.1 先写 `SvgColor_test.cj`：`#rgb` / `#rrggbb` / `#rrggbbaa`、大小写、`rgb` 逗号与空格语法、百分比分量、越界钳制、`rgba` 百分比 alpha、`hsl` 六个色相区、`hsla`、`transparent`
- [ ] 3.2 先写失败用例：`none`、未知色名、空串、分量个数错误
- [ ] 3.3 实现命名色表（CSS3 147 色 + `transparent`，静态数组 + 线性扫描 + 大小写归一）
- [ ] 3.4 实现 `SvgColor` 的 `parse` / `tryParse` / `fromRgb` / `fromHsl` / `toString`
- [ ] 3.5 补充 `parse(toString(x)) == x` 往返用例（跳过 alpha ≠ 1 的 hex 输入）

## 4. 画笔（M1.1）

- [ ] 4.1 先写 `SvgPaint_test.cj`：`none` / `currentColor` / 颜色 / `url(#id)` / 带引号 `url("#id")` / 三种 fallback
- [ ] 4.2 先写失败用例：`url("http://...")`、非法 `url()`、空串
- [ ] 4.3 实现 `SvgPaint` / `SvgPaintKind` / `SvgPaintServerRef`，外部引用抛 `SvgException(kind: Security)`
- [ ] 4.4 确保 `SvgPaint.parse` 无任何 I/O 依赖（代码审查项）

## 5. 矩阵与变换（M1.2）

- [ ] 5.1 先写 `SvgMatrix_test.cj`：`identity`、`multiply` 结合律、`apply`、`determinant`、`invert` 往返、不可逆返回 `None`
- [ ] 5.2 实现 `SvgPoint` / `SvgMatrix` 及六个工厂方法
- [ ] 5.3 先写 `SvgTransform_test.cj`：单变换、多变换顺序（`translate(10,20) scale(2)` 作用于 `(1,1)` ⇒ `(12,22)`）、缺省参数、负角度、`matrix` 六参数、未知函数、空串、非法数字
- [ ] 5.4 实现 `SvgTransformOp` / `SvgTransform` 的 `parse` / `toMatrix` / `toString`

## 6. 路径（M1.2）

- [ ] 6.1 先写 `SvgPathData_test.cj` 的十个命令绝对/相对用例与参数个数校验
- [ ] 6.2 先写词法边界用例：`M1-2`、`0.5.5`、`1e3` / `1E-3`、`A5 5 0 0110 10`、逗号与空白混用、双逗号、`Z` 后数字、空路径
- [ ] 6.3 实现路径扫描器（单遍状态机，带位置信息）与 `SvgPathCommand` / `SvgArcParams`
- [ ] 6.4 实现 `M` 后隐式 `L` 的重复展开
- [ ] 6.5 先写 `toAbsolute` 用例：当前点/子路径起点、`H/V` 转 `L`、`A` 只转终点、相对 `S/T`
- [ ] 6.6 实现 `toAbsolute()`
- [ ] 6.7 实现 `toString` 规范序列化并验证往返

## 7. 视口与列表（M1.2）

- [ ] 7.1 先写 `SvgViewBox_test.cj`：四参数、逗号/空白、负宽高、零宽高
- [ ] 7.2 实现 `SvgViewBox`
- [ ] 7.3 先写 `SvgPreserveAspectRatio_test.cj`：九种对齐、`meet` / `slice`、`none`、非等比视口、退化视口
- [ ] 7.4 实现 `SvgPreserveAspectRatio` 与 `toMatrix`
- [ ] 7.5 先写 `SvgPointList_test.cj` / `SvgNumberList_test.cj`：奇偶个数、分隔符混用
- [ ] 7.6 实现 `SvgPointList` / `SvgNumberList` / `SvgListSeparator`

## 8. 模型基础（M1.3）

- [ ] 8.1 先写 `SvgElement_test.cj`：构造、`attr` / `setAttr` / `removeAttr`、同名原位替换、追加顺序
- [ ] 8.2 实现 `SvgNode` / `SvgAttribute` / `SvgNamespaces`
- [ ] 8.3 实现 `SvgElement` 的属性与子节点 API、`parent` 维护
- [ ] 8.4 先写 `text()` 与 `elementPath()` 用例（含同名兄弟编号）
- [ ] 8.5 实现 `text()` / `elementPath()` / `toXmlElement()` / `toString()`
- [ ] 8.6 先写缓存失效用例：`setAttr` 后类型化读取返回新值，`removeAttr` 后返回 `None`
- [ ] 8.7 实现 `attributesVersion` 与类型化缓存基础设施

## 9. 根与容器（M1.3）

- [ ] 9.1 先写 `SvgRoot_test.cj`：`width/height/x/y/viewBox/preserveAspectRatio` 读写与缺省
- [ ] 9.2 实现 `SvgRoot`
- [ ] 9.3 先写 `SvgContainer_test.cj`：十种 `SvgContainerKind` 的标签映射
- [ ] 9.4 实现 `SvgContainer` 与 `SvgContainerKind`

## 10. 形状（M1.3）

- [ ] 10.1 先写 `SvgShape_test.cj`：绘制属性读写、`strokeDashArray` 的 `none` 与列表、`fillRule` / `strokeLineCap` / `strokeLineJoin` 枚举
- [ ] 10.2 实现 `SvgShape`、三个枚举与绘制属性访问器
- [ ] 10.3 逐个实现 `SvgRect` / `SvgCircle` / `SvgEllipse` / `SvgLine` / `SvgPolyline` / `SvgPolygon` / `SvgPath`，每个配套几何属性用例

## 11. 文本（M1.4）

- [ ] 11.1 先写 `SvgTextElement_test.cj`：`x/y/dx/dy` 列表、单值转单元素、`rotate` 列表、字体属性
- [ ] 11.2 实现 `SvgTextElement`、`SvgTextAnchor`、`SvgLengthAdjust`
- [ ] 11.3 实现 `SvgText` / `SvgTspan` / `SvgTextPath`，后者的 `href` 与 `startOffset` 配套用例

## 12. 渐变、引用与图片（M1.4）

- [ ] 12.1 先写 `SvgGradient_test.cj`：`gradientUnits` / `gradientTransform` / `spreadMethod` / `href`、线性与径向几何属性
- [ ] 12.2 实现 `SvgGradient` / `SvgLinearGradient` / `SvgRadialGradient` / `SvgCoordinateUnits` / `SvgSpreadMethod`
- [ ] 12.3 先写 `SvgStop_test.cj`：`50%`、`1.5`、`-0.2` 的归一与钳制、`currentColor` 保留、`stopOpacity`
- [ ] 12.4 实现 `SvgStop`
- [ ] 12.5 先写 `SvgUse_test.cj` / `SvgImage_test.cj`：`href` 与 `xlink:href` 双写法读取、写侧 `xlink` 开关
- [ ] 12.6 实现 `SvgUse` / `SvgImage`

## 13. 未知元素与文档（M1.4）

- [ ] 13.1 先写 `SvgUnknownElement_test.cj`：非 SVG 命名空间、前缀/URI/属性/子树完整保留
- [ ] 13.2 实现 `SvgUnknownElement`
- [ ] 13.3 先写 `SvgDocument_test.cj`：`elementById` 首匹配、`elementsByTag` 跨命名空间、`warnings` 累积
- [ ] 13.4 实现 `SvgDocument` 与 `toXmlDocument()`

## 14. 解析器（M1.5）

- [ ] 14.1 先写 `SvgParser_test.cj` 的五个入口等价用例（文本 / 字节 / 流 / 路径 / `XmlDocument`）
- [ ] 14.2 实现 `SvgParser` 五个重载与 `SvgParseOptions` / `SvgSecurityOptions` 定义
- [ ] 14.3 实现 `SvgTag` 表驱动映射
- [ ] 14.4 先写命名空间用例：任意前缀、无命名空间子元素继承、根命名空间非法
- [ ] 14.5 实现 `SvgBuilder` 的元素归属判定与命名空间规范化
- [ ] 14.6 先写严格/宽松用例：未知标签、非法属性值、缺必需属性、外部引用
- [ ] 14.7 实现严格/宽松分支与 warning 收集
- [ ] 14.8 先写错误定位用例：`XmlException` 包装后的 `kind`、行列、`elementPath`
- [ ] 14.9 实现 `SvgException` 包装与构建器路径栈

## 15. 生成器（M1.6）

- [ ] 15.1 先写 `SvgWriter_test.cj`：紧凑/缩进、`xmlDeclaration`、`trailingNewline`、`charset`
- [ ] 15.2 实现 `SvgWriterOptions`、`SvgWriter`、`writeSvgString`
- [ ] 15.3 先写命名空间用例：根 `xmlns`、`xmlns:xlink`、未知前缀声明
- [ ] 15.4 实现 `SvgDocument` → `XmlDocument` 的递归构造与 `f_xml::XmlWriter` 调用
- [ ] 15.5 先写结构等价往返用例（六个样本）与紧凑模式二次写入字节稳定用例
- [ ] 15.6 修复往返暴露的问题并补测试

## 16. 安全（M1.7）

- [ ] 16.1 先写 `unsafe.svg` 驱动的用例表：脚本、事件属性、外部 `href`、协议相对、`javascript:`、`data:` 图片、片段引用
- [ ] 16.2 实现 `SvgUnsafePolicy` 与构建期过滤，逐条写 warning
- [ ] 16.3 先写开关用例：`allowScript` / `allowEventAttributes` / `allowExternalReferences` / `allowDataImages` 的独立生效
- [ ] 16.4 先写上限用例：元素数 1,000,001、深度 513、宽松模式仍抛 `Limit`
- [ ] 16.5 实现元素数/深度计数与 `Limit` 抛出，透传 `f_xml::EntityLimits`

## 17. 样本与端到端（M1.8）

- [ ] 17.1 编写 `testdata/basic-shapes.svg`（七种形状 + 分组 + 变换）
- [ ] 17.2 编写 `testdata/text.svg`、`testdata/gradient.svg`
- [ ] 17.3 编写 `testdata/namespaces.svg`（默认命名空间 + `xlink` + 编辑器私有命名空间）
- [ ] 17.4 编写 `testdata/comments.svg`（注释 / PI / CDATA / DOCTYPE）
- [ ] 17.5 编写 `testdata/unsafe.svg`（脚本 / 事件 / 外链）
- [ ] 17.6 新增 `SvgRoundTrip_test.cj`：六个样本 `parse → write → parse` 结构等价
- [ ] 17.7 新增大样本冒烟：`.assets/README/module-dependencies.svg` 存在时跑往返与耗时统计，不存在时打印「已跳过」
- [ ] 17.8 记录性能基准（解析 ≤ 25 ms、序列化 ≤ 20 ms、峰值内存 ≤ 8× 输入，仅作参考不作门禁）

## 18. 文档与验收（M1.8）

- [ ] 18.1 写 `f_svg/README.md` 与 `README_en.md`，覆盖安装、解析、构造、生成、安全选项
- [ ] 18.2 核对 README 与 `doc/f_svg模块设计.md` 的公开 API 一致，修正漂移
- [ ] 18.3 根 `README.md` / `README_en.md` 增加 `f_svg` 条目
- [ ] 18.4 `cjpm build` 无新增 warning
- [ ] 18.5 `cjpm test` 全绿
- [ ] 18.6 对照 `specs/svg-value-types`、`specs/svg-document-model`、`specs/svg-security` 逐条确认场景有对应用例
- [ ] 18.7 按 `AGENTS.md` 的 Git 流程在建好的 feature 分支上提交，不直接落在 `master`
