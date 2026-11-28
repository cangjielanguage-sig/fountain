# f_bloom 模块审查报告

- **审查日期**：2026-11-28
- **模块路径**：`f_bloom`（1 个源文件，`src/BloomFilter.cj` 共 270 行）
- **基线**：工作区快照（sts/1.3.x 工作区，未对照远端目标分支；本报告全部问题来源记为「存量」）
- **审查重点**：正确性、死代码、重复逻辑、空实现、并发安全、存量 BUG、README 覆盖率（通用维度 + 全部专项扫）
- **报告版本**：v1

## 发现

### [严重][存量] `n = 0` 时位数组长度为 0，`add` / `mightContain` 必然取模除零崩溃

- **位置**：`f_bloom/src/BloomFilter.cj:41`（`new(n, p)`）、`:55`（`init`）、`:64`、`:89`、`:114`
- **来源**：存量（快照模式无基线；`git blame -L 55,80` 显示 `4be871f2f` 之前已存在，`a8ce09072` 追加序列化未触碰该路径）
- **判据**：review-checklist §11（边界 / 除零）、§1（构造参数域未校验导致不可用对象）
- **证据**：静态确定 —— `makeM(0, p) = ceil(-(0 * log p) / ln2²) = 0`，故 `size = 0`、`arraySize = (0+63)/64 = 0`、`bitSet` 为空数组；随后 `add`/`mightContain` 执行 `h(element) % UInt64(size)` 即 `% 0`，仓颉整数取模零抛 `ArithmeticException`。全部推导只需 `makeM` 的算式（`:73-75`）与取模语句（`:89`、`:114`），不依赖输入数据。
- **描述**：`new(n, p)` / `new(n, p, seeds)` 对 `n` 没有任何校验，`n = 0` 会得到一个“构造成功但任何查询都抛异常”的对象。仓内存在真实调用点：`f_store/src/SSTable.cj:425` 在 Bloom Block 长度为 0 时兜底 `BloomFilter.new(0, 0.01)`，该过滤器随后在 `f_store/src/LevelManager.cj:109` 的读路径被 `mightContain(key.bytes)` 调用 —— 也就是说“旧格式 / footer 损坏的 SSTable”这条降级路径会把读请求变成异常，而不是“Bloom 恒为 false 的保守退化”。另外 `makeK(0, 0)` 走 `Float64(0)/Float64(0)` = NaN 再 `Int64(math.ceil(NaN))`（`:70-72`、`:76-78`），`k` 取值未定义；即便 k 恰好为 0，也不改变 `size = 0` 的结论。
- **建议**：`new` / `init` 入口校验 `n >= 1`，非法抛 `IllegalArgumentException`；同时给 `m` 与 `k` 加下限（如 `size = max(m, 64)`、`k >= 1`），让退化输入得到“恒 false 的过滤器”而不是异常。调用方 `f_store/src/SSTable.cj:425` 的空 Bloom Block 分支应改传 `n = 1`（与 `deserialize` 内部兜底一致）。README 需补一条约束：`n` 必须 ≥ 1。

### [严重][存量] `deserialize` 完全信任头部长度字段，可致巨量预分配（OOM）、越界异常，并与其 README 契约相反

