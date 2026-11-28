# f_jit 模块审查报告

> **模块第 21/38 部分**（本报告只覆盖 `files/f_jit.part21.txt` 列出的 20 个文件：`CallForFnConcurrency_test` → `Compiler`，全部为 `.cj`，本部分不含任何 `.md`。其余文件由第 1–20、22–38 部分产出，合并以主 Agent 为准。）

- **审查日期**：2026-11-28
- **模块路径**：`f_jit`（本部分 20 个源文件，3310 行）
- **基线**：工作区快照（master 与 sts/1.3.x 同一提交 `120fd2542`，`git diff` 为空 ⇒ 全部问题记「存量」）
- **审查重点**：动态调用/桥接正确性（typecode 分支表）、句柄与资源生命周期、并发安全、递归与栈溢出、死代码、重复逻辑；本部分对应「编译缓存 / 编译管线 / 编译器门面 / 参数封送（CallMarshal） / 类注册表」五块
- **报告版本**：v1（第 21/38 部分）

## 发现

### [一般][存量] #1 进程级编译缓存 `ready` 无容量上限、无淘汰，长跑进程按源码指纹单调增长

- **位置**：`f_jit/src/CompileCache.cj:31-35`（三张 static 表）、`:80-87`（`finish` 只写不淘汰）、唯一逐出点 `f_jit/src/JitFunction.cj:259-266`（`close` 内 `CompileCache.remove(k)`）；条目持有体见 `f_jit/src/CompilePipeline.cj:246-255`
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §5「缓存键无界」「长期持有」、§12.1「有界性」
- **证据**：静态确定（`ready: HashMap<String, JitFunction>` 没有任何容量字段、LRU/TTL 或拒绝路径；只有 `remove(key)` / `reset()` 会减小它，二者都不在编译主路径上）＋ 需实测（单条占用与增长速率）
- **描述**：键 = 源码指纹，每条目是一个 `JitFunction`，其 `body` / `replay` 闭包（`CompilePipeline.cj:246-255`）捕获整个 `LoadedUnit`，即字节码、函数目录、类型表、常量表全部随条目常驻，JIT 路径还额外持有机器码。仓内已有两个**不 close** 的真实调用路径：
  - `f_egraph/src/FlowScriptRunner.cj:37`：每次执行 flow script 都 `compiler.compile(source)`，不同脚本文本各占一条，永不逐出；
  - `f_rule/src/rule/ScriptAction.cj:50`：每条规则脚本编译一次并长期持有 `compiled_`，动作销毁时不 `close`。
  即"服务持续喂新脚本 ⇒ 缓存持续增长"。同一份代码里 `failures` 已经有 `FAILURES_MAX = 256` 的上界（`CompileCache.cj:95-106`），`ready` 没有，两者口径不一致。按 1 KB 脚本、每条目 10–50 KB（字节码 + 类型表 + 机器码）粗估，1 万份不同脚本常驻约 100–500 MB，属可触达的 OOM 面（阈值需实测）。
- **建议**：给 `ready` 加容量上限 + 按最近命中淘汰（或 TTL）；淘汰时对 `JitFunction` 走 `close` 以释放机器码与常量槽。若"编译产物必须常驻"是硬需求，则改为可配置上限并在超限时抛明确错误（拒绝路径），不要让增长到 OOM 才暴露。

### [一般][存量] #2 缓存命中缺「原字节二次校验」，与设计文档的碰撞防护契约不符

- **位置**：`f_jit/src/CompilePipeline.cj:61-64`（源码路径）、`:97-100`（字节码路径）；条目结构 `f_jit/src/CompileCache.cj:32`、`:80-87`
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §11「契约与实现不符」「与规格冲突」；规格 `f_jit/doc/design-m1.md:417`：「**碰撞 = 语义错误**（去重键撞车 ⇒ 返回**别的** `JitFunction`）⇒ 缓存条目**保存原始输入字节**，命中后做**长度 + 字节二次校验**（不符按 Miss 重编）」
- **证据**：静态确定 —— `ready` 的 value 只有 `JitFunction`，没有任何原始字节字段；`runSource` / `runUnit` 在 `lookup(key)` 命中后直接 `return f`，没有长度比较、没有逐字节/二次指纹比较
- **描述**：文档明确把"指纹碰撞"当作必须由实现兜底的语义错误（且 `design-m1.md:1029` 再次强调"不靠概率兜底"），实现里这条防线完全不存在：一旦 FNV-1a-128 撞车，返回的是**另一份源码**编译出来的单元，调用方拿到的函数体、参数表、helper 绑定全部错位，且无任何诊断。概率极低，但这是文档承诺的确定性保障，不是"可能更好"。
- **建议**：条目改成 `(raw: Array<UInt8>, fn: JitFunction)`（或保存 (长度, 二次指纹如 CRC32)），命中时先比长度再比字节/二次指纹，不符则按 Miss 重编并覆盖条目。补一条用例：手工把两条目指向同一 key（或注入 fake fingerprint），断言第二次调用不返回第一条的产物。

