# f_util 模块审查报告

> **模块第 2/4 部分**（本报告只覆盖 `files/f_util.part2.txt` 列出的 19 个文件，全部是 `f_util/src/` 下的 `.cj`：`CaseFormat_test` → `StrategyPattern`。本部分没有 `.md`；`README.md` / `README_en.md` / `doc/**` 与其余 29 个 `.cj` 由第 1、3、4 部分产出。本部分编号独立，合并时以主 Agent 为准。）

- **审查日期**：2026-11-28
- **模块路径**：`f_util`（本部分 19 个 `.cj`，0 个 `.md`；模块共 48 `.cj` + 19 `.md`）
- **基线**：工作区快照（`HEAD 97507061b`，`git status` 无源码 diff ⇒ 本部分所有问题记「存量」）
- **审查重点**：工具类正确性与边界、死代码、重复逻辑、空实现、栈溢出、OOM、并发安全、存量 BUG
- **报告版本**：v1（第 2/4 部分）
- **验证方式**：只读审查，未跑 `cjpm build` / `cjpm test`；所有"运行时后果"均由代码路径与官方文档语义推导，未做实测

## 发现

### [严重][存量] #1 `cityHash` 三种长度全都不可用：0–15 字节越界崩溃、16–127 字节只读首尾 24 字节、≥128 字节死循环后越界

- **位置**：`f_util/src/CityHash.cj:34-39`（短输入直接进 `weakHashLen32WithSeeds`）、`176-211`（该函数在 `184-202` 读 `offset + len - 8` / `offset + 8`）、`74-96`（尾部循环）、`132-139`（`fetch64` 无边界检查）
- **来源**：存量（`git blame`：`4be871f2fd 2026-10-02`；快照模式无基线可比）
- **判据**：review-checklist §11「边界差一 / 越界 / 空集合未处理」、§4「无界循环」
- **证据**：静态确定 —— 三条都能只读代码判定：
  1. `len < 16`：走 `weakHashLen32WithSeeds(data, 0, len, …)`。`len < 8` 时 `186` 行算 `offset + len - 8 < 0`；`8 ≤ len < 16` 时先过 `len <= 16` 分支，随后 `201-202` 无条件 `fetch64(bytes, offset)` 与 `fetch64(bytes, offset + 8)`，后者读 `bytes[8..16]`，对 8–15 字节的数组越界。`fetch64` 里 `bytes[offset + i]` 没有任何检查 ⇒ `IndexOutOfBoundsException`。即 `cityHash("abc")`、`cityHash("12345678")` 必崩。
  2. `16 ≤ len < 128`：只调一次 `weakHashLen32WithSeeds(..., len, k0, k1)`，它只读 `offset+0..8`、`offset+8..16`、`offset+len-16..len-8`、`offset+len-8..len` 四处。`len ≥ 24` 时区间 `[16, len-16)` 的字节完全不参与运算 ⇒ 两个只有中间字节不同的输入必然同哈希（例如两个 100 字节、首 8/尾 8 字节相同的串）。
  3. `len ≥ 128`：`78` 行 `let remaining = len - pos`，`80` 行 `while (remaining > 0)`，循环体（`80-94`）只改 `tailOffset`、从不改 `remaining` ⇒ 死循环；`tailOffset` 每轮至少 +1、`88/90` 行读 `tailOffset + chunkSize - 16`，很快就会越过数组末尾 ⇒ 实际表现是先跑若干轮再抛越界（若数据足够长则表现为长时间空转）。
- **描述**：`cityHash` 是 `public` 顶层函数（三个重载：`String` / `Array<UInt8>` / 泛型 `T <: ToString`），仓内目前没有任何调用点（已全仓搜索 `cityHash`，只有定义处与 cjo 符号），属于对外 API 的潜伏崩溃点；任何下游拿它算短串就会挂。除崩溃外，16–127 字节的碰撞面会让它作为哈希键（去重、分片）直接失效。
- **建议**：不要在这份实现上做局部修补。按 CityHash 原始定义重写长度分派（`HashLen0to16` / `17to32` / `33to64` / `>64` 四个分支，每个分支显式检查可用字节数），或者直接用项目里已有、且有黄金值用例的 FNV / murmur 替代。`fetch64` 至少加 `offset + 8 <= bytes.size` 断言；`while (remaining > 0)` 改成 `while (tailOffset < len)` 并把 `chunkSize` 上限夹到剩余长度。必须补 `0/1/7/8/15/16/23/24/32/127/128/129` 长度的用例，否则修了也无人守。

### [严重][存量] #2 `murmurHash` 分块循环上界写错 + `tailLen == 8` 二次混合：≥32 字节的输入大部分字节不参与哈希

- **位置**：`f_util/src/MurmurHash3X128.cj:30`（`nblocks = len / 16`）、`39`（`for (offset in 0..nblocks : 16)`）、`71-72`（`tailStart = nblocks * 16`）、`77-108`（尾部处理，`97` 的 `else if (tailLen > 0)`）
- **来源**：存量（`git blame`：`4be871f2fd 2026-10-02`；快照模式无基线可比）
- **判据**：review-checklist §11「边界差一 / 契约与实现不符」、§6.4「重复消费/漏消费」
- **证据**：静态确定 —— 官方区间语义：`start..end : step` 是左闭右开、`step` 为步长（`cangjie-docs/docs/dev-guide/source_zh_cn/basic_data_type/range.md:22-23`）。于是：
  - `offset ∈ {0, 16, 32, …} ∩ [0, nblocks)`。`len = 32 ⇒ nblocks = 2`，只有 `offset = 0` 一轮，`tailStart = 32`、`tailLen = 0` ⇒ 字节 `[16, 32)` 从未被哈希；`len = 48` 只哈希 `[0,16)`，`[16,48)` 全丢；`len = 4096 ⇒ nblocks = 256`，只有 `offset = 0,16,…,240` 共 16 轮，`[256, 4096)` 全丢。任何 `len ≥ 32` 的输入都至少丢 16 字节，长输入丢绝大部分。
  - `tailLen == 8`（即 `len % 16 == 8`）：先走 `77` 的 `tailLen >= 8` 分支读 8 字节并混入 `h1`，随后 `97` 的 `else if (tailLen > 0)` 成立（8 > 0），把同一批 8 字节重新组装成 `k1_tail` 再混一次 ⇒ `h1` 被重复异或。这与标准 MurmurHash3 x64_128 的 `case 8:` 语义不符。
- **描述**：`murmurHash` 是 `public`，仓内有真实调用：`f_codec/src/default/DefaultCodec.cj:87/109/121/182` 用它做"类型限定名 → 类型 ID"的注册与反查键，`fdbm/src/route/algorithms.cj:225/282` 用它做分片。类型名 32–47 字节时后 16 字节被忽略 ⇒ 两个只在第 16 字节之后不同的类型名会得到相同键，反序列化会按错误的 creator 构造对象（**数据错乱**，不是简单碰撞）；注意 `DefaultCodec.cj:185-187` 的注释明确把碰撞当成"128 位哈希理论碰撞、概率极低，暂不处理"，而本实现让它变成"改掉第 17 个字节就碰撞"的结构性碰撞。分片侧表现为长 key 的分布退化（可接受，但会掩盖真实倾斜）。
- **建议**：块循环改成 `for (i in 0..nblocks) { let offset = i * 16 … }`（或 `for (offset in 0..(nblocks*16) : 16)`），尾部按 `tailLen` 精确分支（`>= 16` 不应出现；`> 8` 处理 `k2`，`== 8` 只处理 `k1`，`1..7` 处理 `k1` 的部分字节），并删掉 `97` 的 `else if` 让 `8` 不再落进 `k1` 部分分支。补黄金值用例：至少 `0/1/7/8/9/15/16/17/31/32/33/48/127/128/4096` 长度，与独立的 Python/`murmur3` 参考实现对拍。
- **相关**：`39-43` 每 16 字节 `data[offset..offset+16]` 分配一个切片，再 `readLittleEndian`，见「优化可行性方案 O1」。

