# f_random 模块审查报告

- **审查日期**：2026-11-28
- **模块路径**：`f_random`（8 个 .cj 源文件 + 2 个 .md，源文件共约 1000 行）
- **基线**：工作区快照（sts/1.3.x 工作区，未对照远端目标分支；`git status --short f_random` 为空，工作区干净；本报告全部问题来源记为「存量」）
- **审查重点**：随机算法正确性与偏差、死代码、重复逻辑、并发安全、存量 BUG、README 覆盖率（通用维度 + 全部专项扫）
- **报告版本**：v1

## 发现

### [严重][存量] 浮点区间 `closed: true` 把上界放大 1.0，返回值可超出 `max`

- **位置**：`f_random/src/ExtendRandom.cj:48-54`（`Random.nextFloat64(min,max,closed)`）、`:55-61`（`Random.nextFloat32`）、`:77-83`（`SecureRandom.nextFloat64`）、`:84-90`（`SecureRandom.nextFloat32`）
- **来源**：存量（`git blame -L 47,103` 全部落在 `4be871f2f chore: 统一换行符为 LF`，该文件内容自 2026-10-02 起未变；工作区无改动）
- **判据**：review-checklist §11（契约与实现不符 / 逻辑错误）、§10（`closed` 参数语义）
- **证据**：静态确定 —— 实现是 `nextFloat64() * (max - min + if (closed) { 1.0 } else { 0.0 }) + min`。`nextFloat64()` 的值域是 `[0.0, 1.0)`（std 文档已核对：`random_package_classes.html` 中 `func nextFloat64()` 明确写 `[0.0, 1.0)`），乘 `(max-min+1.0)` 后值域是 `[0, max-min+1)`，加 `min` 得 `[min, max+1.0)`。
- **描述**：`closed` 在接口注释（`ExtendRandom.cj:25-26` 无注释，但 README.md:91-92、README_en.md:90-91 写“closed 表示是否包含 max”）里的语义是“是否包含上界”，实现却是“把跨度加 1”。后果：`rand.nextFloat64(0.0, 1.0, closed: true)` 有约 50% 概率返回 `> 1.0` 的值；任何用 `closed: true` 生成索引 / 百分比 / 概率的调用方都会拿到越界值（索引越界、概率 > 1）。整数路径把 `closed` 原样传给浮点路径（`:63`、`:66`、`:69`、`:72`、`:92`、`:95`、`:98`、`:101`），整数语义“加 1 后 floor”恰好正确，所以同一份代码在整数上是“包含上界”、在浮点上是“上界 +1”——这是把整数技巧套到浮点上的设计错误。README.md:533-535 / README_en.md:535-537 已把该行为如实写成“已知行为”，属于“文档承认的实现缺陷”，文档记录不改变实现与契约相反的事实。
- **建议**：浮点版本改成 `nextFloat64() * (max - min) + min`，`closed` 只用于控制“是否允许恰好取到 max”（如需闭合，可 `min + nextFloat64() * (max - min + 0.0)` 后用 `min(x, max)` 裁剪，或直接按 `closed ? max : max 的前一个可表示值` 处理）；`closed` 的取整语义应下沉到整数版本自己的 `+1`，不要通过浮点跨度实现。同步删除 README 的“已知行为 1”。

### [严重][存量] `RandomString` 三个 min/max 重载调用错方法，字符集与承诺不符

- **位置**：`f_random/src/RandomString.cj:107`（`randomAllLetters(min,max)` 调 `randomLowerLetters`）、`:140`（`randomUpperLettersNumbers(min,max)` 调 `randomLowerLettersNumbers`）、`:146`（`randomLettersNumbers(min,max)` 调 `randomLowerLettersNumbers`）
- **来源**：存量（`git blame -L 103,147` → `4be871f2f`，该文件 2026-10-03 后未改）
- **判据**：review-checklist §11（语义与命名 / 注释不符、契约与实现不符）、§2（近似重复导致的行为漂移）
- **证据**：静态确定 —— 三个函数体分别只有一行 `randomAllLetters(rand.nextInt64(min, max))` 形态的调用，被调方法名与函数名不一致；对照 `:103-105`（`randomAllLetters(count)` → `ALL_LETTERS`）、`:136-138`（`randomUpperLettersNumbers(count)` → `UPPER_LETTERS_AND_NUMBERS`）、`:142-144`（`randomLettersNumbers(count)` → `ALL_LETTERS_AND_NUMBERS`）可确认正确实现就在同文件上方。
- **描述**：`randomAllLetters(8,16)` 只产出小写字母；`randomUpperLettersNumbers(8,16)` 与 `randomLettersNumbers(8,16)` 都只产出“小写字母 + 数字”。这三个 API 的用途典型是生成密码 / 验证码 / 令牌，字符集被静默降级后不会报错也不会告警：需要大写字符的强度要求会悄悄失效（熵从 62 个字符降到 36 个，约 5 位/字符 → 5.17 位/字符的差别不大，但字符集约束本身被破坏）。同文件还有至少 10 组 `(count)` / `(min,max)` 成对重载（`:89-165`），全部是“命名后缀不同、函数体逐行对应”的复制结构，这三处错误正是复制粘贴后未改被调名的结果。README.md:540-551 / README_en.md:544-556 把它写成“已知行为 4”，等于把 BUG 固化进文档。
- **建议**：三处分别改为 `randomAllLetters(...)`、`randomUpperLettersNumbers(...)`、`randomLettersNumbers(rand.nextInt64(min, max))`；更彻底的做法是把 14 组 `(min,max)` 重载统一改为 `random(<charset>, rand.nextInt64(min, max))` 的单一私有辅助（见「§2 重复逻辑」）。修完后删除 README 的“已知行为 4”与 README.md:506-507 的对应说明。

