# f_jit 模块审查报告（第 35/38 部分）

- **审查日期**：2026-11-28
- **模块路径**：`f_jit/src/runtime/`（本部分 12 个源文件，全部 `.cj`）
- **基线**：工作区快照（master 与 sts/1.3.x 同一提交 `120fd2542`，`git diff` 为空）⇒ 全部结论来源为「存量」
- **审查重点**：动态调用 / 桥接正确性（helper 分派表、cell↔宿主值转换）、句柄与资源生命周期、并发安全、死代码、重复逻辑
- **报告版本**：v1（分部分报告，由主 Agent 合并进 `f_jit_v2.md`）

## 发现

### [一般][存量] `cellToAny` 用 `isLiveHandle` 猜测「cell 是否句柄」，Int64 大值与 Float64 位型会被误判为句柄

- **位置**：`f_jit/src/runtime/HandleTable.cj:1331-1337`（`cellToAny`）；写入口 `f_jit/src/runtime/Helpers.cj:796-836`（H43/H44/H45/H46）；值域前提注释 `f_jit/src/runtime/HandleTable.cj:135-137`
- **来源**：存量（工作区快照，无基线可比）
- **判据**：review-checklist §11（数据错误 / 契约与实现不符）、§10 正确性
- **证据**：静态确定 —— `cellToAny(cell)` 先 `getAny(cell)`，命中活槽就返回**槽里的对象**，否则才把 `cell` 当原值；判定完全依赖 `isLiveHandle`（`alive && gens == genOf(cell)`）。类注释宣称「任何已分配句柄的 `gen ≥ 1` ⇒ ID ≥ 2^48，与普通整数值域天然不交」，但该结论只对**小于 2^48** 的 Int64 成立，对 `Float64` 位模式（cell 表示见 `f_jit/doc/jit-bytecode-m1.md:150` 的 §3.2「Float64 = IEEE754 位模式」）根本不成立。
- **描述**：`List<Int64>` 的 `l.add(x)`（`compiler/Lowerer.cj:3112-3116`：`lowerExpr` 后直接 `LIST_APPEND`，元素 cell 未装箱）会把 `x` 的原始 cell 交给 `cellToAny`。若 `x` 恰好等于某个活槽的 ID（例如 `gen=1, tag=3, idx=5` ⇒ `281487861612549`），写入容器的不是这个整数，而是该槽里的 String 对象；同理某些 Float64 位型（`gen` 落在已用世代、`tag`/`idx` 命中活槽）也会被当成句柄。后果是**静默的取值错误**（元素类型与值同时被替换），不报错。触发需要特定数值，属于窄值域缺陷，但完全确定、可构造。
- **建议**：两个方向择一：① 容器元素写入按**静态类型**分派（`LIST_APPEND` 增加「元素是否引用型」的编译期标志，或按 §11.7 LocalType 拆出 `LIST_APPEND_VAL` / 现有句柄版），值型直接存原值、不再走 `cellToAny`；② 若维持现状，把类注释的「天然不交」改为「Int64 < 2^48 与 Bool 安全；Float64 与 ≥ 2^48 的 Int64 存在理论混叠」，并在 `f_jit/doc/jit-bytecode-m1.md` §3.2 登记该限制。

### [一般][存量] `releaseConst` 缺世代号校验，与复用后的常量槽可能串账

- **位置**：`f_jit/src/runtime/HandleTable.cj:633-656`
- **来源**：存量
- **判据**：review-checklist §11（资源/契约）、§12.1（检查-然后-写入的原子性）
- **证据**：静态确定（缺 `gens[off] == genOf(id)` 校验）／可达性待确认（当前调用方有幂等保护）
- **描述**：`release`（`:995`）、`releaseEscaped`（`:1017`）、`resetWindow`（`:1073`）在释放前都比对 `gens[off] == genOf(id)`，唯独 `releaseConst` 只判 `alive && constFlags`。若同一 ID 被释放两次（或单元卸载与常量重登记交错）：第一次把 refs 归零、槽 gen+1 并进空闲表；第二次同一个过期 ID 仍能通过 `alive && constFlags`（槽被别的值重新登记为常量后），把**新常量**的 refs 减到 0 并回收 —— 另一个单元持有的常量句柄随之失效，后续 `fetch` 得 `ERR_NULL_HANDLE(6)`。现有调用方 `backend/JitExecutor.cj:186-206` 用 `released` 标志与一次性清理闭包（`CompilePipeline.cj:258`）挡住了重复释放，所以目前不可达。
- **建议**：在 `releaseConst` 的判定里补 `seg.gens[off] == genOf(id)`，与其余三个释放入口同口径；补一条「过期常量 ID 重复释放不影响新常量」的用例。

