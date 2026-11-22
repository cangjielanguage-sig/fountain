# 设计：XmlWriter 字节暂存复用

## Context

`docs/LocalMode.md` 2.5 把 `XmlWriter.flush` 的 16 KB 编码数组列为优化点。探针（临时用例，已删除）对照了两种刷写方式，64 次刷写、每次 16 KB：

| 路径 | 总分配 | 每次刷写 |
| --- | --- | --- |
| `StringGenerator` + `unsafeBytes()` + `clear()` | 20,080 B | 313 B |
| 复用缓冲 + `bytes()[0..size]` 切片 | 16,712 B | 261 B |

差值是数组描述符与循环开销，**没有 16 KB 的整块复制**：`unsafeBytes()` 返回的是按 size 截好的数组视图。原审计结论不成立。

真正的热点在转义路径：`StringGenerator.append(r: Rune)` 对每个非 ASCII 码点执行

```cangjie
let runeBytes: Array<Byte> = [0, 0, 0, 0]
```

实测 20000 个汉字：

| 路径 | 总分配 | 每 rune |
| --- | --- | --- |
| `StringGenerator.append(r)` | 1,362,824 B | 68 B |
| 复用 4 B 暂存 + `putCp` | 57,536 B | 2 B |

`f_xml.ByteScratch` 已经有这个复用暂存（`private let enc = Array<Byte>(4, repeat: 0)`）与 `putCp`，只是 `XmlWriter` 还在用 `StringGenerator`。

## Goals / Non-Goals

**Goals：**
- 消除非 ASCII 字符逐字符新建暂存数组的分配。
- 所有编码下的输出字节、转义、异常行为保持不变。
- 公开 API 不变；不修改 `f_base.StringGenerator`。

**Non-Goals：**
- 不优化 UTF-8 刷写的数组视图（实测无收益）。
- 不改非 UTF 编码器的 `encode(String)` API（外部依赖，无法避免其返回新数组）。
- 不改刷写门限（16 KB）与缓冲增长策略。

## Decisions

### D1 `XmlWriter` 缓冲换成 `ByteScratch`

```cangjie
private let buffer = ByteScratch()
```

`ByteScratch` 已具备 `reset()`（只置长度、保留容量）、`size`、`bytes()`（底层数组视图）、`toUtf8String()`（零拷贝 String 视图）与 `putCp`。改动点：

- `appendText`：`buffer.append<String>(text)` → `buffer.append(text)`；
- `flushBuffer`：`unsafeBytes()` → `bytes()[0..size]`，`clear()` → `reset()`，`toString()` → `toUtf8String()`；
- 其余 `buffer.size` 判断不变。

**理由**：与 `StringGenerator` 的行为一一对应，且自带复用暂存。**替代方案**：给 `f_base.StringGenerator.append(r)` 加复用暂存字段——会改变所有模块共享的类型布局，影响面远大于本问题。

### D2 `Escaper` 接收 `ByteScratch`

三个方法（`escapeText` / `escapeAttribute` / `writeCData`）的 `out` 参数由 `StringGenerator` 改为 `ByteScratch`：

```cangjie
case r'&' => out.append("&amp;")
...
case _ => out.putCp(r.position())
```

`ByteScratch` 新增 `append(text: String)`，内部整块 `copyTo`；`putCp` 负责 ASCII 直写与非 ASCII 的复用暂存编码。

**替代方案**：保留 `StringGenerator`，只把 `append(r)` 换成 `append<String>(r.toString())`——每字符新建 String，分配更大。

### D3 批量复制改用 `copyTo`

`ByteScratch.ensure` 的扩容拷贝由逐字节循环改为 `this.buf.copyTo(grown, 0, 0, this.buf.size)`；`append(text)` 用 `text.unsafeBytes().copyTo(this.buf, 0, this.len, size)`。`-O0` 下逐字节下标读写会引入额外开销，整块复制与 `ArrayList.add(all:)` 的开销同级。

### D4 刷写路径保持原样

- UTF-8：`output.write(buffer.bytes()[0 .. buffer.size])`；
- 非 UTF：`let text = buffer.toUtf8String()` → `reset()` → `output.write(encodeChecked(text))`。

`toUtf8String()` 返回的 String 别名复用缓冲，但 `reset()` 只改长度、不覆写字节，且 `encodeChecked` 在返回前同步读完，安全。

底层 `OutputStream.write` 必须在返回前消费传入的数组——这一点在改动前就成立（`unsafeBytes()` 同样是内部数组的视图），不是新增约束。

### D5 验证

- 新增 `f_xml/src/XmlWriterScratch_test.cj`：
  - UTF-8 多段刷写（> 32 KB，含汉字/emoji）与期望字符串逐字节相同；
  - 属性转义、CDATA `]]>` 拆分与非 ASCII 混合；
  - UTF-16LE 多段刷写与一次性写出字节相同；
  - 单字节编码的不可映射字符仍为 `?`；
  - env-gated 分配基准（`F_XML_BENCH=1`）：`putCp` 路径 ≤ 8 B/rune，且 `StringGenerator.append(r)` 基线总量至少高 8 倍。
- 既有 `XmlWriter_test` / `XmlWriterIncremental_test` / `WriterEncoding_test` / `FormatSamples_test` 全量回归。

## Risks / Trade-offs

| 风险 | 处理 |
| --- | --- |
| `OutputStream.write` 保留传入视图导致后续写入串改 | 与改动前同一假设（原路径也传内部数组视图）；仓库内所有 sink 都同步复制 |
| 非 UTF 路径的 String 视图在 `reset()` 后失效 | `reset()` 不清字节、`encodeChecked` 同步完成；顺序固定为 取 String → reset → 编码 |
| `ByteScratch` 容量增长 | 翻倍增长 + `copyTo`，摊还 O(1)；`reset()` 保留容量，稳态不再分配 |
| 输出字节变化 | 既有 4 个 writer 测试套件 + 新增多段刷写对拍 |
| 公开 API 变化 | 无：`ByteScratch`/`Escaper` 为包内类型，`XmlWriter` 签名未动 |

## Migration Plan

- 局部替换 `f_xml` 三个文件的缓冲类型与写入方法，无数据/配置迁移。
- 回退：`git revert` 单个提交即可，输出行为不受影响。

## Open Questions

无。