### [严重][存量] #3 `IdMaker` 的位布局与时间戳策略都错了：同毫秒多实例生成完全相同的 ID

- **位置**：`f_util/src/IdMaker.cj:26`（`startMillis` 只在构造时取一次）、`28-33`（`hostSerial << 53`、`startMillis << 12`）、`40-42`（`nextInt64` 只 `fetchAdd(1)`，不刷新时间、不检查序号溢出）
- **来源**：存量（`git blame`：`4be871f2fd 2026-10-02`；快照模式无基线可比）
- **判据**：review-checklist §11「契约与实现不符 / 边界」、§12.1「共享可变状态」
- **证据**：静态确定 ——
  1. **ID = 构造时刻 + 自增计数**。`startMillis` 是 `private let`，只在构造时求值；`nextInt64()` 永远返回 `base + n`（`base = serial<<53 | startMillis<<12`）。两个在同一毫秒内构造的 `IdMaker`（同 serial）得到同一个 `base`，第一个 `nextInt64()` 都返回 `base` ⇒ **主键冲突**。
  2. 该模式在仓内有真实触发路径：`fdbm/src/execute/executors.cj:898` 在**需要补分区列值的每条 INSERT** 上都会调 `IdMakers.forTable(...)`，`fdbm/src/idmaker/IdMakers.cj:87` 每次都 `new SnowflakeIdGenerator(serial)` → `new IdMaker(...)`。同一毫秒内的 N 条这类 INSERT 会拿到 N 个相同 ID。
  3. **位布局与雪花算法相反**：`hostSerial << 53` 把 10 位机器号放在最高位，`startMillis << 12` 把 41 位时间戳放在其下。时间戳不是最高有效字段 ⇒ 不同节点生成的 ID 按数值排序时先按机器号分组、再按时间（且时间还是"启动时刻"），跨节点完全不具备趋势递增/索引局部性，与 `docs/speech/speech.md:4731` 的「10bit主机号+41bit毫秒+12bit序号」描述也不一致。
  4. **12 位序号无溢出保护**：`fetchAdd` 单调加到 4096 后进位污染时间戳字段，此后 ID 里编码的时间不再对应任何真实时刻；`nextInt64` 也没有"同毫秒超过 4096 就等到下一毫秒"的分支。
- **描述**：`IdMaker` 被 fdbm 当作 snowflake 主键生成器（`SnowflakeIdGenerator`）。当前实现同时丢了"跨实例唯一"和"按时间有序"两个核心契约，重复主键会在 ORM 层表现为插入失败或覆盖；位布局错误会让按主键分页/排序的查询失真。
- **建议**：改成标准 snowflake：`((nowMs - epoch) << 22) | (serial << 12) | seq`；`nextInt64` 内部用 `synchronized`/CAS 维护 `(lastMs, seq)`：同毫秒 `seq++`（到 4095 自旋到下一毫秒），新毫秒重置 `seq=0`；并且 `IdMaker` 必须是**进程级单例**（按 serial 缓存），不能每条语句新建。补用例：同毫秒构造两个实例各取 1 个 ID 必须不同；同实例连取 5000 个必须单调且严格递增；跨"毫秒回拨"场景不得回退。

### [严重][存量] #4 `DiffieHellmanKeyExchanger` 的共享密钥计算不成立：先算完整 `g^ab` 再取模，指数是 63 位随机数

- **位置**：`f_util/src/DiffieHellmanKeyExchanger.cj:97-99`（`middle` = `(Decimal(BigInt(g)) ** ab_).toBigInt() % BigInt(p)`）、`84`（`protected var ab_ = random()`）、`100-102`（`random()` = `ThreadLocalRandom.current.nextInt64()`）、`91-95`（`key`）、`78-80`（`finish`）
- **来源**：存量（`git blame`：`4be871f2fd 2026-10-02`；快照模式无基线可比）
- **判据**：review-checklist §11「契约与实现不符」、§10「正确性」、§5「按输入规模不可行的物化」
- **证据**：静态确定（"不可能正确"，具体失败形态需实测）—— 协议要求算 `g^ab mod p`，实现却先算完整的 `g^ab`：
  - `g` 由 16 个随机字节组成（`semi` 里 `randomBytes(bytes: 16)`），量级 ≈ 2^127；`ab_` 是 `Int64` 随机数，量级可达 2^63。精确幂的位数 ≈ `127 × 2^63 ≈ 2^70` bit（约 10^20 字节），无论用哪种表示都不可能在内存里完成 ⇒ 要么 OOM/长时间卡死，要么依赖 `Decimal` 舍入。
  - `Decimal` 是"任意精度十进制，**允许操作过程指定结果精度及舍入规则**"（`stdlib/doc/libs/std/math_numeric/math_numeric_package_overview.md:41`）；`operator **（Int64）` 的文档只对"指数为负值且结果为无限小数"明确写"默认采用 IEEE 754-2019 decimal128 对结果进行舍入"（同目录 `math_numeric_package_structs.md:4904-4914`），正指数在默认上下文下是否精确展开**待确认**。但两种可能都不可用：按上下文精度舍入 ⇒ 128 位底数的 63 位次幂只剩 38 位有效数字，`% p` 与真实模幂无关；精确展开 ⇒ 结果位数 ≈ `127 × 2^63 ≈ 2^70` bit，必然 OOM/长时间卡死。无论哪种，Alice 算 `B^a`、Bob 算 `A^b` 都拿不到同一个值（失败是静默的：双方都得到一个非 `None` 的字符串）。
  - `nextInt64()` 的文档只写"获取一个 Int64 类型的伪随机数"（`stdlib/doc/libs/std/random/random_package_api/random_package_classes.md:733-744`），未限定非负；若取到负值，`Decimal ** 负数` 是小数，`.toBigInt()` 截断后基本为 0 ⇒ `middle` 返回 0（`0 % p == 0`）。此子项 `待确认`（需要实测 `nextInt64` 的取值范围）。
  - `g`、`p` 是随机字节而不是大素数/生成元，`p` 非素数时 `mod p` 的乘法群含零因子、`g` 也不保证是生成元 ⇒ 即使幂算对，协议也没有类注释（`22-35`）宣称的离散对数安全性。
- **描述**：这是"看起来实现了 DH、实际算不出正确共享密钥"的典型形态：接口签名完整、注释写了 7 步协议、`key()` 返回 `String`、`finish()` 返回 `BigInt`，没有任何错误路径。下游若把它当密钥交换用，会得到一个双方不一致的"密钥"，后续对称加密全部解不开（或退化成固定值）。
- **建议**：用 `BigInt` 的模幂（若标准库没有 `modPow`，先实现平方-乘 + 模约减）替换 `Decimal **`；`p`、`g` 改为固定 RFC 3526 素数群/生成元常量，私钥改用 `BigInt(true, 2048, rand: SecureRandom())` 这类接口生成真正的随机大整数（`BigInt` 的 `sign=true` 表示非负，见 `math_numeric_package_structs.md:160-178`，所以现有 `BigInt(true, g)` 至少符号是对的，问题在指数与模幂）。`middle` 对 `g ≤ 1 || g ≥ p` 做校验。若短期内不打算修，至少把类注释改成 `@Deprecated` 并注明"不可用于安全用途"，避免下游误用。

### [严重][存量] #5 `DiffieHellmanKeyExchangerServer.key`：对端可控的 `m` 使 `while (result == "0")` 永不退出

