# f_util 模块审查报告（第 3/4 部分）

- **审查日期**：2026-11-28
- **模块路径**：`f_util`（48 个源文件；本部分覆盖 15 个：`crc32_native_arm` / `crc32_native_stub` / `crc32_native_x86` / `crc64` / `crc64_native_arm` / `crc64_native_stub` / `crc64_native_x86` / `crc_check_test` / `exception/GeoHashException` / `exception/HashException` / `exception/IdException` / `exception/TextTemplateException` / `exception/UUIDException` / `geohash` / `prime`）
- **基线**：工作区快照（`8c0ce643a`，`sts/1.3.x`；除未跟踪的 `docs/review/`、`reviews/` 外工作区干净，无 diff）⇒ 本部分全部缺陷记「存量」
- **审查重点**：CRC 原生实现与调度（4 个平台实现 + 2 个 stub + `crc64` 门面 + 检查值自检）、异常类型族、geohash、素数、死代码、重复逻辑、空实现、栈溢出、OOM、存量 BUG
- **报告版本**：v1（本部分为模块报告的 `part3`，最终由主 Agent 合并为 `docs/review/f_util_review_20261128.md`）

## 发现

### [严重][存量] GeoHash.encode 的二分比较方向反了：同号象限的所有坐标折叠成同一个 hash

- **位置**：`f_util/src/geohash.cj:41`（`h |= if(midlng >= longitude) { lowlng = midlng; 1 << shift }`）、`f_util/src/geohash.cj:49`（`if(midlat >= latitude)` 同构）
- **来源**：存量（快照模式无基线；`git blame -L 31,59` 全部落在 `4be871f2f`（LF 换行统一提交），更早提交 `030b8c0b0`/`a9667b06a` 已存在该逻辑）
- **判据**：review-checklist §11（逻辑错误 / 边界与分支方向）+ §10 正确性
- **证据**：静态确定 —— ① `decode`（`:66-91`）的约定是「bit=1 → 取上半区」（`:78-80` `lowlng = lng`），`tryParse`（`:115-121`）与 `toString`（`:100-103`，每字符高比特=lng）也是同一约定；② 但 `encode` 在 `midlng >= longitude`（即坐标落在**下**半区）时置 bit=1 并把区间更新到**上**半区 `lowlng = midlng`。也就是说每一步都保留了**不含该点**的那一半，并把区间推到点的同一侧之后再也不会换边：
  - `longitude > 0`：第 1 步 bit=0、区间变 `[-180, 0]`（全部 < x），此后每步 `mid < x`，`mid >= x` 恒假 ⇒ 后续 31 个 lng 位全 0；`latitude > 0` 同理。故**整个东北象限 ⇒ hash = 0x0000000000000000**。
  - `longitude < 0`：第 1 步 bit=1、区间变 `[0, 180]`，此后 `mid >= x` 恒真 ⇒ 全 1；`latitude < 0` 同理 ⇒ **整个西南象限 ⇒ 0xFFFFFFFFFFFFFFFF**；混合符号 ⇒ `0x5555…` / `0xAAAA…`。
  - 全部 2³²×2³² 个坐标只剩 **4 个不同 hash**；`encode(116.4, 39.9) == encode(0.001, 0.001) == encode(179, 89) == 0x0`，而 `decode(0x0) = (-180, -90)`。
- **描述**：`GeoHash` 声称实现 geohash，实际退化为「经度符号 1 bit + 纬度符号 1 bit」的 2 bit 编码：`encode` 不保距、不可逆（`decode(encode(x))` 返回对角点 `(-180,-90)` 或 `(180,90)`），`==`/`hashCode` 把整个象限判为相等，作为 `HashMap` 键或空间索引完全不可用；同时它还是 `Parsable`/`DataParsable` 的实现，从 JSON 反序列化会直接把错误值带进业务。仓内目前零生产引用（`grep GeoHash` 只命中定义、README、`.worktrees` 副本），所以缺陷尚未暴露，属于"公开 API 一用就错"。
- **建议**：两处比较取反——`if (longitude >= midlng) { lowlng = midlng; 置位 } else { highlng = midlng }`（纬度同）；`if` 两支的字面量统一写 `1u64` / `0u64`（现在 `:43` 是 `1 << shift`、`:46` 是 `0`、`:51` 是 `1u64 << shift`、`:54` 是 `0u64`，四种写法并存，是复制粘贴的直接证据）。补 4 条用例：同象限两个远点必须不同 hash、`decode(encode(p))` 误差 < 1e-6、`toString` 长度恒 32、`tryParse(toString(g)) == g`。修完后建议与标准 base32 geohash 做一次外部对拍，确认是否要与主流实现互通（当前是自定义四进制，见 §13 项）。

### [严重][存量] GeoHash.tryParse 用「解析前的区间中点」重新 encode，`parse(toString(g))` 恒不成立

- **位置**：`f_util/src/geohash.cj:112-123`（`lng`/`lat` 在 `match` **之前**取中点，循环结束只 `encode(lng, lat)`）
- **来源**：存量（同上，`4be871f2f` 前已存在）
- **判据**：review-checklist §11（逻辑错误 / 返回值与输入语义不符）+ §10（`Option` 隐式装箱掩盖了"返回的是新算的 hash 而不是按位重建"）
- **证据**：静态确定 —— ① 每个 rune 只更新区间，没有把数字位累加进 `hash`；最后一行 `encode(lng, lat)` 才是 hash 的来源，而 `lng`/`lat` 是**区间更新之前**的中点，即 4 个子格的公共角点；② 角点重新 encode 必然按边界规则落到另一个子格：`tryParse("0"×32)` 的角点恒为 `(0, 0)`，按 `:41/:49` 的判定得 `lng/lat` 全 1 位 ⇒ 返回 `hash = 0xFFFF…`，`toString` 得 `"3"×32`；`tryParse("3"×32)` 反过来得 `"0"×32`；③ `encode(...)` 返回 `GeoHash`，靠 `T?` 的隐式装箱变成 `Option<GeoHash>`，所以"少了一个 `Some`/`None` 判断"在编译期看不出来。
- **描述**：`tryParse`/`parse` 对任何合法四进制串都返回一个**与输入无关**的值（实际只有 4 种结果），`parse(x).toString() != x` 恒成立；空串不返回 `None`（循环不执行，`lng=lat=0` ⇒ 返回 `Some(0xFFFF…)`），长度 > 32 的串也不拒绝（多出的 rune 继续收缩已退化的区间）。`parse` 的 `GeoHashException` 因此只在遇到非 `0..3` 字符时触发，"字符串非法"这条契约等于没实现。
- **建议**：按位重建——`var h = 0u64; var n = 0; for (r in hash.runes()) { match (r) { case r'0'..r'3' => h = (h << 2) | UInt64(r - r'0'); case _ => return None }; n += 1 }`，再校验 `0 < n <= 32`（或允许短串但至少拒绝空串），最后 `Some(GeoHash(h))`。不要复用 `encode`——`encode` 走的是"点 → 位"，`tryParse` 要的是"位 → hash"，两者混用就是这个 bug 的根源。补用例：`parse("0")`、`parse("0"×32)`、`parse("")`、`parse("0"×33)`、`parse("4")`。

