# f_jit 模块审查报告（模块第 1/38 部分）

- **审查日期**：2026-11-28
- **模块路径**：`f_jit`（本部分 4 个文件、0 个 `.cj`：`README.md`、`README_en.md`、`doc/asm-inline.md`、`doc/concurrency-audit.md`）
- **基线**：工作区快照（`120fd2542`，`git diff` 为空）⇒ 全部问题来源记为「存量」
- **审查重点**：动态调用/桥接正确性（typecode 分支表）、句柄与资源生命周期、并发安全、递归与栈溢出、死代码、重复逻辑。本部分只有文档，因此把文档里每条可核对的承诺逐条对照 `src/` 取证（§13 / §14）
- **报告版本**：v1（分部分报告，供主 Agent 合并；不写 `docs/review/`）

## 发现

### 1. [严重][存量] 深度递归没有任何上限，文档却把它当普通能力，且承诺「JIT 只是加速层、语义不变」

- **位置**：`f_jit/README.md:375-392`（§6.2 递归）、`:7-9`（语义承诺）、`:255-258`（§3⑥「其余错误码按 `JitException` 抛出」）、`:603-611`（§8 已知限制，未列该限制）；`f_jit/README_en.md:403-419`、`:8-11`、`:642-651`
- **来源**：存量（`git blame` 2026-11-13 `59b5fce057`）
- **判据**：review-checklist §4（无界递归 / 深度由输入决定）+ §14.1（缺关键限制段落）+ §11（契约与实现不符）
- **证据**：静态确定 ——
  - 文档自己的示例就是**非尾递归**：`{ n: Int64 => if (n <= 1) { 1 } else { n * recursive(n - 1) } }`（`README.md:380`），深度由入参决定；
  - 解释器：`src/runtime/Interp.cj:603-619` 的 `CALL_FUNC` 直接 `this.run(UInt32(fid), args, ctx)` **自递归**、`:651-652` 的 `CALL_CLOSURE` 走 `runClosure` 自递归 ⇒ 每层一个仓颉栈帧；
  - 机器码：`src/backend/X86Lower.cj:437-455` `callFunc` 发射经函数入口表的**间接 `call`**（`FF /2`，`[fnTable+8*fid]`），aarch64 同构 ⇒ 每层一条原生栈帧；
  - 没有任何深度闸门：全仓 `MAX_DEPTH|callDepth|recursionDepth|StackOverflow|递归深度` 0 命中；`OP_STACK_GUARD`(0x07) 在 x86 上发射为空（`X86Lower.cj:764`），`LOOP_BACK` 处的守卫只比「操作数栈保留区」（`X86Lower.cj:1020-1032`），与调用深度无关；
  - 平台口径（官方文档 `cangjie-doc/1.3.0/dev-guide/source_zh_cn/Appendix/runtime_env.html`）：仓颉线程默认栈 **128 KB**（`cjStackSize`），native stack overflow 检查**默认不开启**；同目录 `FFI/cangjie-c.html` 明确「运行时无法感知 C 侧实际用栈」——机器码帧与 C 帧同属运行时不可见帧，栈扩容救不了。
  - 崩栈的具体层数需实测（取决于 `cjStackSize` 与每帧大小），但「无上限」是静态事实。
- **描述**：`recursive` 是文档化能力（§6.2/§6.3 两处示例），却没有深度上限、也没有把栈溢出映射成错误码。深度由宿主或外部输入决定时（`recursive(n)`，n 来自请求），机器码路径以 SIGSEGV 终止**整个宿主进程**，不产生 `JitException`；解释器靠运行时栈扩容能撑更久，但同样不是无限。两条引擎的失败点不同，直接违背「语义唯一权威是解释器 / JIT 只是加速层」；调用方也没有任何降级手段。
- **建议**：① 文档 §8 增一条「递归深度不设上限：非尾递归的可用深度受线程栈限制，超出后不是 `JitException` 而是进程崩溃；需要保护的宿主应自行限制输入规模或加深度预算」，并在 §6.2 明确「尾递归不增长栈」只覆盖尾位置；② 代码侧（属 `Interp` / 后端部分）给 `CALL_FUNC` / `CALL_CLOSURE` 加帧计数，超限抛 `ErrCode.STACK_GUARD(15)` 或新码，并允许 `CallContext` 配预算；③ 把「语义不变」限定为「除宿主级故障（栈溢出 / OOM）外」。

### 2. [一般][存量] 「API」表把两个 `protected` 类型当成公开 API，反向又漏掉一个 `public` 类型