- **位置**：`f_util/src/DiffieHellmanKeyExchanger.cj:64-71`（`var result = "0"; while (result == '0') { ab_ = 0; result = super.key(m, p) }`）
- **来源**：存量（快照模式无基线可比）
- **判据**：review-checklist §11「无界循环 / 外部输入未校验」、§12.1「有界性」
- **证据**：静态确定 —— `super.key(m, p)` 返回 `middle(m, p).toString(radix: 36)`，`middle` 是 `m^ab mod p`。若对端传入 `m = p` 或 `m = 0`（`m` 是 `Array<Byte>`，完全由对端控制），则对任意 `ab > 0` 都有 `m^ab ≡ 0 (mod p)` ⇒ `result` 恒为 `"0"`；循环体只重置 `ab_`（重新随机）并重算，`m`/`p` 不变 ⇒ **死循环**，请求线程 CPU 100% 且永不返回。`m` 是 16 字节随机数时 `m % p == 0` 的概率虽低，但攻击者可以直接发 `m = p` 或 `m = 0`。
- **描述**：这是可被单个报文触发的 CPU DoS；同时 `p` 由对端给出，若 `p` 为 0 则 `% BigInt(0)` 抛异常（错误路径未处理）。同一函数里的 `ab_ = 0` 还会破坏实例状态（正在并发的 `finish()` 会踩到被清零的 `ab_`）。
- **建议**：删掉"结果为 0 就重试"的循环，改成对 `m` 做范围校验：`1 < m < p-1`，否则直接抛明确的协议异常并记录；`ab_` 改为 `let`/不可变（每次 `key` 用局部私钥），不要在多线程间共享可变字段。补用例：`m = p`、`m = 0`、`p = 0` 必须在有限时间内返回错误。

### [一般][存量] #6 `PathPattern.compile` 不走 `pretreat`：`{*name}`、`***`、连续 `/` 只在 `compileIfAbsent` 生效

- **位置**：`f_util/src/PathPattern.cj:101-103`（`compile(pattern)`）、`124-127`（`compile<T>(pattern, data)`）、`114-122`（`pretreat` 里的 `{*x}` / `***` / `//` 归一）、`153-156`（只有 `compileIfAbsent` 调 `pretreat`）
- **来源**：存量（快照模式无基线可比）
- **判据**：review-checklist §11「契约与实现不符」、§13（类注释即契约）、§14.1「只做了一半的分支」
- **证据**：静态确定 —— 类注释承诺 `{*...}` 等价于 `/**/{...}`（`PathPattern.cj:40`）、多处 `//` 合并（`28`）。但 `pretreat` 只被 `compileIfAbsent` 调用（`154`）；`compile(pattern)` 与 `compile(pattern, data)` 直接 `parts(pattern, true)`。于是：
  - `compile("/a/{*rest}")` 不走 `^\{[a-zA-Z_]…}$` 分支（`{` 后是 `*`），落到 `714` 的复杂节点分支，`ComplexPathNode.matches` 对 `{*rest}` 的静态片段是空串（见 `888-914`）⇒ 等价于"匹配任意**单级**路径"，而注释承诺的是多级；
  - `compile("/a//b")` 注册一个空段节点，而 `matches()` 会先 `trimRedundantSlash`（`477-479`）把 `/a//b` 归一成 `/a/b` ⇒ 这条路由永远匹配不上；
  - `compile("/a/***/b")` 里的 `***` 不会被折叠成 `**`（`117`）。
  `fleet/src/server/FleetStore.cj:93` 与 `:113` 用的正是 `compile(pattern, …)`（MQ 主题模式由客户端给），所以这不是纯理论问题。
- **建议**：把 `pretreat` 收进 `doCompile` 的第一行（所有入口都归一），或让 `compile` 两个重载先 `let p = pretreat(pattern)` 再传下去；同时把 `trimRedundantSlash` 的 `replace("//","/")` 改成循环到不再变化（`"///"` 一次替换后仍是 `"//"`，见 `105`）。

### [一般][存量] #7 三处"同名注册"都静默覆盖，没有一条按基线要求启动失败

- **位置**：`f_util/src/PathPattern.cj:659-667`（`createPlaceholderRegexNodeIfAbsent` 以**变量名**为键，同名不同正则直接复用第一个节点）、`f_util/src/Mediator.cj:22-24`（`colleagues[colleague.name] = colleague`）、`f_util/src/StrategyPattern.cj:46-54`（`strategies[strategy.name] = strategy`，含批量重载）
- **来源**：存量（快照模式无基线可比）
- **判据**：`fountain-baseline.md` §4「同名注册（扩展 / 路由 / 插件）：启动直接失败，不做隐式优先级；后者静默覆盖前者 = 违规」；review-checklist §12.1「检查-然后-写入」
- **证据**：静态确定 —— 官方文档：`HashMap` 的 `[]=` 运算符"如果键存在，新 value 覆盖旧 value"（`stdlib/doc/libs/std/collection/collection_package_api/collection_package_class.md:6197-6220`），而 `HashMap.add` 才是重复键抛异常的语义。三处都用了 `[]=`，所以：
  - `PathPattern`：`/x/{id:\d+}` 与 `/x/{id:[a-z]+}` 注册到同一父节点时，第二次 `regexPlaceholderPathNodes.get("id")` 命中，**新正则被丢弃**，第二条路由永远按第一条的正则匹配（既不报错也不生效）；
  - `Mediator` / `Strategies`：后注册的同事/策略悄悄替换先注册的，启动日志里没有任何痕迹。
- **描述**：路由/插件表是"配错就会把请求交给错误实现"的地方，静默覆盖把配置错误变成了运行期行为漂移，排查只能靠读代码。这类问题在 f_mvc 的路由装配期尤其危险（多个 Controller 可能声明同名占位符）。
- **建议**：三处都改成 `addIfAbsent` + 存在即抛带上下文的异常（`PathPattern` 的异常里带上两条 pattern 文本与变量名；`Mediator`/`Strategies` 带上 name）。若确实需要"热替换"语义，就显式提供 `replace(...)` 并在 README 写明，不要复用 `register`。

### [一般][存量] #8 `PathPattern` 同层多个候选节点的命中结果由 `HashMap` 遍历顺序决定，与类注释的优先级表不符

- **位置**：`f_util/src/PathPattern.cj:556-581`（`getComplexNode` 取 `complexPathNodes.values()` 第一个命中）、`582-608`（`getRegexPlaceholderNode`）、`627-634`（`getRegexNode`）、`609-626`（`getPlaceholderNode`）；优先级声明在 `42`，`get()` 的尝试顺序在 `254-358`
- **来源**：存量（快照模式无基线可比）
- **判据**：review-checklist §11「契约与实现不符」、§10「正确性（非确定性）」
- **证据**：静态确定 —— 官方文档明确"`HashMap` 并不保证按插入元素的顺序排列，因此遍历的顺序和插入的顺序可能不同"（`cangjie-docs/docs/dev-guide/source_zh_cn/collections/collection_hashmap.md:50`）。四个候选容器都是 `HashMap`（`506-510`），取值都是 `for (n in …values()) { if (n.matches(value)) return n }`，即"谁先被遍历到谁赢"。同时 `get()` 的实际尝试顺序是 精确 → `{name:re}` → `{name}` → 正则/通配 → 复杂段 → `*` → `**`（`256-324`），而注释写的是 `a>b=c=d>e=f=g>h`（`42`）——`{name}`（f）被排在 `*`/`?`/正则（b/c/d）之前，与注释相反。
- **描述**：同一层注册 `/api/{id:\d+}` 和 `/api/{name:\w+}` 时，"123" 同时命中两者，最终选中哪个由哈希顺序决定；不同进程、不同插入顺序、不同 SDK 版本都可能给出不同结果。对 MVC 路由来说这是"同样的代码在不同部署上命中不同 Controller"级别的不可复现缺陷。
- **建议**：候选节点改为有序结构（`ArrayList` 按注册顺序，或显式 `priority: Int64` 排序，同优先级按 pattern 字典序），并在 `get()` 之前按注释的优先级表定序；若确定要保留 `HashMap`，就必须在 `matches` 结果里返回"全部候选"由上层决定，不能靠遍历顺序。补用例：同层注册两个可同时命中的正则，断言多次运行/不同插入顺序下命中一致。

### [一般][存量] #9 `RegexPathNode` 的锚点逻辑写反：不以 `^` 开头的正则只做前缀匹配

