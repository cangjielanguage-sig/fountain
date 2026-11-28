# f_jit 模块审查报告（第 27/38 部分）

- **审查日期**：2026-11-28
- **模块路径**：`f_jit/src/base`（本部分 20 个源文件，全部 `.cj`，无 `.md`）
- **基线**：工作区快照 `120fd2542`（master 与 sts/1.3.x 同提交，`git diff` 为空）⇒ 所有问题来源为「存量」
- **审查重点**：动态调用/桥接正确性（typecode 分支表）、句柄与资源生命周期、并发安全、递归与栈溢出、死代码、重复逻辑
- **报告版本**：v1（分部分报告，本部分不写 `docs/review/` 下的模块报告；合并由主 Agent 完成）
- **本部分覆盖内容**：诊断契约（DiagnosticLevel / DiagnosticsSink / DummyDiagnosticsSink）、错误码与异常载体（ErrCode / JitException / InterruptedException / RegistrationException / SourceCompileException）、typecode 分支表（LocalType）、桥接签名与绑定（HostSignature / SignatureRegistry / JitBindings / PredefinedFunction / Engine / JitMode / JitValue），以及对应 5 个测试文件

## 发现

### [一般][存量] `JitBindings.withOverrides` 合并 5 张表却唯独丢弃 `over.parents`

- **位置**：`f_jit/src/base/JitBindings.cj:99`（关键行 `:116`）
- **来源**：存量（工作区快照，无 diff 可比）
- **判据**：review-checklist §11「契约与实现不符」；`withOverrides` 自身注释（`:92`「同名/同形参的项由 `over` 顶掉，**其余保留**」）与实现相反
- **证据**：静态确定 —— `methods` / `fields` / `ctors` / `statics` 四张表走 `replace*` 合并，`ignored` 走 `union`（`:117`），只有 `parents` 直接取 `parents: this.parents`（`:116`），`over.parents` 全程未被读取。调用侧证据：`f_jit/src/JitBindSupport.cj:166-171` 对未 `@JitBind` 的类型返回 `JitBindings.empty()`（`parents = []`），而 `f_jit/src/ReflectRegistrar.cj:128` 与 `:414` 都是 `enrolledOf(name).withOverrides(bindings)` ⇒ 手工注册路径上 `this.parents` **恒为空**，用户显式传入的 `parents` 100% 被丢弃
- **描述**：`JitBindings.init` 把 `parents!` 暴露为公开命名参数（`:72`，文档写明是「接口的父接口名（superTypes）」），但唯一的两条注册路径都只认 `enrolledOf` 的自动登记，显式传入的父接口链静默消失。后果落在 `ReflectRegistrar.registerInterface`：`effective.parents`（`ReflectRegistrar.cj:418`）为空 ⇒ 按 `ClassRegistration.cj:168-173`（关键 `:172`「手工注册的类若不填，则该类只与自身同型」）的口径，接口继承关系收窄，前端 `E as T ?? F` 的子类型判定会给出错误的合法/非法结论（拒绝合法转型，且没有任何诊断）。
- **建议**：改为 `parents: JitBindings.union(this.parents, over.parents)`（顺序与去重口径和 `ignored` 一致）；若确认 `parents` 只允许宏填写，则应把它从公开构造参数里移除，让误用在编译期暴露，而不是运行期静默丢弃

### [一般][存量] `HostSignature` 形状不校验：`paramNames` 与 `params` 不等长会在 `sameShape` 越界；14 位置空类名会让两个签名撞成同一 id