- **位置**：`f_jit/README.md:63`（`CompileCache`，成员写 `lookup` / `reset` / `runs`）、`:67`（`JitReport`）；`f_jit/README_en.md:67`、`:71`；代码 `f_jit/src/CompileCache.cj:30`（`protected class CompileCache`）、`f_jit/src/JitReport.cj:36`（`protected class JitReport`）、`f_jit/src/runtime/RuntimeState.cj:34`（`public class RuntimeState`，README 全文 0 命中）
- **来源**：存量（`git blame` 2026-10-22 起的 §2 表）
- **判据**：review-checklist §14.2（公开 API 覆盖）+ §1 可见性表（顶层 `protected` 仅本模块可见）
- **证据**：静态确定 —— 两个顶层类型的修饰符都是 `protected`，模块外既无法命名类型、也无法调用成员；`CompileCache.reset`（`:183`）/ `runs`（`:176`）全仓只被 `*_test.cj` 引用，`lookup`（`:53`）只被 `CompilePipeline.cj:61/97` 使用。反向地，`RuntimeState` 出现在 `HandleTable.*With`、`CallMarshal.init` 等 public 签名里，却没进「其他公开 API」索引。
- **描述**：接入方按 §2 表写 `CompileCache.lookup(...)` 会直接编译失败；而一个下游可见的类型完全没有文档，覆盖口径不一致。README 末尾清单（`:615`）也没有这两个 `protected` 类型，文档自身不自洽。
- **建议**：§2 表加「可见性」列，把这两行标成「模块内部（诊断用）」；若要对外观测缓存，再把 `CompileCache` 提为 `public` 且只开放 `lookup` / `runs`，`reset()` 保持 `internal`（清空全局缓存不应给宿主）。`RuntimeState` 在索引里补一行并注明「线程私有运行期状态，不是宿主 API」。

### 3. [一般][存量] FAQ Q1 / §6 的句柄 tag 表与两套编码都不符，`Closure` 与 `Any` 同为 12 自相冲突

- **位置**：`f_jit/README.md:503-511`（Q1 的 tag 列表）、`:310-311`（§6 表 `Closure` 句柄 12 / `Any` 句柄 12）、`:450`（「装箱 12」）；`f_jit/README_en.md:542-551`、`:329-330`、`:486`
- **来源**：存量（`git blame` 2026-10-22 `1a4d246fcc`、2026-10-27 `5c5dfb6ec2`）
- **判据**：review-checklist §13（文档与实现不符）；本部分重点「typecode 分支表」
- **证据**：静态确定 —— 槽 tag 由 `HandleTable.append(ctx, obj, tok)` 写入、`tok` 来自 `tokenOf`，取值是 `TypeToken`（`src/base/TypeToken.cj:37-61`）：LIST 1、MAP 2、STRING 3、DECIMAL 4、DATETIME 5、DURATION 6、RANGE 7、REGEX 8、CLOSURE 9、HOST_CLOSURE 10、HOST_OBJECT 11、ANY 12；`HandleTable.cj:728` 注释明写「世界内宿主类实例登记（tag 恒 **11**）」。文档那串数字更接近 `LocalType`（`src/base/LocalType.cj:36-77`：STRING 4、DECIMAL 5、DATETIME 6、DURATION 7、RANGE 8、REGEX 9、LIST 10、MAP 11、CLOSURE 12、HOST_CLOSURE 13、HOST_OBJECT 14、ANY 15、JSON 16–19），但 `Decimal` / `Range` / `Duration` 各差 1（漏了 DATETIME 这一项）、`Any` 写成 12、`DateTime` 完全没出现；按 `LocalType` 读则 `Closure=12` 与 `Any=12` 同码，按 `TypeToken` 读则 `String` / `List` / `Map` / `tag 14` 全错。
- **描述**：这是「句柄怎么解释」的唯一公开说明，机器码侧 typecode 分支（`H_TAG_OF` / `isType` / `fetch*`）全按 tag 分派；差 1 位就足以把 JSON 节点当宿主对象、把闭包当 Any。表内两个 12 说明它是被改过一半的旧编号。
- **建议**：Q1 与 §6 统一按「槽 tag = `TypeToken` 值」写，并逐个注符号（`TypeToken.STRING` / `HOST_OBJECT` / `ANY`），旁注「`LocalType` 是另一套：STRING 4 … HOST_OBJECT 14、ANY 15、JSON 16–19」；§3③ 已把 tag 定义为句柄字段，术语要区分「方言类型码 / 句柄 tag」。

### 4. [一般][存量] 英文版把裸 `close()` 写成「返回 false」，与 `close(): Unit` 及中文版相反