### [严重][存量] isPrime：qpow/millerRabin 的 UInt64 乘法溢出，p ≳ 2³² 直接抛 OverflowException

- **位置**：`f_util/src/prime.cj:31`（`ans = (ans * aa) % m`）、`:34`（`aa = (aa * aa) % m`）、`:49`（`t = (t * t) % p`）
- **来源**：存量（`git blame` 落在换行统一提交，逻辑自 `030b8c0b0` 起未变）
- **判据**：review-checklist §11（错误处理缺失 / 契约与实现不符）+ §10 正确性
- **证据**：静态确定 —— 仓颉算术运算默认禁止溢出：`basic_operators.md:5`「算术操作符（`+`、`-`、`*`、`/`、`%` 等）的结果会被检测并禁止值溢出」，`integer.md:137`「根据默认的溢出策略将抛出异常」，`Appendix/compile_options.md:233-235`「`--int-overflow=[throwing|wrapping|saturating]`，默认为 `throwing`」；`f_util/cjpm.toml` 未设置 `compile-option`，即用默认 `throwing`。`aa < m`，当 `m > 2³²` 时存在 `aa ≥ 2³²`，`aa * aa ≥ 2⁶⁴` 必然溢出（`ans * aa` 同理，`t * t` 在 `millerRabin` 里同样）。
- **描述**：`isPrime(p: UInt64)` 的声明域是全部 `UInt64`，但只有 `p < 2³²` 能正常返回；`p ≥ 2³²`（例如判一个 64 位哈希/随机数是否为素数）会在 `qpow` 里抛 `OverflowException`，把"谓词"变成"异常源"。同类问题：`qpow(a, b, 0)` 的 `% 0` 抛 `ArithmeticException`、`millerRabin(x, 0)` 的 `p - 1` 无符号下溢抛异常，而三个函数都没有参数前置条件说明。
- **建议**：改成"128 位中间积"——用 `UInt128`（本模块已有 `f_util/src/UInt128.cj`）或 `mulHigh`/`CheckedOp` 做模乘，不要把 `UInt64` 直接相乘；`qpow` 开头 `if (m < 2) { throw IllegalArgumentException("modulus must be >= 2") }`，`millerRabin` 断言 `p > 2 && x % p != 0`；补用例 `isPrime(UInt64.Max)`、`isPrime(0xFFFFFFFFFFFFFFC5)`（已知素数）、`isPrime(3825123056546413051)`（见下一条）。

### [一般][存量] crc32 的平台空实现只按 `os` 收口，Linux 上的 riscv64 / loongarch64 会编译失败

- **位置**：`f_util/src/crc32_native_stub.cj:23`（`@When[os != "Linux"]`）
- **来源**：存量
- **判据**：review-checklist §11（契约与实现不符）+ §14.1（能力覆盖缺失）
- **证据**：静态确定 —— `crc32.cj:101/:106` 无条件引用 `Crc32Hw.update(...)`，`crc32_native_arm.cj:34` 与 `crc32_native_x86.cj:32` 分别被 `@When[os == "Linux" && arch == "aarch64"]` / `[..., arch == "x86_64"]` 收口，于是 `Linux + riscv64|loongarch64` 上 `Crc32Hw` **没有任何定义** ⇒ 编译失败。同族 `crc64_native_stub.cj:24` 用的是正确写法 `@When[os != "Linux" || (arch != "aarch64" && arch != "x86_64")]`，其注释 `:20-22` 明确写了"后者若漏掉，`CrcEngine` 引用 `Crc64Hw` 时会因缺少定义而编译失败（riscv64 / loongarch64）"。契约侧：`f_util/README.md:71` 承诺"其它 OS/架构始终纯软件"。
- **描述**：README 与 `crc64` 的 stub 都把"Linux 非 x86/aarch64"当成受支持平台（纯软件回退），只有 `crc32` 的 stub 漏了这一维；`crc32_native_stub.cj:21` 的注释"只有这两种 target 存在"是未经证实的假设，与同目录 `crc64` stub 的注释直接矛盾。
- **建议**：`crc32_native_stub.cj:23` 改成与 `crc64_native_stub.cj:24` 完全一致的 `@When` 条件；把两个 stub 的 `@When` 表达式抽成一个常量注释块，避免再次分叉。

### [一般][存量] `F_UTIL_CRC_HW=off` 对 CRC-32 无效：两套开关解析只认 `"0"`

