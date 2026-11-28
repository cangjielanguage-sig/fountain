# f_jit 模块审查报告（第 22/38 部分）

- **审查日期**：2026-11-28
- **模块路径**：`f_jit`（本部分 20 个源文件，全部为 `src/*.cj`）
- **基线**：工作区快照（master 与 sts/1.3.x 同一提交 `120fd2542`，`git diff` 为空）⇒ 全部问题来源为「存量」
- **审查重点**：动态调用/桥接正确性（typecode 分支表）、句柄与资源生命周期、并发安全、递归与栈溢出、死代码、重复逻辑
- **报告版本**：分部分报告 `f_jit.part22`（由主 Agent 合并进 `<module>_v2.md`，本文件不替代模块报告）

> 本部分文件构成：2 个产品源文件（`JitBindSupport.cj`、`EscapedClosure.cj`）+ 18 个 `*_test.cj`。因此产品侧结论集中在 `JitBindSupport` 的快照发布与 `EscapedClosure` 的字段归属；其余发现落在测试的有效性与隔离性（这类问题会让回归网失效，按缺陷记，不按风格记）。

## 发现

### [一般][存量] 两个源文件缺 Apache 版权头

- **位置**：`f_jit/src/Inheritance_test.cj:1`、`f_jit/src/Interface_test.cj:1`
- **来源**：存量（工作区快照，`git diff` 为空）
- **判据**：`references/fountain-baseline.md` §3「每个 `.cj` 文件必须有 Apache 2.0 版权注释，位于 `package` 之前」
- **证据**：静态确定 —— 逐一校验本部分 20 个文件首行，仅这两个文件首行即 `package fountain::f_jit`，无任何版权注释；其余 18 个文件首行均为 `/*`
- **描述**：`Inheritance_test.cj`、`Interface_test.cj` 缺版权头。文件里还定义了对外 `public` 的夹具类型（`ProbeBase` / `ProbeDerived` / `ProbeNamed` / `ProbeGreeter` / `ProbeGreeterImpl` / `ProbeUnbound`），属于会进产物的声明，缺头在合规扫描里按缺失处理
- **建议**：补与本模块一致的 Apache 2.0 头（版权年 2026），置于 `package` 之前

### [一般][存量] 并发注册用例无法观察到它声称的「类可见 ⇒ 方法可见」窗口

- **位置**：`f_jit/src/CompilerRegistrationConcurrency_test.cj:59-67`（声明见 `:32-34`）
- **来源**：存量
- **判据**：review-checklist §11「契约与实现不符（用例自述的探针与实际断言不符）」；§12.1 并发正确性
- **证据**：静态确定 —— 文档写「旧实现把 `classes.register` 放在 `Compiler.mtx` 之外，存在『类已可见、方法尚未进入函数快照』的窗口；本用例的成对断言是该窗口的直接探针」。但 `c.registerClass(...)`（`:59`）返回后，`hasClass`（`:62`）与 `hasFunction`（`:65`）都是本线程的顺序读，全部发生在注册完成之后；窗口只存在于 `registerClass` 内部，本线程永远看不到
- **描述**：把 `classes.register` 移出临界区的旧写法依然会让本用例全绿 —— 因为两次读都在注册结束之后，二者必然同时可见。`@Assert(bad, 0)` 实际只验证了「注册成功」；后面的 80 次编译（`:80-87`）也都在全部注册完成后执行，无法捕捉注册期的中间态。结论：这条用例对目标缺陷没有检测力，却给了「已有并发护栏」的错觉
- **建议**：让读者线程在注册窗口内观察，两条可行路径任选：① 起 1~2 个读者线程在注册期间循环 `hasClass(name) ==> hasFunction(name + '.m')`（批量注册 + 短睡眠制造交错）；② 在 `registerClass` 的「发布类」与「发布方法」之间留一个测试钩子（与 `JitBindSupport.publishHook` 同款），读者在钩子里断言成对可见。修完后建议用变异版（把 `classes.register` 移出锁）验证用例会变红

### [一般][存量] 性能门禁用单次采样、两路测量顺序固定

