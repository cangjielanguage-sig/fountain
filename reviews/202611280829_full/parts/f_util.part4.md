# f_util 模块审查报告（第 4/4 部分）

- **审查日期**：2026-11-28
- **模块路径**：`f_util`（48 个源文件；本部分覆盖 3 个：`uuid` / `uuid_test` / `wyhash`，即模块第 4/4 部分）
- **基线**：工作区快照（`8c0ce643a`，`sts/1.3.x`；除未跟踪的 `docs/review/`、`reviews/` 外工作区干净，无 diff）⇒ 本部分全部缺陷记「存量」
- **审查重点**：UUID / wyhash 正确性与性能、死代码、重复逻辑、空实现、OOM、存量 BUG
- **报告版本**：v1（本部分为模块报告的 `part4`，最终由主 Agent 合并为 `docs/review/f_util_review_20261128.md`）

## 发现

### [严重][存量] `UUID.timestampNanos` / `timestamp` 对 v1 / v6 / v7 全部溢出抛异常，v7 另有 4096 倍误差

- **位置**：`f_util/src/uuid.cj:116-173`（`:168` 的 `n * 10000`、`:171` 的 `n * 100`）、`f_util/src/uuid.cj:174-183`（`timestamp` 依赖前者）
- **来源**：存量（`git blame -L 116,183` 全部落在 `4be871f2f`，2026-10-02；逻辑自 `2662f7760` 引入）
- **判据**：review-checklist §11（边界 / 溢出）+ §10 正确性；溢出语义按语言文档 `compile_options.md:235`（默认 `throwing`）
- **证据**：静态确定 —— ① v1/v6 分支拼出 60 bit 的「1582 年起 100 ns 数」，2026 年该值约 `1.4e17`，`n * 100` 得 `1.4e19` > `Int64` 上限 `9.22e18` ⇒ 按默认溢出策略抛 `OverflowException`（不是回绕）；② v7 分支（`:137-151`）把 `rand_a` 的低 12 bit（`values[6]&0xf`、`values[7]`）也当成时间戳低位，`n = (ms << 12) | rand`，再 `n * 10000 * 100` ⇒ `7.3e19`，同样抛异常；即使改成回绕，v7 的结果仍是正确的 4096 倍。
- **描述**：任何真实时间生成的 v1 / v6 / v7 UUID 读 `timestamp` / `timestampNanos` 都会抛 `OverflowException`（v7 还叠了位错位），这两个属性目前等于不可用。仓库侧旁证：`fdbm/src/idmaker/IdMakers_test.cj:194` 的注释已自认「`timestampNanos` 对 1582 年起算会超出 Int64，故单测自行解码」，测试绕开而不是修复；生产路径（`fdbm/src/idmaker/IdMakers.cj:63-76`）只用 `toString()`，因此缺陷一直未暴露。
- **建议**：接口改成不溢出的表示——`timestamp: ?DateTime` 直接由 `(seconds, subSecondNanos)` 组装，或提供 `timestampSeconds` + `timestampNanosOfSecond`；v7 分支改为 `(n >> 12) * 1_000_000`（并只取前 48 bit）；补「v1/v6/v7 各自与 `DateTime.now()` 误差 < 1 s」的用例。

### [严重][存量] `UUID.unixTimeBased()`（v7）时间戳整体右移 16 位，写入值被压缩 65536 倍

- **位置**：`f_util/src/uuid.cj:397`（`UInt8((millis >> (7 - i) * 8) & 0xff)`，`i` ∈ 0..5）
- **来源**：存量（`git blame -L 392,409` → `4be871f2f`）
- **判据**：review-checklist §11（逻辑错误 / 位偏移）+ §10 正确性
- **证据**：静态确定 —— v7 的 `unix_ts_ms` 是 48 bit，第 `i` 字节应取 `millis >> ((5 - i) * 8)`；代码用 `(7 - i) * 8`，`i=0/1` 取到第 56/48 位（恒 0），`i=2..5` 依次取第 40/32/24/16 位 ⇒ 实际写入的是 `millis >> 16`（低 16 位被丢弃，值缩小 65536 倍）。
- **描述**：`UUID.unixTimeBased()` 生成的 v7 UUID，其 48 bit 时间戳只有 `ms / 65536`，同一 65.5 s 窗口内所有 ID 前缀相同、窗口内顺序由随机位决定，v7 承诺的「按时间可排序」失效。调用点：`fdbm/src/idmaker/IdMakers.cj:66`（`uuid` 生成器 v7 分支，用于主键）、`f_llm/src/store/EvolutionLease.cj:36`（租约标识）。按 ID 排序、按时间窗口扫描都会得到错误结果。
- **建议**：改 `(5 - i) * 8`；补用例断言「`UUID.parse(unixTimeBased().toString())` 解出的时间戳与 `DateTime.now()` 相差 < 1 s」，并加「连续两次生成的字符串字典序不倒退」。

