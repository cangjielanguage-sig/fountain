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