- **位置**：`f_jit/src/HostClosureAdapter_test.cj:115-134`
- **来源**：存量
- **判据**：`references/fountain-baseline.md` §8「报告变快要附绝对值、中位数、离散程度」；review-checklist §6.1（无对照数据不得作为结论）
- **证据**：静态确定 —— `reflectiveNs`（`:117`）与 `typedNs`（`:122`）各由一次 `DateTime.now()` 差值得到，各 1 个样本，无重复轮次、无中位数、无离散度；门禁 `typedNs * 10 >= reflectiveNs * 13`（`:131`）直接以单次样本判定 `@Fail`
- **描述**：① 单样本受 GC、调度、CPU 频率影响可达数倍，CI 上会随机变红；② 先测反射、后测 adapter，第二路额外享受了第一路带来的缓存/分支预测/JIT 稳态收益，比值本身有系统偏差；③ 失败信息虽打印 ns，但无法区分「adapter 变慢」与「机器抖动」。这类门禁一旦偶发失败，通常被当噪声忽略，等于护栏失效
- **建议**：改为 N（如 9）轮交替 A/B（`refl, typed, refl, typed…`），每轮取 ns/call，报中位数与 P95，门禁用中位数比；或退一步把该用例降级为「打印观测值 + 只在 `ratio < 1.0` 时报错」，把 1.3× 阈值移进 bench 报告而不是单测

### [一般][存量] 断言失败会把恒阻塞钩子留在全局，导致登记路径与测试进程挂死

- **位置**：`f_jit/src/JitBindSupportSnapshot_test.cj:109-128`
- **来源**：存量
- **判据**：review-checklist §12.1（锁内自旋 + 全局状态未复位 → 死锁）；§11（错误路径未处理）
- **证据**：静态确定 —— 钩子在 `JitBindSupport.enrollInterfaceOf` 的 `synchronized(writeMtx)` 内执行（`JitBindSupport.cj:132-143`），钩子体为 `while (release.load() == 0) {}`（`:111`）；`@Assert(entered.load(), 1)`（`:122`）位于 `release.store(1)`（`:124`）之前。断言抛出后：`release` 永不置 1 → 写线程永久自旋且**永久持有 `writeMtx`**，`publishHook` 也停在 `Some(...)` → 之后任何 `enrollOf` / `enrollInterfaceOf`（含其他用例的 `@JitBind` 初始化）都会二次进入同一钩子并永久自旋
- **描述**：这条用例的失败模式不是「红灯」而是「整个测试进程挂死（或后续全部超时）」，排查成本远高于普通失败；反过来，为了绕过挂死而加超时，又会掩盖真正的发布时机回归
- **建议**：把 `@Assert(entered.load(), 1)` 移到 `writer.get()` 之后、`release` 与 `publishHook` 复位放进 `try { … } finally { release.store(1); JitBindSupport.publishHook = None }`；并对写线程的等待加显式上限（失败时报「钩子未被触发」而不是挂住）

### [轻微][存量] `JitBindSupport` 三处 KDoc 错位，钩子成本描述与实现不符

- **位置**：`f_jit/src/JitBindSupport.cj:27-33`、`:50-58`、`:59-62`
- **来源**：存量
- **判据**：review-checklist §11「语义与注释不符」；§10 可读性
- **证据**：静态确定 —— `:27-33` 是 `@JitBind` 运行期支撑 / M2.1 的说明，紧贴在 `private class BindSnapshot`（`:39`）之上，与紧随其后的 `:34-38`（BindSnapshot 自己的说明）叠成两段无归属注释；`:50-58` 描述的是「类全限定名 → overrides」的**静态字段**（「包初始化时把表填好」），但该字段已不存在（表整体搬进 `BindSnapshot.enrolled`），这段说明实际压在 `publishHook` 上，把 `:59-62` 的钩子说明挤成第二段
- **描述**：读代码的人会以为 `BindSnapshot` 就是 M2.1 主体、`publishHook` 是那张登记表。另有一处口径偏差：`:60-61` 写「只在包初始化 / `registerClass` 的冷路径上多一次 `Option` 匹配」，但只有 `enrollInterfaceOf`（`:139-142`）读钩子，真正的包初始化入口 `enrollOf`（`:116-122`）完全不读 —— 即「包初始化路径多一次匹配」这句在实现上不成立
- **建议**：把 `:27-33` 移到 `public class JitBindSupport`（`:49`）之上；把 `:50-58` 改成对 `current` 快照字段的说明并紧跟 `:66`；钩子说明改为「仅 `enrollInterfaceOf` 调用，用于确定性复现发布时机竞态」；若希望两条登记路径口径一致，则在 `enrollOf` 的 `store` 之后也调用同一个 `firePublishHook()` 私有函数

