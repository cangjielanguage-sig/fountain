# f_jit 模块审查报告（第 29/38 部分）

- **审查日期**：2026-11-28
- **模块路径**：`f_jit/src/bytecode`（18 个）+ `f_jit/src/compiler`（2 个），共 20 个源文件，全部 `.cj`，本部分无 `.md`
- **基线**：工作区快照，`git status` 对本部分目录为空（无未提交改动）；本机 HEAD=`f309f0b55`（dispatch 记载 `120fd2542`，差异为后续 docs 提交），本部分文件的 blame 落在 `8d1b1900a5`（2026-10-17）及更早 ⇒ 所有问题来源为「存量」
- **审查重点**：动态调用/桥接正确性（typecode 分支表）、句柄与资源生命周期、并发安全、递归与栈溢出、死代码、重复逻辑
- **报告版本**：v1（分部分报告；本部分不写 `docs/review/` 下的模块报告，合并由主 Agent 完成）
- **本部分覆盖内容**：`.fbc` 容器读侧用例（FbcReader_test）、加载规则集（FbcRuleSet）、容器组装（FbcWriter）、指纹与去重守卫（Fingerprint）、函数目录（FuncDir）、指令解码（InsnDecoder）、局部类型表（LocalTypes）、名字表（NameTable）、站点表（SiteTable）、opcode 元信息表（OpInfo）、统一拒绝入口（Reject），以及 8 个配套测试文件与 2 个前端/Map 键行为用例

## 发现

### [一般][存量] 去重缓存的「命中后二次校验」没有接线，`DedupGuard` 只被测试引用

- **位置**：`f_jit/src/bytecode/Fingerprint.cj:119`（守卫定义）、`:147`（`matches`）；生产路径 `f_jit/src/CompilePipeline.cj:59-63`、`:96-100`（范围外线索）；义务声明在 `f_jit/src/CompileCache.cj:28`
- **来源**：存量（blame `8d1b1900a5`；快照无 diff）
- **判据**：review-checklist §14.1「接线缺失」+ §11「契约与实现不符」
- **证据**：静态确定 —— 全仓 grep `DedupGuard` 只有 `Fingerprint.cj:119` 的定义与 `Fingerprint_test.cj:112` 的使用；`.matches(` 在生产代码零命中；`CompileCache` 只保存 `HashMap<String, JitFunction>`（`CompileCache.cj:32`），不保存原始字节；`CompileCache.cj:28` 明写「命中后二次校验原字节由调用方（Pipeline）负责」，而 `CompilePipeline.runSource` / `runUnit` 只拼 `Fingerprint.fnv1a128(...)` 字符串键后直接 `lookup`（`CompilePipeline.cj:60-63`、`:96-99`），没有任何字节比较
- **描述**：`Fingerprint.cj:111-118` 与 design D8 / §12.6 的契约是「碰撞 = 语义错误 ⇒ 条目保存原始输入字节，命中后做长度 + 字节二次校验（不符按 Miss 重编）」。现状把 128 位指纹当唯一判据：一旦发生碰撞，A 源码的 `JitFunction` 会被返回给 B 源码，静默执行错误逻辑，且无任何诊断。概率是 2^-128，实际风险极低；但契约与实现相反，`DedupGuard` 成了「只被测试引用、文档却宣称已生效」的对外 API
- **建议**：二选一，不要停在半接线状态。(a) 在 `CompileCache` 条目里保存 `DedupGuard`（或 `key + 原始字节`），`lookup` 命中后用 `matches` 复核，不符则按 Miss 重新编译；(b) 若确认接受概率兜底，删除 `DedupGuard` 并同步改掉 `Fingerprint.cj:36-37`、`:111-118`、`CompileCache.cj:28`、`Fingerprint_test.cj:35` 的承诺，避免「已实现」的假象。选 (a) 时要一并评估每条缓存多一份完整源码/字节码副本的内存代价（见优化方案 O4）

### [一般][存量] `NameTable.validate` 用 O(n) 反查 `nLocals`，且 `types` 与 `dir` 不等长时抛非契约异常

