# `fountain::f_tui`

Unix terminal backend: POSIX `termios` raw mode, terminal size, key decoding, differential ANSI
rendering, and a `ratatui_buffer.Buffer → ANSI` renderer. All terminal code lives in this module.

- Depends only on `f_base` and the ratatui base packages: `ratatui_core`, `ratatui_style`,
  `ratatui_text`, `ratatui_layout`, `ratatui_buffer`.
- Never depends on `crossterm`, `ratatui_backend`, `ratatui_terminal` or `ratatui_widgets`;
  `BufferRenderer` does not implement `ratatui_backend.Backend`.
- System access goes through four injectable interfaces (`PosixFfi` / `ByteSource` /
  `TerminalWriter` / `SizeProvider`), so `cjpm test` needs no real TTY.

## Layers

| Package | Contents |
| --- | --- |
| `fountain::f_tui.term` | `PosixFfi`, `RawMode`, `TerminalSize`, `ByteSource`, `TerminalWriter` |
| `fountain::f_tui.ansi` | `AnsiSequence`, `ScreenBuffer`, `AnsiRenderer`, `AnsiColor` |
| `fountain::f_tui.input` | `EscapeParser`, `KeyReader`, `TerminalKey` |
| `fountain::f_tui.render` | `BufferRenderer`, `Terminal`, `ExitHook` |

## Quick start

```cangjie
import fountain::f_tui.term.*
import fountain::f_tui.render.*

let ffi = RealPosixFfi()
let writer = StdoutTerminalWriter(ffi, STDOUT_FILENO)
let terminal = Terminal(ffi, writer, IoctlSizeProvider(ffi, STDOUT_FILENO))
terminal.start()
try {
    let renderer = terminal.bufferRenderer()
    // The host builds a Buffer with ratatui base types.
    // renderer.draw(buffer)
    // renderer.flush()
} finally {
    terminal.restore()
}
```

- Terminal backend reference: [`doc/terminal-backend.md`](doc/terminal-backend.md)
- The public declarations under `src/` are the source of truth for the API.