- **位置**：`f_jit/README_en.md:53-54`；对照 `f_jit/README.md:50`；代码 `f_jit/src/JitFunction.cj:522-525`、`:227-262`
- **来源**：存量（`git blame` 2026-10-27 `5c5dfb6ec2`）
- **判据**：review-checklist §13（中英不同步、两版结论相反；API 与源码不符）
- **证据**：静态确定 —— `public func close(): Unit { let _ = this.close(0) }`（`JitFunction.cj:522-525`）；只有 `close(timeoutMs): Bool`（`:227`）在未排空时把 `state` 复位为 0 并 `return false`。中文版「不等待在飞调用，丢弃排空结果；未排空时返回 false」是准确的。
- **描述**：英文版给用户一个不存在的返回值（`if (!f.close())` 在仓颉侧直接编译失败），并与中文版的可观测行为相反。
- **建议**：英文改为 "A bare `close()` does not wait: it is equivalent to `close(0)`, discards the drain result and leaves the unit usable. Use `close(timeoutMs): Bool` to drain and observe `false` on timeout."；§2 表并列写清两个重载的返回类型。

### 5. [一般][存量] `asm-inline.md` 的 ABI 表把 `hwTop` 的 ctx 偏移写错（+16 应为 +32）

- **位置**：`f_jit/doc/asm-inline.md:80`；代码 `f_jit/src/runtime/JitContext.cj:115-122`；对照 `f_jit/README.md:250-251`
- **来源**：存量（`git blame` 2026-10-21 `3b82a1c329`）
- **判据**：review-checklist §13（文档与实现不符）+ §2（字面量复制导致的漂移）；本文本身就是「ABI 契约」
- **证据**：静态确定 —— `OFF_ERR_CODE 0 / OFF_SITE 8 / OFF_HW_BASE 16 / OFF_HW_CAP 24 / OFF_HW_TOP 32 / OFF_FN_ID 40 / OFF_FLAGS 48 / OFF_DBG_BASE 56`；`+16` 是 `hwBase`。README 同一张表（`:251`）顺序是对的，两份文档已经漂移。表里还漏了 `hwBase` / `hwCap` / `flags`。
- **描述**：§4.5 要求汇编块「不得触碰句柄表或窗口（`ctx.hwTop`）」，校验器若照此表读 `[r15+16]`，实际读写的是窗口基址——一旦实现，窗口记账会被静默改坏且无法归因。
- **建议**：删掉这张手工拷贝的表，改为「以 `JitContext.OFF_*` 为唯一来源」；至少修正 `hwTop=[r15+32]`，补 `hwBase=+16`、`hwCap=+24`、`flags=+48`。

### 6. [一般][存量] Int64 的 `/`、`%` 零除错误码写成 3（实现是 1 与 2）

- **位置**：`f_jit/README.md:299`（Int64 行「`/`、`%` 零除 → 3」）；`f_jit/README_en.md:318`
- **来源**：存量（`git blame` 2026-11-13 `59b5fce057`）
- **判据**：review-checklist §13（错误码与实现不符）
- **证据**：静态确定 —— `src/base/ErrCode.cj:35-36`（`DIV_ZERO = 1`、`MOD_ZERO = 2`，3 是 `OVERFLOW_I64`）；`src/runtime/Interp.cj:336`（`DIV_ZERO`）、`:346`（`MOD_ZERO`）；`src/runtime/Helpers.cj:570`（`failWith(ErrCode.DIV_ZERO)`）。
- **描述**：错误码是对外契约（`JitException.code`）；按文档写 `e.code == 3` 处理除零会走进溢出分支。同一行 f64 的「÷0 报 1」又正好是真正的 `DIV_ZERO`，更容易误导。
- **建议**：改为「`/` → 1（`ERR_DIV_ZERO`）、`%` → 2（`ERR_MOD_ZERO`）、溢出 → 3」。

### 7. [一般][存量] 并发审计声称「全部 static 已逐个确认保护方式、无可达并发缺陷」，但 2 个进程级计数器是无同步 RMW

