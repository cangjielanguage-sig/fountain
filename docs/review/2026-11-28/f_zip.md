# f_zip 模块审查报告

> **本文件是抽样版（v1）**：只读了部分文件，已被 `f_zip_v2.md`（全量、逐文件覆盖）取代；结论以 v2 为准。


- **审查日期**：2026-11-28
- **模块路径**：`f_zip`（55 个文件：42 个 .cj + 13 个 .md）
- **基线**：工作区快照（sts/1.3.x 工作区，master 同提交 120fd2542，无分支差异）
- **审查重点**：防 zip bomb 的限额是否按实际字节、zip-slip 校验、文件源并发读、解压流的资源释放、README 与实现一致性
- **报告版本**：v1（由主 Agent 直接审查；`ZipReader` / `ZipLimits` / `FileSource` / `Unzip` 逐段读，写出侧与测试为抽查）

## 发现

### [一般][存量] 压缩比只告警不拦截，默认 `maxTotalSize` 2 GB 已足以打爆小内存机器

- **位置**：`f_zip/src/ZipLimits.cj:25-48`（`ratioWarnThreshold` 默认 1000，注释明说「只记 warning，不拦截」；`maxTotalSize` 默认 2 GB、`maxEntrySize` 默认 512 MB）
- **来源**：存量
- **判据**：review-checklist §5（OOM：按不可信长度预分配 / 无界物化）、§11（限额与意图不符）
- **证据**：静态确定 —— 限额按**实际解压字节**累加（`ZipReader.cj:270-280`，这点是对的，不采信 header），但阈值本身是 2 GB；`ratioWarnThreshold` 只产生 warning
- **描述**：一个 100 KB 的 zip 在默认配置下可以合法地解出 2 GB（`read()` 直接物化到 `ByteBuffer`），足以让 1-2 GB 规格的容器 OOM 被杀。压缩比告警不拦截意味着日志里只会有一条 warning，进程随后仍然被撑死。文档澄清了「这是实例级上限」，但默认值对服务端场景偏松
- **建议**：默认改小（如 64 MB / 256 MB），并把「压缩比 > 阈值即拒绝」做成可开关的默认开启项；或让 `read()` 强制走 `open()` 的流式路径

### [一般][存量] `FileSource.readAt` 对共享 `File` 做 `seek` + `read`，是单线程假设下的实现

- **位置**：`f_zip/src/EntrySource.cj:89-110`（`file.seek(Begin(offset))` 后 `file.read(...)`）
- **来源**：存量
- **判据**：review-checklist §12.1（共享可变状态）、§11（契约与实现）
- **证据**：静态确定 —— `ZipReader` 的类注释承诺「解析完成后 `entries()` / `read()` / `contains()` 只读，可并发调用」（`ZipReader.cj:34-35`），而 `FileSource` 只有一个 `File` 句柄，`readAt` 的「定位-读取」两步不是原子的
- **描述**：当前 `readAt` 只在 `loadDirectory()` 阶段（构造期、单线程）经 `readFullyAt` 调用，条目数据走 `openRange`（`FileRangeInputStream` 自带独立句柄），所以**今天不出错**。但这是隐性契约：任何人把 `readAt` 用于并发条目读取（看起来完全合理——方法名和注释都没拦），就会读到别人的窗口数据，且错误表现为「CRC 校验失败」这种完全指错方向的现象
- **建议**：改用 `pread`（不改变文件游标）或在方法上写明「仅构造期单线程可用」并在调试构建里断言

### [轻微][存量] `ZipReader.closed` 是无同步的 `var`，close 与并发读之间存在竞态

- **位置**：`f_zip/src/ZipReader.cj:47`、`:159-172`
- **来源**：存量
- **判据**：review-checklist §12.1（可见性）
- **证据**：静态确定 —— `private var closed = false`（第 47 行），`close()` 写、`ensureOpen()` 读，均无锁/原子量
- **描述**：一个线程 `close()` 的同时另一个线程 `read()`，后者可能读到旧的 `false`，随后在已关闭的 `FileSource` 上读（返回 0 字节）→ 抛 `ZipException("解压体积…")` 或 CRC 错，错误信息指向体积而不是「已关闭」。`close()` 本身幂等（这点没问题）
- **建议**：`closed` 改为 `AtomicBool`，`ensureOpen` 用 `load()`

### [轻微][存量] `FileSource.close()` 静默吞掉关闭失败

- **位置**：`f_zip/src/EntrySource.cj:116-123`
- **来源**：存量
- **判据**：review-checklist §3（静默吞异常）
- **证据**：静态确定 —— `try { file.close() } catch (_: Exception) {}`
- **描述**：文件句柄关闭失败（NFS 断开、fd 已被回收）没有任何痕迹，泄漏的 fd 只能靠 `lsof` 发现
- **建议**：`catch` 里 `debug` 一条带路径的日志；`close()` 的返回值语义保持不变

## 优化可行性方案

