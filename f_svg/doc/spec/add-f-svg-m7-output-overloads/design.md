# 设计：M7 输出重载

## 决策

### D1 `write` 直接复用 `SvgWriter`

`write(output: OutputStream)` 内部构造 `SvgWriter(output)` 并调用 `write(document())`，最后 `flush()`。与 `toSvgString()` 共享同一序列化路径，保证输出逐字节一致。

不通过 `toSvgString().toArray()` 再写流：那样会多一次中间字符串，且无法利用 `XmlWriter` 的流式写入。

### D2 不关闭调用方的流与文件

`write` 与 `save(file:)` 只写入并 `flush`，不调用 `close`。所有权归调用方：调用方可能在同一流上继续写，或在外层 `try (file = File.create(...))` 中统一关闭。

### D3 `save(file:)` 复用 `write`

`save(file: File)` 等价于 `write(file)`。文件系统异常按既有 D9 口径包装为 `SvgException(kind: InvalidValue)`；由于 `File` 已由调用方打开，异常主要来自写入阶段。

### D4 重载解析

保留 `save(path: String)` 与 `save(path: Path)`，新增 `save(file: File)`；三者参数类型不同，不产生歧义。`File` 与 `Path` 都是 `std.fs` 类型，调用方显式构造时无歧义。

## 风险

| 风险 | 处理 |
|---|---|
| 调用方误以为 `save(file:)` 会关闭文件 | 文档与规格明确「不关闭」 |
| `File` 是否实现 `OutputStream` 取决于 std | 实现与测试直接以 `File` 调用 `write`，编译期验证 |
| 双写（先 `save(file:)` 再 `close`）造成重复 flush | `flush` 幂等，允许 |
