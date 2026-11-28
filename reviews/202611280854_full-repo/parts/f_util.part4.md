# f_util 模块审查报告（模块第 4/4 部分）

- **审查日期**：2026-11-28
- **模块路径**：`f_util`（本部分 8 个 `.cj`，0 个 `.md`；整模块 48 `.cj` + 19 `.md`）
- **基线**：工作区快照（`HEAD 97507061b`，`git status` 仅有未跟踪的 `docs/review/`、`reviews/` 两个过程目录；`git blame` 在这批文件上全部落在 `4be871f2fd`（2026-10-02 整仓换行符重写），无法细分的提交 ⇒ 本部分 14 条问题**全部记「存量」**）
- **审查重点**：工具类正确性与边界、死代码、重复逻辑、空实现、栈溢出、OOM、并发安全、存量 BUG
- **报告版本**：v1（第 4/4 部分分报告，由主 Agent 合并；不写 `docs/review/` 模块报告）
- **本部分文件**：`exception/IdException` / `exception/TextTemplateException` / `exception/UUIDException` / `geohash` / `prime` / `uuid` / `uuid_test` / `wyhash`
- **验证方式**：只读审查，未跑 `cjpm build` / `cjpm test`，未做性能测量。涉及数值与位运算的结论用 Python 按源码逐行复算（geohash 的 encode/decode、UUID 的 tryParse、v1/v6/v7 时间戳数值），属「静态确定」；性能类一律降级为「待验证假设」

## 发现

### [严重][存量] #1 `GeoHash.encode` 的置位方向与区间收缩方向相反，整个半球坍缩成同一个哈希

- **位置**：`f_util/src/geohash.cj:38-57`（`encode` 的经纬度分支，关键 `:41-47`、`:49-55`）；受害方 `:66-91`（`decode`）、`:112-124`（`tryParse` 末尾的 `encode(lng, lat)`）
- **来源**：存量（快照模式无基线；blame 落在 `4be871f2fd`）
- **判据**：review-checklist §11「逻辑错误 / 语义与命名不符」+ §10「正确性」
- **证据**：静态确定 —— `if (midlng >= longitude)` 成立表示输入点落在**下半区**，位被置 1，但分支里执行的是 `lowlng = midlng`（把区间收缩到**上半区**）。区间从此永远背离输入点，下一轮比较也就失去意义。按源码逐行复算（与 `decode` 的位语义一起）：
  - `encode(10.0, 10.0) = 0x0000000000000000` → `decode` = `(-179.99999992, -89.99999996)`
  - `encode(-10.0, -10.0) = 0xffffffffffffffff` → `decode` = `(179.99999992, 89.99999996)`
  - `encode(116.4, 39.9) = 0x0`、`encode(-73.9, 40.7) = 0xaaaaaaaaaaaaaaaa`
  每个轴的位只由该坐标的**符号**决定（正 → 全 0，负 → 全 1），于是四个象限只剩 `0x0` / `0x5555…` / `0xaaaa…` / `0xffff…` 四个可能值，64 位编码退化成 2 位。
- **描述**：`decode`（`:74-89`）与 `tryParse`（`:115-121`）都把位 1 解释为「取上半区」，与 `encode` 的区间更新正好相反。因此 `decode(encode(x))` 不但不落在 x 的格子里，还把整象限压成 2 个值；`parse(toString(h))` 同理不成立（`toString` 输出的 32 个四进制字符由位直接拼出，`tryParse` 再 `encode` 回来必然翻面）。任何「按 geohash 前缀做邻域检索 / 空间分桶」的用法都会完全失效，且不会抛异常，只给出错误结果。`f_util/src/geohash.cj` 在仓内无调用者（`grep GeoHash` 只命中 README 与 `GeoHashException` 的引用），因此这个 P0 一直没被下游暴露。
- **建议**：把两个分支的区间更新对调（`midlng >= longitude → highlng = midlng`，`else → lowlng = midlng`，纬度同理），或保留区间更新、把比较改成 `longitude >= midlng`；`tryParse` 末尾不要依赖 `encode` 重算，直接从已收缩的区间取中点构造。补用例：`encode(116.4, 39.9).decode()` 与原点误差小于 1 个格（约 1e-6 度量级）、`parse(toString(h)) == h`、四个象限各 1 例。

### [一般][存量] #1b `GeoHash.tryParse` 不校验串长、`encode` 不校验坐标范围，`parse` 的失败面只剩「非法字符」

- **位置**：`f_util/src/geohash.cj:105-124`（`tryParse` 全循环没有长度判定）、`:31-60`（`encode` 不检查 `longitude ∈ [-180,180]`、`latitude ∈ [-90,90]`）、`:125-127`（`parse`）
- **来源**：存量（blame `4be871f2fd`）
- **判据**：review-checklist §11「空集合/空串未处理、边界校验缺失」+ §3「契约承诺有行为」
- **证据**：静态确定 —— 每个 rune 只贡献 2 位，`tryParse` 对 0/1/31/33 个字符的输入都照常收缩区间并返回 `encode(lng, lat)`：`GeoHash.parse("")` 返回 `encode(0.0, 0.0)`（不抛 `GeoHashException`），31 字符的串也被接受。README `:315`、`:317` 明确写「把**四进制字符串**转成 GeoHash」，`toString()` 固定输出 32 个字符（`62 ..= 0: -2` 共 32 轮），接口契约是 32 位；`encode(200.0, 100.0)` 同样不报错，静默给出越界坐标的哈希。
- **描述**：`GeoHashException` 只在出现 `0-3` 以外字符时才会抛（`:126`），长度与取值范围这两个更常见的输入错误全部静默通过。配合 #1，`parse("")` 与 `parse("0" * 32)` 都没有可用的语义，使用者无法区分「空串」「半截串」「合法串」。
- **建议**：`tryParse` 入口加 `if (hash.size != 32) return None<GeoHash>`（`String.size` 是字节长度，见 `std/core/core_package_api/core_package_structs.md:6181-6189`），循环末尾再从区间中点取值而不是重新 `encode`；`encode` 对越界坐标抛 `GeoHashException` 或明确截断并在注释里写清。补「空串 / 31 字符 / 33 字符 / 越界坐标」四个负例。