- **位置**：`f_jit/doc/concurrency-audit.md:3`、`:8`；代码 `f_jit/src/bytecode/ConstRegistry.cj:62` / `:455`、`f_jit/src/backend/CodeBuffer.cj:28` / `:156` / `:179`
- **来源**：存量（`git blame` 2026-11-27 `fbf97fdbcc`）
- **判据**：review-checklist §12.1（共享可变状态无保护）+ §13（结论与代码不符）
- **证据**：静态确定 —— `public static var regexCompileCount: Int64` 在正则字面量编译路径做 `x = x + 1`；`private static var flushCounter: Int64` 在 `flushICache` 做同样的事。两者都无锁、无原子；`CompileCache` 只对**同键**去重，不同源码的编译是并行的（审计自己的 `ConcurrencyMatrix_test`、README Q8 都以此为前提），编译与 JIT 发射都会并发进入。与审计已列并修复的 H2（`NativeAssets.allocs/frees`）完全同类，后果同样是「只影响测试断言与诊断计数」。
- **描述**：方法段写「`src/` 下全部 25 个进程级 `static let/var`，逐个确认保护方式（锁 / 原子 / 不可变快照 / TLS / 定长数组）」，结论写「没有发现可达的并发缺陷」。这两个计数器既不在 H1–H6 里，也没有任何保护方式，说明扫描口径与实际不符。按 H2 的判准，它们应是第七条隐患。
- **建议**：① 两个计数器改 `AtomicInt64`（与 H2 同修法）；② 审计补一句「诊断计数允许丢计数」，并把扫描口径（哪些 static 计入）写清；③ 结论改为「未发现影响运行时正确性的可达缺陷；诊断计数存在丢计数（已列明）」。

### 8. [轻微][存量] 内嵌代码锚点系统性过期（README 6 处、asm-inline 5 处），Q5 片段还是旧签名

- **位置**：`f_jit/README.md:504`、`:516`、`:537`、`:541`、`:552-562`、`:569`；`f_jit/README_en.md:547`、`:556`、`:576`、`:580`、`:592-603`、`:612`；`f_jit/doc/asm-inline.md:61`、`:329`、`:337`
- **来源**：存量（`git blame` 2026-10-21 ～ 2026-10-27）
- **判据**：review-checklist §13（文档过期 / 示例不能用）；同根因合并为一条
- **证据**：静态确定 ——

| 文档 | 写的锚点 | 实际 |
| --- | --- | --- |
| `README.md:504` | `HandleTable.cj:486` `append` | `HandleTable.cj:689` |
| `README.md:516` | `HandleTable.cj:567` `getAny` | `HandleTable.cj:775` |
| `README.md:537` | `JitFunction.cj:477-487` `releaseReturnHandle` | `JitFunction.cj:703-716` |
| `README.md:541` | `capacityLimit = 1048576`（`:92`） | `HandleTable.cj:159-169` |
| `README.md:552-562` | `finally`（`454-467`） | `JitFunction.cj:680-693` |
| `README.md:569` | `CallMarshal.cj:216-269` | `unboxClosure` 在 `:256-275`（`promoteClosureGraph` 285 起） |
| `asm-inline.md:61` | `X86Lower.cj:68 appendBytes` / `:101 finish()` | `:75` / `:158` |
| `asm-inline.md:61`、`:329` | `A64Emitter.cj:118 finish()` | `:166` |
| `asm-inline.md:329` | `X86Lower.cj:68 appendBytes` | `:75` |
| `asm-inline.md:337` | `X86Lower.cj:45–56 hasSse41`、`:445 降级` | `:62`、`:526-532` |

  Q5 片段同时过期：`helpers.size` → `helperTable.size`、`IterTable.clearAll()` → `clearAll(rs)`、`HandleTable.resetWindow(-1)` → `resetWindow(rs, -1)`、`JitContext.free(ctx)` → `free(ctx, rs)`。仍准确的锚点：`HelperCore.cj:77-83`、`Helpers.cj:1010-1021`、`CodeBuffer.cj:99/112/117/131/149`、`X86Compiler.cj:46/49`、`doc/spec/f-jit-m1/verify.md:69`。
- **描述**：锚点是「文档说的就是代码」的凭据；按 `HandleTable.cj:486` 会读到别的东西，按 `:92` 会读到类注释。Q5 代码块照抄编译不过。文档随两次重构整体后移，锚点没跟上。
- **建议**：只写「文件 + 符号名」，不写行号；或加一条与 `scripts/check_scenarios.sh` 同风格的锚点校验脚本；Q5 片段按现签名重录。

### 9. [轻微][存量] 句柄表存储结构已过期：不是 `objs: ArrayList<Any>`，而是 1024 槽一段的 `segDir: Array<SlotSeg>`

