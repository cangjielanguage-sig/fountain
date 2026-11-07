# svg-security

## MODIFIED Requirements

### Requirement: 渲染期无外部访问

渲染器 SHALL NOT 发起网络请求、打开外部文件、执行脚本或按路径读取图像。

CSS 与画笔中的 `url(...)` SHALL 只接受 `#id` 片段；外部形式 SHALL 按无画笔处理并记 warning。

`<image>` 的外部资源 SHALL 只允许两种来源：

1. `data:image/png;base64,` 内联字节（受 `allowDataImages` 与 base64 长度上限约束）；
2. 调用方显式注入的 `SvgImageResourceProvider.resolve(href)` 返回值。

未注入 provider、provider 返回 `None` 或解码失败时，`<image>` SHALL 绘制占位并记 warning；库内不得自行按 `href` 访问网络或文件系统。

`SvgImageResourceProvider` 的安全责任由调用方承担；`f_svg` SHALL 在文档中声明该边界。

M6 新增两类调用方 provider：`SvgForeignObjectRenderer` 与 `SvgExternalDocumentProvider`。两者 SHALL 只在调用方显式注入时使用；库内 SHALL NOT 自行解析 XHTML、访问网络或读取文件。外部文档 SHALL 使用与主文档相同的 `SvgParseOptions.security` 解析，且 SHALL NOT 因外部文档中的引用再次触发外部加载。

`begin="click"` 等事件型动画 SHALL 保留为待触发项，但渲染 SHALL NOT 等待或分发 UI 事件；只有调用方显式 `fireEvent` 才触发。

#### Scenario: 外部 CSS 引用

- **WHEN** 样式表声明 `fill: url(https://example.com/a.svg#g)`
- **THEN** 渲染成功，该填充按 `none` 处理，产生 warning，无网络请求

#### Scenario: 外部图片

- **WHEN** `<image href="file:///etc/passwd"/>`
- **THEN** 渲染成功，仅绘制占位，未打开文件

#### Scenario: 未注入图片资源

- **WHEN** `<image href="file:///etc/passwd"/>` 且 `images = None`
- **THEN** 渲染成功，仅绘制占位，未打开文件

#### Scenario: 注入 provider

- **WHEN** 调用方注入只识别 `mem://` 前缀的 provider
- **THEN** 只有 `mem://` 请求被交给 provider，其他 href 仍按占位处理

#### Scenario: 动画不执行脚本

- **WHEN** 文档含 `begin="click"` 的动画，渲染器未收到 `fireEvent`
- **THEN** 动画不活动，渲染立即完成，不注册任何事件监听

#### Scenario: 外部文档不递归加载

- **WHEN** provider 返回的外部文档自身含指向另一外部文档的 `use`
- **THEN** 库内不再调用 provider，按缺失引用 warning，不联网

#### Scenario: foreignObject 不经库渲染

- **WHEN** 未注入 `SvgForeignObjectRenderer`
- **THEN** 不解析 `foreignObject` 的 XHTML 子节点，绘制透明占位并 warning

## ADDED Requirements

### Requirement: M6 上限与降级

系统 SHALL 在解析、布局或命中前检查下列上限，并按指定方式处理：

- 单个外部文档字节：16 MiB，超限抛 `Limit`；
- GSUB 上下文链式 lookup 深度：8，超限停止该分支并 warning；
- `font-feature-settings` 条目：64，超限忽略多余条目并 warning；
- 变更监听器数量：32，超限抛 `InvalidValue`；
- `discard` 嵌套深度：1，超限只处理最外层并 warning；
- 命中测试元素数：受 `SvgSecurityOptions.maxElements` 约束，超限抛 `Limit`。

所有检查 SHALL 发生在分配大缓冲或进入递归循环之前；warning SHALL 包含可定位的表名、属性名或元素。

#### Scenario: 外部文档字节

- **WHEN** provider 返回 16 MiB + 1 字节
- **THEN** 抛 `Limit`，不解析该字节数组

#### Scenario: 特性条目上限

- **WHEN** `font-feature-settings` 声明 65 条
- **THEN** 前 64 条生效，多余条目被忽略并 warning

#### Scenario: 监听器上限

- **WHEN** 注册第 33 个变更监听器
- **THEN** 抛 `InvalidValue`，前 32 个仍工作

#### Scenario: discard 嵌套

- **WHEN** `discard` 内嵌套另一个 `discard`
- **THEN** 只处理最外层并 warning

#### Scenario: 命中测试规模

- **WHEN** 文档元素数超过 `maxElements` 后调用命中测试
- **THEN** 抛 `Limit`，不遍历全部元素