### [轻微][存量] `copyBindings` 与 `copyAccepts` 是同一段逻辑的两种值类型

- **位置**：`f_jit/src/JitBindSupport.cj:69-75`、`:77-84`
- **来源**：存量
- **判据**：review-checklist §2（只改类型名的重复）
- **证据**：静态确定 —— 两函数体逐行对齐：新建 `HashMap`、`for ((k, v) in src)` 逐项赋值、返回；唯一差异是值类型 `JitBindings` 与 `(Object) -> Bool`，无边界、无日志、无错误处理差异
- **描述**：真正的差异点为零，属于纯复制。后续若要加「复制时校验」或「复制时统计容量」，必须同时改两处，漏一处即行为漂移（两张表在同一快照里，漂移会破坏「同代登记」这一不变量）
- **建议**：合并为一个泛型私有函数 `private static func copyOf<K, V>(src: HashMap<K, V>): HashMap<K, V>`，两处调用点分别实例化为 `copyOf(old.enrolled)` / `copyOf(old.interfaceAccepts)`；若 std 提供 `HashMap` 拷贝构造，直接用构造更短

### [轻微][存量] `HOST_OBJECT_CODE` / `UNIT_CODE` 注释称「宏里直接引用」，实际宏硬编码 14 / 3

- **位置**：`f_jit/src/JitBindSupport.cj:86-90`（宏侧：`f_jit/src/macros/JitBind.cj:231`、`:253`）
- **来源**：存量
- **判据**：review-checklist §2「字面量复制」（同一张类型码表散落多处）；§11「注释与实现不符」
- **证据**：静态确定 —— 全仓 grep `HOST_OBJECT_CODE|UNIT_CODE` 只命中定义处（`JitBindSupport.cj:87`、`:90`）与 README 的 API 清单（`README.md:665`、`README_en.md:705`），无任何 `.cj` 引用；宏侧 `buildMethod` 直接写 `Token(TokenKind.INTEGER_LITERAL, '14')` 与 `'3'` 作为形参/返回码
- **描述**：注释「宏里直接引用，避免再包一层函数」与事实相反；同时 `LocalType.HOST_OBJECT` / `UNIT` 的类型码在宏里以裸数字复制了一份。typecode 是桥接契约（`RegisterSection` 与宏展开必须逐位一致），一旦 `LocalType` 调整，宏不会跟着变，而这两个「为宏准备」的常量也不会被编译期发现是死值
- **建议**：宏侧 emit `JitBindSupport.HOST_OBJECT_CODE` / `JitBindSupport.UNIT_CODE` 的 token（常量在同一包，宏展开可见），或删掉这两个常量并改注释；两条路径选一条，避免「常量存在但无人用、字面量在用」的中间态

### [轻微][存量] 用例内的夹具重置逻辑被复制了一份

- **位置**：`f_jit/src/CompilerRegistration_test.cj:116-120` vs `:274-277`
- **来源**：存量
- **判据**：review-checklist §2（同文件近似重复）
- **证据**：静态确定 —— `compiler()` 做「`CompileCache.reset()` + `HostFieldTable.resetForTest()` + 构造 `Compiler`」；`memberConflictIsSkipNotReject` 手写同样三行，唯一差异是 sink 换成 `RegistrationSink()`（需要读诊断）
- **描述**：差异是业务要求（要记录诊断），但实现方式是整段复制。夹具以后若再加一步（例如重置 `SignatureRegistry`），复制体不会同步，出现「有的用例干净、有的不干净」的隐性污染
- **建议**：把 `compiler()` 改成 `compiler(sink: ?DiagnosticsSink = None)`（`None` 用 `DummyDiagnosticsSink()`），`memberConflictIsSkipNotReject` 改为传 `sink`

### [轻微][存量] `made2.id` 断言恒真，二参构造的 `id` 映射没有被真正验证