- **位置**：`f_bloom/src/BloomFilter.cj:176`（入口）、`:184`（`Array<UInt64>(seedCount, ...)`）、`:186-189`（读 seeds）、`:190-196`（`bitCount` / 长度检查）、`:199-204`（按 `wordCount` 写 `bitSet`）
- **来源**：存量（`git blame -L 176,206` 全部落在 `a8ce09072 feat(f_bloom): add BloomFilter serialize/deserialize`）
- **判据**：review-checklist §5（按不可信长度预分配）、§11（越界 / 契约不符）、§13（README:63 承诺“越界不抛异常”）
- **证据**：静态确定 —— 入口只校验 `bytes.size < 24`（`:177`），之后 `seedCount = readInt64LE(bytes, 16)` 直接用作数组长度（`:183-184`），没有上限也没有与 `bytes.size` 的交叉校验；`bitCount` 只用于算 `wordCount`（`:192`），而重建实例的位数组容量由 `makeM(n, p)` 决定（`:199`），`wordCount` 与 `filter.bitSet.size` 之间**没有任何比较**，`:203` 直接 `filter.bitSet[i].store(...)`。
- **描述**：四条独立后果，同一根因（头部字段无校验）：
  1. `seedCount = 1e9` → `Array<UInt64>(1e9, repeat: 0)` 先申请 8 GB，晚于长度检查、早于任何越界发现 → OOM；
  2. `seedCount` 为负 → 负数长度数组异常；`seedCount` 大于实际字节数 → `readUInt64LE(bytes, off)` 越界读（`:187`）——这两条都不走 `:178`/`:195` 的兜底；
  3. 构造 104 字节的合法长度载荷（`n=1, p=0.01, seedCount=7, bitCount=128`）即可让 `wordCount = 2 > bitSet.size = 1` → `:203` 数组越界抛异常；`bitCount` 接近 `Int64.Max` 时 `bitCount + 63`（`:192`）与 `off + wordCount * 8`（`:194`）还会整数溢出（本文件其他地方用 `@OverflowWrapping` 挡住溢出，这两处没有）；
  4. 反之 `bitCount` 偏小 → `wordCount < bitSet.size`，尾部 word 保持 0，反序列化“成功”但已写入的元素全部查不到（静默假阴性，且没有任何告警）。
  README（`README.md:63` / `README_en.md:63`）明确承诺“数据长度不足或位数组越界时返回 `BloomFilter.new(1, 0.01)`，不抛异常”，实现只能覆盖“总长 < 24”与“bit 区字节不够”两种，越界写与巨量分配都不在覆盖范围内，属于契约与实现相反。
- **建议**：`deserialize` 改成分步校验，任一步失败返回 `None`（或抛明确异常）而不是静默给默认值：① `seedCount ∈ [1, kMax]` 且 `24 + seedCount*8 + 8 <= bytes.size`；② `bitCount == makeM(n, p)`（或干脆按 `bitCount` 建位数组，别重算），不等即判损坏；③ 所有偏移用 `UInt64` 或 `@OverflowWrapping` 计算后再判上界；④ 格式加 magic + version，便于后续兼容判断。同步修 README:63 的承诺。

### [一般][存量] 误判率 `p` 与 `seeds` 数量未校验：inf / NaN 尺寸或“空转过滤器”静默失效

- **位置**：`f_bloom/src/BloomFilter.cj:41-54`、`:70-78`、`:50-54`（`seeds` 直接当 k 用）
- **来源**：存量（`git blame -L 41,54` → `4be871f2f`）
- **判据**：review-checklist §11（边界 / 空值）、§3（静默失效）
- **证据**：静态确定 —— `p <= 0` 时 `math.log(p)` 为 `-inf` / `NaN`，`makeM` 得 `+inf` 或 `NaN`，`ceilToInt64`（`:70-72`）把非有限值转 `Int64` 属未定义/异常路径，但 `p` 没有任何前置校验；`p >= 1` 时 `m = 0`、`k = 0`；`new(n, p, seeds)` 直接用 `seeds.size` 作哈希函数个数，传空数组即 `k = 0`。
- **描述**：`p = 1.0` 或 `seeds` 为空时 `hashers` 为空数组，`add` 的循环体一次都不执行（空操作），`mightContain` 直接 `return true` —— 对象“能构造、能调用、结果恒定”，调用方（例如把它接到 `f_store` 的读路径上）会以为自己在用过滤器。`p <= 0` / `p > 1` 则走向 `inf`/`NaN` 尺寸，实际表现取决于浮点转整数的未定义行为，可能构造期抛异常也可能得到一个尺寸离谱的位数组。README 只在参数表里写了 `0 < p < 1`（`README.md:23`），没有说违反会怎样，也没说 `seeds` 的数量决定 k、传错数量会让实际误判率偏离 `p`。
- **建议**：构造入口断言 `0.0 < p < 1.0` 且 `!seeds.isEmpty()`，非法直接抛；`new(n, p, seeds)` 的文档补一句“`seeds.size` 即哈希函数个数 k，与 `p` 推算出的最优 k 不一致时实际误判率会偏离 `p`”。

### [一般][存量] `deserialize` 静默兜底无日志、返回值不可区分，损坏数据在调用方不可观测