### [严重][存量] #2 `UUID.timestampNanos` / `timestamp` 三个版本分支全部算错：v1/v6 溢出抛异常，v7 写入端错位、读回端量纲错

- **位置**：读侧 `f_util/src/uuid.cj:116-173`（`timestampNanos`，关键 `:168`、`:171`）、`f_util/src/uuid.cj:174-183`（`timestamp`）；写侧 `f_util/src/uuid.cj:392-409`（`unixTimeBased`，关键 `:397`）
- **来源**：存量（blame `4be871f2fd`）
- **判据**：review-checklist §11「边界/数值错误、错误处理缺失」+ §10「正确性」；整数溢出语义见 `std/overflow/overflow_package_overview.md:7`（默认抛异常）
- **证据**：静态确定，三处独立错误：
  1. **v1/v6 溢出**：`n` 是 1582-10-15 起算的 100 ns 计数，2026 年约 `1.40e17`；`:171` 的 `n * 100` = `1.40e19`，超过 Int64 上限 `9.22e18` ⇒ 抛 `OverflowException`。临界点约 1874 年（`9.22e18 / 100 / 1e7 s ≈ 292 年`，1582 + 292），即**所有现代 v1/v6 UUID 取 `timestampNanos` 都会抛异常**，`timestamp` 先读它，同样抛。同文件 `:711-712` 的注释（“1582 年至今的纳秒数超过 Int64 上限……必须拆成秒 + 纳秒余数”）证明作者知道这个量装不下 Int64，`timestampNanos` 却又原样乘了 100。
  2. **v7 死表达式 + 量纲错**：`:168` 的 `n * 10000` 是 match 分支里的**孤立表达式**（没有赋值给 `n`），值被丢弃；随后 `:171` 只乘 100，而 v7 时间戳是毫秒，正确换算应是 ×1e6。
  3. **v7 混入随机位**：`:149-151` 把 `values[6] & 0xf`（v7 布局里 byte6 的低 4 位，即 `rand_a` 的高 4 位）与 `values[7]`（`rand_a` 低 8 位）拼进了时间戳，12 位随机数污染时间。
  4. **v7 写侧错位**：`:397` 用 `(millis >> (7 - i) * 8)` 往 6 个字节里写 48 位 `unix_ts_ms`，位移应按 6 字节算成 `(5 - i) * 8`。结果是 `(ms << 16) mod 2^48`：`ms = 1.76e12` 时该字段解码回来是 8944 年（复算值 `0xc82cc0000000`），并且每 `2^32 ms ≈ 49.7 天`回绕一次，跨周期的字符串不再单调。
- **描述**：README `f_util/README.md:534`、`:538` 把 `timestampNanos` / `timestamp` 列为公开能力，`:577` 写明 v7「基于 UNIX 时间戳」；实际三条路径都不能用。下游已经踩到：`fdbm/src/idmaker/IdMakers_test.cj:194` 的注释直接写「`timestampNanos` 对 1582 年起算会超出 Int64，故单测自行解码」，并在 `:195-210` 手写了一份位解码绕过该公开属性——这是缺陷被外部绕开的直接证据。v7 的写侧错误还会让任何外部工具（数据库 `uuid_extract_timestamp`、其他语言的 UUID 库）读出错误时间，`fdbm` 的 v7 主键也受影响。
- **建议**：把「1582 起算 100 ns」这个量从 `Int64` 纳秒口径里拿掉——`timestampNanos` 改成返回 `timestamp` 派生值（`(DateTime.UnixEpoch, Duration)` 或 `timestamp.toUnixNanoseconds` 之类的可用口径），v1/v6 分支不做 ×100，`timestamp` 用「秒 + 余数」拼 `Duration`；v7 写侧改 `(5 - i) * 8`，读侧只取 `values[0..5]` 组成 48 位 ms 并 `× 1e6`，`values[6]` 的低 4 位与 `values[7]` 归 `rand_a` 不参与时间；删掉 `:168` 的孤立表达式。补 v1/v6/v7 三个 `timestamp` 往返用例（固定字节数组，断言具体 `DateTime`）。

### [严重][存量] #3 `qpow` 的 UInt64 乘法溢出，`isPrime` 对大于 2^32 的输入直接抛 `OverflowException`

- **位置**：`f_util/src/prime.cj:31`（`ans = (ans * aa) % m`）、`:34`（`aa = (aa * aa) % m`）；调用链 `:44`（`millerRabin` 里 `qpow`）→ `:68`（`isPrime` 里 `millerRabin`）
- **来源**：存量（blame `4be871f2fd`）
- **判据**：review-checklist §11「数值溢出、错误处理缺失」+ §10「正确性」；溢出默认抛异常见 `std/overflow/overflow_package_overview.md:7`
- **证据**：静态确定 —— `aa < m`，只要 `m > 2^32`，平方链就会触到 `2^64`：例如 `p = 4294967311`（2^32 后的素数）时平方链为 `2 → 4 → 16 → 256 → 65536 → 4294967296`，下一步 `4294967296² = 2^64` 溢出。默认整数运算溢出抛 `OverflowException`（`wyhash.cj:36-37` 正是显式加 `@OverflowWrapping` 才敢做无检查乘法，`prime.cj` 没有任何标注），所以 `isPrime(p)` 在 `p > 2^32` 时不是返回 `false`，而是抛异常。另一个独立问题：`:63` 的基集合 `[2,3,5,7,11]` 只保证 `p < 3,474,749,660,383` 内确定，超过后存在强伪素数（当前被溢出先挡住，修好溢出后会暴露）。
- **描述**：`isPrime(p: UInt64): Bool` 的入参契约是 UInt64 全域，`UInt64` 是它的唯一卖点；实际可用范围只有 2^32 以内的幸运值和 2^32 以上的必炸。`qpow` / `millerRabin` / `isPrime` 三个都是 `public`，README `f_util/README.md:408-418` 只抄了注释没有写上限。仓内无调用者（`grep isPrime|qpow|millerRabin` 除 README 外零命中），所以属于「对外 API 一用就炸」，不是线上事故。
- **建议**：`qpow` 改用 128 位中间量（`f_util` 已有 `UInt128`；或 `std.math.numeric.BigInt` 的 `%`），并给 `m == 0` / `m == 1` 明确语义；`isPrime` 先做小素数试除与 `p < 3.47e12` 的确定界检查，超出后改用 12 基或 BPSW；把「支持范围」写进函数注释与 README，不要留 `UInt64` 全域的假契约。

