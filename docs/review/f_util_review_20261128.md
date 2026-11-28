# f_util 模块审查报告

- **审查日期**：2026-11-28
- **模块路径**：`f_util`（48 个源文件）
- **基线**：工作区快照（`8c0ce643a`，`sts/1.3.x`，工作区干净、无 diff）
- **审查重点**：哈希 / CRC / UUID / ID 生成 / 路径匹配 / 模板格式化的正确性与性能；死代码、重复逻辑、空实现、栈溢出、OOM、并发安全、存量 BUG
- **报告版本**：v1（由 `reviews/202611280829_full/parts/f_util.part1..4.md` 合并；同一根因跨部分重复项已合并，严重程度取更严格者）

## 发现

### [严重] CityHash：长度 0..15 的输入必然越界崩溃（空串即崩）

- **位置**：`f_util/src/CityHash.cj:38`（短输入走 `weakHashLen32WithSeeds(data, 0, len, k0, k1)`）、`f_util/src/CityHash.cj:186`、`f_util/src/CityHash.cj:201-202`
- **来源**：存量（工作区快照，无 diff）
- **判据**：review-checklist §11（边界差一 / 越界）+ §10 正确性
- **证据**：静态确定 —— `len <= 16` 分支里 `fetch64(bytes, offset + len - 8)` 在 `len < 8` 时偏移为负；`a = fetch64(bytes, offset)`、`b = fetch64(bytes, offset + 8)` 无条件读 16 字节，`len` 在 8..15 时越过后 8 字节。`fetch64`（`:132-139`）逐字节 `bytes[offset + i]`，仓颉数组下标有边界检查 ⇒ 抛越界异常。
- **描述**：`cityHash("")`、`cityHash("id")`、任意长度 < 16 的字符串/字节数组均抛异常。该函数是 `public` 对外 API，文档未声明长度下限，最常见的短输入直接不可用。
- **建议**：按 CityHash 参考实现补齐 `len` 0..15 的四个分支（`≥8 / ≥4 / ≥1 / =0`），或入口校验 `data.size >= 16` 并抛带说明的异常；`fetch64` 增加偏移上界断言。

### [严重] CityHash：`len >= 128` 且非 128 倍数时尾部循环不递减 `remaining`，读到越界

- **位置**：`f_util/src/CityHash.cj:78-94`（`let remaining = len - pos` 之后循环体只更新 `tailOffset`）
- **来源**：存量（工作区快照，无 diff）
- **判据**：review-checklist §11（边界 / 循环终止条件）+ §4 同源
- **证据**：静态确定 —— `while (remaining > 0)` 的条件变量在循环内从未修改，只有 `tailOffset += chunkSize`；`chunkSize` 由未变的 `remaining` 推出，每轮读"新偏移 + 旧长度"，直到 `fetch64(data, tailOffset + chunkSize - 16)` 越界抛异常。
- **描述**：`len` 为 129、160、1000 这类非 128 倍数输入（几乎全部真实输入）在块循环结束后进入尾部循环，很快越界崩溃；`len` 恰为 128 倍数时尾部逻辑被整段跳过，与 CityHash 收尾不一致。
- **建议**：循环条件改 `while (tailOffset < len)`，每轮在循环内重算 `remaining = len - tailOffset`；按参考实现用 `len & 127` 做 4 段收尾（`≥32 / ≥16 / ≥8 / >0`）。

### [严重] MurmurHash3 x64-128：`len % 16 == 8` 时尾部 8 字节被异或两次，完全不参与哈希

- **位置**：`f_util/src/MurmurHash3X128.cj:77-108`（`if (tailLen >= 8) {...}` 之后接 `if (tailLen > 8) {...} else if (tailLen > 0) {...}`）
- **来源**：存量（工作区快照，无 diff）
- **判据**：review-checklist §11（逻辑错误 / 契约与实现不符）+ §2（同一 `k1` 混合代码写两遍）
- **证据**：静态确定 —— `tailLen == 8` 时第一个分支已算 `k1_tail` 并 `h1 ^= k1_tail`；`tailLen > 8` 为假，落到 `else if (tailLen > 0)` 用相同 8 字节重算同一个 `k1_tail` 再异或一次，两次异或同一值等于没异或。
- **描述**：所有长度 ≡ 8 (mod 16) 的输入（8、24、40 …）最后 8 字节对 `h1` 零贡献 ⇒ 同长度、仅尾部 8 字节不同的两条消息哈希相同。`murmurHash` 被 `f_codec` 当通用哈希用（`f_codec/src/default/DefaultCodec.cj` 6 处），系统性碰撞会放大到缓存键/去重键，且与标准 MurmurHash3 不可互操作。
- **建议**：`else if (tailLen > 0)` 改为 `else if (tailLen > 0 && tailLen < 8)`；补"同长度仅最后 8 字节不同必须不同哈希"的用例（现有用例未覆盖 8..15 尾部）。

### [严重] DiffieHellmanKeyExchanger：`Decimal ** 63 位指数` 用无限精度，运算不可能完成且结果不是 `g^a mod p`

- **位置**：`f_util/src/DiffieHellmanKeyExchanger.cj:97-99`（`(Decimal(BigInt(true, g)) ** ab_).toBigInt() % BigInt(true, p)`）、`f_util/src/DiffieHellmanKeyExchanger.cj:84`（`ab_ = random()`，`random()` 取 `nextInt64()`）
- **来源**：存量（工作区快照，无 diff）
- **判据**：review-checklist §5（按不可信规模展开运算）+ §11（契约与实现不符）+ §10 正确性
- **证据**：静态确定 —— ① `Decimal(BigInt)` 默认精度为 0 即无限精度（std 文档 `math_numeric_package_structs.md:3154`），`Decimal ** Int64` 为精确乘方（同文件 `:4904-4930`），指数为 `nextInt64()`（≈2^63 量级），结果位数约 `128 × 2^62`；② `nextInt64()` 有一半概率为负，负指数走 decimal128 舍入，`toBigInt()` 舍去小数 ⇒ `|g^a| < 1` 时得 0，`A`/`S` 恒为 0，`key()` 返回 `"0"`，Server 侧 `while (result == '0')` 持续重试。
- **描述**：注释与 README 承诺教科书式 DH（`A = g^a mod p`、`S = B^a mod p`），实现既不是模幂也跑不完；正常调用表现为进程挂死/OOM，或双方拿到 `"0"` 当共享密钥（静默失效）。
- **建议**：改用整数模幂（`BigInt` 的 `**` + `%`，或复用同模块 `prime.cj` 的快速幂），指数取绝对值并限制在安全范围（如 256 bit）；`middle()` 不再走 `Decimal`；补"Alice/Bob 两侧密钥相等"用例（该文件当前无任何测试）。

### [严重] DiffieHellmanKeyExchanger：模数 `p` 与生成元 `g` 取随机字节，不做素性/生成元校验（安全）

- **位置**：`f_util/src/DiffieHellmanKeyExchanger.cj:54-59`（`semi()` 里 `randomBytes(bytes: gBytes)` / `randomBytes(bytes: pBytes)`）、`:97-99`
- **来源**：存量（工作区快照，无 diff）
- **判据**：review-checklist §10 安全性（随机参数未校验）+ §11（契约与实现不符）
- **证据**：静态确定 —— `p` 是 `ThreadLocalRandom.nextBytes(16)` 的 16 字节随机值，未做 `millerRabin`/`isPrime`，未剔除偶数与 0；`g` 同样随机，与 `p` 无群关系；注释第 7 条却宣称"鉴于计算离散对数的困难性"。
- **描述**：模数为偶数（≈50%）时 `Z_p*` 结构退化，离散对数几乎可直接求出；奇合数也可被 Pohlig–Hellman 分解。叠加 128 bit 模数（远低于现代下限），这套交换不具备机密性，却以"密钥交换协议"对外提供。
- **建议**：使用 RFC 3526 group14/16 安全素数或固定 2048 bit 素数常量；`g` 取该群生成元/大素数阶子群元素；构造时校验 `p` 为素数且 `p > 2^2047`；短期不改则 README 与类注释必须写明"仅供演示，不可用于真实密钥交换"。

### [严重] PathPattern：回溯分支不推进状态，同深度路径多一级不匹配即无限循环

- **位置**：`f_util/src/PathPattern.cj:363-426`（`match (node.prev)` 三个回退分支各做 `i -= 2`），根因在 `f_util/src/PathPattern.cj:259`（子节点命中时无条件 `prevPlaceholder = NonePathNode.INSTANCE`）
- **来源**：存量（工作区快照，无 diff）
- **判据**：review-checklist §11（逻辑错误 / 循环不终止）+ §6.4（死循环等价无穷复杂度）
- **证据**：静态确定 —— pattern=`/{a}/x/y`、path=`/p/x/z`：`i=2` `getSub("x")` 命中并重置 `prevPlaceholder`（`:259`）；`i=3` 所有候选失败后进入 `case Some(n) where n is PlaceholderPathNode`（`:364`）做 `i -= 2` ⇒ `i=1`，`:425 i++` ⇒ `i=2`；再次命中、再次重置、再次进入同一分支。回路中无变量单调变化，"已试过该占位符"标记被 `:259` 清掉 ⇒ 永久循环。
- **描述**：只要路由存在"占位符后跟两个及以上字面段"的形态（如 `/{id}/detail/info`），任何同深度但尾部不匹配的请求（如 `/18/detail/other`，最普通的 404）就让请求线程 100% CPU 卡死。该函数在 `data(path)`（`:466-468`，逐请求调用）与 `matches(path)` 主路径上，又被 `f_mvc` 的 `HttpRequestDistributorImpl.getHandler` 每请求调用。
- **建议**：加"进展"守卫——记录 `(node, i)` 或本层已试候选，回溯到已访问 `(node, i)` 直接 `return None<T>`；或不要在 `getSub` 分支清空 `prevPlaceholder`；补两条用例：`/{a}/x/y` vs `/p/x/z`（false）、vs `/p/x/y`（true）。

### [严重] PathPattern：请求路径写共享 `patterns`，读侧完全无锁 —— 数据竞争 + 按请求深度永久增长

- **位置**：`f_util/src/PathPattern.cj:242`（`get` 里 `getPathNode(len)`）、`:68-99`（`getPathNode` → `populateNode` → `synchronized(mutex)` 内 `patterns.add` / `patterns[len] = node`）、`:90`（`patterns.get(len)` 在锁外）
- **来源**：存量（工作区快照，无 diff）
- **判据**：review-checklist §12.1（共享可变状态无保护 / 检查-然后-写入）+ §5（无界容器）
- **证据**：静态确定 —— `patterns` 是非并发 `ArrayList<PathNode>`（`:49`），只有 `populateNode`（`:70-87`）与 `doCompile`（`:130-151`）持锁写；匹配路径上的 `get`（`:242`）→ `getPathNode`（`:90` 的 `patterns.get(len)`）全部锁外读。请求段数大于 `patterns.size` 时 `:95-98` 在**请求线程**执行 `patterns.add(NonePathNode.INSTANCE)`。
- **描述**：两个并发访问者是任意两个请求线程：A 遍历 `patterns[len]` 及子节点 HashMap，B 扩容 `patterns`，两者无同步。后果是读到不同步状态、误判路由、两个线程为同一深度创建节点互相覆盖。附带：`patterns` 随"见过的最大路径深度"永久增长，属读路径上泄漏常驻内存。
- **建议**：最后一次 `compile` 后冻结为只读快照（构造期生成完整数组，越界直接返回 `None`）；若必须运行期扩容，读写同锁或"不可变数组 + 原子替换引用"。补并发用例：1 线程注册 + N 线程请求不同深度路径。

### [严重] computeBytes：`groupCount() >= 2` 恒真，纯数字与 `10b` 一律抛 "not supported byte unit"

- **位置**：`f_util/src/Utils.cj:29-33`（`if (matched.groupCount() >= 2) { ... } return num`）、`:36-57`（单位分支）
- **来源**：存量（工作区快照，无 diff）
- **判据**：review-checklist §11（恒真分支 / 函数不可用）+ §1（不可达语句）
- **证据**：静态确定 —— `MatchData.groupCount` 数的是捕获组个数（std 文档 `regex_package_structs.html`，示例 3 组 → 3）；正则 `^(\d+)([kmgtpezyKMGTPEZY]?)[bB]?$` 恒有 2 个捕获组，`:29` 恒真、`:33 return num` 不可达。第二组可为空串 ⇒ `computeBytes("123")` → `computeBytes(123, "")` → `:57 throw IllegalArgumentException("not supported byte unit: ")`；`"10b"` 同理。旁证：`fmq/src/config/MQConfig.cj:183-186` 注释写明该实现对单位分组取值不稳定并自建 `parseByteSize`。
- **描述**：公开工具函数对最常见的两种写法（无单位、`b` 单位）直接抛异常；不匹配输入在 `:27 find(...).getOrThrow()` 抛 `NoneValueException` 而非 `None`；`z`/`y` 单位按默认溢出策略抛异常。调用方无法用 `Option` 判空。
- **建议**：改用 `matched.matchString(2)` 判空（空即无单位 `return num`）；删除永不成立的多字单位分支；溢出用 `CheckedOp` 返回 `None`；`find` 失败直接返回 `None`。

### [严重] GeoHash.encode 二分比较方向反了：同号象限所有坐标折叠成同一个 hash

- **位置**：`f_util/src/geohash.cj:41`（`h |= if(midlng >= longitude) { lowlng = midlng; 1 << shift }`）、`f_util/src/geohash.cj:49`（`if(midlat >= latitude)` 同构）
- **来源**：存量（工作区快照，无 diff；`git blame -L 31,59` 落在换行统一提交，逻辑更早已存在）
- **判据**：review-checklist §11（逻辑错误 / 分支方向）+ §10 正确性
- **证据**：静态确定 —— `decode`（`:66-91`，bit=1 → 取上半区）、`tryParse`、`toString` 均约定"bit=1 取上半区"；但 `encode` 在坐标落**下**半区时置 bit=1 并把区间推到**上**半区。于是每步保留不含该点的半区：`longitude > 0` 时 31 个 lng 位全 0，`latitude > 0` 同理 ⇒ 东北象限全为 `0x0`；西南象限全为 `0xFFFF…`；混合符号得 `0x5555…`/`0xAAAA…`。全部坐标只剩 4 个 hash，`decode(0x0) = (-180,-90)`。
- **描述**：`GeoHash` 退化为"经度符号 1 bit + 纬度符号 1 bit"的 2 bit 编码：不保距、不可逆，`==`/`hashCode` 把整个象限判等，作 HashMap 键/空间索引完全不可用；它还是 `Parsable`/`DataParsable`，反序列化会把错误值带进业务。仓内零生产引用，属"公开 API 一用就错"。
- **建议**：两处比较取反（`if (longitude >= midlng) { lowlng = midlng; 置位 } else { highlng = midlng }`，纬度同）；统一 `1u64`/`0u64` 字面量。补 4 条用例：同象限两个远点不同 hash、`decode(encode(p))` 误差 < 1e-6、`toString` 长度恒 32、`tryParse(toString(g)) == g`。

### [严重] GeoHash.tryParse 用「解析前的区间中点」重新 encode，`parse(toString(g))` 恒不成立

- **位置**：`f_util/src/geohash.cj:112-123`（`lng`/`lat` 在 `match` **之前**取中点，循环结束只 `encode(lng, lat)`）
- **来源**：存量（工作区快照，无 diff）
- **判据**：review-checklist §11（返回值与输入语义不符）+ §10（`Option` 隐式装箱掩盖少判 `Some`）
- **证据**：静态确定 —— 每个 rune 只更新区间，没有把数字位累加进 `hash`；`hash` 来自最后一行 `encode(lng, lat)`，而 `lng/lat` 是区间更新前的中点（4 个子格公共角点）；角点重新 encode 必然落到另一子格。`tryParse("0"×32)` 返回 `0xFFFF…` ⇒ `"3"×32`，反向亦然。空串返回 `Some(0xFFFF…)`，长度 > 32 不拒绝。
- **描述**：`tryParse`/`parse` 对任何合法四进制串返回与输入无关的值（实际只有 4 种结果），`parse(x).toString() != x` 恒成立；`GeoHashException` 只在非 `0..3` 字符时触发，"字符串非法"契约等于没实现。
- **建议**：按位重建 `h = (h << 2) | digit`，校验 `0 < n <= 32`，最后 `Some(GeoHash(h))`；不要复用 `encode`（点→位 vs 位→hash 语义不同）。补 `parse("0")`、`parse("0"×32)`、`parse("")`、`parse("0"×33)`、`parse("4")` 用例。