### [堆内存] `decodeEntry` 的输出缓冲可以按 `uncompressedSize` 预分配（但有上限）

- **现状**：`decodeEntry` 用 `ByteBuffer(initialCapacity: 8192)` + `out.write(chunk)` 逐块增长（`ZipReader.cj` 的 `decodeEntry`），512 MB 条目会经历多次扩容与拷贝
- **方案**：当 `e.uncompressedSize` 合理（≤ `min(maxEntrySize, 实际可能值)`）时按它预分配，异常值仍从 8192 起
- **预期**：大条目（>8 MB）少 3-6 次整块拷贝；需实测
- **代价**：不采信 header 的原则被局部放宽（必须保留上限保护，否则退回「按不可信长度预分配」的坑）
- **验证**：`cjpm bench -O2` 跑 50 MB 单条目解压 100 次，比较中位耗时与分配字节
- **证据状态**：`无基线（待验证，不进 tasks）`

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `read()` 在真实业务里是否被用于 >64 MB 的条目 | `ZipReader.cj:89-95` | 调用方条目大小分布 | 在 fdemo / f_probe 的调用点埋计数（条目大小分桶），跑一周 |
| 2 | 8082 字节块大小对 zlib 解压是否最优 | `ZipReader.cj` `decodeEntry` 的 `chunk` | 吞吐随块大小变化 | `cjpm bench -O2` 扫 4K/8K/32K/64K |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1–13 | `f_zip/README.md`、`README_en.md`、`doc/**`（11 个） | .md | 未读 | 仅从源码注释核对契约；README 未逐行读 |
| 14 | `f_zip/src/ZipReader.cj` | .cj | ✅（主体） | 见发现 1/3 |
| 15 | `f_zip/src/ZipLimits.cj` | .cj | ✅ | 见发现 1 |
| 16 | `f_zip/src/EntrySource.cj` | .cj | ✅（部分） | `FileSource` 段；见发现 2/4 |
| 17 | `f_zip/src/Unzip.cj` | .cj | 部分 | 抽查 `resolveSafeTarget`（拒绝绝对路径 / `..` / 规范化越界）与 `Unzip_security_test.cj` 的三类用例 |
| 18 | `f_zip/src/ZipWriter.cj` | .cj | 未读 | 写出侧 |
| 19 | `f_zip/src/LocalHeader.cj` / `CentralHeader.cj` / `Eocd.cj` / `LeBytes.cj` / `BoundedStream.cj` / `EntryNameTable.cj` | .cj | 未读/抽查 | 只从 `ZipReader` 的调用面推断契约 |
| 20 | `f_zip/src/*_test.cj`（8 个） | .cj | 未读 | 抽查 `Unzip_security_test` |

合计：`.cj` 4 个逐段读完 + 1 个抽查 / 37 个未读；`.md` 13 个未读。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 2 | 发现 1（默认上限）、2（隐性单线程契约） |
| §1 死代码 | 0 | 只对已读文件做了符号检索；未读文件未做 |
| §2 重复逻辑 | 0 | 已读文件未发现同构实现 |
| §3 空实现 | 1 | 轻微 2（空 catch） |
| §4 栈溢出 | 0 | 无递归 |
| §5 OOM | 1 | 发现 1 |
| §6.1 热点瓶颈 | 0 | 无 profile；优化方案已标无基线 |
| §6.2 大粒度锁 | 0 | 读取路径无全局锁（限额用 `AtomicInt64`） |
| §6.3 并发串行 | 0 | `open()` 每次独立句柄，设计正确 |
| §6.4 低效算法 | 1 | 输出缓冲扩容（优化方案） |
| §7 降堆内存方案 | 1 | 同上 |
| §8 降 CPU 方案 | 0 | 需 bench |
| §9 local mode 可行性 | 0 | 大对象是返回值（必须逃逸），不适用 |
| §11 现有代码的 BUG（存量） | 2 | 发现 2/3 |
| §12 并发安全与锁粒度 | 2 | 发现 2/3 |
| §14 功能完备性与 README 覆盖 | 0 | README 未读，未做对照 |
| 文件覆盖（§13 等） | 8/55 | 未读项见上表 |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 0 |
| 一般 | 2 |
| 轻微 | 2 |
| 优化方案（堆内存 / CPU） | 1 / 0 |

## 总评

这是本轮审查里少见地「防线写在代码注释里并且落实到实现」的模块：限额按**实际解压字节**计数（不采信 header 的 `uncompressedSize`）、`maxEntries` 在解析中央目录时就拒绝、`open()` 每次独立句柄因此可并发、`unzip` 有独立的 `resolveSafeTarget` 且配了三条安全用例、`close()` 幂等。剩下的都是「默认值偏松」与「隐性契约没写死」：默认 2 GB 累计上限对服务端偏大，`FileSource.readAt` 借共享句柄做 seek 但没标注单线程约束。没有严重项。存量 4 条（一般 2 / 轻微 2），是否纳入修复待用户决定。
