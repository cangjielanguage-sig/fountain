# svg-document-model

## ADDED Requirements

### Requirement: M3 类型化元素

系统 SHALL 把下列标签映射为类型化元素，而不是 `SvgUnknownElement` 或仅具通用属性的容器：

- `filter` → `SvgFilter`；
- `pattern` → `SvgPattern`（`SvgContainerKind.Pattern`）；
- `marker` → `SvgMarker`（`SvgContainerKind.Marker`）；
- `textPath` 继续映射为 `SvgTextPath`。

`SvgPattern` 与 `SvgMarker` SHALL 保持 `SvgContainer` 的既有行为（子节点、`kind`、标签名回写）；`SvgContainerKind` 的枚举值 SHALL NOT 增删或改名。

#### Scenario: filter 类型化

- **WHEN** 解析 `<filter id="f"><feGaussianBlur stdDeviation="2"/></filter>`
- **THEN** 得到 `SvgFilter`，`primitives.size == 1` 且首个元素为 `SvgFeGaussianBlur`

#### Scenario: pattern 兼容

- **WHEN** 解析 `<pattern id="p" width="10" height="10"/>`
- **THEN** 结果为 `SvgPattern`，同时 `is SvgContainer` 为真，`kind == SvgContainerKind.Pattern`

#### Scenario: 属性往返

- **WHEN** 设置 `filterUnits="userSpaceOnUse"`、`primitiveUnits="objectBoundingBox"` 后写回再解析
- **THEN** 两个属性与设置值一致

### Requirement: M3 滤镜原语元素

`filter` 的 `fe*` 子标签 SHALL 各映射为独立类型：`feGaussianBlur` / `feOffset` / `feFlood` / `feBlend` / `feComposite` / `feMerge` / `feColorMatrix` / `feTile` → 对应 `SvgFe*` 类型；`feMergeNode` → `SvgFeMergeNode`。

#### Scenario: 原语类型化

- **WHEN** 解析含全部 8 种 `fe*` 子元素的 `<filter>`
- **THEN** 每个子元素都得到对应的 `SvgFe*` 类型，`primitives.size == 8`

### Requirement: M3 元素子节点与往返

`SvgFilter` 的 `primitives` SHALL 按文档顺序收集 `fe*` 子元素；非 `fe*` 子元素 SHALL 保留在普通子节点列表中并记 warning。

所有新元素 SHALL 可解析、可修改、可无损写回；未知属性 SHALL 按 M1 规则原样保留，属性顺序不变。

#### Scenario: 非 fe 子元素

- **WHEN** `<filter>` 内混入 `<rect/>`
- **THEN** `rect` 不进入 `primitives`，`warnings` 含一条告警


### Requirement: SVGZ 容器入口

系统 SHALL 提供以下入口：

- `SvgParser.parseAuto(bytes, options!)`：前两字节为 `1F 8B` 时按 gzip 解压后解析，否则按 UTF-8 文本解析；
- `SvgParser.parseGzip(bytes, options!)`：强制按 gzip 解压后解析；
- `writeGzip(document)`：把文档写成 gzip 压缩的 SVG 字节。

`parseGzip` 遇到非 gzip 输入、截断 gzip 或损坏 gzip 时 SHALL 抛 `SvgException(kind: Syntax)`；`parseAuto` 命中魔数但解压失败时 SHALL 抛 `Syntax`，不得静默回退为文本。

#### Scenario: parseAuto 识别

- **WHEN** 同一文档分别以纯文本与 gzip 字节传入 `parseAuto`
- **THEN** 两次得到的根元素、属性与文本内容一致

#### Scenario: 纯文本不误判

- **WHEN** 纯文本 SVG 的前两字节不是 `1F 8B`
- **THEN** 直接按文本解析，不做解压

#### Scenario: 截断 gzip

- **WHEN** 输入以 `1F 8B` 开头但数据被截断
- **THEN** 抛 `SvgException(kind: Syntax)`

### Requirement: SVGZ 上限与输出确定性

解压后的字节 SHALL 继续受 `SvgParseOptions` 的 `security.maxElements`、`security.maxDepth` 与 `f_xml` 上限约束。

解压输出超过 `SvgSecurityOptions.maxDecompressedBytes`（新增字段，缺省 64 MiB）时 SHALL 抛 `SvgException(kind: Limit)`。

`writeGzip` SHALL 使用 `WrapType.GzipFormat`，gzip 头 mtime 固定为 0；同一文档多次调用 SHALL 产生逐字节一致的输出。

#### Scenario: gzip 往返

- **WHEN** `writeGzip(document)` 的输出传给 `parseGzip`
- **THEN** 解析结果与原文结构等价

#### Scenario: 压缩炸弹

- **WHEN** 解压输出超过 `maxDecompressedBytes`
- **THEN** 抛 `SvgException(kind: Limit)`，解析停止

#### Scenario: 输出确定性

- **WHEN** 对同一文档连续调用 `writeGzip` 两次
- **THEN** 两次字节数组完全相等