### [一般][存量] 句柄读路径无锁、释放路径有锁，同一槽的「读 `alive` → 读载荷」不原子

- **位置**：`f_jit/src/runtime/HandleTable.cj:775-789`（`getAny`）、`:934-947`（`isType`）、`:950-962`（`tagOrZero`）、`:1387-1404`（`markFrozen`/`isFrozen`）；写侧 `:986-1003`（`release`）、`:1053-1082`（`resetWindow`）
- **来源**：存量
- **判据**：review-checklist §12.1（共享可变状态无保护 / 可见性）
- **证据**：静态确定（存在中间态）／能否被外部并发调用待确认（缺「同一 ID 跨线程读+释放」的契约说明）
- **描述**：`getAny` 先读 `seg.alive[off]` 再读 `seg.objs[off]`，两步都不是原子/有序的；`release` 在分片锁内依次写 `alive=false` → `objs=0` → `gens+1`。二者交错时读者可能看到「`alive=true` 且 `gens` 恰好仍是旧值」，但 `objs` 已被清成 `Int64(0)`，于是 `getAny` 返回 `Some(0)`（调用方会把它当合法对象，最终在类型分支上得到 `HANDLE_TYPE(8)` 或错误值），而不是 `None`。同类问题还有 `markFrozen` 在 `mtx` 内写、`isFrozen`（`:1398`）完全无锁读 —— 可见性无保证，H82 的写保护判定可能读到旧值。`resetWindow` 与 JIT 线程的读同理。文件头注释（`:779-781`）只声明「槽只由 owner 写、发布后内容不变」，未覆盖**释放**这一写。
- **建议**：① 把「清空 + gen+1」合并成一个可判定顺序：先 `gens[off] = gen+1`（单写原子，读者按 gen 失配直接 None），再清 `objs`/`alive`；② 或引入每槽 `Int64` 的「状态字」（`gen<<1 | alive`）单点发布，读者只读一次；③ `isFrozen` 改为与 `markFrozen` 同锁，或在文档中明确「frozen 只在同线程调用期内可见」。三种都要补一条并发用例（写线程反复 release、读线程反复 get）。

### [一般][存量] 重复逻辑：`release` 与 `releaseEscaped` 是同一实现的两份拷贝

- **位置**：`f_jit/src/runtime/HandleTable.cj:986-1003` 与 `:1006-1026`
- **来源**：存量
- **判据**：review-checklist §2（只改控制流的重复实现）
- **证据**：静态确定 —— 两者输入（`id`）→ 输出（无）→ 副作用（`alive=false`、`objs=0`、清 `escape`/`frozen`、`freeOrRetire`）逐条一致；差异只有判定写法（`release` 用 `if (alive && gens==… && !const)` 合取，`releaseEscaped` 用三条 `return` 早退）。`release` 已经能把逃逸槽回收（`:980-985` 的注释与 `HandleTableM2_test.cj:199-224` 的用例都在证这一点）。
- **描述**：两份实现同时存在，任一处补逻辑（如上面那条 gen 校验、或将来加 `frozen` 语义）都会漂移；`releaseEscaped` 的语义注释「桥把返回值取成宿主对象后调用」也不再是独有语义。
- **建议**：保留 `release`，把 `releaseEscaped` 改成 `release(id)` 的一行转发（或直接删除调用点 `JitFunction.cj:712` / `PromotionGroup.cj:93` 改调 `release`）；两者失败语义已一致，无行为变化。

### [一般][存量] 重复逻辑：槽有效性守卫表达式在 13 处逐字复制

- **位置**：`f_jit/src/runtime/HandleTable.cj:471-472、519-520、583-584、748-749、784、820、923、942、957、972、1037、1116、1328`
- **来源**：存量
- **判据**：review-checklist §2（字面量/表达式复制，含漂移风险）
- **证据**：静态确定 —— 各处的判定都是 `i > 0 && seg.alive[off] && seg.gens[off] == genOf(id)`（后几处再加上 `tags[off] == tok` / `!constFlags` 的变体）；`idxOf`/`offOf`/`segAt` 三连也在同一批函数里重复。
- **描述**：这不是「为可读性展开」——13 处是同一不变量的机械复制。已能看到不一致的苗头：`appendHostObjectWith`（`:743`）只扫 `appendIds` 而其余 pin 路径扫 `appendIds + pins`（这是**有意**的窗口记账差异，注释已写明），但守卫本身仍逐字重复；`isConst`/`isEscaped`/`isFrozen` 又各自漏掉 gen 校验（见上一条的后果）。任一处漏改就会产生「某路径接受失效槽」的静默缺陷。
- **建议**：私有化一个 `slotAt(id, tok): ?(SlotSeg, Int64)`（一次性做 `id>0` / `i>0` / `alive` / `gen` / 可选 `tag` 校验），所有读路径改走它；`release`/`resetWindow`/`moveOutGroup` 改走 `withLiveSlot(id) { seg, off => … }`。行为参数化（是否要求 `!constFlags`）而不是复制。