### [严重] isPrime：qpow/millerRabin 的 UInt64 乘法溢出，p ≳ 2³² 直接抛 OverflowException

- **位置**：`f_util/src/prime.cj:31`（`ans = (ans * aa) % m`）、`:34`（`aa = (aa * aa) % m`）、`:49`（`t = (t * t) % p`）
- **来源**：存量（工作区快照，无 diff）
- **判据**：review-checklist §11（错误处理缺失 / 契约与实现不符）+ §10 正确性
- **证据**：静态确定 —— 仓颉算术默认禁止溢出（`basic_operators.md:5`、`integer.md:137`、`compile_options.md:233-235`，默认 `throwing`；`f_util/cjpm.toml` 未改该选项）。`aa < m`，当 `m > 2³²` 时存在 `aa ≥ 2³²`，`aa * aa ≥ 2⁶⁴` 必然溢出；`ans * aa`、`t * t` 同理。
- **描述**：`isPrime(p: UInt64)` 声明域为全部 `UInt64`，但只有 `p < 2³²` 能正常返回；`p ≥ 2³²` 在 `qpow` 抛 `OverflowException`，把"谓词"变成"异常源"。同类：`qpow(a,b,0)` 的 `% 0` 抛 `ArithmeticException`、`millerRabin(x,0)` 的 `p-1` 无符号下溢抛异常，三者均无前置条件说明。
- **建议**：改用 128 位中间积（本模块已有 `UInt128`）或 `mulHigh`/`CheckedOp` 做模乘；`qpow` 开头校验 `m >= 2`，`millerRabin` 断言 `p > 2 && x % p != 0`；补 `isPrime(UInt64.Max)`、已知素数、强伪素数用例。

### [严重] `UUID.timestampNanos` / `timestamp` 对 v1 / v6 / v7 全部溢出抛异常，v7 另有 4096 倍误差

- **位置**：`f_util/src/uuid.cj:116-173`（`:168 n * 10000`、`:171 n * 100`）、`f_util/src/uuid.cj:174-183`
- **来源**：存量（工作区快照，无 diff）
- **判据**：review-checklist §11（边界 / 溢出）+ §10 正确性；溢出语义按 `compile_options.md:235`（默认 `throwing`）
- **证据**：静态确定 —— v1/v6 拼出 60 bit「1582 年起 100 ns 数」，2026 年约 `1.4e17`，`n * 100` 得 `1.4e19` > `Int64` 上限 `9.22e18` ⇒ 抛 `OverflowException`；v7（`:137-151`）把 `rand_a` 低 12 bit 当时间戳低位，`n = (ms << 12) | rand`，再 `* 10000 * 100` ⇒ `7.3e19`，同样抛；即使回绕，v7 结果仍错 4096 倍。
- **描述**：任何真实时间生成的 v1/v6/v7 UUID 读 `timestamp`/`timestampNanos` 都抛异常（v7 还叠加位错位），两个属性目前不可用。旁证：`fdbm/src/idmaker/IdMakers_test.cj:194` 注释自认溢出并自行解码；生产路径只用 `toString()`，缺陷未暴露。
- **建议**：改成不溢出的表示（`timestamp: ?DateTime` 或 `timestampSeconds` + `timestampNanosOfSecond`）；v7 改为 `(n >> 12) * 1_000_000` 且只取前 48 bit；补 v1/v6/v7 与 `DateTime.now()` 误差 < 1 s 的用例。

### [严重] `UUID.unixTimeBased()`（v7）时间戳整体右移 16 位，写入值被压缩 65536 倍

- **位置**：`f_util/src/uuid.cj:397`（`UInt8((millis >> (7 - i) * 8) & 0xff)`，`i` ∈ 0..5）
- **来源**：存量（工作区快照，无 diff）
- **判据**：review-checklist §11（逻辑错误 / 位偏移）+ §10 正确性
- **证据**：静态确定 —— v7 的 `unix_ts_ms` 是 48 bit，第 `i` 字节应取 `millis >> ((5 - i) * 8)`；代码用 `(7 - i) * 8`，`i=0/1` 取第 56/48 位（恒 0），`i=2..5` 取第 40/32/24/16 位 ⇒ 实际写入 `millis >> 16`，低 16 位丢弃。
- **描述**：`unixTimeBased()` 的 48 bit 时间戳只有 `ms / 65536`，同一 65.5 s 窗口内 ID 前缀相同、顺序由随机位决定，v7 承诺的"按时间可排序"失效。调用点：`fdbm/src/idmaker/IdMakers.cj:66`（主键）、`f_llm/src/store/EvolutionLease.cj:36`（租约标识）。
- **建议**：改 `(5 - i) * 8`；补"`parse(unixTimeBased().toString())` 解出时间戳与 `DateTime.now()` 相差 < 1 s"与"连续两次字典序不倒退"用例。

### [严重] `serialSeq` 序列生成器在同一时间戳下不递增 ⇒ 固定 node 时生成完全重复的 UUID

- **位置**：`f_util/src/uuid.cj:695-702`（内存 CAS 版 `if (last >= timestamp) { seq.load() }`）、`f_util/src/uuid.cj:666-668`（文件版同分支直接 `seq`）；消费侧 `:497-501`、`:709-722`
- **来源**：存量（工作区快照，无 diff）
- **判据**：review-checklist §11（主键重复）+ §12.1（检查-然后-写入未保证唯一性）
- **证据**：静态确定 —— 时间戳未变时两条实现都只读不增，返回当前 `seq`；同一 `timestamp` 的第二次及以后调用得到相同 `(timestamp, seq)`，`generate()`（`:567-585`）只写字节 0..9，仅 node 不同。node 固定（`node(mac)`/`ether(...)`，v1/v6 标准用法）时结果逐字节相同 ⇒ UUID 重复；`seq` 为 `UInt16`，回绕后再次碰撞。
- **描述**：`serialSeq` 名义上"同一时间戳内递增"，实际同 ts 内恒定，既不唯一也不单调。仓内 `fdbm` 每次 `randomNode()` 把概率压到 2⁻⁴⁸，掩盖了问题；外部按 RFC 用固定 MAC 作 node 时，高频取号会直接产生重复主键。
- **建议**：语义改为"时间戳前进 → CAS 换 ts 并 seq 归零；ts 未变 → `seq.fetchAdd(1)`"（文件版同样回写）；补"固定 node + 同 ts 并发 1e5 次不重复"用例。

### [一般] IdMaker：同一毫秒、同一 hostSerial 的两个实例产生完全相同的 ID 序列

- **位置**：`f_util/src/IdMaker.cj:26`（`startMillis`）、`:32`（`current = AtomicInt64((hostSerial << 53) | (startMillis << 12))`）、`:40-42`
- **来源**：存量（工作区快照，无 diff）
- **判据**：review-checklist §11（唯一性契约）+ §10 正确性
- **证据**：静态确定 —— 起始值只由 `hostSerial` 与构造毫秒决定，无进程 ID、实例序号或随机位；同一毫秒内两个 `IdMaker()` 的 `current` 完全相等。另：时间戳占 bit12..52 共 41 位且为绝对 epoch 毫秒（2^41 ms ≈ 69.7 年），2039 年后溢出进 hostSerial 段。
- **描述**：定位是"趋势递增的分布式 ID"，但唯一性只在本实例内成立；多模块各自 `IdMaker()` 或分片共用 hostSerial 时产生主键级重复。
- **建议**：起始值掺入进程级随机低 12 位或配置 `workerId/processId`；41 位时间戳改为相对自定义 epoch 并校验上限；显式处理 `while` 自增跨 2^12 的进位。

### [一般] Factory / Mediator：注册表静默覆盖同名项，缺键时直接抛 `NoneValueException`（契约未声明）

- **位置**：`f_util/src/Factory.cj:36`（`producers.add(...)`）、`:50`、`:53`；`f_util/src/Mediator.cj:23`（`colleagues[colleague.name] = colleague`）、`:26`
- **来源**：存量（工作区快照，无 diff）
- **判据**：fountain-baseline §4（同名注册应启动即失败）+ review-checklist §11（错误处理缺失 / 契约不符）
- **证据**：静态确定 —— `HashMap.add` 对已存在 key 会替换并返回旧值（std 文档 `collection_package_class.md:4861`），两处均丢弃返回值；`operator[](K)` 缺键抛 `NoneValueException`（同文件 `:6147`），`produce`/`execute` 未用 `get()` 判空。
- **描述**：重复注册时后者静默赢，线上表现为"某个实现莫名不生效"；未注册就 `produce` 抛出与 `f_util` 无关的 `NoneValueException`，调用方无法区分"未注册"与"内部错误"。README（`f_util/README.md:143-160`、`:172-180`）未写这两条语义。
- **建议**：`assemble`/`register` 检查 `add` 返回值，非 `None` 抛 `IllegalStateException`；`produce`/`execute` 改用 `get()` 并抛专用异常，或在 README 明确现状。

### [一般] 注册表类均为非并发容器且未声明线程约束（Factory / Mediator / ResponsibilityChain / Strategies）

- **位置**：`f_util/src/Factory.cj:33`（`HashMap`）、`:36` 写、`:50/:53` 读；`f_util/src/Mediator.cj:21`、`:23`、`:26`；`f_util/src/ResposibilityChain.cj:45`（`ArrayList`）、`:56-64`、`:70-82`；`f_util/src/StrategyPattern.cj:42`（`HashMap`）、`:46-54`、`:59-64`
- **来源**：存量（工作区快照，无 diff）
- **判据**：review-checklist §12.1（共享可变状态无保护 / 迭代与修改并发）
- **证据**：静态确定（无锁、无 `Concurrent*`、无"仅启动期注册"契约）；仓内除测试外零调用方，实际并发使用点待确认。
- **描述**：四个类都是 `public`，`std.collection.HashMap`/`ArrayList` 非线程安全。存在运行期注册与并发查找时，可能读到扩容中的桶数组：读到旧值、丢注册项，极端情况桶链断裂死循环。**严重程度说明**：part1 按"可能被并发调用"判一般；part2 因仓内零引用、并发点未确认判轻微。合并取更严格的一般。
- **建议**：二选一并写进类注释——(a) 注册只在启动期、之后只读（`frozen` 标志拒绝后写）；(b) 换 `ConcurrentHashMap`。读多写少用"不可变快照 + 原子替换引用"。

### [一般] DiffieHellmanKeyExchanger：`ab_` 是实例级可变私有状态，`key()` 内部清零重掷，同实例并发调用互相破坏

- **位置**：`f_util/src/DiffieHellmanKeyExchanger.cj:84`（`protected var ab_`）、`:64-71`（`key()` 里 `ab_ = 0` 后循环）、`:86-90`
- **来源**：存量（工作区快照，无 diff）
- **判据**：review-checklist §12.1（检查-然后-写入 / 共享可变状态）
- **证据**：静态确定 —— `key()` 先 `ab_ = 0`，靠 `super.key()` 内 `ab()` 重新赋值；`finish()` 用同一个 `ab_` 算公开值 `B`。两线程同时 `key()`/`finish()` 时 `B` 可能对应另一线程的 `b`，双方密钥必然不等。
- **描述**：`Server` 侧"先 key 后 finish"的时序契约（`:72-77`）在并发下无法维持，`ab_` 被改写后交换静默失败。
- **建议**：`ab_` 改为构造时确定且不可变（`let`），去掉 `key()` 内重试；若必须重试，把 `ab_` 与 `B` 封装为每会话对象，禁止复用实例。

### [一般] UUID.tryParse 过松又过严：忽略分隔符/尾部多余字符、只认小写、只认 variant 2；连带 `IsUUID` 把大写 UUID 判为非法

- **位置**：`f_util/src/uuid.cj:192-251`（`:225-246` 解析循环、`:196-220` nibble 表、`:247-249` variant 校验）；下游 `f_util/src/IsUUID.cj:25`（`UUID.tryParse(x).isSome()`）；根因 `f_util/src/uuid.cj:208-213`（`doParse` 只映射 `a-f`，其余 `case _ => 17` ⇒ `None`）
- **来源**：存量（工作区快照，无 diff）
- **判据**：review-checklist §11（边界 / 输入校验）+ §10 正确性
- **证据**：静态确定 —— ① 只有 `i ∈ {4,6,8,10}` 且字符恰为 `'-'` 才跳过，其余位置不校验分隔符；这些位置被 hex 占位时整体左移吞掉前 32 字符，最后 4 字符不读 ⇒ 长度 36 的构造串可解析成功并映射到同一 UUID；② `doParse` 只列 `a-f`，大写输入一律 `None`；③ `:247` 要求 `values[8] >> 6 == 2`，variant 0/6/7 的合法串无法解析。
- **描述**：`parse` 输入来自 HTTP/JSON/DB，宽松解析让"不同字符串 → 同一 UUID"，宽松+严格混用让同一 UUID 的不同书写形式一半可读一半不可读，`toString`/`parse` 往返契约不成立。`IsUUID` 只做透传，因此 `550E8400-E29B-41D4-A716-446655440000` 这类合法 UUID 校验失败，错误信息只说"必须是UUID格式"，用户无从得知是大小写问题（十六进制大小写不区分是通用约定）。
- **建议**：按 8-4-4-4-12 逐段校验（总长 36、连字符位置固定、其余必须 hex、大小写都收），解析结束断言迭代器耗尽，variant 只校验最高位模式；`doParse` 增加 `A-F` 分支（或 `validate` 先转小写）。补非法串用例（缺分隔符、尾部多余、大写、非 RFC variant）。

### [一般] PathPattern：`{id:\d{4}}` 的正则不补尾部锚点，5 位数字也命中

- **位置**：`f_util/src/PathPattern.cj:826-833`（`if (!name.startsWith("^")) { prefix = "^" } else if (!name.endsWith("$")) { suffix = "$" }`）、`:860-862`
- **来源**：存量（工作区快照，无 diff）
- **判据**：review-checklist §11（契约与实现不符）+ §10 正确性
- **证据**：静态确定 —— `else if` 使"补 `^`"与"补 `$`"互斥，不以 `^` 开头时只加 `^`，得到 `^(\d{4})`；`Regex.matches` 语义是"是否存在匹配"（std 文档示例 `\d{4}-\d{2}-\d{2}` 对 `"2024-10-24&2025-01-01"` 返回 true），不是全串匹配。因此 `12345`、`1234abc` 均命中。
- **描述**：路径参数的正则约束被放宽为前缀匹配，`/{id:\d{4}}/detail` 接受任意长度数字；`{#regex:\d+}` 同类问题（现有测试只验证 prefix 模式，掩盖了 exact 模式过度匹配）。
- **建议**：拆成两个独立判断（缺 `^` 补 `^`、缺 `$` 补 `$`），或统一 `"^(${name})$"` 并用 fullMatch 语义；补负向用例 `matches("/12345") → false`。

### [一般] ComplexPathNode：占位符后的字面后缀被丢弃，`{id}.json` 会匹配 `/x.txt`

- **位置**：`f_util/src/PathPattern.cj:890-897`（正则 `(.*?)\{(.+?)\}(.*?)` 只 `add` 了 `matchString(1)`/`(2)`，第三组丢弃）、`:899-914`、`:916-945`
- **来源**：存量（工作区快照，无 diff）
- **判据**：review-checklist §11（逻辑错误）+ §2（`matches` 与 `extract` 各写一遍分段遍历，两边都少一段）
- **证据**：静态确定 —— `{id}.json` 的 `parts = ["", "id"]`；`matches("foo.txt")` 时 `i=0` 的静态段为空串 ⇒ `startsWith("")` 为真、`pos=0`，循环结束返回 true。`extract("foo.txt")` 因 `i+2 < parts.size` 为假，`end = value.size`，返回 `{"id": "foo.txt"}`。
- **描述**：`/{id}.json`、`/report/{date}.csv` 会匹配任意扩展名（甚至任意内容），并把整段（含后缀）当变量值；`withExtName=false` 的调用先裁掉 `.txt`，使"后缀约束"看似生效实则不生效。`f_mvc` 的 `meta.path` 直接来自注解，带后缀路由是自然用法。
- **建议**：把 `matchString(3)` 也 `add` 进 `parts`，`matches` 末尾校验 `value.endsWith(最后静态段)`；`extract` 与 `matches` 合并为一次扫描。

### [一般] TextTemplate：number 占位符的空值分支把 `noneConverter` 丢弃，空串继续走 `Decimal.parse` 抛异常