### [一般][存量] #4 `UUID.tryParse` / `parse` 两侧都错：接受尾部垃圾、拒绝大写、`Nil` / `Max` 无法往返

- **位置**：`f_util/src/uuid.cj:192-251`（`tryParse`，关键 `:225-246` 的字节循环、`:247-249` 的 variant 门槛、`:196-221` 的 `doParse`）；`:189-191`（`parse` 抛 `IllegalArgumentException`）
- **来源**：存量（blame `4be871f2fd`）
- **判据**：review-checklist §11「边界校验缺失 / 契约与实现不符」+ §3「公开契约承诺有行为但实现打折」
- **证据**：静态确定，按源码复算：
  - `:193` 只校验字节长度 36；循环在 `i == 16` 就退出，**不检查 rune 迭代器是否耗尽**。`"f47ac10b58cc4372a5670e02b2c3d479zzzz"`（32 个 hex + 4 个垃圾字符）被成功解析成 `f47ac10b58cc4372a5670e02b2c3d479`。
  - `:247` 的 `values[8] >> 6 != 2` 硬性要求 RFC 变体，于是 `UUID.parse(UUID.Nil.toString())`（变体 0）与 `UUID.Max`（变体 3）都抛 `IllegalArgumentException` —— `parse(x.toString()) == x` 这个 `Parsable` 基本契约不成立，也读不进 NCS / 微软变体的存量 UUID。
  - `doParse`（`:196-221`）只认 `r'a'..r'f'`，大写 UUID（很多系统默认大写输出）一律 `None`。
- **描述**：三个现象同一根因——手写解析只做到「能凑够 16 字节」，既没有收尾校验，又额外加了一个比 RFC 更严的变体门槛，且大小写支持不对称（同文件的 `ether` 解析就支持大写）。`parse` 抛 `IllegalArgumentException`，而同类「读值失败」的 `timestamp`（`:180`）抛 `UUIDException`，同一类型的错误出现两个异常族，调用方无法统一捕获。
- **建议**：循环结束后断言 `iterator.next()` 为空；变体判定改成 `(values[8] & 0xc0) == 0x80`（RFC 变体是 `10xxxxxx`），或把变体检查从 `tryParse` 下沉到需要它的地方；hex 解析抽成大小写都收的 `private func hexValue(c: Rune): ?Byte` 供 `tryParse` 与 `ether` 共用；`parse` 改抛 `UUIDException`。补 Nil/Max/大写/尾垃圾/缺 `-` 五种用例。

### [一般][存量] #5 `UUID.sha1` 生成的 v5 与 RFC 9562 不一致（byte 6/7 取摘要的 sha[18]/sha[19]）

- **位置**：`f_util/src/uuid.cj:359-377`（关键 `:366-370`）
- **来源**：存量（blame `4be871f2fd`）
- **判据**：review-checklist §11「契约与实现不符」；契约源 `f_util/src/uuid.cj:33-35`（`reference https://www.ietf.org/archive/id/draft-ietf-uuidrev-rfc4122bis-00.html`）与 README `:564-570`（「version 5」+ `sha1` 签名）
- **证据**：静态确定 —— v5 规定取 SHA-1 摘要前 16 字节，仅把 byte6 高 4 位置为版本、byte8 高 2 位置为变体；实现把 byte6、byte7 改成摘要的第 18、19 字节（`sha[18] & 0xf | 5 << 4`、`sha[19]`），其余取 `sha[i]`。这四个字节覆盖了 name 的哈希值，与任何标准实现（Python `uuid.uuid5`、Java `nameUUIDFromBytes`）都不相等。
- **描述**：`UUID.sha1("x")` 看起来是 v5，但按名字生成同一 UUID 的跨语言约定失效——多语言共用一张按名字派生 ID 的表时会对不上，而且不会有任何报错。注释 `:351` 自己也在讨论这段布局「原文是 md5_low，此处应该是一个错误」，说明这块是照图抄写时出的偏差。`randomSha1` 只做随机哈希，不受影响。
- **建议**：`values[i] = if (i == 6) (sha[6] & 0xf) | (5 << 4) else if (i == 8) (sha[8] & 0x3f) | (2 << 6) else sha[i]`，即只用 `sha[0..15]`；补黄金值用例（对 RFC 9562 附录测试向量断言）。

### [一般][存量] #6 序列号扩展点不满足 `serialSeq` 语义：同一刻度返回同一序号；生成器恒返 0 时无界自旋

- **位置**：`f_util/src/uuid.cj:689-704`（`registerSequenceGenerator()`，关键 `:696-702`）、`:650-688`（文件版，关键 `:666-668`）、`:497-501`（`genTimestampAndSequence` 的 `while`）
- **来源**：存量（blame `4be871f2fd`）
- **判据**：review-checklist §11「逻辑错误」+ §12.1「有界性」
- **证据**：静态确定 —— `last >= timestamp` 分支直接 `return seq`（文件版 `:667` 同样是 `seq`），既没有 `fetchAdd` 也没有写回文件，于是同一 100 ns 刻度内的第 2、3… 次调用拿到**完全相同**的序号。`TimeBasedUUIDBuilder.generate`（`:577-580`）把该序号写进 byte8/byte9，只要 node 固定（`node(...)`、`eth0()`、`ether(...)`），两次调用就产出逐字节相同的 UUID。另外 `genTimestampAndSequence` 用 `while (timestamp == 0 || seq == 0)` 等非零序号，用户注册的 `(Int64) -> UInt16` 生成器若恒返回 0 就会无界自旋，没有重试上限也没有超时。
- **描述**：`serialSeq` 的语义是「同一时间戳内单调递增的序号」，实现变成「同一刻度内所有 UUID 共用一个序号」。仓内主用方 `fdbm` 每次额外 `randomNode()` 取 6 字节随机 node，所以重复没暴露（`fdbm/src/idmaker/IdMakers.cj:71`），但「按机器 MAC 生成 node」才是 v1 的标准用法，那条路上会产生重复主键。默认构造器里的 `AtomicUInt16` 版本（`:632-635`）反而是正确的递增实现，被 `registerSequenceGenerator()` 替换后行为退化。
- **建议**：同刻度分支改成「原子自增并返回旧值」（`seq.fetchAdd(1)`，CAS 竞争时重取），文件版在同刻度分支把 `seq + 1` 写回；`genTimestampAndSequence` 加最大重试次数，超限抛 `UUIDException`。补「同一 node 连续生成 10^5 个 UUID 无重复」的用例（`fdbm` 现有用例只覆盖随机 node）。