### [严重][存量] `randomReservoir` 的蓄水池算法少了 `j == i` 分支，抽样不均匀

- **位置**：`f_random/src/RandomReservoir.cj:29-32`（`let r = rand.nextInt64(c)`，`if (r < count) { result[r] = v }`）
- **来源**：存量（`git blame -L 21,36` → `4be871f2f`）
- **判据**：review-checklist §11（算法与承诺不符）、§2（与经典 Algorithm R 的近似重复实现缺少边界分支）
- **证据**：静态确定 —— 经典 Algorithm R 对第 `c` 个元素（0 基，`c >= k`）取 `j = random(0..c)`（**含** `c`），`j < k` 才替换；实现取 `nextInt64(c)`，值域 `[0, c)`，永远取不到 `c`，即“新元素命中自己”这一路被删掉，替换概率从 `k/(c+1)` 变成 `k/c`。
- **描述**：后果是早期元素被系统性低估、后期元素被系统性高估。以 `count=2`、5 个元素（即 `Reservoir_test.cj:23` 的用例）为例，各元素最终被选中的概率可逐项算出：元素 0/1 = `1/2 × 2/3 × 3/4 = 1/4`，元素 2 = `1 × 2/3 × 3/4 = 1/2`，元素 3 = `2/3 × 3/4 = 1/2`，元素 4 = `2/4 = 1/2`，即 `[0.25, 0.25, 0.5, 0.5, 0.5]`，而均匀抽样应为每个 `0.4`（概率和恰为 2，与 k 一致，可自校验）。这是可复现的统计偏差，不是“轻微不均匀”：前两个元素被抽中的概率只有应有值的一半多。README.md:558-559 / README_en.md:563-564 同样把它写成“已知行为 6”。
- **建议**：改为 `let r = rand.nextInt64(c + 1)`，保持 `if (r < count) { result[r] = v }`；同时给测试加“经验分布 vs 理论均匀”的多轮统计断言（见发现「测试覆盖缺口」）。注意 `c + 1` 在 `c == Int64.Max` 时溢出，实际以 `result.size` 为界不会达到，但建议写成 `rand.nextInt64(c) ∈ [0,c)` 的等价式或加注释说明。

### [一般][存量] `Int64` / `UInt64` 区间经 `Float64` 生成：跨度 > 2^53 时整数不可达，全区间可越界

- **位置**：`f_random/src/ExtendRandom.cj:62-64`、`:65-67`（`Random`）、`:91-93`、`:94-96`（`SecureRandom`）
- **来源**：存量（`4be871f2f`）
- **判据**：review-checklist §11（边界 / 精度）、§10（语言特性：浮点表示范围）
- **证据**：静态确定 —— 公式 `Int64(floor(nextFloat64() * (max - min) + min))`，`Float64` 尾数 53 位。跨度 `> 2^53` 时相邻可表示浮点值间隔 ≥ 2，`floor` 后会有整数永远取不到（例：`nextInt64(0, 1 << 60)` 的可达值是 128 的倍数，约 127/128 的整数不可达）。`nextInt64(Int64.Min, Int64.Max)` 时 `Float64(max) - Float64(min) = 2^64`，乘积最大约 `2^64 - 4096`，`floor` 后转 `Int64` 已越界；仓颉文档未定义浮点越界转整数的结果（本地 `basic_data_type/integer.html` 只写了转换语法），因此后果是“错误值或异常”，具体取决于实现 → 该子项标 `待确认`。
- **描述**：这是“用浮点做整数均匀采样”的通病：跨度小于 2^53 时偏差可忽略，跨度大时既有空洞又可能越界。`nextUInt64` 同理（`UInt64` 上界 2^64-1 无法被 `Float64` 精确表示）。README.md:536-538 已说明“有精度损失，甚至溢出”，但没有给出可用替代方案，使用者拿不到正确做法。
- **建议**：整数版本改为整数域拒绝采样（`nextUInt64()` 取 64 位随机数，按 `span` 取模并拒绝落入偏置区），跨度小时走 `nextUInt64() % span` + 拒绝；这同时修掉发现「Int32/UInt32 经 Float32」的熵损失。修改后 `closed` 只在整数域 `span = max - min + 1` 里体现。

### [一般][存量] `Int32` / `UInt32` 区间经 `Float32`：最多 2^24 个取值，低位恒 0

- **位置**：`f_random/src/ExtendRandom.cj:68-70`、`:71-73`（`Random`）、`:97-99`、`:100-102`（`SecureRandom`）
- **来源**：存量（`4be871f2f`）
- **判据**：review-checklist §11（偏差 / 安全强度）、§10
- **证据**：静态确定 —— `nextFloat32()` 只有 24 位有效尾数，`nextUInt32(0, UInt32.Max, closed: true)` 的跨度是 2^32，乘积只能落在 2^24 个格点上（间隔 256），因此结果永远是 256 的倍数、低 8 位恒 0，熵上限 24 位。`nextInt32(0, Int32.Max)` 同样只有 2^24 个可达值。
- **描述**：`SecureRandom` 被本模块当作密码学随机源（`ThreadLocalRandom`、`RandomString` 默认源、`randomReservoir` 内部源都是它），而区间 API 把 32 位熵压到 24 位且带固定低位模式。用于生成盐、ID、验证码下标时不会报错，但强度低于调用方的预期；用于需要 32 位均匀分布的模拟 / 抽样时结果带结构性偏置。
- **建议**：同「Int64 经 Float64」——整数域拒绝采样；`nextInt32`/`nextUInt32` 至少改成先取 `nextUInt32()` 再取模 + 拒绝，不要经过 `Float32`。

### [一般][存量] `randomAllChars` 两个 Unicode 区间等概率，BMP 字符概率约为增补平面的 19.6 倍

