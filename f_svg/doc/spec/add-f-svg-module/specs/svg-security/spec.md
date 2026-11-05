# svg-security

## ADDED Requirements

### Requirement: 危险内容默认移除

系统 SHALL 默认移除 SVG 文档中 local name 为 `script` 的元素（不限定命名空间）与所有 `on*` 事件属性（`onload`、`onclick` 等）。

移除动作 SHALL 在构建模型时执行，不得先进入模型再删除；每次移除 SHALL 向 `SvgDocument.warnings` 追加一条包含元素路径与内容类别的告警。

策略 SHALL 由 `SvgSecurityOptions.unsafePolicy` 控制：`Remove`（默认）、`Reject`（抛 `Security`）、`Keep`（保留，调用方自担风险）。

#### Scenario: 移除脚本

- **WHEN** 解析 `<svg><script>alert(1)</script></svg>`
- **THEN** 模型中无 `script` 元素，`warnings` 至少一条包含 `script` 与 `/svg[1]`

#### Scenario: 移除外来命名空间脚本

- **WHEN** 解析 `foreignObject` 内 XHTML 命名空间的 `<script>`
- **THEN** 该元素同样被移除并记录 warning

#### Scenario: 移除事件属性

- **WHEN** 解析 `<rect onload="x()" width="10" height="10"/>`
- **THEN** `onload` 不在 `attributes` 中，其余属性保留

#### Scenario: Reject 策略

- **WHEN** `unsafePolicy = Reject` 且文档含 `<script>`
- **THEN** 抛 `SvgException(kind: Security)`

### Requirement: 外部引用策略

系统 SHALL 默认移除指向外部资源的引用，包括 `http:`、`https:`、`file:`、协议相对 `//`、`javascript:` 以及任何非 `#` 开头的 URL。

同文档片段引用（`#id`）SHALL 保留；`data:` 图片默认允许（由 `allowDataImages` 控制，默认 `true`）。

解析器 SHALL 从不发起网络请求、从不打开外部文件或外部实体。

#### Scenario: 外部 href 被移除

- **WHEN** 解析 `<image href="https://x/y.png"/>`、`<use href="//evil/x.svg#a"/>`、`<use href="javascript:alert(1)"/>`
- **THEN** 三者的 `href` 均被移除并各记一条 warning

#### Scenario: 片段引用保留

- **WHEN** 解析 `<use href="#ok"/>`
- **THEN** `href` 保留为 `#ok`

#### Scenario: data 图片保留

- **WHEN** 解析 `<image href="data:image/png;base64,AAAA"/>`
- **THEN** `href` 保留

### Requirement: 可配置放行

系统 SHALL 提供 `SvgSecurityOptions`：`unsafePolicy`、`allowScript`、`allowEventAttributes`、`allowExternalReferences`、`allowDataImages`，默认值分别为 `Remove`、`false`、`false`、`false`、`true`。

放行开关 SHALL 只影响对应类别，不得连带放宽其他类别。`allowExternalReferences` SHALL 只放行 `http:`、`https:` 与协议相对 `//` 引用，不得放行 `javascript:` 与 `file:`；后两者仍由 `unsafePolicy` 控制。

#### Scenario: 只放行事件属性

- **WHEN** `allowEventAttributes = true` 且文档同时含 `<script>` 与 `onload`
- **THEN** `onload` 保留，`script` 仍被移除

#### Scenario: 放行外部引用

- **WHEN** `allowExternalReferences = true`
- **THEN** `https:` / `//` 引用保留且不记移除告警

#### Scenario: 放行开关不覆盖危险协议

- **WHEN** `allowExternalReferences = true` 且文档含 `javascript:` 与 `file:` 引用
- **THEN** 两者仍按 `unsafePolicy` 移除或拒绝

### Requirement: 规模上限硬失败

系统 SHALL 按 `SvgSecurityOptions.maxElements`（默认 1,000,000）与 `maxDepth`（默认 512）限制文档规模，超限抛 `SvgException(kind: Limit)`。

上限 SHALL 在严格与宽松模式下都硬失败，不存在降级开关。

实体膨胀上限 SHALL 透传 `f_xml::EntityLimits`，外部 DTD 与外部实体 SHALL 永不加载。

#### Scenario: 元素数超限

- **WHEN** 文档含 1,000,001 个元素
- **THEN** 抛 `SvgException(kind: Limit)`

#### Scenario: 深度超限

- **WHEN** 嵌套深度为 513
- **THEN** 抛 `SvgException(kind: Limit)`

#### Scenario: 宽松模式不放行

- **WHEN** `strict: false` 且深度超限
- **THEN** 仍抛 `SvgException(kind: Limit)`

### Requirement: 安全异常与告警可审计

系统 SHALL 把安全类失败统一表示为 `SvgException(kind: Security)`，规模类失败统一表示为 `SvgException(kind: Limit)`。

`SvgDocument.warnings` SHALL 是只增的有序列表，每条告警包含可定位信息（元素路径或属性名），且不因后续遍历被清空。

#### Scenario: 多条告警累积

- **WHEN** 文档同时含脚本、事件属性与外部引用
- **THEN** `warnings` 至少三条，且分别指向对应元素路径

#### Scenario: 告警不影响解析结果

- **WHEN** 移除不安全内容后文档仍有合法形状
- **THEN** 解析成功返回 `SvgDocument`，不抛异常