### [严重][存量] `serialSeq` 的序列生成器在同一时间戳下不递增 ⇒ 固定 node 时生成完全重复的 UUID

- **位置**：`f_util/src/uuid.cj:695-702`（内存 CAS 版：`if (last >= timestamp) { seq.load() }`）、`f_util/src/uuid.cj:666-668`（文件版同一分支直接 `seq`）；消费侧 `f_util/src/uuid.cj:497-501`、`709-722`
- **来源**：存量（`git blame -L 640,722` → `4be871f2f`）
- **判据**：review-checklist §11（逻辑错误 → 主键重复）+ §12.1（检查-然后-写入未保证唯一性）
- **证据**：静态确定 —— 时间戳没变（`last >= timestamp`）时两条实现都**只读不增**，返回当前 `seq`：同一 `timestamp` 的第二次及以后调用得到相同的 `(timestamp, seq)`；`generate()`（`:567-585`）把这两项写入字节 0..9，只有 node 不同。若 node 固定（`node(mac)` / `ether(...)`，v1/v6 的标准用法，`:551-566`、`:513-550`），生成结果逐字节相同 ⇒ UUID 重复。`seq` 还是 `UInt16`，回绕后与旧值再次碰撞。
- **描述**：`serialSeq` 名义上是「同一时间戳内递增」，实际同时间戳内恒定，既不保证唯一也不保证单调。仓内 `fdbm/src/idmaker/IdMakers.cj:71` 每次 `randomNode()`（48 bit 随机）把重复概率压到 2⁻⁴⁸，所以 `fdbm/src/idmaker/IdMakers_test.cj:67-95` 的 1600 条并发用例能过，但这是靠 node 随机掩盖的；对外部使用者按 RFC 用固定 MAC 作 node 时，高频取号（同一 100 ns 桶）会直接产生重复主键。
- **建议**：语义改成「时间戳前进 → CAS 换 ts 并把 seq 归零；时间戳未变 → `seq.fetchAdd(1)`」，保证同一 ts 内每次调用取到不同 seq（文件版同样：ts 未变则 seq+1 并回写）；返工后补「固定 node + 同 ts 并发 1e5 次不重复」的用例。

### [一般][存量] v5（`sha1`）取的是 SHA-1 尾部第 18/19 字节，与 RFC / 主流实现不互操作

- **位置**：`f_util/src/uuid.cj:363-375`（`:367` 用 `sha[18]`、`:369` 用 `sha[19]`、`:371` 与 `:373` 用 `sha[8..15]`）；注释自认在 `:351`
- **来源**：存量（`git blame -L 353,377` → `4be871f2f`）
- **判据**：review-checklist §11（契约与实现不符）+ §13（README `:565` 写「version 5」）
- **证据**：静态确定 —— RFC 4122 §4.3 / 主流实现（Python `uuid5`、Java `nameUUIDFromBytes`）都是「取 SHA-1 摘要**前 16 字节**，再覆写 byte6 高 4 bit 为版本、byte8 高 2 bit 为变体」；本实现把摘要第 18/19 字节塞进 UUID 第 6/7 字节，摘要第 6/7/16/17 字节被丢弃，byte8 之后又回到 `sha[8..15]`。同一 name 在本模块与其它语言算出的 v5 必然不同。
- **描述**：进程内自洽（生成与比较一致），但跨系统用「同样的 name 生成同一个 UUID」这一 v5 的核心用途失效；代码注释 `:351` 已经写明「此处应该是一个错误」，属已知但未修的偏差。另：`sha1(value)` / `md5(value)` 没有 namespace 参数，本身不是 RFC 的 name-based 构造，README 未说明这一点。
- **建议**：`values[i] = sha[i]`（i<16）后再覆写版本/变体位；如需 RFC 语义，补 `sha1(namespace: UUID, name: String)` 重载，并在 README 写清现行 API 是「无命名空间的哈希派生」。

### [一般][存量] `tryParse` 既过松（忽略分隔符、忽略尾部多余字符）又过严（只认小写、只认 variant 2）

