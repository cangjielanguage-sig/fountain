# Spec Delta

## Purpose

为 `fountain::f_zip` 提供读取侧能力：从内存流或文件路径构造 `ZipReader`、枚举条目、按名取数据或取流、校验 CRC 与大小、按 `ZipLimits` 拦截超限，以及 `unzip` 便捷解压。目标是"大 ZIP 不吃内存、并发解压不串数据、损坏文件快速失败"。

## ADDED Requirements

### Requirement: 两种构造方式

`ZipReader` SHALL 提供 `init(input: InputStream, limits!: ZipLimits = ZipLimits())` 与 `init(path: String, limits!: ZipLimits = ZipLimits())` 两种构造。`init(input)` SHALL 把整个流缓冲进内存以获得随机访问；`init(path)` SHALL 通过 `std.fs.File` 的 `seek` 做窗口读，SHALL NOT 缓冲整个文件。

#### Scenario: 流构造可读内存中的 ZIP

- **WHEN** 用一个包含两个条目的 `ByteArrayInputStream` 构造 `ZipReader`
- **THEN** `entries()` 返回两条，`read(name)` 与原始数据逐字节一致

#### Scenario: 路径构造不缓冲整包

- **WHEN** 用 `ZipReader(path)` 打开一个 1 GB 的 ZIP 并只调用 `entries()`
- **THEN** 进程 RSS 不随文件大小线性增长（增量远小于文件大小）

#### Scenario: 路径构造的尾部窗口上界

- **WHEN** 打开任意合法 ZIP
- **THEN** 首次读取不超过 `min(fileLength, 22 + 65535)` 字节用于 EOCD 定位

### Requirement: 条目枚举保持中央目录顺序

`entries()` SHALL 返回按中央目录出现顺序排列的 `ArrayList<ZipEntry>`，SHALL NOT 合并同名条目，SHALL NOT 排序。每次调用 SHALL 返回独立列表，调用方修改不得影响 reader 内部状态。

#### Scenario: 顺序与中央目录一致

- **WHEN** 依次写入 `b.txt`、`a.txt`、`dir/` 并读回
- **THEN** `entries()` 的顺序是 `b.txt`、`a.txt`、`dir/`

#### Scenario: 同名条目全部保留

- **WHEN** 读取一个外部产生的、含两条同名 `x.txt` 的 ZIP
- **THEN** `entries()` 返回两条 `x.txt`，不合并

#### Scenario: 修改返回列表不影响内部

- **WHEN** 调用方对 `entries()` 的返回值执行 `clear()`
- **THEN** 再次调用 `entries()` 仍返回完整条目

### Requirement: 按名读取与全部读取

`ZipReader.read(name: String): ?Array<Byte>` SHALL 返回该名字**最后一个**匹配条目解压后的数据；名字不存在时返回 `None`。`readAll(name: String): Array<Array<Byte>>` SHALL 按中央目录顺序返回全部同名**文件**条目解压后的数据（目录条目不入结果）。`contains(name: String): Bool` SHALL 报告是否存在该名字。

#### Scenario: 同名取最后一个

- **WHEN** 一个外部 ZIP 含两条同名 `x.txt`，内容分别为 `A` 与 `B`
- **THEN** `read("x.txt")` 返回 `B`

#### Scenario: readAll 返回全部

- **WHEN** 同上 ZIP
- **THEN** `readAll("x.txt")` 返回长度 2 的数组，元素依次为 `A`、`B`
- **AND** 目录条目（`isDirectory` 为真，如 `sub/`）不进结果，即使名字匹配也返回空数组

#### Scenario: 名字不存在

- **WHEN** `read("absent.txt")`
- **THEN** 返回 `None`，不抛异常

#### Scenario: contains

- **WHEN** 对存在与不存在的名字分别调用 `contains`
- **THEN** 分别返回 `true` 与 `false`

### Requirement: 流式打开条目

`ZipReader.open(name: String): ?InputStream` SHALL 返回该条目解压后的限长流，SHALL 在每次调用时**另开独立的文件句柄**（`init(input)` 构造时使用独立缓冲游标），使多个 `open` 可以并发读取而不互相打乱位置。流读到结尾时 SHALL 校验 CRC32 与 `uncompressedSize`，不一致时抛出 `ZipException`。