- **位置**：`f_jit/src/base/HostSignature.cj:58`（init）、`:74`（`sameShape`）
- **来源**：存量（工作区快照）
- **判据**：review-checklist §11「缺少边界校验」「契约与实现不符」；§10 正确性（`Option`/数组边界）
- **证据**：静态确定 —— `sameShape` 的前置检查（`:76`）是 `this.params.size != params.size || this.paramNames.size != paramNames.size`，即只比对「两个对象的同名数组长度」，**没有比对 `this.params.size` 与 `this.paramNames.size`**；随后循环 `while (i < params.size)` 里读 `this.paramNames[i]`（`:84`）。构造 `HostSignature(params: [14,14], paramNames: ['User'], …)` 后再以同形状查表，`i=1` 时索引 `this.paramNames[1]` 直接越界。构造点 `f_jit/src/JitHost.cj:68-73`（`registerSignature`）是对外公开入口，三个数组由调用方给；`HostSignature.init`（`:58-66`）对长度、类名与码的一致性零校验
- **描述**：两个后果。(1) 崩溃面：长度不一致时不是注册期报错，而是把 `Array` 越界异常抛在 `SignatureRegistry.register` / `find` 内部，现场离误用点很远。(2) 静默错派：文档 `:38-43` 明写「只比类别码是不够的：`(User) -> R` 与 `(Order) -> R` 的码都是 `[14] -> R`，会让两个签名撞成同一个 id。类名是签名的区分维度」，但没有任何代码强制 14 位置必须带非空类名；`register`（`:130-152`）按 `sameShape` 幂等返回既有 id ⇒ 第二个类会拿到第一个类的 id，`adapterOf`（`:178-189`）返回第一个类的 adapter，运行期 `f as (Order) -> R` 匹配失败抛异常或调到错误的宿主函数。宏路径（`f_jit/src/macros/JitSignature.cj:43`「14 位置必须写注册类名」）是自洽的，风险面是手写 `JitHost.registerSignature` 的下游调用
- **建议**：在 `HostSignature.init` 里做三项校验并抛 `JitException(ErrCode.CALL_CONTRACT, -1, -1, None, …)`：`params.size == paramNames.size`、`params[i] == HOST_OBJECT` 时 `paramNames[i]` 非空、其余位置 `paramNames[i]` 为空；`ret`/`retName` 同口径。校验放在注册入口而不是查表入口，让误用在第一次登记时就失败

### [一般][存量] 测试 `sinkExceptionIsSwallowedWhenNothingInFlight` 断言的是「异常外抛」，与它声明的契约（引擎吞掉）相反

- **位置**：`f_jit/src/base/Diagnostics_test.cj:133`
- **来源**：存量（工作区快照）
- **判据**：review-checklist §3「空实现 / 静默吞异常」的镜像面——契约声称被覆盖但没有覆盖；reviewer.md「功能缺失要双证」的同一原则（断言必须真正指向被验行为）
- **证据**：静态确定 —— 用例名与注释（`:133`「sink 抛异常：无在途异常 ⇒ 被引擎仅吞掉（不重抛）」）声明验证「吞掉」，但函数体（`:138-143`）是 `try { sink.diag(…) } catch (e: Exception) { swallowed = true }`，`@Assert(swallowed, true)` 只在异常**逃出** `diag` 时成立。直接调用 sink 时不存在任何引擎侧包装，所以该断言恒等于「sink 抛出且未吞掉」
- **描述**：这条用例把「契约未被覆盖」写成了「契约已验证」。任何后续把吞掉逻辑下沉到 `DiagnosticsSink` 默认实现或 `DummyDiagnosticsSink` 的改动都会让它失败，而实现契约 3（有在途 → `addSuppressed`，无在途 → 仅吞掉）的人从中得不到任何信号。文件头 `:36-40` 也承认引擎侧证据在 S5.12/S6.4，但用例名与注释没有同步这一限定
- **建议**：改名为 `sinkExceptionPropagatesToCaller` 并把注释改为「证明 sink 的异常会到达调用方，吞掉责任在引擎」；或把契约 3 的两分支抽成 base 内一个可调用的私有函数（`swallowOrSuppress(inflight: ?Exception, body: () -> Unit)`），由本文件直接断言两分支

### [轻微][存量] 未使用 import：`HostSignature.cj` 引入 `ArrayList` 但全文无使用

- **位置**：`f_jit/src/base/HostSignature.cj:18`
- **来源**：存量（工作区快照）
- **判据**：review-checklist §1「未使用的 `import`」
- **证据**：静态确定 —— `grep -n "ArrayList" f_jit/src/base/HostSignature.cj` 只有两处命中：`:18` 的 import 与 `:102` 注释文本；实现用的是 `AtomicReference<SigSnapshot>` 与 `Array<HostSignature>`（`:120-121`、`:142`）
- **描述**：该文件从「`ArrayList` + 锁」改成「写时复制 + 原子发布」后，import 与注释都没跟着改（注释问题见 F8）
- **建议**：删除 `:18`

### [轻微][存量] 枚举 `==` 五处同一模板（嵌套 `match` 逐构造器展开），全模块共 11 处