### [一般][存量] `replaceSpans` 全量物化匹配位置 + 全量输出缓冲，无上限且单次替换也要扫全串

- **位置**：`f_jit/src/runtime/Helpers.cj:959-1005`（`replaceSpans`），调用点 `:903-936`（H58/H59/H72）
- **来源**：存量
- **判据**：review-checklist §5（一次性物化 / 无拒绝路径）、§6.4（可提前退出的全量扫描）
- **证据**：静态确定（放大倍数可算）／OOM 阈值需实测
- **描述**：`re.lazyFindAll(input)` 虽然是惰性的，但这里先把**全部**匹配的 `start/end` 收进两个 `ArrayList<Int64>`，再重建整串输出。按输入 n 字节、模式几乎处处命中估算：位置表 `2 × (n/2) × 8B = 8n`，输出 `ArrayList<UInt8>` 峰值约 `2n`（扩容期），合计 ≈ **10 倍输入**的瞬时占用；n = 100 MB 时约 1 GB，且没有上限/拒绝路径。另外 `regexReplaceNth(re,s,r,n)`（只替换第 n 个）与 `regexReplaceRange(…,n,m)`（替换 m 个）也必须把全部匹配扫完才动手，命中率高时属于纯浪费。
- **建议**：① `from/count` 命中后即可停止收集（`count >= 0` 时超过 `from+count` 的匹配只需保留 `end` 作为「拷贝到末尾」的起点）；② 输出按 `input.size + Δ` 预估容量一次性分配，避免 `ArrayList<UInt8>` 多次扩容；③ 给 `String` 长度或匹配数设上限并在超限时返回 `ERR_ARG_MISMATCH(14)` 而不是 OOM。三处都要有等价性用例（顺序、重叠匹配、零宽匹配、多字节字符）。

### [轻微][存量] 死代码：4 个符号零引用 + 1 处恒不可达分支

- **位置**：`f_jit/src/runtime/HandleTable.cj:252-259`（`currentWinOrNone`）、`:1162-1168`（`pushFree`）、`:1170-1176`（`popFree()`）、`:1055-1059`（`resetWindow` 的 `else` 分支）；`f_jit/src/runtime/HelperCore.cj:95-108`（`tokenOfValue`）与 `:111-132`（`decTriple`）
- **来源**：存量
- **判据**：review-checklist §1（`private`/`internal` 无引用、不可达分支）
- **证据**：静态确定 —— 全仓 `grep -rn --include=*.cj "currentWinOrNone|pushFree|popFree"`（排除 `.worktrees/`）只命中定义处；`popFreeWith` 才是分配器实际使用的那份（`:1227`）。`winStackOf`（`:208-213`）保证返回的栈恒非空，故 `resetWindow` 里 `if (s.size > 0) … else acquireWin(…)` 的 `else` 永不执行。`tokenOfValue` 全仓（`.cj` + `.md`）零引用，`decTriple` 只被 `tokenOfValue` 的函数体引用 ⇒ 一对死代码（`decTriple` 还带一个 `decTriple(d)[0..2]` 三连调用的重复计算，随删除一并消失）。
- **建议**：删除 4 个符号与 1 个分支；`popFree` 的 TLS 版本若担心后续需要，改为在注释里留一句「用 `popFreeWith(RuntimeEnv.current())`」，不要留空壳。删除前确认无下游仓库按名引用（两个 `private`、一个 `internal`，均不跨模块，风险为零）。

### [一般][存量] H84 `ipow` 未登记进 `HelperId.name` / `isFixed`，hid 名字表与分派表脱节

