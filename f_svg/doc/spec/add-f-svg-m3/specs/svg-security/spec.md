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

- **WHEN** 文档含 `begin="click"` 的动画
- **THEN** 该动画被忽略并记 warning，渲染不等待任何事件

## ADDED Requirements

### Requirement: M3 资源上限表

系统 SHALL 在分配缓冲或解压前检查下列上限，超限 SHALL 抛 `SvgException(kind: Limit)`：

| 项 | 默认上限 |
|---|---|
| 单张解码图像素 | `16 × 1024 × 1024` |
| 单次渲染解码总像素 | `64 × 1024 × 1024` |
| `data:` base64 长度 | 32 MiB |
| gzip 解压输出 | 64 MiB |
| 滤镜区域像素 | 同 `SvgRenderOptions.maxPixels` |
| 图案 tile 像素 | `4 × 1024 × 1024` |
| pattern / marker 引用深度 | 64 |

#### Scenario: 单图超限

- **WHEN** PNG `IHDR` 声明 `5000 × 5000`（25M 像素）
- **THEN** 抛 `SvgException(kind: Limit)`，未分配图像缓冲

#### Scenario: base64 超限

- **WHEN** `data:image/png;base64,` 文本长度超过 32 MiB
- **THEN** 抛 `SvgException(kind: Limit)`，未进行 base64 解码

#### Scenario: 图案深度

- **WHEN** pattern 引用链深度达到 65
- **THEN** 抛 `SvgException(kind: Limit)`

### Requirement: M3 展开上限与检查时机

marker 派生数超过每元素 1024 时 SHALL 追加 warning 并截断，不抛异常。

pattern / marker / gradient 的循环引用 SHALL 追加 warning 并停止展开，不抛异常。

所有上限检查 SHALL 发生在分配大缓冲之前；超限路径不得先分配再报错。

#### Scenario: marker 截断

- **WHEN** 单元素需要派生 2000 个 marker
- **THEN** 只绘制 1024 个，追加 warning，渲染继续

### Requirement: M3 解码与效果告警

下列情况 SHALL 追加可审计 warning，且不中断整个文档渲染：

- 滤镜 `in` / `in2` / `result` 引用不存在的名字；
- `<filter>` 内出现非 `fe*` 子元素；
- 图案 tile 为空；
- 图案子内容渲染失败；
- marker 引用不存在或数量超限；
- `<image>` 资源不可用；
- 非法 `rotate` 值；
- `textPath` 路径缺失或路径短于文本。

每条 warning SHALL 包含可定位的元素或属性信息，便于调用方审计。

#### Scenario: 告警可审计

- **WHEN** 文档同时含空 pattern、缺失 marker 与不可用 image
- **THEN** `SvgRenderer.warnings` 至少三条，分别包含 `pattern`、`marker`、`image` 关键词，渲染仍完成

#### Scenario: 不中断渲染

- **WHEN** 一个元素的效果渲染失败
- **THEN** 同文档其他元素正常绘制，输出位图非空