### [一般][存量] #3 `claim` 之后只有 `catch (e: Exception)` 释放 `compiling` 标记；`Error` 逃逸会让该键永久停在「编译中」

- **位置**：`f_jit/src/CompilePipeline.cj:65-85`、`:101-113`
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §11「错误处理缺失」、§12.1「异步语义 / 状态残留」；异常层级依据 std 文档 `std/core/core_package_api/core_package_exceptions.md`：`class Error <: ToString`（独立根）与 `class StackOverflowError <: Error`，`catch (e: Exception)` 捕获不到它们
- **证据**：静态确定（控制流：`claim` 成功 → `try` → `catch (Exception)` 里 `fail()` → 其余出口只有 `finish()`；没有 `finally` 兜底）＋ 待确认（`SourceCompiler` 在深嵌套源码上是否真会抛 `StackOverflowError`）
- **描述**：`CompileCache.fail()` 是唯一把 key 从 `compiling` 摘掉的失败路径，而它只在 `Exception` 分支里被调用。若编译过程抛出 `Error` 体系（深嵌套源码的解析/降低递归 → `StackOverflowError`，或 `OutOfMemoryError`），异常越过 `catch`，`compiling` 永久保留该 key，且 `failures` 里没有记录。此后：
  - 任何同源 `compile` 的 `claim` 恒 false，只能 `awaitReady`，等满 `awaitTimeoutNs`（默认 30 s）后抛 `CompileTimeout`；
  - `missingResult` 的判定（`CompilePipeline.cj:129-141`）看到 `isCompiling == true`，会把"编译崩溃"报成"编译等待超时"，误导定位。
  这条状态不会自愈：`CompileCache.remove` 只由持有该 `JitFunction` 的一方在 `close` 时触发（`JitFunction.cj:259-266`），而此路径上根本没有产物可供 `close`；`reset()` 只有测试调用。于是同源编译此后每次都走 `awaitReady` 等满超时。
- **建议**：`try { ... } catch (e: Exception) { fail; throw } finally { if (CompileCache.isCompiling(key)) { CompileCache.fail(key, '编译异常中止') } }`；或补 `catch (e: Error)` 分支调新增的 `CompileCache.abandon(key)`（只清 `compiling`，不写失败文本）。两处（`runSource` / `runUnit`）同改。

### [一般][存量] #4 `CompileOptions` 的 `jit` / `strictFp` 在管线里被读两次，配置并发变更会让「缓存键」与「产物」错配

- **位置**：`f_jit/src/CompilePipeline.cj:59-60`（键里用 `c.opts.jit`、`c.opts.strictFp`）与 `:73`（`strictFp: c.opts.strictFp`）、`:236`（`opts.jit`）；字段声明 `f_jit/src/CompileOptions.cj:28`、`:45`（均为 `public var`）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §12.1「共享可变状态无保护」「检查-然后-写入」
- **证据**：静态确定（同一可变字段在一次 `runSource` 内被两次独立读取，中间没有快照、没有同步；`Compiler.opts` 是 `public let`，但指向的对象字段可变，`Compiler` 本身被设计为可多线程共享——`registerFunction` / `snapshot` 都为此加锁）
- **描述**：`major` 已经先在局部变量里拍平（`:53`，正确做法），但 `jit` 与 `strictFp` 没有：
  - `jit`：键用 `:59` 的读值，执行器创建用 `:236` 的读值。并发改成 `Off` 时，可能出现"键写着 `off`、产物其实是 JIT"或反之，之后同配置编译直接命中错类型产物；
  - `strictFp`：键用 `:60`（`bit(c.opts.strictFp)`），构建用 `:73`。错配后果是**静默语义漂移**——`strictFp=false` 的产物（÷0 得 `Inf`）被存进 `fp1` 键，之后声明严格浮点的调用拿到不报错的除法。
  触发条件是"运行期改配置"；`CompileOptions` 是公开可变配置且无任何文档声明线程安全，属契约缺口。
- **建议**：`runSource` / `runUnit` 入口把选项拍成本地快照（`let jit = c.opts.jit`、`let strict = c.opts.strictFp`），键与产物都只用快照；或在 `CompileOptions` 注释里明确"构造后不可变，改配置须新建 `Compiler`"并把字段收成 `let`。

### [一般][存量] #5 `CallMarshal.promoteClosureGraph` 递归无深度上限，闭包捕获链深度由源码决定

- **位置**：`f_jit/src/CallMarshal.cj:284-309`（自递归在 `:303`，`visited` 只做环检测在 `:290-293`）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §4「无界递归（深度由输入决定）」「每帧大对象」；`visited` 防环不防深
- **证据**：静态确定（无深度计数、无上限、无迭代化；每帧再压一个 `ArrayList<Int64>` 线性 `contains` + 递归调用）＋ 待确认（前端允许的闭包嵌套层数是否有上限）
- **描述**：`retType=12` 返回闭包时按捕获图做 DFS：闭包槽 → 每层捕获里的内部闭包再递归。深度 = 闭包链长度，完全由被编译源码决定（代码生成器/模板渲染产物常见"每层包一个闭包"的写法），没有任何上界。深度大时先撞栈（`StackOverflowError`，且它不属于 `Exception`，见 #3 ⇒ 连失败缓存都不会写），同时 `visited.contains` 是线性扫描，整体退化为 O(n²)。
- **建议**：改成显式栈（worklist + 迭代），`visited` 换 `HashSet<Int64>`；若必须保留递归，加深度上限（例如 1024 层）并在超限时抛 `JitException(19)`，把"图太深"变成可诊断错误而不是崩溃。