- **位置**：`f_bloom/src/BloomFilter.cj:177-179`、`:194-196`
- **来源**：存量（`a8ce09072`）
- **判据**：review-checklist §3（`Result` / 失败被丢弃、静默兜底）、§14（契约表达力）
- **证据**：静态确定 —— 两处 `return BloomFilter.new(1, 0.01)` 无日志、无计数器，返回类型 `BloomFilter` 无法表达“解析失败”。
- **描述**：损坏的 Bloom 数据会被还原成一个“合法但全空”的过滤器：此后 `mightContain` 恒 `false`，`f_store` 的 SSTable 读路径退化为“每次都读数据块”，读放大回升且没有任何痕迹可查。这类静默降级在线上只能通过“性能莫名变差”间接发现。
- **建议**：`deserialize` 返回 `Option<BloomFilter>`（或 `(BloomFilter, Bool)`），由调用方决定兜底与日志；若要保持签名，至少接入 `f_log` 打一条 warn 并带 `bytes.size` 与实际消耗长度。注意这会改变对外契约，需与 `f_store/src/SSTable.cj:423` 同步。

### [一般][存量] README 中英两版把布隆过滤器的保证写反，与同段“存在误判”自相矛盾

- **位置**：`f_bloom/README.md:14`、`f_bloom/README_en.md:14`
- **来源**：存量（文档随 `a8ce09072` 一并提交）
- **判据**：review-checklist §13（文档承诺与实现相反）
- **证据**：静态确定 —— 文档写“如果元素不存在，一定返回 false；如果存在，可能返回 true（假阳性）”；实现 `mightContain`（`BloomFilter.cj:112-124`）是标准布隆语义：**不存在时可能误判为 true，存在时一定 true（无假阴性）**。同一段标题又写“**可能存在误判**”，前后不一致。
- **描述**：这句把“无假阴性”和“有假阳性”整个说反了。按字面理解，使用者会认为 `mightContain == false` 只是“可能不存在”，从而放弃唯一正确的用法（`false` 才能作为“一定不存在”的判据），把它当近似精确集合使用。`README_en.md:14` 同样错译（"if the element does not exist, it always returns false"）。
- **建议**：改为“`mightContain` 返回 `false` 表示元素一定不存在；返回 `true` 表示可能存在（假阳性率 ≤ p）”，中英同步。

### [轻微][存量] `init` 对位数组做了两遍初始化，第二遍是纯冗余分配

- **位置**：`f_bloom/src/BloomFilter.cj:65-68`
- **来源**：存量（`4be871f2f`）
- **判据**：review-checklist §1（冗余语句 / 无用赋值）
- **证据**：静态确定 —— `:65` 的数组构造器已为每个槽位创建 `AtomicUInt64(0)`，`:66-68` 的循环再把每个槽位替换成**新建**的 `AtomicUInt64(0)`，第一遍创建的对象全部变垃圾。
- **描述**：`arraySize` 次多余对象分配（1M 元素 / p=1% 时约 15 万个 `AtomicUInt64` 立即成为垃圾），只在构造期发生一次，无功能影响，但会放大启动期的 GC 压力，也让读者误以为构造器不初始化元素。
- **建议**：删掉 `:66-68` 整个循环。

### [轻微][存量] 四个 8 字节小端读写函数逐行重复，且标准库已有同类能力

- **位置**：`f_bloom/src/BloomFilter.cj:210-235`（`writeInt64LE` / `writeUInt64LE`）、`:246-269`（`readInt64LE` / `readUInt64LE`）
- **来源**：存量（`a8ce09072`）
- **判据**：review-checklist §2（只改类型名的重复实现）
- **证据**：静态确定 —— `writeInt64LE` 与 `writeUInt64LE` 除 `value.toUInt()`（`:212`）外 8 行逐字相同；`readInt64LE` 与 `readUInt64LE` 除末尾 `.toInt()`（`:256`）外完全相同。同仓 `f_util/src/MurmurHash3X128.cj:42` 已用 `UInt64.readLittleEndian(blockSlice[0..8])` + `import std.binary.LittleEndianOrder` 达到同样效果。
- **描述**：两份 8 行展开的移位代码，任何一处改动（例如改成大端或加边界检查）都要同步四处，容易漂移。`Float64` 分支（`:237-244`）已经用标准库 `writeLittleEndian`，与整数分支风格不一致。
- **建议**：只保留 `readUInt64LE` / `writeUInt64LE`，有符号版本调用它们后 `.toInt()`；或直接改用 `std.binary` 的 `Int64/UInt64.readLittleEndian` / `writeLittleEndian`（本文件已 `import std.binary.*`），只保留偏移推进逻辑。