- **位置**：`f_jit/src/CompilerRegistration_test.cj:148`（`ManualUser.id` 定义见 `:345-349`）
- **来源**：存量
- **判据**：review-checklist §11「语义与命名不符 / 空断言」；测试有效性
- **证据**：静态确定 —— `public prop id: Int64 { get() { 0 } }` 恒返回 0，与 `init(name:age:)` 传入的实参无关；`@Assert(made2.id, 0)` 因此在任何实现下都成立
- **描述**：手工描述符里 `PublicCtor(params: [STRING, I64], adapter: …)` 的第二个实参是否正确封送，本应由这条断言兜住，实际没有。`ManualUser` 有 `age` 字段（`index: 1`）却未参与断言，`name`/`age` 的错位不会被发现
- **建议**：让 `id` 由构造参数决定（如 `init(name:age:)` 里 `this.id = age`），或把断言改为 `@Assert(made2.age, 3)` 并对 `name` 已有断言保持不变

### [轻微][存量] 三个同形「取名字集合」辅助函数 + 三处精确 size 断言

- **位置**：`f_jit/src/JitBindIgnore_test.cj:104-110`、`:112-118`、`:120-126`（断言在 `:132`、`:148`、`:155`）
- **来源**：存量
- **判据**：review-checklist §2（只改字段名的重复）
- **证据**：静态确定 —— 三个函数体结构完全相同：新建 `HashSet<String>`、`for (x in bindings().<集合>)` 加 `x.name`、返回；差异只有 `methods` / `statics` / `fields`
- **描述**：重复本身很小，真正的问题是配套的 `size == 2` / `size == 1` 精确断言把「当前宏产出数量」写死了。将来给 `@JitBind` 增补成员（例如自动生成 `equals`/`toString` 绑定或新增属性合成规则）时，这三处会同时红，而红的原因与「忽略名单失效」无关，定位成本高
- **建议**：合并为 `private static func namesOf(sel: (JitBindings) -> Array<String>): HashSet<String>`（或直接 `bindings().methods.map { m => m.name }`）；size 断言改为「忽略项不在集合中 + 非忽略项在集合中」，只在确实需要钉数量时保留一处并注明与宏版本的耦合

### [轻微][存量] 并发门闩是无 yield 的忙等，且并发度按「构建机 7 核」写死

- **位置**：`f_jit/src/ConcurrencyMatrix_test.cj:52-58`（并发度常量 `:39-40`）
- **来源**：存量
- **判据**：review-checklist §6.4（忙等/自旋占用），§12.1（测试并发覆盖度）
- **证据**：静态确定 —— 门闩循环体只有 `spins = spins + 1`，无 `sleep`/`yield`/park；上限 `100000000`；注释自述「构建机 7 核，6 线程」。核数不足时先起的线程会在门闩里吃满 CPU，等待的线程拿不到核，门闩退化为「尽早开始」，用例自述这会「让竞态更难复现」
- **描述**：在 2~4 核 CI（或被其他任务挤占的机器）上，这段既浪费 CPU 又削弱它想制造的并发交错 —— 用例仍会绿，但覆盖度已下降且无任何提示。上限 1e8 次自旋在慢机器上本身可能耗时数秒，进一步拉长测试
- **建议**：改用 `std.sync` 的阻塞原语（`Barrier` / `SyncCounter` / `Condition`）一次性放行；必须自旋时每 N 次调 `sleep(Duration.millisecond)` 并降低上限（如 1e6）；并发度改为 `min(6, cpuCount)` 并在注释里写明降级后的语义

### [轻微][存量] 迭代器生命周期用例只 pin 不 release，句柄账目永久漂移

- **位置**：`f_jit/src/IterLifecycle_test.cj:43-44`（`HandleTable.pin(m)`，全函数无 `HandleTable.release(h)`）
- **来源**：存量
- **判据**：review-checklist §11「资源不对称：acquire 未 release」
- **证据**：静态确定 —— `HandleTable` 提供 `release(id)`（`src/runtime/HandleTable.cj:986`），本用例取到 `h` 后直接 `IterTable.open(h, 0u8)`，用例结束未归还；`IterTable` 被桥清空后该 pin 仍然存活
- **描述**：每跑一次该用例，进程内 `HandleTable.liveCount()` 就多 1 且永不回落。本用例自身用相对基线，暂不误伤；但同模块其它用例（`ConstantReclaimFacade_test`、`ConcurrencyMatrix_test.concurrentCallsOnDifferentClosures`）拿 `liveCount()` 做绝对/相对对账，多一条泄漏项会让「句柄是否回收」这类断言的信噪比下降
- **建议**：`try { … } finally { HandleTable.release(h) }`，并在用例末断言 `liveCount()` 回到用例开始时的基线