- **位置**：`f_jit/src/bytecode/NameTable.cj:189-215`（关键循环 `:192-197`、抑制告警 `:214-215`）
- **来源**：存量（快照无 diff）
- **判据**：review-checklist §11「缺少边界校验」「语义与注释不符」；§6.4「低效算法」
- **证据**：静态确定 —— `dir.get(e.fnId)` 返回的 `FuncEntry` 本身就带 `nLocals`（`FuncDir.cj:65`），随后又用 `for (k in 0..dir.size) { if (dir.at(k).fnId == e.fnId) { nLocals = types[k].size; break } }` 反查；`types` 的长度没有任何前置校验（方法签名 `:182` 是对外 public，仓内唯一调用点 `FbcReader.cj:118-136` 恰好等长）；`:214-215` 的 `let unused = fn.fnId` + `let _ = unused` 是为让 `fn` 不被判「未使用」的写法，实际 `fn` 只用于触发 `dir.get` 的拒绝副作用
- **描述**：两个后果。(1) 边界：调用方若传入比 `dir` 短的 `types`，`types[k]` 抛 `IndexOutOfBoundsException`，而不是加载期统一的 `JitException(18, site=-1)`——破坏「加载期拒绝只有一种异常」的契约；触发条件明确（某个名字条目的 `fnId` 在目录中的下标 ≥ `types.size`）。(2) 复杂度：每个名字条目扫一遍目录，加载期 O(名字数 × 函数数)；而同一目录在 `LocalTypes.validate`（`FbcReader.cj:119-121`）已逐函数校验过 `slots.size == nLocals`，这次反查是纯重复
- **建议**：直接用 `Int64(fn.nLocals)`，删除 `:191-197` 的循环与 `:214-215` 的 `unused` 技巧；方法开头补 `if (types.size != dir.size) rejectFormat(...)`（或把参数换成按 fnId 取 nLocals 的闭包），让坏输入也走 18

### [轻微][存量] `Fingerprint.sourceKey` 不是 `compile(source)` 的去重键，换行规范化在生产路径上未生效

- **位置**：`f_jit/src/bytecode/Fingerprint.cj:70-75`（口径定义）vs `f_jit/src/CompilePipeline.cj:59-60`（实际取键）
- **来源**：存量（快照无 diff）
- **判据**：review-checklist §11「契约与实现不符」；§14.1「接线缺失」
- **证据**：静态确定 —— 全仓 `Fingerprint.sourceKey` 只出现在定义、`Fingerprint_test.cj:111-118` 与测试断言中；`CompilePipeline.cj:59-60` 拼键时直接对**未规范化**的 `source` 取 `Fingerprint.fnv1a128(source)`。`Fingerprint.cj:29`、`:71` 明写源码指纹的输入是「换行规范化之后的源码 UTF-8 字节（§12.6）」
- **描述**：同一份逻辑源码用 CRLF / LF 两种换行会得到两个不同缓存键 ⇒ 重复编译、两个 `JitFunction`、两份关闭点；不会产生错误结果，但与冻结的指纹口径不一致，若键需要跨进程复现（持久化/比对）会对不上
- **建议**：`CompilePipeline` 改用 `Fingerprint.sourceKey(source)`，或把规范化前移到 `runSource` 入口并保证「键」与「真正编译的字节」同源；同时补一条管线级用例（现有 `sourceKeyNormalizesNewlines` 只测函数本身）

### [轻微][存量] `OpInfo.OPCODE_TABLE` 是公开可写数组，与「只读元信息」的契约相反

- **位置**：`f_jit/src/bytecode/OpInfo.cj:119`（`public static let OPCODE_TABLE: Array<OpInfo>`），契约在 `:24-27`
- **来源**：存量（快照无 diff）
- **判据**：review-checklist §11「契约与实现不符」；§12.1「共享可变状态无保护」
- **证据**：静态确定 —— 仓颉 `Array` 是引用类型，`let` 只冻结绑定不冻结元素（同模块 `Fingerprint.cj:91-107` 就是 `let out = Array(...)` 后逐元素写入）；`OPCODE_TABLE[i] = OpInfo(...)` 可编译。当前全仓 `OPCODE_TABLE[` 只有读、无写，因此是「契约未受保护」而非已发生的竞争；类注释 `:24-27` 声称它是「只读元信息（五字段全 let、无身份、无行为）」
- **描述**：表本体对任何调用方开放写。一处误写会改变全进程的解码长度/类别（`InsnDecoder.decode` 直接信任 `info.len`，写成 0 时 `opsLen = -1` 会在 `Array<UInt8>(-1)` 处抛异常），并发读写下还可能读到半更新的 struct
- **建议**：把表收进 `private static let`，对外提供 `at(op: UInt8): OpInfo`（越界拒绝）或 `snapshot(): Array<OpInfo>`（返回副本），`selfCheckOk` 与 `InsnDecoder` 改用访问器；若必须保留公开字段，至少在文档写清「禁止写入」并加启动期自检

### [轻微][存量] `DedupGuard.rawBytes` 返回内部数组引用，二次校验可被外部改写绕过

- **位置**：`f_jit/src/bytecode/Fingerprint.cj:136-140`
- **来源**：存量（快照无 diff）
- **判据**：review-checklist §11「契约与实现不符」（守卫的不变量被发布逸出）
- **证据**：静态确定 —— `get() { this.bytes }` 直接返回 `private let bytes` 的引用；`Array` 元素可写，`matches`（`:147-160`）比较的正是这个数组。当前 `rawBytes` 在仓内零使用（只有定义），影响面小
- **描述**：任何拿到 `rawBytes` 的调用方改一个字节，`matches` 就会对同一输入判 Miss（或对碰撞输入判命中），守卫语义失效
- **建议**：返回 `this.bytes.clone()`，或把内部表示改成不可变视图；若确认只供内部使用，收窄为 `private`

