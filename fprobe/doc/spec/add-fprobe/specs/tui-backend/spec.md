# Spec Delta

## Purpose

提供一个自研的 Unix 终端后端 `f_tui`：把 raw mode、终端尺寸、按键读取、ANSI 渲染与 `Buffer → ANSI` 渲染收敛到一个可测试的动态库，使 fountain 的控制台程序不再依赖无法在 Linux 编译的 `crossterm`，也不依赖会传递引入 `crossterm` 的 `ratatui_backend` / `ratatui_terminal` / `ratatui_widgets`。终端相关代码只允许出现在本模块。

## ADDED Requirements

### Requirement: 模块边界与依赖

`f_tui` SHALL 是一个动态库模块，只承载终端能力：平台系统调用封装、raw mode、终端尺寸、按键解码、ANSI 渲染与 `Buffer → ANSI` 渲染。

依赖 MUST 仅为 `f_base` 与 ratatui 基础包 `ratatui_core`、`ratatui_style`、`ratatui_text`、`ratatui_layout`、`ratatui_buffer`；MUST NOT 依赖 `crossterm`、`ratatui_backend`、`ratatui_terminal`、`ratatui_widgets`、任何 `*_crossterm` 包或 `fprobe`；MUST NOT 包含宿主业务逻辑（节点、告警、指标、视图模型）或 panel/table/sparkline 等组件语义。宿主模块只依赖 `f_tui` 暴露的终端接口。

#### Scenario: 依赖清理

- **WHEN** 构建 `fprobe` 或其依赖树
- **THEN** 依赖图中不存在 `crossterm`、`ratatui_backend`、`ratatui_terminal`、`ratatui_widgets`，终端能力全部来自 `f_tui`

#### Scenario: 反向依赖禁止

- **WHEN** 在 `f_tui` 中引入 `fountain::fprobe` 或 `fountain::f_probe` 的导入
- **THEN** 视为设计违规，构建期或审查期必须拒绝

### Requirement: 平台范围与 TTY 检测

`f_tui` SHALL 提供 Unix（Linux / macOS / 鸿蒙 POSIX）实现，并通过 `isatty` 判断标准输入/输出是否连接终端。

非 Unix 平台 MUST 返回明确的 unsupported 错误，而不是编译通过后在运行期静默失败或写入乱码。

#### Scenario: 非 TTY

- **WHEN** 标准输出被重定向到文件或管道
- **THEN** `isTty` 返回 false，调用方可据此拒绝启动控制台模式

#### Scenario: 非 Unix 平台

- **WHEN** 在未实现的平台上调用原始模式或尺寸接口
- **THEN** 返回 unsupported 错误，错误信息包含平台名

### Requirement: raw mode 进入与恢复

`f_tui` SHALL 在进入 raw mode 前保存当前 `termios`，退出时按快照恢复；恢复 MUST 幂等，重复调用不得产生额外的系统调用或输出。

初始化 MUST 按「保存 termios → 进入 raw mode → 进入备用屏 → 隐藏光标」推进；任一步失败 MUST 按逆序回滚已完成的步骤。

终端恢复 MUST 覆盖正常退出、异常退出与 `SIGINT`/`SIGTERM` 三条路径。

#### Scenario: 正常恢复

- **WHEN** 控制台程序按 `q` 退出
- **THEN** 光标恢复显示、退出备用屏、`termios` 恢复为启动时快照

#### Scenario: 重复恢复

- **WHEN** 退出流程中 `restore()` 被调用两次
- **THEN** 第二次不写 ANSI 序列、不重复调用 `tcsetattr`

#### Scenario: 初始化中途失败

- **WHEN** raw mode 已进入但备用屏写入失败
- **THEN** 先退出 raw mode 恢复 `termios`，再返回初始化错误，不留下半初始化状态

### Requirement: 终端尺寸

`f_tui` SHALL 通过 `ioctl(TIOCGWINSZ)` 获取终端行列数，并在尺寸变化时重新读取。

尺寸读取失败 MUST 返回明确错误或约定的回退值并记录日志；MUST NOT 返回未初始化的随机值。行列任一为 0 时 MUST 视为「未知尺寸」，由调用方决定是否跳过绘制。

#### Scenario: 正常尺寸

- **WHEN** 终端报告 120 列 × 40 行
- **THEN** `size()` 返回对应行列

#### Scenario: ioctl 失败

- **WHEN** 尺寸查询返回错误
- **THEN** 返回失败或文档约定的回退尺寸，并记录一次可诊断日志

#### Scenario: 窗口变化