- **位置**：`f_util/src/uuid.cj:192-251`（`:225-246` 解析循环、`:196-220` nibble 表、`:247-249` variant 校验）
- **来源**：存量（`git blame -L 192,251` → `4be871f2f`）
- **判据**：review-checklist §11（边界 / 输入校验）+ §10 正确性
- **证据**：静态确定 —— ① 只有 `i ∈ {4,6,8,10}` 且该字符**恰好是** `'-'` 才跳过（`:214-218`），其余位置不校验分隔符；若这些位置被十六进制字符占位，解析整体左移并吞掉前 32 个字符，最后 4 个字符从不读取 ⇒ 例如 `"0000000000000000" + "80" + 14 位 hex + 任意 4 字符`（长度 36）可解析成功，且与合法串映射到同一个 UUID；② `doParse`（`:196-220`）只列了 `a-f`，大写输入一律 `None`；③ `:247` 要求 `values[8] >> 6 == 2`，variant 0/6/7 的合法 UUID 串无法解析。
- **描述**：`parse` 的输入是外部数据（HTTP 路径、JSON、DB 文本），宽松解析会让「不同字符串 → 同一 UUID」，宽松+严格混用又让同一 UUID 的不同书写形式（大写、非 RFC 变体）一半可读一半不可读，`toString`/`parse` 的往返契约不成立。
- **建议**：按 8-4-4-4-12 逐段校验（总长 36、连字符位置固定、其余必须为 hex、`a-f`/`A-F` 都收），解析结束断言迭代器已耗尽，variant 仅校验最高位模式（`10` 或 `110`/`111`）。

### [一般][存量] `TimeBasedUUIDBuilder` / `TimestampSequenceBuilder` 的可变状态与序列生成器注册都没有同步，API 未声明线程约束

- **位置**：`f_util/src/uuid.cj:446-458`（builder 的 `version/timestamp/seq/uid` 字段）、`477-501`（`randomSeq`/`serialSeq` 写共享字段）、`709-722`（`mutex` 只包住一次 `seqGen` 调用）、`642-704`（`registerSequenceGenerator*` 改 `seqGen`/`closer` 时不持锁）
- **来源**：存量（`git blame -L 446,501` / `-L 640,722` → `4be871f2f`）
- **判据**：review-checklist §12.1（共享可变状态无保护、检查-然后-写入）
- **证据**：静态确定 —— 两个类都是 `public`，字段是实例上的可变状态：线程 A 的 `node()`（`:567-585` 读 `timestamp/seq/version`）与线程 B 的 `serialSeq`（`:483-488` 写同样字段）可交错，A 可能用 B 的 `(ts, seq)` 组装；`registerSequenceGenerator`（`:646-649`、`:689-704`）在 `timestampAndSequence`（`:709`）持锁执行时替换 `seqGen` 并 `closer.close()`，可能出现「新 seqGen + 旧 closer」或关掉正在被读的文件。
- **描述**：仓内调用方（`fdbm/src/idmaker/IdMakers.cj:38-77`）用外部 `Mutex` 规避，并在注释里写明「builder 的 `timestamp`/`seq` 字段非线程安全，必须持锁」——说明约束真实存在，但只写在下游注释里，`UUID`/builder 的公开签名与 README 都没有声明。
- **建议**：在类注释与 README 明确「非线程安全，注册必须在首次生成前完成」；或把 `register*` 与 `timestampAndSequence` 放进同一把锁，使 API 自身安全（代价是注册与取号共锁）。

### [一般][存量] 文件序列生成器：`/tmp` 硬编码、临时目录永不清理、读写位置错乱导致 seq 恒为 0/1

- **位置**：`f_util/src/uuid.cj:650-688`（`:651` `Directory.createTemp('/tmp')`、`:652` 建文件、`:660` 读、`:666-668` 命中旧时间戳分支、`:680-685` seek/写回）
- **来源**：存量（`git blame -L 650,688` → `4be871f2f`）
- **判据**：review-checklist §11（资源不对称）+ §5（无界增长：磁盘条目）+ §10 跨平台
- **证据**：静态确定 —— ① 方法没有 `@When[os == 'Linux']`，`/tmp` 在非 POSIX 平台不存在，构造即失败；② `Directory.createTemp('/tmp')` 每注册一次建一个目录，代码中无任何删除路径（`~init` 只关文件），目录与其文件长期残留；③ `file.read(bytes)` 后位置为 10，`storedNanos >= timestamp` 分支（`:666-668`）直接返回、不 `seek(Begin(0))`，下次 `read` 从 10 开始返回 0 ⇒ 走「首次」分支把 seq 重置为 1（`:673-685`），seq 永远停在 0/1；④ `read` 返回值在 1..9 之间（半写）时按全 0 处理，时间戳被当作 0。
- **描述**：该生成器（跨进程唯一性本应是它的价值）实际既不能跨平台、又持续泄漏临时目录，序列语义也退化为常量；仓内零引用（仅 `README.md:592` 列出）。
- **建议**：读文件后统一 `seek(Begin(0))`；路径从 `f_config` 读取并做平台判断；用固定单文件 + 退出清理（或用 `File` 的 `try-with-resources`）；若无人使用，直接删除该 API 更划算。