- **位置**：`f_random/src/RandomString.cj:154-162`（`:157` `rand.nextInt64(2)`、`:158` 取 `ALL_CHARS[idx]`、`:159` 区间内均匀取值）
- **来源**：存量（`4be871f2f`）
- **判据**：review-checklist §11（分布偏差）、§13（README 表述为“从所有 UNICODE 字符中随机取出”）
- **证据**：静态确定 —— `ALL_CHARS`（`:59`）是 `[0x0000,0xD7FF]` 与 `[0xE000,0x10FFFF]` 两段，长度分别 55,296 与 1,081,344；先以 1/2 概率选段、再段内均匀，单字符概率是 `0.5/55296 ≈ 9.05e-6` 与 `0.5/1081344 ≈ 4.62e-7`，比值 19.57。全 Unicode 标量均匀应为每字符 `1/1136640 ≈ 8.80e-7`。
- **描述**：README.md:496 / README_en.md:497 把该方法的取值来源写成“全部 Unicode scalar”，`:505` 只说明“避开代理区”，没有说明分布按“区间”而不是按“字符”均匀。实际效果是 BMP 常用区被过度采样、增补平面（emoji、古文字等）被严重低估；若用于“随机 Unicode 输入”做 fuzz / 编码测试，覆盖面会系统性缺失。
- **建议**：改为按总标量数 `1136640` 取一个 `[0, 1136640)` 的随机数，再映射到两段（`n < 55296 ? n : n + 0x800`），保持一次 RNG 调用且严格均匀；README 补一句“按字符均匀，而非按区间均匀”。

### [一般][存量] `randomReservoir` 在 `count <= 0` 且数据源非空时抛异常，而不是返回空集

- **位置**：`f_random/src/RandomReservoir.cj:26-30`（`c < count` 不成立 → `rand.nextInt64(0)`）
- **来源**：存量（`4be871f2f`）
- **判据**：review-checklist §11（边界 / 空值）、§3（边界输入落到异常而非空结果）
- **证据**：静态确定 —— `count = 0` 时第一个元素走 `else` 分支，`SecureRandom.nextInt64(0)`；std 文档（`random_package_classes.html`、stdx `crypto_package_classes.html`）明确 `max <= 0` 抛 `IllegalArgumentException`。`count < 0` 同理。`count = 0` 且数据源为空时返回空 `ArrayList`，行为不一致。
- **描述**：`count` 常来自配置或“取前 N 条”的业务参数，`0` 是合法业务值（“不抽样”），当前实现把它变成运行时异常。README.md:555-557 已把它记为“已知行为 6”，但这是可以通过入口校验消掉的边界缺陷，不该固化。
- **建议**：函数入口 `if (count <= 0) { return ArrayList<T>() }`（或抛明确的 `IllegalArgumentException("count must be > 0")` 并写进文档，二选一，不要靠下游 `nextInt64(0)` 偶然抛）。

### [一般][存量] README 声称两个重载用 `closed: true`，实现用的是默认 `false`

- **位置**：`f_random/README.md:502-503`、`README.md:553-554`、`f_random/README_en.md:503-504`、`README_en.md:558-559`；对应实现 `f_random/src/RandomString.cj:74`（`randomAscii(rand.nextInt64(min, max))`）、`:87`（`random(rand.nextInt64(min, max), source)`）
- **来源**：存量（文档随 `030b8c0b0 feat(doc): 为各个模块添加文档` 引入）
- **判据**：review-checklist §13（文档与实现不一致，两边位置均已给出）
- **证据**：静态确定 —— `nextInt64(min, max, closed!: Bool = false)`（`ExtendRandom.cj:62`）默认 `closed = false`，上述两处调用都没传 `closed`，长度区间是 `[min, max)`；README 却写“`randomAscii(min, max)` 与 `random(min, max, source)` 用的是 `closed: true`，长度落在 `[min, max]`，其余重载落在 `[min, max)`”。实际上全部 14 个 `(min, max)` 重载都是 `[min, max)`，README 描述的“不一致”并不存在。
- **描述**：这条错误会直接误导使用者：按文档以为 `randomAscii(1, 4)` 可能返回 4 个字符，实际最多 3 个；反之依赖文档去“避开 closed:true 的重载”也没有意义。属于一句话就能修、但影响所有使用者的契约错误，中英两版同一处都错。
- **建议**：把两句改为“所有 `(min, max)` 重载的长度都落在 `[min, max)`”；若确实希望 `randomAscii` 闭合，则改实现并同步全部重载，不要只改文档。

### [一般][存量] “默认 `RandomString` 实例线程安全”的承诺不成立：随机源在构造时绑定到当前线程

