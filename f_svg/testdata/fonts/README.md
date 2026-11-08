# TrueType 测试 fixture

M4 的 TrueType 测试使用 `SvgTrueTypeM4_test.cj` 中的 `m4BuildTtf()` 手工构造最小字体字节，
覆盖 `head` / `hhea` / `maxp` / `hmtx` / `loca` / `cmap`（format 4 / 12）/ `glyf`
（简单字形、复合字形与自引用深度用例）。

fixture 以代码构造而不是二进制文件存放，便于在测试中逐字段调整以覆盖截断、越界与上限分支。
真实字体只应由调用方通过 `SvgTrueTypeFont.load(Path)` 显式加载，渲染链路不会读取本目录或
文件系统上的任何字体。