### [一般][存量] 锁内做文件 I/O：`timestampAndSequence` 的临界区包含 `read` / `write` / `flush`

- **位置**：`f_util/src/uuid.cj:710-721`（`synchronized(mutex)` 包住 `seqGen(timestamp)`）、被调方 `:660-687`
- **来源**：存量（`git blame -L 709,722` → `4be871f2f`）
- **判据**：review-checklist §6.2（锁内 I/O）/ §12.2（临界区只应保护不变量）
- **证据**：静态确定（临界区内容）—— 注册文件生成器后，临界区内有 1 次 `read`、1 次 `seek`、1 次 `write`、1 次 `flush` 再 1 次 `seek`，全是系统调用；该锁是 v1/v6 每次取号的必经串行段，`fdbm` 取号路径（`IdMakers.cj:70-72`）在其外还套了一层自己的锁。单次持有时长与竞争比例需实测（未测，见「待验证假设」）。
- **描述**：一旦启用文件生成器，取号吞吐被「每号一次 fsync 级 flush」限制，且这个串行段随并发线程数放大等待。
- **建议**：锁内只算 `(ts, seq)`，持久化移出临界区（批量/异步回写）；或启动时一次性加载状态，运行期只写内存。

### [一般][存量] `genTimestampAndSequence` 是无上限忙等：注册的生成器恒返回 0 时死循环

- **位置**：`f_util/src/uuid.cj:497-501`（`while (timestamp == 0 || seq == 0)`）、契约入口 `:465-472`
- **来源**：存量（`git blame -L 497,501` → `4be871f2f`）
- **判据**：review-checklist §11（错误处理缺失）+ §3（把非法返回值当重试信号）
- **证据**：静态确定 —— 循环没有次数上限、没有退避、没有 `Duration` 超时；`registerSequenceGenerator(generator:)` 是公开 API，用户函数若恒返回 0（例如外部计数器未初始化），`serialSeq` 永不返回，线程 100% CPU 空转。「0 表示重试」这一隐式契约只体现在实现里，签名（`(Int64) -> UInt16`）与文档都没有表达。
- **建议**：重试上限（如 1024 次）后抛 `UUIDException('sequence generator returned 0')`；把签名改成 `(Int64) -> ?UInt16` 让「无可用序列」进入类型；在 README 写清语义。

### [一般][存量] `etherName` / `ether` 把 I/O 失败与非法输入都映射成 `UnreachableException`，`eth0()` 是丢弃结果的空壳

- **位置**：`f_util/src/uuid.cj:502-512`（`etherName`，`:508-511`）、`:513-550`（`ether`，`:537`、`:539`）、`:503-505`（`eth0`）
- **来源**：存量（`git blame -L 502,550` → `4be871f2f`）
- **判据**：review-checklist §3（空实现 / 静默）+ §11（语义与命名不符）+ §10 错误处理
- **证据**：静态确定 —— ① 读 `/sys/class/net/<name>/address` 的 `File` 打开或读取失败（网卡不存在、无权限、容器内无该文件）时抛 `UnreachableException`，既丢失 cause 又误导排查方向；② `ether('zz:...')` 这类非法 MAC 串在 `parse` 的 `case _` 抛 `UnreachableException`（`:537`、`:539`），应为参数错误；③ `eth0()` 返回 `Unit` 且丢弃 `etherName('eth0')` 的 UUID，调用后除可能抛异常外没有任何可观察结果，README `:603-605` 却把它作为「使用 eth0」的能力列出。
- **建议**：`etherName` 改抛 `UUIDException` 并带路径与 cause；`ether` 用 `IllegalArgumentException`；`eth0()` 改为返回 `UUID`（其实现与 `etherName('eth0')` 完全重复，也可以删除）。

### [轻微][存量] `etherName` 末尾的 `throw UnreachableException()` 不可达

- **位置**：`f_util/src/uuid.cj:511`
- **来源**：存量（`git blame -L 507,512` → `4be871f2f`）
- **判据**：review-checklist §1（不可达语句）
- **证据**：静态确定 —— `try (f = File(...))` 的资源获取失败与块内 `readToEnd` 失败都会在 `try` 语句处抛出，块内成功路径 `return ether(...)` 直接返回，因此 `try` 之后的同层语句永远执行不到。
- **建议**：删除该行；错误路径按上一条改成显式异常（这一行删除后不影响语义）。