### [轻微][存量] #6 `CallMarshal.makeArgMarshalers` 全仓零引用（死代码），且设计文档仍称它是调用第二步

- **位置**：`f_jit/src/CallMarshal.cj:158-167`
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §1「非 public 顶层声明里的 public 成员，全项目无使用即死代码」（`CallMarshal` 是顶层 `protected class`，其 `public` 成员对外不可达）
- **证据**：静态确定 —— 全仓 `grep makeArgMarshalers`（排除 `.worktrees` / `target`）只命中定义处；生产 `call` 路径直接调 `marshalArg` / `marshalHostClosure`（`f_jit/src/JitFunction.cj:633-637`、`:650`），测试也没有用它
- **描述**：该方法每次调用都新建一个 `ArrayList` 与 N 个捕获 `this`+`tt` 的闭包，属"按签名生成封送器"的旧设计残留；`f_jit/doc/design-m1.md:904` 仍写着「`makeArgMarshalers(sig)` … call 六步第 2 步」，与实现不符（漂移的文档在另一部分，此处只作判据）。`makeRetUnboxer`（`:187-190`）是它的孪生兄弟，但已被注释标注"保留给测试"且有测试使用，不算死代码。
- **建议**：删除该方法，或若确要保留"预生成封送器"的能力，把它接到 `JitFunction` 构造期（按 `paramTypes` 建一次），并在设计文档里同步删掉"六步第 2 步"的表述。

### [轻微][存量] #7 `classFieldOf` / `classMethodOf` / `classCtorsOf` 全仓零引用（死代码），且与 `ClassRegistryView` 同名查询逐行同形

- **位置**：`f_jit/src/ClassRegistry.cj:197-208`、`:211-222`、`:225-230`
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §1（顶层 `protected` 函数，本模块内无引用即死代码）、§2「只改类型名 / 换入口的重复实现」
- **证据**：静态确定 —— 全仓 grep 三个名字只命中定义行；`f_jit/src/compiler/ClassRegistryView.cj:105-116`（`fieldOf`）、`:118-127`（`methodOf`）、`:146-151`（`ctorsOf`）是同一段"遍历 `fields`/`methods`/`ctors` 按名匹配"的实现，差异仅入口（`?ClassDescriptor` vs `className` + `classOf`）
- **描述**：注释写"供 `ClassRegistryView` 同口径查询的宿主侧辅助（桥边界校验用）/ 宿主侧方法解析"，但桥层与编译期都直接用 `ClassRegistryView`，这三份宿主侧副本没有任何调用者。删除后 `ClassRegistry.cj:22-24` 的 `PublicCtor` / `PublicField` / `PublicMethod` 三个 import 也会随之失效，属"兼容残留"。
- **建议**：删除三个函数与相应 import；若桥层将来真需要"按 descriptor 查成员"，把 `ClassRegistryView` 的 `fieldOf/methodOf/ctorsOf` 下沉成接受 `?ClassDescriptor` 的共享辅助，让两边共用一份。

### [轻微][存量] #8 `CompilePipeline.userHelpers` 在实现缺失时静默替换为「恒返回 0」的空实现

- **位置**：`f_jit/src/CompilePipeline.cj:316-319`（`case None => { _ => 0 }`）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §3「静默空实现 / 兜底把错误吃掉」
- **证据**：静态确定 —— `PredefinedSnapshot.implOf` 在 `impls` 数组短于 `names` 时返回 `None`（`f_jit/src/compiler/PredefinedSnapshot.cj:93-98`），而 `PredefinedSnapshot.init` 的 `impls!` 有默认空数组（`:48-52`），即"有名字、无实现"的快照是合法可构造的；这类快照编译出的单元里，该 slot 的 helper 对任何入参都返回 `0`
- **描述**：生产构造点（`Compiler.snapshot`，`f_jit/src/Compiler.cj:196-216`）总是成对填 `impls`，所以当前只在测试构造的快照上可达；但一旦将来有"只登记名字（做类型检查/占位）"的用法，错误会表现为"函数被调用但恒返回 0"，没有异常、没有诊断，比直接失败更难查。
- **建议**：改为 fail fast —— 缺实现时抛 `SourceCompileException('NotImpl', …)` 或在 `diagnostics` 上记一条错误；确实需要占位语义时，把占位实现写进注释并配 `diag` 告警。

### [轻微][存量] #9 `CompileCache.awaitReady` 的「完成判定」与「取结果」分两次取锁，中间条目被移除会给等待者假失败

