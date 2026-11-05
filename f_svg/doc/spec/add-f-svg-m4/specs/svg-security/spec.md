# svg-security

## ADDED Requirements

### Requirement: M4 滤镜上限

以下上限 SHALL 在分配缓冲或执行计算前检查，超限 SHALL 抛 `SvgException(kind: Limit)`：

- `feConvolveMatrix` 的 `order` 任一维超过 9；
- `feTurbulence` 的 `numOctaves` 超过 8；
- `feImage` 与 `<image>` 共享单次渲染累计解码像素预算，超出时抛 `Limit`。

`feImage` 的 `data:` 长度 SHALL 复用 `<image>` 的 base64 长度上限；非法参数与不可用资源 SHALL 降级为 warning，不抛异常。

#### Scenario: 卷积核超限

- **WHEN** `order="9 10"`
- **THEN** 抛 `SvgException(kind: Limit)`，未分配卷积缓冲

#### Scenario: 倍频超限

- **WHEN** `numOctaves="9"`
- **THEN** 抛 `SvgException(kind: Limit)`

#### Scenario: 解码预算共享

- **WHEN** 同一渲染中 `<image>` 与 `feImage` 的累计解码像素超过预算
- **THEN** 抛 `SvgException(kind: Limit)`，后续解码不执行

### Requirement: TrueType 解析上限

TTF 解析 SHALL 在读取表数据前检查：表目录项数 ≤ 64、单表长度 ≤ 16 MiB、单字形点数 ≤ 10000、复合字形递归深度 ≤ 8。超限 SHALL 抛 `SvgException(kind: Limit)`。

`loca` 表非单调、表偏移越界、必需表缺失或数据截断 SHALL 抛 `SvgException(kind: Syntax)`；CFF / OTF 轮廓 SHALL 抛 `SvgException(kind: Unsupported)`。

#### Scenario: 表数超限

- **WHEN** 表目录声明 65 个表
- **THEN** 抛 `SvgException(kind: Limit)`，未读取表体

#### Scenario: 单表过长

- **WHEN** 某表长度超过 16 MiB
- **THEN** 抛 `SvgException(kind: Limit)`

#### Scenario: 字形点数超限

- **WHEN** 简单字形声明超过 10000 个点
- **THEN** 抛 `SvgException(kind: Limit)`

#### Scenario: loca 非单调

- **WHEN** `loca` 后一项小于前一项
- **THEN** 抛 `SvgException(kind: Syntax)`

### Requirement: 字体加载边界

字体字节 SHALL 只由调用方显式提供：`SvgTrueTypeFont.parse(bytes)` 或调用方显式调用 `SvgTrueTypeFont.load(path)`。

渲染过程 SHALL NOT 读取字体文件、按 `font-family` 访问文件系统或网络；文档内容 SHALL NOT 触发任何字体加载。

`load` 只读取传入路径，不存在或不可读时 SHALL 抛 `SvgException(kind: Syntax)`，该安全责任由调用方承担并在文档中声明。

#### Scenario: 渲染不加载文件

- **WHEN** 文档 `font-family="file:///etc/fonts/x.ttf"` 且注册表未注册该字体
- **THEN** 渲染按占位字形处理并 warning，不打开文件

#### Scenario: 显式加载失败

- **WHEN** `SvgTrueTypeFont.load(Path("missing.ttf"))`
- **THEN** 抛 `SvgException(kind: Syntax)`，不抛裸 IO 异常

### Requirement: switch 规模约束

`switch` SHALL NOT 引入额外数量限制，其子元素仍受 `SvgSecurityOptions.maxElements` 与 `maxDepth` 约束；条件求值 SHALL NOT 递归访问文档外资源。

#### Scenario: 元素总数仍受限

- **WHEN** 文档含大量 `switch` 子元素并使总元素数超过 `maxElements`
- **THEN** 解析阶段抛 `SvgException(kind: Limit)`