- **位置**：`f_util/src/TextTemplate.cj:406-410`（`if (value.isEmpty()) { noneConverter }`）
- **来源**：存量（工作区快照，无 diff）
- **判据**：review-checklist §11（读取不用 / 错误路径缺失）+ §3（静默分支）
- **证据**：静态确定 —— `noneConverter` 是 `?String`，该 `if` 无 `return`，表达式值被丢弃；下一行 `Decimal.parse(value)` 对空串必然失败。同文件 `:302-308`（`Value2TimeString`）用的是 `extractNoneConverter()`，说明此处漏写。
- **描述**：字段值为空串时本应输出 `noneConverter`（如 `"-"`），实际抛异常，把"可空字段"变成运行时崩溃；`f_log` 的 `{}` 格式化正好会碰到空值字段。
- **建议**：改为 `if (value.isEmpty()) { return noneConverter.getOrThrow() }`（或 `?? "0"`，与 `Value2TimeString` 同口径），异常换成 `TextTemplateException` 保持错误族一致。

### [一般] TextTemplate：o/O/x/X 进制分支三处错 —— 丢负号、宽度补齐差、大写不生效

- **位置**：`f_util/src/TextTemplate.cj:443-448`（`BigInt(true, number.reScale(0, …).toBigInt().toBytes())`、`"${prefix}${0 * (integer - 1)}${string}"`）、`:344-347`
- **来源**：存量（工作区快照，无 diff）
- **判据**：review-checklist §11（数据错误）+ §2（十进制分支有 `upperCase`/`prefixPlus`/括号处理，进制分支缺失）
- **证据**：静态确定 —— ① `BigInt(sign:magnitude:)` 的 `magnitude` 是绝对值二进制原码，`toBytes()` 是大端补码；`BigInt(true, (-1).toBytes()) = BigInt(true, [255]) = +255`，符号与真值都错；② 补齐用 `integer - 1` 而十进制用 `integer - l`，值 `255` 配 `x####` 补成 5 位；③ `prefix` 恒为 `"0"+char`，`prefix[0]` 恒为 `'0'`，`upperCase` 永不置位，且进制分支直接 `return`，即使置位也不会 `toAsciiUpper()`。
- **描述**：`{n:x###}`、`{n:O##}` 对负数输出错误正数（金额/哈希/掩码格式化静默错值），大写 `X`/`O` 与宽度约束不生效；该分支无任何测试（模块内只有 `TextTemplateCacheKey_test.cj`）。
- **建议**：用 `toBigInt().toString(radix:)` 后在外层处理符号；补齐改 `integer - l`；`upperCase` 改判 `formatter[0] == b'X' || formatter[0] == b'O'`；进制分支末尾同样走 `:433-441` 的公共收尾。

### [一般] TextTemplate：格式串转义识别用 `template` 的下标去索引 `placeholder` 子串

- **位置**：`f_util/src/TextTemplate.cj:151-153`（number：`template[formatEnd - 1] == b'\\'` 与 `template.indexOf("`", …)`）、`:172-174`（time 同构）
- **来源**：存量（工作区快照，无 diff）
- **判据**：review-checklist §11（索引对象错位）+ §2（两段同构代码一起错）
- **证据**：静态确定 —— `formatEnd` 是相对 `placeholder` 的下标，却索引 `template`：`template[formatEnd-1]` 取模板开头附近字符，`indexOf` 也从绝对位置找。只要 `start != 0`（几乎总是），反引号转义判定就落在错误位置。
- **描述**：`{n:number:`##,##\``}` 这类含转义反引号的格式串会被截断/误判，最终报 "time format must be followed…"（错误文案从 time 分支复制，`:157`）；当前无测试覆盖。
- **建议**：两处改 `placeholder[...]` / `placeholder.indexOf(...)`，与 time 分支合并成 `parseBacktickFormat(source, tag)`；错误文案按 tag 区分。

### [一般] TextTemplate：`noneConverter` 契约只在 time/number 生效，plain 变量缺失直接抛异常（与 README 相反）

- **位置**：`f_util/src/TextTemplate.cj:290-296`（`Value2PlainString.doFormat` 忽略 `noneConverter`）、`:241-253`（缺字段抛 `TextTemplateException`）；契约 `f_util/README.md:461-462`
- **来源**：存量（工作区快照，无 diff）
- **判据**：review-checklist §14.1（承诺未实现）+ §13（文档与实现不符）
- **证据**：静态确定 —— 三个 `doFormat` 只有 `Value2TimeString`（`:302-316`）与 `Value2NumberString`（`:407`，本身有缺陷）读 `noneConverter`；`Value2PlainString` 只做 `getter.get(...).toString()`，缺字段由 `:249` 抛异常。
- **描述**：README 是 `f_log`/下游的唯一契约说明，"缺失用 `noneConverter`"最常被依赖；实际只有 `time:`/`number:` 降级，普通 `{field}` 直接抛异常，把日志格式化变成异常源。
- **建议**：`Value2PlainString` 也用 `noneConverter` 兜底（取不到 key 返回 converter，为 `None` 再抛），或改 README 明确仅 time/number 支持并说明 plain 抛异常。

### [一般] UInt128.fromBytes：构造了 HashException 却没 throw，长度 ≠ 16 静默产出错误值

- **位置**：`f_util/src/UInt128.cj:59-62`（`if (bytes.size != 16) { HashException(...) }`）
- **来源**：存量（工作区快照，无 diff）
- **判据**：review-checklist §11（错误处理缺失 / 静默错误值）+ §3（构造即丢弃）
- **证据**：静态确定 —— 语句只构造对象后丢弃，无 `throw`；随后 `for (i in 0..bytes.size)` 照常拼装。`size < 16` 时高位左移把 1 字节当最高字节，`tryParse("abcd")` 返回 `0xabcd0000…` 而非 `None`；`size > 16` 时 `(15-i)*8` 变负，移位超位宽抛 `OvershiftException`。
- **描述**：`UInt128 <: Parsable & DataParsable`，这是从 JSON/字符串反序列化 128 位哈希的唯一入口；长度非法不报错而得到"看着像哈希"的错误值，后续 `typeMurmurCreators.get(murmur)` 查不到才报"类型未注册"，把输入错误伪装成注册缺失。
- **建议**：`throw HashException(...)`；循环只处理前 16 字节或先判长度；补 `tryParse("abcd") == None` 用例（当前无测试）。

### [一般] TreeTransformer：父节点缺失时抛 `NoneValueException`，不是领域异常

- **位置**：`f_util/src/TreeTransformer.cj:58`（`map[parentId].addChild(t)`）
- **来源**：存量（工作区快照，无 diff）
- **判据**：review-checklist §11（错误处理缺失 / 契约不符）
- **证据**：静态确定 —— `map[parentId]` 是 `HashMap` 下标取值，key 不存在抛 `NoneValueException`；同函数另两条失败路径用的是 `IllegalArgumentException`（`:44-46`、`:49-51`）。
- **描述**：`parentId` 指向不存在节点（脏数据、跨页查询只取到子节点）时报无 `id`、无消息的异常，调用方无法区分"数据不完整"与"内部错误"；同一函数三条失败路径用了两种异常族。
- **建议**：改 `match (map.get(parentId)) { case Some(p) => ...; case _ => throw IllegalArgumentException("parent ... not in transformed set") }`，或文档声明"孤儿节点被丢弃"。

### [一般] State：`continues` 默认 true 且无深度/环检测，自引用状态直接栈溢出

- **位置**：`f_util/src/StatePattern.cj:27-31`（`prop continues` 默认 `true`）、`:43-52`（`startup<D>()` 内 `this.exec().startup()` 递归）
- **来源**：存量（工作区快照，无 diff）
- **判据**：review-checklist §4（无界递归）+ §11（默认值导致契约反转）
- **证据**：静态确定 —— `startup` 唯一出口是 `continues == false`；实现类忘覆盖（或 `exec` 链成环/返回自身）就无限递归，无计数、无 visited 集合。另 `startup<D>(): D` 的方法级泛型 `D` **遮蔽**接口的 `State<D>` 数据参数，`startup<Int64>()` 可在 `State<String>` 上编译通过、运行期在 `:49` 抛 `IllegalStateException`。
- **描述**：纯约定式状态机骨架，两个"默认值/泛型"问题会在实现方犯小错时变成崩溃而非编译错误；仓内无 `State` 实现。
- **建议**：`continues` 默认改 `false`；`startup` 加深度上限或 `HashSet<State>` 环检测；泛型参数改名 `R` 并加约束，或去掉方法级泛型直接返回 `D`。

### [一般] TextTemplate：静态模板缓存无容量上限，`f_log` 每次带参日志都以消息串为 key 查一次

- **位置**：`f_util/src/TextTemplate.cj:54`（`private static let templates = ConcurrentHashMap<String, TextTemplate>()`）、`:65-75`（只 `computeIfAbsent`，无淘汰）、`:80-82`（key = 长度前缀拼接）
- **来源**：存量（工作区快照，无 diff）
- **判据**：review-checklist §5（缓存键无界）+ §7
- **证据**：静态确定（无上限、无淘汰）；触发面待确认 —— `f_log/src/base/Logger.cj:51/72/95/114/133/152` 每次 `append` 都无条件 `TextTemplate.compile(message, prefix:"{", suffix:"}")`（不像 `f_llm` 先判 `contains`），`f_llm/src/agents/AgentTask.cj:232` 以整段 prompt 为 key；消息含运行时数据时 key 逐条唯一。
- **描述**：缓存项含 key 串 + `compiled` 里若干切段字符串（又一份原文）+ 对象头，单条约 2×模板长度；条目永不回收，容量与"历史上出现过的不同模板串"同阶，属长期只增不减的全局容器。
- **建议**：加容量上限 + LRU（或按 `f_cache` 策略），超限退化为不缓存直接编译；`f_log` 侧对不含 `{` 的消息跳过 `compile`；README 写明"模板应为静态字面量"。

### [一般] crc32 的平台空实现只按 `os` 收口，Linux 上的 riscv64 / loongarch64 会编译失败

- **位置**：`f_util/src/crc32_native_stub.cj:23`（`@When[os != "Linux"]`）
- **来源**：存量（工作区快照，无 diff）
- **判据**：review-checklist §11（契约不符）+ §14.1（能力覆盖缺失）
- **证据**：静态确定 —— `crc32.cj:101/:106` 无条件引用 `Crc32Hw.update(...)`；arm/x86 版分别由 `@When[os == "Linux" && arch == "aarch64"/"x86_64"]` 收口，故 `Linux + riscv64|loongarch64` 上 `Crc32Hw` 无定义 ⇒ 编译失败。同族 `crc64_native_stub.cj:24` 写法正确（`os != "Linux" || (arch != "aarch64" && arch != "x86_64")`），其注释 `:20-22` 明确提到该场景。README `:71` 承诺"其它 OS/架构始终纯软件"。
- **描述**：README 与 `crc64` stub 都把"Linux 非 x86/aarch64"当受支持平台，只有 `crc32` 的 stub 漏了这一维；`crc32_native_stub.cj:21` 注释"只有这两种 target"与同目录 `crc64` stub 直接矛盾。
- **建议**：`crc32_native_stub.cj:23` 改成与 `crc64_native_stub.cj:24` 完全一致的 `@When`；两处条件抽成共享说明，避免再次分叉。

### [一般] `F_UTIL_CRC_HW=off` 对 CRC-32 无效：两套开关解析只认 `"0"`

- **位置**：`f_util/src/crc32_native_arm.cj:159-164`、`f_util/src/crc32_native_x86.cj:194-199`（`case Some(v) => v != "0"`）
- **来源**：存量（工作区快照，无 diff）
- **判据**：review-checklist §11（同一开关两套语义）+ §2（字面量复制已漂移）
- **证据**：静态确定 —— `crc64_native_arm.cj:287-299` / `crc64_native_x86.cj:295-307` 的 `parseMode` 接受 `off/0`、`on/1`、其它/未设（Auto）；`crc32` 的 `envEnabled` 只把 `"0"` 当关闭，`off/OFF/false` 全被当开启。README `:88` 对外口径是"`F_UTIL_CRC_HW=off`（或 `0`）强制回退"；`doc/spec/accelerate-f-util-crc/design.md:192` 也写"0/off 视为 off、1/on 视为 on"。
- **描述**：按 CRC-64 文档关硬件（`off`）时 CRC-32 仍启用，排障/规避 `mprotect` 被拦截时出现"关了但一半没关"。附带：`crc32` 的 `resetForTest`（`arm:120-127`/`x86:150-157`）不重置 `nativeEnabled`，`crc64` 的会复位 `forcedOff`，同名测试钩子语义不同。
- **建议**：把 `parseMode`/`isOff` 上提为共享解析函数（`CrcGf.cj` 已有 `enum CrcHwMode`），四个 native 文件都调它；`resetForTest` 统一"恢复到初始态（含开关）"。

### [一般] CRC 硬件层脚手架在 4 个文件各写一遍，已出现三处分叉

- **位置**：`f_util/src/crc32_native_arm.cj:36-186` 与 `crc32_native_x86.cj:34-212`（`lock`/`ready`/`nativeEnabled`/`codes`/`available`/`availableFor`/`update`/`call`/`setNativeEnabled`/`resetForTest`/`ensureReady`/`make`/`envEnabled`/`cpuFlags` 逐行同构）；`crc64_native_arm.cj:33-305` 与 `crc64_native_x86.cj:36-321`
- **来源**：存量（工作区快照，无 diff）
- **判据**：review-checklist §2（只改类型名 / 换控制流的重复实现）
- **证据**：静态确定 —— 已漂移：① `envEnabled` 两态 vs `parseMode` 三态；② `crc64_native_arm.cj:214-232` 的 `ensureReady` 只判 `fn.isSome()`，x86 版 `:238-257` 判 `fn.isSome() || fnNorm.isSome()`；③ `crc32_native_arm.cj:166-173` 的 `hasCrc32` 有 `/proc/cpuinfo` 回退，`crc64_native_arm.cj:301-305` 的 `hasPmull` 只读 `getauxval`，容器屏蔽 auxv 时 CRC-32 走硬件、CRC-64 静默回退；④ `resetForTest` 对开关复位不一致。这些差异无注释说明。
- **建议**：抽包内 `struct CrcHwSlot`（`ready` + `lock` + `?CFunc` + `codes` 保活表 + `acquire/release`），平台文件只提供 `probe()`/`code()`/`consts()`；`CrcHwMode` 解析、`cpuFlags`、`call` 的 `finally release` 各保留一份。合并前补 4 个文件同输入 raw 值对拍用例。

### [一般] Miller-Rabin 在循环中途 `t == 1` 也返回 true，且 5 个基不足以覆盖 UInt64

- **位置**：`f_util/src/prime.cj:45-51`（`if (t == 1 || t == p - 1) { return true }` 在每次平方前执行）、`:63`（`let a: Array<UInt64> = [2, 3, 5, 7, 11]`）
- **来源**：存量（工作区快照，无 diff）
- **判据**：review-checklist §11（逻辑错误 / 契约不符）
- **证据**：静态确定（分支语义）—— 标准强伪素数判定只允许首轮 `t == 1 || t == p-1`、后续平方后 `t == p-1` 认定"可能为素数"；平方后出现 `t == 1` 说明找到 1 的非平凡平方根，应判合数。本实现循环体内无条件 `return true`。另 `{2,3,5,7,11}` 只在约 `2.15×10¹²` 以下确定，更大值存在强伪素数（如 `3825123056546413051`）。
- **描述**：即使修好模乘溢出，`isPrime` 仍会对一部分合数返回 `true`，且返回值无"probable"语义提示。
- **建议**：`t == 1` 判定移到首轮或直接判 `false`；基表改为 `{2,3,5,7,11,13,17,19,23,29,31,37}`（64 位确定）或补 Baillie-PSW；命名/KDoc 写明确定性或概率语义。

### [一般] v5（`sha1`）取 SHA-1 尾部第 18/19 字节，与 RFC / 主流实现不互操作

- **位置**：`f_util/src/uuid.cj:363-375`（`:367 sha[18]`、`:369 sha[19]`、`:371/:373 sha[8..15]`）；注释自认在 `:351`
- **来源**：存量（工作区快照，无 diff）
- **判据**：review-checklist §11（契约不符）+ §13（README `:565` 写 version 5）
- **证据**：静态确定 —— RFC 4122 §4.3 / Python `uuid5` / Java `nameUUIDFromBytes` 都是取摘要**前 16 字节**再覆写版本/变体位；本实现把第 18/19 字节塞进 UUID 第 6/7 字节，摘要第 6/7/16/17 字节被丢弃，byte8 之后又回到 `sha[8..15]`。同一 name 与其他语言算出的 v5 必然不同。
- **描述**：进程内自洽，但跨系统"同 name 同 UUID"的 v5 核心用途失效；注释 `:351` 已写明"此处应该是一个错误"。另 `sha1(value)`/`md5(value)` 无 namespace 参数，本身不是 RFC name-based 构造，README 未说明。
- **建议**：`values[i] = sha[i]`（i<16）后覆写版本/变体位；如需 RFC 语义补 `sha1(namespace:, name:)`，README 写清现行 API 是"无命名空间哈希派生"。