- **位置**：`f_jit/src/base/DiagnosticLevel.cj:32`、`f_jit/src/base/Engine.cj:33`、`f_jit/src/base/JitMode.cj:37`、`f_jit/src/base/JitValue.cj:48`、`f_jit/src/base/RegistrationException.cj:34`（`RegistrationRejectKind`）
- **来源**：存量（工作区快照）
- **判据**：review-checklist §2「只改类型名的重复逻辑」——四段函数体逐行对齐，只有枚举构造器名不同
- **证据**：静态确定（逐函数体比对）。`DiagnosticLevel` / `Engine` / `JitMode` / `RegistrationRejectKind` 四处的语义完全相同：「同一构造器 ⇒ true，否则 false」，无任何载荷参与。`JitValue`（`:48-71`）是唯一有载荷比较的（`Int`/`Float`/`Handle` 比载荷，`` `Unit` `` 只比标签），按 `:32-33` 的说明必须按标签分派，属**语义不同**，不能合并。跨文件统计：`grep "public operator func ==(other:" f_jit/src` 共 11 处
- **描述**：每新增一个无载荷枚举就要复制一段 14 行嵌套 `match`，且 `case _ => false` 的层级写错（例如把内层 `case _` 漏掉）不会报错，只会让 `==` 恒真。这类模板是死代码审查里最容易积累「结构相同、内容漂移」的地方
- **建议**：为「无载荷枚举」统一一份模板（宏生成，或集中到一个可复用写法）；`JitValue` 保持手写。注意 `==` 不能删——本仓 11 处枚举都是手写实现，官方文档（`enum_and_pattern_match/enum.md`）也未记载 `enum` 自动派生 `Equatable`

### [轻微][存量] `JitBindings` 四个 `replace*` 函数逐行同构

- **位置**：`f_jit/src/base/JitBindings.cj:137`、`:158`、`:179`、`:199`
- **来源**：存量（工作区快照）
- **判据**：review-checklist §2「只改类型名」——四段 19 行循环体逐行对齐，差异只有元素类型（`PublicMethod` / `JitFieldBinding` / `PublicCtor` / `PredefinedFunction`）与匹配键（`name` 三处、`sameParams` 一处）
- **证据**：静态确定（两两比对函数体）。已核对合并安全性：方法表在本模块内**按 name 唯一**（`f_jit/src/ReflectRegistrar.cj:468`、`:492`、`:672` 全按 `name` 查/替换，无同名重载并存），所以「按 name 替换」与「按 `params` 替换」的口径差异是设计选择，不是缺陷
- **描述**：四处「找到即 clone 整表替换 / 未找到即扩容追加」的逻辑完全一致，任何一处修正（如改成先扫描再一次性构建，见优化方案 O1）都要改四遍，漏一处就出现「构造器走新路径、字段走旧路径」的行为漂移
- **建议**：抽成两个泛型助手：按 key 取值的 `replaceByName<T>(xs, v, keyOf: (T) -> String)` 与 `replaceByParams<T>(xs, v, paramsOf: (T) -> Array<UInt16>)`；或者只保留「name 键」与「params 键」两个实现，由四个调用点传 key 函数

### [轻微][存量] 「签名形状相等」在本模块有 4 份实现，字段集各不相同

- **位置**：`f_jit/src/base/HostSignature.cj:74`（比 `params` + `paramNames` + `ret` + `retName`）、`f_jit/src/base/JitBindings.cj:250`（只比 `params`）、`f_jit/src/runtime/SignaturePlan.cj:62`（比 `params` + `ret`）、`f_jit/src/runtime/HandleTable.cj:551`（`sigEquals`，比 `params` + `ret`）
- **来源**：存量（工作区快照）；后两处在本部分范围外，仅作去重线索
- **判据**：review-checklist §2「表现形式不同的重复逻辑 → 行为漂移」
- **证据**：静态确定 —— 四段都是「长度不同即 false，再逐位比较」，但参与比较的维度分别是 4 / 1 / 2 / 2 个。`HostSignature` 是注册表 id 的键，`SignaturePlan` / `HandleTable.sigEquals` 是运行期回调缓存/去重的键，两者一旦对「形状」的定义分叉，就会出现「注册表认为是两个签名、缓存认为是同一个」的组合
- **描述**：本次没有找到已经漂移的实例（4 处对 `params` 的判定一致），但 `retName` / `paramNames` 这两个后加的维度只在 `HostSignature` 出现，说明漂移机制已经存在。`base` 是最底层包，`runtime` 依赖它不构成反向依赖
- **建议**：在 `base` 提供 `paramsEquals(a: Array<UInt16>, b: Array<UInt16>)` 与 `shapeEquals(params, paramNames, ret, retName, …)` 两个纯函数，四处改为调用；`SignaturePlan` / `HandleTable` 用只比 `params` + `ret` 的轻量重载，语义差异写进函数名（`shapeEquals` vs `keyEquals`）

