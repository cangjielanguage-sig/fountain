# m5-shaping

该场景使用 `SvgSnapshotM5_test.m5ShapingFonts()` 构造的最小 TTF（含 `kern`、`GPOS`
与 `GSUB liga`）渲染 `m5-shaping.svg`，用于锁定字距、连字与 bidi 的确定性输出。
字体 fixture 由测试代码构造，不在本目录保存二进制文件。