### [一般] `TimeBasedUUIDBuilder` / `TimestampSequenceBuilder` 的可变状态与序列生成器注册都无同步，API 未声明线程约束

- **位置**：`f_util/src/uuid.cj:446-458`（builder 字段）、`:477-501`（`randomSeq`/`serialSeq` 写共享字段）、`:709-722`（`mutex` 只包一次 `seqGen` 调用）、`:642-704`（`registerSequenceGenerator*` 改 `seqGen`/`closer` 不持锁）
- **来源**：存量（工作区快照，无 diff）
- **判据**：review-checklist §12.1（共享可变状态无保护、检查-然后-写入）
- **证据**：静态确定 —— 两个类都是 `public`，字段为实例可变状态：线程 A 的 `node()`（`:567-585` 读 `timestamp/seq/version`）与线程 B 的 `serialSeq`（`:483-488` 写同字段）可交错；`register*`（`:646-649`、`:689-704`）在 `timestampAndSequence`（`:709`）持锁执行时替换 `seqGen` 并 `closer.close()`，可能出现"新 seqGen + 旧 closer"或关掉正在读的文件。
- **描述**：仓内调用方（`fdbm/src/idmaker/IdMakers.cj:38-77`）用外部 `Mutex` 规避并在注释写明，说明约束真实存在，但只写在下游注释，公开签名与 README 均未声明。
- **建议**：类注释与 README 明确"非线程安全，注册必须在首次生成前完成"；或把 `register*` 与 `timestampAndSequence` 放入同一把锁（代价是注册与取号共锁）。

### [一般] 文件序列生成器：`/tmp` 硬编码、临时目录永不清理、读写位置错乱导致 seq 恒为 0/1

- **位置**：`f_util/src/uuid.cj:650-688`（`:651 Directory.createTemp('/tmp')`、`:660` 读、`:666-668` 命中旧时间戳分支、`:680-685` seek/写回）
- **来源**：存量（工作区快照，无 diff）
- **判据**：review-checklist §11（资源不对称）+ §5（磁盘条目无界）+ §10 跨平台
- **证据**：静态确定 —— ① 无 `@When[os == 'Linux']`，`/tmp` 在非 POSIX 平台不存在，构造即失败；② 每注册一次建一个临时目录，代码无删除路径（`~init` 只关文件），长期残留；③ `file.read(bytes)` 后位置为 10，`storedNanos >= timestamp` 分支直接返回不 `seek(Begin(0))`，下次 `read` 返回 0 ⇒ 走"首次"分支把 seq 重置为 1，seq 永远停在 0/1；④ `read` 返回 1..9 时按全 0 处理，时间戳被当 0。
- **描述**：该生成器（跨进程唯一性本应是其价值）既不能跨平台、又持续泄漏临时目录，序列语义退化为常量；仓内零引用（仅 `README.md:592` 列出）。
- **建议**：读后统一 `seek(Begin(0))`；路径从 `f_config` 读取并做平台判断；固定单文件 + 退出清理；无人使用则直接删除该 API。

### [一般] 锁内做文件 I/O：`timestampAndSequence` 的临界区包含 `read` / `write` / `flush`

- **位置**：`f_util/src/uuid.cj:710-721`（`synchronized(mutex)` 包住 `seqGen(timestamp)`）、被调方 `:660-687`
- **来源**：存量（工作区快照，无 diff）
- **判据**：review-checklist §6.2（锁内 I/O）/ §12.2（临界区只保护不变量）
- **证据**：静态确定（临界区内容）—— 注册文件生成器后，临界区内有 1 次 `read`、1 次 `seek`、1 次 `write`、1 次 `flush` 再 1 次 `seek`，全是系统调用；该锁是 v1/v6 每次取号的必经串行段，`fdbm` 取号路径（`IdMakers.cj:70-72`）在其外还套了自己的锁。持有时长与竞争比例待实测。
- **描述**：一旦启用文件生成器，取号吞吐被"每号一次 flush"限制，串行段随线程数放大等待。
- **建议**：锁内只算 `(ts, seq)`，持久化移出临界区（批量/异步回写）；或启动时一次性加载状态，运行期只写内存。

### [一般] `genTimestampAndSequence` 是无上限忙等：注册的生成器恒返回 0 时死循环

- **位置**：`f_util/src/uuid.cj:497-501`（`while (timestamp == 0 || seq == 0)`）、契约入口 `:465-472`
- **来源**：存量（工作区快照，无 diff）
- **判据**：review-checklist §11（错误处理缺失）+ §3（把非法返回值当重试信号）
- **证据**：静态确定 —— 循环无次数上限、无退避、无超时；`registerSequenceGenerator(generator:)` 是公开 API，用户函数恒返回 0 时 `serialSeq` 永不返回，线程 100% CPU 空转。"0 表示重试"只体现在实现里，签名 `(Int64) -> UInt16` 与文档均未表达。
- **建议**：重试上限（如 1024 次）后抛 `UUIDException('sequence generator returned 0')`；签名改 `(Int64) -> ?UInt16` 让"无可用序列"进入类型；README 写清语义。

### [一般] `etherName` / `ether` 把 I/O 失败与非法输入都映射成 `UnreachableException`，`eth0()` 是丢弃结果的空壳

- **位置**：`f_util/src/uuid.cj:502-512`（`etherName`，`:508-511`）、`:513-550`（`ether`，`:537`、`:539`）、`:503-505`（`eth0`）
- **来源**：存量（工作区快照，无 diff）
- **判据**：review-checklist §3（空实现/静默）+ §11（语义与命名不符）+ §10 错误处理
- **证据**：静态确定 —— ① 读 `/sys/class/net/<name>/address` 的 `File` 打开/读取失败（网卡不存在、无权限、容器无该文件）抛 `UnreachableException`，丢失 cause 且误导排查；② `ether('zz:...')` 非法 MAC 在 `parse` 的 `case _` 抛 `UnreachableException`，应为参数错误；③ `eth0()` 返回 `Unit` 且丢弃 `etherName('eth0')` 结果，调用后除可能抛异常外无可观察结果，README `:603-605` 却把它作为"使用 eth0"的能力列出。
- **建议**：`etherName` 改抛 `UUIDException` 并带路径与 cause；`ether` 用 `IllegalArgumentException`；`eth0()` 改为返回 `UUID`（其实现与 `etherName('eth0')` 完全重复，也可删除）。

### [轻微] CaseFormat / DiffieHellmanKeyExchanger：顶层声明省略访问修饰符，可见性依赖 SDK 默认值（跨模块引用已存在）

- **位置**：`f_util/src/CaseFormat.cj:20`（`abstract sealed class CaseFormat`，无修饰符）、`f_util/src/DiffieHellmanKeyExchanger.cj:83`（同类写法，`:53`/`:63` 的 `public class` 继承它）
- **来源**：存量（工作区快照，无 diff）
- **判据**：review-checklist §1（可见性）+ fountain-baseline §3（契约显式性）
- **证据**：待确认 —— 语言规范写"其他顶层声明默认修饰符为 `internal`"，而 `f_orm/src/macros/ORMField.cj:21`、`QueryMappersGenerator.cj:23` 跨模块 import 并使用。二者不可能同时成立：要么目标 SDK 默认可见性更宽，要么这两处本来就编不过。缺：目标 SDK 上 `cjpm build f_orm` 的实际结果。
- **描述**：写法依赖"省略即足够可见"的隐含规则，升级 SDK 或调整包划分后可能整体编译失败，对外契约不可读。
- **建议**：两处显式写 `public`（或 `internal` 并同步收窄调用方）；`DiffieHellmanKeyExchanger` 作为 `public` 类父类型必须是 `public`。

### [轻微] CityHash：与 CityHash128 算法不符，`v` 的写入被下一行覆盖（无效计算）

- **位置**：`f_util/src/CityHash.cj:64-68`（`:65` 算 `v`，`:67` 立即 `v = UInt128(x, z)` 覆盖）、`:184-202`（`a` 在 `:201` 被 `fetch64` 覆盖）、`:73-96`
- **来源**：存量（工作区快照，无 diff）
- **判据**：review-checklist §1（读了不用的死写入）+ §11（与命名/文档承诺的算法不符）
- **证据**：静态确定 —— `:67` 无条件覆盖 `:65` 的返回值，标准 CityHash128 的块循环必须保留 `pair` 为滚动状态 `v`；`:201-202` 把按 `len` 分支准备的 `a/b` 丢弃后重新取 8 字节，使 `:184-198` 的 `a` 分支成为死计算。
- **描述**：函数对外提供 `cityHash(...): UInt128`，结果既非 CityHash 也不满足雪崩性质（块循环里 `x = v.right` 恒等于 `z`，状态退化为线性递推）；无法与其他语言 CityHash 对齐，跨语言一致性哈希/分片会漂移。
- **建议**：按 CityHash v1.0.2 的 `CityHash128` 重写块循环与 4 段收尾；若不打算兼容，改名（如 `fyHash`）并注释声明"非标准 CityHash"。

### [轻微] CityHash：私有符号 `mur` / `rotate32` 无调用者，`hashLen16` 有未使用局部量，`chunkSize32` 是无意义别名

- **位置**：`f_util/src/CityHash.cj:158-172`（`mur`）、`:151-154`（`rotate32`）、`:119`（`mix` 赋值后未读）、`:86`（`chunkSize32`）
- **来源**：存量（工作区快照，无 diff）
- **判据**：review-checklist §1（非 public 符号无调用者 / 局部变量赋值未读）
- **证据**：静态确定 —— 全仓 `grep -w mur`、`grep -w rotate32` 仅命中定义与 `mur` 内部；`mix` 在 `hashLen16` 内赋值后再无出现。
- **描述**：从 MurmurHash3 抄来的 `mur`/`rotate32` 是迁移残留，`mix` 是调参残留，`chunkSize32` 让读者误以为有独立语义。
- **建议**：删除 `mur`、`rotate32`、`mix`、`chunkSize32`；`c = ...fetch64(data, tailOffset + chunkSize - 32)` 直接用 `chunkSize`。

### [轻微] MurmurHash3X128：4 个未使用的 import

- **位置**：`f_util/src/MurmurHash3X128.cj:18`（`std.binary.LittleEndianOrder`）、`:20`（`stdx.encoding.hex.*`）、`:22`（`fountain::f_data.DataParsable`）、`:23`（`fountain::f_util.exception.HashException`）
- **来源**：存量（工作区快照，无 diff）
- **判据**：review-checklist §1（未使用的 import）
- **证据**：静态确定 —— 文件只用 `UInt64.readLittleEndian`（`std.core`）、`len.toUInt()`、`text.unsafeBytes()` 与 `@Frozen`/`@OverflowWrapping`；上述 4 个名字零出现。
- **建议**：删除这 4 行 import。

### [轻微] CrcGf_test：`refCrc64Normal` / `le64` 定义后从未使用

- **位置**：`f_util/src/CrcGf_test.cj:46-55`（`refCrc64Normal`）、`:65-71`（`le64`）
- **来源**：存量（工作区快照，无 diff）
- **判据**：review-checklist §1（private 符号无调用者）
- **证据**：静态确定 —— 两符号在本文件 `grep -c -w` 均为 1（仅定义），全仓无其他引用；`refCrc64Reflected`、`be64` 有使用者，说明这两份是"非反射/小端"方向的残留参考实现。
- **建议**：删除；若要保留非反射参考实现，补一条与 `Crc64.ecma182/we` 对拍的用例让它被真正使用。

### [轻微] CrcGf：`reflectConstants` 只被自己的测试引用，而该测试是"自己证明自己"

- **位置**：`f_util/src/CrcGf.cj:134-146`（`reflectConstants`）；`f_util/src/CrcGf_test.cj:297-313`（唯一调用点 `reflectConstantsAreConsistent`）
- **来源**：存量（工作区快照，无 diff）
- **判据**：review-checklist §1（仅测试使用 ⇒ 可见性/去留建议）+ §2（三套常量布局并存）
- **证据**：静态确定 —— 全仓仅 `CrcGf_test.cj:300` 调用；该用例断言全是 `c[i] == CrcGf.xPowModP(...)`，用实现自己的函数验证实现自己的常量数组，未与独立参考或机器码核对照。真正被内核消费的是 `reflectConstants64`（`crc64_native_arm.cj:225-227`）与 `reflectX86Constants`（`crc64_native_x86.cj:249-252`）。
- **描述**：仓库同时存在 3 套 CRC-64 折叠常量布局（4 字 / 8 字 / 10-16 字），8 字那套无生产消费者；多份表示容易改动时只改一处（drift 风险）。
- **建议**：删除 `reflectConstants` 与其自证用例，或让某个内核真正消费它；`CrcGf` 类注释写清"哪套布局给哪个架构用"。

### [轻微] IsUUID：缺少 `messageIfNotMatch!` 构造参数，与 `f_data` 其它 Validator 不一致

- **位置**：`f_util/src/IsUUID.cj:22`（`public const init(){}`）
- **来源**：存量（工作区快照，无 diff）
- **判据**：review-checklist §10（设计一致性 / 可维护性）
- **证据**：静态确定 —— `f_data/src/validation/Validator.cj:41/56/70/87/103/119` 的 6 个 Validator 都是 `init(messageIfNotMatch!: String = '')` 并转发 `super`；只有 `IsUUID` 无法定制失败文案。
- **建议**：改成 `public const init(messageIfNotMatch!: String = '') { super(messageIfNotMatch: messageIfNotMatch) }`。

### [轻微] IdMaker：负数 hostSerial 的异常文案与判据不符

- **位置**：`f_util/src/IdMaker.cj:29-31`
- **来源**：存量（工作区快照，无 diff）
- **判据**：review-checklist §11（语义与文案不符）
- **证据**：静态确定 —— 条件是 `hostSerial > 1023 || hostSerial < 0`，文案固定 `"host serial is too large"`，`-1` 时报"太大"。
- **建议**：文案改为 `"host serial ${hostSerial} must be between 0 and 1023"`。

### [轻微] CrcEngine：64 位反射热循环用 `CPointer<UInt64>` 直接读，隐含 8 字节对齐与小端两个前提

- **位置**：`f_util/src/CrcEngine.cj:305-308`（`let p64 = CPointer<UInt64>(dp)` / `p64.read(j)`）
- **来源**：存量（工作区快照，无 diff）
- **判据**：review-checklist §11（契约不符 / 平台假设未声明）
- **证据**：待确认 —— 注释 `:304` 只写"小端机器上一次 64 位读正好是小端 word"，无编译期/运行期端序判定，也无对齐保证；`Array<Byte>` 裸指针不保证 8 字节对齐。x86_64/aarch64 通常可用，大端或严格对齐平台结果错误或陷入异常。缺：目标平台清单与大端平台验证结果。
- **建议**：用 `UInt64.readLittleEndian(...)` 显式小端读取，或加端序分支；至少把"仅支持小端 + 允许非对齐访问"写成约束。

### [轻微] 测试用例切换全局硬件开关后不走 `try/finally`，异常路径不恢复

- **位置**：`f_util/src/CrcEngine_test.cj:351`（`setNativeEnabled(false)` 在 `try` 之外）、`:367-368`（恢复在用例末尾）；`f_util/src/crc32_codegen_test.cj:64-69`、`:149-156`
- **来源**：存量（工作区快照，无 diff）
- **判据**：review-checklist §11（资源/状态对称释放）
- **证据**：静态确定 —— `:352-363` 之间任何异常（含 `@Fail` 断言失败）都跳过 `:367` 的 `setNativeEnabled(true)`，后续依赖硬件核的用例（`:406`、`:454`、`:479`、`:553`）集体走软件路径或误判；`crc32_codegen_test` 同理，`compute` 抛异常则 `:68`/`:154` 被跳过，`:73`、`:110`、`:189` 误报。两文件都另有正确写法（`CrcEngine_test.cj:443-448`、`crc32_codegen_test.cj:207-212`），说明是遗漏。
- **描述**：一处失败会污染后续用例结果，掩盖真实问题。
- **建议**：两处都包进 `try { ... } finally { setNativeEnabled(true); resetForTest() }`。