- **位置**：`f_util/src/crc32_native_arm.cj:159-164`、`f_util/src/crc32_native_x86.cj:194-199`（`case Some(v) => v != "0"`）
- **来源**：存量
- **判据**：review-checklist §11（契约与实现不符 / 同一开关两套语义）+ §2（字面量复制的重复逻辑已漂移）
- **证据**：静态确定 —— `crc64_native_arm.cj:287-299` / `crc64_native_x86.cj:295-307` 的 `parseMode` 接受 `off`/`0`（Off）、`on`/`1`（On）、其它或未设（Auto）；`crc32` 的 `envEnabled` 只把 `"0"` 当关闭，`"off"`/`"OFF"`/`"false"` 全部被当成"开启"。README 侧：`f_util/README.md:88` 对外发布的口径是"`F_UTIL_CRC_HW=off`（或 `0`）强制回退"，`README.md:71` 只提 `=0`。
- **描述**：按 CRC-64 的文档关硬件（`off`）时 CRC-32 的生成式路径仍然启用，排障/规避 `mprotect` 被拦截时会出现"关了但一半没关"；`doc/spec/accelerate-f-util-crc/design.md:192` 自己写的是"`0`/`off` 视为 off、`1`/`on` 视为 on"，说明两份实现本应一致。附带：`crc32` 的 `resetForTest`（`arm:120-127`/`x86:150-157`）不重置 `nativeEnabled`，而 `crc64` 的 `resetForTest`（`arm:197-212`/`x86:220-236`）会把 `forcedOff` 复位，同名测试钩子语义不同，用例顺序会互相影响。
- **建议**：把 `parseMode`/`isOff` 上提为一个共享的 `CrcHwMode` 解析函数（`CrcGf.cj` 已有 `enum CrcHwMode`），四个 native 文件都调它；`resetForTest` 统一"恢复到初始态（含开关）"。

### [一般][存量] CRC 硬件层的脚手架在 4 个文件里各写一遍，已出现三处分叉

- **位置**：`f_util/src/crc32_native_arm.cj:36-186` 与 `f_util/src/crc32_native_x86.cj:34-212`（`lock`/`ready`/`nativeEnabled`/`codes`/`available`/`availableFor`/`update`/`call`/`setNativeEnabled`/`resetForTest`/`ensureReady`/`make`/`envEnabled`/`cpuFlags` 逐行同构，差异只有 CPU 探测与 `update` 的 dispatch）；`f_util/src/crc64_native_arm.cj:33-305` 与 `f_util/src/crc64_native_x86.cj:36-321`（`mode`/`parseMode`/`isOff`/`call`/`make`/`resetForTest`/`available` 同构）
- **来源**：存量
- **判据**：review-checklist §2（只改类型名 / 换控制流的重复实现）
- **证据**：静态确定 —— 已发生的语义漂移：① `envEnabled` 两态 vs `parseMode` 三态（上一条）；② `crc64_native_arm.cj:214-232` 的 `ensureReady` 只返回 `fn.isSome()`，而 `crc64_native_x86.cj:238-257` 返回 `fn.isSome() || fnNorm.isSome()`；③ `crc32_native_arm.cj:166-173` 的 `hasCrc32` 有 `/proc/cpuinfo` 回退，`crc64_native_arm.cj:301-305` 的 `hasPmull` 只读 `getauxval`，容器屏蔽 auxv 时 CRC-32 能用硬件、CRC-64 静默回退；④ `resetForTest` 对开关的复位不一致（上一条）。这些差异没有任何一处被注释说明，只能靠逐行对比发现。
- **建议**：抽一个包内 `struct CrcHwSlot`（`ready` + `lock` + 已就绪的 `?CFunc` + `codes` 保活表 + `acquire/release` 包装），平台文件只提供 `probe(): Bool`、`code(): Array<UInt8>`、`consts()`；`CrcHwMode` 解析、`cpuFlags` 读取、`call` 的 `acquireArrayRawData/finally release` 各只保留一份。合并前先补 4 个文件的对拍用例（同输入下四个平台实现的 raw 值相等），作为等价性门槛。

### [一般][存量] Miller-Rabin 在循环中途 `t == 1` 也返回 true，且 5 个基不足以覆盖 UInt64

- **位置**：`f_util/src/prime.cj:45-51`（`if (t == 1 || t == p - 1) { return true }` 在每次平方之前执行）、`:63`（`let a: Array<UInt64> = [2, 3, 5, 7, 11]`）
- **来源**：存量
- **判据**：review-checklist §11（逻辑错误 / 契约与实现不符）
- **证据**：静态确定（分支语义）—— 标准强伪素数判定只允许在两个位置认定"可能为素数"：首轮 `t == 1 || t == p-1`，以及后续某一轮平方后 `t == p-1`；**平方之后出现 `t == 1` 说明找到了 1 的非平凡平方根，应判合数**。本实现把 `t == 1` 放在循环体内无条件 `return true`，等价于把这种情况判成素数。另：`{2,3,5,7,11}` 这组基只在约 `2.15×10¹²` 以下确定，`p` 取更大值时存在强伪素数（如 `3825123056546413051` 对前 9 个素数基都是强伪素数），`public func isPrime` 却按"判定素数"承诺 Bool——具体反例需实测（受上一条溢出问题遮挡，当前会先抛异常）。
- **描述**：即使修好模乘溢出，`isPrime` 仍会对一部分合数返回 `true`，且返回值没有"probable"语义提示（无 `isProbablePrime` 之类的命名区分）。
- **建议**：把 `t == 1` 的判定移到"首轮"（循环外）或直接判为 `false`；基表改为 `{2, 3, 5, 7, 11, 13, 17, 19, 23, 29, 31, 37}`（对 64 位确定）或补一轮 Baillie-PSW；函数名/KDoc 写明"64 位确定性判定"或"概率判定 + 误差界"。

### [轻微][存量] crc64_native_arm 的 `ensureReady` 只看反射核，正常域核存在时仍回退表路径

- **位置**：`f_util/src/crc64_native_arm.cj:214-232`（`:216-217` 与 `:228` 只判 `fn.isSome()`）
- **来源**：存量
- **判据**：review-checklist §2（近似重复导致的行为漂移）+ §11（错误处理不对称）
- **证据**：静态确定 —— `available()`（`:96-102`）用 `fn.isSome() || fnNorm.isSome()`，`updateNormal()`（`:144-151`）依赖 `ensureReady()` 的返回值；当 `REF_CODE` 的 `write`/`seal` 失败而 `NORM_CODE` 成功时（`make`/`makeNormal` 各自独立失败，`failAlloc` 只覆盖"同时失败"），`available()` 为 true、`ensureReady()` 为 false ⇒ `ecma182/we` 静默走表路径。x86 版 `:238-257` 已正确返回两者之或。
- **描述**：aarch64 上的非反射 256B+ 数据可能无声地掉到表路径，只体现为吞吐下降，没有任何日志或返回值区分。
- **建议**：`ensureReady()` 末尾改成 `fn.isSome() || fnNorm.isSome()`，与 x86 版一致；`updateNormal` 单独判断 `fnNorm`（即 `if (fnNorm.isNone()) return None`），使两个核的可用性互不牵连。