- **位置**：`f_jit/src/CompileCache.cj:131-139`
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §12.1「检查-然后-写入」的读侧变体（TOCTOU）
- **证据**：静态确定（`synchronized` 块 1 返回 `!compiling.contains(key)`，块 2 才 `ready.get(key)`；两块之间锁已释放）
- **描述**：`finish` 之后、等待者第二次取锁之前若有另一线程 `remove(key)`（例如持有该 `JitFunction` 的一方 `close`），`ready.get` 返回 `None`，调用方按「未就绪」处理：`isCompiling` 已为 false ⇒ 抛 `CompileFailed + fallback`，把"结果被逐出"报成"编译失败"。属误报级缺陷，不产生数据错误。
- **建议**：把判定与取值放进同一个临界区（返回 `(done, ready.get(key))`），或干脆在一次 `synchronized` 里返回 `?JitFunction` 并用"是否仍在 compiling"区分超时。

### [轻微][存量] #10 `Compiler.registerClass` 绕过 `maxPredefined` 上限，与 `registerFunction` 的契约不一致

- **位置**：`f_jit/src/Compiler.cj:113-131`（方法并入在 `:119-126`），对照 `:74-77`（`registerFunction` 的上限检查）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §11「与规格 / 实现自身契约冲突」；上限口径见 `f_jit/src/Compiler.cj:67`「超过上限 → `NotImpl`」与 `:75-76` 的错误文案「预定义函数数量超过上限 … （§8.4）」
- **证据**：静态确定 —— `registerClass` 把 `desc.methods[i].bind` 直接 `this.fns.add(...)`，只判重名，不读 `this.maxPredefined`
- **描述**：注册一个带 N 个方法的类可把 `fns` 撑到 `maxPredefined` 之上，`registerFunction` 随后会开始抛 `NotImpl`（明明还有空间），而 helper slot 表（hid = 0x0100 + slot）的实际规模已经超出声明上限。属"上限只在一条路径生效"。
- **建议**：抽出 `private func addFunctionLocked(f: PredefinedFunction): Unit`（判重 + 判上限 + `noteFunction` + 置空 `snapCache`），`registerFunction` 与 `registerClass` 都走它。

### [轻微][存量] #11 `CompileCache.awaitReady` 末尾 `return None` 在 `while (true)` 之后不可达

- **位置**：`f_jit/src/CompileCache.cj:128-150`（`return None` 在 `:149`）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §1「不可达语句（`while(true)` 之后）」
- **证据**：静态确定（`while (true)` 内所有出口都是 `return`，循环不会正常结束）＋ 待确认（仓颉编译器是否要求此处保留显式返回以满足"必有返回值"检查）
- **描述**：纯冗余语句；如果编译器确实要求，应加一行注释说明"为满足返回值检查保留"，否则易被后来者误认为存在第三种出口。
- **建议**：删除或加注释；若删除后编译报错则保留并注明原因。

### [轻微][存量] #12 三处同语义重复实现（`moveTo`/`removeFrom`、`containsName`/`indexOfLocked`、`runSource`/`runUnit`）

- **位置**：
  - `f_jit/src/CallMarshal.cj:338-351`（`removeFrom`）与 `:353-368`（`moveTo`）——`moveTo` 完整复刻了前者的"线性查找 + `remove(at: i)` + `return`"循环，差别只是多一次 `to.add(id)`；
  - `f_jit/src/Compiler.cj:222-231`（`containsName`）与 `:233-242`（`indexOfLocked`）——同一个"按名线性查找"，前者是后者的布尔投影，只是容器参数不同；
  - `f_jit/src/CompilePipeline.cj:52-92` 与 `:95-120`——同一套 `lookup → claim → try{构建; finish}catch{fail; throw} → awaitReady → missingResult` 骨架的两份拷贝，差异只有构建步骤与 fallback 文案（`'编译失败'` / `'装载失败'`）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §2「换控制流 / 只改参数 / 跨文件复制」
- **证据**：静态确定（逐行比对函数体：输入-输出-副作用同构）
- **描述**：重复本身尚未造成行为漂移，但已在 #2 上体现风险——"命中后二次校验"这条缺失在两份拷贝里**同时**缺失，任何一处修好都必须记得改另一处。`moveTo`/`removeFrom` 的另一处差异点需要显式说明：`moveTo` 在找不到时也会 `to.add(id)`（`:367`），`removeFrom` 无此语义，合并时不要把两者当成完全等价。
- **建议**：`CompilePipeline` 抽 `private static func cached(key: String, fallback: String, build: () -> JitFunction): JitFunction`（构建步骤作参数，版本校验与 helper 拒绝留在调用方）；`CallMarshal` 抽 `private static func takeFrom(list: ?ArrayList<Int64>, id: Int64): Bool`（找到并删除返回 true），`moveTo` 用它再 `to.add`；`Compiler` 的 `containsName` 改为 `HashSet<String>` 成员或直接复用 `indexOfLocked` 风格的通用查找。

### [轻微][存量] #13 `escapedIds` / `makeRetUnboxer` 仅测试使用，且 `escapedIds` 的注释与真实接线不符