### [轻微] FnvHasher：`public` 有状态类，未声明"非线程安全"

- **位置**：`f_util/src/Fnv.cj:182-204`（`update` 改 `core.state` / `scratchA` / `scratchB`）
- **来源**：存量（工作区快照，无 diff）
- **判据**：review-checklist §12.1（共享可变状态）+ §10（契约声明）
- **证据**：静态确定（无锁、无原子、`FnvCore.update` 直接写实例数组）；仓内仅 `Fnv_test.cj` 使用且每用例新建，共享实例使用点待确认。
- **描述**：与 `MessageDigest` 同类，惯例是"每线程/每次使用一个实例"，但类注释 `:178-181` 只描述方法语义，未写线程约束；被当单例复用时 `state` 与两张 scratch 表互相踩。
- **建议**：类注释补"实例非线程安全，需每次新建或外部串行化"；若需共享，`scratchA/scratchB` 改为方法内局部数组或 `ThreadLocal` 缓存。

### [轻微] PathPattern 死代码集合：未使用的构造重载 / 成员 / import

- **位置**：`f_util/src/PathPattern.cj:522-536`（`PathNode` 五个构造重载无调用者）、`:731`（`PathNode.data(data: Any): Unit`）；`f_util/src/TextTemplate.cj:55`（`private static let mutex`）、`:237-239`（`ValueGetter.init(indexText:)`）、`:18`（`Map`）；`f_util/src/StatePattern.cj:19`（`TypeInfos`）；`f_util/src/StrategyPattern.cj:18`（`ArrayList`）
- **来源**：存量（工作区快照，无 diff）
- **判据**：review-checklist §1（非 public 符号 / 未使用 import）
- **证据**：静态确定 —— `PathNode(` 只出现在 `:92/:96/:143` 三处零参构造与子类 `super(...)`；`PathNode.data(`/`mutex`/`indexText:`/`TypeInfos`/单独 `ArrayList` 在包内零命中（`PathNode` 是内部 `open class`，成员可见性只到包内，按硬原则二判）。`PathNode.data<T>()`（`:740`）有使用者，不要一起删。
- **描述**：五个构造重载是"预留扩展点"残留（`starNode`/`doubleStarNode`/`data` 实际由 `createXxxIfAbsent` 与 `setDataIfNone` 完成），读代码时会误以为存在另一条构造路径。
- **建议**：删除五个未用重载、`PathNode.data(Any)`、`TextTemplate.mutex`、`ValueGetter.init(indexText:)` 与三处未用 import。

### [轻微] `PathNode.!=` 与 `PathNode.==` 语义不一致，违反 `Equatable` 契约

- **位置**：`f_util/src/PathPattern.cj:761-766`（`==` 为 `refEq || name ==`，`!=` 为 `name != node.name`）；覆盖实现 `:746-760`、`:793-802`、`:809-818`
- **来源**：存量（工作区快照，无 diff）
- **判据**：review-checklist §11（语义与命名不符 / 接口契约）
- **证据**：静态确定 —— `StarPathNode.==(Any)` 对任意 `PathNode` 返回 true（`:797 o is PathNode`），`!=` 只比 `name`；"星号节点 vs 普通节点"会出现 `a == b` 与 `a != b` 同时为 true。`getComplexNode`（`:570`）与 `getRegexPlaceholderNode`（`:597`）正用 `current != node` 决定跳过候选，语义矛盾会改变候选推进顺序。
- **建议**：`!=` 改为 `!(this == node)`；`==` 的通配语义移到具名方法（如 `accepts(o)`）。

### [轻微] code_buffer：`rawPointer()` 两个分支完全相同，且与 `f_jit` 的 `CodeBuffer` 是同一实现的第二份

- **位置**：`f_util/src/code_buffer.cj:61-67`（`if (sealed) { ptr } else { ptr }`）、`:18-24`
- **来源**：存量（工作区快照，无 diff）
- **判据**：review-checklist §1（恒等分支）+ §2（跨模块复制）
- **证据**：静态确定 —— 两分支返回值逐字相同；`f_jit/src/backend/CodeBuffer.cj:68` 存在同名 `rawPointer()` 与同一套 `mmap` → `mprotect` → `__clear_cache` 流程（`f_jit` 版为 `public class`，`f_util` 版为包内 `class`）。
- **描述**：`sealed` 判断在 `rawPointer` 无作用，读者会误解；两份 W^X 可执行页实现意味着平台细节要改两处。
- **建议**：`rawPointer()` 直接 `return ptr`；把可执行页分配收敛到 `f_util`（依赖方向 `f_jit` → `f_util` 正确），或两处互相注明"改动需同步"。

### [轻微] crc32_hw_kind：手写 `==`/`!=` 与枚举默认结构相等重复

- **位置**：`f_util/src/crc32_hw_kind.cj:24-43`
- **来源**：存量（工作区快照，无 diff）
- **判据**：review-checklist §2（只改语法的重复实现）
- **证据**：静态确定 —— 三个 case 的嵌套 `match` 等价于枚举按值比较，`!=` 又写成 `!(this == other)`；同文件 `Crc32.classifyHw`（`crc32.cj:80-92`）已在做同样的三值分类。
- **描述**：唯一作用是满足 `Equatable<CrcHwKind>`，但 `::` 枚举本身已具备值相等；手写版本在新增 case 时会静默落到 `_ => false`。
- **建议**：删除两个手写运算符，或改单层 `match ((this, other))`。

### [轻微] TextTemplate：`time:` 与 `number:` 两段格式串解析逐行同构（同一条错误文案）

- **位置**：`f_util/src/TextTemplate.cj:143-186`（`:145-167` 与 `:168-186` 两段）
- **来源**：存量（工作区快照，无 diff）
- **判据**：review-checklist §2（换控制流 / 字面量复制）
- **证据**：静态确定 —— 两段都是"定位 `` ` `` → 跳过首个反引号 → 找闭合反引号 → 处理 `\`` → 校验 → trim → 切格式"，差异只有前缀常量与产出 converter；`:157` 的 number 分支直接复用 time 的错误文案。已漂移：time 分支对 `format` 做了 `.regex().replaceAll("`", "\\`")`，number 没有。
- **描述**：两段复制导致同一个转义 bug 出现两份（见"索引对象错位"）。
- **建议**：抽 `parseTaggedFormat(placeholder, tag): ?(String, String)`，两分支只保留"构造哪个 converter"的差异。

### [轻微] ValidationResponsibility：接口给了空 `execute` 默认实现，且没有一行注释说明

- **位置**：`f_util/src/ResposibilityChain.cj:40-42`
- **来源**：存量（工作区快照，无 diff）
- **判据**：review-checklist §3（接口默认空实现 / 有意 no-op 需注释）
- **证据**：静态确定 —— `func execute(arg: A): Unit {}` 为空实现；仓内零实现者，无法从调用方推断语义。
- **描述**：实现类只写 `check` 忘记 `execute` 时，`executeAll` 会"检查通过但什么也不做"——校验链静默失效；若是刻意 Null Object，按清单也必须写明原因。
- **建议**：补注释"校验责任链只用 `check` 判定，`execute` 允许空"；或去掉默认实现让实现类显式表态。

### [轻微] TreeTransformer：两个 `transform` 重载把算出的根节点列表直接丢弃

- **位置**：`f_util/src/TreeTransformer.cj:66-71`（`transform<S>(iterable, emptyId)` 与 `(..., ignoreDuplicate)` 返回 `Unit`）
- **来源**：存量（工作区快照，无 diff）
- **判据**：review-checklist §11（返回值丢弃）
- **证据**：静态确定 —— 两个重载末尾调用返回 `ArrayList<T>` 的另一个重载，表达式值未使用；父子关系已写进各节点 `children`，但根节点只能靠"再扫一遍 `parentId == emptyId`"找回。
- **描述**：三个同名重载里两个丢结果、一个返回结果，选择重载等于无声改变可用信息；这两个重载返回 `Unit`，将来改 `ArrayList<T>` 是破坏性变更。
- **建议**：统一返回 `ArrayList<T>`，或删掉这两个重载只留显式版本。

### [轻微] PathPattern：`matches()` 与 `data()` 的 `withExtName` 默认值相反，且与注释"不包含扩展名"矛盾

- **位置**：`f_util/src/PathPattern.cj:434-441`（`matches(path)` 转调 `matches(path, true)`）、`:457-468`（`data<T>(path)` 转调 `data(path, false)`）
- **来源**：存量（工作区快照，无 diff）
- **判据**：review-checklist §11（语义与注释不符 / 同族 API 口径相反）
- **证据**：静态确定 —— 两处 KDoc 都写"不包含路径中的扩展名"，但 `matches` 默认保留扩展名、`data` 默认裁掉；同一 pattern 与 path，`matches("/api/user.json")` 与 `data(...).isSome()` 可能给出相反结论。
- **描述**：`f_mvc` 的 `getHandler` 走 `data()`，`extractVariableInPath` 也裁扩展名，只有 `matches()`/`matchesPrefix()`（仓内零生产引用）保留；使用者按注释理解会得到反直觉结果。
- **建议**：统一默认值（建议都取 `false`），或参数改必填并在 KDoc 写清两种口径；删掉 `matches*` 或与 `data` 合并为返回 `Option` 的单一入口。

### [轻微] PathPattern：三个编译入口对路径规整与 `{*var}` 预处理不一致

- **位置**：`f_util/src/PathPattern.cj:101-103`（`compile(pattern)`）、`:124-127`（`compile(pattern, data)`）、`:153-156`（`compileIfAbsent` 走 `pretreat`）；`pretreat` 见 `:114-122`
- **来源**：存量（工作区快照，无 diff）
- **判据**：review-checklist §14.1（同能力两入口行为不一致）+ §10（可维护性）
- **证据**：静态确定 —— 只有 `compileIfAbsent` 调 `pretreat`（合并 `///`、把 `/{*name}` 改写为 `/**/{name}`）；另两个入口直接用原始串 `parts(pattern, true)`。查询侧 `get`（`:478`）对请求路径无条件 `trimRedundantSlash`，注册侧不规整 ⇒ 用 `compile` 注册 `"//a"` 永远匹配不到。
- **描述**：类注释把 `{*...}`、连续 `/` 合并列为正式语法特性，但只有生产不使用的入口实现它；`f_mvc` 只用 `compileIfAbsent`，线上暂时只暴露"注册侧不规整"的风险。
- **建议**：`pretreat` + `trimRedundantSlash` 移到 `doCompile` 入口统一做一次，三个公开入口共享同一套规整逻辑。

### [轻微] crc64_native_arm 的 `ensureReady` 只看反射核，正常域核存在时仍回退表路径

- **位置**：`f_util/src/crc64_native_arm.cj:214-232`（`:216-217` 与 `:228` 只判 `fn.isSome()`）
- **来源**：存量（工作区快照，无 diff）
- **判据**：review-checklist §2（近似重复导致行为漂移）+ §11（错误处理不对称）
- **证据**：静态确定 —— `available()`（`:96-102`）用 `fn.isSome() || fnNorm.isSome()`，`updateNormal()`（`:144-151`）依赖 `ensureReady()`；当 `REF_CODE` 的 `write`/`seal` 失败而 `NORM_CODE` 成功时（`make`/`makeNormal` 独立失败，`failAlloc` 只覆盖"同时失败"），`available()` 为 true、`ensureReady()` 为 false ⇒ `ecma182/we` 静默走表路径。x86 版 `:238-257` 已正确返回两者之或。
- **描述**：aarch64 上非反射 256B+ 数据可能无声掉到表路径，只体现为吞吐下降，无日志区分。
- **建议**：`ensureReady()` 末尾改为 `fn.isSome() || fnNorm.isSome()`；`updateNormal` 单独判断 `fnNorm`，使两个核可用性互不牵连。

### [轻微] Crc64Hw.update/updateNormal 不校验 `aligned % 16`，违反 KDoc 前置条件时静默产出错值

- **位置**：`f_util/src/crc64_native_arm.cj:108-111`、`:144-148`；`f_util/src/crc64_native_x86.cj:148-152`、`:164-168`
- **来源**：存量（工作区快照，无 diff）
- **判据**：review-checklist §11（缺少边界校验 → 静默错误值）
- **证据**：静态确定 —— KDoc（`arm:105`、`x86:109`）要求 `aligned` 为 16 的倍数且 >= 16，代码只判 `aligned < 16 || aligned > data.size`。折叠核按 16 字节循环推进，`aligned = 20` 时只消费前 16 字节却把结果当作覆盖 `data[0..20]`，调用方据此跳过软件补齐 ⇒ CRC 错。当前唯一调用点 `CrcEngine.cj:206/:219` 传 `data.size - data.size % 16`，暂时安全；但 `CrcEngine_test.cj:536` 直接调用过。
- **描述**：包内 API 也会被绕过使用，前置条件无运行时断言，错用后只表现为哈希值不对。
- **建议**：加 `if (aligned % 16 != 0) { return None }`（或 debug 断言 + `None`），违约回退表路径。

### [轻微] 死代码：`Crc32Hw.available()`（3 份）与 `Crc64Hw.modeNameForTest()`（3 份）全项目零引用

- **位置**：`f_util/src/crc32_native_arm.cj:68-74`、`crc32_native_stub.cj:25-27`、`crc32_native_x86.cj:86-92`；`f_util/src/crc64_native_arm.cj:184-190`、`crc64_native_stub.cj:54-56`、`crc64_native_x86.cj:207-213`
- **来源**：存量（工作区快照，无 diff）
- **判据**：review-checklist §1（非 public 顶级声明里的成员，全项目无使用即死代码）
- **证据**：静态确定 —— `Crc32Hw`/`Crc64Hw` 均为包内 `class`（无 `public`），成员按硬原则二判。全仓 `available()` 只命中 `Crc64Hw.available()` 的 5 处测试调用；`Crc32Hw.available` 仅 3 处定义、0 调用；`modeNameForTest` 仅 3 处定义、0 调用（三态用例 `CrcEngine_test.cj:477-524` 断言的是 `lastUsedNativeForTest()`）。`CrcHwMode.On` 只在 `modeNameForTest` 里被读，删除后变成只写。
- **描述**：`available()` 是"写过但没用上"的诊断入口（测试用 `availableFor()`）；`modeNameForTest` 是三轮用例改造后的残留，都会误导读者。
- **建议**：删除 CRC-32 的三份 `available()` 与三份 `modeNameForTest()`；若确需整体可用性诊断，让 `Crc32Hw.available()` 在 `availableFor` 之上被真正使用一次。

### [轻微] crc64.cj 有一处悬空 KDoc（NVME 变体说明），不挂在任何声明上

- **位置**：`f_util/src/crc64.cj:48`（`/** 未收录（参数待核对，宁缺勿错）：CRC-64/NVME ... */`，紧跟 `:49` 的另一段 KDoc 修饰 `:50` 的 `all`）
- **来源**：存量（工作区快照，无 diff）
- **判据**：review-checklist §1（文档残留）+ §10 可维护性
- **证据**：静态确定 —— 连续两段 `/** */` 时后一段覆盖前一段作为 `all` 的文档，`:48` 不会出现在任何生成的 API 文档里。
- **描述**：注释本身有价值（说明为何缺 NVME 变体），但位置使其失效。
- **建议**：并入类级 KDoc（`:20-32`）或 `:49` 的文档块，作为"未收录变体"小节。

### [轻微] 测试钩子改静态状态无同步；`resetForTest` 与正在执行的 `CFunc` 之间有 use-after-munmap 窗口

- **位置**：`f_util/src/crc32_native_arm.cj:38`（`:89`/`:117` 锁外读、`:116-118` 无锁写）、`:120-127`；`crc32_native_x86.cj:36`/`:150-157`；`crc64_native_arm.cj:36-42`、`:139`、`:197-212`；`crc64_native_x86.cj:39-45`、`:193`、`:197-236`
- **来源**：存量（工作区快照，无 diff）
- **判据**：review-checklist §12.1（共享可变状态无保护；跨线程资源）
- **证据**：静态确定 —— ① 测试线程无锁写 `nativeEnabled`/`forcedOff`，计算线程在 `update()` 入口无锁读；② 计算线程 A 在 `call()` 里已解构 `?CFunc` 进入机器码，测试线程 B 的 `resetForTest()` 在锁内 `codes.clear()` 释放 `CodeBuffer`（`mmap` 页），A 继续执行已 `munmap` 的页 ⇒ 段错误。触发面仅限测试代码，生产路径只读不写，故定轻微。
- **描述**：`lastNative` 同样"每次 update 无锁写、测试读"，并发下三态断言可能读到别线程的值。
- **建议**：开关字段改 `AtomicBool` 或统一在 `lock` 内读写；`resetForTest` 只清指针字段、代码页延迟释放，并在 KDoc 写明"仅限单线程测试使用"。