- **位置**：`f_jit/README.md:245`（§3③）、`:503`（Q1「`HandleTable.objs: ArrayList<Any>`」）、`:515-523`（Q2 的 `objs[i]` 示例）；代码 `f_jit/src/runtime/HandleTable.cj:57-76`（`SlotSeg`：`objs/tags/gens/alive/...` 八个定长数组）、`:176`（`SEG_SIZE=1024`）、`:178`（`MAX_SEGS=4096`）、`:190`（`segDir`）
- **来源**：存量
- **判据**：review-checklist §13（文档与实现不符）；与本模块 `doc/concurrency-audit.md:23-24`（「`segDir` 定长数组 + 64 分片」）对照
- **证据**：静态确定 —— `HandleTable` 上没有 `objs` 字段，`ArrayList<Any>` 只出现在 `fetchList` 的类型判断里；句柄表本体是 `segDir[c]` → `SlotSeg.objs[off]`。
- **描述**：Q2 的结论（GC 搬对象时机器码的 `Int64` 不变）仍成立，但「一张 `ArrayList`、下标即 ID」的模型会误导读者理解 `idx` 的段/位移拆分、`capacityLimit` 与段目录上限（4M 槽）的关系，也让「只增不减」的水位判断失去依据（真实是段按需创建、槽可复用）。
- **建议**：§3③ 与 Q1/Q2 改为「`segDir: Array<SlotSeg>`（4096 段 × 1024 槽），每段 8 个定长数组；句柄 `idx` 编码段号与段内偏移」，容量水位改为「已创建的段数与 `capacityLimit`」。

### 10. [轻微][存量] helper 白名单上界三处互斥（H01–H83 / H01–H75 / 实际到 H84，`MAX_FIXED` 又是 72）

- **位置**：`f_jit/README.md:249`（H01–H83）vs `:484`（H84 `ipow`）；`f_jit/doc/asm-inline.md:174`（H01–H75）；代码 `f_jit/src/runtime/HelperId.cj:121`（`IPOW=84`）、`:125`（`MAX_FIXED=72`）、`:73-76` / `:106-118`
- **来源**：存量（`git blame` 2026-10-22 `1a4d246fcc` 等）
- **判据**：review-checklist §13 + §2（字面量复制）
- **证据**：静态确定 —— `HelperId` 登记到 84（63–84，66–68 保留）；README 的上界 83 落后一版，asm 文档的 75 落后更多；`MAX_FIXED=72` 与 73–84 的实际登记矛盾（该常量全仓零引用，见范围外提示）。
- **描述**：白名单是安全模型的核心表述（「机器码没有任何直接调用仓颉 API 的通道」），上界写错会让人误判某个 hid 是否被允许；三处数字互斥也让后续新增 helper 时不知道该改哪。
- **建议**：只写「闭区间以 `HelperId.MIN_FIXED`/`MAX_FIXED` 为准，当前 1–84（66–68 保留）」；`MAX_FIXED` 改 84 或删除（改由 `name()` 判）。

### 11. [轻微][存量] 中文版把 x86 后端写成「两遍降低」，实现与英文版都是三遍

- **位置**：`f_jit/README.md:241`；`f_jit/README_en.md:255`；代码 `f_jit/src/backend/X86Lower.cj:95-107`
- **来源**：存量（`git blame` 2026-11-13 `59b5fce057`）
- **判据**：review-checklist §13（中英不同步）
- **证据**：静态确定 —— 实际执行「探针遍（采集 delta）→ `X86Depth.analyze` 深度遍 → 发射遍」三段；源注释标题也自相矛盾（「两遍降低」+ 三个编号项）。
- **建议**：中文改「三遍降低（探针 → 深度 → 发射）」，顺手修 `X86Lower.cj:95` 的注释（代码注释属其他部分，仅提示）。

### 12. [轻微][存量] 并发审计用现在时描述 H1，而它给出的「问题代码位置」已不存在

- **位置**：`f_jit/doc/concurrency-audit.md:29-31`（H1「`finish()` 在 `synchronized(mtx)` 内调用 `fn.bindCacheKey(key)`」）、`:123-132`（H1–H6 全部「已完成」）；代码 `f_jit/src/CompileCache.cj:74-82`
- **来源**：存量（`git blame` 2026-11-27）
- **判据**：review-checklist §13（文档过期）
- **证据**：静态确定 —— `finish` 现在先 `fn.bindCacheKey(key)` 再进 `synchronized(mtx)`，注释直接标「H1」；H2–H6 的修法也都已落地（`NativeAssets.cj:35-36` 原子、`JitFunction.cj:661-668` 加锁、`HandleTable.cj:149-169` 原子 + `mut prop`、`Compiler.registerClass` 整体进锁、`CompilePipeline.cj:126-134` 三态）。
- **描述**：标题与 §2 都写成「遗留隐患」，下一轮审查会把它当现行缺陷再否证一次；H1 的锚点把「问题代码长什么样」写错。
- **建议**：§2 改成「历史形态（已修复，保留为回归说明）」，每条加「修复前位置 / 修复点（当前行号）/ 回归用例」，或把状态提到标题里。