### [轻微][存量] 注释与实现/语言事实不一致（6 处，同一根因：改造后未同步注释）

- **位置与证据**：全部静态确定
  1. `f_jit/src/base/HostSignature.cj:93-104`：`SignatureRegistry` 的类注释写在一个 `private class SigSnapshot`（`:111`）**上方**，文档工具会把它挂到 `SigSnapshot` 上；`SignatureRegistry`（`:119`）自己没有任何注释
  2. `f_jit/src/base/HostSignature.cj:102-103`：「`ArrayList` 的读在锁内拷贝引用」——实现早已改成 `AtomicReference<SigSnapshot>` 写时复制（`:121-151`），没有 `ArrayList`，也不在锁内读
  3. `f_jit/src/base/LocalType.cj:79-86`：「15–19 是 M3 的预留登记位，本步只占位不实名」——实现 `:104-108` 已实名（`'Any'` / `'JsonValue'` / `'JsonObject'` / `'JsonArray'` / `'JsonNull'`）
  4. `f_jit/src/base/LocalType.cj:164-173`：`fromToken` 的映射表只列到 `HostObject↔11`，实现 `:187` 多了 `case 12u16 => ANY`
  5. `f_jit/src/base/JitException.cj:51-53`：「仓颉（1.3.0）**没有函数默认参数**（默认值只在跨平台 `common/specific` 声明里有定义）」——文档 `cangjie_docs/docs/dev-guide/source_zh_cn/function/define_functions.md:35,47` 明确「命名参数还可以设置默认值…只能为命名参数设置默认值，不能为非命名参数设置默认值」，同包的 `f_jit/src/base/JitBindings.cj:68-73`、`PredefinedFunction.cj:49` 就用了默认值。真实原因是 `cause` 是**位置参数**，而不是「没有默认参数」这个特性
  6. `f_jit/src/base/Diagnostics_test.cj:88`：「断言只看 level 与 code，不匹配 message 文本」——`:96`、`:111` 两处断言的正是 message 文本；`f_jit/src/base/LocalType_test.cj:122`：「12 属 M3（Any）登记位，本步仍未定义」——`:125` 紧接着断言 `fromToken(12u16) == ANY`
- **判据**：review-checklist §11「语义与命名 / 注释不符」、§13（注释即内部契约文档）
- **描述**：单条都是措辞层面，但 3、4、6 会让人误判 `LocalType` 的当前合法集（据此写分支表就少一个 case），5 会让人以为默认参数不可用而继续复制重载。共同根因是 M3 回填与「ArrayList → 快照」两次改造后没回头同步注释
- **建议**：按实现改注释；`HostSignature.cj:93-104` 整体下移到 `:119` 的 `class SignatureRegistry` 上方，`:105-110` 的 `SigSnapshot` 注释保持原位

### [轻微][存量] `JitBindings.isEmpty()` 只看 4 张表，`parents` / `ignored` 不参与判定

- **位置**：`f_jit/src/base/JitBindings.cj:86`
- **来源**：存量（工作区快照）
- **判据**：review-checklist §11「语义与命名不符」
- **证据**：静态确定 —— 函数体只判 `methods` / `fields` / `ctors` / `statics`（`:87-88`），`parents`（`:59`）与 `ignored`（`:66`）被忽略。`grep -rn "\.isEmpty()" f_jit/src` 未发现 `JitBindings` 的调用点（仓内零引用，`public` 对外可达，不判死代码）
- **描述**：`JitBindings(parents: [...])` 这种「只有父接口、没有成员」的实例会返回 `true`。下游若用它做「无绑定，跳过合并」的短路（这是 `isEmpty` 最自然的用法），会把父链一起跳过，与 `withOverrides` 的 `parents` 问题（F1）叠加
- **建议**：把 `parents.size == 0 && ignored.size == 0` 纳入判定；或改名为 `hasMemberBindings()`，让语义边界写在名字上

### [轻微][存量] `JitBindings` / `PredefinedFunction` 构造不做防御性拷贝，与同包 `HostSignature` / `ClassRegistration` 相反