### [轻微][存量] 合法集边界有两份常量，`maxLocalType` 只用于文案且无一致性测试

- **位置**：`f_jit/src/bytecode/FbcRuleSet.cj:47-48`、`:125-141`（12/14/19）vs `f_jit/src/base/LocalType.cj:200-207`（12/14/19）
- **来源**：存量（快照无 diff）
- **判据**：review-checklist §2「字面量复制」；§11「规格与实现漂移」
- **证据**：静态确定 —— `isLocalTypeInLegalSet` 完全委托 `LocalType.isLegal(code, verMajor)`（`FbcRuleSet.cj:74-76`），其注释还自称「边界判定的唯一事实来源」；`maxLocalType` 不参与任何判定，只出现在 `FbcReader.cj:257` 的错误文案里。V1 用 `LocalType.CLOSURE` 命名常量（`:129`），V2/V3 用裸 `14u16`/`19u16`（`:137`、`:141`）；`FbcReader_test.localTypeLegalSetBoundariesByVersion`（`:353-370`）断言的是 `LocalType.isLegal` 的边界，没有断言 `maxLocalType` 与它一致
- **描述**：改一处忘另一处时，拒绝信息会写「合法集 0–19」而实际按 0–20 判定（或相反），测试全绿。自定义 `FbcRuleSet(verMajor: 4, maxLocalType: 30, …)` 更极端：`maxLocalType` 声称 30，判定恒 false
- **建议**：删掉 `maxLocalType`，文案改用 `LocalType.name` 或按 `isLegal` 二分求上界；或保留字段但在 `FbcRuleSet.init` 里断言「`maxLocalType` 是 `isLocalTypeInLegalSet` 的最大真值」并补一条 0–255 全扫用例（现有用例可顺势扩展）

### [轻微][存量] `LocalTypes.validate` 两个三参重载函数体逐行同构

- **位置**：`f_jit/src/bytecode/LocalTypes.cj:104-115`（`verMajor` 版）与 `:124-136`（`rules` 版）；二参重载 `:100-102` 再转调前者
- **来源**：存量（快照无 diff）
- **判据**：review-checklist §2「只改类型名 / 只换数据来源」
- **证据**：静态确定（逐行比对）—— 两段都是「长度不符 → 18；逐槽按合法集不符 → 18」，差异只有谓词（`LocalType.isLegal(code, verMajor)` vs `rules.isLocalTypeInLegalSet(code)`）与文案里 `verMajor=` 的取值来源；而 `FbcRuleSet.isLocalTypeInLegalSet` 本身就是 `LocalType.isLegal(code, this.verMajor)`（`FbcRuleSet.cj:74-76`），对同一 major 语义完全一致。`verMajor` 版仓内只有 `LocalTypes_test` 在用（`FbcReader.cj:120` 走 rules 版）
- **描述**：三份入口、两份函数体；任一处补校验（例如新增「句柄槽不许两次装箱」）都要改两遍，漏一处就出现「加载器放行、单测拒绝」的漂移
- **建议**：抽一个私有 `validateCodes(isLegal: (UInt16) -> Bool, verMajor: UInt16)`，两个公开重载只传谓词；或删掉 `verMajor` 重载，测试改用 `FbcRuleRegistry` 规则集

### [轻微][存量] 十六进制格式化在本模块有 4 份，且 dump 用小写、诊断用大写

- **位置**：`f_jit/src/bytecode/InsnDecoder.cj:130-154`（本部分内，`internal`，大写）；`f_jit/src/compiler/Assembler.cj:335-348`（`private static hex`，大写）、`f_jit/src/compiler/Lexer.cj:906-916`（`internal static hex2`，大写）、`f_jit/src/compiler/CodeDump.cj:144-160`（`private static hex2`，**小写**）
- **来源**：存量（快照无 diff）；后三处为本部分范围外线索
- **判据**：review-checklist §2「表现形式不同的重复逻辑 / 字面量复制」
- **证据**：静态确定 —— 四处输出都是「两位十六进制」，前三处用 `match` 到 `'0'..'F'`（或 `'${digit(b/16)}${digit(b%16)}'`），`CodeDump` 的 `digit` 返回 `'a'..'f'`；`InsnDecoder` 的 `hex2` 还被 `FbcReader.hexOf32`（`FbcReader.cj:442-447`）包了一层 u32 版本
- **描述**：同一模块内十六进制的大小写有两个事实来源。诊断文本（`0x7C`）与字节码 dump（`0x7c`）直接对比时会看起来不一致，而没有任何注释说明这是有意的格式差异
- **建议**：只保留 `bytecode` 包内一个 `internal func hex2(UInt8)` + `hexOf32(UInt32)`，`Assembler`/`Lexer` 删除副本改为调用；`CodeDump` 若确实需要小写，改为显式参数 `hex2(v, upper: false)` 并在 dump 头部说明格式，别靠另一份实现承载差异