- **位置**：`f_util/src/PathPattern.cj:823-833`
- **来源**：存量（快照模式无基线可比）
- **判据**：review-checklist §11「语义与命名不符 / 契约与实现不符」
- **证据**：静态确定 ——
  ```cangjie
  if (!name.startsWith("^")) { prefix = "^" }
  else if (!name.endsWith("$")) { suffix = "$" }
  ```
  `else if` 挂在前一个 `if` 上：正则**不以 `^` 开头**时只补 `^`，永远不补 `$`；只有"已经以 `^` 开头且不以 `$` 结尾"才补 `$`。于是 `{id:\d+}` 编译成 `^(\d+)`，`regex.matches("123abc")` 为真 ⇒ 路径段 `"123abc"` 能匹配数值占位符，之后 `extractParsableVariableInPath<Int64>` 才失败（错误被推到参数绑定阶段，且错误信息指向解析而非路由）。
- **描述**：路由正则的语义应当是"整段匹配"（同类工具的 `[]` 也是整段），当前实现让正则成为前缀匹配，等于放宽了所有 `{name:regex}` 路由的约束；对把正则当校验用的调用方（如时间范围、枚举 `{direction:(before|after)}`）会放行 `beforeX`、`123abc` 这类带尾缀的输入，真正拒绝要到后续参数解析/业务校验才发生。
- **建议**：改成两条独立判断：`if (!name.startsWith("^")) { prefix = "^" }`、`if (!name.endsWith("$")) { suffix = "$" }`；补用例：`{id:\d+}` 必须拒绝 `123abc`、`{direction:(before|after)}` 必须拒绝 `beforeX`。

### [一般][存量] #10 `PathPattern` 的匹配路径会写共享 `patterns`，且读在锁外

- **位置**：`f_util/src/PathPattern.cj:48-50`（`mutex` / `patterns` / `originPatterns`）、`68-99`（`getPathNode`：`90` 行锁外 `patterns.get(len)`，`69-89` 的 `populateNode` 在锁内 `add` / 赋值）、`477-491`（`get` 从 `matches()` / `data()` 进入）
- **来源**：存量（快照模式无基线可比）
- **判据**：review-checklist §12.1「共享可变状态无保护 / 迭代与修改并发」、§12.2「锁粒度」
- **证据**：静态确定（竞态窗口）+ 需实测（是否真的产生错误结果）—— 共享路径是实打实的：
  - `f_mvc/src/HttpRequestDistributorImpl.cj:19` 一个进程级 `private let patterns = PathPattern()`，`:43-45` 的 `getHandler(path)` 在每个请求线程上跑 `patterns.data<…>(path)`；
  - `fleet/src/server/FleetStore.cj:89-93` 用 `ConcurrentHashMap<MessageID, PathPattern>` 保存每个订阅的匹配器，`notify`（`81-87`）对每个 `PathPattern` 调 `data<T>(path)`；只要 MQ 投递线程多于一个，这些调用就是并发的（`ConcurrentHashMap` 只保证 map 本身，不保证 value 的线程安全）。
  `data()` → `get()` → `getPathNode(parts.size)`；当请求的段数大于当前 `patterns.size` 时，`populateNode`（`70-78`）会在锁内 `patterns.add(NonePathNode.INSTANCE)` 并写入新 `PathNode`——也就是说**匹配（读）路径会改共享容器**。而 `90` 行的 `patterns.get(len)` 在 `synchronized` 之外，与另一线程的 `add` 构成对 `ArrayList` 内部数组/长度的无同步读写。
- **描述**：`Mutex` 只包住了写，没包住读；`ArrayList` 不是线程安全容器（`ArrayList.get` 有边界检查，但并发扩容时的读没有可见性保证）。后果的严重程度取决于实现细节（可能只是读到 `None` 后多建一个节点，也可能抛异常/丢节点），但"每请求在全局锁内扩容 + 锁外读同一容器"本身已经同时是正确性缺陷和锁粒度问题：冷启动/首次访问长路径时，所有请求线程在这把实例锁上串行，且扩容临界区里还包含 `originPatterns` 回放（对每个 `**` 模式重跑 `this.parts` + 正则替换，见 `70-86`）。
- **建议**：分成读写两条路径：匹配时只读（`patterns` 用不可变数组 + 原子替换发布），`getPathNode` 未命中就直接返回 `None`，不要在匹配里创建节点；`compile` 阶段一次性把所有可能长度预热好（或用 `ConcurrentHashMap<Int64, PathNode>` 做长度索引，`addIfAbsent` 后发布）。若保留 `Mutex`，`getPathNode` 的读也必须进锁，并补一条并发用例：8 线程同时 `matches` 不同深度路径 + 另一线程 `compile`，断言无异常且路由结果稳定。

### [一般][存量] #11 `State.startup` 是无上限递归，状态机成环即栈溢出

- **位置**：`f_util/src/StatePattern.cj:43-52`（`startup` 里 `this.exec().startup()`）；`exec` 声明在 `35`，`continues` 默认 `true` 在 `27-31`
- **来源**：存量（快照模式无基线可比）
- **判据**：review-checklist §4「无界递归 / 间接递归」
- **证据**：静态确定（递归结构）+ 待确认（实际深度取决于使用者实现）—— `startup` 每帧调用 `exec()` 取下一个状态再递归，没有任何深度计数、访问集合或环检测；`continues` 默认返回 `true`，实现者只要让某个状态 `exec()` 返回自身（状态机里非常常见）就是无限递归。仓颉不保证尾调用优化（checklist §4 明示），因此即使写成尾递归也不能作为保险。
- **描述**：这是框架骨架 API（仓内暂无实现类），一旦被业务状态机使用，误配一个自环就是 `StackOverflowError` 级崩溃，且栈深度由状态链长度决定、不受控。
- **建议**：改成循环 + 显式上限：`var s: State<D> = this; var depth = 0; while (s.continues) { if (++depth > MAX) { throw IllegalStateException(...) }; s = s.exec() }`；`MAX` 可用常量或配置；`exec` 返回 `State<D>` 而不是泛型 `S`（见 #19 的类型参数遮蔽）。

### [一般][存量] #12 `ValidationResponsibility.execute` 的默认空实现让"忘记覆盖"静默通过

- **位置**：`f_util/src/ResposibilityChain.cj:40-42`
- **来源**：存量（快照模式无基线可比）
- **判据**：review-checklist §3「接口给了默认空实现，实现类忘记覆盖」、§11「静默失效」
- **证据**：静态确定 —— `public interface ValidationResponsibility<C, A> <: Responsibility<C, A, Unit> { func execute(arg: A): Unit {} }`：`execute` 给了空函数体，`ResponsibilityChain.executeAll`（`78-82`）只调 `check` 与 `execute`，返回 `Unit`、不检查任何结果。一个只实现了 `check` 的校验策略会稳定地"校验通过"，链式校验整体静默失效。
- **描述**：校验链的失败模式应当是"漏实现 → 编译报错"而不是"漏实现 → 全部放行"。当前形态把一个编译期可发现的问题推到了运行期，且没有任何日志/返回值能让调用方察觉。
- **建议**：删掉默认实现（强制实现类提供 `execute`）；如果确实要支持"只检查不执行"的策略，就提供显式的 `NoOpValidation` 类并让使用者主动选择。

### [一般][存量] #13 `Factory` / `Mediator` 用 `HashMap` 下标取缺失键：抛 `NoneValueException`，没有任何上下文