### [轻微][存量] 私有字段 `size` 与公开属性 `bitCount` 语义重复，且 `serialize` 内局部变量遮蔽同名属性

- **位置**：`f_bloom/src/BloomFilter.cj:27`、`:31-35`、`:146`
- **来源**：存量（`4be871f2f` / `a8ce09072`）
- **判据**：review-checklist §10（命名 / 可读性）
- **证据**：静态确定 —— `bitCount` 的 getter 只是 `size`（`:33`），两处维护同一含义；`serialize` 内 `let bitCount = this.size`（`:146`）又与属性同名。
- **描述**：`size` 读起来像“字节数”或“元素数”，实际是位长度；与同类的 `n`（预期元素数）并排时极易误读。冗余的别名层没有带来封装收益（没有 setter、没有派生计算）。
- **建议**：字段直接命名 `bitCount` 并 `public let`（或保留私有名 `bitCount` 去掉属性），`serialize` 内改用 `this.bitCount`，不再引入同名局部变量。

### [轻微][存量] `hashableToBytes` 未按同文件惯例加 `& 0xFF` 掩码，依赖窄化转换截断

- **位置**：`f_bloom/src/BloomFilter.cj:107`（对比 `:213-220`、`:226-233`）
- **来源**：存量（`4be871f2f`）
- **判据**：review-checklist §10（可读性 / 一致性）、§11（`待确认`：窄化转换语义）
- **证据**：待确认 —— `UInt8((h >> ((7 - i) * 8)).toUInt())` 未掩码，而同一文件所有 `UInt8(...)` 都写成 `UInt8(x & 0xFFu64)`；若仓颉 `UInt64 -> UInt8` 的显式转换在越界时截断则行为正确（缺少的是显式意图），若抛异常则 `Hashable` 重载对所有 8 字节序列都会崩。缺少的信息：`cangjie-doc-lookup` 对整数窄化转换越界语义的确认（本轮无本地文档可用）。
- **描述**：两种写法混用使读者无法判断作者是否知道 `toUInt()` 后仍有 56 位在高位；一旦上层把 `h` 的字节序或宽度调整，这里会静默出错（或直接崩）。
- **建议**：改为 `UInt8((h >> ((7 - i) * 8)).toUInt() & 0xFF)`，与同文件其余位置一致；或统一改走 `writeUInt64LE` 复用同一段逻辑。

### [轻微][存量] `ToString` / `Hashable` 两个重载缺少语义约束：可能重载歧义，且依赖不稳定的字符串表示

- **位置**：`f_bloom/src/BloomFilter.cj:99-104`、`:128-133`
- **来源**：存量（`4be871f2f`）
- **判据**：review-checklist §10（API 设计 / 语言特性）、§13（文档未约束用法）
- **证据**：待确认 —— 需要编译验证两点：① 某类型同时实现 `ToString` 与 `Hashable` 时，`filter.add(x)` 的两个候选互不为子类型，仓颉重载决议应报歧义（README:64 只提示“不要混用重载”，没提这种编译错误）；② 类未重写 `toString()` 时默认实现是否含对象哈希/地址（若是，`add(ToString)` 写入的值跨进程不可复现，持久化后必然查不到）。
- **描述**：四个重载里有两个基于接口，参数类型覆盖面重叠；`Array<Byte>`/`String` 是精确匹配，风险集中在用户自定义类型。README 只按“判定口径不同”解释，没有给出“该用哪个重载”的选择规则，也没有提示 `ToString` 依赖用户实现的稳定性。
- **建议**：文档补一节“重载选择规则”：优先 `Array<Byte>`（自己控制编码）；需要与对象生命周期解耦时用 `Hashable`；`ToString` 仅用于已重写且输出稳定的类型；同时说明同时实现两个接口时需显式转型选择重载。

### [轻微][存量] README 示例里的 `k` 是未定义符号，示例不能直接编译

- **位置**：`f_bloom/README.md:34`、`f_bloom/README_en.md:34`
- **来源**：存量（`a8ce09072`）
- **判据**：review-checklist §13（示例代码不能用）
- **证据**：静态确定 —— `let seeds = Array<UInt64>(k){i => ... }` 中 `k` 在该片段内无定义，`...` 也不是合法仓颉表达式；实现里 `k` 只是 `seeds.size`（`BloomFilter.cj:59`），没有公开的 `k` 访问器（只有 `seeds` 迭代器与 `bitCount`）。
- **描述**：使用者复制这段会直接编译失败，且无从得知“k 应该取多少”。这是模块唯一一处“自定义种子”的用法示例，缺失会把人推向 `new(n, p)` 的随机种子（跨进程不一致）。
- **建议**：改成可编译的示例，例如 `let seeds = Array<UInt64>(7) { i => UInt64(i) * 0x9E3779B97F4A7C15 }`，并说明个数即 k（p=1% 时约 7），分布式/持久化场景必须固定。

