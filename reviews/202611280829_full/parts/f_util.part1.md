# f_util 模块审查报告（第 1/4 部分）

- **审查日期**：2026-11-28
- **模块路径**：`f_util`（48 个源文件；本部分覆盖 15 个：`CaseFormat` / `CityHash` / `CrcEngine` / `CrcGf` / `DiffieHellmanKeyExchanger` / `Factory` / `Fnv` / `IdMaker` / `IsUUID` / `Mediator` / `MurmurHash3X128` 及其测试）
- **基线**：工作区快照（`8c0ce643a`，`sts/1.3.x`，工作区干净，无 diff）⇒ 本部分全部缺陷记「存量」
- **审查重点**：哈希 / CRC / ID 生成的正确性与性能、工厂 / 中介者并发、死代码、重复逻辑、空实现、OOM、存量 BUG
- **报告版本**：v1（本部分为模块报告的 `part1`，最终由主 Agent 合并为 `docs/review/f_util_review_20261128.md`）

## 发现

### [严重] CityHash：长度 0..15 的输入必然越界崩溃（空串即崩）

- **位置**：`f_util/src/CityHash.cj:38`（短输入走 `weakHashLen32WithSeeds(data, 0, len, k0, k1)`）、`f_util/src/CityHash.cj:186`、`f_util/src/CityHash.cj:201-202`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11（边界差一 / 越界）+ §10 正确性
- **证据**：静态确定 —— `len <= 16` 分支里 `fetch64(bytes, offset + len - 8)` 在 `len < 8` 时偏移为负；`a = fetch64(bytes, offset)`、`b = fetch64(bytes, offset + 8)` 无条件读 16 字节，`len` 在 8..15 时 `offset + 8 .. offset + 15` 越过数组末尾。`fetch64`（`:132-139`）逐字节做 `bytes[offset + i]`，仓颉数组下标有边界检查 ⇒ 抛越界异常（非静默错误值）。
- **描述**：`cityHash("")`、`cityHash("id")`、任意长度 < 16 的字符串或字节数组都会抛异常。该函数是 `public` 对外 API，且没有任何文档说明长度下限，属"最常用输入直接不可用"。
- **建议**：按 CityHash 参考实现补齐 `len` 0..15 的四个分支（`≥8 / ≥4 / ≥1 / =0`，用 `fetch32`/逐字节读取），或至少在入口校验 `data.size >= 16` 并抛带说明的异常；`fetch64` 增加 `offset + 8 <= bytes.size` 断言。

### [严重] CityHash：`len >= 128` 且不是 128 的倍数时尾部循环不递减 `remaining`，读到越界为止

- **位置**：`f_util/src/CityHash.cj:78-94`（`let remaining = len - pos` 之后循环体内只更新 `tailOffset`）
- **来源**：存量
- **判据**：review-checklist §11（边界 / 循环终止条件）+ §4 同源（每轮重复读同一区间）
- **证据**：静态确定 —— `while (remaining > 0)` 的条件变量在循环体内从未被修改，只有 `tailOffset += chunkSize`；`chunkSize` 由未变的 `remaining` 推出，因此每轮读的是"新偏移 + 旧长度"，直到 `fetch64(data, tailOffset + chunkSize - 16)` 越界抛异常。
- **描述**：`len` 为 129、160、1000 这类非 128 倍数的输入（几乎全部真实输入）在块循环结束后进入尾部循环 ⇒ 要么长时间空转，要么很快越界崩溃；`len` 恰为 128 倍数时尾部逻辑被整段跳过，与 CityHash 的收尾处理也不一致。
- **建议**：把循环条件改成 `while (tailOffset < len)`，每轮 `remaining = len - tailOffset` 在循环内重算；同时按参考实现用 `len & 127` 做 4 段收尾（`≥32 / ≥16 / ≥8 / >0`）。

### [严重] MurmurHash3 x64-128：`len % 16 == 8` 时尾部 8 字节被异或两次，等于完全不参与哈希

- **位置**：`f_util/src/MurmurHash3X128.cj:77-108`（`if (tailLen >= 8) {...}` 之后接 `if (tailLen > 8) {...} else if (tailLen > 0) {...}`）
- **来源**：存量
- **判据**：review-checklist §11（逻辑错误 / 契约与实现不符）+ §2 近似重复（同一 `k1` 混合代码写了两遍）
- **证据**：静态确定 —— `tailLen == 8` 时第一个分支已算 `k1_tail` 并 `h1 ^= k1_tail`；`tailLen > 8` 为假，落到 `else if (tailLen > 0)` 为真，用完全相同的 8 字节重算同一个 `k1_tail`，再次 `h1 ^= k1_tail`。两次异或同一个值等于没异或。
- **描述**：所有长度 ≡ 8 (mod 16) 的输入（8、24、40 …）最后 8 字节对 `h1` 零贡献 ⇒ 同长度、仅尾部 8 字节不同的两条消息哈希相同。函数名为 `murmurHash` 且被 `f_codec` 当通用哈希用（`f_codec/src/default/DefaultCodec.cj` 6 处引用），这种系统性碰撞会直接放大到缓存键 / 去重键上；同时结果也与任何标准 MurmurHash3 实现不可互操作。
- **建议**：`else if (tailLen > 0)` 改为 `else if (tailLen > 0 && tailLen < 8)`；并补一条"同长度仅最后 8 字节不同必须不同哈希"的用例（现有用例没有覆盖 8..15 的尾部区间）。

### [严重] DiffieHellmanKeyExchanger：`Decimal ** 指数` 用 63 位随机指数 + 无限精度，运算不可能完成且结果不是 `g^a mod p`