- **位置**：`f_util/src/Factory.cj:49-54`（`producers[TypeInfo.of<T>()]`）、`f_util/src/Mediator.cj:25-27`（`colleagues[arg.name]`）
- **来源**：存量（快照模式无基线可比）
- **判据**：review-checklist §11「错误处理缺失 / 静默或误导」、§10「错误处理」
- **证据**：静态确定 —— 官方文档：`HashMap` 的 `operator [](key)` 在键不存在时抛 `NoneValueException`（`stdlib/doc/libs/std/collection/collection_package_api/collection_package_class.md:6147-6165`）。两处都直接把下标结果当值用：未 `assemble`/未 `register` 的类型或名字会得到一个不带键名、不带注册表内容的 `NoneValueException`，和"值本身是 `None`"的错误无法区分。同目录的 `Strategies.execute`（`59-64`）已经用 `match (strategies.get(name))` + `IllegalAccessException("there is no strategy…")` 做了正确示范，三处口径不一致。
- **描述**：工厂/中介者是启动装配期最容易"漏注册"的地方；当前失败信息无法定位是哪个类型/哪个名字漏了，排查成本高。`Factory.produce` 里 `producers[...]` 的取值与 `convert` 的 `TypeNotMatchException` 是两种完全不同的失败，调用方只能靠堆栈区分。
- **建议**：统一改成 `match (map.get(key)) { case Some(v) => …; case None => throw IllegalAccessException("… not assembled/registered: ${key}") }`；`Factory` 里把 `TypeInfo.of<T>()` 提到局部变量复用。

### [轻微][存量] #14 死代码清单（CityHash / PathPattern）

- **位置**：
  - `f_util/src/CityHash.cj:158-172`（`mur` 全文件无调用）、`151-154`（`rotate32` 只被 `mur` 调用）、`119`（`hashLen16` 里 `let mix = …` 算完不用）
  - `f_util/src/PathPattern.cj:522-536`（`PathNode` 的 5 个 `init` 重载无任何调用点；被用的是 `516` 的 `init()`、`519` 的 `(name, prev)`（各子类 `super(...)` 走它）与 `537` 的私有 6 参 `init`）、`731-733`（`func data(data: Any)` 无调用）、`494-501`（`extend<T> Option<T> where T <: PathNode { func matches(value: String) }` 无调用，`matches(Option<PathNode>)` 走的是 `453-455` 的私有重载）、`959-961`（`Mode.matching()` 无调用）
- **来源**：存量（快照模式无基线可比）
- **判据**：review-checklist §1「无调用者 / 读了不用」；机械动作：`private` 全仓搜、`internal` 本包内搜
- **证据**：静态确定 —— 已逐个符号全仓搜索（`mur(`、`rotate32`、`PathNode(`、`.data(`、`Mode.matching`、`Option<PathNode>` 的 `matches`）：除定义处外零命中。`PathNode` 是 `open class`（无 `public`）⇒ 内部类型，其成员与 `init` 不属于对外契约。
- **描述**：`mur` 是 MurmurHash3 的 32 位混合函数，属于未完成的移植残留；`mix` 白算一次 64 位乘法 + 异或；`PathNode` 的 5 个构造重载与 `data(Any)`、`Option.matches`、`Mode.matching()` 是迭代过程中留下的兼容残留。
- **建议**：删除上述符号；`hashLen16` 直接内联 `return hashLen16Minimal(u, v) ^ UInt64(len)`（或删掉 `hashLen16Minimal` 保留一个）。

### [轻微][存量] #15 `CrcGf` 的 Barrett 约减"参考实现"与被测实现同构，无法证伪

- **位置**：`f_util/src/CrcGf.cj:58-75`（`barrettMu` 的 63 步移位减法）与 `f_util/src/CrcGf_test.cj:250-278`（`refBarrettMuLow` 逐行相同的移位减法）、`176-182`（`barrettReduce` 的公式实现）与 `158-173`（`refMod128` 同一套 hi/lo 异或约减）
- **来源**：存量（快照模式无基线可比）
- **判据**：review-checklist §2「近似重复」、§10「可测试性」
- **证据**：静态确定 —— 测试文件开头声明"参考实现独立写在本文件里：不复用 `CrcGf` 的辅助函数，避免生成器自己证明自己"（`CrcGf_test.cj:21-25`），但 `refBarrettMuLow` 与 `barrettMu` 是同一套 `if (bit) { hi ^= 1<<i; lo ^= poly<<i; hi ^= poly>>(64-i); q |= 1<<i }` 的移位减法；`refMod128` 与 `barrettReduce`/`barrettMu` 也共用这套域约减。两者只有在"多项式移位方向/进位处理"上犯**同一种**错误时才会同时出错，测试照样全绿——`crc64HwXz256MatchesSoftwareRegression`（`CrcEngine_test.cj:433-450`）的存在说明历史上已经踩过一次"常量布局错、测试没发现"的坑。
- **描述**：`barrettMu` / `barrettReduce` 是生成式折叠核的数学基础，它们的正确性目前只被"同构实现"验证；`refCrc64Reflected`（`CrcGf_test.cj:29-44`）与 `CrcEngine_test.refUpdate` 是真正的独立参考（逐位、不查表），但那两条只验证表路径，不直接验证 `barrettMu` 的商。
- **建议**：`barrettMu` 的参考值改为"独立来源"：用 `BigInt` 直接算 `x^128 / (x^64 + poly)` 的商，或把已发布的 CRC-64 常量（`x^128 mod P`、`mu`）作为黄金值逐字对照；`barrettReduce` 用 `BigInt` 算 `(hi·2^64 + lo) mod P` 对拍，而不是再写一遍移位减法。

### [轻微][存量] #16 重复逻辑：`hashLen16` / `pretreat` / `Mediator` 与 `Strategies`

- **位置**：`f_util/src/CityHash.cj:117-128`（`hashLen16` 与 `hashLen16Minimal` 逐行相同，只多一次 `^ len`，且各自重算 `shiftMix(xorResult * k1) * k1`）、`f_util/src/PathPattern.cj:105` 与 `119`（`pretreat` 和 `trimRedundantSlash` 各做一次 `replace("//","/")`，`pretreat` 先替换再调 `trimRedundantSlash`）、`f_util/src/Mediator.cj:20-28` 与 `f_util/src/StrategyPattern.cj:41-64`（同一套 name→实现 注册表 + 按 name 分派，仅容器类型与异常口径不同）
- **来源**：存量（快照模式无基线可比）
- **判据**：review-checklist §2「只改类型名 / 换控制流 / 近似重复」
- **证据**：静态确定 —— 三组都是"语义相同、实现两份"：
  - `hashLen16` 完全可以写成 `hashLen16Minimal(u, v) ^ UInt64(len)`，现在两处各算一遍 `shiftMix(xor*k1)*k1`；
  - `pretreat` 的 `p.replace("//","/")`（`119`）紧接着 `trimRedundantSlash(p)` 里又做一次（`105`），且单次 `replace` 处理不了 `"///"`；
  - `Mediator.execute` 与 `Strategies.execute` 都是"按 name 从 map 取实现并调用"，但缺失键时一个抛 `NoneValueException`、一个抛 `IllegalAccessException`（见 #13），属重复导致的行为漂移。
- **建议**：`hashLen16` 改为委托；`pretreat` 只保留一次归一（把 `"//"` 合并做成循环直到稳定，放进 `trimRedundantSlash`）；`Mediator` 收敛为 `Strategies` 的一层薄封装，或明确二者分工（Mediator 负责"同事"协作、Strategies 负责"选一个"）并在类注释写清差异，同时统一异常。
- **说明**：`CrcGf_test.cj:21-25` 与 `CrcEngine_test.cj:37-69` 各有一份逐位 CRC 参考实现，文件里已注明"不复用被测辅助函数，避免生成器自己证明自己"，属刻意独立，不计入重复。

### [轻微][存量] #17 未使用的 `import`（多处，证据等级"待确认"）