### 13. [轻微][存量] 中文标题层级全是 `#`；英文版缺 Q7（`close()` 后重编 / 缓存逐出）与 `isClosed()` 说明

- **位置**：`f_jit/README.md:75-80`、`:328`、`:375`、`:501-587`（2.1 / 6.0 / Q1 都是 `#`，与文档标题同级）；`f_jit/README_en.md:538-640`（FAQ 只有 7 条）
- **来源**：存量（`git blame` 2026-10-22 ～ 2026-10-27）
- **判据**：review-checklist §13（`README_en` 少整节、关键段落缺失）
- **证据**：静态确定 —— 中文 8 条 FAQ（Q1–Q8），英文 7 条，缺「`close()` 之后还能再编译同一份源码吗」（`README.md:581-585`，含「终态即逐出 / 超时回退不逐出」契约）；中文 §1 有 `isClosed()` 的双语义说明（`:50`），英文没有。
- **描述**：缺的那条正好是 `close()` 契约里最容易误解的部分（逐出 vs 保留）；层级全为 `#` 让目录和锚点全平。
- **建议**：中文标题改 `##` / `###`；英文补 Q7 与 `isClosed()` 句。

### 14. [轻微][存量] 「其他公开 API」索引把 `HandleTable.initialCapacity` 标成 `var`（实际是 `mut prop`），`capacityLimit` 未收录

- **位置**：`f_jit/README.md:651`、`f_jit/README_en.md:691`
- **来源**：存量（H4 原子化改造后未同步索引）
- **判据**：review-checklist §13 / §14.2
- **证据**：静态确定 —— `src/runtime/HandleTable.cj:149-169`：`public static mut prop initialCapacity` / `public static mut prop capacityLimit`（底层 `AtomicInt64`）；`capacityLimit` 在正文 `:541` 被引用却不在索引里。
- **建议**：两项改标 `prop`，`capacityLimit` 补一行「默认 1048576，触顶 → 16」。

### 15. [轻微][存量][待确认] §6.5「`JitFunction` 没有对应码、编译期就会被拒」与注册面实现矛盾

- **位置**：`f_jit/README.md:452-456`；`f_jit/README_en.md:488-493`
- **来源**：存量（`git blame` 2026-10-22 `1a4d246fcc`）
- **判据**：review-checklist §13（文档与实现不符）
- **证据**：待确认 —— 所有宿主类只有一个码 `HOST_OBJECT = 14`（`src/base/LocalType.cj:60`），§2.2 也写「`registerClass(desc)`：任意类」；`PredefinedFunction.checkParamTypes` 允许 14（`src/base/PredefinedFunction.cj:68-73`）；在 `src/compiler/`、`src/base/`、`src/bytecode/` 搜 `JitFunction` 只有注释命中，**没有任何特判拒绝**。缺一条编译用例：`registerType<JitFunction>()`（或注册同名 `ClassDescriptor`）后，`{ f: JitFunction => 1 }` 是否真的编译失败。
- **描述**：结论（建议用闭包包一层）大概率仍成立，但理由「没有对应码」不成立；若实际可注册，文档就在替用户关闭一条可用路径，且「编译期被拒」的承诺没有实现支撑。
- **建议**：跑上述用例定性；若可注册，改成「不推荐（桥侧执行体，跨桥语义未定义），推荐用宿主闭包（13）传参」。

## 优化可行性方案