- **位置**：`f_jit/src/CallMarshal.cj:330-336`（`escapedIds`，注释「供桥的逃逸区接管」）、`:187-190`（`makeRetUnboxer`，注释已写「保留给测试」）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §1「仅测试使用 → 可见性建议，不是死代码」；§11「语义与注释不符」
- **证据**：静态确定 —— `escapedIds` 生产路径零引用（`f_jit/src/JitFunction.cj:650-684` 用 `unboxRet` + `releaseReturnHandle` 归还返回槽），只被 `f_jit/src/CallMarshal_test.cj:88` 调用；`makeRetUnboxer` 只被 4 个测试文件调用
- **描述**：注释说"供桥的逃逸区接管"，实际桥/`JitFunction` 从没调用过它——读者会以为逃逸句柄由 `escapedIds` 交接，而真实交接点是 `JitFunction.releaseReturnHandle`。二者都在 `protected class` 里，对外不可见，属"包内放宽 + 仅测试"。
- **建议**：把 `escapedIds` 注释改成"测试用：查看本次调用已逃逸的槽（生产路径不发逃逸区）"，或直接删掉并把 `CallMarshal_test.cj:88` 改成断言 `escaped.size`；`makeRetUnboxer` 保留但在注释里统一写"测试辅助"。

## 优化可行性方案

> 不是缺陷，是「还能更好」。本部分没有提供 `cjprof` / `cjpm bench` 基线（`CallPathBench_test.cj` 只打印 `CP-BENCH`，数据需人工抄录到 `doc/optimize-call-path.md`），因此下面每条都标 `无基线（待验证）`，不进 `tasks.md`。

### [CPU] 封送/解包的类型码分派改成表驱动或 `match` 跳转表

- **现状**：`f_jit/src/CallMarshal.cj:80-155`（`marshalArg`）与 `:198-230`（`unboxRet`）都是按 `LocalType` 码顺序 `if` 链。一次句柄型实参在命中 `isHandleType`（`:376-379`）前要过 `HOST_CLOSURE / I64 / F64 / UNIT / BOOL / ANY / JSON 区间(2 次) / HOST_OBJECT` 共 9–11 次比较；每次 `call<T>` 对每个实参 + 每个返回值各走一遍
- **方案**：`match (t) { case 0u16 => … }` 让编译器生成跳转表；或按签名在 `JitFunction` 构造期预生成 `Array<(Any) -> Int64>`（正是 `makeArgMarshalers` 的初衷，见 #6 —— 若要复活它请接到构造期而不是每次调用）
- **预期**：单次封送少 ~10 次分支/间接；对短调用（B1 场景）相对收益最大
- **代价**：多一张表/一段初始化；码集变更要同步维护 20 行
- **验证**：`cjpm bench -O2` 跑 `f_jit/src/CallPathBench_test.cj` 的 B1（150k 次）与 B3，比较 Q1/L1 中位数与离散度（该文件本身已做 3 轮中位数）
- **证据状态**：`无基线（待验证）`

### [CPU] `awaitReady` 的墙钟忙等改为有界睡眠退避

- **现状**：`f_jit/src/CompileCache.cj:143-147`：`while ((MonoTime.now() - t).toNanoseconds() < backoffNs) {}` 纯自旋，退避 1 µs → 500 µs 封顶，最长持续到 30 s 超时。N 个同键等待者 = N 个核 100% 自旋，同时还反复读墙钟
- **方案**：把自旋换成 `sleep(Duration.microsecond * k)`（`std.core` 的 `func sleep(dur: Duration)`，见 `std/core/core_package_api/core_package_funcs.md:1670`）；`std.sync` 现状没有 `Condition`（只有已废弃的 `Monitor`），所以"睡眠退避 + 每次唤醒重查"是最小改动方案；若愿意改结构，可由 `finish/fail` 直接唤醒等待者（`Barrier` / 一次性 `Future` 交接）
- **预期**：等待期 CPU 占用从"每等待者一核"降到接近 0，把核让给真正在编译的线程
- **代价**：唤醒粒度变粗（百 µs–ms 级），冷启动/首编延迟可能略升；需要重新验证"退避避免抢全局锁"这一原始收益（注释里记录的 187 µs/次 vs 个位数 µs）
- **验证**：8 个线程同键 `compile`，`cjprof` 采样等待线程的 CPU 时间 + 端到端耗时中位数对照
- **证据状态**：`无基线（待验证）`

### [堆内存] 编译缓存有界化（容量 + 按最近命中淘汰）

- **现状**：`f_jit/src/CompileCache.cj:32` 的 `ready` 只增不减（同 #1）；每条目持有 `LoadedUnit` 全量 + 机器码，且因 `body`/`replay` 闭包（`CompilePipeline.cj:246-255`）即使 JIT 成功也保留字节码（DEOPT 重放需要，属有意设计）
- **方案**：给 `ready` 加 `capacity`（可配置，默认例如 512）+ LRU 淘汰；淘汰时调 `JitFunction.close(0)` 释放机器码与常量槽；同时对 `failures` 保持现有 256 上限
- **预期**：长跑稳态 RSS 有界（与源码多样性解耦）；命中率按"热脚本集 ≤ 容量"假设不降
- **代价**：命中率下降 ⇒ 冷门脚本重编（编译是 ms 级）；`close` 需保证不打断正在执行的单元（`JitFunction.close` 已有 active 计数与超时回退）
- **验证**：循环编译 1 万份不同源码后再反复命中前 100 份，采样 `getAllocatedHeapSize()` / RSS 是否收敛
- **证据状态**：`无基线（待验证）`