- **位置**：`f_util/src/MurmurHash3X128.cj:19-23`（`std.convert.*` 无可疑用法；`stdx.encoding.hex.*`、`fountain::f_data.DataParsable`、`fountain::f_util.exception.HashException` 全文件无引用，尤其 `HashException` 已 import 却一次都没抛）、`f_util/src/CityHash.cj:18/20`（`std.convert.*`、`fountain::f_data.*` 无引用）、`f_util/src/Factory.cj:20` 与 `f_util/src/StatePattern.cj:19`（`fountain::f_base.TypeInfos` 只 import 未用，两处都只用 `std.reflect.TypeInfo`）、`f_util/src/StrategyPattern.cj:18`（`ArrayList` 未用）
- **来源**：存量（快照模式无基线可比）
- **判据**：review-checklist §1「未使用的 import」
- **证据**：待确认 —— 逐个符号在本文件内搜索无引用；但仓颉的扩展方法可能靠 import 引入（`UInt64.readLittleEndian`、`Int64.toUInt`），未跑编译器的 unused 告警，因此不做"可删"结论，只记录。
- **描述**：`MurmurHash3X128.cj` 里 `HashException` 的"幽灵 import"值得注意：它暗示作者原本打算做入参/长度校验，但实现里没有任何校验分支。
- **建议**：跑一次 `cjpm build` 看 unused import 告警后统一清理；`MurmurHash3X128.cj` 若确实不需要 `HashException`，删掉 import，若要保留就把"seed 为 0 / 空输入"之类的契约写清。

### [轻微][存量] #18 `CrcEngine_test` 的吞吐用例会留下全局状态，且失败路径不回滚

- **位置**：`f_util/src/CrcEngine_test.cj:344-373`（`Crc64Hw.setNativeEnabled(false)` 后没有 `try/finally`，`370` 的 `@Fail` 会跳过 `367` 的恢复）、`477-524`（`env.setVariable("F_UTIL_CRC_HW", …)` 改写进程环境，`520-523` 有 finally 但其它用例仍可能读到）、`406-425`（每轮 `setNativeEnabled(true)/resetForTest()` 依赖前一轮成功）
- **来源**：存量（快照模式无基线可比）
- **判据**：review-checklist §10「可测试性」、§11「资源/状态不对称」
- **证据**：静态确定 —— `throughputCrc64SlicingAtLeastSixtyMegabytesPerSecond` 在 `351` 关闭硬件路径，只有顺序执行到 `367` 才恢复；一旦 `370` 的断言失败，后续所有 CRC-64 用例都会在"硬件被禁用"的状态下运行（对结果正确性影响不大，但会让 `crc64Hw*` 系列全部 SKIP，掩盖真实回归）。`env.setVariable` 修改的是进程级环境变量，与 `Crc64Hw` 的静态开关叠加，用例顺序会改变行为。
- **描述**：测试本身不影响生产，但这类"失败后污染后续用例"的写法会让性能门禁/硬件用例的失败难以定位。
- **建议**：所有 `setNativeEnabled` / `env.setVariable` 都放进 `try { … } finally { 恢复 }`；硬件用例统一用一个 `withNative(bool) { … }` 辅助函数；`Crc64Hw.resetForTest()` 在 `setUp/tearDown`（`@BeforeEach/@AfterEach`）里做，而不是散落在用例中。

### [轻微][存量] #19 注释/命名与实现不符（`semi` 示例、`Mediator` 的类型参数、`matches` 默认值）

- **位置**：`f_util/src/DiffieHellmanKeyExchanger.cj:37-47`（示例 `alice.semi(16)`，但 `54` 的签名是 `semi(gBytes!: Int32 = 16, pBytes!: Int32 = 16)`，命名参数不能按位置传）、`f_util/src/Mediator.cj:20`（`C` 类型参数在类体内零使用，只在 `where` 约束里出现）、`f_util/src/PathPattern.cj:434-441`（注释"不包含路径中的扩展名"，实现 `matches(path)` 调 `matches(path, true)`，即**包含**扩展名）、`f_util/src/StatePattern.cj:43`（`func startup<D>(): D` 遮蔽接口自身的 `D`，`TypeInfo.of<D>()` 打印的是方法类型参数，与外层 `prop data: D` 不是同一符号）
- **来源**：存量（快照模式无基线可比）
- **判据**：review-checklist §11「语义与注释不符」、§10「可读性」
- **证据**：静态确定 —— 四处都能直接对照；`semi` 的命名参数/位置参数规则见 `cangjie-docs/.../function/define_functions.md`（命名参数用 `!` 声明、调用必须带名）。
- **描述**：`startup<D>` 的类型参数遮蔽是四处里唯一有功能风险的：它让 `match (this.data) { case x: D => … }` 的类型判定依赖调用点的推断，而不是接口的 `D`；其余三处是文档/命名瑕疵。
- **建议**：`semi` 示例改成 `alice.semi()` 或 `alice.semi(gBytes: 16, pBytes: 16)`；`Mediator` 去掉未用的 `C`（或把它用在 `execute` 的返回类型上）；`matches` 的注释改成"包含扩展名"；`startup` 去掉方法级 `<D>`，直接用接口的 `D`。

### [轻微][存量] #20 本部分缺少关键用例：`murmurHash` / `cityHash` / `IdMaker` / `DiffieHellman*` 零测试

- **位置**：`f_util/src/MurmurHash3X128.cj:28`、`f_util/src/CityHash.cj:34`、`f_util/src/IdMaker.cj:23`、`f_util/src/DiffieHellmanKeyExchanger.cj:53-113`；对照：CRC/FNV/PathPattern 都有专门 `*_test.cj`
- **来源**：存量（快照模式无基线可比）
- **判据**：review-checklist §10「可测试性」；reviewer.md「发现的问题要能回答有什么用例覆盖」
- **证据**：静态确定 —— 本部分 19 个文件里 5 个是测试（`CaseFormat_test` / `CrcEngine_test` / `CrcGf_test` / `Fnv_test` / `PathPattern_test`），全仓 `*_test.cj` 中没有任何 `murmurHash` / `cityHash` / `IdMaker` / `DiffieHellman` 的引用。
- **描述**：`murmurHash` 是 f_codec/fdbm 的运行时依赖，`IdMaker` 是 fdbm 的主键生成器，两者都属于"错了上层只表现为偶发数据异常"的类型；#2、#3 能存活到现在，与"零黄金值用例"直接相关。
- **建议**：优先补三条：`murmurHash` 与独立实现的多长度对拍（含 `len % 16 == 8`、`len ≥ 32`）；`IdMaker` 同毫秒双实例唯一性 + 5000 次单调性；`PathPattern` 同层多正则的确定性（#8）。

## 优化可行性方案

> 以下都不是缺陷，是"修 #1/#2/#10 时顺手可做"的改进；全部**无性能基线**，因此只作为下一轮补数据的候选，不进 `tasks.md`。

### [CPU] O1 `murmurHash` 去掉每 16 字节的切片分配

- **现状**：`MurmurHash3X128.cj:39-43` 每处理一个 16 字节块就 `data[offset..offset+16]` 生成一个切片，再对它做两次 `readLittleEndian`；块数 = 输入长度 / 16，分配次数与输入大小线性相关。
- **方案**：改为直接在 `data` 上用 `UInt64.readLittleEndian(data[offset..offset + 8])`（或按字节组装），删掉中间 `blockSlice`；尾部同理。
- **预期**：每 MiB 少 65536 个切片对象；GC 次数与分配量下降（幅度未知）。
- **代价**：需确认 `readLittleEndian` 接受"从任意偏移开始的切片"且不复制（std 签名如此，但要在目标 SDK 上核对）。
- **验证**：`cjpm bench -O2` 对 1 MiB 输入跑修复前后各 10 轮，比中位数与四分位距；`cjprof heap` 看分配量。
- **证据状态**：无基线（待验证，不进 tasks）

### [CPU] O2 `PathPattern` 把匹配期扩容移出请求路径

