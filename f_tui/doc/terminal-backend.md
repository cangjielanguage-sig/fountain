# `f_tui` 终端后端

`fountain::f_tui` 是 fountain 的 Unix 终端后端。它把 raw mode、终端尺寸、按键解码、ANSI 渲染
与 `ratatui_buffer.Buffer → ANSI` 渲染收敛在一个动态库内，宿主只依赖本模块的公开接口。

## 1. 平台范围与依赖

- 目标平台：Linux（x86_64 / aarch64）、macOS、鸿蒙 POSIX。
- 非 Unix 平台不实现 Windows Console 后端：`SystemExitHook`、`RealPosixFfi` 在 Windows 上返回
  unsupported 语义。
- 直接依赖只有 `f_base` 与 ratatui 基础包：
  `ratatui_core`、`ratatui_style`、`ratatui_text`、`ratatui_layout`、`ratatui_buffer`。
- 禁止依赖 `crossterm`、`ratatui_backend`、`ratatui_terminal`、`ratatui_widgets`。
  `BufferRenderer` 不实现 `ratatui_backend.Backend`。
- `term` / `ansi` / `input` 三个包不引用 ratatui；只有 `render` 包使用 ratatui 基础类型。

## 2. 可注入的系统边界

生产代码只通过四个接口接触操作系统，测试全部注入假实现，不需要真实 TTY：

| 接口 | 位置 | 职责 |
| --- | --- | --- |
| `PosixFfi` | `term/PosixFfi.cj` | `isatty` / `tcgetattr` / `tcsetattr` / `ioctl(TIOCGWINSZ)` / `read` / `write` |
| `ByteSource` | `term/ByteSource.cj` | 带超时读取一个字节（stdin） |
| `TerminalWriter` | `term/TerminalWriter.cj` | 写出文本并 flush（stdout） |
| `SizeProvider` | `term/TerminalSize.cj` | 提供终端行列数 |

`PosixFfi` 的公开方法：

```cangjie
public interface PosixFfi {
    func isTty(fd: Int32): Bool
    func getTermios(fd: Int32): Option<Termios>
    func setTermios(fd: Int32, value: Termios): Bool
    func windowSize(fd: Int32): Option<WinSize>
    func readByte(fd: Int32, timeoutMs: Int64): Option<UInt8>
    func writeBytes(fd: Int32, bytes: Array<UInt8>): Bool
}
```

`termios` 用 `@C struct` + `VArray` 映射：Linux / 鸿蒙为 32 位标志、32 字节 `c_cc`（`sizeOf` = 60），
macOS 为 64 位标志、20 字节 `c_cc`（`sizeOf` = 72）。布局与常量由 `PosixFfi_test.layoutMatchesPlatform`
在测试期断言。

## 3. raw mode 与生命周期

`RawMode(ffi, fd)`：

- `enter()`：`tcgetattr` 保存快照 → 计算 raw `termios` → `tcsetattr` 写回。
  raw 模式关闭 `ICANON` / `ECHO` / `IEXTEN` / `ICRNL` / `IXON` / `OPOST`，保留 `ISIG`，
  使 `SIGINT` / `SIGTERM` 仍能触发退出恢复；`VMIN = 1`、`VTIME = 0`。
- `restore()`：按启动快照写回；未进入或已恢复时是空操作，连续调用不产生额外系统调用。
- `isActive()` / `snapshot()` 用于诊断与测试。

`Terminal(ffi, writer, sizeProvider, exitHook, fdIn, fdOut)` 的状态机：

```
start():  isatty(fdIn) && isatty(fdOut)
          → rawMode.enter()
          → AnsiRenderer.enterAltScreen()
          → AnsiRenderer.hideCursor()
restore(): AnsiRenderer.reset()（显示光标 → 退出备用屏 → 复位样式）
          → rawMode.restore()
```

- 任一步失败按逆序回滚已完成的步骤，再抛 `TuiException(Init)`；TTY 检查失败抛
  `TuiException(Unsupported)`。
- `restore()` 幂等；默认通过 `SystemExitHook` 注册到 `atExit` 与 `SIGINT` / `SIGTERM`，
  正常返回、异常抛出、信号退出共用同一回调。
- 写 stdout 失败（管道关闭、EPIPE 等）时 `AnsiRenderer` 标记 broken，后续渲染不再写终端，
  异常不穿透到采集线程。

## 4. 终端尺寸

```cangjie
public struct TuiSize { public var width: UInt16; public var height: UInt16 }
public interface SizeProvider { func size(): Option<TuiSize> }
public class IoctlSizeProvider <: SizeProvider { ... }
public class TerminalSize {
    public init(provider: SizeProvider)
    public func size(): Option<TuiSize>
    public func lastKnown(): TuiSize
}
```

- `ioctl(TIOCGWINSZ)` 成功返回行列；失败返回 `None`，不返回未初始化值。
- 行列任一为 `0` 视为未知尺寸，返回 `None`，由宿主决定跳过绘制。
- 每次 `size()` 都重新读取，窗口变化后立即生效。

## 5. 按键解码