- **WHEN** 终端窗口在运行期改变大小
- **THEN** 下一次绘制使用新的行列数，不沿用旧尺寸

### Requirement: 按键读取

`f_tui` SHALL 从字节流解码按键，支持：可打印字符、`Enter`、`Tab`、`Shift+Tab`（`CSI Z`）、方向键（`CSI A/B`）、独立 `ESC`、UTF-8 多字节字符；单次读取 MUST 支持超时。

解码 MUST NOT 因未知序列、拆包或超时而抛异常：超时/EOF 返回空结果，未知序列映射为 `Unknown` 并继续后续读取。

#### Scenario: 方向键

- **WHEN** 输入字节为 `0x1B 0x5B 0x41`
- **THEN** 解码结果为 `Up`

#### Scenario: 拆包

- **WHEN** `0x1B 0x5B` 与 `0x41` 分两次到达
- **THEN** 解码器保留未完成序列，在后续读取中继续拼装，不误判为多个按键

#### Scenario: 超时

- **WHEN** 在超时时间内没有可读字节
- **THEN** 返回空结果，不阻塞、不抛异常，调用方可继续渲染

#### Scenario: UTF-8

- **WHEN** 输入为完整的中文 UTF-8 序列
- **THEN** 解码为单个字符，不按字节拆成多个按键

### Requirement: ANSI 渲染

`f_tui` SHALL 通过固定 ANSI 序列完成：进入/退出备用屏、隐藏/显示光标、清屏、光标定位、SGR 样式（至少 16 色，支持 256 色）、文本输出。

渲染 MUST 基于帧缓冲做差分：只输出与上一帧不同的单元格与必要的样式切换；首次绘制或尺寸变化时可整屏重绘。

来自业务数据的控制字符 MUST 在写入终端前被替换或剔除，防止数据注入 ANSI 序列。

#### Scenario: 备用屏

- **WHEN** 后端启动
- **THEN** 输出进入备用屏与隐藏光标的序列；退出时输出恢复序列

#### Scenario: 差分帧

- **WHEN** 第二帧只有一行文本变化
- **THEN** 输出只包含该行的定位与文本，不重发整屏

#### Scenario: 数据注入

- **WHEN** 指标文本中包含 `ESC` 或其它控制字符
- **THEN** 终端只显示可见替换字符，不执行该控制序列

### Requirement: Buffer 到 ANSI 渲染

`f_tui` SHALL 提供 `BufferRenderer`，接收 `ratatui_buffer.Buffer`，把其中的单元格字符、前景色/背景色与修饰符翻译为 ANSI 输出。

实现 MUST 覆盖初始化、恢复、绘制、刷新、尺寸查询、清屏与光标位置设置；MUST 只使用 ratatui 基础包，不得实现或引入 `ratatui_backend.Backend`，不得引入 `ratatui_widgets`。渲染器 MUST NOT 承担布局、组件或业务逻辑；组件由宿主基于基础类型自绘。

#### Scenario: 绘制缓冲区

- **WHEN** 传入包含文字与样式的 `Buffer` 并调用 `draw` + `flush`
- **THEN** 输出包含对应行列的文本与 SGR 样式，且一次刷新只写一次 stdout

#### Scenario: 尺寸一致

- **WHEN** 终端尺寸为 80 × 24
- **THEN** `BufferRenderer.size()` 返回 80 × 24，宿主据此构建 Buffer，输出边界与布局一致

#### Scenario: 样式复位

- **WHEN** 一帧结束
- **THEN** 输出样式复位序列，后续终端输出不被残留颜色污染

#### Scenario: 禁用后端包

- **WHEN** 审查 `f_tui` 的依赖清单或源码导入
- **THEN** 不存在 `ratatui_backend`、`ratatui_terminal`、`ratatui_widgets` 或 `crossterm`，渲染逻辑只组合五个基础包

### Requirement: 可测试性

`f_tui` SHALL 把系统交互收敛到可注入接口：字节来源、终端写入、尺寸来源与 POSIX 调用封装。测试 MUST 能注入假实现，在无 TTY、无真实终端的环境中验证解码、渲染、尺寸与恢复顺序。

#### Scenario: 无 TTY 单测

- **WHEN** 在 CI 中运行 `cjpm test`
- **THEN** 所有终端用例使用假字节源/假 writer/假 ioctl，不要求真实 TTY，不修改当前终端状态

#### Scenario: 失败注入

- **WHEN** 假 writer 在写入中途返回失败
- **THEN** 后端标记为不可用并停止后续渲染，异常不穿透到调用线程