### [CPU] `Compiler.snapshot` 的去重与拷贝改增量/哈希

- **现状**：`f_jit/src/Compiler.cj:190-220`：注册变更后首次编译要把 `fns` + `autoFunctions()` 全量拷贝成 4 个数组，并用 `containsName`（`:222-231`，线性）对每个自动函数去重 ⇒ O(A·F)。代码注释自述「F=200 时实测占单编译 11.6%，4 线程累计 41.5%」（`:39-42`），但未附采样方法与原始数据
- **方案**：`containsName` 换 `HashSet<String>`；自动函数在 `addAutoFunction` 侧就与 `fns` 合并（增量化），`snapshot()` 只做数组转换
- **预期**：按注释口径可去掉单编译 ~11% 的拷贝开销；4 线程下收益更大（同一把 `mtx` 内的串行段缩短）
- **代价**：多一个 `HashSet` 的常驻内存（名字数量级 ≤ 数百）；需保证注册/注销时集合同步
- **验证**：`cjprof` 复核 `snapshot` 自耗时占比（F=200 / 1000 两组），4 线程并发编译同一 `Compiler`
- **证据状态**：`无基线（注释数据未复核，需重测）`

## 待验证假设

> 没有性能测试数据支撑的猜测，**不进 `todo.md` / `tasks.md`**。

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 封送/解包的类型码 `if` 链是短调用路径的主要自耗时之一 | `f_jit/src/CallMarshal.cj:80-155`、`:198-230` | 该函数 self time 占比、每参平均比较次数 | `cjprof record` 跑 `CallPathBench_test` B1（150k 次、4 线程 3 轮），看 `marshalArg`/`unboxRet` 占比 |
| 2 | `awaitReady` 自旋在多等待者场景下吃掉整核，且放大同键编译的总墙钟 | `f_jit/src/CompileCache.cj:143-147` | 等待线程 CPU%、唤醒延迟分布 | 8 线程同键 `compile`，`cjprof` + 线程状态（RUNNABLE 占比） |
| 3 | `ready` 缓存随源码多样性线性增长，单条约 10–50 KB | `f_jit/src/CompileCache.cj:32`、`f_jit/src/CompilePipeline.cj:246-255` | 1k/5k/10k 份不同源码后的 heapUsed 增量、单条实测占用 | 循环 `compile` 不同源码，采样 `getAllocatedHeapSize()` / RSS（需 WSL 侧跑） |
| 4 | `promoteClosureGraph` 的 `visited.contains` 使深闭包链退化为 O(n²) | `f_jit/src/CallMarshal.cj:288-309` | 链长 1k/5k/10k 时的耗时曲线 | 构造嵌套闭包源码，`call` 返回闭包并计时（`cjpm bench -O2`） |
| 5 | `Compiler.snapshot` 的 O(A·F) 去重与全量拷贝在 F 大时占比显著（注释称 11.6% / 41.5%） | `f_jit/src/Compiler.cj:39-42`、`:196-219` | 复核占比与 4 线程放大倍数 | `cjprof`，F=200 与 F=1000 两组，单线程与 4 线程各 3 轮取中位数 |