- **位置**：`f_jit/src/base/JitBindings.cj:68`、`f_jit/src/base/PredefinedFunction.cj:48`
- **来源**：存量（工作区快照）
- **判据**：review-checklist §12.1「共享可变状态」；同包内已存在相反惯例
- **证据**：静态确定 —— `JitBindings.init` 直接 `this.methods = methods`（`:74-79`）；`PredefinedFunction.init` 直接 `this.paramTypes = paramTypes`（`:53`）；而 `HostSignature.init` 用 `params.clone()` / `paramNames.clone()`（`HostSignature.cj:60-61`），`ClassRegistration.init` 对四张表全部 `clone()`（`f_jit/src/base/ClassRegistration.cj:184-187`）。`Array` 是引用类型，构造后调用方仍可通过手里的数组改写已发布绑定表的内容
- **描述**：仓内两条构造路径（`@JitBind` 宏给出的数组字面量、`withOverrides` 新建的数组）都不会事后改写入参数组，所以**当前没有可触发的竞争路径**；风险在语义层面：`JitBindings` 被当作不可变快照发布到 `JitBindSupport` 里（读侧无锁），一旦有调用方复用并修改同一数组，读侧就会看到半更新内容，而 Type 上没有 const 保护
- **建议**：与 `HostSignature` / `ClassRegistration` 对齐做 `clone()`；若刻意选择「交出所有权」以避免注册期多一次复制，就在类注释里写明这条所有权约定

### [轻微][存量] 测试里的同义反复断言（断言自己刚写的字面量长度）

- **位置**：`f_jit/src/base/Diagnostics_test.cj:48`、`:68`；`f_jit/src/base/ErrCode_test.cj:88`、`:89`；`f_jit/src/base/LocalType_test.cj:59`；`f_jit/src/base/RegistrationException_test.cj:50`
- **来源**：存量（工作区快照）
- **判据**：review-checklist §3 判据「有没有用例覆盖」——断言必须能区分「实现错了」
- **证据**：静态确定 —— 例如 `Diagnostics_test.cj:47-48` 先 `let all = [Info, Warn]` 再 `@Assert(all.size, 2)`，断言的是上一行字面量长度；`DiagCode` 的 `@Assert(all.size, 6)`、`LocalType_test` 的 `@Assert(expected.size, 15)`、`RegistrationException_test` 的 `@Assert(kinds.size, 6)` 同理。它们无法证明「枚举只有 N 档」（编译器不允许遗漏 `match` 分支这一点已经由 `for` 里的穷尽 `match` 覆盖）
- **描述**：这类断言的唯一作用是让用例数看起来有覆盖度，实际零判别力；真正的判别力来自 `for (level in all) { match … }` 与逐值 `@Assert`
- **建议**：删除 `size` 断言（穷尽 `match` 已由编译器保证），或改成对「新增构造器必须同步此表」有约束力的检查（如 `@Assert(all.size, <枚举构造器数>)` 附注释说明它防的是漏加，而非防实现错）

### [轻微][存量][可见性建议] `SignatureRegistry.resetForTest` 是对外公开的进程级重置

- **位置**：`f_jit/src/base/HostSignature.cj:196`
- **来源**：存量（工作区快照）
- **判据**：reviewer.md「对外可达的 `public` 若想收窄可见性，单独作为可见性建议」——**不是死代码**
- **证据**：静态确定 —— `SignatureRegistry` 是 `public class`，`resetForTest` 是 `public static`；调用方全部在测试里（`f_jit/src/HostSignature_test.cj:55,60,65,70,75,83,89,112,117,131`、`f_jit/src/HostClosureAdapter_test.cj:62,73,80,86,93,104,123`），共 19 处，无生产调用点
- **描述**：下游可以调用它把整张签名表清空，此后所有已编译产物里的签名 id 全部失效（`get(id)` 返回 `None`，H63 走不到 adapter），表现为难以定位的运行期降级。同时它是两个测试类共享的进程级状态：当前 `f_jit/cjpm.toml` 未配置 `[profile.test] parallel`（默认串行），所以不构成 flake；一旦有人用 `cjpm test --parallel=true`（`cjpm_manual.md:615`），两个测试类会互相清表
- **建议**：收窄为 `internal`（测试与本包同包，可直接调用）；若必须保留 `public`，在注释里写明「仅测试用，调用后所有既有签名 id 失效」

## 优化可行性方案

### [堆内存] `JitBindings.withOverrides` 改为「先收集覆盖项，再单趟构建」