### [轻微][存量] v2 的时间信息读取未实现，且两个属性行为不一致

- **位置**：`f_util/src/uuid.cj:119-170`（`case _ => 0`）、`174-183`（无 `case 2`）
- **来源**：存量（`git blame -L 116,183` → `4be871f2f`）
- **判据**：review-checklist §11（静默错误值）+ §13（README `:545` 写「兼容 UUID version 1 2 6」）
- **证据**：静态确定 —— `UID()`（`:489-493`）可把 builder 置为 version 2 并生成 v2 UUID；对 v2，`timestampNanos` 走 `case _` 静默返回 `0 * 100 = 0`，`timestamp` 抛 `UUIDException`，同一份数据两个属性一个「有值（假）」一个「抛异常」。
- **建议**：v2 的 time_low 仍可解出 32 bit 秒级时间，可单列分支；无法还原时让 `timestampNanos` 也抛同一异常，并在 README 注明 v2 时间戳不可还原。

### [轻微][存量] README 把 `TimestampSequenceBuilder` 的注册方法写成返回 `This`，代码返回 `Unit`

- **位置**：文档 `f_util/README.md:623-627`（`:625` `registerFileSequenceGenerator(): This`、`:627` `registerSequenceGenerator(): This`）vs 代码 `f_util/src/uuid.cj:650`、`:689`（均 `Unit`）
- **来源**：存量（README 与 `uuid.cj` 同属 `4be871f2f` 快照）
- **判据**：review-checklist §13（API 与文档不符）
- **证据**：静态确定 —— `TimeBasedUUIDBuilder` 的同名包装确实返回 `This`（`:469-476`），README 把外层与内层的签名抄成了同一份；内层 `TimestampSequenceBuilder` 的两个方法没有返回值。
- **建议**：README 改成 `: Unit`，或让内层返回 `This` 与 README 对齐（后者更一致，但会改动公开签名）。.md 全文属模块合并范围，此处只给证据。

### [轻微][存量] 未使用的 import

- **位置**：`f_util/src/wyhash.cj:18`（`import fountain::f_base.*`）、`f_util/src/uuid.cj:24`（`import stdx.crypto.crypto.*`）
- **来源**：存量（`git blame` → `4be871f2f`）
- **判据**：review-checklist §1（未使用的 import）
- **证据**：静态确定 / 待确认 —— `wyhash.cj` 全文只用到本文件的 `SECRET*`、`wyrand`、`wyhash`、`mix`、`r4`、`r8`，无任何 `f_base` 符号，属确定未使用；`uuid.cj` 的摘要只用 `stdx.crypto.digest.{MD5, SHA1}` 与其 `write/finish`，未见 `stdx.crypto.crypto` 的符号（若 `finish()` 依赖该包的接口扩展则需保留），标 **待确认**。
- **建议**：删除 `wyhash.cj:18`；`uuid.cj:24` 先试删再编译验证（本报告不跑构建）。

### [轻微][存量] 重复逻辑：版本/变体位设置 5 处、hex nibble 解析 2 处（且已漂移）

- **位置**：版本/变体 5 处 —— `f_util/src/uuid.cj:321-324`（md5）、`332-335`（random）、`367/371`（sha1）、`399/403`（v7）、`435/437`（custom）；hex 解析 2 处 —— `196-221`（`tryParse.doParse`，只认小写）、`518-541`（`ether.parse`，大小写都认）
- **来源**：存量（`git blame` → `4be871f2f`）
- **判据**：review-checklist §2（字面量复制 / 只改类型名的近似重复）
- **证据**：静态确定 —— 5 处都是「byte6 = (x & 0xf) | (ver << 4)；byte8 = (x & 0x3f) | (2 << 6)」，仅 version 常量不同；两处 nibble 解析语义相同、`case` 集合不同（大写与小写）已造成行为漂移（见上文 `tryParse` 条目）。
- **建议**：抽 `private func withVersionVariant(values: Array<Byte>, version: Byte): Array<Byte>` 与 `private func hexNibble(c: Rune): ?Byte`；把「是否接受大写」「遇到 `'-'` 的行为」作为显式参数，避免第三份实现再次漂移。

### [轻微][存量] 可见性不一致（可见性建议，不算死代码）

- **位置**：`f_util/src/uuid.cj:609`（`public func timeHighFirst`）与 `:586`（`private func timeLowFirst`）
- **来源**：存量（`git blame -L 586,623` → `4be871f2f`）
- **判据**：review-checklist §10（设计合理性）；按硬原则一，`public` 且对外可达故不判死代码
- **证据**：静态确定 —— `TimeBasedUUIDBuilder` 是 `public class`，`timeHighFirst` 对外可达；它与 `timeLowFirst` 是同一层的字节编码细节，后者为 `private`，仓内零调用（`grep 'timeHighFirst'` 只命中定义与 README `:616`）。
- **建议**：统一收窄为 `private`（或包内），除非确有外部子类需要；若要保留，补一句用途注释说明为什么暴露字节编码闭包。