- **位置**：`f_util/src/DiffieHellmanKeyExchanger.cj:97-99`（`(Decimal(BigInt(true, g)) ** ab_).toBigInt() % BigInt(true, p)`）、`f_util/src/DiffieHellmanKeyExchanger.cj:84`（`ab_ = random()`，`random()` 取 `nextInt64()`）
- **来源**：存量
- **判据**：review-checklist §5（OOM：按不可信规模展开运算）+ §11（契约与实现不符）+ §10 正确性
- **证据**：静态确定 —— ① `Decimal(BigInt)` 的默认精度为 0 即"无限精度"（std 文档 `math_numeric_package_structs.md:3154`：「默认采用精度值为 0，即无限精度进行构建」），`Decimal ** Int64` 为精确乘方（同文件 `:4904-4930`），指数是 `nextInt64()`（≈ 2^63 量级），结果位数约 `128 × 2^62`，任何一次 `middle()` 都无法在有限内存/时间内完成；② `nextInt64()` 有一半概率为负，负指数走 decimal128 舍入（文档同节注明），`toBigInt()` 按文档示例口径舍去小数部分（`123.xx → 123`，`structs.md:4179-4208`）⇒ `|g^a| < 1` 时得 0，`A`/`S` 恒为 0，`key()` 返回 `"0"`，Server 侧 `while (result == '0')` 会持续重试。
- **描述**：注释与 README 承诺的是教科书式 DH（`A = g^a mod p`、`S = B^a mod p`），实现既不是模幂、也跑不完；正常调用表现为进程挂死/OOM，或双方拿到 `"0"` 当共享密钥（静默失效）。
- **建议**：改用整数模幂（`BigInt` 的 `**` + `%`，或复用同模块 `prime.cj` 的 `qpow` 快速幂），指数取绝对值并限制在安全范围内（如 256 bit）；`middle()` 全程不再走 `Decimal`；补一条"Alice/Bob 两侧密钥相等"的用例（当前该文件**没有任何测试**）。

### [严重] DiffieHellmanKeyExchanger：模数 `p` 与生成元 `g` 直接取随机字节，不做素性/生成元校验（安全）

- **位置**：`f_util/src/DiffieHellmanKeyExchanger.cj:54-59`（`semi()` 里 `randomBytes(bytes: gBytes)` / `randomBytes(bytes: pBytes)`）、`:97-99`（直接拿 `p` 当模数）
- **来源**：存量
- **判据**：review-checklist §10 安全性（外部/随机参数未校验）+ §11（契约与实现不符）
- **证据**：静态确定 —— `p` 是 `ThreadLocalRandom.nextBytes(16)` 的 16 字节随机值（`f_random` 的均匀字节），未做 `millerRabin`/`isPrime`，也未剔除偶数与 0；`g` 同样是随机字节，与 `p` 无群关系。注释第 7 条却宣称"鉴于计算离散对数的困难性"。
- **描述**：模数为偶数（≈50%）时 `Z_p*` 结构退化、`g^x mod p` 的离散对数几乎可直接求出；即使为奇合数也可用 Pohlig–Hellman 分解。叠加 128 bit 模数（远低于任何现代下限），这套交换**不具备机密性**，却以"密钥交换协议"对外提供。
- **建议**：使用标准安全素数（RFC 3526 group14/16）或固定 2048 bit 素数常量；`g` 取该群的生成元/大素数阶子群元素；构造时校验 `p` 为素数且 `p > 2^2047`；若短期内不改，README 与类注释必须写明"仅供演示，不可用于真实密钥交换"。

### [一般] IdMaker：同一毫秒、同一 hostSerial 的两个实例产生完全相同的 ID 序列

- **位置**：`f_util/src/IdMaker.cj:26`（`startMillis` 取构造时刻）、`:32`（`current = AtomicInt64((hostSerial << 53) | (startMillis << 12))`）、`:40-42`（`fetchAdd(1)`）
- **来源**：存量
- **判据**：review-checklist §11（正确性 / 唯一性契约）+ §10
- **证据**：静态确定 —— 起始值只由 `hostSerial` 与"构造那一刻的毫秒"决定，没有进程 ID、实例序号或随机位；`nextInt64()` 只是在同一基数上自增。两个 `IdMaker()`（含 `init()` 默认构造，配置项 `idMakerHostSerial` 相同）在同一毫秒内构造时，`current` 完全相等 ⇒ 两个实例吐出同一串 ID。另外时间戳占 bit12..52 共 41 位且是**绝对** epoch 毫秒，2^41 ms ≈ 69.7 年，2039 年后高位溢出进 hostSerial 段。
- **描述**：类名与 README 定位是"趋势递增的分布式 ID"，但唯一性只在本实例内成立；多模块各自 `IdMaker()`、或分片部署共用同一 hostSerial 时会产生主键级重复（若被当主键使用则为严重）。
- **建议**：起始值掺入进程级随机（`ThreadLocalRandom` 低 12 位作序列种子）或从配置读 `workerId/processId`；41 位时间戳改为"相对自定义 epoch"的秒/毫秒并校验上限；`while` 内自增跨过 2^12 时进位到时间戳段的行为需要显式处理或直接按 63 位整型计数器文档化。

### [一般] Factory / Mediator：注册表静默覆盖同名项，缺键时直接抛 `NoneValueException`（契约未声明）