### [轻微][存量] 「严格升序 / 键唯一」检查在 NameTable 与 SiteTable 共 6 份

- **位置**：`NameTable.cj:136-138`（add）、`:186-188`（validate）、`:240-242`（decode）；`SiteTable.cj:112-114`（add）、`:170-172`（validate）、`:205-207`（decode）
- **来源**：存量（快照无 diff）
- **判据**：review-checklist §2「换控制流 / 字面量复制」
- **证据**：静态确定（逐函数体比对）—— 6 处都是「与前一条比较，不满足严格升序即 `rejectFormat`」，三种文案（「名字表键未严格升序或重复」「名字表键未严格升序」「站点表未严格升序」），谓词分别是 `!NameEntry.keyLess(prev, e)` 与 `off <= prev.off`；`decode` 已拒绝乱序，`FbcReader.load` 随后又调 `validate` 再查一遍（`FbcReader.cj:126-127`、`:136`）
- **描述**：键序是 `NameTable.lookup` / `SiteTable.lookup` 二分的正确性前提，却在 6 处各写一份、消息还不统一；将来加「允许相等键」之类的调整必须同时改 6 处
- **建议**：两个类各自抽一个私有 `checkKey(prev, cur)`（或包内泛型 `requireStrictlyAscending<T>(prev, cur, less, msg)`），`add`/`decode`/`validate` 共用；若固定走 `decode → validate`，`validate` 里可去掉键序检查并在文档写清前提，减少一遍 O(n) 扫描

### [轻微][存量] 测试 `m1RuleSetRejectsV2Product` 与 `m1RuleSetRejectsV2Header` 完全重复

- **位置**：`f_jit/src/bytecode/FbcReader_test.cj:252-257` 与 `:336-344`
- **来源**：存量（快照无 diff）
- **判据**：review-checklist §2（用例级重复，非夹具代码）
- **证据**：静态确定 —— 两段都构造同一份 v2 产物，`FbcHeader.read(ByteReader(raw))` 后调用 `expectRejectRules(raw, h, FbcRuleRegistry.V1)`；后者只多一条 v3-vs-v2 断言（`:342-343`）。前者的用例名（`V2Product`）与后者（`V2Header`）描述的是同一件事
- **描述**：同一断言跑两遍，用例数虚高；失败时无法从用例名区分是哪条契约坏了（两者都只证明「主版本不匹配即拒绝」）
- **建议**：合并为一条 `ruleSetRejectsHigherMajorHeader`，把 v2→v1 与 v3→v2 两个方向都放进去

### [轻微][存量] `FbcWriter` 的 `ArrayList` import 未使用

- **位置**：`f_jit/src/bytecode/FbcWriter.cj:18`
- **来源**：存量（快照无 diff）
- **判据**：review-checklist §1「未使用的 import」
- **证据**：静态确定 —— 全文 `ArrayList` 只出现在 `:18` 的 import 与 `:95` 的注释文本里；实现全程用 `Array<UInt8>`（`:40-43`、`:104`）
- **描述**：旧实现（逐字节进 `ArrayList` 再 `toArray`）的残留；注释保留历史说明没问题，import 应删
- **建议**：删除 `:18`

### [轻微][存量] `JsonConst_test` 导入 `JsonNull` 未使用

- **位置**：`f_jit/src/bytecode/JsonConst_test.cj:20`
- **来源**：存量（快照无 diff）
- **判据**：review-checklist §1「未使用的 import」
- **证据**：静态确定 —— 全文 `JsonNull` 只此一处；用例只匹配 `JsonObject` / `JsonArray`
- **描述**：无害但会掩盖「JSON null 常量是否被覆盖」的问题——该文件确实没有 `JsonNull` 用例
- **建议**：删除 import；若要补 null 用例，则保留并新增 `addJson('null')` 的实例化断言

### [轻微][存量] `jsonInstantiatesOnceAndReusesIdentity` 的断言只比内容，不验证「同一对象」