- **现状**：`getPathNode` 在匹配线程上按 `parts.size` 懒建节点（`68-99`），首次访问某种深度的路径会在实例锁内 `add` + 回放 `originPatterns`（含正则替换与 `split`）。
- **方案**：启动期把所有已注册路由的段数预热好（`compile` 结束时按 `patterns.size` 补齐），匹配期只读；或把 `patterns` 换成 `Array<PathNode>` + 原子替换发布。
- **预期**：请求路径不再取锁、不再分配节点（收益取决于长路径请求占比）。
- **代价**：`compile` 后新增长度仍可能未命中，需要"未命中直接返回 `None`"的语义（不影响正确性，只是不再自动补节点）。
- **验证**：`cjprof` 跑 10 分钟路由压测，比较 `getPathNode` 的自耗时占比与锁等待时间；同时用 #10 的并发用例验证无竞态。
- **证据状态**：无基线（待验证，不进 tasks）

### [堆内存] O3 `Fnv.hash` 复用 `FnvCore`，避免每次调用 4 个数组

- **现状**：`Fnv.cj:53-56` 每次 `hash()` 都 `FnvCore.of(...)`，构造 `basis`、`state`、`scratchA`、`scratchB` 四个 `Array<UInt32>`（1024 位时各 32 个 limb，合计 512 B）+ 结果数组；`Fnv32/64/128/256/1024` 的每个入口都走这条路径（`84/92/104/112/124/133/142/…`）。
- **方案**：给 `FnvHasher` 增加"一次性算完但复用内部缓冲"的静态入口，或用 `ThreadLocal<FnvCore>`（`reset()` 已实现）复用 4 个数组；`Fnv64.fnv1a` 这类高频入口不再走 `Array<UInt64>` 中转。
- **预期**：单次哈希的堆分配从 5 个数组降到 0–1 个；对 f_jit 的常量指纹（每次编译大量调用）收益最明显。
- **代价**：`ThreadLocal` 常驻内存（每线程 ~512 B）；需保证 `reset()` 后 `basis` 不被改写。
- **验证**：`getAllocatedHeapSize()` 前后对照 + 10 万次 `Fnv64.fnv1a` 的 `cjpm bench -O2`。
- **证据状态**：无基线（待验证，不进 tasks）

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `CrcEngine.update` 每次调用 `acquireArrayRawData` 3/5/9 次（数据 + 2/4/8 张表）在小帧场景下开销显著，可能抵消切片收益 | `f_util/src/CrcEngine.cj:238-277`、`281-363`、`366-407` | 4 KiB 帧的单次 acquire/release 占比 | `cjprof record` 跑 f_protocol 帧校验场景（4 KiB × 10 万帧），看 `acquireArrayRawData` 自耗时；与"只在构造期 acquire、长期持表指针"版本对照 |
| 2 | `Fnv.update` 在逐字节循环里 `match (variant)` 分支，1024 位长输入是热点 | `f_util/src/Fnv.cj:314-325` | 自耗时占比、输入规模 | `cjpm bench -O2` 对 1 MiB × {FNV1, FNV1A} × {W64, W1024} 各 10 轮；再用 `cjprof` 看 `mulPrime` / `update` 占比 |
| 3 | `PathPattern.matches` 每请求都 `trimRedundantSlash` + `split` + 多次 `HashMap` 查找/正则匹配，是路由瓶颈 | `f_util/src/PathPattern.cj:477-491`、`174-179`、`627-634` | 端到端 P99 与 `matches` 自耗时 | 对 f_mvc 的 100 条路由、10 万次请求压测，`cjprof` 取 `PathPattern.get`/`matches` 自耗时；再与"预编译段数组"版本对照 |
| 4 | `murmurHash` 在 f_codec 序列化热路径上（每次编解码一次）的切片分配占 GC 压力的一部分 | `f_util/src/MurmurHash3X128.cj:39-43`；调用方 `f_codec/src/default/DefaultCodec.cj:87` | 分配量与 GC 次数 | 跑 f_codec 编解码基准（1 万对象），`cjprof heap` 比较修复前后 `getAllocatedHeapSize()` |
| 5 | `IdMaker` 的 CAS 在 fdbm 批量插入（单线程/多线程）下不构成瓶颈，但"每条需补 ID 的 INSERT 都 new IdMaker"会额外分配 | `f_util/src/IdMaker.cj:28-42`；`fdbm/src/execute/executors.cj:898` | 每语句分配对象数、插入吞吐 | 1 万条 INSERT 的分段计时 + 分配量埋点；修正 #3 后再测一次 |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_util/src/CaseFormat_test.cj` | .cj | ✅ | 6 种命名风格两两转换的断言；无语义问题，仅作为 CaseFormat 的覆盖证据（CaseFormat 本体属第 1 部分） |
| 2 | `f_util/src/CityHash.cj` | .cj | ✅ | 见 #1（三条崩溃/碰撞）、#14（死代码）、#17（未用 import） |
| 3 | `f_util/src/CrcEngine.cj` | .cj | ✅ | 表驱动 + slicing-by-2/4/8 + 裸指针路径；宽度/位宽分派正确，原始指针全部 `try/finally` 配对；未发现缺陷，性能见待验证 #1 |
| 4 | `f_util/src/CrcEngine_test.cj` | .cj | ✅ | 逐位参考实现 + 24 个 CRC-16/6 个 CRC-64 对拍 + 吞吐门禁；见 #18（状态回滚） |
| 5 | `f_util/src/CrcGf.cj` | .cj | ✅ | 构造期常量推导；`barrettMu` / `xPowModP` / 三套常量布局均被 native 核与测试使用，无死代码；仅 `135` 行两条语句挤一行（格式） |
| 6 | `f_util/src/CrcGf_test.cj` | .cj | ✅ | 独立参考实现对拍 + Barrett 约减长除法校验；但 `refBarrettMuLow`/`refMod128` 与被测实现同构（见 #15）；`refCrc64*` 与 `CrcEngine_test.refUpdate` 的重复属刻意独立（见 #16 说明） |
| 7 | `f_util/src/DiffieHellmanKeyExchanger.cj` | .cj | ✅ | 见 #4（共享密钥无效）、#5（死循环）、#19（示例与签名不符） |
| 8 | `f_util/src/Factory.cj` | .cj | ✅ | 见 #13（缺失键异常）、#17（未用 import）；`Producer` 的默认 `throw IllegalAccessException("unimplemented")` 属模板方法设计，未单列缺陷（见 §3 自检说明） |
| 9 | `f_util/src/Fnv.cj` | .cj | ✅ | 5 宽度 × 2 变体共用 `FnvCore`；limb 拼装/素数分解乘法与官方基值一致（测试有黄金值）；分配见优化 O3 |
| 10 | `f_util/src/Fnv_test.cj` | .cj | ✅ | 覆盖空串基值、已知向量、1024 位进位、增量/分块不变性；质量良好，未发现问题 |
| 11 | `f_util/src/IdMaker.cj` | .cj | ✅ | 见 #3（位布局 + 同毫秒重复 + 序号溢出）、#20（无用例） |
| 12 | `f_util/src/IsUUID.cj` | .cj | ✅ | 注解 + `UUID.tryParse`；`None → false` 正确，无空实现 |
| 13 | `f_util/src/Mediator.cj` | .cj | ✅ | 见 #7（静默覆盖）、#13（NoneValueException）、#16（与 Strategies 重复）、#19（未用类型参数） |
| 14 | `f_util/src/MurmurHash3X128.cj` | .cj | ✅ | 见 #2（丢字节/重复混合）、#17（未用 import）、#20（无用例）；`rotl64` 调用常量非 0，无移位 UB |
| 15 | `f_util/src/PathPattern.cj` | .cj | ✅ | 见 #6–#10、#14、#16、#19；核心状态机（`254-432`）的 `i -= 2` 回溯未发现可静态证明的负索引路径，标 `待确认`，未计入发现 |
| 16 | `f_util/src/PathPattern_test.cj` | .cj | ✅ | 22 个用例覆盖单/双星、`?`、复杂段、双星多级、前缀；**未覆盖**同层多正则的确定性（#8）与 `{*name}`（#6） |
| 17 | `f_util/src/ResposibilityChain.cj` | .cj | ✅ | 见 #12（空默认实现）；`execute` 抛异常语义有注释说明，正常 |
| 18 | `f_util/src/StatePattern.cj` | .cj | ✅ | 见 #11（无界递归）、#19（类型参数遮蔽）、#17（未用 import） |
| 19 | `f_util/src/StrategyPattern.cj` | .cj | ✅ | 见 #7（静默覆盖）、#16、#17（`ArrayList` 未用）；`execute` 的缺失键处理是三者中最规范的 |