- **位置**：`f_util/src/Factory.cj:36`（`producers.add(TypeInfo.of<T>(), producer)`）、`f_util/src/Factory.cj:50`、`:53`（`producers[TypeInfo.of<T>()]`）；`f_util/src/Mediator.cj:23`（`colleagues[colleague.name] = colleague`）、`:26`（`colleagues[arg.name]`）
- **来源**：存量
- **判据**：fountain-baseline §4（同名注册应启动直接失败，不做隐式优先级）+ review-checklist §11（错误处理缺失 / 契约与实现不符）
- **证据**：静态确定 —— std 文档 `collection_package_class.md:4861` 明确 `HashMap.add` 对已存在 key「该键的值将被新值替换，并且返回旧的值」，而两处都丢弃了返回值；`operator[](K)`（同文件 `:6147`）在 key 不存在时抛 `NoneValueException`，`produce`/`execute` 都没有 `get()` 判空或换成领域异常。
- **描述**：重复注册（两个 `@Bean` 想注册同一类型策略、插件同名）时后者静默赢，线上表现为"某个实现莫名不生效"；未注册就 `produce` 时抛出与 `f_util` 无关的 `NoneValueException`，调用方无法按类型区分"未注册"和"内部错误"。README（`f_util/README.md:143-160`、`:172-180`）也只写了"注册/查找"，没有这两条语义。
- **建议**：`assemble`/`register` 检查 `add` 返回值，非 `None` 时抛 `IllegalStateException`（同名注册启动即失败）；`produce`/`execute` 改用 `get()`，缺失时抛 `TypeNotMatchException` 之外的专用异常（或在 README 明确写"缺失抛 `NoneValueException`"）。

### [一般] Factory / Mediator：非并发 `HashMap` 被注册与查找两侧同时访问，无任何同步

- **位置**：`f_util/src/Factory.cj:33`（`private let producers = HashMap<...>()`）、`:36` 写、`:50/:53` 读；`f_util/src/Mediator.cj:21`（`private let colleagues = HashMap<...>()`）、`:23` 写、`:26` 读
- **来源**：存量
- **判据**：review-checklist §12.1（共享可变状态无保护 / 迭代与修改并发）
- **证据**：静态确定（无锁、无 `ConcurrentHashMap`、无"仅启动期注册"的契约）；共享实例的使用点待确认（仓内除测试外无调用方，见「文件覆盖」说明）
- **描述**：两个类都是 `public`，`std.collection.HashMap` 明确非线程安全。只要存在"运行期注册"（插件按需 `register`、`@Bean` 懒加载）与并发 `produce`/`execute`，就可能读到扩容中的桶数组：读到旧值、丢注册项，极端情况是桶链断裂导致死循环。
- **建议**：二选一并写进类注释——(a) 注册只在启动期、之后只读（加一个 `frozen` 标志，写入时若已 frozen 抛异常）；(b) 换 `ConcurrentHashMap`。若要保留"注册后仍可写"，用不可变快照 + 原子替换引用（读多写少的最优解）。

### [一般] DiffieHellmanKeyExchanger：`ab_` 是实例级可变私有状态，`key()` 内部还会清零重掷，同实例并发调用互相破坏

- **位置**：`f_util/src/DiffieHellmanKeyExchanger.cj:84`（`protected var ab_: Int64 = random()`）、`:64-71`（`key()` 里 `ab_ = 0` 后循环）、`:86-90`（`ab()` 惰性重掷）
- **来源**：存量
- **判据**：review-checklist §12.1（检查-然后-写入 / 共享可变状态）
- **证据**：静态确定 —— `key()` 先 `ab_ = 0`，靠 `super.key()` 内的 `ab()` 重新赋值；`finish()` 用同一个 `ab_` 算公开值 `B`。两个线程同时 `key()`/`finish()` 时，`B` 可能对应另一个线程的 `b`，双方密钥必然不相等。
- **描述**：`Server` 侧"先 `key` 后 `finish`"的时序契约（`:72-77` 注释）在并发下无法维持；`ab_` 一旦被并发改写，交换静默失败（各自拿到不同密钥）。
- **建议**：`ab_` 改为构造时确定且之后不可变（`let`），把"重试"从 `key()` 里去掉（重试应由调用方发起完整握手）；若必须保留重试，把 `ab_` 与 `B` 一起封装成每会话对象，禁止复用同一实例。

### [一般] IsUUID：大写 UUID 被判为非法

- **位置**：`f_util/src/IsUUID.cj:25`（`UUID.tryParse(x).isSome()`）；根因在同包 `f_util/src/uuid.cj:208-213`（`doParse` 只把 `r'a'..r'f'` 映射为数值，其余走 `case _ => 17` ⇒ `None`）
- **来源**：存量
- **判据**：review-checklist §11（契约与实现不符）+ §10 正确性（外部输入）
- **证据**：静态确定 —— 十六进制大小写不区分是 UUID 文本表示的通用约定，而 `tryParse` 只接受小写；`IsUUID` 只做透传，因此 `550E8400-E29B-41D4-A716-446655440000` 这类合法 UUID 校验失败。
- **描述**：`@IsUUID` 是给外部入参（HTTP/JSON 请求体）用的校验注解，实际会把大量合法输入判错，且错误信息是"必须是UUID格式的字符串"，用户无从得知是大小写问题。
- **建议**：`doParse` 增加 `r'A'..r'F'` 分支（或在 `validate` 里先 `toAsciiLowerCase()` 再解析）；若"只接受小写"是刻意口径，在 `description` 与 README 写明。

### [轻微] CaseFormat / DiffieHellmanKeyExchanger：顶层声明省略访问修饰符，可见性依赖 SDK 默认值（跨模块引用已存在）

