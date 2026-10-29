# f_zip 公开 API 速查

`fountain::f_zip` 对外只有九个名字：

| 名字 | 形态 | 用途 |
| --- | --- | --- |
| `ZipReader` | class | 读 ZIP（内存流 / 文件路径两种构造） |
| `ZipWriter` | class | 写 ZIP（内存路径 / 流式路径） |
| `ZipEntry` | struct | 中央目录里的一条条目（只读） |
| `ZipLimits` | struct | 读取侧四道上限（可覆盖） |
| `ZipWriterOptions` | class | 写入选项（阈值 / 临时目录 / 压缩方法） |
| `CompressionMethod` | enum | `Stored` / `Deflate` |
| `ZipException` | class | 唯一异常类型 |
| `zip` | func | 目录 → ZIP |
| `unzip` | func | ZIP → 目录 |

---

## 读取

```cangjie
// 从流：整包进内存（网络流、内存里的 zip、xlsx）
let r = ZipReader(input)            // init(input: InputStream, limits!: ZipLimits = ZipLimits())
// 从文件：File.seek 窗口读，不缓冲整包
let r = ZipReader("a.zip")          // init(path: String, limits!: ZipLimits = ZipLimits())

r.entries(): ArrayList<ZipEntry>    // 中央目录顺序，不合并同名、不排序；每次返回独立列表
r.contains(name): Bool
r.read(name): ?Array<Byte>          // 同名取**最后一个**；不存在返回 None
r.readAll(name): Array<Array<Byte>> // 全部同名**文件**条目，按中央目录顺序（目录条目不返回）
r.open(name): ?InputStream          // 每次另开独立游标，可并发读；读到 EOF 才校验 CRC
r.close(): Unit                     // 幂等；关闭后 entries/read/open 抛 ZipException
```

- **以中央目录为准**：`crc32` / `compressedSize` / `uncompressedSize` / `method` 全部取中央目录，
  不信任 local header（bit 3 置位时那里的值可能是 0）。
- **读取层不做路径策略**：`read("../evil.txt")` 照常返回字节；路径校验只在 `unzip` 里执行。
- `ZipEntry.modifiedAt` 是 `Option<DateTime>`：DOS 时间为全 0 时返回 `None`（"没有时间信息"比伪造
  1980-01-01 更诚实）。

## 写入

```cangjie
let w = ZipWriter(output)                                   // 默认 ZipWriterOptions()
let w = ZipWriter(out, options: ZipWriterOptions.forServer()) // 64 MB 阈值

w.position: Int64          // 已写出字节数，单调递增，close() 前不含中央目录
w.spilling: Bool           // 当前 add() 是否在"落临时文件"阶段

w.add(name, data): String          // 内存路径（bit 3 = 0，无 descriptor）
w.addFileStream(name, input): String // 流式路径（bit 3 = 1，24 字节 ZIP64 descriptor）
w.addFile(name, path): String      // 流式加一个磁盘文件（跟随符号链接）
w.addDirectory(name): String       // 目录条目（自动补 `/`，同名合并）
w.close(): Unit                    // 必须调用；幂等
```

- 所有 `add*` 返回**实际写入的名字**（同名冲突会被改名：`a.txt → a_2.txt`）。
- **`tempDir` 是首选目录，不是排他项**：`add()` 超阈值落盘时按
  `ZipWriterOptions.tempDir` → `TMPDIR` → 系统临时目录 → `./.fountain_tmp/`（自动创建）逐级回退，
  某一级不可用就试下一级；四级都不可写才抛 `无法创建临时文件，且条目大小 ...`，**不降级回内存**。
- **`ZipWriter` 不是线程安全的**：单条 `OutputStream` 顺序写，同一个 writer 不得并发调用。
  `spilling` 是 `AtomicBool`，可以跨线程读。
- **`spilling` 与 `position` 不保证原子一致**，二者只用于展示，不要拿来做逻辑判断。
- 写入中途抛异常后 writer 进入**脏状态**，此后任何 `add*` / `close()` 都抛
  `条目 ... 写入中断，ZIP 结构不完整`——半截的 local header 无法修补。

## 限额

```cangjie
ZipLimits(
    maxEntrySize!: Int64 = 512 * 1024 * 1024,        // 单条目解压上限
    maxTotalSize!: Int64 = 2 * 1024 * 1024 * 1024,   // 每个 reader 实例的累计上限
    maxEntries!: Int64 = 65535,                      // 中央目录条目数上限（只服务读取）
    ratioWarnThreshold!: Int64 = 1000                // 压缩比告警阈值（只告警）
)
```

- **`maxTotalSize` 是"每个 `ZipReader` 实例的累计"，不是进程级全局闸门。**
  要限制一次批量导入的总量，调用方得自己持剩余配额、逐次传入。
- 计数按**实际解压出的字节**累加，不采信 header 的 `uncompressedSize`。
- **早拒语义**（`ZipLimits` 分两层拦截）：
  ① 中央目录声明的 `uncompressedSize` 已经超过 `maxEntrySize` 时，在**打开条目前**就拒绝，
     一个字节都不解（消息 `解压体积超过上限 ${limit}（${name}）`）；
  ② 声明值没超、实际解压却超了（header 撒谎的炸弹样本）时，按**实际字节**在流式读取中立刻中断，
     不返回部分数据。
  `maxEntries` 也在**解析中央目录的过程中**就拒绝，不会先建完列表再判；写入侧没有条目数上限
  （条目数 **≥ `0xFFFF`** 就自动升级 ZIP64——65535 本身是读取侧的哨兵值）。

## 便捷函数

```cangjie
unzip(input: InputStream, dir: Path, limits!: ZipLimits = ZipLimits()): Int64
unzip(path: String, dir: Path, limits!: ZipLimits = ZipLimits()): Int64
zip(output: OutputStream, dir: Path, options!: ZipWriterOptions = ZipWriterOptions()): Int64
```

- `unzip` 返回解压出的**文件数**（不含目录条目）；目标目录不存在自动创建；同名文件覆盖。
- **`unzip` 遇加密条目不做回滚**：加密检查发生在逐条打开时，出错前已经解出的文件**留在磁盘上**，
  函数直接抛错、不清理已写出的条目（当前这一条自己的半截文件会被删掉）。
  需要"全有或全无"的调用方请解压到临时目录，成功后再整体替换。
- `zip` 返回写入的**文件数**；目录条目也写（空目录能还原）；符号链接一律跳过
  （目录链接跳过整棵子树）。

## 安全默认值

| 风险 | 默认行为 |
| --- | --- |
| Zip Slip | 绝对路径 / `..` 段 / 规范化后在目标目录外 → `条目路径非法：${name}` |
| 符号链接 | `unzip` / `zip` 跳过并记 warning；`addFile` 跟随（调用方指名道姓） |
| ZIP 炸弹 | `ZipLimits` 四道上限，超限中断且不落半截文件 |
| 加密 ZIP | bit 0 / bit 6 置位即 `不支持加密 ZIP（${name}）`，不做部分支持 |

## 与 f_excel 的交接约定

- **拉模式**：`addFileStream` 由 f_zip 主动从 `input` 读。`f_excel` 需要把行迭代器包成惰性
  `InputStream`，不需要 f_zip 提供推模式（`openEntry(name): OutputStream`）。
  （对应 `docs/f_excel模块设计.md:462`）
- `f_excel` 需要的两个构造 `ZipReader(input)` / `ZipReader(path)` 与 `open(name)` 均已可用。
