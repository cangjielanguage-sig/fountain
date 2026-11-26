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

---

## Other public API

The declarations below are not expanded above; they are grouped by module level and by type (members declared in `extend` blocks are listed under the extended type). See the corresponding files under `src/` for the full semantics.

- Module level: `CursorPos` (struct), `ScreenCell` (struct), `StdinByteSource` (class), `SystemExitHook` (class), `public struct Termios`, `TuiErrorCode` (enum), `TuiException` (class), `TuiSize` (struct), `public struct WinSize`, `displayWidth` (func), `makeRaw` (func), `sanitizeSymbol` (func), `version` (func)
- `AnsiColor`: `Default` (let), `backgroundParams` (func), `blue` (var), `equals` (func), `foregroundParams` (func), `green` (var), `index` (var), `indexed` (func), `isDefault` (func), `kind` (var), `red` (var), `rgb` (func)
- `AnsiRenderer`: `clear` (func), `enterAltScreen` (func), `exitAltScreen` (func), `hideCursor` (func), `isBroken` (func), `reset` (func), `setCursor` (func), `showCursor` (func)
- `AnsiSequence`: `cursorTo` (func), `styleFor` (func)
- `BufferRenderer`: `clear` (func), `isBroken` (func), `setCursor` (func), `size` (func)
- `CursorPos`: `x` (var), `y` (var)
- `EscapeParser`: `feed` (func), `flushEscape` (func), `isLoneEscape` (func), `next` (func), `pendingCount` (func)
- `IoctlSizeProvider`: `size` (func)
- `KeyReader`: `pendingCount` (func), `readKey` (func)
- `RawMode`: `enter` (func), `isActive` (func), `snapshot` (func)
- `RealPosixFfi`: `getTermios` (func), `isTty` (func), `readByte` (func), `setTermios` (func), `windowSize` (func), `writeBytes` (func)
- `ScreenBuffer`: `clone` (func), `get` (func), `height` (func), `sameCell` (func), `set` (func), `width` (func)
- `ScreenCell`: `bg` (var), `equals` (func), `fg` (var), `isPlain` (func), `modifier` (var), `skip` (var), `symbol` (var)
- `StdinByteSource`: `read` (func)
- `StdoutTerminalWriter`: `write` (func)
- `SystemExitHook`: `register` (func)
- `Terminal`: `isInitialized` (func), `size` (func)
- `TerminalSize`: `lastKnown` (func), `size` (func)
- `Termios`: `var c_cc: VArray<UInt8, $20> = VArray<UInt8, $20>(repeat: 0)`, `var c_cflag: UInt64 = 0`, `var c_iflag: UInt64 = 0`, `var c_ispeed: UInt64 = 0`, `var c_lflag: UInt64 = 0`, `var c_line: UInt8 = 0`, `var c_oflag: UInt64 = 0`, `var c_ospeed: UInt64 = 0`
- `TuiException`: `code` (let)
- `TuiSize`: `height` (var), `isUnknown` (func), `width` (var)
- `WinSize`: `ws_col` (var), `ws_row` (var), `ws_xpixel` (var), `ws_ypixel` (var)