- **位置**：`f_util/src/CaseFormat.cj:20`（`abstract sealed class CaseFormat`，无修饰符）、`f_util/src/DiffieHellmanKeyExchanger.cj:83`（`abstract sealed class DiffieHellmanKeyExchanger`，无修饰符，`:53`/`:63` 的 `public class` 继承它）
- **来源**：存量
- **判据**：review-checklist §1（可见性）+ fountain-baseline §3 同源（契约显式性）
- **证据**：待确认 —— 语言规范（`cangjie_docs/.../package/toplevel_access.md`）写明「其他顶层声明……默认修饰符为 `internal`」，而 `f_orm/src/macros/ORMField.cj:21` 与 `f_orm/src/macros/QueryMappersGenerator.cj:23` 跨模块 `import fountain::f_util.CaseFormat` 并在 `:118-132`、`:401-444` 使用。二者不可能同时成立：要么目标 SDK（`cjpm.toml` 声明 `cjc-version = "1.2.0"`）的默认可见性比规范更宽，要么这两处引用/继承本来就是编译不过的。缺的信息：在目标 SDK 上 `cjpm build f_orm` 的实际结果。
- **描述**：写法依赖"省略即足够可见"的隐含规则，升级 SDK 或调整包划分后可能整体编译失败，且对外契约不可读。
- **建议**：两处都显式写 `public`（或 `internal` 并同步收窄调用方）；`DiffieHellmanKeyExchanger` 既然作为 `public` 类的父类型，必须是 `public`。

### [轻微][存量] CityHash：与 CityHash128 算法不符，`v` 的写入被下一行覆盖（无效计算）

- **位置**：`f_util/src/CityHash.cj:64-68`（`:65` 算出 `v`，`:67` 立即 `v = UInt128(x, z)` 覆盖）、`:184-202`（`weakHashLen32WithSeeds` 的 `len` 分支算出的 `a` 在 `:201` 被 `fetch64` 覆盖）、`:73-96`（尾部只做两行混合 + `finalMerge`）
- **来源**：存量
- **判据**：review-checklist §1（读了不用的死写入）+ §11（与命名/文档承诺的算法不符）
- **证据**：静态确定 —— `:67` 无条件覆盖 `:65` 的返回值，标准 CityHash128 的块循环必须把新算出的 `pair` 保留为滚动状态 `v`；`:201-202` 把按 `len` 分支准备的 `a/b` 全部丢弃后重新取 8 字节，使 `:184-198` 的 `a` 分支（`a = shiftMix(a*k1)*k1`、`a += d`）成为死计算。
- **描述**：函数对外提供 `cityHash(...): UInt128`，但结果既非 CityHash 也不满足其雪崩性质（块循环里 `x = v.right` 恒等于 `z`，状态退化为线性递推）；无法与任何其他语言的 CityHash 对齐，跨语言做一致性哈希/分片时会两端漂移。
- **建议**：按 CityHash v1.0.2 的 `CityHash128` 重写块循环与尾部 4 段收尾；若不打算兼容，改名（如 `fyHash`）并在函数注释声明"非标准 CityHash"，避免调用方误以为可互操作。

### [轻微][存量] CityHash：私有符号 `mur` / `rotate32` 无调用者，`hashLen16` 有未使用局部量，`chunkSize32` 是无意义别名

- **位置**：`f_util/src/CityHash.cj:158-172`（`mur`）、`:151-154`（`rotate32`，仅被 `mur` 调用）、`:119`（`let mix = ...` 之后未读）、`:86`（`let chunkSize32 = chunkSize`）
- **来源**：存量
- **判据**：review-checklist §1（非 public 符号无调用者 / 局部变量赋值后未读）
- **证据**：静态确定 —— 全仓 `grep -w mur`、`grep -w rotate32` 仅命中定义处与 `mur` 内部各 2 次；`mix` 在 `hashLen16` 内赋值后再无出现。
- **描述**：从 MurmurHash3 抄来的 `mur`/`rotate32` 是迁移残留，`mix` 是调参残留，读者会误以为它们在参与计算。
- **建议**：删除 `mur`、`rotate32`、`mix`、`chunkSize32`；`c = ...fetch64(data, tailOffset + chunkSize - 32)` 直接写 `chunkSize`。

### [轻微][存量] MurmurHash3X128：4 个未使用的 import

- **位置**：`f_util/src/MurmurHash3X128.cj:18`（`std.binary.LittleEndianOrder`）、`:20`（`stdx.encoding.hex.*`）、`:22`（`fountain::f_data.DataParsable`）、`:23`（`fountain::f_util.exception.HashException`）
- **来源**：存量
- **判据**：review-checklist §1（未使用的 import）
- **证据**：静态确定 —— 文件内只用到 `UInt64.readLittleEndian`（`std.core` 的 `UInt64` 静态方法，`:42`/`:78`）、`len.toUInt()`（`std.convert`）、`text.unsafeBytes()`（`f_base`）与 `@Frozen`/`@OverflowWrapping`（编译器内置注解）；上述 4 个名字在本文件内零出现。
- **建议**：删除这 4 行 import。

### [轻微][存量] CrcGf_test：`refCrc64Normal` / `le64` 定义后从未使用

- **位置**：`f_util/src/CrcGf_test.cj:46-55`（`refCrc64Normal`）、`:65-71`（`le64`）
- **来源**：存量
- **判据**：review-checklist §1（private 符号无调用者）
- **证据**：静态确定 —— 两符号在本文件内 `grep -c -w` 均为 1（仅定义处），全仓无其他引用；`refCrc64Reflected`、`be64` 有使用者，说明这两份是"非反射 / 小端"方向的残留参考实现。
- **建议**：删除；若想保留非反射参考实现，补一条与 `Crc64.ecma182/we` 对拍的用例让它真正被使用。

### [轻微][存量] CrcGf：`reflectConstants` 只被自己的测试引用，而该测试是"自己证明自己"