合计：`.cj` 19 个 / `.md` 0 个 / 共 19 个，全部读完。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 5（#1–#5） | 另 #11–#13、#19 属正确性/可读性；语言特性方面核对了单引号字符串（`strings.md:9`）、返回类型推导（`define_functions.md:85-95`）、`as` 返回 `Option`（`typecast.md:54`），未发现误用 |
| §1 死代码 | 1（#14） | 已逐个 `private` / 内部类型成员全仓搜引用（`mur`、`rotate32`、`PathNode` 的 5 个 `init`、`data(Any)`、`Option.matches`、`Mode.matching`）；`public` 顶层 API 不判（`DiffieHellman*`、`Mediator`、`Strategies`、`cityHash` 仓内零引用只作信息）；接口实现/父类覆盖不判 |
| §2 重复逻辑 | 2（#15、#16） | 已把 19 个文件的函数体按"输入→输出→副作用"两两比对：`hashLen16`/`hashLen16Minimal`、`pretreat`/`trimRedundantSlash`、`Mediator`/`Strategies` 三组重复（#16），以及测试侧 `refBarrettMuLow`/`refMod128` 与被测实现同构（#15）；CRC 逐位参考实现（`refCrc64*` 与 `CrcEngine_test.refUpdate`）属刻意独立，不计 |
| §3 空实现 | 1（#12） | `ValidationResponsibility.execute` 空体；`Producer.produce` 默认抛异常（非空实现，但把编译期问题推到运行期，已在 #13 一并记录）；`IsUUID`、`State.continues` 的默认实现有语义、非空 |
| §4 栈溢出 | 1（#11） | `State.startup` 递归无上限、无环检测；`PathPattern` 的正则/复杂段匹配是循环不是递归；`Fnv`/`CRC` 无递归 |
| §5 OOM | 0 | 无"按报文长度预分配"；`PathPattern.patterns` 只按路径段数增长（有界于 URL 长度），已并入 #10 的锁粒度描述；`Fnv`/`CRC` 的临时数组是常量大小 |
| §6.1 热点瓶颈 | 0 | 未提供 `cjprof` / `bench` 数据，`CrcEngine` 注释里的 51–58 MB/s 是历史测量但非本轮可得基线；全部转「待验证假设」1–5 |
| §6.2 大粒度锁 | 0 | `PathPattern` 的锁只在编译/首次建节点时持有，临界区含正则替换属"冷路径"；竞争频率与持有时长无数据，见 #10 与待验证 #3 |
| §6.3 并发串行 | 0 | 无 `spawn` + 立即 `get()`；`Crc64Hw` 的硬件路径是单线程计算（第 1 部分文件，未展开） |
| §6.4 低效算法 | 0 | 未发现"`remove(at:0)` 当队列 / 热点 `contains` / 循环拼串"；`getRegexNode` 的线性扫描规模是"同层路由数"，量级小，未定为缺陷 |
| §7 降堆内存方案 | 1（O3） | 另有 O1 的切片分配；均无基线，只列方案 |
| §8 降 CPU 方案 | 2（O1、O2） | 无基线，只列方案；热点结论全部在「待验证假设」 |
| §9 local mode 可行性 | 0 | 本部分没有"函数内创建、函数内销毁"的大对象图：`FnvCore` 会逃逸到 `FnvHasher`，`PathPattern` 节点长期存活，`CrcEngine` 的临时量是标量；且 `String.split`/`Regex.replaceAll` 无 mode 重载，改造被 checklist §9 约束 3 卡住。收益只能用峰值内存证明，当前无数据 |
| §11 现有代码的 BUG（存量） | 12 | #1–#5（崩溃/错误结果/死循环）、#6–#10、#13、#19 中的功能项；每个读到的函数都过了边界/空值/错误处理/契约四项 |
| §12 并发安全与锁粒度 | 1（#10） | 逐项核对：`IdMaker` 用 `AtomicInt64`（但语义错，见 #3）、`CrcEngine` 构造后不可变、`Fnv.hash` 全局部量、`FnvHasher` 可变但属"每线程一个"用法、`Mediator`/`Strategies`/`PathPattern.patterns` 均为启动期写 + 运行期读（`PathPattern` 例外，已列 #10）；`Mutex` 为可重入锁（`sync_package_overview.md:137`），`doCompile → getPathNode → populateNode` 的嵌套 `synchronized` 不会自锁 |
| §14 功能完备性与 README 覆盖 | 0 | 本部分不含 README/`doc/**`（由其它部分覆盖）；就代码侧：`{*name}` 的归一化只在 `compileIfAbsent` 生效（已列 #6），`DiffieHellman` 的 `semi`/`finish`/`key` 三入口都已接线、但语义不可用（#4）；`randomByteLen`（`DiffieHellmanKeyExchanger.cj:106-113`）仓内零引用，属对外 API 不作死代码判定 |
| 文件覆盖（§13 等） | 19/19 | 无缺文件；本部分 0 个 `.md`，`§13` 文档一致性留给含 README 的部分 |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 5 |
| 一般 | 8 |
| 轻微 | 7 |
| 优化方案（堆内存 / CPU） | 1 / 2 |

## 总评

本部分代码质量分化非常明显，不能一概而论：

- **CRC 子系统（`CrcEngine` / `CrcGf` + 测试）是全仓标杆**：表驱动与 slicing-by-2/4/8 的分派条件清晰、裸指针路径每个出口都配对 `releaseArrayRawData`、测试用独立逐位实现对拍而不是"自己跟自己比"，还带 `F_UTIL_PERF` 门控的吞吐下限。唯一的问题是吞吐用例的全局状态回滚（#18，轻微）。
- **`Fnv` 与 `PathPattern`**：`Fnv` 的实现与黄金值测试扎实（#20 的缺失用例不含它）；`PathPattern` 功能覆盖很广、测试也密，但有三类结构性问题——入口不一致（#6）、注册冲突静默覆盖（#7）、候选顺序不确定（#8），再加上正则锚点（#9）和匹配期写共享容器（#10）。建议把 #6–#9 作为一组一起修（都落在"编译/定序"阶段），#10 单独作为并发改造。
- **四个"对外可用但实际不可用"的 API 是本轮最该先处理的风险**：`cityHash`（#1，短串必崩、长串死循环）、`murmurHash`（#2，≥32 字节丢字节，已被 f_codec 当类型键用）、`IdMaker`（#3，同毫秒重复主键，已被 fdbm 每语句构造）、`DiffieHellmanKeyExchanger`（#4/#5，密钥算不对 + 对端可控死循环）。这四条都是"能编译、能调用、结果错/挂死"的类型，且全部没有用例兜底（#20），优先级应高于任何性能优化。
- **设计模式骨架（`Factory` / `Mediator` / `Strategies` / `ResponsibilityChain` / `State`）**：作为库的扩展点基本可用，但错误口径不统一（#13）、同名注册静默覆盖（#7）、校验接口有空默认实现（#12）、状态机递归无上限（#11）。这些不是当前阻塞项，但会在下游接入时放大成"配错不报错"。

**存量缺陷共 20 条（严重 5 / 一般 8 / 轻微 7），按规则只报不修，是否纳入修复由用户决定**；其中 #1–#5 建议作为第一批。#1–#3 与 #4/#5 的修复都必须同时补上 #20 的黄金值用例，否则同样的缺陷会在下一次重构里复现。性能类结论全部停留在「待验证假设」，本部分没有任何可复核的 benchmark 数据，因此没有一条 CPU/内存收益被写成结论。