### [一般][存量] #7 `TimeBasedUUIDBuilder` 的可变字段无任何同步，也没有线程安全声明

- **位置**：`f_util/src/uuid.cj:446-501`（`version` / `timestamp` / `seq` / `uid` 由 `randomSeq` / `serialSeq` / `UID` 写）、`:567-585`（`generate` 读）、`:646-654`（`registerSequenceGenerator` / `registerFileSequenceGenerator` 在 mutex 外替换 `seqGen` / `closer`）
- **来源**：存量（blame `4be871f2fd`）
- **判据**：review-checklist §12.1「共享可变状态无保护、发布逸出」+ §12.2（锁粒度）
- **证据**：静态确定 —— `TimestampSequenceBuilder.timestampAndSequence`（`:707-721`）用 `mutex` 保护了时间戳/序号的计算，但结果写回 `TimeBasedUUIDBuilder` 的四个普通 `var`，`generate` 再读它们，两步之间没有任何 happens-before。两个线程共用同一 builder 时：线程 A 可能读到自己的 `timestamp` + 线程 B 的 `seq`（错配），也可能两边都拿到同一对 `(timestamp, seq)` 而与各自的 node 组合失效；`registerSequenceGenerator` 替换闭包同样在锁外。类为 `public`，README `:586-618` 未提线程安全。
- **描述**：缺陷已被下游发现但没回写：`fdbm/src/idmaker/IdMakers.cj:34-36` 的类注释写「builder 的 `timestamp`/`seq` 字段非线程安全，`nextStringId()` 必须持锁（D10）」，并在 `:70-72` 用外部 `Mutex` 串行化。`f_util` 自己既没有文档也没有内建同步，下一个使用者不会知道这条隐含约束。
- **建议**：把 `serialSeq` + `node` 合并为原子的 `nextUUID(...)`（内部持锁，临界区只覆盖字段写入与 16 字节组装，不放 I/O），或至少在类注释与 README 明确「非线程安全，必须外部串行化」；`registerSequenceGenerator` 系列替换 `seqGen` 时取同一把 `mutex`。补 8 线程共用 builder 的断言用例。

### [一般][存量] #8 文件序列号生成器把磁盘 I/O 放在 UUID 生成锁内，并硬编码 `/tmp`、临时文件不清理

- **位置**：`f_util/src/uuid.cj:650-688`（`file.read` / `seek` / `write` / `flush`）、`:709-721`（`synchronized(mutex)` 内调用 `seqGen(timestamp)`）
- **来源**：存量（blame `4be871f2fd`）
- **判据**：review-checklist §6.2「锁内做 I/O」+ §12.2「临界区是否只保护不变量」
- **证据**：静态确定 —— `timestampAndSequence` 在 `synchronized(mutex)` 内调 `seqGen(timestamp)`，文件版每次调用要做 seek + read + seek + write + flush（5 次系统调用，含一次落盘），全部在锁内；`genTimestampAndSequence` 的 `while` 还会在序号为 0 时重复取同一把锁。`:651` 的 `Directory.createTemp('/tmp')` 硬编码 Linux 临时目录，`@When` 没有加平台限制（同文件的 `etherName` 就加了 `@When[os == 'Linux']`），临时目录与 `yyyyMMddHHmmssSSS` 命名的文件在 `close()` 后也不删除。
- **描述**：启用文件版后，全进程取号被串行化到一次 `fsync` 的延迟（毫秒级，随磁盘抖动），UUID 生成吞吐掉到 IOPS 量级；这属于「可选扩展点把主路径变成阻塞路径」。`/tmp` 硬编码让 Windows 上调用直接抛文件异常（`f_util/cjpm.toml` 声明了 mingw 目标），临时文件残留则是每次进程启动新建一个目录 + 一个文件。
- **建议**：文件版改成「启动读一次 + 按区间预分配（例如一次领 64 个序号写回）」，把 I/O 移出每次取号的锁；临时目录走 `std.env` 的临时目录 API 或加参数，`close()` 里删文件；至少补 `@When[os == 'Linux']` 或文档标注平台限制。

### [一般][存量] #9 输入边界缺失：`node(Array)` 不校验 6 字节、`ether` 长度不足报 `UnreachableException`、`randomMd5/randomSha1` 的 `bytes` 未校验

- **位置**：`f_util/src/uuid.cj:564-566`（`node(node: Array<Byte>)` → `node[i]`，i 取到 5）、`:513-550`（`ether` 的 `parse(itr.next())`）、`:314-316`、`:356-358`（`randomMd5` / `randomSha1`）
- **来源**：存量（blame `4be871f2fd`）
- **判据**：review-checklist §11「空集合 / 边界未处理、错误处理缺失」
- **证据**：静态确定 —— `generate`（`:582`）对每个 UUID 调 `node(i - 10)`，i = 10..15 ⇒ 索引 0..5，数组短于 6 直接 `IndexOutOfBoundsException`；`ether` 传入少于 17 个 rune 的串时 `parse(None)` 抛 `UnreachableException`（把「格式不对」报成「不可达」）；`randomMd5(bytes: -1)` 只会在 `SecureRandom.nextBytes` 里炸，负值和超大值都没有前置校验。
- **描述**：三个 `public` 入口都把调用方错误变成不相关的运行时异常，排障时看不到真实原因；`randomMd5(bytes: 10^9)` 还会按调用方给的长度一次性分配。仓内调用点（`fdbm` 用 `randomNode()`）不会踩到，但这是对外契约的一部分。
- **建议**：`node(Array)` 前置 `if (bytes.size < 6) throw UUIDException(...)`；`ether` 解析失败抛 `UUIDException("bad ether address ...")`；`randomMd5/randomSha1` 校验 `bytes > 0` 并给上限（例如 1024）。