- **位置**：`f_util/src/CrcGf.cj:134-146`（`reflectConstants`）；`f_util/src/CrcGf_test.cj:297-313`（唯一调用点 `reflectConstantsAreConsistent`）
- **来源**：存量
- **判据**：review-checklist §1（仅测试使用 ⇒ 可见性/去留建议）+ §2（重复逻辑：三套常量布局并存）
- **证据**：静态确定 —— 全仓仅 `CrcGf_test.cj:300` 调用；`reflectConstantsAreConsistent` 的断言全是 `c[i] == CrcGf.xPowModP(...)`，即用实现自己的函数验证实现的常量数组，未与任何独立参考或机器码核对照。相比之下 `reflectConstants64`（`crc64_native_arm.cj:225-227`）与 `reflectX86Constants`（`crc64_native_x86.cj:249-252`）才是被内核真正消费的两套布局。
- **描述**：仓库里同时存在 3 套 CRC-64 折叠常量布局（4 字 / 8 字 / 10-16 字），其中 8 字那套没有任何生产消费者；同一概念的多份表示容易在改动时只改一处（drift 风险）。
- **建议**：删除 `reflectConstants` 与其自证用例，或让某个内核真正消费它；同时在 `CrcGf` 类注释里写清"哪套布局给哪个架构用"。

### [轻微][存量] IsUUID：缺少 `messageIfNotMatch!` 构造参数，与 `f_data` 其它 Validator 不一致

- **位置**：`f_util/src/IsUUID.cj:22`（`public const init(){}`）
- **来源**：存量
- **判据**：review-checklist §10（设计一致性 / 可维护性）
- **证据**：静态确定 —— `f_data/src/validation/Validator.cj:41`、`:56`、`:70`、`:87`、`:103`、`:119` 的 `IsNotEmpty`/`IsNotBlank`/`StringSize`/`IsInteger`/`IsDecimal`/`IsEmail` 全部是 `init(messageIfNotMatch!: String = '')` 并 `super(messageIfNotMatch: messageIfNotMatch)`；只有 `IsUUID` 无法定制失败文案。
- **建议**：改成 `public const init(messageIfNotMatch!: String = '') { super(messageIfNotMatch: messageIfNotMatch) }`。

### [轻微][存量] IdMaker：负数 hostSerial 的异常文案与判据不符

- **位置**：`f_util/src/IdMaker.cj:29-31`
- **来源**：存量
- **判据**：review-checklist §11（语义与命名/文案不符）
- **证据**：静态确定 —— 条件是 `hostSerial > 1023 || hostSerial < 0`，文案固定为 `"host serial is too large"`，`-1` 时报"太大"。
- **建议**：文案改为 `"host serial ${hostSerial} must be between 0 and 1023"`（去掉 "too large"）。

### [轻微][存量] CrcEngine：64 位反射热循环用 `CPointer<UInt64>` 直接读，隐含 8 字节对齐与小端两个前提

- **位置**：`f_util/src/CrcEngine.cj:305-308`（`let p64 = CPointer<UInt64>(dp)` / `p64.read(j)`）
- **来源**：存量
- **判据**：review-checklist §11（契约与实现不符 / 平台假设未声明）
- **证据**：待确认 —— 注释（`:304`）只写"小端机器上一次 64 位读正好是小端 word"，没有编译期/运行期端序判定，也没有对齐保证；`Array<Byte>` 的裸指针不保证 8 字节对齐。在 x86_64/aarch64（仓颉现有目标平台）通常可用，大端或严格对齐平台上结果错误或陷入异常。缺的信息：目标平台清单与大端平台的验证结果。
- **建议**：用 `UInt64.readLittleEndian(dp.read(...))` 之类的显式小端读取，或加 `@When[os == ...]`/端序常量分支；至少在注释里把"仅支持小端 + 允许非对齐访问"写成约束。

### [轻微][存量] CrcEngine_test：吞吐用例在异常路径上不恢复全局开关

- **位置**：`f_util/src/CrcEngine_test.cj:351`（`Crc64Hw.setNativeEnabled(false)` 在 `try` 之外）、`:367-368`（恢复在用例末尾）
- **来源**：存量
- **判据**：review-checklist §11（资源/状态对称释放）
- **证据**：静态确定 —— `:352-363` 之间任何异常（含 `@Fail` 抛出的断言失败）都会跳过 `:367` 的 `setNativeEnabled(true)`，后续依赖硬件核的用例（`:406`、`:454`、`:479`、`:553`）会集体走软件路径或误判。同文件 `:443-448`、`:533-548` 的写法是正确的（`try/finally`），说明这是遗漏而非风格。
- **建议**：把 `:351` 后的整段包进 `try { ... } finally { Crc64Hw.setNativeEnabled(true); Crc64Hw.resetForTest() }`。

### [轻微][存量] FnvHasher：`public` 有状态类，未声明"非线程安全"

- **位置**：`f_util/src/Fnv.cj:182-204`（`FnvHasher` 的 `update` 改 `core.state` / `scratchA` / `scratchB`）
- **来源**：存量
- **判据**：review-checklist §12.1（共享可变状态）+ §10（契约声明）
- **证据**：静态确定（无锁、无原子、`FnvCore.update` 直接写实例数组）；共享实例的使用点待确认（仓内仅 `Fnv_test.cj` 使用，且每个用例内新建）
- **描述**：与 `MessageDigest` 同类，惯例是"每线程/每次使用一个实例"，但类注释（`:178-181`）只描述了 `update`/`finish`/`reset` 语义，没写线程约束；一旦被当单例复用，`state` 与两张 scratch 表会互相踩。
- **建议**：类注释补一句"实例非线程安全，需每次使用新建或外部串行化"；若要支持共享，把 `scratchA/scratchB` 改为方法内局部数组（每次分配，或换成 `ThreadLocal` 缓存）。

## 优化可行性方案

> 以下均无改前基线，按规则只作为"待验证"方案，不进 `tasks.md`。

### [堆内存] CrcEngine 每个变体同时生成正向与反射两张 256 项表，实际只消费其中一张