- **位置**：`f_random/src/RandomString.cj:61`（`public RandomString(private let rand!: SecureRandom = ThreadLocalRandom.current)`）；文档 `f_random/README.md:526`、`README_en.md:527`
- **来源**：存量（`4be871f2f`）
- **判据**：review-checklist §12.1（线程封闭假设 / 发布逸出）、§13（文档承诺与实现不符）
- **证据**：静态确定 —— 默认参数在**构造时**求值，取到的是构造线程的 `ThreadLocal` 实例并存入 `rand` 字段；实例一旦跨线程使用，多个线程就共享同一个 `SecureRandom` 对象。仓内真实用法：`f_mvc/src/FileDownload.cj:32` `private static let random = RandomString()`（范围外，仅作影响面证据），该静态实例在首个触发类初始化的线程上绑定 `rand`，之后 `boundary`（`:39`）在任意请求线程上调用 `randomLettersNumbers(32)`。`SecureRandom` 的线程安全性 stdx 文档未声明（`crypto_package_classes.html` 只描述熵源与算法）→ 是否构成数据竞争标 `待确认`；但“换个线程用就不安全”与 README 的无条件承诺已经冲突。
- **描述**：README 把“每个线程首次访问 `current` 时创建一个 `SecureRandom`”当成“`RandomString` 实例线程安全”的依据，混淆了“每线程一个随机源”与“对象可跨线程共享”。正确说法是：只有“每个线程各自构造自己的 `RandomString`”才线程封闭；共享一个实例时随机源被共享，并发调用的行为取决于 `SecureRandom` 实现。本模块其余路径（`randomReservoir` 每次新建、`RandomString` 方法只用局部 `StringGenerator`）不存在共享可变状态。
- **建议**：二者取一：① `RandomString` 不缓存随机源，每次取 `ThreadLocalRandom.current`（代价是每字符一次 `ThreadLocal.get`）；② README 改为“线程封闭使用：每个线程各自构造 `RandomString()` 才安全；跨线程共享同一实例时随机源被共享，不在本模块保证范围内”。建议同时给 `RandomString` 加一条“不要用 `static let` 跨线程共享”的提示（`f_mvc` 的用法需按①改造，属范围外）。

### [一般][存量] 测试只覆盖 6 个方法、只断言长度与字符集，三个错误重载与全部偏差都测不出来

- **位置**：`f_random/src/RandomString_test.cj:22-100`（6 个用例：`randomAscii` / `random` / `randomLowerLetters` / `randomUpperLetters` / `randomAllLetters` / `randomNumbers`）、`f_random/src/Reservoir_test.cj:20-28`
- **来源**：存量（`4be871f2f`）
- **判据**：review-checklist §14（测试对契约的覆盖）、§11（缺陷无回归网）
- **证据**：静态确定 —— 被测公开方法约 30 个，覆盖 6 个；`randomAllLetters(min,max)` / `randomUpperLettersNumbers(min,max)` / `randomLettersNumbers(min,max)` 三个有 BUG 的重载**零调用**；`randomLowerHex`/`randomUpperHex`/`randomPrintableAsciis`/`randomAllChars`/`randomGaussian*Stream`/`randomInt64` 等区间迭代器、`nextInt64/nextUInt64/nextFloat64` 区间扩展全部无测试。`Reservoir_test` 只断言 `r.size == 2`，不断言元素隶属、不检查分布，因此蓄水池偏差（元素概率 0.25 vs 0.4）无法被发现。
- **描述**：现有测试相当于“能跑通”的冒烟测试，对随机算法的两个核心契约（字符集正确、分布均匀）都没有断言。上面三条严重 / 一般缺陷全部落在测试盲区，说明后续改动也没有回归保护。
- **建议**：① 给每个 `(min,max)` 重载加“结果字符全部落在承诺字符集内”的断言（可直接复用 `HashSet<Rune>` 写法，`RandomString_test.cj:40-50` 已有模板）；② 加长度区间断言（`[min, max)`）；③ 给 `randomReservoir` 加经验分布断言（固定 5 元素、`k=2`、10 万轮，每个元素命中率与 `2/5` 的偏差在 3σ 内），这条会直接暴露发现 3；④ 给 `nextInt64/nextUInt64` 加“全区间多次采样覆盖到高位整数”的断言，暴露浮点精度问题。

### [轻微][存量] `RandomIterator.cj` 21 个迭代器类零引用（约 190 行死代码），且没有对应工厂方法

- **位置**：`f_random/src/RandomIterator.cj:146`(`RandomBoolIterator`)、`:155`、`:164`、`:173`、`:182`、`:191`、`:201`、`:210`、`:219`、`:228`、`:237`、`:246`、`:255`、`:264`、`:273`、`:282`、`:291`、`:300`、`:309`、`:318`、`:327`（至 `:334` 结束）
- **来源**：存量（`4be871f2f`）
- **判据**：review-checklist §1（非 public 顶层类型无调用者；其 `public func next()` 因类型对外不可达，一并不可达）、§14.1（接线缺失）
- **证据**：静态确定 —— 全仓 `grep`（`*.cj`）这些类名只命中定义处；唯一被实例化的是 `RangeRandomInt*`/`RangeRandomUInt*`（`RandomIterator.cj:25,28,31,34,68,71,74,77`）与 `RandomGaussianFloat{16,32,64}Iterator`（`:41,49,57,84,92,100`）。这些类的构造函数也没有任何调用点。类型声明本身是包内可见（无 `public`），因此成员的 `public` 只是“包内放宽”，按硬原则二判死代码。
- **描述**：21 个类 = 9 种“无上界”+ 7 种“有上界”+ 5 种其余（`RandomUInt8sIterator`、`Float16/32/64`）的逐行复制，每个都只做 `rand.nextXxx(...)` 转发。它们对应的公开能力（`randomBool()`、`randomInt8()`、`randomUInt64(min,max)` 之外的流式工厂）在 `BaseRandom` 里也没有声明，README.md:317-340 只列了 7 个工厂方法，等于“写了一半没接线”。`UpperRandom*Iterator` 的 `private var upper` 也从未被修改（应为 `let`），进一步说明是未完成的草稿。
- **建议**：二选一：① 补齐 `BaseRandom` 的 `randomBool()/randomInt8()/...` 工厂并让这些类进入真实调用链（接口改动需同步 README）；② 直接删除 `:146-334` 与 `:191-199`，只保留 7 个在用的迭代器。当前状态（留着不用）是最差选项：编译期多 21 个类型、读者要判断“是不是漏了工厂”。

### [轻微][存量] `imported.cj` 只有 `package` 声明，是空文件残留