### [轻微][存量] 测试只覆盖 v4 往返，本部分 3 个严重缺陷都落在无覆盖路径上

- **位置**：`f_util/src/uuid_test.cj:21-32`（唯一用例）
- **来源**：存量（`git blame -L 21,32` → `3a5fa2f7d`，2025-06-24）
- **判据**：review-checklist §14（覆盖不足）
- **证据**：静态确定 —— 用例只断言 `UUID.random()` 的 `version == 4` / `variant == 2` 与 `parse(toString())` 相等；`timeBased` / `unixTimeBased` / `md5` / `sha1` / `tryParse` 的失败路径零用例。`timestampNanos` 的溢出、v7 位偏移、`serialSeq` 同 ts 不递增因此都没有被拦住（`fdbm` 的并发用例用 `randomNode()` 掩盖了第三项）。
- **建议**：补四组用例——v1/v6/v7 时间戳与 `DateTime.now()` 的误差、固定 node 下同 ts 的并发唯一性、`sha1` 与已知向量（如 Python `uuid5`）对齐、`tryParse` 的非法串（缺分隔符、尾部多余字符、大写、非 RFC 变体）。

## 优化可行性方案

### [堆内存] `UUID` 内联 16 字节，去掉每实例的 `Array<Byte>` 与构造期 `HashBuilder`

- **现状**：每个 `UUID` 持有一个 `Array<Byte>`（16 字节载荷 + 数组头，量级 32–48 B）并在构造时 `HashBuilder().append<Byte, Array<Byte>>(values).build()`（`uuid.cj:38-40`）额外产生一个 `HashBuilder` 实例；`UUID.random()` 还先分配一个 16 字节随机数组（`:331`）。即每生成一个 UUID 至少 3 个堆对象。
- **方案**：`struct UUID { let hi: UInt64; let lo: UInt64 }`（或 `Array` 换成两个 `Int64`），`hashCode` 直接对两个 word 做一次 `mix`；`values` 改成按需构造的视图（`toString`/`toData`/`timestampNanos` 按 word 取字节）。
- **预期**：每次创建少 2 个堆对象（约 60–80 B 分配量），`fdbm` 取号、`f_egraph` 事件默认 `session` 等高频路径的分配量与 GC 次数下降；具体比例未测。
- **代价**：`values` 语义变化，`tryParse`/`custom`/`sha1` 等按数组构造的分支要改；属破坏性内部改动（字段是 `private`，外部影响小）。
- **验证**：同一负载（1e6 次 `UUID.random()` + `toString()`）改前/改后对照 `getAllocatedHeapSize()`、GC 次数、RSS，`-O2`，中位数。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] `toString` 用 256 项字节→2 字符表，或一次性写 36 字节缓冲