### [轻微] 5 个异常类逐行同构，只有类名不同

- **位置**：`f_util/src/exception/GeoHashException.cj:20-32`、`HashException.cj:20-32`、`IdException.cj:20-32`、`TextTemplateException.cj:20-32`、`UUIDException.cj:20-32`
- **来源**：存量（工作区快照，无 diff）
- **判据**：review-checklist §2（只改类型名的重复实现）
- **证据**：静态确定 —— 5 个文件除类名外逐字符相同（4 个 `init` 全部转发 `super`）；5 个类都在使用（`geohash.cj:126`、`UInt128.cj:61`、`IdMaker.cj:30`、`TextTemplate.cj:109/249/305/334`、`uuid.cj:180`）。
- **描述**："按类型 catch"是正当设计，不能合并成一个类（会丢 `catch (e: IdException)` 的区分能力），但每个类 4 个构造器的样板可收敛。
- **建议**：加 `abstract class FUtilException <: BaseException`（含 4 个构造器），5 个具体类继承并只保留必要构造器；样板从 5×13 行降到 5×5 + 1×13 行。

### [轻微] qpow / millerRabin 作为 public API 没有返回类型声明，也没有参数前置条件

- **位置**：`f_util/src/prime.cj:25`（`public func qpow(a: UInt64, b: UInt64, m: UInt64) {`）、`:39`（`public func millerRabin(x: UInt64, p: UInt64) {`）
- **来源**：存量（工作区快照，无 diff）
- **判据**：review-checklist §10（可读性 / API 契约）+ §14.2（README 公开 API 覆盖）
- **证据**：静态确定 —— 两处靠 `return ans` / `return true|false` 推导返回类型，签名对调用方不可见；README 只在 `:725` 的公开符号清单列出名字，无签名、无 `m > 1`/`x < p`/`x % p != 0` 约束。另 `millerRabin(x, p)` 当 `x % p == 0`（如 `x == p`）时对素数也返回 `false`，前提同样没写。
- **描述**：三个"零引用、零测试"公开函数中的两个（`isPrime` 也零引用），下游只能靠读实现猜语义。
- **建议**：补显式返回类型（`: UInt64` / `: Bool`）与参数约束 KDoc；`millerRabin` 把 `x % p == 0` 归为合数或声明"要求 `1 < x < p`"；README 补签名。

### [轻微] GeoHash.encode 不校验经纬度范围，越界/NaN 静默产出 hash

- **位置**：`f_util/src/geohash.cj:31-59`（无 `MIN/MAX_LATITUDE/LONGITUDE` 校验，`:24-27` 的常量只在二分里用）
- **来源**：存量（工作区快照，无 diff）
- **判据**：review-checklist §11（缺少边界校验）
- **证据**：静态确定 —— `encode(200.0, 100.0)` 不抛异常，二分对"点永远在区间外"不收敛；`Float64.NaN` 与任何值比较都是 `false`，两个判断都走 else，返回固定 hash 而不报错。
- **描述**：`GeoHash` 是 `Parsable`/`DataParsable`，经纬度常来自外部（GPS、JSON、DB），越界值应拒绝而非给一个看似正常的 hash。
- **建议**：入口加 `if (!(latitude >= -90.0 && latitude <= 90.0) || !(longitude >= -180.0 && longitude <= 180.0)) throw ...`（NaN 会被自然拒绝）；`encode(coordinate:)` 复用同一校验。

### [轻微] README 的 `encode(latitude, longitude)` 与实现的 `(longitude, latitude)` 顺序相反

- **位置**：实现 `f_util/src/geohash.cj:31`（`encode(longitude: Float64, latitude: Float64)`）；文档 `f_util/README.md:304`、`:306`
- **来源**：存量（工作区快照，无 diff）
- **判据**：review-checklist §13（文档与代码不一致）+ §11（语义与命名不符）
- **证据**：静态确定 —— 命名实参按名字绑定，`encode(latitude: 39.9, longitude: 116.4)` 恰好正确；但按 README 的位置调用 `encode(39.9, 116.4)` 会把纬度当经度。源码 `:60-62` 的 KDoc 写 `(longitude, latitude) = (coordinate[0], coordinate[1])`，与 README `:306` 相反。
- **描述**：同一契约两处给相反顺序，`encode(coordinate:)` 的元组顺序因此没有唯一答案；下游按 README 写调用会静默交换经纬度。
- **建议**：README 与 `README_en.md:306` 改为 `(longitude, latitude)`，`encode(coordinate:)` 明确"`coordinate[0]` 是经度"；KDoc 给具体例子（`encode(116.4, 39.9) // 北京`）。

### [轻微] `etherName` 末尾的 `throw UnreachableException()` 不可达

- **位置**：`f_util/src/uuid.cj:511`
- **来源**：存量（工作区快照，无 diff）
- **判据**：review-checklist §1（不可达语句）
- **证据**：静态确定 —— `try (f = File(...))` 的资源获取失败与块内 `readToEnd` 失败都会在 `try` 语句处抛出，块内成功路径 `return ether(...)` 直接返回，`try` 之后的同层语句永远执行不到。
- **建议**：删除该行；错误路径按"etherName 异常族"条目改成显式异常。

### [轻微] v2 的时间信息读取未实现，且两个属性行为不一致

- **位置**：`f_util/src/uuid.cj:119-170`（`case _ => 0`）、`:174-183`（无 `case 2`）
- **来源**：存量（工作区快照，无 diff）
- **判据**：review-checklist §11（静默错误值）+ §13（README `:545` 写"兼容 UUID version 1 2 6"）
- **证据**：静态确定 —— `UID()`（`:489-493`）可把 builder 置为 version 2 并生成 v2；对 v2，`timestampNanos` 走 `case _` 静默返回 `0 * 100 = 0`，`timestamp` 抛 `UUIDException`，同一份数据一个"有值（假）"一个抛异常。
- **建议**：v2 的 time_low 仍可解出 32 bit 秒级时间，可单列分支；无法还原时让 `timestampNanos` 也抛同一异常，并在 README 注明 v2 时间戳不可还原。

### [轻微] README 把 `TimestampSequenceBuilder` 的注册方法写成返回 `This`，代码返回 `Unit`

- **位置**：文档 `f_util/README.md:623-627`（`:625`、`:627`）vs 代码 `f_util/src/uuid.cj:650`、`:689`
- **来源**：存量（工作区快照，无 diff）
- **判据**：review-checklist §13（API 与文档不符）
- **证据**：静态确定 —— `TimeBasedUUIDBuilder` 的同名包装确实返回 `This`（`:469-476`），README 把外层与内层签名抄成了同一份；内层两个方法无返回值。
- **建议**：README 改成 `: Unit`，或让内层返回 `This` 与 README 对齐（后者更一致但改动公开签名）。

### [轻微] 未使用的 import

- **位置**：`f_util/src/wyhash.cj:18`（`import fountain::f_base.*`）、`f_util/src/uuid.cj:24`（`import stdx.crypto.crypto.*`）
- **来源**：存量（工作区快照，无 diff）
- **判据**：review-checklist §1（未使用的 import）
- **证据**：静态确定 / 待确认 —— `wyhash.cj` 全文只用本文件的 `SECRET*`、`wyrand`、`wyhash`、`mix`、`r4`、`r8`，无 `f_base` 符号；`uuid.cj` 摘要只用 `stdx.crypto.digest.{MD5, SHA1}` 与其 `write/finish`，未见 `stdx.crypto.crypto` 符号（若 `finish()` 依赖该包接口扩展则需保留），标待确认。
- **建议**：删除 `wyhash.cj:18`；`uuid.cj:24` 先试删再编译验证（本报告不跑构建）。

### [轻微] 重复逻辑：版本/变体位设置 5 处、hex nibble 解析 2 处（且已漂移）

- **位置**：版本/变体 5 处 —— `f_util/src/uuid.cj:321-324`（md5）、`:332-335`（random）、`:367/371`（sha1）、`:399/403`（v7）、`:435/437`（custom）；hex 解析 2 处 —— `:196-221`（`tryParse.doParse`，只认小写）、`:518-541`（`ether.parse`，大小写都认）
- **来源**：存量（工作区快照，无 diff）
- **判据**：review-checklist §2（字面量复制 / 只改类型名）
- **证据**：静态确定 —— 5 处都是 `byte6 = (x & 0xf) | (ver << 4); byte8 = (x & 0x3f) | (2 << 6)`，仅 version 常量不同；两处 nibble 解析语义相同、`case` 集合不同，已造成大小写行为漂移。
- **建议**：抽 `withVersionVariant(values, version)` 与 `hexNibble(c: Rune): ?Byte`，把"是否接受大写""遇到 `'-'` 的行为"作为显式参数，避免第三份实现再漂移。

### [轻微] 可见性不一致（可见性建议，不算死代码）

- **位置**：`f_util/src/uuid.cj:609`（`public func timeHighFirst`）与 `:586`（`private func timeLowFirst`）
- **来源**：存量（工作区快照，无 diff）
- **判据**：review-checklist §10（设计合理性）；按硬原则一，`public` 且对外可达故不判死代码
- **证据**：静态确定 —— `TimeBasedUUIDBuilder` 是 `public class`，`timeHighFirst` 对外可达；它与 `timeLowFirst` 是同一层字节编码细节，后者为 `private`，仓内零调用（`grep timeHighFirst` 只命中定义与 README `:616`）。
- **建议**：统一收窄为 `private`（或包内），除非确有外部子类需要；保留则补用途注释。

### [轻微] 测试只覆盖 v4 往返，本模块 3 个 UUID 严重缺陷都落在无覆盖路径上

- **位置**：`f_util/src/uuid_test.cj:21-32`（唯一用例）
- **来源**：存量（工作区快照，无 diff）
- **判据**：review-checklist §14（覆盖不足）
- **证据**：静态确定 —— 用例只断言 `UUID.random()` 的 `version == 4` / `variant == 2` 与 `parse(toString())` 相等；`timeBased`/`unixTimeBased`/`md5`/`sha1`/`tryParse` 的失败路径零用例。时间戳溢出、v7 位偏移、`serialSeq` 同 ts 不递增均未被拦住。
- **建议**：补四组用例——v1/v6/v7 时间戳与 `DateTime.now()` 误差、固定 node 同 ts 并发唯一性、`sha1` 与已知向量（如 Python `uuid5`）对齐、`tryParse` 非法串（缺分隔符、尾部多余、大写、非 RFC variant）。

## 优化可行性方案

> 不是缺陷，是"还能更好"。以下 10 条均**无改前基线**，按规则标 `无基线（待验证，不进 tasks）`，不计入模块统计的缺陷数。

### [堆内存] CrcEngine 每个变体同时生成正向与反射两张 256 项表，实际只消费一张

- **现状**：构造函数（`CrcEngine.cj:82-111`）无条件生成 `normalTable` 与 `reflectedTable`（各 2 KiB）；32 位反射变体再加 `slice1..3`，64 位变体加 `slices64[1..7]`。按 `crc32.cj` 12 个、`crc64.cj` 6 个、`crc16.cj` 24 个变体估算，类初始化后常驻约 200 KiB，其中约一半是永不索引的方向表。
- **方案**：按 `refin` 只生成需要的那张（另一张置 `[]`），`slicing16`/`slicing64` 派生基数同步改为 `if (refin) reflected else normal`；`update` 两个兜底分支已只看一张表，无需改语义。
- **预期**：常驻表内存约减半（≈100 KiB），首次触达 `Crc32`/`Crc64`/`Crc16` 的类初始化时间约减半。
- **代价**：无行为变化；需确认没有测试/调试直接读两张表（均为 `private`）。
- **验证**：`cjpm build -O2` 后 `MonoTime` 分段统计首次访问耗时与进程 RSS；`crc_check_test.cj` 全绿作为等价性门槛。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [堆内存] TextTemplate 静态缓存加容量上限与淘汰

- **现状**：`templates` 保存 `key(模板原文) → TextTemplate(compiled: ArrayList<Value2String>)`，一条缓存项≈2×模板长度 + 切段对象（每段一个 `OriginValue2String` + 一个 `ValueGetter`），生命周期 = 进程生命周期；条目数与"出现过的不同模板串"同阶。
- **方案**：改为有界 LRU（如 4096 条 / 8 MiB 估算上限），超限淘汰最久未用；或对超长模板（>4 KiB）不缓存。
- **预期**：把"只增不减"变成有界稳态（`getAllocatedHeapSize()` 长跑后回落）；定性收益，无量化数据。
- **代价**：淘汰后重复编译（一次模板解析 + 若干正则/Escape 处理），需在命中率上取平衡；`f_log` 热路径会更多走"未命中→编译"。
- **验证**：`cjpm test -O2` 跑全部用例；30 分钟稳态日志压测，采 `getAllocatedHeapSize()` 与 `templates.size`。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [堆内存] UUID 内联 16 字节，去掉每实例的 `Array<Byte>` 与构造期 `HashBuilder`

- **现状**：每个 `UUID` 持有一个 `Array<Byte>`（16 字节载荷 + 数组头，量级 32–48 B），构造时 `HashBuilder().append<Byte, Array<Byte>>(values).build()`（`uuid.cj:38-40`）再产生一个 `HashBuilder`；`UUID.random()` 还先分配 16 字节随机数组（`:331`）。每生成一个 UUID 至少 3 个堆对象。
- **方案**：`struct UUID { let hi: UInt64; let lo: UInt64 }`，`hashCode` 直接对两个 word 做一次 `mix`；`values` 改为按需构造的视图（`toString`/`toData`/`timestampNanos` 按 word 取字节）。
- **预期**：每次创建少 2 个堆对象（约 60–80 B），`fdbm` 取号、`f_egraph` 事件默认 `session` 等高频路径分配量与 GC 次数下降；比例未测。
- **代价**：`values` 语义变化，`tryParse`/`custom`/`sha1` 等按数组构造的分支要改；字段是 `private`，外部影响小。
- **验证**：1e6 次 `UUID.random()` + `toString()` 改前/改后对照 `getAllocatedHeapSize()`、GC 次数、RSS，`-O2`，中位数。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] Fnv 一次性入口每次调用都构造完整引擎（4 个数组 + 结果数组）

- **现状**：`Fnv.hash`（`Fnv.cj:53-57`）→ `FnvCore.of`（`:303-311`）每次都新建 `basis`/`state`/`scratchA`/`scratchB` 四个数组，再 `words()` 分配第 5 个；`Fnv32/Fnv64` 只用第一个字。`Fnv64.fnv1a` 是 `f_jit` 常量指纹路径（`:96`），调用量大且输入短。
- **方案**：为 `W32/W64` 增加无 `FnvCore` 的快路径（`var h = basis; for (b in data) { h = (h ^ b) * prime32/64 }`，`UInt64` 乘法天然截断）；其余宽度保留现实现。
- **预期**：W32/W64 单次哈希从 5 次堆分配降到 0～1 次；短输入（< 64 B）耗时主要来自分配，降幅需实测。
- **代价**：多一条实现分支，需与现实现逐位等价（`Fnv_test.cj` 黄金值可复用）。
- **验证**：`cjpm bench -O2` 对 8/32/256 B 各 1e6 次，中位数与 P95 对照；同时看每轮分配量。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] MurmurHash3X128：每个 16 字节块产生 3 次切片复制

- **现状**：`MurmurHash3X128.cj:40-43` 每块先 `data[offset..offset+16]` 复制 16 B，再 `blockSlice[0..8]`、`[8..16]` 各复制 8 B，然后 `readLittleEndian`。1 MiB 输入 = 65536 块 × 3 次复制 ≈ 2 MiB 额外拷贝 + 131072 次小数组分配。
- **方案**：直接对 `data` 使用带偏移的小端读取（std 有 offset 重载则直接用，否则手写 8 次下标拼装或 `unsafe` 裸指针读）。
- **预期**：块循环分配从 3/块降到 0/块，GC 压力与耗时同步下降（比例待测）。
- **代价**：引入 `unsafe` 或手写字节拼装，需与现实现逐位对照；`f_codec` 序列化依赖该哈希，必须先补"新旧同值"用例。
- **验证**：`cjpm bench -O2`，1 MiB / 64 KiB / 16 B 三档对照中位数与分配量。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] FnvCore.mulPrime：每字节两趟全 limb 扫描（W256/W1024 才有意义）