- **位置**：`f_jit/src/runtime/HelperId.cj:120-121`（声明）、`:130-220`（`name` 缺 `case 84u16`）、`:222-226`（`isFixed`）；对照 `f_jit/src/runtime/Helpers.cj:138-139`（`case 84 => ipow`）
- **来源**：存量
- **判据**：review-checklist §14.1（"枚举新 case 没有分支" / 接线缺失）、§13（表与实现漂移）
- **证据**：静态确定 —— `name` 的 `match` 覆盖 1–65、69–83，唯独没有 `84u16`，落到 `_ => 'unknown(84)'`；`isFixed(84)` 因此返回 `false`。而 `HelperId.IPOW = 84` 是正式常量、`dispatchHelper` 有 `case 84 => ipow`，`Helpers_test.cj:113-117` 的期望表也只列到 83（所以这条缺口没有被用例抓到）。
- **描述**：同一个「已登记 hid」在两张表里结论相反：分派表认它是固定 helper，名字/合法性表认它是未知值。当前 `isFixed` 只被测试引用（`Ops.cj:218` 的注释把它定位为「hid 合法值域」的守卫），所以眼下只影响诊断输出（运行期报告里 H84 会显示 `unknown(84)`）；一旦按注释把这层守卫接到加载期/汇编期校验，`**` 运算就会被误判为未实现（`ERR_NOT_IMPL` 18）。另外 `MAX_FIXED = 72`（`:125`）也没随 73–84 的扩展更新，与 `isFixed` 实际返回 `true` 的范围矛盾。
- **建议**：`name` 补 `case 84u16 => 'ipow'`；把 `isFixed` 改成纯数值判定（`hid != 66 && 67 && 68 && hid <= 84`），并用 `MAX_FIXED`/新常量表达上界；在 `Helpers_test` 的期望表里补 84 与 `name(84)`，让「声明 ⊂ name ⊂ isFixed」三者由一条用例守住。

### [轻微][存量] 注释与实现不符（2 处）

- **位置**：`f_jit/src/runtime/HandleTable.cj:445-449`、`f_jit/src/runtime/HelperEntry.cj:18-27`
- **来源**：存量
- **判据**：review-checklist §10（可读性 / 可维护性：注释承诺 A、实现做 B）
- **证据**：静态确定
- **描述**：① `pin` 的说明写「仓颉没有引用相等运算符，`==` 对 `ArrayList` 是值相等」，但同一文件 `:481`、`:587`、`:752` 都在用 `refEq`，`std.core` 提供该运算符 —— 该括注是旧结论，会误导后来者放弃按身份去重；② `HelperEntry.cj` 头部声明「机器码经固定 ABI 调用本表（每个 helper 一个 `@C` 入口）」，实际两个后端都只取 `HelperAddresses.dispatch()` 走 `h_dispatch`（`backend/X86Lower.cj:59/416`、`backend/A64Lower.cj:50/530`），72 个 `@C` 入口在仓内仅 `HelperEntry_test.cj` 使用。
- **建议**：① 删掉「没有引用相等运算符」的括注；② 头部改成「`h_dispatch` 是机器码的唯一入口；逐 helper 的 `@C` 入口保留给宿主导调/测试」，并说明新增 hid 需同时改 `HelperId` + `dispatchHelper`（H84 的教训见上一条）。

### [轻微][存量] 测试：用例名与断言不符，`99` 兜底路径未被覆盖

- **位置**：`f_jit/src/runtime/Helpers_test.cj:716-728`（`helperInternalExceptionBecomes99`）
- **来源**：存量
- **判据**：review-checklist §3（空实现/兜底分支要有用例）、§10 可维护性
- **证据**：静态确定 —— 用例名声称验证「helper 内部异常 → `HELPER_PANIC(99)`」，但函数体只断言了 `call(16,[0]) → 6` 与 `call(66,[]) → 18`，没有任何输入会走到 `invokeHelper` 的 `catch (e: Exception)` 分支；`castFail`（H77）与 `hIsType` 的 `UInt16(argAt(...))` 受检转换失败才是 99 的真实入口。`HandleTableGenExhaustion_test.cj:60-63` 还留了一条 `println` 诊断（测试输出噪声）。
- **建议**：补一条真正触发 99 的用例（例如 `call(17, [s, 70000])` 让 `UInt16(Int64)` 溢出，走 `catch (e: Exception) → ctxWritePanic`），或把用例名改成它实际验证的内容；`println` 改为断言失败时才输出。

### [轻微][存量] 测试专用 API 以 `public` 暴露在对外类型上（可见性建议）

- **位置**：`f_jit/src/runtime/HandleTable.cj:1249`（`liveCount`）、`:1266`（`slotCount`）、`:1271`（`retiredCount`）、`:1276`（`resetForTest`）
- **来源**：存量
- **判据**：review-checklist §1「可见性建议」（**不是**死代码：`HandleTable` 是 `public class`，成员对外可达）
- **证据**：静态确定 —— 四个符号在仓内只被 `*_test.cj` 与 `HandleTable` 自身调用；`resetForTest` 的注释已自称「不用于生产路径」，但它能从任何下游代码清空整张全局句柄表（并让所有在飞 ID 失效），属于危险的能力外泄。
- **建议**：`resetForTest` 至少降为 `internal`（测试与被测代码同包，无需 public）；三个计数函数可保留（审计有用），但建议在注释里标明「审计用、非线程安全快照」。降可见性前需确认无下游依赖。