- **现状**：`uuid.cj:88-101` 每次 16 次循环、32 次 `builder.append(Rune)` + 4 次 `append('-')`；`StringGenerator` 内部是 `ArrayList<Byte>`（`f_base/src/StringGenerator.cj:23`），从 0 容量起增长，36 字节要经历多次扩容复制，末尾再 `String.fromUtf8Unchecked` 拷一次。
- **方案**：静态 `Array<String>(256)`（每项 2 个 hex 字符），`toString` 变成 16 次 `append(String)` + 4 次连字符；或直接写 `Array<UInt8>(36)` 后一次转 `String`。
- **预期**：单次 `toString` 的 append 次数从 36 降到 20（或 37 次数组写 + 1 次转换），UUID→String 主导路径（`f_egraph/src/base/Event.cj:32` 等默认参数、`f_codec/src/default/DefaultCodec.cj:1022` 临时目录名）受益；比例未测。
- **代价**：静态表常驻约 4–8 KB（字符串头 + 内容）；`StringGenerator` 是否复用实例需确认（当前每次 `new`）。
- **验证**：`cjpm bench -O2`，1e6 次 `UUID.random().toString()`，报中位数与离散度；与当前实现同机同 SDK 对照。
- **证据状态**：`无基线（待验证，不进 tasks）`

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `wyhash` 用带边界检查的 `Array<UInt8>` 下标，runtime 原版是 `arrayGetUnchecked(RawArray)`（`stdlib/libs/std/core/hashable.cj:775-870`），每字节多一次边界检查，≥ 256 B 输入可能明显慢 | `f_util/src/wyhash.cj:130-138` | 与 std 版同输入的自耗时差 | `cjpm bench -O2`，1 KiB / 64 KiB 各 1e6 次，与 std 的 `wyhash` 同机对照 |
| 2 | `UUID.random()` + `toString()` 是高频分配点（每次 3+ 个堆对象） | `f_util/src/uuid.cj:330-337`、`88-101` | 分配量与 GC 占比 | `cjprof heap`，跑 1e6 次 random+toString，看分配热点排名 |
| 3 | `timestampAndSequence` 的 `Mutex` 在 `fdbm` 取号路径上是串行段（含 `DateTime.now()` 与序列生成） | `f_util/src/uuid.cj:710-721` | 持锁时长、线程等待占比 | 8 线程 × 10k 次取号，分段计时 + 线程状态采样（BLOCKED/WAITING 占比） |
| 4 | `toString` 的 `ArrayList<Byte>` 扩容与 36 次 `add` 在 UUID→String 主导场景里占比可观 | `f_util/src/uuid.cj:88-101` | 扩容次数与单次耗时分解 | 微基准对比「预分配 36 字节 + 一次转换」版本，`-O2`，中位数 |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_util/src/uuid.cj` | .cj | ✅ | 见发现 S1–S3、G1–G7、M1–M6 |
| 2 | `f_util/src/uuid_test.cj` | .cj | ✅ | 仅一个 v4 用例，见「测试覆盖」条 |
| 3 | `f_util/src/wyhash.cj` | .cj | ✅ | 算法与 `cangjie_runtime/stdlib/libs/std/core/hashable.cj:763-870` 逐行一致（仅 `Array` 下标替代 `arrayGetUnchecked`）；仓内零引用（`grep wyhash/wyrand` 只命中本文件与 README），属对外 API，不判死代码 |

合计：`.cj` 3 个 / `.md` 0 个 / 共 3 个，全部读完。本部分不含 `.md`；为给 §13/§14 取证，另行按行核对了 `f_util/README.md:94-109`（wyhash 签名）与 `:492-628`（UUID / TimeBasedUUIDBuilder / TimestampSequenceBuilder 声明），未展开其它 `.md` 内容（属模块合并范围）。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 5 | 正确性 3 条（S1/S2/S3）、设计 2 条（G3 线程契约、M6 可见性）；语言特性已核对：`struct` 内 `Array` 为引用语义但仅内部构造、无外部可变别名，`Option` 无静默丢弃；安全性：无凭据、无注入面，`etherName` 读固定 sysfs 路径 |
| §1 死代码 | 3 | 逐个 private/internal 符号搜引用：`hex`、`h`、`timeLowFirst`、`emptyCloser`、`mutex`、`SequenceResource.empty`、`timeStart` 均有调用者；`public` 且对外可达的 `Nil`/`Max`/`toData`/`toString(radix:)`/`eth0` 按硬原则一不判（`eth0` 的功能问题另列 G7）；命中：`uuid.cj:511` 不可达 `throw`、`wyhash.cj:18` 未使用 import、`uuid.cj:24` 未使用 import（待确认） |
| §2 重复逻辑 | 2 | 已把 3 个文件的函数体逐一两两比对；命中「版本/变体位 5 处重复」与「hex nibble 解析 2 处（已漂移）」，合并为 1 条 M 级发现；`r4`/`r8` 与 `mix` 与 runtime 同源但属必要移植，不判重复；`timeLowFirst`/`timeHighFirst` 位偏移不同、语义不同，不判重复 |
| §3 空实现 | 1 | `eth0()`（`uuid.cj:503-505`）返回 `Unit` 丢弃结果，归入 G7；`SequenceResource.empty` 是显式 Null Object（`{=>}` + `{=> false}`），有注释语义、非缺陷；无 `TODO`/`FIXME`/`catch {}` |
| §4 栈溢出 | 0 | 3 个文件无递归（`ether`/`generate`/`compare`/`wyhash` 全为循环或单层闭包调用）；`while` 循环次数由常量或输入长度线性界定，唯一无界循环是 G6 的忙等（属挂死不是爆栈） |
| §5 OOM | 0 | 分配规模均为常量：`Array<Byte>(16)`、`nextBytes(16/10/6)`、`StringGenerator` 36 字节；`randomMd5(bytes:)`/`randomSha1(bytes:)` 的 `bytes` 由调用方给定（非不可信输入），未按上限校验但属调用方自担，未计入；磁盘侧无界条目见 G4 |
| §6.1 热点瓶颈 | 0 | 无 profile / bench 数据（`scope.md`「已有性能资料」为空），任何热点结论不成立；4 条线索全部进「待验证假设」，未写成缺陷 |
| §6.2 大粒度锁 | 1 | G5：`timestampAndSequence` 临界区内含文件 `read/write/flush/seek`（仅在注册文件生成器后成立），临界区内容已逐句列出 |
| §6.3 并发串行 | 0 | 本部分无 `spawn`/`Future`；`fdbm` 的外部锁属调用方设计，不在本部分范围 |
| §6.4 低效算法 | 0 | `compare` 为定长 16 字节、`toString` 为定长 36 字符、`wyhash` 为线性单遍；未见嵌套循环或热点 `contains`；`toString` 的 append 次数进「优化方案」而非缺陷（无数据） |
| §7 降堆内存方案 | 1 | 见「[堆内存] UUID 内联 16 字节」，标 `无基线（待验证，不进 tasks）` |
| §8 降 CPU 方案 | 1 | 见「[CPU] toString 预计算表」，标 `无基线（待验证，不进 tasks）` |
| §9 local mode 可行性 | 0 | 本部分临时对象都是 16 字节级数组与 36 字节串，改造只降分配量、无法用峰值内存证明收益；且 `UUID` 是返回值必然逃逸，不满足逃逸检查 |
| §11 现有代码的 BUG（存量） | 9 | 读到的 6 个函数族（`tryParse`/`timestampNanos`/`timestamp`/`timeBased 生成链路`/`unixTimeBased`/`sha1`）的边界、空值、错误类型、资源释放逐条核对；命中 S1–S3、G1–G7、M1–M2，全部为存量 |
| §12 并发安全与锁粒度 | 3 | `UUID` 不可变（`values`/`h` 均 `let`、无外部可变别名）⇒ 线程安全；`TimestampSequenceBuilder.timestampAndSequence` 有 `Mutex` 保护；命中 G3（builder 字段与注册无同步）、G5（锁内 I/O）、S3（检查-然后-写入导致同 ts 复用 seq） |
| §14 功能完备性与 README 覆盖 | 2 | 以 `src/` 公开声明逐项对 `README.md:492-628`：符号覆盖完整（含 `timeHighFirst`、`register*`），命中 M2（README 承诺 v1/2/6 但 v2 时间戳不可读）与 M3（两个注册方法返回类型写成 `This`）；`TimeBasedUUIDBuilder` 承诺能力均已接线，无 `TODO`/`Unsupported` |
| 文件覆盖（§13 等） | 3/3 | `uuid.cj` / `uuid_test.cj` / `wyhash.cj` 全部读完；本部分无 `.md`，README 只做逐行取证未展开 |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 3 |
| 一般 | 7 |
| 轻微 | 7 |
| 优化方案（堆内存 / CPU） | 1 / 1 |

存量合计 17 条（本部分无本次改动引入项），是否纳入修复待用户决定。

## 总评

`wyhash` 是对 runtime 实现的忠实移植（仅把 `RawArray` 换成 `Array`，代价是每字节一次边界检查），算法本身没有发现正确性问题；真正的问题集中在 `uuid.cj`：**v1/v6/v7 三个版本的时间戳读写全都有硬错**——读取侧对 1582 年起算的纳秒值做 `*100` 必溢出（v7 还叠加 12 bit 随机位错位），写入侧 v7 的时间戳整体右移 16 位；`serialSeq` 在同时间戳内不递增，使 v1 在「固定 node」这一标准用法下会产生重复主键（仓内靠 `randomNode()` 掩盖）。这四条属于阻塞项：v7 已被 `fdbm` 用作主键生成器、被 `f_llm` 用作租约标识，时间有序性已失效；`timestamp` / `timestampNanos` 作为公开属性则完全不可用。

次要面：`sha1` 取尾部字节导致 v5 与其它语言不互操作；`tryParse` 的宽松解析会让不同字符串落到同一 UUID；文件序列生成器在跨平台、临时目录清理与文件位置三处都不成立，且把 I/O 放进了锁内。可维护性方面，版本/变体位设置被复制了 5 份、hex nibble 解析复制了 2 份并已出现大小写漂移，抽取后能同时消掉一处潜在缺陷。

建议排期：S1–S3 先修并补时间戳/唯一性用例（现有 `uuid_test` 只覆盖 v4 往返，是本轮 3 个严重缺陷没被拦住的原因）；G1/G2 与互操作/输入校验相关，可同批；G4/G5 若确认文件生成器无人使用，直接删除比修更划算；其余按轻微项随重构处理。性能类结论本轮没有测量数据，只列了 2 条带「无基线」标记的方案与 4 条待验证假设，不进修复清单。