- **现状**：`Fnv.cj:344-354` 每字节调用一次 `mulPrime`，内部两次 `shiftBytesInto`（各遍历 `limbCount`，W1024 时 32 个）再遍历一次做加法 ⇒ 约 3 × limbCount 次操作/字节。
- **方案**：把 `(state << k) + (state << 8) + state * c` 合成单趟（按 `limbShift`/`bitShift` 从高到低一次算完，同时累加 `prod` 与两个移位项）。
- **预期**：W1024 每字节 limb 访问次数约降 2/3；纯常数优化，不影响结果。
- **代价**：进位逻辑合并后更难读，需现有黄金值用例兜底（`Fnv_test.cj` 已覆盖 1024 位长输入）。
- **验证**：`cjpm bench -O2`，W1024 × 5 KiB 与 1 MiB 两档对照中位数。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] f_log 每行日志都对模板串做一次 cacheKey 拼接 + 一次 HashMap 查找

- **现状**：`f_log/src/base/Logger.cj:51/72/95/114/133/152` 每次带参日志都调 `TextTemplate.compile(message, prefix:"{", suffix:"}")`；`compile`（`TextTemplate.cj:69-70`）先 `cacheKey` 做 4 次字符串拼接 + 2 次 `Int64.toString`（`:81`），再按整串 key 哈希比较。输入规模 = 每日日志行数。
- **方案**：① `f_log` 侧先用 `message.contains("{")` 短路；② `cacheKey` 在 `prefix/suffix` 为默认值时退化为直接以 `template` 为 key（另一个 map 或加前缀标记）；③ 仍偏贵则把"模板 → TextTemplate"挂到调用点静态变量（宏/`lazy`）。
- **预期**：每行日志减少 2 次小串分配 + 1 次整串哈希（占比未测）。
- **代价**：`f_log` 与 `f_util` 各改一处；②需保证两种 key 不碰撞（现用长度前缀，改造要保留）。
- **验证**：`cjpm bench -O2` 同模板 1e6 次 `compile+format`，对照中位数与分配量；10 万行/秒压测看 CPU 占比。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] PathPattern 每请求两次 `trimRedundantSlash` + 一次 `split` + 多次子串分配

- **现状**：`data(path)`（`:466`）→ `get`（`:477-479`）先 `trimRedundantSlash`（内部 `replace("//","/")` 再判首尾），再 `parts()` → `trimExt` + `split("/")`，随后逐段在若干 `HashMap` 与线性集合查找（`:553-640`，`getComplexNode`/`getRegexNode`/`getPlaceholderNode` 都是 O(候选数) 顺序扫描）。每请求至少 3 个新字符串 + 1 个 `Array<String>`。
- **方案**：请求侧改为按 `/` 单趟扫描 + 记录区间下标，在 `get` 内直接对原串切片比较，不再物化 `Array<String>`；对同一 `len` 把候选预编译成有序列表，避免每段遍历 `HashMap.values()`。
- **预期**：每请求分配从 O(段数) 个串降到 1 个；匹配耗时常数更小（未测）。
- **代价**：`parts` 被 `extractVariablesInPath`、`compile` 复用，改造要保留"按下标取变量值"；需 33 个 `PathPattern_test` 用例全绿做等价性门槛。
- **验证**：`cjpm bench -O2`，注册 200 条路由、请求 10 万次（命中/未命中各半），对照 P50/P99 与分配量。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] 每次 `update` 都要进一次全局 `Mutex`，可改为就绪后的无锁快路径

- **现状**：`Crc32Hw.update`（`crc32_native_arm.cj:92` / `crc32_native_x86.cj:116`）与 `Crc64Hw.update/updateNormal`（`crc64_native_arm.cj:113/:149`、`crc64_native_x86.cj:153/:169`）调用开头都走 `ensureReady()` → `synchronized(lock)`；初始化完成后临界区只有一次 `ready` 读 + 两个 `isSome()`。调用方 `CrcEngine.cj:205/:218` 只在 `data.size >= 256` 时启用硬件并整段传入，数据越大锁成本越低，但 256B~4KiB 帧调用频次高。
- **方案**：`ready` 改 `AtomicBool`，入口 `if (ready.load()) { 直接取缓存 CFunc } else { ensureReady() }`；`ready=true` 的发布与 `fn`/`constsXx` 写入用同一次 release/acquire（或先写完再原子置真）。`lock` 只保护首次初始化。
- **预期**：每次 update 省一次互斥进入/退出（数量级 10 ns，未测）；并发下消除单个全局互斥点。
- **代价**：需正确实现发布语义；`resetForTest` 必须先置假再清指针。改动面 4 个文件，建议与"脚手架合并"一起做。
- **验证**：`cjpm bench -O2`，256B/4KiB/1MiB 三档 + 1/8 线程，对照 P50/P99；采 BLOCKED 次数确认竞争消失。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] `UUID.toString` 用 256 项字节→2 字符表，或一次性写 36 字节缓冲

- **现状**：`uuid.cj:88-101` 每次 16 次循环、32 次 `builder.append(Rune)` + 4 次 `append('-')`；`StringGenerator` 内部是 `ArrayList<Byte>`（`f_base/src/StringGenerator.cj:23`），从 0 容量增长，36 字节要多次扩容复制，末尾再 `String.fromUtf8Unchecked` 拷一次。
- **方案**：静态 `Array<String>(256)`（每项 2 个 hex 字符），`toString` 变成 16 次 `append(String)` + 4 次连字符；或直接写 `Array<UInt8>(36)` 后一次转 `String`。
- **预期**：单次 `toString` 的 append 次数从 36 降到 20（或 37 次数组写 + 1 次转换），UUID→String 主导路径受益；比例未测。
- **代价**：静态表常驻约 4–8 KB；`StringGenerator` 是否复用实例需确认（当前每次 `new`）。
- **验证**：`cjpm bench -O2`，1e6 次 `UUID.random().toString()`，报中位数与离散度，同机同 SDK 对照。
- **证据状态**：`无基线（待验证，不进 tasks）`

## 待验证假设

> 无性能测试数据支撑的猜测，**不进 `todo.md` / `tasks.md`**；不计入模块统计。

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `Fnv.hash` 的 5 次分配是 `f_jit` 常量指纹路径的主要开销 | `f_util/src/Fnv.cj:53-57` | 该路径调用次数与分配占比 | 对 `f_jit` 编译期跑 `cjprof record`，看 `FnvCore.of`/`Array` 分配自耗时与样本数 |
| 2 | `CrcEngine` 类初始化（建表）在首个 CRC 请求上产生可感知延迟 | `f_util/src/CrcEngine.cj:82-168` | 首次触达耗时 | 冷启动脚本 `MonoTime` 包住首次 `Crc32.isoHdlc.compute`，重复 30 次取中位数 |
| 3 | 32/64 位切片的裸指针路径在 `-O2` 下仍优于下标路径 | `f_util/src/CrcEngine.cj:235-237`（注释称 `-O0` 下 51~58 MB/s） | `-O2` 对照数据 | 同机 `cjpm bench -O2` 分别跑裸指针版与下标版，1 MiB，中位数与离散度 |
| 4 | `CaseFormat.convert` 每次新建目标对象在 ORM 宏展开期可忽略 | `f_util/src/CaseFormat.cj:50` | 宏展开期调用次数 | 统计 `f_orm` 宏编译 100 字段实体的 `convert` 调用次数与总耗时 |
| 5 | `IsUUID` 的 `UUID.tryParse` 逐字符 `match` 是请求校验路径热点 | `f_util/src/uuid.cj:192-250`（`IsUUID` 透传） | 单次耗时与 QPS 占比 | 校验接口 10 万次压测，`cjprof` 看 `tryParse` 自耗时占比 |
| 6 | `data()` 的路由匹配是 HTTP 请求主路径上的可观开销（段数 5~8、路由 200+） | `f_util/src/PathPattern.cj:242-432` | 自耗时占比 | 对 f_mvc 压测接口 `cjprof record`，看 `PathPattern.get*` 的 self time 与样本数 |
| 7 | 日志路径上 `cacheKey` 的字符串拼接 + 哈希占 `append` 的可观比例 | `f_util/src/TextTemplate.cj:80-82` | 每行日志分配字节与 CPU 占比 | 10 万行/秒压测 + `cjprof`，对照"含 `{` / 不含 `{`"两种消息 |
| 8 | `TextTemplate.templates` 在真实负载下条目数持续增长（而非收敛） | `f_util/src/TextTemplate.cj:54` | 条目数随时间曲线 | 加 `templates.size` 埋点，跑 30 分钟稳态业务流量 |
| 9 | `UInt128.toString()`（`toBytes` 每次分配 16 B + `toHexString`）在类型注册表键计算里是热点 | `f_util/src/UInt128.cj:29-31`、`f_codec/src/default/DefaultCodec.cj:46` | 调用次数与占比 | 对 f_codec 编解码基准 `cjprof`，统计 `UInt128.toBytes` 样本占比 |
| 10 | 高并发下每次 update 的全局 `Mutex` 成为串行点（尤其 256B 小帧） | `crc32_native_arm.cj:129-144`、`crc64_native_x86.cj:238-257` | 锁等待时长、BLOCKED 线程数、吞吐曲线 | 1/2/4/8 线程 × 10⁶ 次 256B update，采线程状态 + `cjprof`，与无锁快路径版对照 |
| 11 | `CrcEngine` 的 256B 阈值使 16~255B 帧校验全走表路径，是 `f_protocol`/`f_store` 热点 | `CrcEngine.cj:205/:218`（范围外线索） | 真实帧长分布与各长度段调用占比 | 在 `f_protocol` 帧校验处埋点统计帧长直方图，再对短帧单测表路径吞吐 |
| 12 | `cpuFlags()`/`hasPclmul()` 首次调用整读 `/proc/cpuinfo`（数十 KB）造成首请求抖动 | `crc32_native_x86.cj:201-212`、`crc32_native_arm.cj:175-186`、`crc64_native_x86.cj:309-321` | 首次 `availableFor()` 耗时 | 分段计时 100 次冷启动进程的首调用 |
| 13 | `GeoHash.toString()` 每次 32 次 `append<UInt64>`，每次分配一个 String | `f_util/src/geohash.cj:100-103` | 单次调用分配字节 | `cjprof` + `getAllocatedHeapSize()` 跑 10⁶ 次；对照直接写 32 个 ASCII 字节 |
| 14 | `wyhash` 用带边界检查的 `Array<UInt8>` 下标，比 runtime 的 `arrayGetUnchecked(RawArray)` 慢 | `f_util/src/wyhash.cj:130-138` | 与 std 版同输入的自耗时差 | `cjpm bench -O2`，1 KiB / 64 KiB 各 1e6 次，与 std `wyhash` 同机对照 |
| 15 | `UUID.random()` + `toString()` 是高频分配点（每次 3+ 个堆对象） | `f_util/src/uuid.cj:330-337`、`88-101` | 分配量与 GC 占比 | `cjprof heap`，跑 1e6 次 random+toString，看分配热点排名 |
| 16 | `timestampAndSequence` 的 `Mutex` 在 `fdbm` 取号路径上是串行段（含 `DateTime.now()` 与序列生成） | `f_util/src/uuid.cj:710-721` | 持锁时长、线程等待占比 | 8 线程 × 10k 次取号，分段计时 + 线程状态采样（BLOCKED/WAITING 占比） |
| 17 | `toString` 的 `ArrayList<Byte>` 扩容与 36 次 `add` 在 UUID→String 主导场景占比可观 | `f_util/src/uuid.cj:88-101` | 扩容次数与单次耗时分解 | 微基准对比"预分配 36 字节 + 一次转换"版，`-O2`，中位数 |

## 文件覆盖