## 优化可行性方案

### [堆内存] 常量引用计数表 `constRefs` 常驻 8 B/槽，可为 1 M 槽表省约 8 MB

- **现状**：`SlotSeg`（`HandleTable.cj:57-77`）每段 1024 槽固定分配 8 个数组，其中 `constRefs: Array<Int64>` 占 **8 B/槽**（总 24 B/槽中的 1/3）；它只对**路径 A 常量槽**有意义（`releaseConst` 之外的读路径从不访问），而常量槽数量级是「单元常量个数」，远小于 `capacityLimit`。
- **方案**：`constRefs` 从段内数组改为段外的 `HashMap<Int64, Int64>`（键 = 全局 idx），或按段懒建（只有段内出现过 `pinConst` 时才分配该段的计数数组）。
- **预期**：`capacityLimit = 2^20` 全量增长时，槽内存从 ≈ 24 MB 降到 ≈ 16 MB（按 1024 槽/段、8 数组估算），常量路径额外承担一次哈希查找。
- **代价**：`pinConst`/`releaseConst` 多一次 map 访问（都在冷路径 + `mtx` 内）；`resetForTest` 需清 map。
- **验证**：`cjpm test -O2` 跑 `HandleTable_test` + `ConstantReclaim_test`，另用 `getAllocatedHeapSize()` 对照「增长到 1 M 槽后」的常驻差。
- **证据状态**：无基线（待验证，不进 tasks）

### [堆内存 / CPU] 每次 helper 调用都新分配 `Array<Int64>`

- **现状**：`helperEntry`（`HelperEntry.cj:33-44`）对**每一次** helper 调用 `Array<Int64>(n, repeat: 0)` 并把实参逐个拷进去；这是全 JIT 最热的一条路径（每条 `CALL_HELPER` 一次），分配次数 = helper 调用次数。
- **方案**：① 用 `RuntimeState` 上的线程私有可复用缓冲（容量按 max argc 增长，复用前只写前 n 项）；② 或让 `dispatchHelper` 直接读 `CPointer<Int64>`（把 `argAt` 改成接受裸指针 + n），彻底去掉托管数组。
- **预期**：helper 调用路径的分配次数从 1 降到 0，GC 压力与单次调用延迟同步下降（幅度待测）。
- **代价**：① 需要保证 `a` 不会在 `dispatchHelper` 内被保存（当前实现全部即时消费，无逃逸）；② 改签名会波及 72 个 `@C` 入口与 `invokeHelper` 的测试调用点（`AnyHelpers_test.cj:111` 等）。
- **验证**：`cjpm bench -O2` 跑 `PerfM2_test` / `CallPathBench_test` 的 helper 密集场景，对照中位数与 `getAllocatedHeapSize()`；`cjprof record` 看分配点是否从 `helperEntry` 消失。
- **证据状态**：无基线（待验证，不进 tasks）

### [CPU] 窗口内 pin 去重是线性扫描，随窗口内 pin 数退化为 O(n²)