- **现状**：构造函数（`CrcEngine.cj:82-111`）无条件生成 `normalTable` 与 `reflectedTable`（各 `256 × 8 B = 2 KiB`）；32 位反射变体再加 `slice1..3`（3 × 2 KiB），64 位变体再加 `slices64[1..7]`（7 × 2 KiB）。按 `crc32.cj` 12 个变体、`crc64.cj` 6 个变体、`crc16.cj` 24 个变体（16 位是 `256 × 2 B × 2`）估算，类静态初始化后常驻约 200 KiB，其中约一半是永远不会被索引的方向表（`update` 的每个分支只读 `reflectedTable` 或 `normalTable` 之一）。
- **方案**：按 `refin` 只生成需要的那张（另一张置 `[]`），`slicing16`/`slicing64` 的派生基数同步改为 `if (refin) reflected else normal`；`update` 的两个兜底分支已分别只看一张表，无需改语义。
- **预期**：常驻表内存约减半（≈100 KiB），首次触达 `Crc32`/`Crc64`/`Crc16` 的类初始化时间约减半（建表循环少一半）。
- **代价**：无行为变化；需确认没有外部（测试/调试）直接读 `normalTable`/`reflectedTable`——两者都是 `private`。
- **验证**：`cjpm build -O2` 后统计 `Crc32/Crc16/Crc64` 首次访问耗时（`MonoTime` 分段）与进程 RSS；`crc_check_test.cj` 全绿作为等价性门槛。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] Fnv 一次性入口每次调用都构造完整引擎（4 个数组 + 结果数组）

- **现状**：`Fnv.hash`（`Fnv.cj:53-57`）→ `FnvCore.of`（`:303-311`）每次都新建 `basis`/`state`/`scratchA`/`scratchB` 四个数组，再 `words()` 分配第 5 个；`Fnv32/Fnv64` 只用第一个字（`:84`、`:104`）。`Fnv64.fnv1a` 是 `f_jit` 常量指纹路径（文件注释 `:96`），调用量大且输入很短。
- **方案**：为 `W32/W64` 增加无 `FnvCore` 的快路径（`var h = basis; for (b in data) { h = (h ^ b) * prime32/64 }`，`UInt64` 乘法天然截断，不需要 limb 数组）；其余宽度保留现有实现。
- **预期**：W32/W64 单次哈希从 5 次堆分配降到 0～1 次；短输入（< 64 B）耗时主要来自分配，预计降幅明显（需实测确认，当前无数据）。
- **代价**：多一条实现分支，需与现实现做逐位等价性用例（现有 `Fnv_test.cj` 的黄金值可直接复用）。
- **验证**：`cjpm bench -O2` 对 8/32/256 B 输入各跑 1e6 次，取中位数与 P95，对照现实现；同时看 `getAllocatedHeapSize()` 每轮分配量。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] MurmurHash3X128：每个 16 字节块产生 3 次切片复制

- **现状**：`MurmurHash3X128.cj:40-43` 每块先 `data[offset..offset+16]` 复制 16 B，再 `blockSlice[0..8]`、`blockSlice[8..16]` 各复制 8 B，然后才 `readLittleEndian`。1 MiB 输入 = 65536 块 × 3 次复制 ≈ 2 MiB 额外拷贝 + 131072 次小数组分配。
- **方案**：直接对 `data` 使用带偏移的小端读取（`UInt64.readLittleEndian(data[offset..offset+8])` 仍是复制；若 std 提供带 `offset` 的重载则直接用，否则手写 8 次下标拼装或用 `unsafe` 裸指针读）。
- **预期**：块循环的分配次数从 3/块降到 0/块，GC 压力与耗时同步下降（具体比例待测）。
- **代价**：引入 `unsafe` 或手写字节拼装，需与现实现逐位对照；`f_codec` 的序列化路径依赖该哈希，必须先补"新旧实现同值"用例。
- **验证**：`cjpm bench -O2`，1 MiB / 64 KiB / 16 B 三档，对照现实现的中位数与分配量。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] FnvCore.mulPrime：每字节两趟全 limb 扫描（W256/W1024 才有意义）