### [轻微][存量] #10 死代码：未使用的 `stdx.crypto.crypto.*` import、`timestampNanos` 里的孤立表达式

- **位置**：`f_util/src/uuid.cj:24`、`:168`
- **来源**：存量（blame `4be871f2fd`）
- **判据**：review-checklist §1「未使用的 import、读了不用的表达式」
- **证据**：静态确定 —— `uuid.cj` 内没有任何 `SecureRandom` / `SM4` 等 `stdx.crypto.crypto` 包符号（随机源走 `f_random.ThreadLocalRandom`，SecureRandom 在它内部），`stdx.crypto.digest` 的 `MD5`/`SHA1` 是另外一行 import；`:168` 的 `n * 10000` 位于 match 分支末尾且未被赋值，作为语句其值被丢弃（这是 #2 的可见症状）。
- **建议**：删掉 `:24`；`:168` 按 #2 重写。这一维可以在 `cjlint` 里常态化（`unused import` 应报 warning）。
- **备注**：本部分其余私有符号已逐个搜过：`geohash.cj` 的 4 个 `MAX/MIN` 常量各 4 处使用；`uuid.cj` 的 `h`、`hex`、`toString(withDash:)`、`generate`、`timeLowFirst`、`genTimestampAndSequence`、`emptyCloser`、`timeStart`、`mutex`、`seqGen`、`closer` 均有调用；`wyhash.cj` 的 `SECRET0-3`、`mix`、`r4`、`r8` 均有调用；`internal` 的 `UUID(values:)`、`TimeBasedUUIDBuilder.init`、`TimestampSequenceBuilder.init`/`timestampAndSequence`、`SequenceResource(...)` 均被同类使用。`SequenceResource` 虽是 `public struct`，构造器为 `internal`，仓外不可构造，但其 `public` 成员在类内被真实调用，不判死代码。

### [轻微][存量] #11 重复逻辑：同文件两份手写十六进制解析（大小写行为不一致）+ 五处 version/variant 打戳

- **位置**：`f_util/src/uuid.cj:196-221`（`tryParse` 内 `doParse`）与 `:518-541`（`ether` 内 `parse`）；打戳逻辑 `:321-324`（md5）、`:332-335`（random）、`:363-375`（sha1）、`:395-407`（unixTimeBased）、`:427-441`（custom）
- **来源**：存量（blame `4be871f2fd`）
- **判据**：review-checklist §2「同语义不同写法、字面量复制；近似重复里少了一处边界判断往往是缺陷」
- **证据**：静态确定 —— 两个 hex 转换函数的输入/输出/副作用一致（Rune → Byte），唯一差别是 `parse` 支持大写、`doParse` 不支持，且 `doParse` 用魔法值 16/17 当分隔符与非法哨兵；这正是 #4「大写 UUID 被拒」的成因。五处构造函数都在重复这两组打戳常量——`(x & 0xf) | (v << 4)` 与 `(x & 0x3f) | (2 << 6)`（md5/random 写成两步 `&= …` + `|= …`，其余写成生成器里的单表达式），控制流一处原地改数组、一处 `Array(16){...}`，`unixTimeBased` 的位移错误（#2）就出在生成器那一版。
- **建议**：抽 `private func hexValue(c: Rune): ?Byte`（大小写都收）与 `private func stamped(version: Byte, bytes: Array<Byte>): Array<Byte>`，5 个构造函数共用；分隔符哨兵改用 `?Byte` 表达，不用 16/17。

### [轻微][存量] #12 带副作用的 `prop` + 两段式 builder：连续两次 `node(...)` 产出完全相同的 UUID

- **位置**：`f_util/src/uuid.cj:477-488`（`randomSeq` / `serialSeq` 是 `prop`，每次读都改字段）、`:551-566`（`node` / `randomNode` 依赖上一次读 `serialSeq` 的结果）
- **来源**：存量（blame `4be871f2fd`）
- **判据**：review-checklist §10「可读性 / 命名与语义」+ §11「语义与命名不符」
- **证据**：静态确定 —— `generate`（`:567-585`）用的是字段 `this.timestamp` / `this.seq`，不读 `serialSeq` 就不刷新。`builder.serialSeq.node(1)` 之后再 `builder.node(1)`，两次的 timestamp/seq/node 全同 ⇒ 相同 UUID。`prop` 在 Cangjie 里是属性访问语义，读者不会预期 `builder.randomSeq` 有副作用。
- **建议**：改成 `nextUUID(node: Int64)` / `nextUUIDRandomNode()` 这类一次返回 UUID 的方法，把「刷新时间戳与序号」变成显式动作；或至少把 `randomSeq`/`serialSeq` 改成普通方法并加注释说明「每个 UUID 必须紧跟一次刷新」。

### [轻微][存量] #13 测试只覆盖 `random()`，v1/v6/v7、parse 边界、序列唯一性全裸奔

- **位置**：`f_util/src/uuid_test.cj:21-31`
- **来源**：存量（blame `4be871f2fd`）
- **判据**：review-checklist §14「示例/用例覆盖不足」+ §10 可验证性
- **证据**：静态确定 —— 唯一用例断言 v4 的 `version == 4`、`variant == 2` 与 `toString` ↔ `parse` 往返；#2（三个版本的时间戳）、#4（Nil/Max/大写/尾垃圾）、#5（v5 黄金值）、#6（固定 node 的序号唯一性）涉及的分支零覆盖。`geohash.cj` / `prime.cj` 在本模块也没有任何 `*_test.cj`。
- **建议**：按各条建议补最小用例集；`geohash` 至少一条「四象限 + 往返」，`prime` 至少一条对 2^32 以上的素数（如 `4294967311`）断言 `isPrime` 返回 `true` 且不抛异常。测试文件属本部分，补测不会扩大改动面。

## 优化可行性方案

> 不是缺陷。以下三条都**没有改前基线**，只作为下一轮补数据的候选，不进 `tasks.md`。

### [CPU] O1 `UUID.toString` 每 UUID 一次 `StringGenerator` + 36 次 `append` + 一次字节缓冲拷贝