- **位置**：`f_jit/src/bytecode/JsonConst_test.cj:58-84`（关键 `:79`）
- **来源**：存量（快照无 diff）
- **判据**：review-checklist §11「契约与实现不符」（用例名/注释承诺的契约没有被断言）
- **证据**：静态确定 —— 用例名与注释写「跨访问同 ID」「同一条目重复访问取到同一对象：同一 JSON 文本、且内容未被重建」，但断言是 `@Assert(a.toString(), b.toString())`，只证明两份 `toString()` 相等；两次 `instanceAt` 若各自重新解析，也会通过
- **描述**：`ConstRegistry` 的「加载期只解析一次」是性能与对象身份契约（`instantiateSharesDagSubstructures` 就是对 List 用「改子结构、另一侧可见」来证明同一对象）。本用例是 JSON 版对应物，却是弱断言，回归时不会报警
- **建议**：沿用 `FbcReader_test.cj:619-642` 的做法——对同一个 `hid` 取两次，向其中一个 `JsonObject` 写入/删除键，断言另一个可观察到；若语言提供引用相等运算，也可直接比较引用

### [轻微][存量] `crc32OfPayload` 与 `build` 各算一遍 CRC，且前者仓内零引用

- **位置**：`f_jit/src/bytecode/FbcWriter.cj:88-90` 与 `:118-131`
- **来源**：存量（快照无 diff）
- **判据**：review-checklist §2「同一换算在两处各写一遍」；§1 信息项（public 无引用不判死代码）
- **证据**：静态确定 —— 两处都是 `Crc32.isoHdlc.compute(...)`：一处对 `payload()`，一处对 `build` 里同一个 `body`；`grep crc32OfPayload` 只有定义（`:88`）与 `:95` 的注释，无任何调用点（含测试）
- **描述**：CRC 覆盖范围（code + const + site + name）是写方与读方必须一致的冻结口径；现在它在 `crc32OfPayload` 与 `build` 各有一份，改一处就漂移。同时 `crc32OfPayload` 是对外 public 却无人使用，读者无法判断哪条是权威实现
- **建议**：让 `build` 调用统一的内部 `crcOf(code, consts, site, name)`（配合 O1 改成流式），`crc32OfPayload` 作为薄包装保留；若确认外部无依赖，删除该公开方法需用户拍板

## 优化可行性方案

> 不是缺陷，是"还能更好"。本部分没有 `cjprof` / `cjpm bench` 数据（`scope.md` 给的 `docs/LocalMode*.md` 与本部分路径无关），以下全部为无基线方案，不进 `todo.md` / `tasks.md`。

### [堆内存] `FbcWriter.build` 的峰值是 2 份完整载荷，且逐字节拷贝两趟

- **现状**：`payload()` 先分配 `Array<UInt8>(total)` 并把四段拷进去（`FbcWriter.cj:98-115`），`build()` 再分配 `head + body` 并把 `body` 再拷一遍（`:135-145`）；`crc32OfPayload()`（`:88-90`）另走一遍 `payload()`。单次 `build` 峰值 ≈ 2×载荷 + 0.5 KB 头，载荷 1.9 KB 时可忽略，随单元线性放大
- **方案**：把 `payload()` 改成「先算总长 + 分段喂 CRC」的两段式：先向 `Crc32` 逐段 update（需确认 `f_util.Crc32` 是否支持分段；只支持一次性 `compute` 时退化为「算完即弃」），再一次性分配最终 `out`，把目录头与四段直接写入；`crc32OfPayload` 复用同一实现，删掉第二条路径
- **预期**：峰值从 2× 降到 1×，拷贝从 2 趟降到 1 趟
- **代价**：依赖 `Crc32` 的增量 API；`build` 的控制流从「拼 body → 拼 out」变成「算长 → 写头 → 写段」，可读性略降
- **验证**：`cjpm bench -O2` 编译 1 MB 源码产物，20 轮取中位数，量 `getAllocatedHeapSize()` 峰值与 RSS 峰值，改前改后同输入
- **证据状态**：无基线（待验证，不进 tasks）

### [CPU] `InsnDecoder.decode` 每条指令分配一个 `operands` 数组，加载期还对同一函数体解码两遍

- **现状**：`decode` 对每条指令分配 `Array<UInt8>(opsLen)`（`InsnDecoder.cj:71-74`），`len = 1` 时是零长数组；`FbcReader.checkInstructionSet`（`FbcReader.cj:270-293`）与 `checkSiteCoverage`（`:320-340`）各自遍历全部函数体一次 ⇒ 加载一份单元产生 2N 次解码与 2N 次数组分配（N = 指令数）
- **方案**：给 `InsnDecoder` 增加「就地读操作数」的静态方法（`u8At(code, off, i)` / `u16At` / `i32At`，不物化 `operands`），`DecodedInsn` 只在需要反汇编/诊断时物化；两次扫描合并为一个循环（同时校验指令集与 `SET_SITE` 覆盖），或用一次 `decode` 结果供两处使用
- **预期**：加载期分配从 2N 降到 0（或 N），大单元 GC 压力与解码耗时下降
- **代价**：`DecodedInsn` 从「纯数据」变成持有 `code` 引用，调用点需要改；合并扫描会改变拒绝顺序（指令集错误 vs site 未覆盖谁先报），需要用现有 11 类拒绝面用例锁定文案顺序
- **验证**：`cjprof record` 跑 `FbcReader.load` 一份 10 万指令的合成单元，看 `decode` 自耗时占比与 GC 次数；改后同输入对照，取中位数
- **证据状态**：无基线（待验证，不进 tasks）