- **位置**：`f_random/src/imported.cj:16`（全文件仅 `package fountain::f_random`）
- **来源**：存量（`4be871f2f`）
- **判据**：review-checklist §1（无声明 / 兼容残留）
- **证据**：静态确定 —— 16 行全部是版权头，正文只有包声明；文件不被任何地方 `import`（包声明文件本来也不可被 `import`），删除不影响编译产物。
- **描述**：与 `f_random` 下其他文件对照，只有它没有类型或函数。此类空文件常见于“迁移时占位”，留着会让读者以为包里有额外入口，也会让按文件统计的模块规模虚高。
- **建议**：删除该文件（已确认 `git ls-files` 中只有它一个空壳）。

### [轻微][存量] `Random` 与 `SecureRandom` 两个 `extend` 的 12 个函数体逐行重复

- **位置**：`f_random/src/ExtendRandom.cj:47-74` vs `:76-103`（`nextFloat64`/`nextFloat32`/`nextInt64`/`nextUInt64`/`nextInt32`/`nextUInt32` 各一份）
- **来源**：存量（`4be871f2f`）
- **判据**：review-checklist §2（只改接收者类型的重复实现）
- **证据**：静态确定 —— `Random` 版与 `SecureRandom` 版的 6 组方法体逐字相同，唯一差别是所属 `extend`；`nextUInt64`（`:65-67` / `:94-96`）连注释都没有，无法从注释判断两者是否应保持一致。
- **描述**：两份完全相同的实现意味着任何修正（例如上面两条精度缺陷）必须改 4 处（`Int64/UInt64/Int32/UInt32` × 2 个类型），漏一处就产生“`Random` 修好了、`SecureRandom` 仍偏”的漂移——`closed` 缺陷目前就同时存在于 4 处。仓颉的 `extend` 不能共享泛型实现，但可以抽一个顶层自由函数（`func scaleFloat64(v: Float64, min: Float64, max: Float64, closed: Bool): Float64`）供两个 `extend` 调用，也可抽一个 `private func randomRange` 供整数路径复用。
- **建议**：把区间换算抽成 2-3 个包内 `func`（`scaleFloat64` / `scaleFloat32` / `intSpan`），两个 `extend` 只保留一行转发；这样改一处即同时作用于 `Random` 与 `SecureRandom`，也便于给它们加统一的参数校验（见发现「`randomReservoir` 边界」同类问题：本模块所有区间 API 都不校验 `min <= max`）。

### [轻微][存量] 测试里有恒真断言与不一致的循环上界

- **位置**：`f_random/src/RandomString_test.cj:32`（`@Assert(ch >= 0 && ch <= 127)`，`ch: UInt8`）、`:78` 与 `:90`（`for (i in 0..10_0000)`，其余用例是 `10_000`）
- **来源**：存量（`4be871f2f`）
- **判据**：review-checklist §10（可读性 / 测试有效性）
- **证据**：静态确定 —— `UInt8` 无符号，`ch >= 0` 恒真，断言实际只剩 `ch <= 127`；`10_0000` 是 100,000，比同文件其余 5 个用例的 10,000 多一个数量级，看起来是手误而非刻意。
- **描述**：恒真条件会让断言看起来比实际更严格；循环次数不一致会让“测试耗时”与“覆盖强度”两个判断都失真（`test4`/`test5` 比其他用例慢 10 倍）。另外 6 个用例的循环变量 `i` 都未使用，编译期会产生未使用变量告警。
- **建议**：删除 `ch >= 0`，循环统一为 `10_000`；循环变量改 `_`。

### [轻微][存量] README 写“所有键盘可打印字符”，实现不含空格

- **位置**：`f_random/src/RandomString.cj:52-53`（字符集字符串以 `` ` `` 开头，无空格）；文档 `f_random/README.md:495`、`README_en.md:496`
- **来源**：存量（`4be871f2f`）
- **判据**：review-checklist §13（文档措辞与实现不符）
- **证据**：静态确定 —— 字符集 = 字母(52) + 数字(10) + `` `~!@#$%^&*()-_=+[{]}\|'";:/?.>,< ``（32 个标点），共 94 个，ASCII 可打印区 `0x20-0x7E` 共 95 个，缺的正是空格 `0x20`（`:52` 拼接的第二段以反引号开头，反引号前没有空格）。
- **描述**：空格算不算“键盘可打印字符”可以商量，但文档用的是“所有”，实现少一个字符；若用户拿它生成“随机可打印串”做长度/分词测试，空格缺失会让用例覆盖不到空白分支。
- **建议**：要么在字符集里补空格（注意这会改变已有输出的分布，属行为变更），要么把文档改为“全部可打印 ASCII（不含空格）”。

## 优化可行性方案

> 以下均无改前基线数据，按规则只作「待验证」，不进修复清单。

### [CPU] `randomReservoir` 每次调用新建一个 `SecureRandom`

- **现状**：`f_random/src/RandomReservoir.cj:22` 每次调用都 `SecureRandom(priv: priv)`；`SecureRandom` 初始化要走 OpenSSL DRBG + 操作系统熵源（stdx 文档：`RAND_bytes` / `RAND_priv_bytes`，AES-256-CTR DRBG）。`Reservoir_test.cj:22` 的 10 万轮循环即 10 万次构造。
- **方案**：改为复用 `ThreadLocalRandom.current`（已是每线程一个），或新增 `randomReservoir(count, source, rand!: SecureRandom = ThreadLocalRandom.current)` 重载让调用方注入随机源；保留现有 `priv` 参数作为兼容入口。
- **预期**：省掉每次调用的 DRBG 初始化；单次抽样调用从“一次熵源 + 一次构造”降到纯抽样。收益取决于构造耗时占比（见待验证假设 #1），无数据前不给百分比。
- **代价**：`priv: true` 的语义需要保留（私有 DRBG 与默认 DRBG 不同），默认路径的随机源从“每次新实例”变成“线程内复用”，对安全性无实质影响（SecureRandom 本身就是密码学安全的），但会改变“每次调用独立实例”的隐含假设。
- **验证**：`cjpm bench -O2`，对照组为当前实现，输入 1e6 个元素的 `ArrayList<Int64>`、`count=100`，取中位数与离散度；另用 `cjprof record` 看 `SecureRandom::init` 占比。
- **证据状态**：无基线（待验证，不进 tasks）