- **现状**：`pinWith` / `pinHostClosureWith` / `pinHostObjectWith`（`HandleTable.cj:457-598`）每次都线性扫 `appendIds + pins`（`winPinSize`，`:262-273`）；测试注释已自陈该退化：`HandleTableGenExhaustion_test.cj:27-28`「否则 3.2 万次 pin 会让去重扫描退化成 O(n²)」，用例本身要靠「每轮开窗/收窗清空清单」绕开。窗口容量默认 128（`initialCapacity`），但 `capacityLimit` 可调到 2^20，窗口内 pin 数不受 128 限制。
- **方案**：为每个 `Win` 增加一个 `HashMap<UInt64, Int64>`（键 = `(tok<<48) ^ idx` 之类，或用 `canonKeyOf` 的 64 位哈希），`pin` 时 O(1) 命中；可变容器（List/Map/JsonValue）按 `refEq` 无法哈希，可维持线性扫描但只扫这部分清单（数量通常很小）。
- **预期**：窗口内 pin 从 O(k²) 降到 O(k)，k = 单次调用注册的宿主对象数。
- **代价**：每窗口多一个 map（小对象）；`Win` 池复用时要 `clear()`（现有 `freeWins` 已做 clear）；身份型去重的语义必须逐条保持（不可变值按规范键、容器按引用）。
- **验证**：`cjpm bench -O2` 构造「单次调用 pin 1k/10k 个不同对象」的场景，对照改前改后中位数；`cjprof` 确认 `pinWith` 自耗时占比下降。
- **证据状态**：无基线（待验证，不进 tasks）

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `popFreeWith` 最坏要依次探 64 个分片锁（每片一次 `synchronized`），空闲表偏空时分配路径的锁开销显著 | `HandleTable.cj:1179-1199` | 单次分配的自耗时占比、锁等待时长 | `cjprof record` 跑「多线程高 churn」场景（4 线程 × 20k 轮，已有用例可复用），看 `popFreeWith`/`Mutex.lock` 占比 |
| 2 | `hsLen`/`hsAt`/`strSub` 每次 `toRuneArray()` 全串物化，长串上长度/取字符变成 O(n) 且每次一个新数组 | `Helpers.cj:213-226、465-481` | 长串（≥ 64 KB）下的自耗时与分配量 | 分段计时：1 MB 串上 `hs_len` 1e5 次；`getAllocatedHeapSize()` 前后差 |
| 3 | `pinConst` 在 `mtx` 内线性扫 `1..totalSlots`，常量多的单元（数千常量）装载期退化为 O(n²) | `HandleTable.cj:611-630` | 常量个数 × 单次扫描耗时 | 造 5k 常量单元，计时 `pinConst` 总耗时；同时记录 `totalSlots` |
| 4 | `replaceSpans` 的 10 倍输入放大在真实负载（日志/模板替换）上先于 GC 触发 OOM | `Helpers.cj:959-1005` | 输入规模与 RSS 峰值 | 100 MB 串 + `a` 模式跑 `regex_replace_all`，采 RSS 峰值与耗时段 |
| 5 | 每个 helper 一次 `Array<Int64>` 分配是 GC 压力的主要来源之一 | `HelperEntry.cj:33-44` | 分配速率、GC 次数与停顿 | `cjprof heap` 跑 `PerfM2_test` 的 helper 密集循环，统计分配点排名 |
| 6 | `HelperId.isFixed` 的字符串拼接只在测试/编译期使用，未进运行期热路径（若进则每次一个 String 分配） | `HelperId.cj:222-226` | 生产调用次数 | 全仓确认无生产调用（本轮已确认仅 `Ops.cj:218` 注释与测试），若后续接入编译期校验则不成立 |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_jit/src/runtime/HandleTable.cj` | .cj | ✅ | 主体；见发现「cell 混叠」「releaseConst」「无锁读」「release 重复」「守卫重复」「replaceSpans」「死代码」「注释不符」「可见性」；优化方案 1/3 |
| 2 | `f_jit/src/runtime/HandleTableGenExhaustion_test.cj` | .cj | ✅ | 世代耗尽回归；`println` 噪声见发现「测试」；O(n²) 自陈用于优化方案 3 |
| 3 | `f_jit/src/runtime/HandleTableM2_test.cj` | .cj | ✅ | tag 10/11、`moveOutGroup`、`appendHostObject` 记账；与实现一致 |
| 4 | `f_jit/src/runtime/HandleTableStripeConcurrency_test.cj` | .cj | ✅ | 分片并发护栏；覆盖 pin/release/开窗收窗，未覆盖「读+释放」交错（见发现 #3） |
| 5 | `f_jit/src/runtime/HandleTable_test.cj` | .cj | ✅ | 窗口/逃逸/常量引用计数；与实现一致 |
| 6 | `f_jit/src/runtime/HelperAddresses.cj` | .cj | ✅ | 两个 `@C` 地址导出；被两个后端使用，无问题 |
| 7 | `f_jit/src/runtime/HelperCore.cj` | .cj | ✅ | `invokeHelper` 转码 + `argAt`/`allocValue`；死代码见发现「死代码：4 个符号」 |
| 8 | `f_jit/src/runtime/HelperEntry.cj` | .cj | ✅ | 72 个 `@C` 薄入口 + `h_dispatch`；注释不符见发现「注释与实现不符」 |
| 9 | `f_jit/src/runtime/HelperEntry_test.cj` | .cj | ✅ | ABI 对拍；`malloc` 返回值未判空（测试内，未单列） |
| 10 | `f_jit/src/runtime/HelperId.cj` | .cj | ✅ | hid 常量表；H84 漏登记见发现「H84 未登记」 |
| 11 | `f_jit/src/runtime/Helpers.cj` | .cj | ✅ | 81 个 hid 实现 + 分派（1–65 / 69–84，66–68 保留）；见发现「cell 混叠」「replaceSpans」，优化方案 2/3 |
| 12 | `f_jit/src/runtime/Helpers_test.cj` | .cj | ✅ | 逐族验收；用例名/覆盖见发现「测试」 |

合计：`.cj` 12 个 / `.md` 0 个 / 共 12 个，全部读完。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 6 | 正确性 2 条（cell 混叠、`releaseConst` 缺 gen）；并发正确性 1 条；可读性 2 条（注释不符、重复逻辑漂移风险）；语言特性 1 条（`refEq` 误述）。本部分无外部输入解析，安全性无命中（无注入面、无凭据） |
| §1 死代码 | 1 | 逐符号搜过：`currentWinOrNone` / `pushFree` / `popFree()` / `tokenOfValue` 全仓零引用（`tokenOfValue` 含 `.md` 搜索），`decTriple` 仅被死函数引用；`resetWindow` 的 `else` 分支不可达。另有 `private` 的 `sigEquals`/`parseDurationText`/`replaceSpans`/`castFail`/`newSlot`/`winPinSize`/`winPinIdAt`/`safeNanos` 均有调用者；`internal` 的 `argAt`/`allocValue`/`decFromTriple`/`helperEntry`/`dispatchHelper` 均有调用者；`public` 且对外可达（`makeId`/`idxOf`/`promote`/`isFixed`/`name`/`EscapeArea.*`）按硬原则一不判，仓内引用情况已记录（`promote`/`isFixed`/`name` 仓内仅测试引用） |
| §2 重复逻辑 | 2 | 逐对比较了本部分的函数体：`release`≡`releaseEscaped`（命中）；槽守卫表达式 13 处复制（命中）；`pinWith`/`pinHostClosureWith`/`pinHostObjectWith`/`appendHostObjectWith` 四段扫描循环骨架相同（并入守卫条目）；`fetchString`/`fetchList`/`fetchDecimal`/… 10 个 `fetchX` 是 `fetchAny` + 单 case 的同形包装（**判为有意展开**：返回类型不同、无行为差异，抽泛型会牺牲返回类型）；72 个 `@C` 入口是 ABI 表（**判为有意重复**，见发现 #9 的注释问题）；`dtArith`/`durArith` 已参数化，不算重复 |
| §3 空实现 | 0 | 逐个函数体检查：无 `{}`、无 `TODO`、无 `catch {}`（两处 `catch (_: Exception)` 均在 `failWith` 后中止，不是吞异常）；`HelperCore.ctxWriteCode(ctx, code, e)` 与 `ctxWritePanic(ctx, e)` 不使用 `e` 属**有意签名**（写码通道单一，cause 走 `HostFault`），非空实现；`fnTable` 返回 0 是解释器形态的规范语义（`Helpers.cj:1038-1046` 已注明） |
| §4 栈溢出 | 0 | 本部分 40 余个函数无自递归、无间接递归；`decTriple`/`parseDurationText`/`replaceSpans`/`liveCount` 均为显式循环；`pinWith` 等的去重循环有上界（窗口清单长度） |
| §5 OOM | 1 | `replaceSpans` 全量物化（命中，一般）；`strRepeat` 的 `n × len` 有溢出检查但无内存上限（属源语言 `s * n` 语义，不另报）；`segDir`/`SlotSeg` 定长受 `capacityLimit` 约束，非无界增长；`Win` 池上限 8，有界 |
| §6.1 热点瓶颈 | 0 | 无 `cjprof`/`cjpm bench` 数据，热点结论不成立；6 条候选全部进「待验证假设」 |
| §6.2 大粒度锁 | 0 | 三个临界区逐个看过：`mtx` 内的 `pinConst` 全表扫描（O(n)，冷路径）、`liveCount` 全表计数（审计）、`releaseConst` 的 mtx→分片锁嵌套；分片锁内只有数组读写，无 I/O、无日志、无回调、无 `spawn().get()`。`pinConst` 的扫描长度可疑但缺数据，进待验证假设 #3 |
| §6.3 并发串行 | 0 | 本部分无 `spawn`、无 `Future.get`、无共享单 writer |
| §6.4 低效算法 | 1 | 窗口 pin 去重 O(k²)（命中，进优化方案）；`pinConst` O(totalSlots)、`popFreeWith` 64 分片探测缺数据（待验证假设 #1/#3） |
| §7 降堆内存方案 | 2 | `constRefs` 常驻 8 B/槽、每 helper 一次 `Array<Int64>`（均无基线） |
| §8 降 CPU 方案 | 3 | 同三条优化方案（去分配、去 O(k²)、去全表扫描） |
| §9 local mode 可行性 | 0 | 唯一候选是 `helperEntry` 的 `Array<Int64>`（函数内创建、不返回、不存全局），但：① 它是 std `Array`，需 `@local` 构造与 mode 重载支持，官方不保证；② 收益只能靠峰值内存对照证明，当前无改前基线；③ 同包与 `invokeHelper` 必须同 SDK 编译。结论：**待验证假设**（并入 #5），不写优化建议 |
| §11 现有代码的 BUG（存量） | 3 | cell 混叠、`releaseConst` 缺 gen、无锁读与释放不原子（均标 `[存量]`）；另核对了 `hl_get`/`hs_at`/`str_sub`/`insert`/`set`/`remove` 的 6 处下标边界（`< 0`、`>= size`、`x > y`）与 `dt_of` 的 3–7 参数边界，均正确 |
| §12 并发安全与锁粒度 | 2 | 共享点已列全：`static mtx`、64 个分片 `mtx`+`lists`、`segDir`（定长只换元素）、`totalSlots`/`capacityLimit`/`initialCapacity`/`retiredSlots`（`AtomicInt64`）、线程私有 `RuntimeState.wins/freeWins/freeHint`。锁序固定 `mtx → 分片锁`（`releaseConst:651-654` 有注释，本文件无反向取锁）⇒ 无死锁；命中 2 条（读/写不原子、`isFrozen` 可见性），锁粒度本身合理（分片 + 冷路径才用全局锁） |
| §14 功能完备性与 README 覆盖 | 1 | 本部分无 `.md`；`HelperId` 的 81 个常量与 `dispatchHelper` 的 case 逐值对照：**分派无遗漏、无多余**；但 `name`/`isFixed` 漏 H84（命中，见发现「H84 未登记」）；72 个 `@C` 入口只覆盖到 72，73–84 只能经 `h_dispatch` —— 与两个后端的实际调用方式一致，非缺失 |
| 文件覆盖（§13 等） | 12/12 | `f_jit.part35.txt` 的 12 行全部读完，无跳过 |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 0 |
| 一般 | 7 |
| 轻微 | 4 |
| 优化方案（堆内存 / CPU） | 2 / 1 |

（其中「每 helper 一次 `Array<Int64>`」同时属堆内存与 CPU 两类，统计时只计入堆内存，故 §7 记 2 条、§8 记 3 条。）

存量缺陷 11 条（严重 0 / 一般 7 / 轻微 4），是否纳入修复待用户决定。

## 总评

本部分覆盖句柄表（分块存储 + 分片空闲表 + 窗口记账 + 逃逸/常量）与 helper 分派表（81 个 hid、统一 `h_dispatch` 入口、cell↔宿主值转换），是 f_jit 运行时最核心、也是并发面最宽的一段。

整体质量偏上：锁序显式固定并写了注释（`mtx → 分片锁`），热路径读不加锁有明确论证，段地址稳定不搬迁、世代号退休、容量倍增与 `capacityLimit` 兜底都做了边界推导，测试里有专门的并发护栏与世代耗尽回归（这两个用例的质量高于仓库平均），81 个 hid 的分派逐值对齐、无空洞（名字表漏 H84，见发现）。

主要风险集中在三处，都不阻塞但需要排期：

1. **cell 值域混叠**（发现 #1）——`Int64 ≥ 2^48` 与 `Float64` 位型都可能落进活句柄 ID 的值域，而 `cellToAny` 靠 `isLiveHandle` 猜。注释里「天然不交」的断言是错的，会让后来者继续按错误前提加代码。这一条是唯一可能产生**静默取值错误**的缺陷，建议优先处理（改注释 + 在 §3.2 登记限制至少是必须的）。
2. **释放与读的原子性**（发现 #3）与 **`releaseConst` 缺世代校验**（发现 #2）——都属于「生命周期边界上少一道校验」，当前调用方恰好挡住了，一旦下游出现跨线程释放就会以 `Some(0)` 或 `ERR_NULL_HANDLE` 的形式冒出来。
3. **实现层面的可维护性债务**（发现 #4/#5/#7/#9/#10）——两个同义释放函数、13 处复制的槽守卫、4 个零引用符号 + 1 处不可达分支、2 处过期注释、1 条名不副实的用例。这些不产生行为缺陷，但每加一条句柄路径就要多改 n 处，是后续缺陷的温床；清理成本很低（都是 `private`/`internal`，无下游影响）。

性能方面本部分**没有可用基线**，因此 `popFreeWith` 的 64 分片探测、`pinConst` 的全表扫描、`toRuneArray` 的全串物化、每 helper 一次的 `Array<Int64>` 分配都只作为待验证假设，不作为缺陷；`replaceSpans` 的 10 倍输入放大是静态可算的，已按 OOM 风险报为一般。

本部分未覆盖：`LocalType`/typecode 分支表、`CallMarshal` 的 Marshal/逃逸收尾、`Interp` 的 helper 调用点 —— 这些分别在 f_jit 的其他部分，本报告的「桥接正确性」结论只到 helper 分派与 cell↔值转换为止。