### [轻微][存量] Crc64Hw.update/updateNormal 不校验 `aligned % 16`，违反 KDoc 前置条件时静默产出错值

- **位置**：`f_util/src/crc64_native_arm.cj:108-111`、`:144-148`；`f_util/src/crc64_native_x86.cj:148-152`、`:164-168`
- **来源**：存量
- **判据**：review-checklist §11（缺少边界校验 → 静默错误值）
- **证据**：静态确定 —— KDoc（`arm:105`、`x86:109`）要求"`aligned` 必须是 16 的倍数且 >= 16"，代码只判 `aligned < 16 || aligned > data.size`。折叠核按 16 字节循环推进，`aligned = 20` 时只消费前 16 字节却把结果当作覆盖 `data[0..20]` 返回，调用方据此跳过软件补齐 ⇒ CRC 错。当前唯一调用点 `CrcEngine.cj:206`/`:219` 传入 `data.size - data.size % 16`，暂时安全。
- **描述**：`Crc64Hw` 是包内类型，但 `update`/`updateNormal` 在 `CrcEngine_test.cj:536` 被直接调用，说明"内部 API 也会被绕过使用"；前置条件没有运行时断言，错用后只表现为哈希值不对，排查成本高。
- **建议**：加一行 `if (aligned % 16 != 0) { return None }`（或 `debug` 断言 + `None`），让违约回退到表路径而不是算错。

### [轻微][存量] 死代码：`Crc32Hw.available()`（3 份）与 `Crc64Hw.modeNameForTest()`（3 份）全项目零引用

- **位置**：`f_util/src/crc32_native_arm.cj:68-74`、`f_util/src/crc32_native_stub.cj:25-27`、`f_util/src/crc32_native_x86.cj:86-92`；`f_util/src/crc64_native_arm.cj:184-190`、`f_util/src/crc64_native_stub.cj:54-56`、`f_util/src/crc64_native_x86.cj:207-213`
- **来源**：存量
- **判据**：review-checklist §1（非 public 顶级声明里的成员，全项目无使用即死代码）
- **证据**：静态确定 —— `Crc32Hw`/`Crc64Hw` 都是包内 `class`（无 `public`），成员按硬原则二判。全仓搜 `available()` 只有 `Crc64Hw.available()` 的 5 处调用（`CrcEngine_test.cj:407/435/455/483/561`），`Crc32Hw.available` 只有 3 处定义、0 处调用；`modeNameForTest` 只有 3 处定义，全仓 0 处调用（三态用例 `CrcEngine_test.cj:477-524` 断言的是 `lastUsedNativeForTest()`，没用它）。`CrcHwMode.On` 也只在 `modeNameForTest` 里被读到，删除该函数后 `On` 变成只写不读。
- **描述**：`available()` 在 CRC-32 侧是"写过但没用上"的诊断入口（`availableFor()` 才是测试用的那个）；`modeNameForTest` 是三轮用例改造后的残留。二者都会误导读者以为存在对应的诊断路径。
- **建议**：删除 CRC-32 的三份 `available()` 与三份 `modeNameForTest()`；若确实需要"整体可用性"诊断，让 `Crc32Hw.available()` 在 `availableFor` 之上被真正使用一次（例如 `Crc32` 的 `toString`/诊断日志），否则不留。

### [轻微][存量] crc64.cj 有一处悬空 KDoc（NVME 变体说明），不挂在任何声明上

- **位置**：`f_util/src/crc64.cj:48`（`/** 未收录（参数待核对，宁缺勿错）：CRC-64/NVME ... */`，紧跟着 `:49` 的另一段 KDoc 修饰 `:50` 的 `all`）
- **来源**：存量
- **判据**：review-checklist §1（文档残留 / 读了不用）+ §10 可维护性
- **证据**：静态确定 —— 连续两段 `/** */` 时后一段覆盖前一段作为 `all` 的文档，`:48` 的内容不会出现在任何生成的 API 文档里。
- **描述**：注释本身是有价值的信息（说明为何缺 NVME 变体），但位置使其失效；`Crc64.all` 的文档变成"全部变体：便于遍历自检"，读者看不到"NVME 未收录"的原因。
- **建议**：把 `:48` 并入类级 KDoc（`:20-32`）或 `:49` 的文档块内，作为"未收录变体"小节。

### [轻微][存量] 测试钩子改静态状态无同步；`resetForTest` 与正在执行的 `CFunc` 之间有 use-after-munmap 窗口

- **位置**：`f_util/src/crc32_native_arm.cj:38`（`nativeEnabled`，`:89`/`:117` 锁外读、`:116-118` 无锁写）、`:120-127`（`resetForTest` 在锁内 `codes.clear()`）；`f_util/src/crc32_native_x86.cj:36`/`:150-157`；`f_util/src/crc64_native_arm.cj:36-42`、`:139`、`:197-212`；`f_util/src/crc64_native_x86.cj:39-45`、`:193`、`:197-236`
- **来源**：存量
- **判据**：review-checklist §12.1（共享可变状态无保护；跨线程资源）
- **证据**：静态确定 —— 两个并发访问者：① 测试线程调 `setNativeEnabled(false)`（无锁写 `nativeEnabled`/`forcedOff`）与计算线程在 `update()` 入口无锁读（`arm:89`、`x86:113`）；② 计算线程 A 在 `call()` 里已把 `?CFunc` 解构成局部 `f` 并进入机器码，测试线程 B 调 `resetForTest()` 在锁内 `codes.clear()` 释放 `CodeBuffer`（对应 `mmap` 页），A 继续执行已 `munmap` 的页 ⇒ 段错误。触发面仅限测试代码（`crc32_codegen_test.cj` 有 4 个并发 `spawn`，`CrcEngine_test.cj` 单线程），生产路径只读不写，故定轻微。
- **描述**：`lastNative`（`crc64` 两版）同样是"每次 update 无锁写、测试读"，并发 update 下本身就有数据竞争，三态用例的断言可能读到别的线程写的值。
- **建议**：把开关字段改为 `AtomicBool`/原子读写（或统一在 `lock` 内读写，`ensureReady` 已持锁，只需把入口判断也挪进去）；`resetForTest` 只清指针字段，代码页延迟释放（或断言"此时无并发调用"并在 KDoc 写明"仅限单线程测试使用"）。