> 与 `{workdir}/files/f_util.txt` 一一对应（48 个 `.cj`）。`.md`（README / README_en / `doc/**`）不在本模块清单内，仅作契约取证引用。

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_util/src/CaseFormat.cj` | .cj | ✅ | 默认可见性（轻微）；5 子类 `convert` 模板化，不判重复 |
| 2 | `f_util/src/CaseFormat_test.cj` | .cj | ✅ | 6×5 转换矩阵覆盖完整；缺"连续大写/数字边界"用例 |
| 3 | `f_util/src/CityHash.cj` | .cj | ✅ | 严重×2（短串越界、尾部循环）、轻微×3（非标准算法、死符号、可见性无关）；无测试 |
| 4 | `f_util/src/CrcEngine.cj` | .cj | ✅ | 轻微（裸指针对齐/端序）；优化方案 1/10 |
| 5 | `f_util/src/CrcEngine_test.cj` | .cj | ✅ | 轻微（开关未 try/finally）；对拍设计良好 |
| 6 | `f_util/src/CrcGf.cj` | .cj | ✅ | 轻微（`reflectConstants` 仅自证测试） |
| 7 | `f_util/src/CrcGf_test.cj` | .cj | ✅ | 轻微（`refCrc64Normal`/`le64` 死代码） |
| 8 | `f_util/src/DiffieHellmanKeyExchanger.cj` | .cj | ✅ | 严重×2（模幂、非素数参数）、一般×1（`ab_` 并发）、轻微×1（可见性）；无测试 |
| 9 | `f_util/src/Factory.cj` | .cj | ✅ | 一般×2（静默覆盖/缺键异常、注册表并发）；`Producer` 默认抛异常已在 README 说明 |
| 10 | `f_util/src/Fnv.cj` | .cj | ✅ | 算法与官方基值逐项一致；轻微（`FnvHasher` 线程声明）；优化 4/6 |
| 11 | `f_util/src/Fnv_test.cj` | .cj | ✅ | 黄金值覆盖 5 宽度 × 2 变体 × 空/短/emoji/长输入 |
| 12 | `f_util/src/IdMaker.cj` | .cj | ✅ | 一般×1（同 ms 重复）、轻微×1（文案） |
| 13 | `f_util/src/IsUUID.cj` | .cj | ✅ | 一般×1（大写 UUID 被拒，并入 tryParse 条目）、轻微×1（缺 message 参数） |
| 14 | `f_util/src/Mediator.cj` | .cj | ✅ | 一般×2（与 Factory 合并）；泛型 `C` 未被成员使用，属 API 噪声 |
| 15 | `f_util/src/MurmurHash3X128.cj` | .cj | ✅ | 严重×1（尾部双异或）、轻微×1（4 个未用 import）；优化 5 |
| 16 | `f_util/src/PathPattern.cj` | .cj | ✅ | 严重×2（回溯死循环、读路径竞态）、一般×2（正则未锚定、复杂段丢后缀）、轻微×5 |
| 17 | `f_util/src/PathPattern_test.cj` | .cj | ✅ | 33 用例覆盖好；缺负向：正则过度匹配、同深度回溯、带后缀复杂段 |
| 18 | `f_util/src/ResposibilityChain.cj` | .cj | ✅ | 轻微×2（空 `execute`、注册表并发并入合并项） |
| 19 | `f_util/src/StatePattern.cj` | .cj | ✅ | 一般×1（默认 `continues=true` + 递归无守卫 + 泛型遮蔽）；仓内零实现 |
| 20 | `f_util/src/StrategyPattern.cj` | .cj | ✅ | 注册表并发（并入合并项）、`ArrayList` 未用 import |
| 21 | `f_util/src/TextTemplate.cj` | .cj | ✅ | 一般×5（空值、进制、索引错位、契约、缓存无界）、轻微×1（两段解析重复）；优化 2/7 |
| 22 | `f_util/src/TextTemplateCacheKey_test.cj` | .cj | ✅ | 5 用例覆盖缓存键隔离；缺"长度前缀防碰撞"（`a`+`bc` vs `ab`+`c`）边界 |
| 23 | `f_util/src/TreeTransformer.cj` | .cj | ✅ | 一般×1（孤儿 `NoneValueException`）、轻微×1（两重载丢根） |
| 24 | `f_util/src/UInt128.cj` | .cj | ✅ | 一般×1（长度不校验、不 throw）；无测试 |
| 25 | `f_util/src/Utils.cj` | .cj | ✅ | 严重×1（`computeBytes` 恒真分支）；无测试 |
| 26 | `f_util/src/code_buffer.cj` | .cj | ✅ | 轻微×1（`rawPointer` 恒等分支 + 与 f_jit 重复）；失败路径回退契约清楚 |
| 27 | `f_util/src/crc16.cj` | .cj | ✅ | 24 变体参数与 RevEng 检查值自洽；无死代码 |
| 28 | `f_util/src/crc32.cj` | .cj | ✅ | 11 变体齐全；硬件/软件分层与 16 字节对齐注释一致 |
| 29 | `f_util/src/crc32_codegen_test.cj` | .cj | ✅ | 轻微（开关未 try/finally）；对拍+非对齐+4×1000 并发覆盖好 |
| 30 | `f_util/src/crc32_hw_kind.cj` | .cj | ✅ | 轻微（手写枚举相等） |
| 31 | `f_util/src/crc32_native_arm.cj` | .cj | ✅ | 一般（脚手架重复/开关两态）、轻微（测试钩子无同步）；机器码字节未反汇编，依赖对拍用例 |
| 32 | `f_util/src/crc32_native_stub.cj` | .cj | ✅ | 一般（`@When` 漏 arch，Linux riscv64/loongarch64 编译失败） |
| 33 | `f_util/src/crc32_native_x86.cj` | .cj | ✅ | 同 #31；`resetForTest` 语义与 crc64 不一致 |
| 34 | `f_util/src/crc64.cj` | .cj | ✅ | 6 变体参数与 catalog 一致；轻微（`:48` 悬空 KDoc） |
| 35 | `f_util/src/crc64_native_arm.cj` | .cj | ✅ | 轻微×2（`ensureReady` 忽略 `fnNorm`、未校验 `aligned%16`）、死代码、测试钩子并发 |
| 36 | `f_util/src/crc64_native_stub.cj` | .cj | ✅ | 三平台收口正确，是 stub 范本；轻微（`modeNameForTest` 死代码） |
| 37 | `f_util/src/crc64_native_x86.cj` | .cj | ✅ | 脚手架重复 + 漂移、`aligned` 校验、死代码、测试钩子 |
| 38 | `f_util/src/crc_check_test.cj` | .cj | ✅ | 16/32/64 全变体 × catalog + 增量 + 空输入四类断言齐全；`@Fail` 会中断首个偏差 |
| 39 | `f_util/src/exception/GeoHashException.cj` | .cj | ✅ | 参与"5 异常类同构"；被 `geohash.cj:126` 使用 |
| 40 | `f_util/src/exception/HashException.cj` | .cj | ✅ | 同上；`UInt128.cj:61` 构造后未 throw（已在 #24 报） |
| 41 | `f_util/src/exception/IdException.cj` | .cj | ✅ | 同上；被 `IdMaker.cj:30` 使用 |
| 42 | `f_util/src/exception/TextTemplateException.cj` | .cj | ✅ | 同上；被 `TextTemplate.cj:109/249/305/334` 使用 |
| 43 | `f_util/src/exception/UUIDException.cj` | .cj | ✅ | 同上；被 `uuid.cj:180` 使用 |
| 44 | `f_util/src/geohash.cj` | .cj | ✅ | 严重×2（方向反、中点重算）、轻微×1（无范围校验）；无测试 |
| 45 | `f_util/src/prime.cj` | .cj | ✅ | 严重×1（模乘溢出）、一般×1（MR 分支/基不足）、轻微×1（无签名/前置条件）；零引用零测试 |
| 46 | `f_util/src/uuid.cj` | .cj | ✅ | 严重×3（时间戳溢出、v7 右移、serialSeq）、一般×7、轻微×7 |
| 47 | `f_util/src/uuid_test.cj` | .cj | ✅ | 仅 v4 往返用例，见"测试覆盖不足" |
| 48 | `f_util/src/wyhash.cj` | .cj | ✅ | 与 runtime 实现逐行一致（仅 `Array` 下标替代 unchecked）；未用 import；零引用但属对外 API |

合计：`.cj` 48 个 / `.md` 0 个 / 共 48 个，全部读完。

## 覆盖自检

> 命中数为四部分之和，跨部分重复条目已去重。命中 0 条的维度均写明清查过程。

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 45 | 正确性：CityHash×2、Murmur、DH×2、IdMaker、PathPattern×4、computeBytes、UInt128、TextTemplate×3、TreeTransformer、GeoHash×3、isPrime×2、UUID×5；设计：注册表契约、统一入口、Equatable 契约、API 噪声、线程契约、可见性；语言特性：默认可见性、`Option` 隐式装箱、返回类型推导、`var` 可改 `let`；可读性：200 行单函数、悬空 KDoc、错误文案；安全性：DH 非素数模数（1 条，无凭据/注入面） |
| §1 死代码 | 14 | 已逐个 `private` 全仓搜、`internal`/包内成员在包内搜、`public` 先判对外可达：CityHash `mur`/`rotate32`/`mix`/`chunkSize32`、Murmur 4 import、`CrcGf_test` 2 符号、`CrcGf.reflectConstants`、PathNode 5 重载 + `data(Any)`、TextTemplate `mutex`/`indexText`、3 处 import、`Crc32Hw.available`×3、`modeNameForTest`×3、`crc64.cj:48` 悬空 KDoc、`uuid.cj:511` 不可达 throw、wyhash/uuid 未用 import。对外可达 `public`（`PathPattern` 的 `matches*`、`eth0`、`isPrime` 等）仓内零引用不判 |
| §2 重复逻辑 | 11 | 已对同文件函数体两两比对并跨文件搜字面量：Murmur 尾部 k1 混合×2、CrcGf 三套常量布局、CaseFormat 模板化（不判）、TextTemplate time/number 解析、code_buffer↔f_jit、CrcHwKind 手写相等、`computeBytes`↔`parseByteSize`（下游自建）、CRC 4 份脚手架、5 异常类、PathNode `==`/`!=`、UUID 版本位×5 + hex 解析×2 |
| §3 空实现 | 2 | `ValidationResponsibility.execute` 空实现无注释；`eth0()` 丢弃结果（空壳）。`Producer.produce` 默认抛异常、`SequenceResource.empty`、平台 stub 的 no-op 均有注释，判有意 Null Object |
| §4 栈溢出 | 1 | `State.startup` 递归无深度/环检测且 `continues` 默认 true；其余（CityHash/Murmur/FNV/CRC/geo/prime/UUID）均为迭代，`qpow`/`millerRabin` 深度恒定 |
| §5 OOM | 4 | DH 无限精度乘方；TextTemplate 静态缓存无界；`doCompile` 在 `prefix/suffix` 为空串时 `start` 恒 0、`compiled` 无界增长（死循环式 OOM，`TextTemplate.cj:83-98`）；PathPattern `patterns` 按请求深度永久增长。其余容器规模为常量 |
| §6.1 热点瓶颈 | 0 | 未提供 `cjprof`/`cjpm bench` 数据，热点结论不成立；17 条候选全部进「待验证假设」，无一条写成缺陷 |
| §6.2 大粒度锁 | 2 | `timestampAndSequence` 临界区内含文件 `read/write/flush/seek`；CRC 每次 `update` 进全局 `Mutex`（临界区仅读 `ready`，结构属高频小临界区，进优化方案）。`PathPattern.mutex` 临界区含 `compile`/`supplier()`，仅启动期注册，不单列 |
| §6.3 并发串行 | 0 | 生产路径无 `spawn`/`Future` 提交即等待；`crc32_codegen_test.cj:117-129` 是 4 个独立 `spawn` 后统一 `get`，形态正确 |
| §6.4 低效算法 | 4 | `Fnv.hash` 每次构造 5 数组、Murmur 每块 3 次切片、PathPattern 每段 `HashMap.values()` 全量扫描 + 每请求 2 次 `replace`，均入优化方案（无占比数据）。CityHash 死循环另计严重 |
| §7 降堆内存方案 | 3 | CrcEngine 正/反射双表（≈100 KiB）、TextTemplate 缓存有界化、UUID 内联 16 字节。注：part1 的 Fnv 分配方案同时计入 §8，合并后按 CPU 归类，故此处按实际堆内存方案计 3 |
| §8 降 CPU 方案 | 7 | Fnv 快路径、Murmur 块读取、FnvCore 单趟 limb、f_log key 构造、PathPattern 去物化、CRC 无锁快路径、UUID.toString 查表 |
| §9 local mode 可行性 | 0 | 候选产物全部逃逸（`String`、`UInt128`、`Array<UInt64>`、`PathNode`、`UUID`），逃逸检查不通过；且无改前/改后峰值内存数据，不满足立项条件 |
| §11 现有代码的 BUG（存量） | 49 | 四部分逐条核对边界/空值/错误处理/资源对称：CityHash 越界×2、Murmur、DH×2、IdMaker、Factory/Mediator、PathPattern×4、computeBytes、UInt128、TreeTransformer、State、TextTemplate×4、GeoHash×3、isPrime×2、UUID×8、CRC 调度×3、测试状态恢复×2 等；合并去重 2 条（tryParse/IsUUID、测试开关）。全部存量 |
| §12 并发安全与锁粒度 | 8 | 共享点：PathPattern `patterns`（严重）、Factory/Mediator/ResponsibilityChain/Strategies 注册表（合并 1 条）、DH `ab_`、FnvHasher、UUID builder 字段与注册、CRC 测试钩子/`lastNative`、UUID 锁内 I/O、serialSeq 检查-然后-写入。不可变/值类型（`UInt128`、`UUID`、`Crc64` 实例、CRC 静态表、`CrcEngine` 表）判安全 |
| §13 文档一致性（.md） | 1 | 本模块清单无 `.md`，为取证读了 `f_util/README.md` / `README_en.md` / `doc/spec/**`：命中 `encode(latitude, longitude)` 与实现相反 1 条；`README.md:623-627` 的 `This`/`Unit` 计入 §14，`noneConverter` 计入 §11/§14，不重复计数 |
| §14 功能完备性与 README 覆盖 | 5 | ① `crc32_native_stub` 漏 arch，README"其它架构纯软件"在 Linux riscv64/loongarch64 不成立；② `qpow`/`millerRabin`/`isPrime` 只有符号名无签名/限制；③ `noneConverter` 承诺未对 plain 实现；④ README 承诺 v1/2/6 但 v2 时间戳不可读；⑤ `TimestampSequenceBuilder` 注册方法返回类型写成 `This`。`Crc64`/`Crc32`/`Crc16` 变体表、异常族清单与实现逐项一致 |
| 文件覆盖（§13 等） | 48/48 | 48 个 `.cj` 全部读完；本模块清单无 `.md`，README/doc 仅作契约取证 |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 14 |
| 一般 | 25 |
| 轻微 | 36 |
| 优化方案（堆内存 / CPU） | 3 / 7 |

存量缺陷共 **75** 条（part1 21 + part2 24 + part3 16 + part4 17 = 78，跨部分合并去重 3 条），本轮无本次改动引入项；是否纳入修复待用户在门禁决定。

## 总评

`f_util` 的质量呈明显的三档分布。**工程化程度最高的一档是 FNV 与 CRC 参数/测试体系**：`Fnv` 五个宽度 × 两个变体的基值与素数逐位对照官方值，黄金值覆盖到 1024 位长输入；`Crc16/Crc32/Crc64` 的变体参数与 RevEng catalog 自洽，`crc_check_test` 用"全变体 × 检查值 + 顶层 API 指向 + 增量=一次算完 + 空输入"四类断言钉死参数，`CrcEngine_test`/`crc32_codegen_test` 另有硬件/软件对拍、三态开关、分配失败回退、非对齐长度与 4 路并发用例。`code_buffer` 的失败路径一律返回 `None`/`false` 交调用方回退，边界清楚。这一档的问题几乎都在"复制粘贴后忘了同步"的收尾：CRC 硬件脚手架 4 份分叉、`F_UTIL_CRC_HW=off` 在 CRC-32 侧不生效、`crc32` stub 漏 arch 导致 Linux riscv64/loongarch64 编不过、aarch64 `ensureReady` 漏 `fnNorm`。抽一份 `CrcHwSlot` 可一次性消掉，建议排期。

**第二档是"对外 API 一用就错"的四个重灾区**，共同点是实现未收尾或根本未验证：

1. `PathPattern` 是全模块最高风险文件。`get()` 是 200 行回溯状态机，其中"占位符 + 两个字面段"形态会**无限循环**（同深度不匹配的普通 404 请求即可打死一个请求线程），同时还在**读路径上写共享 `ArrayList`**——两个普通请求就构成对 `std.collection.ArrayList` 的无同步并发读写。再叠加正则缺尾锚点的过度匹配、`ComplexPathNode` 丢字面后缀，这套路由在"测试能过"与"线上正确"之间差距明显。
2. `uuid.cj` 的 v1/v6/v7 三个版本时间戳读写全有硬错：读取侧 `*100` 必溢出（v7 还叠 12 bit 随机位错位），写入侧 v7 时间戳右移 16 位；`serialSeq` 同 ts 内不递增，使 v1 在"固定 node"标准用法下产生重复主键（仓内靠 `randomNode()` 掩盖）。v7 已被 `fdbm` 用作主键、`f_llm` 用作租约标识，时间有序性已失效；`timestamp`/`timestampNanos` 作为公开属性完全不可用。
3. `CityHash` / `MurmurHash3X128` 是从其他语言机械搬运未收尾：空串/短串直接越界、`len >= 128` 尾部循环不终止、Murmur 尾部 8 字节被异或两次（同长度仅尾 8 字节不同即碰撞）。三者都只看代码即可定论，且 `CityHash` 完全没有测试。
4. `GeoHash` / `prime` 零测试、零引用、公开 API：`encode` 二分方向反了，全部坐标只剩 4 个 hash（东北象限 = `0x0`，`decode(encode(北京)) = (-180,-90)`）；`tryParse` 用区间中点重算，`parse(toString(g))` 恒不成立；`isPrime` 的模乘在 `UInt64` 上溢出，`p ≥ 2³²` 抛异常，即使修好溢出 Miller-Rabin 的 `t == 1` 分支也判反、5 个基覆盖不到 64 位。

**第三档是骨架类**：`Factory`/`Mediator`/`ResponsibilityChain`/`Strategies`/`State`/`TreeTransformer`/`UInt128`/`computeBytes` 多为零测试小件，缺陷形态一致——本该失败的输入静默成功（`computeBytes` 的 `groupCount` 恒真、`UInt128` 不抛长度异常、`State` 默认 `continues=true` 变成无限递归），或契约只在实现里隐含（注册表静默覆盖、缺键抛 `NoneValueException`）。`DiffieHellmanKeyExchanger` 是其中最严重的：用 `Decimal` 无限精度乘方做 63 位指数模幂（跑不完或恒得 0），模数还是随机字节而非素数，实际上不具备密钥交换能力，却以"密钥交换协议"对外提供。

**阻塞项（建议本轮修）**：PathPattern 回溯死循环与读路径竞态、UUID 的 v7 位偏移与 `serialSeq` 唯一性、`UUID.timestampNanos` 溢出、`GeoHash.encode`/`tryParse`、`CityHash` 两处越界、`Murmur` 尾部双异或、`isPrime` 模乘溢出、`computeBytes` 恒真分支、DH 的模幂与非素数参数、`crc32_native_stub` 的 `@When`。这些都属于"对外 API 正确性/安全性"或"换平台编不过"，修复范围局部、收益直接。`UInt128.fromBytes` 漏 `throw` 与 `Factory/Mediator` 契约收紧建议同批处理。

**可排期**：CRC 硬件脚手架合并 + `F_UTIL_CRC_HW` 三态统一（同一批文件改两遍，宜与上述修复同批）；`TextTemplate` 的四处格式化缺陷与 `noneConverter` 契约（前提是补 `time:`/`number:` 用例，当前该路径一行测试都没有）；UUID 的 v5 互操作与 `tryParse` 严格化；文件序列生成器若确认无人使用，删除比修更划算。

**测试缺口是本模块缺陷长期存在的直接原因**：`CityHash`、`UInt128`、`Utils`、`geohash`、`prime`、`DiffieHellmanKeyExchanger`、`TextTemplate`（time/number）、`UUID`（v1/v6/v7/v5）均无有效用例，`uuid_test` 只有一个 v4 往返。补用例的成本高于改代码，但收益更持久。

性能类结论本轮全部无测量数据（`scope.md` 未提供 bench/profile），因此只列了 10 条带 `无基线` 标记的优化方案与 17 条待验证假设，均不进修复清单。范围外提示（不占本轮统计）：① `fmq/src/config/MQConfig.cj:183-186` 已因 `computeBytes` 不可用自建 `parseByteSize`，修好后可回收；② `f_jit/src/backend/CodeBuffer.cj` 与 `f_util/src/code_buffer.cj` 是同一套 W^X 页管理的两份实现；③ `f_util/doc/spec/crc32-hw-cfunc/` 与 `accelerate-f-util-crc/` 对同一开关给了两套口径（`=0` vs `off/0/on/1`），合并时应保留三态并让 CRC-32 对齐。