**范围外提示**：`f_jit/src/JitFunction.cj:240-256` 的 `close` 也用「`spins` 上限 + 纯自旋」等 drain，与 `awaitReady` 同族；它不在本部分文件清单内，仅提示合并时可能需统一改。

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_jit/src/CallForFnConcurrency_test.cj` | .cj | ✅ | 并发用例；`@Test` 类，无缺陷 |
| 2 | `f_jit/src/CallMarshal.cj` | .cj | ✅ | 见 #5、#6、#12、#13、优化 O1 |
| 3 | `f_jit/src/CallMarshalAny_test.cj` | .cj | ✅ | Any 行用例；与实现一致 |
| 4 | `f_jit/src/CallMarshalM2_test.cj` | .cj | ✅ | 14/13 行用例；文件内 `ExcSite` 仅本文件使用 |
| 5 | `f_jit/src/CallMarshal_test.cj` | .cj | ✅ | 封送/解包/提升组用例；`escapedIds` 仅此处使用（#13） |
| 6 | `f_jit/src/CallPathBench_test.cj` | .cj | ✅ | 非门槛基准，只打印 `CP-BENCH`；作为优化验证手段引用 |
| 7 | `f_jit/src/CastOr_test.cj` | .cj | ✅ | `as`/`??` 语义用例；负例助手 `expectCompileFailure` 每次 reset 缓存，与缓存键口径一致 |
| 8 | `f_jit/src/ClassRegistry.cj` | .cj | ✅ | 见 #7；类名四类冲突与快照语义实现完整 |
| 9 | `f_jit/src/ClassRegistry_test.cj` | .cj | ✅ | 含 8 线程并发注册用例；覆盖 `DuplicateClass` / `FunctionNameClash` / 快照隔离 |
| 10 | `f_jit/src/CompileAwaitTimeout_test.cj` | .cj | ✅ | 超时与三态判定用例；时序断言取下界，无假失败风险 |
| 11 | `f_jit/src/CompileCache.cj` | .cj | ✅ | 见 #1、#2、#9、#11、优化 O2/O3 |
| 12 | `f_jit/src/CompileCache_test.cj` | .cj | ✅ | `:98` 的 `let unused = f` 是无用局部（仅为延长引用），属测试噪声，未单列 |
| 13 | `f_jit/src/CompileConcurrency_test.cj` | .cj | ✅ | 4 线程编译不同源码；锁住旧 `auditMemBases` 竞态 |
| 14 | `f_jit/src/CompileFailureCache_test.cj` | .cj | ✅ | 注册失效 + 失败缓存上限；`:43-51` 的 `firstOk` 初值/catch 赋值冗余，测试噪声 |
| 15 | `f_jit/src/CompileOptions.cj` | .cj | ✅ | 见 #4；`cpuFeatures` 有文档注明"预留给 M2"，仓内仅测试读（`FacadeRegistry_test.cj:31`），不判死代码 |
| 16 | `f_jit/src/CompileOptions_test.cj` | .cj | ✅ | 版本默认值与可设置性；与实现一致 |
| 17 | `f_jit/src/CompilePipeline.cj` | .cj | ✅ | 见 #2、#3、#4、#8、#12，优化 O4 |
| 18 | `f_jit/src/CompilePipelineVersion_test.cj` | .cj | ✅ | 版本不串缓存；与 `runSource` 键格式（`:59-60`）一致 |
| 19 | `f_jit/src/CompilePipeline_test.cj` | .cj | ✅ | 端到端 / 同源复用 / 编译期失败 / 运行期报告 |
| 20 | `f_jit/src/Compiler.cj` | .cj | ✅ | 见 #10、#12，优化 O4；锁序 `this.mtx → ClassRegistry.mtx → CompileCache.mtx` 与 `finish` 的"锁外 bindCacheKey"一致，未发现 ABBA |

合计：`.cj` 20 个 / `.md` 0 个 / 共 20 个，全部读完。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 5 | #2（契约）、#3（异常层级）、#4（可变配置）、#9（TOCTOU）、#12（重复实现）；分层与依赖方向正常（`Compiler → CompilePipeline → SourceCompiler/FbcReader/JitExecutor`，无反向依赖）；无外部输入拼串、无凭据、无日志泄密面 |
| §1 死代码 | 3 | 已机械过：逐个 `private` 成员核对引用（本文件内 + `makeArgMarshalers`/`classFieldOf`/`classMethodOf`/`classCtorsOf`/`escapedIds`/`makeRetUnboxer`/`failureCount` 全仓 grep，排除 `.worktrees`/`target`）、`internal` 在本包及子包搜、`protected` 在本模块搜。命中 `makeArgMarshalers`（#6）、`classFieldOf/classMethodOf/classCtorsOf`（#7）、`awaitReady` 末尾不可达 `return None`（#11）；`makeRetUnboxer`/`escapedIds`/`failureCount` 仅测试使用，记可见性建议（#13），不判死代码；`public class Compiler`/`CompileOptions` 的 public 成员对外可达，一律不判；`CallMarshal.init()` 无参形态仅测试使用，同样只作信息 |
| §2 重复逻辑 | 1 | 已逐文件把函数体压成"输入→输出→副作用"两两比对（`CallMarshal` 14 个函数、`ClassRegistry` 9 个、`Compiler` 7 个、`CompilePipeline` 15 个、`CompileCache` 11 个），并按错误文案/字面量跨文件搜（`'编译失败'`/`'装载失败'`/`'参数类型不符'`/`'闭包句柄无效'` 等）。合并为 #12 三处 + #7 的跨文件同形；测试里的 `setup/teardown/codeOf` 属测试准备代码，不计 |
| §3 空实现 | 1 | #8（`userHelpers` 的 `{ _ => 0 }`）；其余 `case None => ()` 均为可选字段缺失，语义正确；无 `TODO`/`FIXME`/`UnsupportedException` 落在主路径 |
| §4 栈溢出 | 1 | #5（`promoteClosureGraph`）；`CallMarshal` 其余路径无递归，`Compiler`/`CompileCache`/`CompilePipeline` 全为循环 |
| §5 OOM | 1 | #1（缓存无上限）；`failures` 已有 256 上限，`pinned/escaped` 为单次调用生命周期，`ClassRegistry` 规模由注册数决定（启动期） |
| §6.1 热点瓶颈 | 0 | 无本部分的 `cjprof`/`bench` 数据（`CallPathBench_test` 只打印），所有性能判断降级为「待验证假设」5 条 |
| §6.2 大粒度锁 | 0 | 逐处核对临界区：`CompileCache` 各方法锁内只做 map 操作；`Compiler.registerType` 在 `this.mtx` 内跑反射注册，但被 `hasClass` 守卫为一次性（`f_rule/src/rule/ScriptAction.cj:92-94`），属冷路径；`ClassRegistry.snapshot` 锁内 `toArray()` 为 O(n) 小拷贝。无锁内 I/O / 日志 / 序列化 |
| §6.3 并发串行 | 0 | 无 `spawn` 后立即 `get()`（测试里的 `spawn` 都是先收集再统一 `get`）；同键编译由 `claim` 去重，等待者已在 #2/优化 O2 讨论 |
| §6.4 低效算法 | 0 | `promoteClosureGraph` 的 `visited` 线性 `contains`（O(n²)）已并入 #5（§4 计数），不重复计；`indexOfLocked`/`containsName` 线性查找在 ≤256 量级，不构成问题 |
| §7 降堆内存方案 | 1 | 优化 O3（缓存有界化）；`CallMarshal` 的惰性 `pinned/escaped` 已是"值型调用不分配"，无明显副本可删 |
| §8 降 CPU 方案 | 3 | 优化 O1（分派表）、O2（忙等）、O4（snapshot 拷贝/去重） |
| §9 local mode 可行性 | 0 | 不适用：每调用临时对象（`Array<Int64> cells`、`pinned/escaped`）全部经 `JitFunction` 闭包/缓存逃逸，且无峰值内存对照数据；收益无法用峰值证明 ⇒ 按约束只能是待验证假设，本部分未列入 |
| §11 现有代码的 BUG（存量） | 13 | 本轮读到的 20 个文件里，边界/空值/错误处理/资源/并发/契约逐条核对：命中 #1–#13；已核对无缺陷的点包括 `CallMarshal.bitsOfCell/bitsOfCell2` 的 64 位有无符号往返（`Int64.Min` 与 `-1` 边界均正确）、`rejectUserHelpers` 的 `off+2 < size` 边界与 `OPCODE_TABLE` 全 256 项 `len >= 1`（无死循环）、`CompilePipeline.indexOf/typesOf` 的兜底下标 |
| §12 并发安全与锁粒度 | 3 | #3（状态残留）、#4（可变配置双读）、#9（TOCTOU）；已核对锁序 `this.mtx → ClassRegistry.mtx`、`this.mtx → CompileCache.mtx`（`Compiler.registerFunction/registerClass/registerType` → `invalidateFailures`），以及 `CompileCache.finish` 刻意在锁外调 `fn.bindCacheKey` 以避免与 `JitFunction.close`（单元锁 → 缓存锁）构成 ABBA，未发现环 |
| §14 功能完备性与 README 覆盖 | 0 | 本部分无 `.md` 文件；以 `README.md` 的符号索引（`:619`）与正文抽查：`makeArgMarshalers`、`makeRetUnboxer`、`escapedIds`、`hasClass`、`registeredNames`、`strictFp`、`verMajor`、`cpuFeatures`、`registerInterface` 均有条目，无遗漏；`cpuFeatures` 文档注明"预留给 M2"，代码仅测试读，属"预留字段"而非缺失接线；`Compiler` 的公开能力（`compile` / `registerType` / `registerInterface` / `registerClass` / `hasFunction` / `registeredNames`）在 README 与 `README_en.md` 均有对应段落 |
| 文件覆盖（§13 等） | 20/20 | 20 个 `.cj` 全部读完；本部分无 `.md`，故 §13 文档一致性未在本部分展开（`design-m1.md` 仅作 #2/#6 的判据引用） |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 0 |
| 一般 | 5 |
| 轻微 | 8 |
| 优化方案（堆内存 / CPU） | 1 / 3 |

存量缺陷 13 条，是否纳入修复待用户决定。

## 总评

本部分代码整体质量偏上：状态机（`CompileCache` 的 Idle→Compiling→Ready/Failed）、锁序（H1 的"锁外 bindCacheKey"、H5 的"类注册与方法并入同临界区"）、快照语义（类/函数注册只影响之后的编译）都有成文注释，并发与超时路径也有对应用例（`CallCompileConcurrency` / `CompileCache_test` / `CompileAwaitTimeout_test`），没有严重级缺陷。

风险集中在**进程级编译缓存的边界**：`ready` 无上限（#1）、命中无原字节二次校验（#2）、非 `Exception` 崩溃会把键永久卡在"编译中"（#3）——这三条都是"单次跑没事、长跑/异常输入才暴露"的类型，且下游 `f_egraph`/`f_rule` 已经在用"每次执行都编译新源码且不 close"的模式，建议一起排期。#4（可变配置双读）属确定性语义漂移，修法只是一行本地快照，性价比最高。#5 的递归深度建议随手改成迭代，与 #3 的 `StackOverflowError` 是同一根因链上的两个面。

其余 8 条轻微问题以死代码（#6、#7）、重复实现（#12）、误导性注释（#13）为主，不影响行为，可随下次重构清理。性能方面本部分没有任何测量数据，4 条优化方案全部标"无基线（待验证）"，需先在 WSL 侧用 `CallPathBench_test` + `cjprof` 补齐对照再决定是否立项。