### [轻微][存量] 5 个异常类逐行同构，只有类名不同

- **位置**：`f_util/src/exception/GeoHashException.cj:20-32`、`HashException.cj:20-32`、`IdException.cj:20-32`、`TextTemplateException.cj:20-32`、`UUIDException.cj:20-32`
- **来源**：存量
- **判据**：review-checklist §2（只改类型名的重复实现）
- **证据**：静态确定 —— 5 个文件除类名外逐字符相同（4 个 `init` 全部是 `super(...)` 转发）。5 个类都在使用：`geohash.cj:126`（`GeoHashException`）、`UInt128.cj:61`（`HashException`）、`IdMaker.cj:30`（`IdException`）、`TextTemplate.cj:109/249/305/334`、`uuid.cj:180`。
- **描述**：这是"按类型 catch"的正当设计，不能合并成一个类（会丢掉 `catch (e: IdException)` 的区分能力），但每个类 4 个构造器的样板可以收敛。
- **建议**：在 `f_util.exception` 内加一个 `abstract class FUtilException <: BaseException`（含 4 个构造器），5 个具体类改为 `public class XxxException <: FUtilException { public init() { super() } ... }`——仍然保留 5 个类型，但样板从 5×13 行降到 5×5 行 + 1×13 行。若判断"异常族就是要各自独立演进"，在 README 写一句即可，不必改代码。

### [轻微][存量] qpow / millerRabin 作为 public API 没有返回类型声明，也没有参数前置条件

- **位置**：`f_util/src/prime.cj:25`（`public func qpow(a: UInt64, b: UInt64, m: UInt64) {`）、`:39`（`public func millerRabin(x: UInt64, p: UInt64) {`）
- **来源**：存量
- **判据**：review-checklist §10（可读性 / API 契约）+ §14.2（README 公开 API 覆盖）
- **证据**：静态确定 —— 两处都靠 `return ans` / `return true|false` 让编译器推导返回类型（`define_functions.md:111` 允许推导），签名对调用方不可见；README 只把它们列在 `:725` 的公开符号清单里（"`millerRabin`（func）、`qpow`（func）"），没有签名、没有 `m > 1`/`x < p`/`x % p != 0` 的约束说明。另外 `millerRabin(x, p)` 当 `x % p == 0`（如 `x == p`）时对素数也返回 `false`，这个前提同样没写。
- **描述**：这是三个"零引用、零测试"的公开函数里的两个（`isPrime` 也零引用，见文件覆盖表），既没有签名文档也没有前置条件，下游只能靠读实现猜语义。
- **建议**：补显式返回类型（`: UInt64` / `: Bool`）与参数约束的 KDoc；`millerRabin` 把 `x % p == 0` 归到"合数"或显式声明"要求 `1 < x < p`"；README 的公开清单补签名。

### [轻微][存量] GeoHash.encode 不校验经纬度范围，越界/NaN 静默产出 hash

- **位置**：`f_util/src/geohash.cj:31-59`（无 `MIN/MAX_LATITUDE/LONGITUDE` 校验，`:24-27` 的四个常量只在二分里用）
- **来源**：存量
- **判据**：review-checklist §11（缺少边界校验）
- **证据**：静态确定 —— `encode(200.0, 100.0)` 不抛异常，二分对"点永远在区间外"的输入不收敛到任何有效位置（当前因上一条 bug 更极端：直接退化成符号位）；`Float64.NaN` 与任何值比较都是 `false`，两个判断都走 else 分支，返回一个固定 hash 而不报错。
- **描述**：`GeoHash` 是 `Parsable`/`DataParsable`，经纬度常来自外部（GPS、JSON、DB），越界值应当拒绝而不是给一个看似正常的 hash。
- **建议**：入口加 `if (!(latitude >= -90.0 && latitude <= 90.0) || !(longitude >= -180.0 && longitude <= 180.0)) { throw IllegalArgumentException("...") }`（NaN 会被这组比较自然拒绝）；`encode(coordinate:)` 复用同一校验。

### [轻微][存量] README 的 `encode(latitude, longitude)` 与实现的 `(longitude, latitude)` 顺序相反

- **位置**：实现 `f_util/src/geohash.cj:31`（`encode(longitude: Float64, latitude: Float64)`）；文档 `f_util/README.md:304`（`public static func encode(latitude: Float64, longitude: Float64)`）、`README.md:306`（`GeoHash.encode(coordinate[0], coordinate[1])` 紧随上一行的 `(latitude, longitude)`，暗示 `coordinate[0]` 是纬度）
- **来源**：存量（README 归其它部分，此处只作契约取证）
- **判据**：review-checklist §13（文档与代码不一致）+ §11（语义与命名不符）
- **证据**：静态确定 —— 命名实参调用按名字绑定，所以 `encode(latitude: 39.9, longitude: 116.4)` 恰好正确；但按 README 的**位置**调用 `encode(39.9, 116.4)` 会把纬度当经度。源码 `:60-62` 的 KDoc 写的是 `(longitude, latitude) = (coordinate[0], coordinate[1])`，与 README 的 `:306` 相反。
- **描述**：同一份契约在两个地方给了相反顺序，`encode(coordinate:)` 的元组顺序因此没有唯一答案；`f_data`/下游按 README 写调用会静默交换经纬度（对 geohash 来说就是完全不同的格子）。
- **建议**：README 的签名与 `README_en.md:306` 改为 `(longitude, latitude)`，`encode(coordinate:)` 的文档明确"`coordinate[0]` 是经度"；建议在 KDoc 里同时给一个具体例子（`encode(116.4, 39.9) // 北京`）避免再反。