`KeyReader(ByteSource, escapeTimeoutMs = 25)` 先按调用方超时读首字节；若首字节是 `0x1B`，
用较短超时继续读后续字节，以区分独立 ESC 与 CSI / SS3。未完成序列保留在 `EscapeParser`
内部，下一次读取继续拼装；超时或 EOF 返回 `None`，不抛异常。

`TerminalKey` 映射：

| 输入字节 | `TerminalKey` |
| --- | --- |
| `0x09` | `Tab` |
| `0x0A` / `0x0D` | `Enter` |
| `0x1B`（超时无后续） | `Escape` |
| `0x1B 0x5B 0x41` | `Up` |
| `0x1B 0x5B 0x42` | `Down` |
| `0x1B 0x5B 0x5A` | `BackTab`（Shift+Tab） |
| `0x1B 0x4F 0x41` | `Up`（SS3） |
| `0x1B 0x4F 0x42` | `Down`（SS3） |
| 合法 UTF-8 序列 | `Char(Rune)` |
| 其它控制字符 / `0x7F` / 未知 CSI | `Unknown` |

`q` / `r` / `a` 等可打印字符一律解为 `Char`，语义由宿主（例如 fprobe 的 `KeyMap`）决定。

## 6. ANSI 渲染与差分

`AnsiRenderer(TerminalWriter)` 只输出固定序列：

| 功能 | 序列 |
| --- | --- |
| 进入 / 退出备用屏 | `ESC[?1049h` / `ESC[?1049l` |
| 隐藏 / 显示光标 | `ESC[?25l` / `ESC[?25h` |
| 清屏 | `ESC[2J` |
| 光标定位（1 基） | `ESC[{row};{col}H` |
| 前景 256 色 / 真彩 | `ESC[38;5;{n}m` / `ESC[38;2;{r};{g};{b}m` |
| 背景 256 色 / 真彩 | `ESC[48;5;{n}m` / `ESC[48;2;{r};{g};{b}m` |
| 复位样式 | `ESC[0m` |

`ScreenBuffer(width, height)` 是帧缓冲：

- `set(x, y, cell)` 会清洗控制字符（`0x00-0x1F`、`0x7F-0x9F` 替换为 `?`），
  并按显示宽度为中文/全角字符标记第二列为 `skip`。
- `get(x, y)` 返回 `ScreenCell`（`symbol` / `fg` / `bg` / `modifier` / `skip`）。
- `clone()` 用于保存上一帧。

`AnsiRenderer.render(frame, forceFull)`：

- 首帧、尺寸变化或 `forceFull = true` 时整屏重绘；否则只输出与上一帧不同的单元格。
- 差分按行分组，只为变化行输出定位与文本；宽字符的 `skip` 列不重复输出。
- 一帧结束输出 `ESC[0m`；一次 `render` 只调用一次 `TerminalWriter.write` 与一次 `flush`。
- 写失败后 `isBroken()` 为真，后续渲染直接返回 `false` 且不再写终端。

## 7. `Buffer → ANSI` 渲染器

`BufferRenderer(AnsiRenderer, SizeProvider)`：

```cangjie
public class BufferRenderer {
    public init(renderer: AnsiRenderer, sizeProvider: SizeProvider)
    public func start(): Bool
    public func restore(): Unit
    public func isBroken(): Bool
    public func size(): TuiSize
    public func clear(): Unit
    public func setCursor(position: ?Position): Unit
    public func draw(buffer: Buffer): Unit
    public func flush(): Bool
}
```

- `draw(Buffer)` 只做机械翻译：单元格 `symbol`、`Cell.fg` / `Cell.bg`、`Cell.modifier.bits`
  → `ScreenCell`；颜色映射见 `BufferRenderer.toAnsiColor`。
- `ratatui_buffer.Buffer` 的 `setString` 不会为宽字符设置 `skip`，`BufferRenderer` 按显示宽度
  自行跳过后续列，保证中文占两列。
- `flush()` 把当前帧交给 `AnsiRenderer.render` 做差分输出。
- `size()` 每次向 `SizeProvider` 重新查询；未知时回退到 Buffer 的 `area`（`draw` 内）。
- 不实现 `ratatui_backend.Backend`，不承担布局、panel、table、sparkline 等组件语义。

## 8. 测试替身

单元测试全部使用假实现，不触碰真实终端：

| 替身 | 用途 |
| --- | --- |
| `FakePosixFfi` | 记录 `tcgetattr` / `tcsetattr` / `ioctl` 调用顺序，模拟 ioctl 失败 |
| `FakeByteSource` | 预置字节队列，模拟拆包、超时与 EOF |
| `RecordingWriter` | 记录 ANSI 文本与 flush 次数，可在指定写入位置注入失败 |
| `FakeSizeProvider` | 返回固定或变化的行列数 |
| `RecordingExitHook` | 捕获退出回调，模拟正常/异常/信号三条退出路径 |

约定：测试只断言接口调用顺序、ANSI 序列、差分内容与状态，不打开 `/dev/tty`，不修改运行 `cjpm test`
的终端。
