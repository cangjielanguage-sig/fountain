# svg-security

## ADDED Requirements

### Requirement: 渲染资源上限

渲染入口 SHALL 在分配像素缓冲前检查 `width × height × devicePixelRatio²`；超过 `SvgRenderOptions.maxPixels`（默认 `64 × 1024 × 1024`）时 SHALL 抛 `SvgException(kind: Limit)`。

`width` / `height` ≤ 0、`devicePixelRatio` ≤ 0 SHALL 抛 `SvgException(kind: InvalidValue)`。

#### Scenario: 超大画布

- **WHEN** 请求 `100000 × 100000` 输出且未提高 `maxPixels`
- **THEN** 渲染立即抛 `SvgException(kind: Limit)`，不分配像素缓冲

#### Scenario: 非正尺寸

- **WHEN** `width = 0` 或 `devicePixelRatio = 0`
- **THEN** 抛 `SvgException(kind: InvalidValue)`

### Requirement: 渲染期无外部访问

渲染器 SHALL NOT 发起网络请求、打开外部文件、执行脚本或解码外部图像。

CSS 与画笔中的 `url(...)` SHALL 只接受 `#id` 片段；外部形式 SHALL 按无画笔处理并记 warning。`<image>` SHALL 只绘制占位，不读取 `href` 指向的资源。

#### Scenario: 外部 CSS 引用

- **WHEN** 样式表声明 `fill: url(https://example.com/a.svg#g)`
- **THEN** 渲染成功，该填充按 `none` 处理，产生 warning，无网络请求

#### Scenario: 外部图片

- **WHEN** `<image href="file:///etc/passwd"/>`
- **THEN** 渲染成功，仅绘制占位，未打开文件

#### Scenario: 动画不执行脚本

- **WHEN** 文档含 `begin="click"` 的动画
- **THEN** 该动画被忽略并记 warning，渲染不等待任何事件

### Requirement: 渲染递归与规模上限

`use` 展开、嵌套 `<svg>`、渐变 `href` 继承、`clipPath` / `mask` 引用与动画 `mpath` 引用的递归深度 SHALL 不超过 64。

检测到循环引用时 SHALL 在深度 64 终止并记 warning（渲染继续）；非循环引用但深度超过 64 时 SHALL 抛 `SvgException(kind: Limit)`。

单个动画的 `values` 项数 SHALL 不超过 10000；超过 SHALL 抛 `SvgException(kind: Limit)`。

#### Scenario: use 自引用

- **WHEN** `<g id="a"><use href="#a"/></g>`
- **THEN** 渲染在深度 64 终止，产生 warning，进程不崩溃

#### Scenario: 非循环深层嵌套

- **WHEN** 65 层互不相同的嵌套 `<use>` 链
- **THEN** 渲染抛 `SvgException(kind: Limit)`

#### Scenario: 渐变循环引用

- **WHEN** 渐变 A `href="#B"`、渐变 B `href="#A"`
- **THEN** 继承在深度上限处停止并记 warning，渲染继续

#### Scenario: 动画 values 爆炸

- **WHEN** 动画 `values` 含 10001 项
- **THEN** 抛 `SvgException(kind: Limit)`