### [CPU] 加载期目录/名字表查找是线性的，整体 O(n²)

- **现状**：`FuncDir.add` 每条都调 `find`（线性，`FuncDir.cj:163-177`）⇒ 解析 N 条目录 O(N²)；`NameTable.validate` 每个名字条目再线性扫一遍目录（`NameTable.cj:192-197`）。N = 1 万函数时约 5×10⁷ 次比较，N = 10 万时约 5×10⁹ 次
- **方案**：`FuncDir` 内部维护 `HashMap<UInt32, Int64>`（fnId → 下标）供 `find`/`get`/`add` 使用（`add` 后同步插入），解析完即可丢弃或保留；`NameTable.validate` 改用 `dir.get(fnId).nLocals`（同时解决发现 #2 的反查）
- **预期**：目录解析从 O(N²) 降到 O(N)，名字表校验从 O(名字数×函数数) 降到 O(名字数)
- **代价**：每个目录多一张 map（N 项，约 24–48 B/项），内存换时间；`FuncDir` 的 `find` 返回语义不变
- **验证**：构造 1k / 10k / 100k 函数的合成 `.fbc`，量 `FbcReader.load` 耗时曲线（应接近线性）；`cjpm bench -O2`，每档 20 轮取中位数
- **证据状态**：无基线（待验证，不进 tasks）

### [堆内存] `Fingerprint.normalizeSource` 对每份源码产生 3 份瞬时副本