#### Scenario: 并发读四个条目不串数据

- **WHEN** 用 `init(path)` 构造后，对四个不同条目同时 `open` 并交替读到结尾
- **THEN** 四条数据分别与各自原始内容逐字节一致

#### Scenario: 读到 EOF 才校验

- **WHEN** `open` 返回的流被读到 EOF，且中央目录记录的 CRC 与数据不匹配
- **THEN** 在 EOF 处抛出 `ZipException`，消息形如 `CRC 校验失败：期望 ${exp}，实际 ${act}（${name}）`

#### Scenario: 不存在的条目

- **WHEN** `open("absent.txt")`
- **THEN** 返回 `None`

### Requirement: 以中央目录为准解析

`f_zip` SHALL 一律从中央目录取 `crc32` / `compressedSize` / `uncompressedSize` / `method`，SHALL NOT 信任 local header 中的同名值（bit 3 置位时 local header 的这些字段可能为 0）。local header 只用于定位数据起点（跳过 name 与 extra）。

#### Scenario: bit 3 置位的条目

- **WHEN** 读取一个 local header 的 crc 与 size 全为 0、真实值在 data descriptor 与中央目录中的流式条目
- **THEN** 读取成功，CRC 与大小以中央目录为准校验通过

#### Scenario: local header 与中央目录不一致

- **WHEN** 构造一个 local header 声称 size 为 0、中央目录声称真实大小的 ZIP
- **THEN** 解压按中央目录的大小进行，不因 local header 的 0 而返回空

### Requirement: 解压校验与原子性

`read(name)` / `open(name)` SHALL 在解压完成后校验 CRC32 与 `uncompressedSize`。校验失败或被上限中断时 SHALL 抛出 `ZipException`，SHALL NOT 返回部分数据。

#### Scenario: 大小不符

- **WHEN** 中央目录声明 `uncompressedSize` 为 100，实际解压出 90 字节
- **THEN** 抛出 `ZipException`，不返回这 90 字节

#### Scenario: 截断的压缩流

- **WHEN** 压缩数据被截断、解压中途结束
- **THEN** 抛出 `ZipException`，消息说明结构不完整

### Requirement: ZipLimits 四道上限

`ZipLimits` SHALL 是可覆盖的只读配置，含四个字段与默认值：`maxEntrySize = 512 MB`、`maxTotalSize = 2 GB`、`maxEntries = 65535`、`ratioWarnThreshold = 1000`。

- 单条目解压超过 `maxEntrySize` → 中断并报错，不返回部分数据（先用中央目录的 `uncompressedSize` 提前拒绝，再按实际解压字节兜底）
- 本次累计解压超过 `maxTotalSize` → 中断；计数按**实际解压出的字节**累加，不采信 header 的 `uncompressedSize`
- 中央目录条目数超过 `maxEntries` → **在解析中央目录的过程中**拒绝，不先建完整列表
- 压缩比超过 `ratioWarnThreshold` → 记 warning 日志后继续

头部声明值只用于提前拒绝，超过上限的判定以实际解压字节为准。

#### Scenario: 单条目超限

- **WHEN** 用 `ZipLimits(maxEntrySize: 1024)` 读取一个解压后 4096 字节的条目
- **THEN** 抛出 `ZipException`，消息形如 `解压体积超过上限 1024（${name}）`

#### Scenario: 累计超限

- **WHEN** 用 `ZipLimits(maxTotalSize: 3000)` 依次读取两个各 2000 字节的条目
- **THEN** 第一条成功，第二条抛出超限异常

#### Scenario: 计数不采信 header

- **WHEN** 一个条目的 header 声称 `uncompressedSize` 为 1，实际解压出超过 `maxTotalSize` 的字节
- **THEN** 在累计超过上限时立即中断，不因为 header 的 1 而放行

#### Scenario: 头部声明值只用于提前拒绝

- **WHEN** 一个条目的中央目录 `uncompressedSize` 超过 `maxEntrySize`
- **THEN** 不启动解压，直接抛出超限异常
- **AND** 另一个条目声明值在上限内、实际解压字节超过上限时，仍按实际字节中断