## 优化可行性方案

> 以下均无改前基线数据，按规则只作「待验证」，不进修复清单。

### [堆内存] `Hashable` 重载每次调用分配 8 字节临时数组

- **现状**：`hashableToBytes`（`BloomFilter.cj:105-108`）每次 `add` / `mightContain` 都 `Array<Byte>(8)` 新建一个对象；调用一次 = 1 次分配，k 次哈希复用同一数组（不重复分配）。
- **方案**：把 8 字节 `hashCode()` 直接喂给哈希函数（如 `wyhash` 的 `Array<UInt8>` 重载换成对 `(UInt64, seed)` 的混合函数，或复用线程内固定缓冲）。
- **预期**：每调用少 1 个 8 字节数组对象（含对象头约 32 字节）。仓内 `f_store` 读路径用的是 `Array<Byte>` 重载（`LevelManager.cj:109`），此重载暂无热调用方，收益无法量化。
- **代价**：需要新增一个“按 8 字节整数哈希”的入口，或引入可变缓冲（并发下必须是线程封闭的），语义边界要保证与现有实现完全等价。
- **验证**：`cjpm bench -O2` 对 1e6 次 `add(Hashable)` 取中位数，对比分配次数（`getAllocatedHeapSize()`）。
- **证据状态**：无基线（待验证，不进 tasks）

### [CPU] `hashers` 用闭包间接调用，可改为种子数组 + 直接调用

- **现状**：`hashers: Array<(UInt64, (Array<Byte>) -> UInt64)>`（`:28`、`:59-62`），每次 `add`/`mightContain` 对 k 个元素做 `for ((_, h) in hashers)` 的元组解构 + 间接调用（`:88`、`:113`）；p=1% 时 k=7，即每元素 7 次间接跳转。
- **方案**：存 `Array<UInt64> seeds`，循环里直接 `wyhash(bytes, see: seeds[i])`，把 `seeds` 迭代器与序列化都改为读该数组（同时消掉 `serialize` 里的 `seedsArr` 中转，`:141-144`）。
- **预期**：去掉 k 次闭包间接调用与元组解构；量级未知，需 profile 判断在端到端读路径中的占比。
- **代价**：`hashers` 字段语义变化（内部私有，影响面仅本文件）；`seeds` 属性改为对数组的 `iterator().map`，行为不变。
- **验证**：`cjprof record` 跑 `f_store` 读基准（10 万次 get，1% 不存在的 key），看 `BloomFilter::add`/`mightContain` 自耗时占比；`cjpm bench -O2` 前后对照，取中位数与离散度。
- **证据状态**：无基线（待验证，不进 tasks）

### [堆内存] 每个 64 位字一个 `AtomicUInt64` 对象，位数组有固定对象头开销

- **现状**：`bitSet: Array<AtomicUInt64>`（`:26`、`:65`），每 64 位一个引用型原子对象；n=1e6、p=1% 时 m≈9.6e6 位 ≈ 15 万 word，载荷 1.2 MB，对象头与引用额外占约 1.2-2.4 MB（估算，未实测）。
- **方案**：仅当有实测证据表明这部分内存占比显著时，再评估改用「连续 `Array<Int64>` + `unsafe` FFI 原子操作」或分片 + 普通数组；`std.sync` 目前只提供引用型原子类型，短期无零成本替代。
- **预期**：位数组内存最多可降约 50%（估算，未实测）；不改变查询语义。
- **代价**：FFI 原子操作、平台差异、`unsafe` 代码，且不能为了省内存牺牲无锁写语义（README:15 的并发承诺）。
- **验证**：`getAllocatedHeapSize()` / RSS 对比同规模过滤器的峰值与稳态，另跑多线程 `add` + `mightContain` 压测确认无回归。
- **证据状态**：无基线（待验证，不进 tasks）

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `mightContain` 是 `f_store` 读路径热点（每读一次 key 都调用） | `f_bloom/src/BloomFilter.cj:112`；调用方 `f_store/src/LevelManager.cj:109` | 自耗时占比、调用次数 | `cjprof record` 跑 `f_store` 读基准（10 万次 get，1% 不命中），按函数看 self time |
| 2 | 每次调用 7 次 `wyhash`（对短 key 全量扫描）是 CPU 主要成本 | `f_bloom/src/BloomFilter.cj:88`、`:113` | 单次 `wyhash` 耗时与 k 的关系 | 分段计时：固定 k 从 1 到 10，测 1e6 次 `mightContain` 的中位数 |
| 3 | 构造期 15 万个 `AtomicUInt64`（含重复初始化）放大启动期 GC | `f_bloom/src/BloomFilter.cj:65-68` | 构造耗时、分配量 | `cjpm bench -O2` 建 1e6/1% 过滤器 100 次，测耗时与 `getAllocatedHeapSize()` |