### [堆内存] `randomReservoir` 的结果 `ArrayList` 未按 `count` 预分配

- **现状**：`f_random/src/RandomReservoir.cj:23` `var result = ArrayList<T>()`，容量按默认增长策略反复扩容；`count` 在入口已知，最多装 `min(count, n)` 个元素。
- **方案**：入口校验 `count > 0` 后 `ArrayList<T>(count)`（`count` 为 `Int64`，需转 `Int64` 容量参数）；`count` 大于数据源时多分配的槽位随函数返回被回收，代价是短时峰值。
- **预期**：去掉 `log2(count)` 次扩容与元素搬迁；`count = 1000` 时约 10 次扩容、累计搬迁约 2000 个引用（估算，未实测）。
- **代价**：`count` 远大于实际元素数时（例如 `count = 1e6`、源只有 10 个）会一次性预分配大数组，属“按调用方参数预分配”，需在文档里写明“`count` 决定预分配峰值”；若担心这一点，可改为 `min(count, 4096)` 起步。
- **验证**：`getAllocatedHeapSize()` 前后对照 + `cjpm bench -O2` 同输入（1e6 元素、count=1000）耗时中位数。
- **证据状态**：无基线（待验证，不进 tasks）

### [CPU] `RandomString` 每字符一次 `SecureRandom` 调用

- **现状**：`RandomString.cj:69`（`randomAscii` 每字符 `rand.nextUInt32(128)`）、`:82`（每字符 `nextInt64(source.size)`）、`:159`（`randomAllChars` 每字符两次调用：`nextInt64(2)` + `nextUInt32(start,end)`）；`SecureRandom` 每次调用都跨到 OpenSSL。
- **方案**：批量取随机字节（一次 `nextBytes(64)`）后在本地按位切分消费；`randomAllChars` 用一次 64 位取值同时决定区间与段内偏移（按总标量数 1136640 取样，顺带修复发现 6 的分布偏差）。
- **预期**：每字符的跨边界调用从 1-2 次降到 1/8 次（8 字节可切 8 个 ASCII 字符）；具体收益需 profile 确认，无数据前不给百分比。
- **代价**：需要引入一个“字节缓冲 + 位偏移”的小状态（可做成函数内局部，不跨调用），并处理拒绝采样（避免取模偏置）；实现复杂度上升，必须配等价性测试。
- **验证**：`cjpm bench -O2` 生成 1e6 个 32 字符串，对比当前实现的中位数；`cjprof record` 看 `SecureRandom::nextUInt32` 自耗时占比。
- **证据状态**：无基线（待验证，不进 tasks）

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `SecureRandom` 构造占 `randomReservoir` 单次调用耗时的主要部分 | `f_random/src/RandomReservoir.cj:22` | 构造耗时 / 抽样耗时占比 | `cjprof record` 跑 1e6 次 `randomReservoir(100, list)`，看 `SecureRandom::init` 与 `randomReservoir` 的 self time |
| 2 | `RandomString` 的逐字符 `SecureRandom` 调用是大 `count` 场景的主要成本 | `f_random/src/RandomString.cj:69`、`:82`、`:159` | 每字符 RNG 调用耗时占比 | `cjpm bench -O2` 生成 1e6 个 32 字符串，与“一次取 8 字节批量消费”的临时实现对照，取中位数 |
| 3 | `ArrayList` 未预分配导致 `randomReservoir` 的扩容搬迁占可观比例 | `f_random/src/RandomReservoir.cj:23` | 扩容次数 / 搬迁元素数 | 加容量埋点（`ArrayList.capacity`）跑 `count=1000`、1e6 元素，统计扩容次数与 `getAllocatedHeapSize()` |

## 文件覆盖