### [轻微][存量] 两个测试专用的诊断 sink 逐行重复

- **位置**：`f_jit/src/CompilerRegistration_test.cj:353-374`（`RegistrationSink`）
- **来源**：存量
- **判据**：review-checklist §2（跨文件复制，仅类名/方法集微差）
- **证据**：静态确定 —— 与 `f_jit/src/ReflectRegistrar_test.cj:361-386` 的 `RecReflectSink` 逐行对齐：`private let messages = ArrayList<String>()`、`init()`、`diag(level, code, message)` 忽略前两参只存 message、`count()`、`contains(text)` 线性扫描；唯一差异是 `RecReflectSink` 多一个 `onlySkipped()`。另有 `src/backend/BackendSelector_test.cj:116` 的 `Sink` 记录 `(level, code)` 对，属第三种近似实现（该文件在本部分范围外，仅作比对）
- **描述**：同名职责（记录 `DiagnosticsSink` 消息用于断言）在模块内散了三份，`contains` 的实现完全一致。第三方（`Sink`）已记录 level/code，说明「更完整的版本」已经存在，却没人复用
- **建议**：在测试公共位置（如 `src/test/` 下的夹具文件）抽一个 `RecordingDiagnosticsSink`（记录 `(level, code, message)`，提供 `count` / `contains` / `lastCode`），三处改用同一实现；这是测试代码归并，不涉及产品 API

### [轻微][存量] 过程级计数器做精确断言，依赖 `cjpm test` 串行执行

- **位置**：`f_jit/src/ConcurrencyMatrix_test.cj:104`（`@Assert(CompileCache.runs(), 1)`）、`:147`（`== THREADS * per`）
- **来源**：存量
- **判据**：review-checklist §12.1（共享可变状态 + 测试隔离）；§11（断言脆弱）
- **证据**：静态确定 —— `CompileCache` 是进程级单例，`runs()` 是全局累加计数，本用例只靠开头的 `CompileCache.reset()`（`:63`、`:114`）保证起点为 0；同模块另有多个用例编译源码（`CompilerRegistration_test`、`JitBind_test` 等）并同样 `reset()`
- **描述**：只要测试运行器并行跑用例类（或未来开启 `--parallel`），`runs()` 就会被别的用例推进，两条精确断言随机失败；反过来，谁忘了 `reset()` 也会让别人的断言失败。当前 `f_jit/cjpm.toml` 无并行测试配置，所以现状成立，但这是隐式契约，没有一行注释或断言保护
- **建议**：断言改为「本用例内增量」：进入用例取 `let base = CompileCache.runs()`，结束时断言 `runs() - base == 1`（或 `48`）；这样即使并行也不会误判，且不需要全局 `reset()` 承担隔离职责

### [轻微][存量] 同名登记静默覆盖，无冲突诊断

- **位置**：`f_jit/src/JitBindSupport.cj:119`（`enrolled[key] = b`）、`:136-137`（`enrolled[key] = b` / `acceptsMap[key] = accepts`）
- **来源**：存量
- **判据**：`references/fountain-baseline.md` §4「同名注册（扩展 / 路由 / 插件）→ 启动直接失败，不做隐式优先级」
- **证据**：静态确定 —— `enrolled` / `interfaceAccepts` 的写入没有 `contains` 判断，也没有 `diag`；后写者直接覆盖。`JitBindSupportSnapshot_test` 的并发用例（`:67-78`）正是靠这层覆盖语义反复写同一个 key
- **描述**：同一个类被两个 `@JitBind`（或宏 + 显式 `enrollOf`）登记时是「最后写入者生效」，与基线 §4 相反。风险取决于是否有意：若「同类型重复登记等价于幂等」是设计，则当前实现正确，但缺一句注释；若不是，则两个包初始化顺序不同会导致绑定随机漂移，且没有任何日志能发现
- **建议**：至少加一句注释说明 last-wins 是有意语义；更稳的做法是覆盖时比对 `JitBindings` 的方法/字段集合，不一致则 `diag(WARNING, …)`（生产路径不 `throw`，避免包初始化顺序问题升级为启动失败）。属**待确认**项：需要作者确认覆盖语义是否为契约

## 优化可行性方案