- **现状**：`withOverrides`（`JitBindings.cj:99-118`）对每条覆盖项调用一次 `replace*`，而每个 `replace*` 命中时执行 `xs.clone()`（`:142`/`:163`/`:183`/`:204`）——k 条覆盖 ⇒ k 次全表复制 + k 个临时数组，峰值同时存活「原表 + k 个中间表」。表规模 = 类成员数十条，k = 显式覆盖条数（通常 1–3），只在注册期执行一次
- **方案**：先在 `over` 侧建「键 → 覆盖项」的临时 `HashMap`（键同 `replace*` 的匹配键），再对 `this` 的四张表各走一趟：命中则取覆盖值、未命中保留原值，最后一次性 `toArray()`。四个 `replace*` 可同时消掉（与 F6 同源）
- **预期**：注册期数组复制次数由 `k` 降到 1，临时数组峰值由 `k+1` 份降到 2 份；以每类 20 成员、覆盖 2 条估算，单类注册少 2 次全表复制
- **代价**：需要为四张表各写一次「键化」逻辑（或引入键函数），代码行数短期增加；`HashMap` 在小 k 下的常数开销可能吃掉部分收益
- **验证**：`cjpm bench -O2`，注册 1000 个类（每类 20 方法 / 5 字段）的启动耗时与 `getAllocatedHeapSize()` 前后对照，取 10 轮中位数与离散度；同时断言合并语义（同名替换、未命中追加、顺序保持）与现状逐位一致
- **证据状态**：`无基线（待验证，不进 tasks）`

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 注释引用「拼键 790 ns vs 线性扫 349 ns」是注册/查表路径的真实量级，且在本机 SDK 上仍成立 | `f_jit/src/base/HostSignature.cj:107-110` | 测量环境、输入规模、轮数、离散度均未归档 | 对 `SignatureRegistry.find` 跑 `cjpm bench -O2`，表规模 1/4/8/16 条目，各 10 万次取中位数 |
| 2 | `withOverrides` 的 clone-per-override 是启动期堆分配的可观测来源 | `f_jit/src/base/JitBindings.cj:137-218` | 注册期分配量与峰值 | 注册 1000 类场景下 `getAllocatedHeapSize()` 分段计时 + `cjprof heap` |
| 3 | `JitBindings.union` 的 `ArrayList.contains`（`JitBindings.cj:130`）在忽略名单较大时退化为 O(k²) | `f_jit/src/base/JitBindings.cj:121-135` | k 的实际分布与单次耗时 | 埋点统计 `ignored` 条数分布；k=1/10/100/1000 各跑 1 万次 |
| 4 | `cjpm test --parallel=true` 下 `SignatureRegistry.resetForTest` 会与 `HostClosureAdapter_test` 互相清表 | `f_jit/src/base/HostSignature.cj:196` | 并行执行下的失败率 | 以 `--parallel=true` 连跑 20 轮 `cjpm test`，统计 flaky 用例（当前 `f_jit/cjpm.toml` 未开并行，默认串行不受影响） |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_jit/src/base/DiagnosticLevel.cj` | .cj | ✅ | 枚举 `==` 重复见 F5 |
| 2 | `f_jit/src/base/DiagnosticsSink.cj` | .cj | ✅ | 接口默认实现 + 契约注释，与 `DummyDiagnosticsSink` 一致 |
| 3 | `f_jit/src/base/Diagnostics_test.cj` | .cj | ✅ | F3（断言与契约相反）、F8-6、F11 |
| 4 | `f_jit/src/base/DummyDiagnosticsSink.cj` | .cj | ✅ | 有注释的 Null Object，不判 §3 |
| 5 | `f_jit/src/base/Engine.cj` | .cj | ✅ | `protected` 枚举 + `==`（接口实现，豁免死代码）；全模块引用 35 处 |
| 6 | `f_jit/src/base/ErrCode.cj` | .cj | ✅ | 码值/`describe`/`isHostSide` 与测试逐项对齐，未发现缺口 |
| 7 | `f_jit/src/base/ErrCode_test.cj` | .cj | ✅ | F11；码表断言有判别力 |
| 8 | `f_jit/src/base/HostSignature.cj` | .cj | ✅ | F2、F4、F7、F8-1/2、F12 |
| 9 | `f_jit/src/base/InterruptedException.cj` | .cj | ✅ | 单构造器异常，无问题 |
| 10 | `f_jit/src/base/JitBindings.cj` | .cj | ✅ | F1、F6、F7、F9、F10 |
| 11 | `f_jit/src/base/JitException.cj` | .cj | ✅ | F8-5（注释关于默认参数的断言错误）；重载语义正确 |
| 12 | `f_jit/src/base/JitException_test.cj` | .cj | ✅ | 六字段往返、`BaseException` 可捕获均有判别力 |
| 13 | `f_jit/src/base/JitMode.cj` | .cj | ✅ | F5 |
| 14 | `f_jit/src/base/JitValue.cj` | .cj | ✅ | `==` 按标签 + 载荷分派，与注释一致；`protected` 枚举 + 接口实现豁免 |
| 15 | `f_jit/src/base/LocalType.cj` | .cj | ✅ | 分支表逐位核对（0–19、`NONE=0xFFFF`、`isLegal` 三版分派）无误；F8-3/4 |
| 16 | `f_jit/src/base/LocalType_test.cj` | .cj | ✅ | F8-6、F11；`isHandle`/`isConvertible` 边界用例完整 |
| 17 | `f_jit/src/base/PredefinedFunction.cj` | .cj | ✅ | 合法集校验（0–8/10–11/13/14、ret ≤ 14）与错误消息一致；F10 |
| 18 | `f_jit/src/base/RegistrationException.cj` | .cj | ✅ | 六类拒绝 + 三段消息；`buildMessage` 六分支全覆盖；F5 |
| 19 | `f_jit/src/base/RegistrationException_test.cj` | .cj | ✅ | `hintOf` 与生产消息表为测试侧独立期望值，不判 §2；F11 |
| 20 | `f_jit/src/base/SourceCompileException.cj` | .cj | ✅ | `hintSuffix` 空提示剪裁正确；六字段组装与注释一致 |

合计：`.cj` 20 个 / `.md` 0 个 / 共 20 个，全部读完。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 4 | 正确性 3（F1 契约合并、F2 边界校验、F9 语义判定）、可读性 1（F8 注释错位）；无 Controller/Service/DAO 分层可判；无外部输入拼接、无凭据，安全面无命中 |
| §1 死代码 | 1 | F4（未使用 import）。逐符号搜引用：`SigSnapshot`/`writeMtx`/`current`/`union`/`replaceMethod`/`replaceField`/`replaceCtor`/`replaceStatic`/`sameParams`/`checkParamTypes`/`checkRetType`/`buildMessage`/`hintSuffix`/`DiagRecord`/`RecordingSink`/`OverridingSink`/`ThrowingSink`/`SinkFailure`/`hintOf` 全部有调用者；`Engine`/`JitValue` 为 `protected` 枚举但全模块分别引用 35/26 次，其 `==` 属接口实现豁免；`public` 且对外可达者（`ErrCode`/`LocalType`/`HostSignature`/`SignatureRegistry`/`JitBindings`/`PredefinedFunction`/异常类）不判；无 `return`/`throw`/`break`/`continue` 后同层语句（逐个函数尾表达式确认）；`private init()` 是刻意的不可实例化声明 |
| §2 重复逻辑 | 3 | F5（5 处枚举 `==`，同模块共 11 处）、F6（4 个 `replace*`）、F7（4 份形状比较）。另外两处经比对**判定不是重复**：`LocalType.name` 与 `TypeToken.name`（码空间不同：LocalType 0–19 vs token 0–12）、`RegistrationException_test.hintOf` 与 `buildMessage`（测试侧独立期望值，用于发现文案漂移） |
| §3 空实现 | 0 | `DummyDiagnosticsSink` 是带注释的 Null Object（`DummyDiagnosticsSink.cj:18-23`）；全部分无 `TODO`/`FIXME`、无 `catch {}`、无空函数体；`SourceCompileException.hintSuffix` 的空串分支是有语义的剪裁。测试侧「契约覆盖不实」在 F3、测试「零判别力断言」在 F11 单独记（不重复计入本行） |
| §4 栈溢出 | 0 | 逐个函数确认本部分无递归：`sameShape`/`sameParams`/`replace*`/`union`/`name`/`fromToken`/`describe` 均为循环或 `match`；枚举 `==` 只嵌套一层 `match`；无自引用结构与深拷贝 |
| §5 OOM | 0 | 无「按报文长度预分配」「全量物化」「无界缓存」。`SignatureRegistry` 只增不减，但条目数由注册类/签名数量决定（宿主启动期可控、非不可信输入），且无淘汰需求；`Array(n+1, repeat:)` 的 n 为已注册条目数。量化结论：条目为个位数~百级 × 单条约 100 B，峰值可忽略 |
| §6.1 热点瓶颈 | 0 | 本部分无 profile/bench 数据；`HostSignature.cj:108` 注释里的 349/790 ns 无归档基线 ⇒ 进待验证假设 #1，不作发现 |
| §6.2 大粒度锁 | 0 | 唯一锁 `writeMtx`（`HostSignature.cj:120`）只包「扫表 + 内存数组复制 + 原子 store」，临界区无 I/O/解析/日志/外部回调；竞争线程数 = 注册线程（启动期） |
| §6.3 并发串行 | 0 | 本部分无 `spawn`/`Future`/线程池，无形式并发 |
| §6.4 低效算法 | 0 | `register` 单次 O(n) 复制（n 个位数）、`union` 的 `contains` O(k²)（k 为忽略名单）均未达瓶颈，缺数据 ⇒ 假设 #2、#3；`adapterOf`/`find` 线性扫已在注释里说明取舍 |
| §7 降堆内存方案 | 1 | O1（`withOverrides` 单趟构建），证据状态「无基线（待验证）」 |
| §8 降 CPU 方案 | 0 | 本部分唯一的 CPU 候选与 O1 同源（少复制即少 CPU），已合并进 §7，不重复计 |
| §9 local mode 可行性 | 0 | 本部分无「函数内创建、函数内释放」的大对象峰值场景；注册期代码执行一次，收益无法用峰值内存证明，且 `SignatureRegistry` 的静态快照按设计要长期存活（逃逸），不满足 local 条件 |
| §11 现有代码的 BUG（存量） | 6 | F1、F2、F3、F8、F9、F10（全部为存量，快照模式无基线可比） |
| §12 并发安全与锁粒度 | 1 | F10（数组内容可被外部改写，仓内无触发路径）。正面核对：`SignatureRegistry` 写时复制 + 原子发布，读侧无锁、id 只追加，`resetForTest` 与 `register` 同锁 ⇒ 安全；`JitBindings`/`HostSignature` 无跨线程可变字段；本部分无多锁，不存在锁序问题 |
| §14 功能完备性与 README 覆盖 | 0 | 本部分不含 `.md`，README 覆盖判定归属含 `README.md` 的部分；已核对「承诺 vs 实现」：`DiagnosticsSink` 契约 1/2/3 均有对应实现或注释限定（契约 3 的引擎侧未在本部分实现，已在 F3 说明）；`JitBindings.parents` 的可用性缺口并入 F1，不重复计 |
| 文件覆盖（§13 等） | 20/20 | 本部分清单 20 个文件全为 `.cj`，无 `.md`，无缺读 |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 0 |
| 一般 | 3 |
| 轻微 | 9 |
| 优化方案（堆内存 / CPU） | 1 / 0 |

存量缺陷共 12 条（3 一般 + 9 轻微），是否纳入修复待用户决定；本报告不替用户拍板。

## 总评

本部分是 f_jit 的类型码表与注册契约底座，主干代码质量良好：`LocalType` 的分支表（`isHandle` / `isConvertible` / `hasBoxPoint` / `isSameOrDescendant` / `fromToken` / `isLegal`）与文档表格逐位对齐，边界（0–3 值型 / 4–19 句柄型 / `NONE=0xFFFF` / 三版合法集）没有找到差错；`SignatureRegistry` 的「写时复制 + 原子发布 + id 只追加」是本模块并发处理最干净的一处，读路径无锁且语义成立；`ErrCode` / `RegistrationException` / `SourceCompileException` 的码表与消息组装同测试逐项咬合。

风险集中在**「对外 API 的入参没有被契约拦住」**这一条线上，两条一般级问题都出自这里：`JitBindings.withOverrides` 只合并四张表、静默丢弃 `parents`（F1，会让接口继承链在手工注册路径上消失，前端子类型判定给出错误结论）；`HostSignature` 对 `params` / `paramNames` 的长度与类名一致性零校验（F2，轻则注册期抛越界，重则两个不同类的签名撞成同一 id 而错派 adapter）。两者都属「合法用法不受影响、误用无提示」，不阻塞当前主路径，但会把下游的配置错误变成运行期错派或远端崩溃，建议优先补校验与合并语义，成本很低。

其余为可维护性问题：5 处枚举 `==` 与 4 处 `replace*` 的同模板复制（F5、F6）、4 份签名形状比较（F7）会让「形状」定义在多处漂移；6 处注释停在改造前（F8，其中 `LocalType` 的两条会直接误导分支表写法）；测试侧有一条与契约相反的用例（F3）和若干零判别力断言（F11），会制造「契约已覆盖」的假象。三条一般级问题都建议排期，轻微项可与下一次 `f_jit` 重构合并处理。