本部分 4 个文件均为文档，没有可直接落地的堆内存 / CPU 改造对象（性能改造点在 `.cj`，属其他部分）。文档层面的可维护性改进（符号化锚点、公开 API 清单同源生成）已并入各条「建议」，不重复计为方案。

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 深度递归的真实崩栈阈值远低于业务预期（机器码帧对运行时栈扩容不可见） | `f_jit/README.md:375-392`；`src/runtime/Interp.cj:603-619`、`src/backend/X86Lower.cj:437-455` | 两引擎各自的崩溃深度与每帧字节数 | 固定 `cjStackSize`（默认 128 KB 与 1 MB 两组），跑 `recursive(n)` 二分 n，记录首个崩溃点与信号；x86_64 / aarch64 各一次 |
| 2 | `CompileCache.awaitReady` 的墙钟自旋在并发编译时吃掉可观 CPU | `src/CompileCache.cj:154-163` | 等待者数 × 自旋时长的 CPU 占比 | `cjprof record`：N=2/4/8 线程同键编译同一长源码（或调大 `awaitTimeoutNs`），看 `awaitReady` 自耗时 |
| 3 | `PowHelper` 用异常判乘法溢出（`try { a * b } catch`）在 `**` 密集负载下比显式检查更贵 | `src/runtime/PowHelper.cj:71-78` | 单次 `**` 耗时与异常路径占比 | `cjpm bench -O2`：`2 ** k` 1e6 次（溢出/不溢出两组），改前改后中位数对照 |
| 4 | 并发审计的调用开销基线（2971 ns/call）与 README 引用的 1.27×/2.40×/1.91× 可作后续对照基线 | `doc/concurrency-audit.md:102-121`、`README.md:597-599` | `-O2`/`-O0` 标注、轮次、中位数与离散度 | 同机 `cjpm bench -O2` 跑 `CallPathBench_test` 3 轮，记录中位数 / P95 / SDK 版本 / 负载；专用 8 核复跑 verify.md 场景 |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_jit/README.md` | .md | ✅ | 709 行全读；§1–§8 + 「其他公开 API」索引；15 条发现中 12 条与本文件相关（#1–#4、#6、#8–#11、#13–#15） |
| 2 | `f_jit/README_en.md` | .md | ✅ | 749 行全读；逐章与中文对照（FAQ 少 1 条、§1 语义句缺失、`close()` 结论相反） |
| 3 | `f_jit/doc/asm-inline.md` | .md | ✅ | 338 行全读；opcode RSVD 区间、157 opcode、`verify.md:69`、常量 kind 10/11、`verMinor=14`、`flags.bit1` 均核对通过；ABI 偏移（#5）、锚点（#8）、helper 上界（#10）有问题 |
| 4 | `f_jit/doc/concurrency-audit.md` | .md | ✅ | 132 行全读；H1–H6 的「已完成」逐条对代码复核（含 H1 锁外 `bindCacheKey`、H2/H4 原子、H3 加锁、H5 注册进锁、H6 三态）均成立；问题在扫描完整性（#7）与时态（#12） |

合计：`.cj` 0 个 / `.md` 4 个 / 共 4 个，全部读完。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 4 | #3（类型码）、#4（`close()` 返回值）、#6（错误码）、#15（类型可注册性）；无安全类问题——文档不含凭据/注入面，`asm-inline` 明确「默认关闭 + 进程内任意代码执行」，白名单表述与 `HelperId` 一致 |
| §1 死代码 | 0 | 本部分无声明可判；反向核对了文档引用的符号：README「其他公开 API」658 项脚本比对 `src/` 全部存在（0 缺失），另对 `append` / `getAny` / `releaseReturnHandle` / `unboxClosure` / `IPOW` / `CompileTimeout` 等逐个 grep 到定义或写点 |
| §2 重复逻辑 | 1 | `asm-inline.md:71-82` 的 ABI 常量表是 `jit-bytecode-m1.md` §12.2 的第二份字面量拷贝且已漂移（#5）；两份 README 的 658 项 API 清单经脚本比对完全一致（刻意镜像，不计），「同源生成」建议见 #8 |
| §3 空实现 | 0 | 无空段/占位 TODO；`asm-inline.md:3` 明确「仅可行性分析，未开发、未立规格」，与代码一致（`src/` 无 asm 语法、`ConstKind` 只到 11），属有意声明，不判「承诺未实现」 |
| §4 栈溢出 | 1 | #1（无深度上限；已按官方文档核对默认栈 128 KB 与 overflow 检查默认关闭）。`recursive` 的尾位置 `LOOP_BACK` 是同帧跳转，「尾递归不增长栈」成立 |
| §5 OOM | 0 | 文档唯一容量承诺 `capacityLimit=1048576`、`MAX_SEGS=4096` 与实现一致（`HandleTable.cj:159-169`、触顶 → 16）；无非尾递归以外的无界增长承诺（解释器帧增长归 §4） |
| §6.1 热点瓶颈 | 0 | 无 profile / bench 原始数据；三条性能线索（递归深度、`awaitReady` 自旋、`**` 异常路径）与审计基线均进待验证假设 1–4 |
| §6.2 大粒度锁 | 0 | 已核对文档声称的共享点：`CompileCache` 全局锁只护三张表与去重、`HandleTable` 读路径无锁 + 64 分片、`JitFunction.mtx` 只护状态与 `lastEscaped`；未发现「锁内 I/O / 回调」的描述或实现 |
| §6.3 并发串行 | 0 | 无 `spawn` 后立即 `get`；README Q8「无进程级调用锁」与 `JitFunction.callLocked` 一致；`JitContext` 池化已回退且有数据 |
| §6.4 低效算法 | 0 | 文档层面无嵌套循环 / `contains` / `remove(at:0)` 类描述；本部分无 `.cj` |
| §7 降堆内存方案 | 0 | 本部分为文档，无可量化的持有路径；句柄表容量语义已核对 |
| §8 降 CPU 方案 | 0 | 同上；`awaitReady` / `**` 两条只是假设，无基线 |
| §9 local mode 可行性 | 0 | 文档未涉及 local mode，也无峰值内存数据，不构成方案 |
| §11 现有代码的 BUG（存量） | 15 | 本部分 15 条全部为存量（blame 2026-10-21 ～ 2026-11-27，均早于 HEAD）；按后果定级：严重 1 / 一般 6 / 轻微 8 |
| §12 并发安全与锁粒度 | 1 | #7（审计扫描完整性）；H1–H6 的「已完成」状态逐条与代码核对均成立，`RuntimeEnv` / `UserHelperTable` / `IterTable` 确为 TLS |
| §13 文档一致性 | 13 | 两版 README 与两份专题文档逐条对照 `src/`：13 条直接属 §13（#2–#6、#8–#15）；#1 同时属 §4/§14，未重复计数 |
| §14 功能完备性与 README 覆盖 | 3 | #2（`protected` 类型列为 API + `RuntimeState` 漏登记）、#4（`close()` 契约在英文版失真）、#13（英文缺 Q7） |
| 文件覆盖（§13 等） | 4/4 | 无不读文件，无未读原因 |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 1 |
| 一般 | 6 |
| 轻微 | 8 |
| 优化方案（堆内存 / CPU） | 0 / 0 |

## 总评

这 4 个文档的整体质量在仓内属于上游：157 条 opcode、RSVD 槽区间（0x08–0x0F / 0x1D–0x1F / 0x27–0x2F / 0x3C–0x3F / 0x4E–0x4F / 0x6F / 0x73 / 0x8A–0x8F / 0x9F / 0xC0–0xFF）、常量 kind 10/11、`verMinor=14`、`flags.bit1=NEED_JIT`、`verify.md:69` 的「157 个 opcode 0 缺失」、加速比 1.27×/2.40×/1.91× 都能与源码或证据文件对上；`concurrency-audit` 的 H1–H6 也逐条在代码里落实（锁外 `bindCacheKey`、`AtomicInt64`、`lastEscaped` 加锁、注册进 `this.mtx`、`CompileTimeout` 三态）。

问题集中在两类。第一类是**契约级事实错误**：递归深度/栈溢出完全没进「已知限制」，而文档同时承诺「JIT 只是加速层、语义不变」——非尾递归在解释器与机器码里都是真递归且没有任何闸门，溢出是进程崩溃、不产生 `JitException`（#1，本部分唯一严重项）；其次是句柄 tag 与方言类型码混用（#3）、Int64 零除错误码（#6）、英文版 `close()` 返回值（#4）、ABI 表的 `hwTop` 偏移（#5）。这几条都在宿主可见的契约面上，改动本身是纯文档，但会直接改变调用方的错误处理与安全假设。第二类是**文档随实现漂移**：11 处锚点错位（README 6 处、asm-inline 5 处）且 Q5 片段是旧签名（#8）、句柄表存储模型过期（#9）、「两遍/三遍」「H01–H83/H01–H75/`MAX_FIXED=72`」「`initialCapacity` 是 var」这类小口径错误（#10/#11/#14）、中英两版已经分叉（#4/#13）。根因是「按行号引用 + 两份手写清单」，建议一次性改成符号引用 + 从 `src/` 生成索引，否则下一轮重构还会再漂。

`asm-inline` 的可行性结论（B 先行、破 I7/禁 deopt、JIT-only）论证扎实，但 ABI 表若被后续实现直接采用，`hwTop` 偏移会成为真缺陷，应在立项前修正。`concurrency-audit` 的结论可以保留，但「25 个 static 全覆盖」与两个未加保护的诊断计数器冲突（#7），建议改成「运行期正确性无缺陷 + 诊断计数允许丢计数」，避免下一轮审计以它为豁免依据。

存量 15 条（严重 1 / 一般 6 / 轻微 8），是否纳入修复待用户决定；快照模式无基线，不区分「本次改动」。

**范围外提示**（不计入本部分统计，留待对应 `.cj` 分部分确认）：① `HelperId.MAX_FIXED = 72`（`src/runtime/HelperId.cj:125`）与已登记的 73–84 矛盾，且全仓零引用（`public`，属一致性/可见性信息，非死代码）；② `JitFunction.close(timeoutMs)` 的等待上限按自旋次数折算（`timeoutMs * 100000`，`src/JitFunction.cj:237-247`），不是真实毫秒，实际墙钟随 CPU/锁开销漂移；③ `CompileCache.reset` / `runs` 仅被 `*_test.cj` 引用且类型为 `protected`，属可见性建议。