> 与 `reviews/202611280854_full-repo/files/f_random.txt` 一一对应，10 行全覆盖。

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_random/README.md` | .md | ✅ | 与实现大体一致；命中 §13 两条（长度区间说明写反、线程安全承诺过宽）+ §13 一条措辞（可打印字符不含空格）；公开 API 逐项对照无遗漏；“已知行为”1/2/4/6 是对上述缺陷的文档化 |
| 2 | `f_random/README_en.md` | .md | ✅ | 与中文版章节、参数、示例同构（9 个目录项、6 条已知行为一一对应）；上述三处文档问题同样存在（`:503-504`、`:527`、`:496`），无整节缺失 |
| 3 | `f_random/src/ExtendRandom.cj` | .cj | ✅ | 292 行全读；`ExtendRandom` / `BaseRandom` 两个接口 + `Random`/`SecureRandom` 两个 `extend`；缺陷集中在区间换算（`closed`、浮点精度），两版 12 个方法体逐行重复 |
| 4 | `f_random/src/RandomIterator.cj` | .cj | ✅ | 361 行全读；7 个在用迭代器 + 21 个零引用迭代器（`:146-334`）；`prop current` 与 7 个工厂均有引用 |
| 5 | `f_random/src/RandomReservoir.cj` | .cj | ✅ | 37 行全读；蓄水池抽样缺 `j == i` 分支（偏差已量化）、`count <= 0` 边界抛异常、每次新建 `SecureRandom` |
| 6 | `f_random/src/RandomString.cj` | .cj | ✅ | 166 行全读；三个 `(min,max)` 重载调用错方法、`randomAllChars` 区间等概率偏差；静态字符集用 `concat` + `fold` + `toArray` 构造（`:31-55`），仅在类初始化执行一次 |
| 7 | `f_random/src/RandomString_test.cj` | .cj | ✅ | 100 行全读；6 个用例、覆盖 6 个方法；恒真断言 `ch >= 0`、循环上界 `10_0000` 不一致；三个错误重载零覆盖 |
| 8 | `f_random/src/Reservoir_test.cj` | .cj | ✅ | 29 行全读；只断言 `size == 2`，不检查隶属与分布；10 万轮 × 每次新建 `SecureRandom` |
| 9 | `f_random/src/ThreadLocalRandom.cj` | .cj | ✅ | 32 行全读；`private static let ThreadLocal` + `getOrCompute`，每线程一个实例，构造器私有、`@Frozen`，无共享可变状态；未提供 `remove()` 入口，线程池长驻线程会各留一个实例（容量有界，不构成泄漏） |
| 10 | `f_random/src/imported.cj` | .cj | ✅ | 16 行全读；只有版权头 + `package` 声明，空文件残留 |

合计：`.cj` 8 个 / `.md` 2 个 / 共 10 个，全部读完。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 15 | 严重 3（浮点 `closed` 越界、三个字符集重载调用错方法、蓄水池偏差）+ 一般 7（64 位浮点精度、32 位浮点熵、`randomAllChars` 区间偏差、`count<=0` 抛异常、README 长度区间写反、线程安全承诺、测试盲区）+ 轻微 5（21 个死类、空文件、12 个重复方法体、恒真断言、可打印字符不含空格）；安全性方面无注入面（本模块不拼 SQL / 不解析外部报文），但 `SecureRandom` 区间 API 的熵损失已单列 |
| §1 死代码 | 2 | 已逐个检查 8 个 `.cj`：21 个包内迭代器类全仓 `grep` 只命中定义处（`:146-334` 合并为 1 条）；`imported.cj` 只有包声明（1 条）；`private` 符号（`RandomString.concat`、各字符集常量、`ThreadLocalRandom.rand`、`RandomIterator.rand`）均有引用；`public` 且对外可达（`ExtendRandom`/`BaseRandom`/`randomReservoir`/`RandomString`/`ThreadLocalRandom` 及其成员）不判；`extend` 里的 `prop current`、7 个工厂、3 个高斯流均有调用方；`RandomIterator` 为 `abstract sealed` 包内类，其 `protected let rand` 被 4 个子类使用 |
| §2 重复逻辑 | 1 | 已把 8 个文件里 60+ 个函数体压成「输入-输出-副作用」比对：`Random`/`SecureRandom` 两个 `extend` 的 12 个方法体逐字相同（1 条）；21 个迭代器类同形但已按死代码计，不重复计数；`RandomString` 的 14 组 `(count)`/`(min,max)` 重载是必要 API 形态、语义差异只在“先取长度”，不算重复（但其中 3 处因复制粘贴调用错方法，已按缺陷计）；两版 README 属翻译对应 |
| §3 空实现 | 0 | 无空函数体、无 `TODO`/`FIXME`、无 `catch {}`、无 `throw UnsupportedException`；`ThreadLocalRandom.private init() {}` 是刻意的“禁止实例化”，有注释说明；`imported.cj` 的空文件已按 §1 计；接口默认方法 `nextBytes`/`nextUInt8s`（`ExtendRandom.cj:260-273`）有真实实现 |
| §4 栈溢出 | 0 | 全模块无递归（无自调用、无相互调用）；`concat` 用 `flatMap` + `fold` 迭代，深度由“字符集段数 1-2”与数组长度决定，非用户可控递归；`RandomString` 的字符循环是平铺 `for` |
| §5 OOM | 0 | 无全局缓存、无只增不减的容器、无 `readToEnd` 类全量物化；`Array<UInt8>(length)`（`:261`）、`Array<UInt8>(size)`（`RandomIterator.cj:197`）、`ArrayList<T>`（`RandomReservoir.cj:23`）的长度都来自调用方参数而非报文字段，属“调用方按需申请”，未构成按不可信长度预分配；`Result` 容量问题已列入优化方案 |
| §6.1 热点瓶颈 | 0 | 本轮未提供该模块的 profile / bench 数据；`SecureRandom` 每字符调用、每次抽样新建实例都是线索，已按格式写入「待验证假设」#1-#3，不参与统计、不进 tasks |
| §6.2 大粒度锁 | 0 | 全模块无 `synchronized`、无 `Mutex`、无锁对象，不存在临界区；`ThreadLocal` 的 `getOrCompute` 是“读-算-写”但作用域为当前线程，无线程间竞争 |
| §6.3 并发串行 | 0 | 无 `spawn`、无 `Future`、无并发容器、无批处理队列；`randomReservoir` 是单线程顺序遍历 |
| §6.4 低效算法 | 0 | `randomReservoir` 是 O(n) 单趟；`RandomString` 字符生成是 O(count) 平铺循环；无嵌套循环、无 `contains`、无 `remove(at: 0)`；`concat` 的 `fold` + `toArray` 只在类初始化执行一次，量级为字符集长度（94），不构成低效算法；`randomAllChars` 每字符两次 RNG 调用属跨边界成本，已列入优化方案而非算法问题 |
| §7 降堆内存方案 | 1 | `randomReservoir` 结果 `ArrayList` 未预分配（无基线，待验证）；`ThreadLocal` 长驻线程各持一个 `SecureRandom`，数量等于线程数、有上界，未单列 |
| §8 降 CPU 方案 | 2 | `randomReservoir` 每次新建 `SecureRandom`、`RandomString` 每字符一次 RNG 调用；均为无基线（待验证） |
| §9 local mode 可行性 | 0 | 本模块所有产物都逃逸：`RandomString` 返回 `String`、`randomReservoir` 返回 `ArrayList<T>`、迭代器把随机源存为成员；函数内的 `StringGenerator`（f_base 类）与 `ArrayList<Rune>` 也无 local-mode 重载，改造需先给 `f_base` 加 mode 重载，收益无法用峰值内存证明 |
| §11 现有代码的 BUG（存量） | 7 | 逐条核对 8 个源文件的边界与空值：浮点 `closed` 越界（4 处）、64 位整数经浮点精度/越界（4 处）、32 位整数经 `Float32` 熵损失（4 处）、`randomAllChars` 区间偏差、三个字符集重载调用错方法、蓄水池缺 `j == i`、`count <= 0` 抛异常；已确认无缺陷的边界：`randomAscii(0)` 返回空串、`random(count, 空 source)` 抛 `IllegalArgumentException`（std 契约，未文档化但可用）、`nextUInt8s` 原地替换并返回同引用、`UpperRandom*` 未校验 `upper`（其类本身已死） |
| §12 并发安全与锁粒度 | 1 | 共享路径逐条排查：`ThreadLocalRandom.rand` 是 `private static let` 但内容为 `ThreadLocal`（线程封闭，`getOrCompute` 无竞态）；`Random`/`SecureRandom` 的 `extend` 无状态；`RandomString` 方法只用局部 `StringGenerator`。命中项是 `RandomString` 构造时捕获线程本地随机源、实例跨线程共享（`RandomString.cj:61` + `f_mvc/src/FileDownload.cj:32` 实证），`SecureRandom` 自身线程安全性 stdx 未声明 → 数据竞争部分标 `待确认`；锁粒度维度无锁可谈 |
| §14 功能完备性与 README 覆盖 | 0 | 以 `src/` 公开声明为基准逐项对照 README：`ExtendRandom`（8 方法）、`BaseRandom`（全部声明 + 2 个默认方法）、`Random`/`SecureRandom` 的 `current` 与 7 个工厂、`randomReservoir`、`RandomString`（类 + 2 个构造器 + 30 个方法）、`ThreadLocalRandom.current` 全部有文档；根 `README.md:340` / `README_en.md:308` 已登记本模块；`cjpm.toml` 依赖（仅 `f_base`）与 README 依赖说明一致；“半成品”（21 个未接线迭代器）已按 §1 计入死代码，不重复计 §14 |
| 文件覆盖（§13 等） | 10/10 | 无缺失文件；§13 命中 3 条（长度区间写反 = 一般，线程安全承诺 = 一般，可打印字符不含空格 = 轻微） |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 3 |
| 一般 | 7 |
| 轻微 | 5 |
| 优化方案（堆内存 / CPU） | 1 / 2 |

存量缺陷合计 15 条（严重 3 / 一般 7 / 轻微 5），全部为存量（快照模式无 diff 可比）；是否纳入修复待用户决定。

## 总评

模块规模不大（8 个源文件、约 1000 行），但“随机”这件事上几乎没有一处是对的：**所有区间 API 都建立在“浮点乘法 + floor”之上**，于是浮点 `closed` 直接把上界放大 1.0（`nextFloat64(0,1,closed:true)` 有约一半概率返回 >1），整数路径在跨度超过 2^24 / 2^53 时分别丢掉低位、产生空洞甚至在 `Int64` 全区间越界。这三个问题同源，建议作为一次改动整体替换为整数域拒绝采样，而不是逐个打补丁——否则四个 `extend` 方法（`Random`/`SecureRandom` × `Int*`/`UInt*`）会继续各自漂移。

另外两处是纯逻辑错误，与浮点无关，修起来最便宜：`RandomString` 的三个 `(min,max)` 重载复制粘贴后没改被调方法名（大小写字母集、大写字母+数字集被静默降级为小写），以及 `randomReservoir` 的 Algorithm R 少了 `j == i` 分支——后者可以用 `k=2, n=5` 直接算出各元素命中率 `[0.25, 0.25, 0.5, 0.5, 0.5]`（均匀应为 0.4），误差大到任何统计测试都能发现。这两条建议进下一轮修复窗口。

值得肯定的是：模块没有锁、没有全局可变状态、没有递归，`ThreadLocalRandom` 的线程封闭模型是对的，`randomReservoir` 的单趟 O(n) 与 `RandomString` 的字符集划分也合理；结构上真正的债务是 `RandomIterator.cj` 里 21 个从未接线的迭代器类（约 190 行）和两个 `extend` 的 12 份重复方法体，前者应删除或补齐工厂，后者抽出 2-3 个包内换算函数即可同时消掉重复与“改一处漏三处”的风险。

文档层面有个结构性问题：README 的「注意事项与已知行为」把 4 条真实 BUG（浮点 `closed`、整数精度、三个字符集重载、蓄水池偏差）逐条写成了“按代码实际行为记录，代码本身未做改动”，这会让读者以为这些是设计取舍而非缺陷；加上“长度区间”那条描述与实现相反、线程安全承诺过宽，文档目前更接近“缺陷清单”而不是契约。建议随实现修复一起重写该节，只保留真正无法避免的限制（如区间参数不校验 `min <= max`）。

测试是最大的空白：30 个公开方法只覆盖 6 个，三个有 BUG 的重载零调用，蓄水池只断言 `size`。在没有分布断言之前，本模块任何“随机性正确”的结论都不可验证——补齐字符集断言与经验分布断言，优先级应高于任何性能优化。三个优化方案（每次新建 `SecureRandom`、`ArrayList` 预分配、逐字符 RNG）均无改前基线，按规则只作待验证假设，不进修复清单。