本部分未提出有基线的优化方案（无 profile / bench 数据，两条候选均已降级进「待验证假设」，不进 `todo.md` / `tasks.md`）。

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `acceptsInterface` 在每次「接口类型实参」封送时做 1 次 `AtomicReference.load` + 1 次 `HashMap.get`，可能是封送固定开销的组成部分；若实参封送本身只有几百 ns，这里占比可观 | `f_jit/src/JitBindSupport.cj:147-153` | 自耗时占比、调用频次（每脚本调用几次） | `cjprof record` 跑 10 万次含接口形参的脚本调用（`-O2`），看 `acceptsInterface` self time 占比；同时计数调用次数 |
| 2 | 每次 `enrollOf` 复制整张已登记表（写时复制），N 个 `@JitBind` 类启动期为 O(N²) 次插入；类多时启动耗时可能可见 | `f_jit/src/JitBindSupport.cj:114-122` | 启动期登记总耗时随 N 的变化曲线 | 用 100 / 500 / 1000 个 `@JitBind` 类各跑一次包初始化，分段计时取中位数（`-O2`，同机） |
| 3 | `ConcurrencyMatrix_test.gate` 在低核 CI 上把并发窗口压缩，降低竞态复现率，同时吃掉整段 CPU | `f_jit/src/ConcurrencyMatrix_test.cj:52-58` | 实际交错次数 / 变异命中率 | 2 核与 8 核各跑 100 轮，统计「变异版（故意破坏去重）被检出」的比例与单次耗时 |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_jit/src/CompilerRegistrationConcurrency_test.cj` | .cj | ✅ | 探针与实际断言不符，见发现 #2 |
| 2 | `f_jit/src/CompilerRegistration_test.cj` | .cj | ✅ | 夹具复制、恒真断言、sink 重复，见 #8 / #9 / #13 |
| 3 | `f_jit/src/CompilerSnapshotCache_test.cj` | .cj | ✅ | 缓存失效语义两条用例与实现一致，无问题 |
| 4 | `f_jit/src/ConcurrencyMatrix_test.cj` | .cj | ✅ | 忙等门闩、全局计数精确断言，见 #11 / #14 |
| 5 | `f_jit/src/ConstantReclaimFacade_test.cj` | .cj | ✅ | 设置 `initialCapacity=128` / `capacityLimit=1048576` 与 `HandleTable` 默认值（`src/runtime/HandleTable.cj:168-169`）相同，无副作用；用例语义成立 |
| 6 | `f_jit/src/DaDiagnostic_test.cj` | .cj | ✅ | 四条分类断言与注释一致，无问题 |
| 7 | `f_jit/src/EscapedClosure.cj` | .cj | ✅ | 字段 `seq`/`group`/`state`/`active` 均有读写方（`JitFunction.cj:382` / `:270` / `:307,321,328` / `:347,354`），锁归属与注释一致；无死代码、无递归 |
| 8 | `f_jit/src/FacadeRegistry_test.cj` | .cj | ✅ | 注册/查询/注销、限额用例，断言与实现一致 |
| 9 | `f_jit/src/HandleTableConfigRace_test.cj` | .cj | ✅ | 保存/恢复全局配置且注释诚实说明「不构成变异证据」，是本部分测试卫生的正面样例 |
| 10 | `f_jit/src/HelperTableScope_test.cj` | .cj | ✅ | 栈语义与残留检查扎实，无问题 |
| 11 | `f_jit/src/HostClosureAdapter_test.cj` | .cj | ✅ | 单样本性能门禁，见 #3 |
| 12 | `f_jit/src/HostSignature_test.cj` | .cj | ✅ | 签名幂等/形状严格性用例，无问题 |
| 13 | `f_jit/src/Inheritance_test.cj` | .cj | ✅ | 缺版权头，见 #1 |
| 14 | `f_jit/src/Interface_test.cj` | .cj | ✅ | 缺版权头，见 #1 |
| 15 | `f_jit/src/IterLifecycle_test.cj` | .cj | ✅ | 句柄未 release，见 #12 |
| 16 | `f_jit/src/JitBacked_test.cj` | .cj | ✅ | `isJitBacked` 守卫四条用例，针对「静默回退」这一真实风险，无问题 |
| 17 | `f_jit/src/JitBindIgnore_test.cj` | .cj | ✅ | 三个同形辅助 + 精确 size 断言，见 #10 |
| 18 | `f_jit/src/JitBindSupport.cj` | .cj | ✅ | 三处 KDoc 错位、复制函数、常量与宏字面量重复、静默覆盖，见 #5 / #6 / #7 / #15 |
| 19 | `f_jit/src/JitBindSupportSnapshot_test.cj` | .cj | ✅ | 断言失败可挂死进程，见 #4 |
| 20 | `f_jit/src/JitBind_test.cj` | .cj | ✅ | 四类成员登记 / 合并 / 300 次重复调用，无问题 |

合计：`.cj` 20 个 / `.md` 0 个 / 共 20 个，全部读完。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 2 | 可读性/注释：#5、#7；无安全检查面（本部分无外部输入、无注入点、无凭据；`JitBindSupport` 只做类型码与闭包登记）。正确性主路径（快照发布、字段锁归属）逐个函数核对后无缺陷 |
| §1 死代码 | 0 | `JitBindSupport` 的 `copyBindings`/`copyAccepts`/`writeMtx`/`current`/`BindSnapshot` 均被引用；`HOST_OBJECT_CODE`、`UNIT_CODE`、`bindName`、`code`、`parentsOf`、`isInterface`、`acceptsInterface` 属对外可达 public（`public class JitBindSupport`），按硬原则一不判死代码（仓内引用情况已写入 #7 与 README 提示）；`internal publishHook` 仅被 `JitBindSupportSnapshot_test.cj:109,126` 引用 —— 属「仅测试使用」，按 §1 记可见性信息不记死代码；`EscapedClosure` 为包内类，其 4 个字段全部有读方（见文件覆盖 #7）。私有辅助函数（测试类里的 `compiler`/`manualDescriptor`/`gate`/`kindOf`/`methodOf` 等）逐个搜过，均有调用者 |
| §2 重复逻辑 | 5 | #6（`copyBindings`/`copyAccepts`）、#7（常量 vs 宏字面量 14/3）、#8（夹具重置三行）、#10（三个 name-set 函数）、#13（两个测试 sink 逐行重复）。此外比对过本部分 5 组结构相近的用例（快照缓存 2 条、签名 2 条、继承 2 条），差异点都是业务要求（不同缓存失效路径 / 不同签名形状 / 不同继承场景），不记重复 |
| §3 空实现 | 0 | 无空函数体、无 `TODO`/`FIXME`/`UnsupportedException`；`case None => ()` 出现在 `JitBindSupport.cj:141`（可选钩子的正常缺省）与测试的 `match` 兜底（`CompilerRegistration_test.cj:321`），语义正确。`DummyDiagnosticsSink` 是文档化的空实现（本部分仅作参数使用） |
| §4 栈溢出 | 0 | 本部分无递归函数、无自引用结构遍历、无深拷贝；`ConcurrencyMatrix_test`/`CompilerRegistrationConcurrency_test` 的深度由常量线程数决定 |
| §5 OOM | 0 | 容器均有界：`ConcurrencyMatrix_test` 的 `fs` 最多 6 个 Future、`JitBindSupportSnapshot_test` 的写者循环固定 2000 次、`CompilerRegistration_test` 的 `ArrayList<String>` 只存诊断文案；`JitBindSupport` 的 `enrolled`/`interfaceAccepts` 以类名为 key，规模受已注册类数约束，无按请求增长路径；无按不可信长度预分配 |
| §6.1 热点瓶颈 | 0 | 无 `cjprof` / `cjpm bench` 数据，`acceptsInterface` 与写时复制两条候选结论已降级进「待验证假设」#1/#2，不作为发现 |
| §6.2 大粒度锁 | 0 | 产品侧的 `writeMtx` 只包「复制两张表 + 发布引用」，无 I/O、无日志、无解析，临界区与不变量等长；唯一「锁内跑外部回调」是测试专用 `publishHook`（`JitBindSupport.cj:139-142`），已并入 #4 说明，不单列 |
| §6.3 并发串行 | 0 | 无 `spawn(...).get()` 形式并发；`ConcurrencyMatrix_test` 均为「先全部提交、再统一 `get()`」 |
| §6.4 低效算法 | 1 | #11（门闩无 yield 自旋，吃 CPU 且削弱交错）；`JitBindSupport` 的写时复制是 O(N) 每写、O(N²) 总计，但发生在冷路径，且无数据证明是瓶颈，按 §6.1 规则不记缺陷 |
| §7 降堆内存方案 | 0 | 无长期持有的大对象；`BindSnapshot` 每次登记多一份表副本，但旧快照随即不可达（写时复制的固有代价，非泄漏）；无基线，不改写为结论 |
| §8 降 CPU 方案 | 0 | 与 §6.1 同因：缺测量数据；唯一可说的 `bindNameOf` 字符串拼接在冷路径，不构成方案 |
| §9 local mode 可行性 | 0 | 本部分无「函数内创建、函数内销毁的大临时对象」；`JitBindings` 复制结果会逃逸进静态快照，逃逸检查不通过（`JitBindSupport.cj:118-120`）；改造收益需峰值内存前后对照，当前无数据 |
| §11 现有代码的 BUG（存量） | 3 | #2（探针失效）、#9（恒真断言）、#12（句柄未回收）。另核对了 20 个文件的边界/空值/异常路径：`expectClassReject` 的 `None` 分支、`DaDiagnostic_test.kindOf` 的双 catch、`HandleTableConfigRace_test` 的保存-恢复、`ConstantReclaimFacade_test` 的 `close(0)` 返回值均正确 |
| §12 并发安全与锁粒度 | 2 | #4（测试钩子在全局锁内自旋 + 失败不复位 → 挂死）、#14（过程级计数器做精确断言）。产品侧并发结论：`JitBindSupport` 的「写时复制 + `AtomicReference` 原子发布」是良构的 —— 写者全在 `writeMtx` 内完成「读旧快照 → 复制 → 填充 → store」，读者只做一次 `load`（`AtomicReference.load` 采用默认内存排序，见 `api/std/sync/classes/atomicreference/load.md`），两张表因此同代；`EscapedClosure.state/active` 的全部读写都在所属单元的 `mtx` 内（`JitFunction.cj:307,321,328,347,354`），`seq`/`group` 是 `let` |
| §14 功能完备性与 README 覆盖 | 0 | 本部分无 `.md`，「承诺但未实现」需 README 侧取证，归模块其它部分。**范围外提示（一句）**：对照 `README.md:665` 的 `JitBindSupport` 成员清单，`public static func code<T>()`（`JitBindSupport.cj:93`）与 `enrollOf<T>()`（`:114`）两个 public 成员未列入，README 的 API 清单因此不完整 |
| 文件覆盖（§13 等） | 20/20 | 清单 20 个文件逐行读完；本部分不含 `.md`，§13 文档一致性无可审对象（README 属其它部分） |

## 模块统计（仅本部分）

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 0 |
| 一般 | 4 |
| 轻微 | 11 |
| 优化方案（堆内存 / CPU） | 0 / 0 |

存量 15 条（4 一般 + 11 轻微），是否纳入修复待用户决定。

## 总评

本部分是 `f_jit` 的「注册 / 绑定 / 重载解析」测试集群，加上两个薄产品文件。产品代码质量好：`JitBindSupport` 用「写时复制 + `AtomicReference` 原子发布」替换全局锁读路径，写者只在 `writeMtx` 内复制与发布、读者零锁且两张表同代，是我在本部分唯一需要证明的并发不变量，读完后成立；`EscapedClosure` 刻意把 `state`/`active` 交给所属单元的 `mtx` 保护并在注释里写明「不在条目上加锁」，实际读写路径与该约定一致，没有偷跑出来的裸访问。typecode 分支表这块本部分只看到常量与宏的分工（宏硬编码 14/3、常量无人引用，见 #7），真正的 typecode 分派在各 Lower/Marshal 文件里，属其它部分。

风险集中在测试层，且都是「给了安全感但没给保护」这一类：并发注册用例的成对断言发生在注册返回之后，观察不到它自己声明的窗口（#2）；性能门禁是单样本 + 固定顺序（#3）；断言失败会把恒阻塞钩子留在全局锁内，让进程挂死而不是变红（#4）。这三条不修，后续对注册路径或绑定快照的重构很可能在「全绿」的情况下把缺陷放过去。另有 2 个文件缺版权头（#1），修起来最便宜。

无阻塞项（0 严重）；4 条一般建议排进下一轮，11 条轻微里 #5 / #7（注释与常量的口径）优先，因为 `typecode` 一旦调整，宏与常量的漂移不会有任何编译期告警。