- **现状**：`:85-101` 每次 `toString()` 新建 `StringGenerator`（内部一个 `ArrayList<Byte>`），循环 16 次、每次 2 次 `append(Rune)` 加 4 次 `append(r'-')`，最后 `toString()` 再把整个缓冲复制成 `String`。`fdbm` 的 uuid 主键、`f_http` 的上传路径（`MultipartFormDataParser.cj:101`）、`f_egraph` 每事件的 `session` 默认值都在这条路径上。
- **方案**：预分配 36 字节 `Array<Byte>`，用 256 项 ASCII 表直接写 `hex`，返回 `String.fromUtf8(bytes)`（或 `String.fromAscii`，按 SDK 可用 API 选）；`toString(radix: 16)` / `toHexString()` 复用同一份 32 字节写入逻辑。
- **预期**：每次转换少 1 次 `ArrayList` 分配与 36 次方法调用，字节缓冲只分配一次。占比未知，需 profile。
- **代价**：`StringGenerator` 自带 UTF-8 编码语义，改成手写 ASCII 需要保证只写 `0-9a-f-`（都是 ASCII，安全）；代码量略增。
- **验证**：`cjprof record` 跑「10^6 次 `UUID.random().toString()`」（`-O2`，同机），看 `toString` 自耗时与分配字节数；改前改后各 10 轮取中位数与 IQR。
- **证据状态**：无基线（待验证，不进 tasks）

### [CPU] O2 `wyhash` 用边界检查索引，std 的同款实现用 `arrayGetUnchecked3`

- **现状**：`f_util/src/wyhash.cj:53-101` 直接 `arr[pos]` 逐字节读取，4/8 字节读取函数（`:130-137`）每次 4~8 次边界检查；`std` 的同名实现（`cangjie_runtime/stdlib/libs/std/core/hashable.cj:996-1046`）用的是 `arrayGetUnchecked3<UInt8>`，其余逻辑逐行相同（本次已逐段对比 `size<4` / `==4` / `<8` / `<=16` / `>48` 五个分支与 `mix`，确认是忠实移植）。
- **方案**：在 `size`/`start` 已在前置校验过（`size <= arr.size - start`）之后，把 `r4`/`r8` 换成内部 unchecked 读（`unsafeGet` / `arrayGetUnchecked`，按 SDK 可用 API），或在模块内加一层 `@OverflowWrapping` 的裸指针读。
- **预期**：每次 hash 少 `len` 次边界检查；`f_bloom` 的布隆过滤器（`f_bloom/src/BloomFilter.cj:61`，`seeds` 个 seed 各算一次 hash）是唯一仓内调用点，收益随 `seeds` 放大。
- **代价**：必须在 `wyhash` 入口补 `start >= 0 && size >= 0 && start + size <= arr.size` 校验，否则 unchecked 读会越界（当前是抛异常兜底，改错就变内存安全事件）。
- **验证**：`cjpm bench -O2` 对 `wyhash(bytes, size: 64/1024)` 各 10^6 次，改前改后中位数 + IQR；等价性用现有 `wyhash` 输出对拍（新实现必须逐位相同）。
- **证据状态**：无基线（待验证，不进 tasks）

### [堆内存] O3 `UUID` 以 `Array<Byte>(16)` 存值，每个实例多一次堆分配

- **现状**：`f_util/src/uuid.cj:37-40` 的 `values: Array<Byte>` 让每个 `UUID` 结构体持有一个 16 字节数组对象（对象头 + 16 B，约 40 B/实例），且 `==`/`compare` 都是逐字节读数组。`fdbm` 按行生成主键、`f_egraph` 每个事件一个 `session`，实例量大但生命周期短。
- **方案**：把 `values` 换成 `UInt128`（`f_util/src/UInt128.cj` 已有 `toBytes`/`fromBytes`）或两个 `Int64`；`toString` 走 `UInt128.toBytes()` 按需生成，`compare` 改成两次 `Int64` 比较，`BigInt(true, values)` 只在 `toString(radix:)` 里按需转。
- **预期**：每个 UUID 少 1 次堆分配、结构体从「8 B + 堆对象」变成 16~20 B 内联；`==`/`compare` 少一次指针追随。
- **代价**：`compare` 的字节序语义要重算（当前是大端逐字节），`toData`/`tryFromData`/`custom`/`md5`/`sha1` 全部要改取值方式；`UInt128` 自身的 `hashCode` 低位碰撞问题（part3 #11 提及）会影响 `Hashable` 质量，需要一并评估。
- **验证**：`getAllocatedHeapSize()` 前后差 / 10^6 个 UUID 的分配次数与峰值；`cjprof heap` 看 `Array<Byte>` 是否从热点分配列表中消失。
- **证据状态**：无基线（待验证，不进 tasks）

## 待验证假设

> 没有性能测试数据支撑的猜测，不作为结论，不进 `todo.md` / `tasks.md`。

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `UUID.toString` 的 `StringGenerator` + 36 次 append 在按行生成主键时占单次取号耗时的主要部分 | `f_util/src/uuid.cj:85-101`；调用方 `fdbm/src/idmaker/IdMakers.cj:71` | `toString` 自耗时占比、单次分配字节数 | `cjprof record` 跑 10^6 次 `UUID.random().toString()`（`-O2`），对比 O1 实现 |
| 2 | `wyhash` 的逐字节边界检查在布隆过滤器多 seed 场景下是可测开销 | `f_util/src/wyhash.cj:53-101`；调用方 `f_bloom/src/BloomFilter.cj:61` | 每次 hash 的 ns 与边界检查占比 | `cjpm bench -O2`，`size = 64/1024`，`seeds = 1/8`，对比 std 的 unchecked 版本 |
| 3 | `UUID` 每实例一次 16 字节数组分配在 fdbm 批量生成时占分配量的大头 | `f_util/src/uuid.cj:37-40` | 分配次数与单实例字节数、GC 次数 | `getAllocatedHeapSize()` 前后差 + `cjprof heap`，输入 10^6 个 UUID |
| 4 | `registerFileSequenceGenerator` 的单次 `fsync` 延迟（毫秒级）会让并发取号吞吐掉两个数量级 | `f_util/src/uuid.cj:650-688` | 单次取号延迟 P50/P99、并发吞吐 | 打开文件版，8 线程 × 10^4 次取号，分段计时 + 线程状态采样（BLOCKED 占比） |