- **现状**：`Fnv.cj:344-354` 每个输入字节调用一次 `mulPrime`，内部两次 `shiftBytesInto`（各遍历 `limbCount` 个 limb，W1024 时 32 个）再遍历一次做加法 ⇒ 约 3 × limbCount 次操作/字节。
- **方案**：把 `(state << k) + (state << 8) + state * c` 合成单趟（按 `limbShift`/`bitShift` 从高到低一次算完，同时累加 `prod` 与两个移位项）。
- **预期**：W1024 每字节 limb 访问次数约降 2/3；W256 同理。属纯常数优化，不影响结果。
- **代价**：进位逻辑合并后更难读，需要现有黄金值用例兜底（`Fnv_test.cj` 已覆盖 1024 位长输入）。
- **验证**：`cjpm bench -O2`，W1024 × 5 KiB 与 1 MiB 两档，对照中位数。
- **证据状态**：`无基线（待验证，不进 tasks）`

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `Fnv.hash` 的 5 次分配是 `f_jit` 常量指纹路径的主要开销 | `f_util/src/Fnv.cj:53-57` | 该路径的调用次数与分配占比 | 对 `f_jit` 编译期跑 `cjprof record`，看 `FnvCore.of`/`Array` 分配的自耗时与样本数 |
| 2 | `CrcEngine` 类初始化（建表）在首个 CRC 请求上产生可感知延迟 | `f_util/src/CrcEngine.cj:82-168` | 首次触达耗时 | 冷启动脚本里 `MonoTime` 包住首次 `Crc32.isoHdlc.compute`，重复 30 次取中位数 |
| 3 | 32/64 位切片的裸指针路径在生产编译（`-O2`）下仍优于下标路径 | `f_util/src/CrcEngine.cj:235-237` 注释声称 `cjpm test`（`-O0`）下 51~58 MB/s | `-O2` 下的对照数据 | 同机 `cjpm bench -O2` 分别跑裸指针版与下标版，1 MiB，取中位数与离散度 |
| 4 | `CaseFormat.convert` 每次调用新建目标对象（Pascal/Camel 走 `new()`）在 ORM 宏展开期可忽略 | `f_util/src/CaseFormat.cj:50` | 宏展开期调用次数 | 统计 `f_orm` 宏编译一个 100 字段实体的 `convert` 调用次数与总耗时 |
| 5 | `IsUUID` 的 `UUID.tryParse` 逐字符 `match` 是请求校验路径的热点 | `f_util/src/uuid.cj:192-250`（`IsUUID` 透传调用） | 单次耗时与 QPS 占比 | 对校验接口做 10 万次压测，`cjprof` 看 `tryParse` 自耗时占比 |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_util/src/CaseFormat.cj` | .cj | ✅ | 见 §1 发现（默认可见性）、§2（5 个子类 `convert` 近乎同构，属模板化实现，判为可读性取舍不报重复） |
| 2 | `f_util/src/CaseFormat_test.cj` | .cj | ✅ | 6×5 转换矩阵覆盖完整；缺"连续大写/数字边界"用例 |
| 3 | `f_util/src/CityHash.cj` | .cj | ✅ | 见 §1 严重×2、§2 轻微×2（无测试文件） |
| 4 | `f_util/src/CrcEngine.cj` | .cj | ✅ | 见 §1 轻微（对齐/端序）、优化方案 1 |
| 5 | `f_util/src/CrcEngine_test.cj` | .cj | ✅ | 见 §1 轻微（全局开关未恢复）；等价性用例设计良好（逐位参考实现独立） |
| 6 | `f_util/src/CrcGf.cj` | .cj | ✅ | 见 §1 轻微（`reflectConstants` 仅测试引用） |
| 7 | `f_util/src/CrcGf_test.cj` | .cj | ✅ | 见 §1 轻微（`refCrc64Normal`/`le64` 死代码） |
| 8 | `f_util/src/DiffieHellmanKeyExchanger.cj` | .cj | ✅ | 见 §1 严重×2、一般×1、轻微×1（无测试文件） |
| 9 | `f_util/src/Factory.cj` | .cj | ✅ | 见 §1 一般×2；`Producer` 默认抛 `IllegalAccessException` 已在 README 说明，不计空实现 |
| 10 | `f_util/src/Fnv.cj` | .cj | ✅ | 算法与官方素数/偏移基值逐项核对一致；见 §1 轻微（`FnvHasher` 并发声明）、优化方案 2/4 |
| 11 | `f_util/src/Fnv_test.cj` | .cj | ✅ | 黄金值覆盖 5 宽度 × 2 变体 × 空串/短串/emoji/长输入，自检充分 |
| 12 | `f_util/src/IdMaker.cj` | .cj | ✅ | 见 §1 一般×1、轻微×1 |
| 13 | `f_util/src/IsUUID.cj` | .cj | ✅ | 见 §1 一般×1（大写被拒）、轻微×1（缺 message 参数） |
| 14 | `f_util/src/Mediator.cj` | .cj | ✅ | 见 §1 一般×2（与 Factory 合并）；泛型参数 `C` 未被任何成员使用（`Mediator.cj:20`），属 API 噪声，计入可读性未单列 |
| 15 | `f_util/src/MurmurHash3X128.cj` | .cj | ✅ | 见 §1 严重×1、轻微×1（未使用 import）、优化方案 3 |

合计：`.cj` 15 个 / `.md` 0 个 / 共 15 个，全部读完（本部分未分配 `.md`，README 与 `doc/**` 由其它部分覆盖）。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 12 | 正确性 6（CityHash×2、Murmur、DH×2、IdMaker）、设计 3（Factory/Mediator 契约与并发、Mediator 泛型 `C` 冗余）、语言特性 2（默认可见性、`var` 应为 `let` 的可读性问题未单列）、安全性 1（DH 非素数模数） |
| §1 死代码 | 4 | 已逐个 `private` 符号全仓搜、`internal` 在包内搜、`public` 先判对外可达性：CityHash `mur`/`rotate32`/`mix`/`chunkSize32`（全仓仅定义处）、Murmur 4 个未用 import、`CrcGf_test` 的 `refCrc64Normal`/`le64`、`CrcGf.reflectConstants`（仅测试引用，按可见性建议报）；`FnvCore`(internal，有调用者)、`CrcGf`/`CrcEngine` 的 internal 方法（被 `crc16/crc32/crc64/native` 大量调用）均不判；`Factory`/`Mediator`/`Fnv`/`IdMaker`/`IsUUID` 是对外可达 `public`，仓内零引用不作死代码 |
| §2 重复逻辑 | 3 | ① `Murmur` 尾部 `k1` 混合代码写了两遍（同时是缺陷，已并入严重项）；② `CrcGf` 三套 CRC-64 常量布局语义重叠（已报轻微）；③ `Factory.produce`/`Mediator.execute` 是同一套"查表-调用"骨架但泛型/异常语义不同，抽取反而增加间接层，判为不重复。`CaseFormat` 6 个子类 `convert` 结构同构但被 `isDelimiter`/`withDelimiter`/大小写规则参数化，判为模板化实现不报 |
| §3 空实现 | 0 | `Producer.produce()`/`produce(arg)` 的默认 `throw IllegalAccessException("unimplemented")` 是显式"必须覆盖"契约且 README（`f_util/README.md:143-146`）已说明，属有意为之；其余无空函数体、无 `TODO`、无 `catch {}` |
| §4 栈溢出 | 0 | 逐函数确认无递归：CityHash/Murmur/FNV/CRC 全是迭代；`DiffieHellmanKeyExchanger` 无递归；`CaseFormat` 转换是单趟 `for` |
| §5 OOM | 1 | DH 的 `Decimal ** 63 位指数`（无限精度精确乘方）→ 结果规模 ~2^62×128 bit，OOM/挂死（已并入严重项）；其余容器规模均为常量（256 项表、`width.words()` 数组） |
| §6.1 热点瓶颈 | 0 | 未提供 `cjprof`/`cjpm bench` 数据，热点结论不成立；4 条候选已进「待验证假设」与「优化可行性方案」（均标 `无基线`） |
| §6.2 大粒度锁 | 0 | 本部分 15 个文件无任何锁/`synchronized`/`Mutex`；`CrcEngine` 的 `unsafe` 只做裸指针读，不涉及互斥 |
| §6.3 并发串行 | 0 | 无 `spawn`/`Future`/线程池使用，不存在"提交即等待"形态 |
| §6.4 低效算法 | 2 | `Fnv.hash` 每次构造 5 个数组（优化方案 2）、`Murmur` 每块 3 次切片复制（优化方案 3）；均为常数开销，按"已知规模未预分配"入优化方案而非缺陷（缺实测数据） |
| §7 降堆内存方案 | 2 | CrcEngine 正/反射双表（约 100 KiB 可省）、Fnv 一次性入口的数组构造（可与 CPU 方案合并计） |
| §8 降 CPU 方案 | 3 | Fnv 快路径、Murmur 块读取、FnvCore 单趟 limb 运算 |
| §9 local mode 可行性 | 0 | 所有中间对象都作为返回值逃逸（`Array<UInt64>` 摘要、`UInt128`、`String`），`CrcEngine.update` 的裸指针数据来自入参，逃逸检查不通过；且无改前改后峰值内存数据，不符合立项条件 |
| §11 现有代码的 BUG（存量） | 11 | 本轮 15 个文件的边界/空值/错误处理逐条核对：CityHash 空串与短串越界、尾部循环不终止、Murmur 双异或、DH 幂运算与参数、IdMaker 唯一性/2039 溢出、Factory/Mediator 缺失键异常、IsUUID 大写、CrcEngine 端序假设、CrcEngine_test 状态恢复；全部为存量（快照无基线） |
| §12 并发安全与锁粒度 | 3 | `Factory`/`Mediator`（非并发 `HashMap` 双端访问，无同步）、`DiffieHellmanKeyExchanger.ab_`（共享可变 + 重置）、`FnvHasher`（有状态且未声明非线程安全）；`CrcEngine`/`FnvCore` 的表与 `basis` 构造后只读，`CaseFormat` 单例的 `new()` 返回新实例或返回无状态单例 ⇒ 无共享可变状态，判安全。锁粒度维度：本部分无锁，无从谈粒度 |
| §13 文档一致性（.md） | 0 | 本部分未分配 `.md`（`f_util/README*.md` 与 `doc/**` 归其它部分）；范围外提示 2 条见「总评」末尾 |
| §14 功能完备性与 README 覆盖 | 0 | 本部分 public 声明与其文档承诺逐项对照：`Producer` 默认抛异常、`Factory`/`Mediator`/`Fnv`/`FnvHasher`/`FnvWidth`/`FnvVariant`/`IdMaker`/`IsUUID`/`Semi` 均在 README 有对应段落；未见"承诺但未接线"。`DiffieHellmanKeyExchanger.randomByteLen()` 仓内零引用但属对外 API，不作缺失 |
| 文件覆盖（§13 等） | 15/15 | 本部分 15 个文件全部读完，无 `.md` 分配 |

## 模块统计（本部分）

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 5 |
| 一般 | 5 |
| 轻微 | 11 |
| 优化方案（堆内存 / CPU） | 2 / 3 |

存量缺陷共 21 条，是否纳入修复待用户在门禁决定。

## 总评

哈希与 CRC 的"工程化"程度差别很大：`Fnv`（5 宽度 × 2 变体，官方基值/素数逐位核对、黄金值覆盖到 1024 位长输入）与 `CrcEngine`（表驱动、slicing-by-4/8/2、逐位参考实现对拍 + 吞吐门禁）是这部分质量最高的代码，`CrcGf` 的 Barrett 常量也有独立参考实现验证。相对地，`CityHash` 与 `MurmurHash3X128` 是从其他语言机械搬运后未收尾：CityHash 的空串/短串直接越界、`len >= 128` 时尾部循环不终止，Murmur 的尾部 8 字节被异或两次——三者都是只看代码即可定论的崩溃/静默错误，且三份实现都没有测试文件（`CityHash` 完全没有）。`DiffieHellmanKeyExchanger` 更严重：用 `Decimal` 无限精度乘方做 63 位指数模幂（跑不完或恒得 0），模数还是随机字节而非素数，实际上不具备密钥交换能力，属于"对外承诺了安全能力但实现不成立"。

阻塞项（建议本轮修）：CityHash 两处越界/死循环、Murmur 尾部双异或、DH 的模幂与非素数参数——四条都影响对外 API 的正确性/安全性，且修复范围局部。`Factory`/`Mediator` 的静默覆盖与缺失键异常、`IdMaker` 的同毫秒重复，属于"用起来才发现"的类型，建议在补文档的同时一并收紧契约。死代码与未使用 import 集中在这几个搬运文件的收尾部分，清理成本很低。

范围外提示（不占本轮统计）：① `f_util/src/UInt128.cj:61` 的 `HashException(...)` 只是构造对象后丢弃，没有 `throw`，长度非法时并不抛异常——本部分 `CityHash`/`Murmur` 都返回该类型，建议下一部分核对；② `f_util/README.md:369` 写"FNV-1 与 FNV-1a × 宽度 32 / 64 / 128 / 256"，漏了已实现的 1024 位（同文件 `:731` 又列出 `Fnv1024`），且 `:733` 把 `bits`/`words` 写成 `prop`（实现是 `func`）。