## 优化可行性方案

> 均无改前基线，只作"待验证"方案，不进 `tasks.md`。

### [CPU] 每次 `update` 都要进一次全局 `Mutex`，可改为就绪后的无锁快路径

- **现状**：`Crc32Hw.update`（`crc32_native_arm.cj:92` / `crc32_native_x86.cj:116`）与 `Crc64Hw.update/updateNormal`（`crc64_native_arm.cj:113/:149`、`crc64_native_x86.cj:153/:169`）在每次调用开头都走 `ensureReady()` → `synchronized(lock)`；初始化完成后临界区只有 `if (ready)` 一次读 + 两个 `isSome()`。调用方 `CrcEngine.cj:205/:218` 只在 `data.size >= 256` 时启用硬件，并把整段数据**一次性**传入（非分块），因此单次数据越大，这次锁的相对成本越低；但帧/WAL 这类 256B~4KiB 的调用频次高。
- **方案**：`ready` 改为 `AtomicBool`（或 `std.sync` 的原子布尔），`update` 入口 `if (ready.load()) { 直接取缓存的 CFunc } else { ensureReady() }`；`ready=true` 的发布与 `fn`/`constsXx` 的写入用同一次 release/acquire（或在 `ready` 置真前完成写入，再原子置真）。`lock` 只保护首次初始化。
- **预期**：每次 update 省一次互斥进入/退出（数量级 10 ns，未测）；并发调用下消除单个全局互斥点。
- **代价**：需要正确实现发布语义（否则 `fn` 的可见性退化）；`resetForTest` 必须先把 `ready` 置假再清指针，否则别的线程会读到"就绪但为空"的状态。改动面 4 个文件，建议与上文"脚手架合并"一起做。
- **验证**：`cjpm bench -O2`，256B/4KiB/1MiB 三档 + 1/8 线程，对照 P50/P99；另采线程状态（BLOCKED 次数）确认竞争是否真的消失。
- **证据状态**：`无基线（待验证，不进 tasks）`

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 高并发下每次 update 的全局 `Mutex` 成为串行点（尤其 256B 小帧） | `crc32_native_arm.cj:129-144`、`crc64_native_x86.cj:238-257` | 锁等待时长、BLOCKED 线程数、随线程数的吞吐曲线 | 1/2/4/8 线程 × 10⁶ 次 256B update，采线程状态 + `cjprof`，与"无锁快路径"版本对照 |
| 2 | `CrcEngine` 的 256B 阈值使 16~255B 的帧校验全部走表路径，是 `f_protocol`/`f_store` 的热点 | `CrcEngine.cj:205/:218`（范围外，经本部分 KDoc/常量发现） | 真实帧长分布与各长度段的调用占比 | 在 `f_protocol` 帧校验处埋点统计帧长直方图，再对这些长度单测表路径吞吐 |
| 3 | `cpuFlags()`/`hasPclmul()` 首次调用整读 `/proc/cpuinfo`（数十 KB）造成首请求抖动 | `crc32_native_x86.cj:201-212`、`crc32_native_arm.cj:175-186`、`crc64_native_x86.cj:309-321` | 首次 `availableFor()` 的耗时 | 分段计时 100 次冷启动进程的首调用 |
| 4 | `GeoHash.toString()` 每次 32 次 `append<T>(UInt64)`，每次分配一个 String | `geohash.cj:100-103` | 单次调用分配字节数 | `cjprof` + `getAllocatedHeapSize()` 跑 10⁶ 次；对照直接写 32 个 ASCII 字节 |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_util/src/crc32_native_arm.cj` | .cj | ✅ | 见 §2（脚手架重复）、§12 轻微（测试钩子无同步）、§1 死代码（`available()`）、§6.2（每次 update 取锁，进优化方案）；`hasCrc32` 有 auxv + `/proc` 双路径；`:51-66` 的机器码字节未反汇编核对（只读审查、无目标平台工具链），正确性依赖 `crc32_codegen_test` 的硬件/软件对拍 |
| 2 | `f_util/src/crc32_native_stub.cj` | .cj | ✅ | 见 §14 一般（`@When` 漏 arch，Linux riscv64/loongarch64 编译失败） |
| 3 | `f_util/src/crc32_native_x86.cj` | .cj | ✅ | 同 #1；另 `:145` 注释"重新打开需要 `resetForTest()`"与实现不符（`ready`/`fn` 未清，直接 `setNativeEnabled(true)` 即恢复），并入 §2/§12 观察项 |
| 4 | `f_util/src/crc64.cj` | .cj | ✅ | 6 个变体的 poly/init/refin/xorout/check 与 RevEng catalog 一致（另有 `crc_check_test` 兜底）；见 §1 轻微（`:48` 悬空 KDoc） |
| 5 | `f_util/src/crc64_native_arm.cj` | .cj | ✅ | 见 §11 轻微（`ensureReady` 忽略 `fnNorm`）、§11 轻微（未校验 `aligned % 16`）、§1（`modeNameForTest`）、§12（`lastNative` 无同步） |
| 6 | `f_util/src/crc64_native_stub.cj` | .cj | ✅ | 三平台收口写法正确（是本部分唯一正确的 stub），见 §1（`modeNameForTest` 死代码） |
| 7 | `f_util/src/crc64_native_x86.cj` | .cj | ✅ | 见 §2（与 arm 版脚手架重复 + 3 处漂移）、§11 轻微（`aligned` 校验）、§1（`modeNameForTest`）、§12 |
| 8 | `f_util/src/crc_check_test.cj` | .cj | ✅ | 设计好：16/32/64 三族"全变体 × catalog 检查值 + 顶层 API 指向 + 增量=一次算完 + 空输入=finish(init)"四类断言齐全；不足：`@Fail` 在每个变体循环里会中断，一次运行只能看到第一个偏差；未覆盖 `GeoHash`/`prime`（它们各自零测试） |
| 9 | `f_util/src/exception/GeoHashException.cj` | .cj | ✅ | 见 §2 轻微（5 个异常类同构）；被 `geohash.cj:126` 使用 |
| 10 | `f_util/src/exception/HashException.cj` | .cj | ✅ | 同上；被 `UInt128.cj:61` 使用（该处构造后未 `throw`，已在 part2 报） |
| 11 | `f_util/src/exception/IdException.cj` | .cj | ✅ | 同上；被 `IdMaker.cj:30` 使用 |
| 12 | `f_util/src/exception/TextTemplateException.cj` | .cj | ✅ | 同上；被 `TextTemplate.cj:109/249/305/334` 使用 |
| 13 | `f_util/src/exception/UUIDException.cj` | .cj | ✅ | 同上；被 `uuid.cj:180` 使用 |
| 14 | `f_util/src/geohash.cj` | .cj | ✅ | 本部分最高风险文件：`encode` 方向反了（4 个 hash）、`tryParse` 用中点重算、无范围/长度校验；无任何测试 |
| 15 | `f_util/src/prime.cj` | .cj | ✅ | 见 §11 严重（模乘溢出）、§11 一般（MR 中途 `t==1`、5 基不足）、§14 轻微（无返回类型/前置条件）；零引用零测试 |

合计：`.cj` 15 个 / `.md` 0 个 / 共 15 个，全部读完（本部分未分配 `.md`；`README.md`/`README_en.md`/`doc/spec/**` 仅作契约取证引用，正式审查归其它部分）。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 12 | 正确性 6（`encode` 方向、`tryParse` 重建、`isPrime` 溢出、MR 分支、5 基不足、`aligned` 未校验）；设计 2（`F_UTIL_CRC_HW` 两套语义、4 份脚手架分叉）；语言特性 3（`GeoHash.encode` 无输入校验含 NaN、`qpow`/`millerRabin` 依赖返回类型推导、`Option` 隐式装箱掩盖 `tryParse` 少判 `Some`）；可读性 1（`crc64.cj:48` 悬空 KDoc）；安全性 0（无凭据、无注入面；`CFunc` 只调本地生成代码，`acquireArrayRawData` 均有 `finally release`） |
| §1 死代码 | 3 | 逐个 `private`/包内成员搜全仓：① `Crc32Hw.available()` ×3 零调用；② `Crc64Hw.modeNameForTest()` ×3 零调用（连带 `CrcHwMode.On` 变成只写）；③ `crc64.cj:48` 悬空 KDoc（文档残留）。`Crc32Hw.availableFor`/`Crc64Hw.available`/`lastUsedNativeForTest`/`forceAllocFailureForTest` 均有测试引用（仅测试引用按"可见性建议"处理，不判死代码）；`supports`/`supportsNormal`/`update`/`updateNormal` 有 `CrcEngine.cj` 生产引用；`crc32_native_*`/`crc64_native_*` 的私有常量与探测函数全部有本文件引用；`qpow`/`millerRabin`/`isPrime`/`GeoHash`/5 个异常类是顶层 public（对外可达），仓内零引用不判死代码 |
| §2 重复逻辑 | 2 | ① `crc32_native_arm`↔`crc32_native_x86`、`crc64_native_arm`↔`crc64_native_x86` 的锁/就绪/保活/调用/复位脚手架逐行同构（含 `cpuFlags`、`envEnabled`/`parseMode`、`call`、`make`、`resetForTest`，即同族 4 组"就绪标志 + 双核"状态机是同一套语义的 4 份实现），且已漂移 4 处；② 5 个异常类只改类名。`geohash` 的 `encode`/`decode` 各写一遍二维二分，但两方向（点→位 / 位→点）语义不同，不判重复 |
| §3 空实现 | 0 | 空函数体只有 2 个平台 stub 文件（`crc32_native_stub`、`crc64_native_stub`）与 `setNativeEnabled`/`resetForTest` 的 no-op 分支，均有注释说明"非目标平台恒走软件 / 没有 native 路径"，属清单允许的有意 Null Object；无 `TODO`/`FIXME`/`UnsupportedException` |
| §4 栈溢出 | 0 | `geohash`（32 轮定长循环）、`prime`（`while` 迭代）、`crc*`（无递归）全部是迭代；`qpow`/`millerRabin` 调用深度恒定 1 层 |
| §5 OOM | 0 | `codes` 只在首次 `ensureReady` 追加（≤2 项、每项 <1 KiB，`resetForTest` 清空），无随请求增长；`cpuFlags` 只读一次 `/proc/cpuinfo`；`crc_check_test` 的 `payload` 固定 1777 B；无按外部长度预分配 |
| §6.1 热点瓶颈 | 0 | 未提供 `cjprof`/`cjpm bench` 数据（`scope.md`「已有性能资料」为空），热点结论不成立；4 条候选已进「待验证假设」，1 条结构线索进优化方案并标 `无基线` |
| §6.2 大粒度锁 | 1 | 每次 `update` 都进全局 `Mutex`（临界区只有读 `ready`）——结构上属"高频小临界区"，不是"锁内做 O(输入) 动作"；无锁等待数据，故只进「优化可行性方案 [CPU]」，不作缺陷计数 |
| §6.3 并发串行 | 0 | 本部分无 `spawn`/`Future`；`crc32_codegen_test` 的 4 路并发不在本部分 |
| §6.4 低效算法 | 0 | CRC 路径是 O(n) 单遍（硬件/表两条都无嵌套）；`hex()` 与 `GeoHash.toString()` 的逐位/逐字符分配属常数级线索，无占比数据，已并入待验证假设 #4 |
| §7 降堆内存方案 | 0 | 本部分无常驻大对象：`codes` <2 KiB、无缓存表、无全量物化；`GeoHash` 是 8 字节 struct。没有可量化收益的方案，故不凑数 |
| §8 降 CPU 方案 | 1 | `ensureReady` 无锁快路径（见优化方案）；其余（脚手架合并）属可维护性，已计入 §2 |
| §9 local mode 可行性 | 0 | 候选只有 `encode`/`decode` 的标量循环（无堆分配）与 `toString` 的 32 个小串（返回值逃逸），无"函数内大临时对象"，不满足立项前提 |
| §11 现有代码的 BUG（存量） | 16 | 全部 16 条发现均为存量（快照模式无基线），逐条核对了边界（经纬度范围/空串/超长串/`aligned`/`p<2`）、空值（`?CFunc`、`?Array` 的 `match` 全覆盖）、错误处理（`resetForTest` 与执行中 `CFunc` 的 UAF 窗口、`ensureReady` 返回值不对称）、契约（`F_UTIL_CRC_HW` 两套语义、README 参数顺序、`isPrime` 声明域） |
| §12 并发安全与锁粒度 | 1 | 已列出共享点与同步手段：`ready`/`crc32c`/`iso`/`fn`/`fnNorm`/`constsXx`/`codes` 都在 `synchronized(lock)` 内读写（首次初始化安全）；`nativeEnabled`/`forcedOff`/`lastNative`/`failAlloc` 在锁外读写（发现 1 条轻微）；`GeoHash` 是值类型、`Crc64` 实例字段全 `let`、`CrcEngine` 的表为静态只读 ⇒ 判安全 |
| §13 文档一致性（.md） | 1 | 本部分未分配 `.md`；为取证读了 `README.md:71/88/304-306`、`README_en.md:71/88/306`、`doc/spec/accelerate-f-util-crc/design.md:192/243-249`、`doc/spec/crc32-hw-cfunc/design.md:35`：命中 1 条（`encode(latitude, longitude)` 与实现相反），其余（CRC-64 三态开关、256B 阈值、无 C 垫片）与实现一致；`doc/spec/crc32-hw-cfunc` 只承诺 `=0`，与 `crc32` 实现一致，但与 `accelerate-f-util-crc` 的统一口径冲突（已计入 §11 一般） |
| §14 功能完备性与 README 覆盖 | 2 | ① `crc32_native_stub` 漏 arch 收口，README 承诺的"其它架构纯软件"在 Linux riscv64/loongarch64 上不成立；② `qpow`/`millerRabin`/`isPrime` 是公开 API，README 只有符号名（`:725`）没有签名与限制说明，`isPrime` 对 `p ≥ 2³²` 的实际行为（抛异常）也与"判定素数"的承诺不符。`Crc64` 的 6 个变体、`Crc32`/`Crc16` 的变体表、异常族清单（`README.md:660`）与实现逐项一致，无"公开 API 完全无文档"项 |
| 文件覆盖（§13 等） | 15/15 | 15 个文件全部读完，本部分无 `.md` 分配；`README.md`/`README_en.md`/`doc/spec/**` 仅作契约取证 |

## 模块统计（本部分）

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 3 |
| 一般 | 4 |
| 轻微 | 9 |
| 优化方案（堆内存 / CPU） | 0 / 1 |

存量缺陷共 16 条，是否纳入修复待用户在门禁决定。

## 总评

本部分的质量分成两档，界线很清楚：**CRC 的机器码与调度是真的做过工程的，`geohash`/`prime` 则基本没被验证过**。

CRC 这一档：6 个变体的参数与 RevEng 检查值自洽，`crc_check_test` 用"全变体 × catalog 检查值 + 顶层 API 指向 + 增量=一次算完 + 空输入"四类断言把参数钉死，`CrcEngine_test` 另有硬件/软件对拍、三态开关与分配失败回退的用例（`crc32_codegen_test` 还覆盖了 4 路并发与非对齐长度，见 part2）——这是本模块最扎实的一组测试。原生实现本身没发现问题：`mmap`→`mprotect` 的失败一律返回 `None` 回退软件，`acquireArrayRawData` 都有 `finally release`，`@When` 平台收口思路正确（`crc64` stub 的写法就是范本）。问题集中在"四份脚手架各写一遍"带来的漂移上：`F_UTIL_CRC_HW=off` 在 CRC-32 侧不生效、`resetForTest` 语义两边不同、aarch64 少了 `/proc` 回退、arm 版 `ensureReady` 漏了 `fnNorm`，还有 `crc32` stub 漏 arch 维度会在 Linux riscv64/loongarch64 上直接编译失败。这些都不是算法问题，是"复制粘贴后忘了同步"的收尾问题——合并成一份 `CrcHwSlot` 就能一次性消掉，建议排期做。

`geohash` 与 `prime` 是另一档，共同点是**零测试、零引用、公开 API**：

1. `GeoHash.encode` 的二分比较方向反了，导致全部坐标只剩 4 个 hash（整个东北象限 = `0x0`）。这不是"精度不够"或"与标准 base32 不通"，而是函数本身不成立：`decode(encode(北京))` 返回 `(-180, -90)`。`tryParse` 又用"区间中点重新 encode"来实现，`parse(toString(g))` 恒不成立，空串还被当成合法输入。作为 `DataParsable`，这两个函数会把错误值直接写进反序列化路径。
2. `isPrime` 的模乘在 `UInt64` 上溢出，`p ≥ 2³²` 抛 `OverflowException`；即使修好溢出，Miller-Rabin 的 `t == 1` 分支判反了、5 个基也覆盖不到 64 位。三个函数（`qpow`/`millerRabin`/`isPrime`）里前两个没有返回类型，三个都没有前置条件、没有用例。

阻塞项（建议本部分先修）：`GeoHash.encode` 方向 + `GeoHash.tryParse` 重建（一个 20 行的修复 + 4 条用例）、`isPrime` 的模乘溢出、`crc32_native_stub` 的 `@When`。前两条是"对外 API 一调就错"，第三条是"换平台编不过"，修复面都很局部。`F_UTIL_CRC_HW` 语义统一与脚手架合并建议与上面的修复同批做，因为要在同一批文件上改两遍。

范围外提示（不占本轮统计）：① `CrcEngine.cj:205/:218` 的 256B 阈值决定 16~255B 帧全走表路径，是否合理取决于 `f_protocol`/`f_store` 的真实帧长分布（已列待验证假设 #2）；② `CrcEngine_test.cj:477-524` 的三态用例断言的是 `lastUsedNativeForTest()`，若要覆盖"`on` 强制尝试"的语义，`modeNameForTest` 应当是断言入口而不是死代码；③ `f_util/doc/spec/crc32-hw-cfunc/` 与 `accelerate-f-util-crc/` 对同一开关给了两套口径（`=0` vs `off/0/on/1`），合并时应保留三态、把 CRC-32 对齐过去。