## 文件覆盖

> 与 `reviews/202611280854_full-repo/files/f_util.part4.txt` 逐行对应，共 8 行。

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_util/src/exception/IdException.cj` | .cj | ✅ | 4 个 `init` 全部委托 `BaseException`；`public` 顶层类对外可达，仓内 `f_util/src/IdMaker.cj:30` 有真实使用；无缺陷 |
| 2 | `f_util/src/exception/TextTemplateException.cj` | .cj | ✅ | 同上样板；`TextTemplate.cj` 7 处抛出，无缺陷 |
| 3 | `f_util/src/exception/UUIDException.cj` | .cj | ✅ | 同上样板；仅 `uuid.cj:180` 一处使用（#4 建议 `parse` 也改抛它） |
| 4 | `f_util/src/geohash.cj` | .cj | ✅ | 见 #1（encode 方向反，半球坍缩）、#1b（串长/坐标范围未校验）；`GeoHash` 的 `==`/`hashCode`/`toString` 与 `decode` 的位语义自洽，问题在 `encode` |
| 5 | `f_util/src/prime.cj` | .cj | ✅ | 见 #3（qpow 溢出）；`millerRabin(x, 2)` 返回 false、`qpow(_, _, 0)` 除零属同一族边界，已并入 #3 建议 |
| 6 | `f_util/src/uuid.cj` | .cj | ✅ | 见 #2/#4/#5/#6/#7/#8/#9/#10/#11/#12；`toData`/`tryFromData`（`:42-57`）的 DataAny 递归每层解一层且 `DataAny.new` 已扁平化嵌套，不构成无界递归 |
| 7 | `f_util/src/uuid_test.cj` | .cj | ✅ | 见 #13（只覆盖 v4 与基础往返）；断言本身与实现一致，无缺陷 |
| 8 | `f_util/src/wyhash.cj` | .cj | ✅ | 与 `cangjie_runtime/stdlib/libs/std/core/hashable.cj:996-1046` 逐段对比：五个长度分支、`>48` 的 do-while、`mix`/`r4`/`r8` 全部一致，是忠实移植；唯一差别是边界检查（O2）。`import fountain::f_base.*` 用于 `String.unsafeBytes()`（`f_base/src/UnsafeBytes.cj:24`），不是死 import |

合计：`.cj` 8 个 / `.md` 0 个 / 共 8 个，全部读完。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 8 | 正确性：#1/#1b/#2/#3/#4/#5/#6/#9；设计：#7/#12（builder 的可变状态与两段式协议）、#8（扩展点把阻塞搬进主路径）；可读性：#10/#11/#13。语言特性核对过：无返回类型的函数是**类型推导**（`define_functions.md:95-113`），不算缺陷；枚举构造器可不带类型名使用（`enum.md:80-98`），所以 `uuid.cj:508` 的 `Read` 不是编译错误，未报；`BigInt(true, values)` 的 `sign=true` 是「非负数」（`math_numeric_package_structs.md:157-176`），`toString(radix:)` 无符号问题；`Array<T> ==` 是逐元素结构相等（`core_package_structs.md:2011-2021`）。安全：`UUID.random` 的随机源是 `f_random.ThreadLocalRandom` → `stdx.crypto.SecureRandom`（`f_random/src/ThreadLocalRandom.cj:24-31`），v4 不可预测，无弱随机问题 |
| §1 死代码 | 2 | #10（未使用 import + 孤立表达式）。逐个符号搜过：所有 `private` 常量/字段/辅助函数（`geohash.cj` 4 个坐标常量、`uuid.cj` 的 `h`/`hex`/`toString(withDash:)`/`generate`/`timeLowFirst`/`genTimestampAndSequence`/`emptyCloser`/`timeStart`/`mutex`/`seqGen`/`closer`、`wyhash.cj` 的 `SECRET0-3`/`mix`/`r4`/`r8`）与 `internal` 入口（`UUID(values:)`、`TimeBasedUUIDBuilder.init`、`TimestampSequenceBuilder.init`/`timestampAndSequence`、`SequenceResource(...)`）都有真实调用；`protected` 本部分为 0；`public` 顶层（异常类、`UUID`、`GeoHash`、`TimeBasedUUIDBuilder`、`TimestampSequenceBuilder`、`SequenceResource`、三个 `prime` 函数、4 个 `wyhash` 重载）对外可达，一律不判；`uuid_test.cj` 的 `@Test` 类不算死代码 |
| §2 重复逻辑 | 1 | #11（`doParse` 与 `ether.parse` 同语义不同大小写行为；5 处 version/variant 打戳字面量复制）。另比对了 `md5`/`random`/`sha1`/`unixTimeBased`/`custom` 五个构造函数体、`timeLowFirst` 与 `timeHighFirst`、`node(Int64)` / `node(UInt64)` / `node(Array)`（位序不同，不合并）。三个异常类为 4 个构造器的语言样板（子类不能继承构造器），不判重复 |
| §3 空实现 | 0 | 本部分无空函数体、无 `TODO`/`FIXME`、无 `catch {}` 吞异常。`SequenceResource.empty`（`:725`）是 Null Object，缺一句「为什么可以空」的注释，属可读性细节不单列；`#4` 的「校验写了一半」按 §11 记在「发现」而非本节 |
| §4 栈溢出 | 0 | 唯一递归是 `UUID.tryFromData` 的 `case x: DataAny => tryFromData(x.data, flag)`（`:47`），每层解一层且 `DataAny.new`（`f_data/src/base/DataAny.cj:23-27`）已把嵌套扁平化，深度由调用方手工嵌套决定，不构成无界递归；geohash/prime/wyhash 全为定长或 `while` 循环 |
| §5 OOM | 0 | 无全量物化、无按不可信长度预分配、无全局容器。`randomMd5/randomSha1` 的 `bytes` 是调用方给定长度（已在 #9 建议加上限）；`custom` 固定输出 16 字节；`registerFileSequenceGenerator` 的缓冲固定 10 字节 |
| §6.1 热点瓶颈 | 0 | 未提供本模块 `cjprof` / `cjpm bench` 原始输出；所有性能判断转「待验证假设」1–4，未进「发现」 |
| §6.2 大粒度锁 | 1 | #8（`synchronized(mutex)` 内做 seek/read/write/flush）。同一把锁在默认/原子生成器下只包 `DateTime.now()` 与一次闭包调用，临界区很短，不构成 |
| §6.3 并发串行 | 0 | 本部分无 `spawn` / `Future` / 队列；`uuid_test.cj` 无线程 |
| §6.4 低效算法 | 0 | 未发现嵌套循环、`remove(at: 0)`、循环拼串、重复编译正则。`tryParse` 单遍 O(36)、`toString` 单遍 O(16)、`compare` O(16)、geohash 定长 32 轮，均线性且常数小；`prime` 的 `isPrime` 每轮分配一个 5 元素数组（`:63`）属常数级，并入 #3 建议 |
| §7 降堆内存方案 | 1（O3） | O3：`UUID` 的 16 字节数组改为内联 `UInt128`。无基线，只列方案 |
| §8 降 CPU 方案 | 2（O1、O2） | O1（`toString` 的 `StringGenerator`）、O2（`wyhash` 边界检查）；均无基线 |
| §9 local mode 可行性 | 0 | 本部分可纳入 local region 的只有 `toString` 的 `StringGenerator` 与 `encode` 的标量计算，前者分配量极小且结果 String 逃逸；`f_util` 未启用 local mode，收益只能用峰值内存证明，当前无数据，不列方案 |
| §11 现有代码的 BUG（存量） | 8 | #1/#1b/#2/#3/#4/#5/#6/#9。逐个函数过了边界/空值/错误处理/资源/契约：geohash 四象限与 0/31/33 字符输入、prime 的 `p<2`/`p==a[i]`/偶数、uuid 的 8 个构造函数与 3 个序列生成器、wyhash 的 0/1/3/4/7/8/16/17/48/49 长度分支均按源码复算或对比 std 实现；`wyhash` 未发现偏差 |
| §12 并发安全与锁粒度 | 1 | #7（builder 可变字段无同步、`registerSequenceGenerator` 锁外替换）。`GeoHash`/`prime`/`wyhash` 纯函数；`UUID.Nil`/`Max` 是 `static let` 结构体，`values` 私有且构造后不再改写（`:325`/`:336` 都是先改数组再构造），共享安全；`SequenceResource` 的闭包只持有 `File`，`close()` 有 `isClosedFn` 守卫但不保证幂等并发调用，属 #8 同一族的扩展点，未单列 |
| §14 功能完备性与 README 覆盖 | 1 | #13（测试只覆盖 v4）。README 对本部分 `public` 符号的覆盖（`timestampNanos`/`timestamp`/`timeBased`/`unixTimeBased`/builder 各方法/`SequenceResource`）已逐项核对，除 part1 已报的 `TimestampSequenceBuilder` 返回值与 `encode` 参数顺序外无新增遗漏；#2/#5 的「文档承诺与实现不符」按缺陷记在 §11，不重复计数 |
| §13 文档一致性 | 0（本部分无 `.md`） | 本部分 0 个 `.md`；引用到的 README 行号（`:315`/`:534`/`:538`/`:577`）只作契约证据，文档本身的核对归第 1 部分 |
| 文件覆盖 | 8/8 | 与 `files/f_util.part4.txt` 逐行对应，无缺失（见上表） |

