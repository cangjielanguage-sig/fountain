# `fountain::f_tui`

Unix 终端后端：POSIX `termios` raw mode、终端尺寸、按键解码、ANSI 差分渲染，以及
`ratatui_buffer.Buffer → ANSI` 渲染器。终端相关代码只允许出现在本模块。

- 只依赖 `f_base` 与 ratatui 基础包：`ratatui_core`、`ratatui_style`、`ratatui_text`、
  `ratatui_layout`、`ratatui_buffer`。
- 不依赖 `crossterm`、`ratatui_backend`、`ratatui_terminal`、`ratatui_widgets`；
  `BufferRenderer` 不实现 `ratatui_backend.Backend`。
- 系统交互只经过 `PosixFfi` / `ByteSource` / `TerminalWriter` / `SizeProvider` 四个可注入接口，
  `cjpm test` 不需要真实 TTY。

## 分层

| 包 | 内容 |
| --- | --- |
| `fountain::f_tui.term` | `PosixFfi`、`RawMode`、`TerminalSize`、`ByteSource`、`TerminalWriter` |
| `fountain::f_tui.ansi` | `AnsiSequence`、`ScreenBuffer`、`AnsiRenderer`、`AnsiColor` |
| `fountain::f_tui.input` | `EscapeParser`、`KeyReader`、`TerminalKey` |
| `fountain::f_tui.render` | `BufferRenderer`、`Terminal`、`ExitHook` |

## 快速使用

```cangjie
import fountain::f_tui.term.*
import fountain::f_tui.render.*

let ffi = RealPosixFfi()
let writer = StdoutTerminalWriter(ffi, STDOUT_FILENO)
let terminal = Terminal(ffi, writer, IoctlSizeProvider(ffi, STDOUT_FILENO))
terminal.start()
try {
    let renderer = terminal.bufferRenderer()
    // 宿主用 ratatui 基础类型构建 Buffer
    // renderer.draw(buffer)
    // renderer.flush()
} finally {
    terminal.restore()
}
```

- 终端后端说明：[`doc/terminal-backend.md`](doc/terminal-backend.md)
- 接口以 `src/` 下的公开声明为准。

---

## 其他公开 API

以下声明未在上文展开，按「模块级 / 类型」分组列出（`extend` 里的成员归到被扩展的类型）；完整语义见 `src/` 下对应文件。

- 模块级：`CursorPos`（struct）、`ScreenCell`（struct）、`StdinByteSource`（class）、`SystemExitHook`（class）、`public struct Termios`、`TuiErrorCode`（enum）、`TuiException`（class）、`TuiSize`（struct）、`public struct WinSize`、`displayWidth`（func）、`makeRaw`（func）、`sanitizeSymbol`（func）、`version`（func）
- `AnsiColor`：`Default`（let）、`backgroundParams`（func）、`blue`（var）、`equals`（func）、`foregroundParams`（func）、`green`（var）、`index`（var）、`indexed`（func）、`isDefault`（func）、`kind`（var）、`red`（var）、`rgb`（func）
- `AnsiRenderer`：`clear`（func）、`enterAltScreen`（func）、`exitAltScreen`（func）、`hideCursor`（func）、`isBroken`（func）、`reset`（func）、`setCursor`（func）、`showCursor`（func）
- `AnsiSequence`：`cursorTo`（func）、`styleFor`（func）
- `BufferRenderer`：`clear`（func）、`isBroken`（func）、`setCursor`（func）、`size`（func）
- `CursorPos`：`x`（var）、`y`（var）
- `EscapeParser`：`feed`（func）、`flushEscape`（func）、`isLoneEscape`（func）、`next`（func）、`pendingCount`（func）
- `IoctlSizeProvider`：`size`（func）
- `KeyReader`：`pendingCount`（func）、`readKey`（func）
- `RawMode`：`enter`（func）、`isActive`（func）、`snapshot`（func）
- `RealPosixFfi`：`getTermios`（func）、`isTty`（func）、`readByte`（func）、`setTermios`（func）、`windowSize`（func）、`writeBytes`（func）
- `ScreenBuffer`：`clone`（func）、`get`（func）、`height`（func）、`sameCell`（func）、`set`（func）、`width`（func）
- `ScreenCell`：`bg`（var）、`equals`（func）、`fg`（var）、`isPlain`（func）、`modifier`（var）、`skip`（var）、`symbol`（var）
- `StdinByteSource`：`read`（func）
- `StdoutTerminalWriter`：`write`（func）
- `SystemExitHook`：`register`（func）
- `Terminal`：`isInitialized`（func）、`size`（func）
- `TerminalSize`：`lastKnown`（func）、`size`（func）
- `Termios`：`var c_cc: VArray<UInt8, $20> = VArray<UInt8, $20>(repeat: 0)`、`var c_cflag: UInt64 = 0`、`var c_iflag: UInt64 = 0`、`var c_ispeed: UInt64 = 0`、`var c_lflag: UInt64 = 0`、`var c_line: UInt8 = 0`、`var c_oflag: UInt64 = 0`、`var c_ospeed: UInt64 = 0`
- `TuiException`：`code`（let）
- `TuiSize`：`height`（var）、`isUnknown`（func）、`width`（var）
- `WinSize`：`ws_col`（var）、`ws_row`（var）、`ws_xpixel`（var）、`ws_ypixel`（var）