## 文件覆盖

> 与 `reviews/202611280854_full-repo/files/f_bloom.txt` 一一对应。

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_bloom/README.md` | .md | ✅ | 与实现基本一致；§14 公开成员全覆盖；见发现「README 保证写反」「示例 k 未定义」「deserialize 兜底承诺不符」 |
| 2 | `f_bloom/README_en.md` | .md | ✅ | 与中文版同构，同样存在保证写反与示例 `k` 未定义问题；无整节缺失 |
| 3 | `f_bloom/src/BloomFilter.cj` | .cj | ✅ | 270 行全读；并发写读用 `AtomicUInt64`，无递归、无全局状态，无锁粒度问题；缺陷集中在参数校验与 `deserialize` |

合计：`.cj` 1 个 / `.md` 2 个 / 共 3 个，全部读完。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 6 | 严重 2（n=0 除零、deserialize 头部无校验）+ 一般 1（p/seeds 域）+ 轻微 3（size/bitCount 命名、掩码不一致、重载语义）；无外部输入拼接、无凭据、无日志泄露 |
| §1 死代码 | 1 | 已逐个检查 12 个 private 符号（`bitSet`/`size`/`hashers`/`hashableToBytes`/`ceilToInt64`/`makeM`/`makeK`/`writeFloat64LE` 与三个整型读写）及私有 `init`，均有引用；`new(n,p)`/`new(n,p,seeds)`/`seeds`/`bitCount` 为对外可达 public，不判；命中项为 `init` 内第二遍冗余初始化（`:66-68`） |
| §2 重复逻辑 | 1 | 已两两比对全部 23 个函数体的「输入-输出-副作用」；`writeInt64LE`/`writeUInt64LE`、`readInt64LE`/`readUInt64LE` 仅差类型转换，合并为 1 条；`add` 与 `mightContain` 循环结构相同但语义（写 vs 读并提前返回）不同，不算重复；两版 README 属翻译对应，不算重复 |
| §3 空实现 | 1 | 无空函数体、无 TODO/FIXME、无 `catch {}`；命中项为两处 `return BloomFilter.new(1, 0.01)` 静默兜底（`:178`、`:195`），无日志且返回值不可区分 |
| §4 栈溢出 | 0 | 全文件无递归（无自调用、无相互调用）；数组遍历深度固定为 k 与 wordCount，无用户可控递归 |
| §5 OOM | 1 | 命中并已并入严重项：`Array<UInt64>(seedCount)`（`:184`）长度来自数据；`m` 由 `n` 推算，`n` 大时构造即巨量分配，属调用方职责，未单列 |
| §6.1 热点瓶颈 | 0 | 本轮无 profile / bench 数据，`f_store` 读路径上的调用只算线索；已列入「待验证假设」#1-#3，不参与统计 |
| §6.2 大粒度锁 | 0 | 全文件无 `synchronized`、无 `Mutex`、无锁对象；位操作走 `AtomicUInt64` 单字原子，不存在临界区 |
| §6.3 并发串行 | 0 | 无 `spawn`、无 `Future`、无并发容器、无批处理/队列，不存在串行段 |
| §6.4 低效算法 | 0 | `add`/`mightContain` 为 O(k) 定长循环，无嵌套循环、无 `contains`、无字符串拼接；k 次哈希是布隆过滤器的必需成本，非低效实现 |
| §7 降堆内存方案 | 2 | `Hashable` 重载 8 字节临时数组、`AtomicUInt64` 对象头开销；均为 无基线（待验证） |
| §8 降 CPU 方案 | 1 | `hashers` 闭包间接调用 → 种子数组直调；无基线（待验证） |
| §9 local mode 可行性 | 0 | 唯一大对象是 `serialize` 的返回缓冲（必须逃逸）与构造期位数组（存进成员，必然逃逸），无“函数内创建并销毁”的大临时对象，改造无收益 |
| §11 现有代码的 BUG（存量） | 3 | 已核对全部公开方法（`add`/`mightContain` 各 4 个重载、`serialize`、`deserialize`）、2 个构造入口与 4 个读写辅助的边界与空值：n=0 除零、deserialize 头部越界与巨量分配、p/seeds 域未校验；其余边界（`bitIndex ≤ 63`、`pos < size`、`bytes.size < 24`）已逐条推导无缺陷 |
| §12 并发安全与锁粒度 | 0 | 共享状态只有 `bitSet`（`AtomicUInt64.fetchOr`/`load`，逐字原子）与不可变字段 `n`/`p`/`size`/`hashers`；构造函数完成后才可能被发布，`deserialize` 的 `store` 发生在发布前 → 无数据竞争，也不需要锁。`serialize` 逐字 `load` 不构成一致快照：与并发 `add` 重叠时，恢复出的过滤器可能缺位（对该批元素出现假阴性）。README 未承诺快照语义，故按“文档未覆盖的语义边界”处理、不计为并发缺陷；若后续要在在线过滤器上做检查点，需先与调用方约定 quiesce 或双缓冲 |
| §14 功能完备性与 README 覆盖 | 0 | 以 `src/` 公开声明为基准逐项对照 README:55：`n`/`p`/`bitCount`/`seeds`/两个 `new`/4 个 `add`/4 个 `mightContain`/`serialize`/`deserialize` 全部有文档；根 `README.md:458` 已登记本模块；无“承诺但未实现”的能力（唯一承诺偏差是 deserialize 兜底条件，已按 §13 计入一般项） |
| 文件覆盖（§13 等） | 3/3 | 无缺失文件；§13 命中 2 条（README 保证写反 = 一般，示例 `k` 未定义 = 轻微） |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 2 |
| 一般 | 3 |
| 轻微 | 6 |
| 优化方案（堆内存 / CPU） | 2 / 1 |

存量缺陷合计 11 条（严重 2 / 一般 3 / 轻微 6），全部为存量；是否纳入修复待用户决定。

## 总评

单文件 270 行的实现整体结构清晰：位数组用 `AtomicUInt64` 做字级原子写、`n`/`p`/`size`/`hashers` 全为不可变字段，无锁并发模型是对的，`add`/`mightContain` 的位运算与提前返回也没有问题；`serialize`/`deserialize` 的格式设计（种子随数据走、bit 区按 word 落盘）方向正确。没有递归、没有全局状态、没有大粒度锁，性能面不存在结构性缺陷。

阻塞项集中在**输入边界**而非算法：一是构造入口对 `n`/`p`/`seeds` 完全不校验，`n = 0` 会得到一个“查询必抛异常”的对象，而仓内 `f_store/src/SSTable.cj:425` 正在用 `BloomFilter.new(0, 0.01)` 作为空 Bloom Block 的兜底，这条降级路径一旦被走到就是读请求异常；二是 `deserialize` 直接信任 `seedCount`/`bitCount`，既能被一个 104 字节的载荷触发数组越界，也能用 `seedCount` 申请 8 GB 内存，而 README 明确写着“越界时静默兜底、不抛异常”——契约与实现相反，属于必须一起改的一对。这两条都建议在下一轮修复窗口处理；`f_store` 侧的 `new(0, 0.01)` 调用点需同步改为合法尺寸（属范围外，仅提示）。

一般项里，`p`/`seeds` 的静默失效与 `deserialize` 无日志是同一类“降级不可观测”问题，修法可以合并成一个“构造函数与反序列化统一做参数校验 + 失败可观测”的改动；README 那句把布隆保证写反的话风险不低，改一个句子即可，建议顺手修掉。

轻微项（重复的小端读写、重复的位数组初始化、`size`/`bitCount` 命名、README 示例的未定义 `k`、`Hashable` 掩码风格、重载语义文档）都是可排期的清理项，不影响正确性。三个优化方案全部无基线，按规则只作待验证，不进修复清单。