## 模块统计

> 只统计本部分 8 个文件。

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 3 |
| 一般 | 7 |
| 轻微 | 4 |
| 优化方案（堆内存 / CPU） | 1 / 2 |

存量缺陷 14 条（严重 3 / 一般 7 / 轻微 4），是否纳入修复待用户决定；本部分未改动任何源码。

## 总评

本部分是 `f_util` 里缺陷密度最高的一段，而且集中在三个「数学/位运算」工具上——`geohash.cj`、`uuid.cj`、`prime.cj`。三条严重问题（#1、#2、#3）都不是风格问题，而是「按 API 名去用就得到错误结果或异常」：

- `GeoHash.encode` 的置位与区间收缩方向相反（#1），使整个半球坍缩成两个哈希值，`decode`/`parse` 完全不可逆；配套的 `tryParse`/`encode` 又对串长与坐标范围不做校验（#1b），连「输入是不是 32 位四进制」都区分不出来。这是三行代码的符号错误，但后果是「空间索引静默失效」，应当作为第一优先级修，并同时补四象限与负例。
- `UUID` 的时间戳（#2）在读侧与写侧同时越界：v1/v6 的 `n * 100` 自 1874 年起必然溢出 Int64，v7 的 48 位字段被整体左移 16 位、读回时又只乘了 100 且混入 12 位随机数——这些是「照 8 字节布局抄到 6 字节字段」的复制型错误。`fdbm` 的单测注释已经承认并绕过了 `timestampNanos`（`fdbm/src/idmaker/IdMakers_test.cj:194`），说明问题真实存在于使用路径上。
- `prime.isPrime`（#3）的模幂用 UInt64 直接做 64×64 乘法，`p > 2^32` 时溢出抛 `OverflowException`，「UInt64 素数判定」这个卖点只在 2^32 以下成立；5 个基的确定性上限（3.47e12）也没有写进任何文档。

一般项里，#6/#7/#8 是同一个模式：序列号与 builder 的扩展点没有落实契约（同刻度不递增、可变字段无同步、文件版把 fsync 搬进锁内），仓内主用方 `fdbm` 靠「随机 node + 外部锁」两个巧合规避了重复，这两个巧合都不在文档里。#4/#5/#9 是解析与边界校验的欠账，修法都很小（收尾校验、`& 0xc0` 判变体、大小写合并、长度前置检查）。

轻微项是死代码（一个未使用 import、一处孤立表达式）、两份手写 hex 解析（正是大小写不一致的成因）、带副作用的 prop 与测试覆盖缺口。

`wyhash.cj` 与三个异常类是这部分质量最好的文件：`wyhash` 与 std 实现逐段一致，异常类就是标准样板。性能方面本轮不给结论——`toString`、`wyhash` 边界检查、`UUID` 的 16 字节数组都只有机制、没有数据，全部降级为待验证假设与「无基线」方案，需下一轮 `cjprof` / `cjpm bench -O2` 补测后再谈是否排期。