#### Scenario: 条目数在解析期拒绝

- **WHEN** 用 `ZipLimits(maxEntries: 10)` 读取一个中央目录声明 11 条的 ZIP
- **THEN** 抛出 `ZipException`，消息形如 `条目数 11 超过上限 10`
- **AND** 不构造出 11 个 `ZipEntry`

#### Scenario: 高压缩比只告警

- **WHEN** 读取一个压缩比 2000 倍但总量在限额内的条目
- **THEN** 数据正常返回，仅产生一条 warning 日志

#### Scenario: 上限可按实例覆盖

- **WHEN** 用 `ZipLimits(maxEntrySize: 8L * 1024 * 1024 * 1024)` 构造 reader
- **THEN** 该实例的单条目上限为 8 GB，其它实例不受影响

### Requirement: maxTotalSize 是每实例累计

`maxTotalSize` SHALL 按**单个 `ZipReader` 实例**累计，SHALL NOT 是进程级全局闸门。此语义 SHALL 写入 `ZipReader` 的 KDoc 与 `f_zip/doc/api.md`。

#### Scenario: 两个实例各自计数

- **WHEN** 两个 `ZipReader` 实例各有 2000 字节的读取量，`maxTotalSize` 均为 3000
- **THEN** 两个实例分别成功，互不影响

#### Scenario: 同实例跨 read 与 open 累计

- **WHEN** 在同一实例上先 `read` 一个 2000 字节条目，再 `open` 另一个 2000 字节条目读到 EOF
- **THEN** 第二次读取触发累计超限

### Requirement: 关闭语义

`ZipReader.close()` SHALL 释放 `init(path)` 打开的文件句柄，SHALL 幂等（重复调用不抛异常）。关闭后调用 `entries()` / `read()` / `open()` SHALL 抛出 `ZipException`。

#### Scenario: 重复关闭

- **WHEN** 连续调用 `close()` 两次
- **THEN** 不抛异常

#### Scenario: 关闭后读取

- **WHEN** `close()` 之后调用 `read` 或 `open`
- **THEN** 抛出 `ZipException`，说明 reader 已关闭

### Requirement: unzip 便捷解压

`f_zip` SHALL 提供 `unzip(input: InputStream, dir: Path, limits!: ZipLimits = ZipLimits()): Int64` 与 `unzip(path: String, dir: Path, limits!: ZipLimits = ZipLimits()): Int64`，把全部条目解压到目标目录并返回解压的文件数。路径校验与符号链接策略见 `f-zip-security`。目标目录不存在时 SHALL 自动创建；同名文件 SHALL 覆盖（与 `read` 取最后一个的语义一致）。

#### Scenario: 解压并返回文件数

- **WHEN** 解压一个含 3 个文件与 2 个目录条目的 ZIP
- **THEN** 返回 `3`

#### Scenario: 嵌套路径自动建目录

- **WHEN** 解压含 `a/b/c.txt` 的 ZIP 到空目录
- **THEN** `a/b/` 被自动创建，`c.txt` 内容逐字节正确

#### Scenario: 路径构造走 seek 不爆内存

- **WHEN** 用 `unzip(path, dir)` 解压一个 1 GB 的 ZIP
- **THEN** 进程 RSS 不随文件大小线性增长

#### Scenario: 目录条目被创建

- **WHEN** ZIP 中含名字以 `/` 结尾的空目录条目 `empty/`
- **THEN** 目标目录下存在 `empty/`

### Requirement: 读取侧不应用路径策略

`ZipReader.read(name)` / `open(name)` SHALL NOT 实施任何路径安全策略——它们只返回字节。路径校验只在 `unzip` 中执行。这样调用方自己做解压时不会被 reader 挡掉。

#### Scenario: 含穿越路径的条目仍可读取

- **WHEN** 一个 ZIP 含条目名 `../evil.txt`，内容为 `X`
- **THEN** `read("../evil.txt")` 返回 `X`
- **AND** `contains("../evil.txt")` 为 `true`

#### Scenario: unzip 会拒绝同一条目

- **WHEN** 用 `unzip` 解压同一个 ZIP
- **THEN** 抛出 `ZipException`，消息形如 `条目路径非法：../evil.txt`