- **现状**：`ArrayList<UInt8>()` 逐字节追加（含扩容拷贝）→ `toArray()` 再拷一份 → `String.fromUtf8` 再建一份；输入 1 MB 源码时峰值约 2–3 MB 额外副本（`Fingerprint.cj:90-108`）
- **方案**：先 `Array<UInt8>(bs.size)` 预分配（结果长度 ≤ 输入长度），单趟写入并记录实际长度，最后 `String.fromUtf8(out[0..n])`（若切片会拷则直接 `out` + 长度参数）；`sourceKey` 里再 `unsafeBytes()` 也可省掉（直接对 `out` 取 FNV）
- **预期**：临时副本从 3 份降到 1 份，规范化 + 取指纹的分配量约减半
- **代价**：需要处理「无 CR」时是否直接返回原串（可再省一次分配，但会让 `sourceKey` 与返回值的别名关系变化）
- **验证**：对 1 MB / 10 MB 源码各跑 20 轮 `normalizeSource` + `sourceKey`，量 `getAllocatedHeapSize()` 与单次耗时中位数，`-O2`
- **证据状态**：无基线（待验证，不进 tasks）

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 加载期热点在「两次全函数体解码 + 每指令分配」，而非段拷贝 | `FbcReader.cj:270`、`:320`；`InsnDecoder.cj:71` | `decode` 自耗时占比、GC 次数 | `cjprof record` 加载 10 万指令合成单元，对比 1 万指令 |
| 2 | `NameTable.validate` 的 O(名字数×函数数) 在真实单元已达毫秒级 | `NameTable.cj:192-197` | 加载耗时随规模曲线 | 1k/10k/100k 函数 + 每函数 5 个命名槽的合成单元，分段计时 |
| 3 | `FbcWriter.build` 的 2× 载荷峰值在大单元上可测 | `FbcWriter.cj:98-145` | 峰值 RSS / heapUsed 与载荷大小的关系 | 1 MB / 10 MB 产物，`getAllocatedHeapSize()` 前后差 + RSS |
| 4 | `normalizeSource` 的 ArrayList 扩容是编译期分配大头之一 | `Fingerprint.cj:92-107` | 该函数分配量与总分配占比 | 1 MB 源码 bench + `cjprof heap` |
| 5 | `OpInfo` 的 `Array<struct>`（含 `String` 字段）在解码循环里是否有缓存不友好 | `OpInfo.cj:119`；`InsnDecoder.cj:60` | cache miss / 自耗时占比 | 平台 profiler 跑 1e7 次 `decode` |
| 6 | `Crc32` 是否支持分段 update（决定 O1 能否做到 1× 峰值） | `FbcWriter.cj:89`、`:131` | `f_util.Crc32` 的 API 能力 | 查 `f_util` 源码/文档，确认有无 `update`/`final` |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_jit/src/bytecode/FbcReader_test.cj` | .cj | ✅ | S2.13/14/15 用例：版本分派、11 类拒绝面、加载期实例化；用例重复 #F10，`expectReject` 未断言 site（同族 helper 有） |
| 2 | `f_jit/src/bytecode/FbcRuleSet.cj` | .cj | ✅ | 规则集与注册表；`maxLocalType` 双源 #F6；`isInstructionLegal`/`isRegistryDependent` 均被 loader 使用 |
| 3 | `f_jit/src/bytecode/FbcWriter.cj` | .cj | ✅ | 容器组装；未使用 import #F11；`crc32OfPayload` 双份 #F14；峰值 2× 载荷（O1） |
| 4 | `f_jit/src/bytecode/Fingerprint.cj` | .cj | ✅ | 三类指纹口径 + `DedupGuard`；二次校验未接线 #F1、`sourceKey` 未接线 #F3、`rawBytes` 别名 #F5 |
| 5 | `f_jit/src/bytecode/Fingerprint_test.cj` | .cj | ✅ | 5 组金值/负例；只覆盖守卫本身，未覆盖管线接线（见 #F1） |
| 6 | `f_jit/src/bytecode/FuncDir.cj` | .cj | ✅ | 26 B 目录项；`codeOff/codeLen` 用减法防溢出（正确）；`find`/`add` 线性（O3） |
| 7 | `f_jit/src/bytecode/FuncDir_test.cj` | .cj | ✅ | 往返、重复 fnId、两类越界、entryFn；正向对照齐全 |
| 8 | `f_jit/src/bytecode/InsnDecoder.cj` | .cj | ✅ | 解码 + 操作数读取；每指令分配（O2）；`hex2` 基座 #F8 |
| 9 | `f_jit/src/bytecode/InsnDecoder_test.cj` | .cj | ✅ | 定长/rel32 正负偏移/RSVD+FORBID/截断/取操作数越界 |
| 10 | `f_jit/src/bytecode/JsonConst_test.cj` | .cj | ✅ | JSON 常量用例；未使用 import #F12；identity 断言弱 #F13 |
| 11 | `f_jit/src/bytecode/LocalTypes.cj` | .cj | ✅ | 槽表；三重重载 #F7；边界统一委托规则集 |
| 12 | `f_jit/src/bytecode/LocalTypes_test.cj` | .cj | ✅ | 槽读写/长度/版本边界/规则集全扫；`:188` 注释写「4..14」而用例覆盖 4..19（M3 的 15–19） |
| 13 | `f_jit/src/bytecode/NameTable.cj` | .cj | ✅ | 名字表；#F2 反查与 `unused` 技巧；键序检查 #F9；`decode` 先按剩余字节校验 count（正确） |
| 14 | `f_jit/src/bytecode/OpInfo.cj` | .cj | ✅ | 256 项全表；脚本复算 `callHostRowAndM1RowsUnchanged` 的 FNV 金值一致；可写表 #F4 |
| 15 | `f_jit/src/bytecode/OpInfo_test.cj` | .cj | ✅ | 表规模/禁区/代表项/操作数长度/类别码/FNV 金值；金值经复算通过 |
| 16 | `f_jit/src/bytecode/Reject.cj` | .cj | ✅ | 两个统一拒绝入口（18 / 14），被 bytecode 包广泛使用，无问题 |
| 17 | `f_jit/src/bytecode/SiteNameTable_test.cj` | .cj | ✅ | site 前驱查询/乱序/越界/冻结；name 键序/坏键/UTF-8/空表 |
| 18 | `f_jit/src/bytecode/SiteTable.cj` | .cj | ✅ | 站点表；二分前驱查询（含负 site）正确；键序检查 #F9 |
| 19 | `f_jit/src/compiler/A4Frontend_test.cj` | .cj | ✅ | P1-1…P1-9 行为用例；依赖同包 `SourceCompiler`/`LowererM2_test.entryBytes`（范围外） |
| 20 | `f_jit/src/compiler/A5MapKey_test.cj` | .cj | ✅ | 常量 Map 的 Float64/Decimal 键命中与既有键型回归 |

合计：`.cj` 20 个 / `.md` 0 个 / 共 20 个，全部读完。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 4 | #F1（契约未接线）、#F2（边界 + 非契约异常）、#F3（口径未生效）、#F13（断言不指向契约）；无注入/敏感数据面 |
| §1 死代码 | 2 | 已逐个 `private`/`internal` 符号全仓搜引用：`payload`/`nameAt`/`need`/`oneEntryTable`/`compile`/`errText*` 均有调用；`internal` 的 `hex2`/`hexOf32`/`rejectFormat`/`rejectRegex` 均有调用；无 `protected`。`public` 按硬原则一不判：`crc32OfPayload`、`strBytesSize`、`rawBytes`、`isHandleSlot`、`selfCheckOk` 仓内无引用（或仅测试）仅作信息，不记死代码；命中的 2 条是未使用 import |
| §2 重复逻辑 | 6 | 已把 20 个文件内每个函数体压成「输入→输出→副作用」两两比对，并按相同错误文案/常量跨文件搜：命中 #F6（边界常量双份）、#F7（validate 双重载）、#F8（hex 4 份，大小写不同）、#F9（升序检查 6 份）、#F10（用例重复）、#F14（crc 双路径）；`SiteTable`/`NameTable` 的 add/decode 结构相似但元素与校验面不同，按「差异是业务要求」保留不判 |
| §3 空实现 | 0 | 无空函数体（`FbcWriter.init() {}` 是合法默认构造）、无 TODO/FIXME/UnsupportedException；测试里的 `catch` 都紧跟 `rejected` 断言，不吞错 |
| §4 栈溢出 | 0 | 本部分无递归/间接递归；段结构与容器均为显式循环，无自引用对象图 |
| §5 OOM | 0 | 三处段解码都先按剩余字节校验 `count`（`NameTable.cj:235`、`SiteTable.cj:200`、`FbcReader.cj:249`），无按不可信长度预分配；载荷规模受输入文件约束，峰值问题见 O1/O4 |
| §6.1 热点瓶颈 | 0 | 无 profile / bench 数据，热点不成立；6 条线索已写入「待验证假设」 |
| §6.2 大粒度锁 | 0 | 本部分无 `synchronized`/`Mutex`/锁对象 |
| §6.3 并发串行 | 0 | 无 `spawn`/`Future`/任务提交 |
| §6.4 低效算法 | 1 | #F2 的「每名字条目线性扫目录」；另有 O3 的目录 `find` 线性（无基线，列入优化方案） |
| §7 降堆内存方案 | 2 | O1（build 2× 载荷）、O4（normalizeSource 3 份副本），均为无基线 |
| §8 降 CPU 方案 | 2 | O2（decode 分配 + 双扫描）、O3（目录/名字表 O(n²)），均为无基线 |
| §9 local mode 可行性 | 0 | `payload()`/`normalizeSource()` 的临时数组都作为返回值逃逸，不满足「函数内创建、函数内释放」；无峰值内存数据，收益无法证明 |
| §11 现有代码的 BUG（存量） | 2 | #F1、#F2；其余边界（codeOff/codeLen 减法、count×SIZE 校验、`off >= codeLen`、`line/column ≥ 1`、`rel32` 基准）逐条核对无缺陷 |
| §12 并发安全与锁粒度 | 1 | #F4（`OPCODE_TABLE` 是进程级共享可变数组，当前无写点）；其余为无状态 static 函数或 per-unit 可变对象，无共享路径 |
| §14 功能完备性与 README 覆盖 | 2 | #F1、#F3 均为「设计承诺但生产路径未接线」；本部分无 `.md`，README 覆盖维度不适用 |
| 文件覆盖（§13 等） | 20/20 | 20 个 `.cj` 全部逐行读完；本部分无 `.md`，§13 不适用 |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 0 |
| 一般 | 2 |
| 轻微 | 12 |
| 优化方案（堆内存 / CPU） | 2 / 2 |

## 总评

本部分是 `.fbc` 容器的核心读写面，序列化/反序列化的**边界校验总体扎实**：`count` 先按剩余字节校验、`codeOff/codeLen` 用减法防溢出、`crc32` 覆盖四段、`rel32` 以「下一条指令」为唯一基准、opcode 表有 256 项自检 + FNV 金值（本部分用脚本复算了 `10437089730419021315`，与用例一致）。没有严重缺陷，也没有栈溢出、无界增长或锁问题。

主要风险不在解析器，而在**「设计口径」与「生产路径」的接线**：#F1（D8 的命中后二次校验没有接，`DedupGuard` 只被测试引用）与 #F3（`sourceKey` 的换行规范化没被 `compile(source)` 使用）都是「能力已写好、入口没接」；这类问题不会让测试变红，但会让文档承诺与运行时行为长期分叉。其次是 #F2：`NameTable.validate` 里为取一个已经存在的 `nLocals` 做 O(n) 反查，并用 `let _ = unused` 压掉告警，顺带把「types 短于 dir 就抛非 18 异常」的边界暴露在公开方法上。

其余 12 条轻微项分两类：一类是重复实现（hex 4 份、升序检查 6 份、validate 双重载、边界常量双份、crc 双路径），另一类是测试质量问题（identity 弱断言、重复用例、两个未使用 import）。建议排期：先修 #F1 / #F2（一般），其余随重构收敛；O1–O4 需要先补基线数据再决定是否进 tasks。

本部分 14 条发现全部为存量（工作区快照无 diff），是否纳入修复待用户决定。
