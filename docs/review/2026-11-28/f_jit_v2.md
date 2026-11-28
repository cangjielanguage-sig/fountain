# f_jit 模块审查报告

- **审查日期**：2026-11-28
- **模块路径**：`f_jit`（595 个文件：305 个 .cj + 290 个 .md）
- **基线**：工作区快照（sts/1.3.x 工作区，master 同提交 120fd2542，无分支差异）
- **审查重点**：见 scope.md（正确性、死代码、重复逻辑、空实现、栈溢出、OOM、热点、并发与锁、存量 BUG、内存/CPU 优化空间、local mode 可行性、README 覆盖）
- **报告版本**：v1（由 38 个分部分报告合并：`parts/f_jit.part1..38.md`）

## 发现

<!-- 第 1 部分 -->

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

<!-- 第 2 部分 -->

### [严重][存量] `STACK_GUARD` 的能力被设计夸大：只护帧内操作数栈，错误码 15 全仓无生产者

- **位置**：`f_jit/doc/design-m1.md:1146`（附 A.7「栈防守与安全点｜隐式（回边/**进入**）」）、`f_jit/doc/design-m1.md:1465`（C.4 `STACK_GUARD` 行「解释器余量亦不足 → **桥写 15**」）、`f_jit/doc/design-m1.md:1437`（C.2 入口序列没有该指令）、`f_jit/doc/design-m1.md:267`（§2.3.10 错误码 15）；代码 `f_jit/src/backend/A64Lower.cj:364-370`、`f_jit/src/backend/X86Lower.cj:1020`、`f_jit/src/runtime/Interp.cj:212`、`f_jit/src/base/ErrCode.cj:61`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §4「无界递归 / 深度由输入决定」、§11「契约与实现不符」、§13「文档内部不一致」
- **证据**：静态确定 —— `STACK_GUARD` 的判据是 `(rbp − FRAME) − rsp`，只检查**本帧操作数栈**是否越过帧底；`CALL_FUNC`/`CALL_CLOSURE` 压入的新机器栈帧位于 `rsp` 之下，这个比较看不到调用深度。设计 A.7 声称「进入」也发 `STACK_GUARD`，但 C.2 入口序列（`:1437`）没有它，编译器也从不发射 0x07（`f_jit/src/compiler/Ops.cj:35` 只有常量；`grep -rn "Ops.STACK_GUARD"` 在编译器内零命中），唯一发射点是 `LOOP_BACK` 的 lowering。解释器把 0x07 当空操作（`Interp.cj:212`），而它的 `CALL_FUNC` 是仓颉原生递归（`Interp.cj:614` → `run` → `exec`）。错误码 15 没有任何写入者：`grep -rn "ErrCode.STACK_GUARD"` 只命中定义与测试断言，`DiagCode`/桥/引擎均不写 15
- **描述**：设计用 A.7/C.4 建立了一个「回边与进入都有栈防守、最坏退回解释器、解释器不够就写 15」的安全论证；这条论证在实现里不成立：进入无守卫、解释器无检查、15 无生产者。非尾 `recursive` 的深度由运行期数据决定，两条引擎都以宿主 `StackOverflowError`（灾难性 `Error`，按 D1 不捕不吞）终止，而不是 15。递归深度本身已在 part1 #5 记录（同根因，合并时保留一条即可）；本条针对的是**设计文档把 `STACK_GUARD` 当作通用递归防护**这一错误论断
- **建议**：二选一——① 删掉 A.7「进入」与 C.4「桥写 15」，把 `STACK_GUARD` 明确限定为「帧内操作数栈余量」；② 补真正的调用深度预算（ctx/线程态 depth，`CALL_FUNC`/`CALL_CLOSURE` 入口增减，超限写 15，解释器同一上限），并把上限写进 §8.4 契约

### [一般][存量] 生命周期 API 写成 `unload` / `isUnloaded`，实现只有 `close` / `isClosed`

- **位置**：`f_jit/doc/design-m1.md:894-895`（`func unload(timeout!: ?Duration = None): Bool`、`prop isUnloaded: Bool`）、`f_jit/doc/design-m1.md:981-985`（§8.6 的 `Ready --CAS--> Unloading --activeCalls==0--> Unloaded` 状态机）、`f_jit/doc/design-m1.md:968`（§8.4 第 0 步「Ready（未卸载）」）；代码 `f_jit/src/JitFunction.cj:227`（`close(timeoutMs: Int64): Bool`）、`:471`（`isClosed(): Bool`）、`:523`（`close(): Unit`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §13「API / 配置 / 默认值与源码不符」、§14.1「承诺了但没实现」；本部分审查重点「句柄与资源生命周期」
- **证据**：静态确定 —— `f_jit/src` 全仓 `grep -n "func unload"` 只命中私有 `unloadClosure`（`JitFunction.cj:302`），公开成员只有 `close` / `close(timeoutMs)` / `isClosed`；`JitFunction <: Resource`（`:59`）决定了 `close` 是契约名。`design-m2.md:383` 还明确写「`unload` 保持单元级不变」，说明后续设计也认为它仍存在
- **描述**：按设计写 `f.unload()` 或读 `f.isUnloaded` 的宿主代码无法编译；§8.6 的卸载状态机、§8.4 的入口断言都以 `unload` 命名，读设计去核对 `JitFunction` 会找不到落点。生命周期是宿主最容易误用的一块（漏关闭 → 代码内存/提升组常驻），文档名与实际 API 不一致会直接放大这个风险
- **建议**：§7.3.3 与 §8.6 统一改为 `close(timeoutMs): Bool` / `close(): Unit` / `isClosed()`，并注明「`Resource` 契约；入口实例 = 单元卸载，包装实例 = 释放本闭包」；若要保留 `unload` 兼容别名，需在设计中单列并说明与 `close` 的关系

### [一般][存量] `Compiler.compile(unit: SourceUnit)` 分发入口未实现，`SourceUnit` 在生产路径无消费方

- **位置**：`f_jit/doc/design-m1.md:880`（`func compile(unit: SourceUnit): JitFunction`）、`f_jit/doc/design-m1.md:950-952`（§8.2 分发入口「替换 ② 为 `FbcReader.load(raw)`，去重键 = 字节码指纹」）、`f_jit/doc/design-m1.md:181-182`（`SourceUnit.entryFn` 须与容器头一致，否则加载期拒绝）；代码 `f_jit/src/Compiler.cj:185`（只有 `compile(source: String)`）、`f_jit/src/CompilePipeline.cj:95`（`runUnit(raw: Array<UInt8>, c: Compiler)`，入口号取容器头 `unit.header.entryFn`，不接受期望值）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §14.1「承诺了但没实现」、§13「API 与源码不符」、§1「非 public 无引用 / public 无使用」的取证要求
- **证据**：静态确定 —— `grep -rn "compile(unit" f_jit/src` 零命中；`SourceUnit` 只出现在自身定义、`src/base/SourceUnit_test.cj` 与 `src/BaseVisibility_test.cj`，无生产消费方；`Root.cj:23-46` 也未再导出它。设计承诺的「`entryFn` 与容器头不一致→加载期拒绝」在 `runUnit` 路径不存在（它直接用容器头的值）
- **描述**：设计把「分发已编译字节码」列为与源入口并列的公开能力，实现只提供 `CompilePipeline.runUnit(raw, c)`——参数少一个期望入口号、语义也不同（不能用 `SourceUnit` 指定入口）。`SourceUnit` 因此是一个「对外 public、仓内只被测试引用」的悬空契约类型；宿主按 §8.2 无法把「我想要 entryFn=N」表达出来
- **建议**：二选一并写进设计：① 在 `Compiler` 上补 `compile(unit: SourceUnit): JitFunction`，在 `runUnit` 前校验 `unit.entryFn == header.entryFn`；② 承认分发入口只有 `runUnit`，删除 `SourceUnit` 或把它降为 `internal`，并同步 §2.3.5 / §7.3.1 / §8.2

### [一般][存量] `CallContext.args` 已被删除，设计仍把它当作 Marshal 载体与 `rawEntry` 实参来源

- **位置**：`f_jit/doc/design-m1.md:172-173`（`var args: Array<Int64>`、`var deadline: ?DateTime`）、`f_jit/doc/design-m1.md:958`（§8.3 第 2 步「逐参 Marshal → CallContext.args」）、`f_jit/doc/design-m1.md:970`（`rawEntry(ctx, &args[0], nargs)`）；代码 `f_jit/src/base/CallContext.cj:44-47`（只有 `public let deadline!: ?DateTime = None`，注释明确「为何删掉 `args`：从未被任何执行路径读取」）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §13「API 与源码不符」、§1「读了不用 / 兼容残留」
- **证据**：静态确定 —— `CallContext` 现在是无字段（除 `deadline`）的单行 struct；`JitFunction.callLocked` 的封送走 `call<T>(args: Array<Any>)` + `CallMarshal`（`JitFunction.cj:617-635`），再用 `JitContext.create(hwBase, …)` 建 ctx，实参数组是局部 `cells`，与 `CallContext` 无关
- **描述**：设计把 `CallContext` 描述成「桥侧调用参数（args + deadline）」，并把它画进三态收尾第 2 步。宿主若按设计构造 `CallContext(args: ...)` 会编译失败；读设计排查「实参怎么进 ctx」会被引到一个不存在的字段。更实际的后果是：`CallContext` 的语义边界（只装调用级选项）在文档里没有一处写清
- **建议**：§2.3.4 改成「`CallContext` 只装调用级选项（`deadline`）；实参走 `call<T>(args: Array<Any>)` 并由 `CallMarshal` 封送」；§8.3 第 2 步把 `CallContext.args` 换成局部 `cells`，并说明 `args` 曾存在但从未被消费

### [一般][存量] 去重缓存与 D4 / §3.3.8 的契约不符：键含配置项、命中无原字节二次校验、`DedupGuard` 无调用者

- **位置**：`f_jit/doc/design-m1.md:914`（`lookupOrClaim(sourceCode)`「内部以 `FNV-1a-128(规范化源码)` 为键」）、`f_jit/doc/design-m1.md:1014`（D4「一份源码只出一份字节码与 JIT 产物」）、`f_jit/doc/design-m1.md:417`（「缓存条目保存原始输入字节，命中后做长度 + 字节二次校验（不符按 Miss 重编）」）；代码 `f_jit/src/CompilePipeline.cj:59-60`（`'src/<jit>/v<verMajor>/fp<strictFp>/<fnv1a128(source)>'`）、`:96`（`'fbc/<jit>/<fnv1a128(raw)>'`）、`f_jit/src/CompileCache.cj:53-58`（`lookup` 只返回 `?JitFunction`，不持有原始字节）、`f_jit/src/bytecode/Fingerprint.cj:119`（`DedupGuard` 全仓无生产引用）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §13「规格与实现漂移」、§14.1「接线缺失」、§1「注册了但永不触发」
- **证据**：静态确定 —— 缓存键由「jit 模式 / verMajor / strictFp / 指纹」四段拼成，注释写明「同源不同配置必须各自成键」，因此同一份源码在 `Auto` 与 `Off`、`strictFp=true/false`、v1/v3 下会各出一份产物，D4 的绝对表述不成立；`lookup` 的签名无法做二次校验（没有第二份字节可对比），`CompileCache.cj:28` 注释把责任推给 Pipeline，但 `runSource` / `runUnit` 命中即 `return f`（`CompilePipeline.cj:57-60`、`:97-100`），全仓也搜不到字节比较；`DedupGuard` 是为该契约准备的类型，却只被定义
- **描述**：这组偏差有三个可观察后果：① D4 的「一份源码只出一份产物」在宿主切换 `jit`/`strictFp`/`verMajor` 时不成立，缓存条目数按配置组合增长，「close 后同源再编」也不再是唯一入口；② §3.3.8 把「碰撞 = 语义错误」定为必须靠二次校验兜底，实现的 128 位指纹命中后直接复用，安全论证缺了最后一环（理论上仍是可碰撞的，虽然概率极低）；③ `DedupGuard` 成为「为契约而生、从未接线」的类型，后续读者会以为校验已存在
- **建议**：三处对齐——① 文档把 D4 改成「同一 (源码, jit, strictFp, verMajor) 只出一份产物」，并说明关闭/重编语义按该键；② 要么在 `CompileCache` 条目里保存 `(key, rawBytes)` 并在 `lookup` 命中时用 `DedupGuard.matches` 复核，要么删掉 §3.3.8 的二次校验承诺与 `DedupGuard`（明确接受 128 位碰撞概率）；③ 不要让注释把「调用方负责」写成事实而不给调用方留接口

### [一般][存量] 桥内执行结果机制已被内联重构：`invoke` / `tryInvoke` / `JitValue` / `AdapterRegistry` 在生产路径均不存在

- **位置**：`f_jit/doc/design-m1.md:207-213`（§2.3.6 `JitValue`「产生点唯一：`invoke`/`tryInvoke` 三态收尾第 3 步」）、`f_jit/doc/design-m1.md:896-897`（私有 `invoke(ctx): JitValue` / `tryInvoke(ctx): Result<JitValue, JitException>`）、`f_jit/doc/design-m1.md:915`（`AdapterRegistry.register/lookup/removeUnit`「call 第 5 步；卸载」）、`f_jit/doc/design-m1.md:961`（§8.3 第 5 步「跨模块/动态 → `AdapterRegistry` 运行期校验 → 19」）；代码 `f_jit/src/base/JitValue.cj:42`（`protected enum JitValue`，全仓生产代码零构造/零读取）、`f_jit/src/AdapterRegistry.cj:27`（`protected class`，只被自身与 `AdapterRegistry_test.cj` 引用）、`f_jit/src/JitFunction.cj:555-577`（`call<T>` 内联完成 T 校验，未经过任何注册表）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §1（顶层 `protected` 类型无引用 = 死代码；接口/父类覆盖除外）、§3「接口默认空实现 / 承诺但实现为空」、§13
- **证据**：静态确定 —— `grep -rn "JitValue" f_jit/src` 只命中定义文件与 `Root.cj:21` 的一句注释（该注释还把 `JitValue` 列为「执行期内部类型」）；`AdapterRegistry` 的全部调用点在 `AdapterRegistry_test.cj`。T 一致性校验实际由 `localTypeOf<T>` 与 `retType` 比较完成（`JitFunction.cj:568-577`），命中失败仍返回 19，功能在、机制不在
- **描述**：设计用整整一节描述「用户意图 `JitMode` → 实际事实 `Engine` → 桥内结果 `JitValue`」这条链路，并用 `Result<JitValue, JitException>` 定义「不抛变体」。实现把这三态直接内联进 `call<T>`，`JitValue` 从此没有任何生产者/消费者，`AdapterRegistry`（含两张 static 表与卸载清理）也整体悬空。读者会按设计去找 `invoke`/`tryInvoke` 与适配器注册时机，实际都不存在；这也让「D3 结案：`JitValue` 为 protected 因唯一消费者是私有 invoke」的论证失效
- **建议**：§2.3.6 / §7.3.3 / §7.3.5 / §8.3 收敛为「`call<T>` 单一路径：Marshal → 执行 → `unboxRet` → T 校验（`localTypeOf<T>`）」，删除 `invoke`/`tryInvoke`/`JitValue` 或明确标注为已撤销；`AdapterRegistry` 与 `JitValue` 若确认不再需要，按死代码清理（`protected` 顶层类型，`Root.cj` 已声明不对外）

### [一般][存量] §6.3 后端产物与引擎选择的实现形态已重构，`JitArtifacts` / `JitCompiler` / `BackendSelector` 的描述全部失配

- **位置**：`f_jit/doc/design-m1.md:816-822`（`JitArtifacts` 持 `code: CodeBuffer` / `fnTable: FnTable` / `mirror: ConstMirror`，有 `rawEntry(fnId)` 与 `free()`）、`f_jit/doc/design-m1.md:811-814`（`JitCompiler.init(backend, diagnostics)` + `compileUnit(unit, handleIds)`）、`f_jit/doc/design-m1.md:843`（`BackendSelector.select` 由桥管线第 3 步调用）、`f_jit/doc/design-m1.md:985`（卸载顺序依赖 `JitArtifacts.free()`）；代码 `f_jit/src/backend/JitCompiler.cj:23-56`（`JitArtifacts` 是 `code: Array<UInt8>` + `fnIds/offsets/lengths`，只有 `entry/codeOf`，无 `free()`）、`:63-80`（`JitCompiler` 全 static，无 `init`）、`f_jit/src/backend/JitExecutor.cj:53-70`（`JitExecutor.create(unit, entryFn)` 自行建 `CodeBuffer/FnTable/ConstMirror` 并选路）、`f_jit/src/backend/BackendSelector.cj:40`（`select` 仅被自身与测试调用）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §13「API / 结构与源码不符」、§14.1「接线缺失」、§3（承诺的 `free()` 与选路入口无实现）
- **证据**：静态确定 —— `grep -rn "BackendSelector\." f_jit/src` 的生产命中只有 `BackendSelector.cj` 自身；`JitArtifacts` 的三件原生资产改由 `JitExecutor` 私有字段持有（`JitExecutor.cj:34-37`），`release()` 在 `:185`；`JitArtifacts` 不再拥有可释放资源，`free()` 无从谈起
- **描述**：这是设计里「JIT 产物束 = 三块非 GC 资产 + 入口表」的核心结构，§8.7 的卸载顺序（「code buffer + fnTable 最后释放」）完全建立在它之上。实际结构是「纯字节束（可 GC）+ 独立的 `JitExecutor` 持有三块原生资产」，所以按设计核对资源释放会找不到 `JitArtifacts.free()`，也无法解释 `BackendSelector` 为何存在却不在管线里。资源生命周期的描述因此失真（真正的释放点在 `JitExecutor.release` 与 `JitFunction.close` 的 `rel` 闭包）
- **建议**：§6.3.2–6.3.4 按现实现重写：`JitArtifacts` = 字节束 + `entry/codeOf`；`JitExecutor` = 资产所有者 + 引擎门禁（非 Linux/非 x86_64/aarch64 → `None`）；`BackendSelector` 标注为「仅诊断/测试用，生产管线不经过」或直接删除；§8.7 的释放顺序改为按 `JitExecutor.release` 与 `JitFunction.close` 的实际次序描述

### [一般][存量] 诊断接线缺失：`JitFallback` / `MmapFailed` 永不送达宿主 sink，编译阶段固定使用 `DummyDiagnosticsSink`

- **位置**：`f_jit/doc/design-m1.md:196-197`（`JitMode` 不可用「只记 diagnostics」）、`f_jit/doc/design-m1.md:843`（`BackendSelector.select` 否则 `(Interp, None)` 并记 diagnostics）、`f_jit/doc/design-m1.md:945`（§8.1 第 ③ 步「diagnostics 记 `(Warn, JitFallback)`」）；代码 `f_jit/src/backend/JitExecutor.cj:53-70`（不支持即 `return None`，不接收也不调用 `DiagnosticsSink`）、`f_jit/src/CompilePipeline.cj:239`（`JitExecutor.create(unit, entryFn)`，未传 `opts.diagnostics`）、`f_jit/src/CompilePipeline.cj:72`（`SourceCompiler(snap, DummyDiagnosticsSink(), …)` 硬编码）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §14.1「接线缺失」、§3「开关打开后走进空分支」、§13「承诺与实现相反」；本部分审查重点「动态调用/桥接正确性」
- **证据**：静态确定 —— `grep -rn "diag(" f_jit/src` 的非测试命中只有 `BackendSelector.cj:61/71`（未被管线调用）与 `ReflectRegistrar.cj:908`（注册期）；`DiagCode.MmapFailed` 无任何发射点；`JitMode.Force` 在非 Linux 上能观察到的唯一差异是 `JitFunction.isJitBacked()`，而不是设计承诺的 `(Warn, JitFallback)` 事件
- **描述**：T7 的可观测定义是「存在 `(Warn, JitFallback)` 事件」，而宿主通过 `Compiler.compile()` 走的生产路径永远不会产生该事件；编译期的 sink 也被替换成 `DummyDiagnosticsSink`，宿主传入的 `opts.diagnostics` 只在 `registerType/registerInterface` 时被用到。结果是：设计里的「静默降级、只记 diagnostics」实际变成「静默降级、什么都不记」，宿主无法在自己的日志里区分「JIT 生效」与「悄悄退解释器」
- **建议**：把 `opts.diagnostics` 传进 `SourceCompiler` 与 `JitExecutor.create`（或由 `CompilePipeline` 在 `create` 返回 `None` 时按门禁原因发 `(Warn, JitFallback)` / `MmapFailed`）；删除 `BackendSelector` 或让它重新成为唯一选路入口；在 `DiagCode` 注释里写清每个码的发射点

### [一般][存量] `unregisterFunction` 契约不符：设计为 `Unit` + 未注册抛编译期错误，实现为 `Bool` + 返回 false

- **位置**：`f_jit/doc/design-m1.md:876`（`func unregisterFunction(name: String): Unit`｜「注销（未注册 → 编译期错误）」）；代码 `f_jit/src/Compiler.cj:87-99`（`public func unregisterFunction(name: String): Bool`，未命中 `return false`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §13「API 与源码不符」、§11「错误处理缺失或静默」「契约与实现不符」
- **证据**：静态确定 —— 返回类型与失败路径都与设计相反；`design-m2.md` / `design-m3.md` 未记录该变更（`grep` 零命中），README 也未说明「未注册返回 false」
- **描述**：注销一个拼错的名字在实现里是静默 `false`，在设计里是编译期错误。宿主若按设计用 `catch (SourceCompileException)` 检测注册表拼写问题，会完全失效；反之若按实现忽略返回值，也无法知道注销是否真的发生。注册表是与编译器共享的可变状态，「静默无操作」比「抛错」更难排查
- **建议**：确定一种语义并同步三处（设计 / README / 实现）：要么保留 `Bool` 并在 §7.3.1 写明「未注册 → false，不抛」，要么恢复抛 `SourceCompileException(UndefinedIdentifier)`；不建议两者并存

### [一般][存量] 同键编译失败只共享文本、不共享异常类型：等待方拿到 `kind=CompileFailed`，首个调用方拿到真实 kind

- **位置**：`f_jit/doc/design-m1.md:914`（`CompileCache`「失败共享异常」）；代码 `f_jit/src/CompilePipeline.cj:82` / `:110`（`CompileCache.fail(key, e.message)` 只存文本）、`f_jit/src/CompileCache.cj:98-107`（`failures: HashMap<String, String>`）、`f_jit/src/CompilePipeline.cj:129-137`（`missingResult` 一律返回 `('CompileFailed', m)`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11「错误处理缺失或静默」、§12.1「`Future` 异常被吞 / 异步语义」、§13「契约与实现不符」
- **证据**：静态确定 —— 首个线程抛原始 `SourceCompileException`（如 `kind=UnregisteredFunction`）；同键的后续线程经 `awaitReady → None → missingResult` 得到 `SourceCompileException('CompileFailed', 原文本)`。`kind` 是测试与宿主分支的依据（`design-m1.md:152` 明写「测试断言 kind」），文本相同不能替代
- **描述**：并发首次编译同一份坏源码时，先到的线程能拿到精确诊断（未注册函数 / 未定义标识符 / 类型不符），后到的线程只拿到 `CompileFailed`。宿主若按 `kind` 提示「该注册哪个函数」，只有第一个请求能得到正确提示；同一份源码的失败语义随线程时序变化
- **建议**：失败条目保存 `(kind, position, line, column, lineText, hint)`（或直接保存异常对象的克隆），`missingResult` 按原 kind 重建；或者文档明确写「缓存失败只保证文本等价，kind 统一为 `CompileFailed`」

### [一般][存量] `compile()` 可能返回正在 `close` 的单元：`Ready` 复用语义在 `Unloading` 窗口内不成立

- **位置**：`f_jit/doc/design-m1.md:1014`（D4「命中 Ready 复用」）、`f_jit/doc/design-m1.md:982`（§8.6「Unloading（拒绝新调用）」）、`f_jit/doc/design-m1.md:968`（§8.4 第 0 步「入口断言 Ready，否则 19」）；代码 `f_jit/src/CompileCache.cj:53-58`（`lookup` 只按 key 取 `JitFunction`，不检查状态）、`f_jit/src/JitFunction.cj:235`（`close` 先把 `state=1`）、`:263`（排空后才 `CompileCache.remove(k)`）、`:198-206`（`enterUnit` 在 `state != 0` 时抛 19）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §12.1「发布逸出 / 检查-然后-写入」「异步语义：取消后仍改状态」、§11「并发正确性」；本部分审查重点「并发安全、句柄与资源生命周期」
- **证据**：静态确定（机制成立）/ 待确认（是否属可接受语义）—— `close` 从 `state=1` 到 `remove` 之间有一个跨排空的窗口（`active` 不为 0 时可长达整个 timeout），此窗口内 `CompileCache.lookup(key)` 仍能取到该单元；`runSource` / `runUnit` 命中即返回，随后 `call` 在 `enterUnit` 得 `CALL_CONTRACT(19)`。`UnloadConcurrency_test.cj:26-90` 只验证「close 期间已有句柄的新调用得 19」，没有覆盖「close 期间 compile 命中同一 key」
- **描述**：宿主并发做「编译同一源码」与「关闭旧单元」时，`compile` 可能成功返回一个已经进入卸载态的句柄，紧接着第一次 `call` 就抛 19；若宿主不重试，表现为「刚编译出来就不能用」。设计只承诺「Unloading 拒绝新调用」，没有规定此时 `compile` 的可见性，属于契约空白
- **建议**：`CompileCache.lookup` 命中后过滤 `state != 0` 的条目（返回 `None` 并允许重新 `claim`），或在 `close` 开始时就把条目从 `ready` 摘除（排空失败再放回）；同时在 §8.6 补一句「compile 与 close 并发时 compile 要么返回可用单元、要么重新编译」，并加一条并发用例

### [一般][存量] §7.3.6 的再导出清单未落地：根包没有 `public import base.*` / `bytecode.*` / `runtime.*`，`CallContext` / `SourceUnit` / `TypeToken` / `Version` / `HandleTable` 均不在用户面

- **位置**：`f_jit/doc/design-m1.md:923-926`（`public import fountain::f_jit.base.*`、`...bytecode.*`、`...runtime.*`（`HandleTable`））；代码 `f_jit/src/Root.cj:23-46`（逐符号导入 19 项，无 `base.*`、无 `bytecode.*`、无 `runtime.*`；`CallContext`、`SourceUnit`、`TypeToken`、`Version`、`HandleTable` 都不在其中）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §13「API / 配置与源码不符」、§14.2「公开 API 未文档化 / 索引未登记」、§1「对外可达 ≠ 用户面可达」
- **证据**：静态确定 —— `grep -n "^public import" Root.cj` 只有 19 条 base 单符号；`BaseVisibility_test.cj:20` 用的是 `import fountain::f_jit.base.*`，因此它并不能证明「根包再导出清单不缺项」（测试注释与实际导入口径不一致）
- **描述**：按设计写 `import fountain::f_jit.*` 后使用 `CallContext()`、`HandleTable.pin()`、`TypeToken.LIST`、`Version.MINOR` 会编译失败，必须改写成 `fountain::f_jit.base.CallContext` / `fountain::f_jit.runtime.HandleTable`。§2.3.6 还写「宿主经 `HandleTable.get(id)` 取回对象」，进一步暗示这些类型在用户面；README §2 也把 `CallContext` 列为公开 API。再导出清单是「用户面冻结」的唯一定义（`Root.cj:20` 注释自称按 S6.11 只导出清单内声明），清单与实现不一致会让「什么算对外契约」失去判据
- **建议**：按 `design-m2/m3` 的实际用户面重写 §7.3.6：把 `CallContext`、`TypeToken`、`Version`（若确实要给宿主）补进 `Root.cj`，或从设计/README 的用户面清单删除；`BaseVisibility_test` 改为从根包 `import fountain::f_jit.*` 断言，才能真正测到再导出

### [一般][存量] 编译期递归下降没有嵌套上限，深嵌套源码在 `compile(source)` 内栈溢出

- **位置**：`f_jit/doc/design-m1.md:493-505`（§4.3.2 `AstExpr`/`AstStmt` 递归定义）、`f_jit/doc/design-m1.md:429`（§4.1 前端管线）、`f_jit/doc/design-m1.md:519`（`DefiniteAssignment.analyze` 数据流）；代码 `f_jit/src/compiler/Parser.cj:767`（`parseExpr`）、`:983`（`parseUnary`）、`:1002`（实参递归）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §4「无界递归：深度由输入决定」、§14.1「半成品 / 只处理部分输入」
- **证据**：静态确定 —— `parseExpr` 经一元/括号/调用实参回到自身，形成递归下降；`Parser.cj` 里的 `depth` 变量只用于括号/元组配平（`:516`、`:546`、`:616`），全文件没有递归深度计数器或拒绝阈值；设计正文对 Lexer/Parser/DA 也没有任何嵌套上限
- **描述**：`compile(source)` 是公开入口，源码长度与嵌套深度不受约束；`((((…1…))))`、连续一元运算或深层 `if` 表达式会线性消耗宿主栈，数千至上万层即可触顶（阈值需实测，不在本报告断言字节数）。后果是编译期崩溃（`StackOverflowError`）而不是 `SourceCompileException`，宿主无法按 §8.4 的统一错误通道捕获
- **建议**：Parser（以及同样递归的 `DefiniteAssignment`/`Lowerer`）加统一 depth 计数，超限抛 `SourceCompileException`（新增 `TooDeep` kind 或明确复用现有 kind）；上限与诊断码写入 §4.3/§8.4，并在 README 的「已知限制」同步

### [一般][存量] `pin` 的「同表同对象复用同 ID」与实现的「窗口内去重」不一致

- **位置**：`f_jit/doc/design-m1.md:700`（§5.3.2 `pin<T>`｜路径 B「同表同对象复用同 ID；tag 按类型 token 写」）；代码 `f_jit/src/runtime/HandleTable.cj:462-498`（只在当前窗口 `appendIds + pins` 内线性查重，注释明写「不再在全局锁内做全表线性扫描」）、`:488`（List/Map 显式排除）、`:611-629`（`pinConst` 才做全表去重）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §13「契约与实现不符」、§12.1「跨线程身份 / 状态共享」、§11「语义与命名不符」
- **证据**：静态确定 —— 实现只在**本调用窗口**已登记的 ID 里按规范键/对象身份查重；窗口外或跨调用的同一对象一律新开槽。可变容器每次 `pin` 都取新槽（`:488`），设计未写这个例外
- **描述**：设计把「同对象 ⇒ 同 ID」写成 `pin` 的契约，桥/宿主可能据此缓存 ID 或做身份比较；实际跨调用、跨窗口都不保证，第二次调用后可能拿到不同 ID，旧 ID 还会随窗口重置失效。`JitValue.Handle`「只能显式 release」的论证也建立在这个身份假设上，假设不成立时释放责任更难界定
- **建议**：把契约改写为「**同一调用窗口内**同值（不可变类型）/同对象（闭包、Any 盒、宿主对象）复用同 ID；跨调用不保证；List/Map 每次新槽」；若宿主确实需要跨调用稳定身份，另设 `pinStable` 并说明生命周期与释放责任

### [一般][存量] `initialCapacity` / `capacityLimit` 设计为无同步 `static var`，却允许运行中调整

- **位置**：`f_jit/doc/design-m1.md:703-704`（§5.3.2 两个 `static var`：「调用前可调」「运行中调大即时生效、调小不追溯」）、`f_jit/doc/design-m1.md:706`（`append` 扩容读这两个值）；代码 `f_jit/src/runtime/HandleTable.cj:149-169`（`AtomicInt64` + `mut prop`，注释 H4 明说「不再有数据竞争」）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §12.1「共享可变状态无保护 / 可见性」、§10 设计合理性
- **证据**：静态确定 —— 设计只给普通 `static var`，未指定 `Atomic`、锁或发布方式；`append`（读 cap/limit）与宿主赋值（写）并发时构成数据竞争，扩容判定可能读到撕裂/过期值。实现已改成原子属性，反证设计原文的写法不安全
- **描述**：按设计直接实现会出现「调大容量不生效」「读到旧上限提前报 16」这类不可复现问题，并行调用下更明显。文档没有写「配置只在无并发时改」或「必须原子」
- **建议**：§5.3.2 明确「两字段必须是原子读写的配置；每次开窗取一次快照（`openWindowWith` 已如此），窗口生命周期内不再重读全局值」，并把「即时生效」限定为「对**新开窗口**生效」

### [一般][存量] §8.6 卸载状态机与「code buffer 最后释放、可能仍有活跃调用」自相矛盾

- **位置**：`f_jit/doc/design-m1.md:982-985`（§8.6：`activeCalls==0 → Unloaded` 与「code buffer+fnTable（最后，**可能仍有活跃调用在执行**）」同段）、`f_jit/doc/design-m1.md:894`（§7.3.3 `unload`「超时恢复 Ready 可重试；幂等返回 true」）；代码 `f_jit/src/JitFunction.cj:239-286`（排空 `active==0` 后才 `state=2`，再在锁外 `release()`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §12.1「并发正确性」、§11「语义与注释不符」
- **证据**：静态确定 —— 状态机规定只有活跃调用归零才进入终态，此时不可能还有调用在执行；实现也把 `state=2` 放在 `active==0` 之后、`release()` 之前。同段两句只能有一句成立
- **描述**：这是卸载/释放的唯一权威描述。实现者若照括号里的「可能仍有活跃调用」去做，会把 `munmap`/`free` 提前到排空之前，直接 use-after-free；反之照状态机做，就该删掉该括号。`unload` 的「幂等返回 true」与「超时返回 false 可重试」也需要分开表述（重复卸载 true、超时 false）
- **建议**：改写为「进入 Unloading 后拒绝新调用；`active==0` 是释放的**前置条件**；资产在终态后、单线程内释放」；`unload` 契约拆成「已卸载 → true；本次成功 → true；超时 → false 且状态回 Ready」

### [轻微][存量] `DiagKind` 清单缺 4 个实际存在的 kind，文档却称「清单见 §4.3.9」

- **位置**：`f_jit/doc/design-m1.md:152`、`f_jit/doc/design-m1.md:564`（词法族 9 + 解析/名字/校验族 6）；代码 `f_jit/src/compiler/Token.cj:273-320`（另有 `NOT_ASSIGNED=:308`、`TYPE_MISMATCH=:310`、`SYNTAX_ERROR=:312`、`CODE_GEN=:319`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §13「文档过期」、§14.1「只做了一半的分支」
- **证据**：静态确定 —— 4 个 kind 都在 `DiagKind` 内、被 `DefiniteAssignment` / `ClassRegistryView` / `Diag.cj` 实际抛出，且不属于「M2/M3 增量」（设计把增量限定为 m3 的 JSON 段错误）
- **描述**：`kind` 是测试断言与宿主分支的稳定标识（§4.3.9 明写「测试按 kind 断言」）。清单少 4 项会让读者以为 `NotAssigned`/`TypeMismatch`/`SyntaxError`/`CodeGen` 是非法值，也会让「词法族逐 kind 一条用例」的覆盖要求漏掉 4 个分支
- **建议**：§4.3.9 补齐 4 个 kind 并各给一句触发条件；`CodeGen` 标明「内部不变量，不可由用户源码构造」

### [轻微][存量] 附录 B 把 `0xBE MAP_ITER_STEP` 放在「0xA0–0xAF」节，`0xB0–0xBF` 节又缺它

- **位置**：`f_jit/doc/design-m1.md:1368`（节标题「0xA0–0xAF 分配/变更区」）、`f_jit/doc/design-m1.md:1388`（`BE MAP_ITER_STEP` 行）、`f_jit/doc/design-m1.md:1390`（节标题「0xB0–0xBF …」但无 0xBE）；代码 `f_jit/src/bytecode/OpInfo.cj:331`（0xBE 归在「0xB8–0xBF」注释段）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §13「文档过期 / 结构错误」、§2「字面量复制导致漂移」
- **证据**：静态确定 —— 标题声明的区间与行内 opcode 不匹配；`0xBE` 在 B.11 中检索不到
- **描述**：这是 ISA 全表，读者按区间查 `0xBE`（Map for-in 的 STEP）会漏掉，而它恰好是 `for-in` 语义（迭代器推进/取键/取值/close）的关键指令；同时 `0xBE` 与 `0xAF` 的配对关系（BEGIN/STEP）被区间拆散
- **建议**：把 0xBE 行移到 B.11（`0xB0–0xBF`），或把 B.10 标题改成「0xA0–0xAF + 0xBE」并在 B.11 交叉引用

### [轻微][存量] `HW_CLOSE`（0x7B）在 B.7 未标 M1 `ERR_NOT_IMPL`，与 §4.3.7 校验⑧及汇编器实现相反

- **位置**：`f_jit/doc/design-m1.md:1325`（`7B HW_CLOSE`｜语义「关闭区块」、失败码「—」，无 M1 注记）、`f_jit/doc/design-m1.md:547`（校验⑧「`CALL_HOST`/`HW_OPEN`/`HW_CLOSE` M1 一律 `ERR_NOT_IMPL`」）；代码 `f_jit/src/compiler/Assembler.cj:185-186`（`HW_OPEN || HW_CLOSE` 恒拒）、`f_jit/src/backend/A64Lower.cj:388` / `X86Lower.cj:1056`（把 0x7B 降成 nop）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §13「文档内部不一致」、§3「开关打开后走进空分支」
- **证据**：静态确定 —— 汇编器对两条都拒绝，因此后端的 nop 分支在 M1 不可达；B.7 的 `HW_OPEN` 行写了 M1 注记（`1324`），`HW_CLOSE` 行漏写
- **描述**：附录 B 是「哪些指令能用」的判据；漏标会让人以为 `HW_CLOSE` 在 M1 可装载（而它实际连汇编都过不了）。同时后端/解释器为它保留的 no-op 分支是死分支，容易被误读成「M1 已支持关闭区块」
- **建议**：给 `HW_CLOSE` 补「M1 汇编期 `ERR_NOT_IMPL`」，与 B.7 的 `HW_OPEN` 行、§4.3.7 校验⑧保持一致；若后端分支只是为 M2 预留，加注释说明

### [轻微][存量] `CompiledSourceUnit.fingerprint: UInt64` 与 §3.3.8 的 FNV-1a-128 冲突，且该字段全仓无读取

- **位置**：`f_jit/doc/design-m1.md:563`（`fingerprint: UInt64`（源码指纹），并称「根包：`FbcReader.load(raw)` 加载校验 + 缓存键（§8.1）」）、`f_jit/doc/design-m1.md:414`（源码指纹 = **FNV-1a-128**）；代码 `f_jit/src/compiler/SourceCompiler.cj:55`（`public let fingerprint: UInt64`）、`:130-132`（`Fnv128.fnv1a(src)` 后 `h.left` 截断低 64 位）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §1「读了不用」、§2「同一事实两处定义漂移」、§13
- **证据**：静态确定 —— 128 位指纹无法装进 `UInt64`；实现显式截断，注释「缓存键只需稳定、不要求抗碰撞到 128 位」；`grep -rn "\.fingerprint"` 在 `CompiledSourceUnit` 上零读取（缓存键由 `CompilePipeline.cj:60` 重新对源码算 `fnv1a128`）
- **描述**：设计把该字段定为缓存键的来源，实现里它既不是 128 位、也没人读；真正的键在管线层重算。读者若按设计认为「去重靠这个字段」会低估碰撞面，也解释不了为什么 `SourceCompiler` 还要取一次 FNV-128（重复计算）
- **建议**：把字段改成 `UInt128` 并由管线直接使用（删掉重算），或删除该字段、§4.3.9 注明「指纹由 `CompilePipeline` 计算，`CompiledSourceUnit` 不携带」

### [轻微][存量] 「ctx / 转储是全过程仅有的两块 GC 管辖外内存」与 CodeBuffer / FnTable / ConstMirror 矛盾

- **位置**：`f_jit/doc/design-m1.md:689`（「ctx 与转储缓冲是全过程仅有的两块 GC 管辖外内存」）、`f_jit/doc/design-m1.md:689`（释放机制「只保留一种收尾机制」）；代码 `f_jit/src/backend/CodeBuffer.cj:53-64`（`mmap` 代码内存）、`f_jit/src/backend/NativeAssets.cj:71-83`（`FnTable` = `LibC.malloc`）、`:155`（`ConstMirror.build`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §13「文档内部矛盾」、§11「资源不对称」；本部分审查重点「句柄与资源生命周期」
- **证据**：静态确定 —— 三块资产都由 `JitExecutor` 持有、`release()` 释放（`JitExecutor.cj:34-37`、`:185`），既不在仓颉堆，也不经 `JitFunction` 的 `finally` 释放
- **描述**：这句话的本意应是「桥自己 `malloc/free` 的只有 ctx 与 dump」，但写成「全过程仅有两块」会让资源审计只盯这两块，漏掉代码内存、fnTable、常量镜像（三者恰是最容易泄漏的原生资产）。`f_jit` 已有 `NativeAssets.liveCount` 之类的计数设施，文档口径应与之一致
- **建议**：改成「桥以 `malloc/free` 直接管理的是 ctx 与转储缓冲；代码内存/入口表/常量镜像由 `JitExecutor` 管理（mmap/malloc），生命周期见 §6.3 / §8.7」

### [轻微][存量] 设计层面的失败缓存无淘汰（按源码无界），实现以 256 条上限兜底但文档未记载

- **位置**：`f_jit/doc/design-m1.md:914`（状态机 `Idle→Compiling→Ready/Failed`，未写 `Failed` 的清理/上限）；代码 `f_jit/src/CompileCache.cj:95`（`FAILURES_MAX = 256`）、`:98-107`（到上限整表清空）、`:167-174`（`remove` 才清理）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §5「无界容器 / 缓存键无界」、§13「文档缺关键限制」
- **证据**：静态确定 —— 设计只描述状态迁移，没有容量、TTL 或淘汰；实现承认「按源码指纹累积，长期运行会无限增长」并用 256 条上限兜底（`CompileFailureCache_test.cj:38-66` 断言 ≤256）
- **描述**：按设计实现会得到一个「持续喂坏源码就无界增长」的进程级表；虽然当前实现已加界，文档没写这条界，读者无法从设计得知「失败缓存是冷路径、会被整表清空」这一重要行为（也解释不了为什么注册表变更要 `invalidateFailures`）
- **建议**：§7.3.5 补「失败条目有界（当前 256，触顶整表清空）；注册/注销/类注册变更时整体失效」，并说明这不是 LRU 而是「冷路径可重编」的取舍

### [轻微][存量] 附录 E 第 58 条仍写「x86_64 整单元 lowering 未补齐、`BackendX86_64.compile` 保持降级解释器」，实现已接通

- **位置**：`f_jit/doc/design-m1.md:1680`（「仍待补齐：x86_64 的整单元 lowering（P5.8）。`BackendX86_64.compile` 保持『降级解释器』…」）；代码 `f_jit/src/backend/X86Compiler.cj:35-60`（真实 lowering：prologue + `X86Lower` + 收敛块）、`f_jit/src/backend/JitCompiler.cj:87`（`'x86_64' => X86Compiler.compileFunctionWith(...)`）、`f_jit/src/backend/BackendSelector.cj:89-101`（`BackendX86_64.compile` 逐函数调用 `X86Compiler`，失败才 `false`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §13「文档过期：写着『暂不支持』其实已支持」
- **证据**：静态确定 —— `BackendX86_64.compile` 不再是 stub；`JitExecutor.create` 在 x86_64 上直接走 `JitCompiler.compileUnitWith`（`JitExecutor.cj:77`）
- **描述**：读者会据此认为 x86_64 永远只能解释执行，从而误判性能与部署面（README 与测试都按「JIT 可用」写）；这条过期结论还留在「实施偏差与修正记录」里，看起来像最新状态
- **建议**：把该条改成「x86_64 单函数 lowering 已接通（`X86Compiler`），剩余风险是部分指令返回 `None` 导致整单元降级」；若仍有个别片段未实现，逐条列出指令名而不是整体判死

### [轻微][存量] `3e2` 的 Decimal scale 示例写错（-3 应为 -2）

- **位置**：`f_jit/doc/design-m1.md:1052`（附 A.1「`3e2` → scale=-3」）；代码 `f_jit/src/compiler/Lowerer.cj:3879`（`scale = 小数位数 − 指数`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §13「文档与实现不一致」、§11「与规格 / README 冲突」
- **证据**：静态确定 —— `3e2` 无小数位、指数 +2 ⇒ `0 − 2 = -2`；`1e-3` ⇒ `+3`。文档把 `3e2` 写成 -3 是符号/位数错位
- **描述**：这是 Decimal 字面量构造的数值口径示例，实现者按文档写会得到 `3×10^3 = 3000` 而不是 `300`，影响常量值、常量指纹与差分黄金值
- **建议**：改为「`3e2` → scale=-2、`1e-3` → scale=3」，并补 `1.5e-2` 把「小数位 + 指数」公式写全

### [轻微][存量] `Version.HDR_SIZE = 36` 缺「magic 之后」限定，与 40 B payload 冲突

- **位置**：`f_jit/doc/design-m1.md:279`（§2.3.11「新布局头长度（旧单元 32）」）、`f_jit/doc/design-m1.md:402`（§3.3.8「容器头（40 B payload 起点）」）、`f_jit/doc/design-m1.md:403`（字段偏移 0…36）；代码 `f_jit/src/base/Version.cj:96-99`、`f_jit/src/bytecode/FbcHeader.cj:79-81`（`payload = 4 + HDR_SIZE = 40`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §13「文档内部不一致」
- **证据**：静态确定 —— 实现明确 `hdrSize` 是「magic 之后的部分」；设计只写「新布局头长度 36」，与 §3.3.8 的 40 B 起点字面冲突
- **描述**：按 §2.3.11 字面理解「头长度 36」会与 §3.3.8 的 40 B 起点差 4 字节，`.fbc` 读写偏移容易错位
- **建议**：§2.3.11 补「= magic 之后的头长度；payload = 4 + 36 = 40」，旧布局写「4 + 32 = 36」

### [轻微][存量] helper 73–76 已登记，但 §5.3.4 / B.7 / C.4 三张编号表未回填

- **位置**：`f_jit/doc/design-m1.md:724-725`（§5.3.4「H01–H62 对应 1–62；63–68 保留；69–72 增量」）、`f_jit/doc/design-m1.md:1319`（B.7 `CALL_HELPER` 的 hid 范围「1–62、69–72」）、`f_jit/doc/design-m1.md:1575-1583`（C.4 路由表）、`f_jit/doc/design-m1.md:1623-1627`（附录 D 新增 73–76）；代码 `f_jit/src/runtime/HelperId.cj:115-118`（`DATETIME_NOW=73 / DATETIME_PARSE=74 / DATETIME_OF=75 / DURATION_PARSE=76`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §2「同一张表散落多处导致行为漂移」、§13「文档过期」
- **证据**：静态确定 —— 正文三张表都停在 72，附录 D 才出现 73–76；`HelperId` 实际已登记到 84（78–84 为 M3 的 Any/JSON/`ipow`），`MAX_FIXED` 仍是 72（`HelperId.cj:125`），正文与代码的编号面不一致
- **描述**：同一事实维护四份（§5.3.4 族表、B.7 操作数说明、C.4 路由表、D 段增量）。读者按正文查 73–76 会得到「未分配」，按 `HelperId` 查又会发现 73–76 已用于 DateTime/Duration 构造；后续再加 helper 必然重复出错
- **建议**：数值只保留一处权威（`HelperId` + 一张表），其余章节改为引用；至少把 73–76 回填 §5.3.4 / B.7 / C.4，并注明 `MAX_FIXED` 随增量更新

<!-- 第 3 部分 -->

### [一般][存量] 并行调用文档状态行写「未实施」，与 §9「P0–P6 已落地并归档」相反，§1「现状」仍描述已删除的实现

- **位置**：`f_jit/doc/design-parallel-call.md:3`（状态行）、`:9-21`（§1 现状表）
- **来源**：存量（工作区快照，无基线可比）
- **判据**：review-checklist §13（文档过期 / 与实现相反）、§14（能力未接线口径）
- **证据**：静态确定 —— 文档第 3 行写「状态：**已设计、未实施**」，而同一文件 `:223`「已落地（P0–P6）」、`:249`「P6 → 已完成并归档」、`:251`「调用链不再有任何每调用一次的全局锁」；§1 所列「现状」在代码中已全部不成立：`JitFunction.cj` 已无 `callMtx`（仅 `:47`/`:500` 两处注释提及），`RuntimeEnv.cj:41-51` 的 `deadline` 已随 `stateTls`（`ThreadLocal<RuntimeState>`）改为线程私有，`HandleTable.cj:86` 已是 `FreeStripes`（分片锁）而 §1 `:15` 引用的 `HandleTable.cj:88-141` 现在落在 `FreeStripes` 定义区（`:86` 起），`envMtx`、`freeSlots` 全仓已无实现（`src/` 内仅剩注释）。
- **描述**：读者按第 3 行判断该能力「未实施」，会把 `:9-21` 当成现行瓶颈去重做一遍；而 `:13`/`:14`/`:19` 的行号引用（`JitFunction.cj:49/150`、`backend/JitExecutor.cj:37/126/150`、`RuntimeEnv.cj:30`）指向的代码已不存在，按引用去核对会得到错误结论。文档自身没有「§1 为设计前快照」的标注。
- **建议**：状态行改为「已实施（P0–P6，2026-11-26，后续优化 2026-11-27）」；把 §1 整体加一句「以下为设计前现状（历史），当前实现见 §9」并删除/刷新已失效行号；`HandleTable.cj:88-141` 的引用改成「分片空闲表前的全局 `freeSlots`」并去掉行号。

### [一般][存量] P6 验收门槛「8 线程 ≥ 5× 单线程」未达成，文档却记「P6 已完成并归档」

- **位置**：`f_jit/doc/design-parallel-call.md:170`、`:210`（门槛），`:233`（实测），`:249`（结论）
- **来源**：存量（工作区快照，无基线可比）
- **判据**：review-checklist §8（性能结论必须给对照与门槛）、§13（文档结论与数据相反）
- **证据**：静态确定 —— `:170`/`:210` 写验收「8 线程 ≥ 5× 单线程」，`:233` 实测「2/4/8 线程 = 1.27×/2.40×/1.91×（共享 7 核 VM，8 线程超订）」；`:249` 仍记「P6 → 已完成并归档」，`:253`「验收：全量 1210 用例（1209 通过 + PerfOverride_test 高负载假失败）」。
- **描述**：同一文档内「门槛」与「实测」相差 2.6 倍，且 8 线程比 4 线程还低（1.91× < 2.40×），这是超订导致的真实扩展性上限信号；文档既未判定门槛失效、也未把结论降级为「共享 VM 下的参考值」，直接以「已归档」收口，会让后续优化误以为并行度已达标。`PerfOverride_test` 的「高负载假失败」同样只有断言、没有「为何是假」的证据。
- **建议**：把 `:170`/`:210` 的门槛改为**按环境分段**（独占核 N 核 ≥ X×、共享 VM 仅记录参考值），或在 `:233` 明确「门槛未达成，已按实测修订」；`:249` 的「归档」补一句「性能门槛未达成，转 P6b 待优化」，并把 8 线程低于 4 线程的现象作为已知结论写进风险表。

### [一般][存量] `HelperId` 增量表仍是旧编号 66/67/68/73/74/75，与同文档 §5.0 和实现 78–83 冲突

- **位置**：`f_jit/doc/design-m3.md:144`（§5.4 `HelperId` 行）；对照 `:98-102`（§5.0）、`:106-122`（§5.1/§5.2）、`:379`（附 B）
- **来源**：存量（工作区快照，无基线可比）
- **判据**：review-checklist §13（配置/常量与源码不符）+ §2（同一事实多处重复 → 漂移）
- **证据**：静态确定 —— `:144` 写 `H_ANY_BOX=66`、`H_ANY_IS=67`、`H_ANY_AS=68`、`H_JSON_GET=73`、`H_JSON_SET=74`、`H_JSON_NEW=75`，同一行的备注却写「JSON 面 v0.3.15 顺延 H81–H83」；`src/runtime/HelperId.cj:102-107` 实为 `ANY_BOX=78 / ANY_IS=79 / ANY_AS=80 / JSON_GET=81 / JSON_SET=82 / JSON_NEW=83`（`src/compiler/Ops.cj:247-253` 同值），且 `:98-102` 明写「旧编号 … 在本文档 … **已全部替换**」。
- **描述**：73–76 在代码中已被时间/间隔构造占用（`DATETIME_NOW/PARSE/OF=73/74/75`、`DURATION_PARSE=76`、`CAST_FAIL=77`，见 `HelperId.cj:99`、`:115-118`），按 `:144` 分配编号会与既有 helper 撞号；66/67/68 在 `HelperId.cj` 已属保留区，而 §5.0 自己也宣告「66–68 已被占用」，同一份文档对这三个号给出两种状态。§5.0 声称旧编号「已全部替换」，实际未替换，属于典型的「同一张表在正文/附录重复、只改了一处」。这一行还写 `HelperId` 常量为 `H_ANY_BOX` 前缀，代码里没有 `H_` 前缀。
- **建议**：`HelperId` 行改为 `ANY_BOX=78 / ANY_IS=79 / ANY_AS=80 / JSON_GET=81 / JSON_SET=82 / JSON_NEW=83`，并删掉「编号接 H65 之后」的旧措辞；长期建议只保留 §5.1/§5.2 一处编号定义，§5.4 用「见 §5.1/§5.2」引用，避免第三次漂移。

### [一般][存量] 验签口径自相矛盾：§5.1.2 / §9 / §10 M2-1 仍称「单次 `is` 主线成立」，§11 已认定该方案语言上不可实现

- **位置**：`f_jit/doc/design-m2.md:171`（§5.1.2 `verify` 行）、`:380`（§9 决策行）、`:391`（§10 M2-1）；对照 `:474`（§11 第 1 条）
- **来源**：存量（工作区快照，无基线可比）
- **判据**：review-checklist §13（文档自相矛盾 / 与实现相反）
- **证据**：静态确定 —— `:171` 写「验签 = **单次 `is (T1..Tn) -> R`**」、`:380` 写「验签口径 = 单次 `is (T1..Tn) -> R`（语言子类型语义）」、`:391` 写「**已实测确认** … `is` 支持函数类型 … **结案**——主线验签成立」；`:474` 写「**原方案语言上不可实现**：`T`/`R` 是运行期数据，`is` 右侧须静态类型，物化路径为 11^(n+1) 分支」。实现侧 `src/runtime/Signature.cj:92-97` 注释给出同一结论，主线是 `verifyReflective`（`Signature.cj:111`，`FunctionTypeInfo.of` 逐位比对），旧 `verify` 仅保留 0–2 元（`Signature.cj:169`），`CallMarshal.cj:177` 走的是 `verifyReflective`。
- **描述**：§11 是「实施偏差回写」，但它只说「本节记不一致」，没有把正文标为作废；`:391` 尤其危险——它宣称该方案「已实测确认、主线成立、结案」，是后续实现与测试的**选型依据**，而事实相反。按 `:171` 实现会得到只对 0–2 元、不校验具体类名的验签器（即代码里被 GAP-04/05 修掉的那一版）。
- **建议**：`:171`/`:380`/`:391` 就地加「**已被 §11 第 1 条废止**」，或直接改写为「`FunctionTypeInfo.of` 逐位比对」；`:391` 的「已实测确认」改成「已实测确认 `is` 支持函数类型，但**无法**用于运行期签名比对（见 §11-1）」。

### [一般][存量] §9 决策行称「非闭包实例 `close` → 19、`isClosed` = false」，与 §6.1.4 和实现的 `Resource` 契约相反

- **位置**：`f_jit/doc/design-m2.md:383`（§9 最后一行）；对照 `:256-258`（§6.1.4）
- **来源**：存量（工作区快照，无基线可比）
- **判据**：review-checklist §13（文档自相矛盾）、§11（契约与实现不符）
- **证据**：静态确定 —— `:258` 写「**`Resource` 契约**：入口实例 `close(timeoutMs)` 卸载**单元** … 包装实例 `close(timeoutMs)` 释放本闭包」；`:383` 写「（非闭包实例：`close` → 19、`isClosed` = false）；`unload` 保持**单元级**不变」。实现与 `:258` 一致：`JitFunction.cj:227-232` 由 `owner.isSome()` 分派，入口实例走单元卸载，`:471-475` `isClosed()` 对入口实例返回 `state == 2`。
- **描述**：两句话对**入口实例**给出互斥语义（报错 vs 卸载）。按 `:383` 实现会让 `JitFunction` 无法满足 `Resource` 契约（`close()` 必然抛 19），M1 的 `unload` 语义也会断掉；`:383` 还把 `close` 与 `unload` 说成两个东西，而代码里 `unload` 就是入口 `close`。
- **建议**：删除 `:383` 括号内的「非闭包实例：`close` → 19、`isClosed` = false」，改为「入口实例 `close` = 单元卸载、`isClosed` = 已进终态（同 §6.1.4）」。

### [一般][存量] design-m2 未回写 M2.2 / M2.3 两个增量，且自称权威版本 v0.8.33 而规格已到 v0.8.34

- **位置**：`f_jit/doc/design-m2.md:3`（依据写 v0.8.28）、`:39-43`（§1「包与声明增量总览」）、`:469`（§11 写「权威语义以 v0.8.33 为准」）
- **来源**：存量（工作区快照，无基线可比）
- **判据**：review-checklist §13（文档过期）、§14（声明总览不完备 → 增量未接线口径）
- **证据**：静态确定 —— `doc/jit-bytecode-m2.md:3` 的版本日志已推进到 **v0.8.34**，新增「M2.3：裸 `as T` 合法（失败置 **7 BAD_CAST**）；`as T ?? V` 惰性取 `V`；下转型/类名未跟踪落到运行期 `$as$<C>`；新增固定 helper **H77 `cast_fail`**；新增 `@JitSignatures` 宏」。这些在 `design-m2.md` 中**一次都没有出现**（对 `SignatureRegistry`/`parents`/`cast_fail`/`H77`/`JitSignatures`/`as T ??` 全量 grep 均 0 命中），但代码已落地：`src/base/ClassRegistration.cj:174` `ClassDescriptor.parents`（注明 M2.2）、`src/compiler/Ops.cj:245` `CAST_FAIL=77`、`src/compiler/Lowerer.cj:2872-2896`（`$as$` 运行期判定 + H77）、`src/macros/JitSignature.cj:47` `@JitSignatures`。另有 M2.2 的类型化 adapter（`src/runtime/Signature.cj:375` `HostCallback.adapter`、`src/AdapterRegistry.cj`）同样未进 §1 总览。
- **描述**：§1 声称列出 M2 的**全部**新增声明与受影响声明，实际缺三类能力（M2.2 类型化 adapter + `ClassDescriptor.parents`；M2.3 `as` 收窄转型 + H77 + `@JitSignatures`）；`:3` 与 `:469` 两个「权威版本」还互相不一致（v0.8.28 vs v0.8.33），而两者都已落后于规格。只按本文件实施的人会漏掉运行期 `as` 路径，把 `as` 当纯编译期动作，错误码写成 7/22 之外的第三种或不报错。
- **建议**：`design-m2.md` 增「§11.1 M2.2 增量」「§11.2 M2.3 增量」两节（照 §11 表格体例），§1 总览补 `SignatureRegistry`/`HostCallback.adapter`/`ClassDescriptor.parents`/`H77`/`@JitSignatures`；`:3` 与 `:469` 统一改为当前规格版本。

### [一般][存量] M3-7「`as` 在左值非 15 时不经 helper、7 只出自 CAST」已被 M2.3 推翻，却被当作「结构性不重叠」的依据

- **位置**：`f_jit/doc/design-m3.md:287`（M3-7「为什么分列站得住」）
- **来源**：存量（工作区快照，无基线可比）
- **判据**：review-checklist §13（规格与实现漂移）、§11（契约与实现不符）
- **证据**：静态确定 —— `:287` 写「`as` 在**左值静态类型非 15** 时不经 helper（上行零操作 / 不相容 = 编译错误）⇒ 22 只出自盒面；7 只出自 `CAST`——**结构性不重叠**」。M2.3（`doc/jit-bytecode-m2.md:3`）已把非盒 `as` 改为「编译期优先 + 运行期兜底」，实现 `src/compiler/Lowerer.cj:2872-2896`：类名未跟踪时插入 `$as$<C>` 调用，失败分支发 `CALL_HELPER H77`（`CAST_FAIL`，恒置 7）；`src/compiler/Ops.cj:245`。
- **描述**：「22 只在盒面」仍成立，但「7 只出自 `CAST`」在**行为上也不成立**了——非 15 的 `as` 在类名未跟踪时经 H77 同样产出 7，两种码按接收者类型分派而非按来源分派。`:288` 的再启条件「若真出现串号（如把 `as` 的非盒路径接去 `CAST`）」描述的正是 M2.3 已落地的形态，读起来像「未发生」，会误导 T38 对拍用例的设计（例如断言非盒 `as` 不产生 helper 调用）。
- **建议**：`:287` 改为「22 只在 15 盒面（H80）、7 在 `CAST` 与 `H77 cast_fail`（非盒 `as` 运行期兜底）——**按接收者类型分派**，不按错误码来源分派」；`:288` 的再启条件改为「若出现同一接收者类型同时产出 7/22」。

### [一般][存量] `SignatureDescriptor.validate` 合法集仍写 0–8/10–11/14，与 M3「JSON 可作签名」和实现（含 16–19）冲突

- **位置**：`f_jit/doc/design-m2.md:170`（validate 行）；对照 `f_jit/doc/design-m3.md:81`（TypeRef JSON 可作签名）、`f_jit/doc/design-m3.md:379`（附 B helper 形参 16）
- **来源**：存量（工作区快照，无基线可比）
- **判据**：review-checklist §13（API/合法集与源码不符）
- **证据**：静态确定 —— `design-m2.md:170` 写「合法性（T/R ∈ 0–8、10–11、14；12/13 拒）」；实现 `src/runtime/Signature.cj:80-84` 的 `isLegalCode` 额外放行 `JSON_VALUE–JSON_NULL`（16–19，注释标「m3 §11 JSON 码 16–19 零注册」）。`design-m3.md:81` 明确「JSON 类型可作**参数 / 返回 / 局部 / 签名**（含跨桥）」，但 m3 全文没有一句回写「`SignatureDescriptor.validate` 合法集扩至 16–19」。
- **描述**：跨桥时 JSON 形参/返回要进 `SignatureDescriptor`，按 m2 `:170` 的规则会被判非法 → 验签失败 → 19。M3 只声明了能力、没声明被改的校验规则，交叉引用断链。
- **建议**：`design-m3.md` §1 `base` 行或 §5.1 补「`SignatureDescriptor.isLegalCode` 合法集 = 0–8/10–11/14/16–19」；`design-m2.md:170` 加「M3 起扩至 16–19（见 design-m3 §1）」。

### [轻微][存量] 特化面 API 名与实现不符（`plan`/`size`/`marshalArgs`/`plan` 可变性/开关归属）

- **位置**：`f_jit/doc/design-m3.md:132`、`:133`、`:134`、`:136`、`:159`；`f_jit/doc/design-m2.md:163`
- **来源**：存量（工作区快照，无基线可比）
- **判据**：review-checklist §13（API 与源码不符）
- **证据**：静态确定 —— 文档称 `SignatureTable`（protected class，`:132`）有 `func plan(sig)`（`:132`）与 `func size()`（`:133`）；实现为 `public class SignatureTable`（`src/runtime/SignaturePlan.cj`），方法名 `getOrBuild`（`:141`）与 `entryCount`（`:189`），另有 `buildCount`。文档称 `SignaturePlan.marshalArgs(args: CPointer<Int64>, out: …)`（`:134`），实现为 `marshalArgs(a: Array<Int64>): Array<Any>`（`SignaturePlan.cj:82`）。文档称 `HostCallback.plan` 是 `var`、在「验签完成时绑定」（`design-m3.md:136`；`design-m2.md:163` 同样写 `var plan`），实现是 `public let plan`（`src/runtime/Signature.cj:383`），在 `HostCallback` 构造时 `SignatureTable.getOrBuild(sig)` 绑定（`:391`）。文档 `:159` 把「特化开关（强制通用 / 强制特化）」挂在 `CompilePipeline`，实际开关是 `SignatureTable.enabled`（`SignaturePlan.cj:135`），`CompilePipeline.cj` 对该符号零引用。
- **描述**：不是语义错误，但四处在同一节内，按文档写会找不到符号；`:136` 的「验签完成时绑定」与实际「装箱时绑定」在时序上也不同（影响失效面判断：条目在验签前就可能持有 plan）。
- **建议**：按实现改名为 `getOrBuild`/`entryCount`/`marshalArgs(Array<Int64>): Array<Any>`；`plan` 改 `let`、绑定时机改「条目构造（装箱）时——m3 §5.3 原文『验签即建』的实现落点」；`:159` 的开关归属改为 `SignatureTable.enabled`。

### [轻微][存量] M2 声明表与实现签名不符（`HostCallback.sig` 可空、`ClassRegistry` 三个解析方法实为顶层函数）

- **位置**：`f_jit/doc/design-m2.md:161-162`（HostCallback 成员）、`:226`（ClassRegistry 解析辅助）
- **来源**：存量（工作区快照，无基线可比）
- **判据**：review-checklist §13（声明与源码不符）
- **证据**：静态确定 —— `:162` 写 `let sig: SignatureDescriptor`（非空），实现是 `public let sig: ?SignatureDescriptor`（`src/runtime/Signature.cj:354`，`None` = 未验签，`:349` 注释与 `cached` 的 `:341-343` 都依赖可空语义）。`:226` 写 `ClassRegistry` 的成员 `func classOfField(...)` / `classOfMethod(...)` / `classOfCtors(...)`，实现是 `src/ClassRegistry.cj:197/211/225` 的**顶层** `protected func classFieldOf(desc, field)` / `classMethodOf(desc, method)` / `classCtorsOf(desc)`（首参是描述符，不是 `this`）。
- **描述**：`sig` 的可空性是「缓存 = 条目字段存在性」这一设计（§5.1.2 `cached`）的载体，写成非空会让实现者做不出「已验签/未验签」区分；解析辅助的形态差异会造成按名搜不到（`ClassRegistry.classOfField` 全仓 0 命中）。
- **建议**：`sig` 改 `?SignatureDescriptor` 并注明 `None` = 未验签；`:226` 改为 `classFieldOf/classMethodOf/classCtorsOf`（顶层 protected，首参 `?ClassDescriptor`），或明确写出它们是 `ClassRegistry` 的门面包装。

### [轻微][存量] M3-5 仍标「待实施」，其两项待办（`cjpm` 依赖、加载期防御拒绝）均已落地

- **位置**：`f_jit/doc/design-m3.md:271-276`（M3-5 标题与「剩余仅 … 两项待办」）
- **来源**：存量（工作区快照，无基线可比）
- **判据**：review-checklist §14（接线缺失的反面：已接线却记未完成）、§13（文档过期）
- **证据**：静态确定 —— `:272` 要求「`f_jit/cjpm.toml` 增 `fountain::f_data` 依赖」，`f_jit/cjpm.toml:21` 已有 `"fountain::f_data" = {path = "../f_data"}`；`:273` 要求「加载器对解析失败防御拒绝」，`src/bytecode/ConstRegistry.cj:432-437` `parseJsonConst` 在 `JsonValue.fromStr` 异常时 `rejectFormat('JSON 常量解析失败 …（M3 §11 加载期防御拒绝）')`，`ConstRegistry.cj:169` 在 `PJson` 分支调用它。
- **描述**：`:275` 的「现状核查（2026-10-13）… 剩余仅『cjpm 依赖 + 防御拒绝』两项待办」在实现完成后未更新，读者会重复排期。
- **建议**：M3-5 状态改为「已结案（依赖与防御拒绝均已落地，位置：`cjpm.toml:21`、`ConstRegistry.cj:432`）」。

### [轻微][存量] H79 失败码只列 8、并称「纯读」，实现经 `$as$<C>` 可抛 21

- **位置**：`f_jit/doc/design-m3.md:109`（H79 行）；对照 `:169`（§7.1「问答 = 纯读」）、`:232`（§9「is/as 纯读 ⇒ 重放安全」）
- **来源**：存量（工作区快照，无基线可比）
- **判据**：review-checklist §13（错误码面与实现不符）、§12.1（失败路径 / 异步语义）
- **证据**：静态确定 —— `src/runtime/AnyHelpers.cj:52-63` 的 `anyIs` 在 `anyMatches` 命中 14 型时进入 `case 14`（`AnyHelpers.cj:160-161`），后者调用 `classBoundHit`；`classBoundHit`（`AnyHelpers.cj:177-196`）在判定体抛出普通异常时经 `:190-191` 转成 `HOST_EXCEPTION`（21），条目缺失 / 签名不符 / 返回非 Bool 则 `HANDLE_TYPE`（8）。
- **描述**：H79 的失败面是 {8, 21}，不是文档写的仅 8；它也不是严格意义的「纯读」——14 类界判定要执行一次宿主侧 helper。对盒与句柄表确实无写入，所以 §9 的「重放安全」结论不一定错，但前提没有被文档写清（失败即终止、不产生可观察副作用）。
- **建议**：H79 失败码改为 `8, 21`；§9 决策行补「纯读指不修改盒 / 句柄表；14 类界判定经 `$as$<C>`，失败 21 即 fail-fast 终止，重放不受影响」。若要求 `is` 永不失败，可把 `classBoundHit` 的异常降级为「不命中」，但那会改变错误码契约，需用户拍板。

### [轻微][存量] Map 的 `aux` 写「键码 << 8 | 值码」，实现只校验值码，键类型不可区分

- **位置**：`f_jit/doc/design-m3.md:112`（类型描述符）、`:114`（容器转型「精确区分」）、`:356`（附 A 同表述）
- **来源**：存量（工作区快照，无基线可比）
- **判据**：review-checklist §13（规格与实现漂移）、§11（语义与规格不符）
- **证据**：静态确定 —— 前端确实压入 `(键码 << 8) | 值码`（`src/compiler/Lowerer.cj:2667`），但运行期 `mapAuxMatches`（`src/runtime/AnyHelpers.cj:217-221`）只检查 `(aux & 0xFF) == ANY`（或 `0xFFFF`），**完全忽略键码**；注释明确写键码被 `ConstMapKey` 包装擦除，「无法也不应校验」。因此 `box is Map<String,Any>` 对 `Map<Int64,Any>` 同样返回 1，`as Map<String,Any>` 同样命中。
- **描述**：文档把 `aux` 定义为「键码 + 值码」并声称按 `(typecode, aux)` 精确区分，但键维度实际不参与判定；这是**静默命中**（不报 22），使用者无法用 `is/as` 排除键类型不符的 Map。与发现 #8（签名合法集）同属「M3 能力声明未回写校验面」。
- **建议**：§5.1 / §5.2 / 附 A 补一句「Map 键类型在 `ConstMapKey` 处擦除，`is/as` 只校验值码；键类型一致性由宿主契约保证」；若要键级判定，需在 `ConstMapKey` 保留键码或改走宿主 `is HashMap<String,Any>`，并补 T38 正负用例。

<!-- 第 4 部分 -->

### [严重][存量] #1 AArch64 的 `DUP2`（0x18）降低把顶两格顺序颠倒，与 §5 语义和解释器不一致

- **位置**：`src/backend/A64Lower.cj:208-212`（`x9=[x20]`、`x10=[x20+8]`，`pushX(9)` 再 `pushX(10)`）；规范同错：`doc/jit-bytecode-m1.md:2083`（A64 列 `stp x10,x9,[sp,#-16]!`）；定义侧 `doc:247`（`DUP2: a b → a b a b`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11「契约与实现不符」；§0 I7 / §12.7「三引擎逐位一致」
- **证据**：静态确定 —— 以栈底→栈顶 `1,2` 为例：
  - 解释器 `src/runtime/Interp.cj:286-290`：`b=顶=2`、`a=次顶=1`，`push(a)`、`push(b)` ⇒ `1,2,1,2` ✓
  - x86 `src/backend/X86Lower.cj:801-804`：两次 `pushMemRsp(8)`，第二次读到已被下移的 `[rsp+8]`(=b) ⇒ `1,2,1,2` ✓
  - aarch64：压 2 再压 1 ⇒ `1,2,2,1` ✗（等价「复制顶两格后交换」）；§12.4 的 `stp x10,x9,[sp,#-16]!` 把 `a` 放在更低地址（=新栈顶），同为 `a,b,b,a`
- **描述**：后端语义错误而非笔误。前端当前不发射 `DUP2`（`Op.DUP2` 仅见于 `src/compiler/Ops.cj:46` 与栈效应表），故现有 `compile(source)` 产物不受影响；但分发入口接受的任意 `.fbc` 若含 `0x18`，aarch64 结果与解释器/x86 不同，直接违反 I7。一旦前端启用 `DUP2`，影响面扩大到全部平台差异用例
- **建议**：A64 改为先压次顶再压顶（`pushX(10)`→`pushX(9)`），或 `stp x9,x10,[sp,#-16]!`（`x9`=顶时把顶放低地址）；同步修 §12.4 A64 列；补 T2 差分用例（`PUSH 1/2 + DUP2 + 4×POP/RET`，断言 `1,2,1,2`）

### [严重][存量] #2 文档承诺的分发入口 `compile(unit: SourceUnit)` 在公开 API 上不存在

- **位置**：规范 `doc:762`（`public func compile(unit: SourceUnit): JitFunction`）、`doc:1065`（§8.4 同名方法）；实现 `src/Compiler.cj:185`（只有 `compile(source: String)`）、`src/CompilePipeline.cj:51`（`protected class CompilePipeline`）、`:95`（`public static func runUnit(raw: Array<UInt8>, c: Compiler): JitFunction`，但类不可达）、`src/base/SourceUnit.cj`（唯一消费者是测试）
- **来源**：存量（快照）
- **判据**：review-checklist §14.1「承诺了但没实现」、§13「示例代码不能用」
- **证据**：静态确定 —— `grep "func compile("` 全仓只有 `Compiler.compile(source: String)` 与后端 `Backend.compile(unit: LoadedUnit, …)`，无接收 `SourceUnit` 的公开入口；承载分发管线的 `CompilePipeline` 为 `protected`（模块内可见），`public static runUnit` 随类一同不可达；`SourceUnit` 仅被测试构造；管线还忽略 `SourceUnit.entryFn`（改用容器头），即便公开也与文档语义不同。底层公开件只能拿到 `LoadedUnit`/`JitArtifacts`，`JitFunction` 的 public 构造只收闭包（`src/JitFunction.cj:117-134`），不构成 `unit → JitFunction` 统一入口
- **描述**：分发模型（T1 黄金字节码、共享管线与缓存、装载 user hid → 拒绝）是 §8/§8.4/§11.8 的核心承诺，但用户面能把 `.fbc` 变成 `LoadedUnit`，却没有公开途径变成可调用的 `JitFunction`——按文档写 `compiler.compile(unit)` 直接编译失败，只能自行复刻桥（ctx、常量镜像、句柄表、转储缓冲）。这是契约能力缺失，不是改名
- **建议**：二选一——补 `public func compile(unit: SourceUnit): JitFunction` 并明确 `entryFn` 取 `unit.entryFn` 还是容器头；或撤回 §8 ①b / §8.4 / §11.8 的「分发装载」与 `SourceUnit`。无论哪种都补一条公开面可达性用例

### [一般][存量] #3 门面签名漂移：`unload`/`isUnloaded` 实为 `close`/`isClosed`，`Compiler.init` 与 `unregisterFunction` 形态亦不同

- **位置**：规范 `doc:785-786`（`unload(timeout!: ?Duration = None)` / `prop isUnloaded`）、`doc:1049-1057`（`init(name!: = "compiler", opts!: , maxPredefined!: = 256)`、`unregisterFunction(name): Unit`）、`doc:1228-1230`；实现 `src/JitFunction.cj:227`（`close(timeoutMs: Int64): Bool`）、`:471`（`isClosed()`）、`:523`（`close(): Unit`）、`src/Compiler.cj:61`（位置参数 `init`）、`:87`（`unregisterFunction(...): Bool`）
- **来源**：存量（快照）
- **判据**：review-checklist §13「API/默认值与源码不符」「示例不能用」
- **证据**：静态确定 —— ① 生命周期方法名、参数类型（`Duration` → `Int64` 毫秒）、默认值、`prop`→方法全变，§8.7 整节仍以 `unload` 命名；② `Compiler.init` 文档为带默认值的具名参数，实现为位置参数（另有 `init()`/`init(opts:)`）；`doc:1105` 的 `Compiler(name: "demo", …)` 因此不可编译；③ `unregisterFunction` 文档返回 `Unit` 且「未注册 → `CompileException`」，实现返回 `Bool`（未注册 `false`，不抛）；且 `CompileException` 这个类型在全文与全仓都不存在
- **描述**：门面改名后未回写规格：按 §8.4 示例/§8.7 编码的宿主一律编译失败，且错误处理写法（抛 vs 返回布尔）完全不同。另 §8.2「需要自定义 `CallContext` 时改用 `invoke`」亦失效——`invoke` 是 `private`，而实现已提供 `call<T>(args, options: CallContext)` 公共重载（`src/JitFunction.cj:159`，`src/base/CallContext.cj:34-45`）
- **建议**：以实现为准改文档（`close(timeoutMs)` / `isClosed()` / 位置参数 / `Bool`），或保留 `unload` 别名并标弃用；补 `call<T>(args, options)` 并删除「改用 invoke」句；`unregisterFunction` 的失败语义二者择一写死

### [一般][存量] #4 `CALL_HOST` 操作数编码两处口径冲突：规范 `u16 fid + u8 argc`（4 B） vs 实现 `u8 argc`（2 B）

- **位置**：规范 `doc:355`、`doc:1539`（`OpInfo(0x79, "OP_CALL_HOST", "u16 u8", 4, …)`）；实现 `src/bytecode/OpInfo.cj:255`（`'u8', 2`）、`src/backend/X86Lower.cj:1054`（`helper(63, u8(argc)+1, 0)`，只读 1 字节）
- **来源**：存量（快照）
- **判据**：review-checklist §13「格式与源码不符」、§2「同一张表多处 → 行为漂移」
- **证据**：静态确定 —— §5/§10.3 说 4 B 带 `fid`；实现与 `src/bytecode/OpInfo_test.cj:134-149`、`src/bytecode/FbcRuleSet.cj:88-102` 说明 2 B 无 `fid`；`OpInfo.selfCheckOk()` 只校验 `len == 1 + ΣoperandSize(fmt)`，两种口径都「自检通过」，不会暴露冲突
- **描述**：`0x79` 是 M2 起合法的线上操作码，长度决定解码步进：按 4 B 口径解码会越过下一条指令 2 B，整段 code 错位（反汇编、调试器、差分工具、第三方实现全受影响）。M1 汇编期禁用故仓内不炸，但规范自称「数值权威」
- **建议**：回改 §5/§10.3 为 `u8 argc` 并注明「M2 重定义，原 `u16 fid` 已废止」；步进长度由 `OpInfo.len` 单一来源提供，`FbcRuleSet` 不再各写一份

### [一般][存量] #5 `hs_len` 语义与实现相反（文档「UTF-8 字节数」，实现「码点数」），并与自身 String 迭代规范互斥

- **位置**：规范 `doc:1727`、`doc:1916`（`String——索引 + STR_AT`）、`doc:383`（`LEN` =「元素数」）；实现 `src/runtime/Helpers.cj:212-216`（`Int64(s.toRuneArray().size)`）、`src/runtime/Helpers_test.cj:157`（断言「hs_len 按码点」）、`src/compiler/Lowerer.cj:749-775`（`LEN` + `STR_AT` 组合）
- **来源**：存量（快照）
- **判据**：review-checklist §13「规格与实现漂移」、§11「语义与注释不符」
- **证据**：静态确定 —— `STR_AT`/`STR_SUB` 索引域为码点，`for-in` 以 `LEN` 作上界。若按文档（`LEN`=字节数）实现，非 ASCII 串迭代上界大于码点数，`STR_AT` 在越过最后一个码点后必报 `ERR_IDX_OOB(4)`
- **描述**：`LEN` 对 String 的口径是跨指令契约（循环上界、切片、诊断都依赖它）。文档错这一句会直接误导新后端/新语言移植（UTF-16 或字节两种直觉都不对），并让「按文档写的用例」与实现不一致（差分看起来像三引擎不一致，实际是规范错）
- **建议**：§11.4 改为「`hs_len` 返回 Unicode 码点数（与 `STR_AT`/`STR_SUB` 同域）；UTF-8 字节长度需另设 helper（当前无）」；§5 `LEN` 行补「String = 码点数」

### [一般][存量] #6 §9.16 转储头协议写 `[dbgBase]=fnId`，实现写 `fnId+1`（`fnId=0` 与哨兵冲突）

- **位置**：规范 `doc:1348`；实现 `src/runtime/DbgDump.cj:30-35`（首格 `fnId+1`、0 为哨兵）、`:95-110`（`writeOnceStackRaw` 写 `fnId+1`）、报告组装处读出时减 1
- **来源**：存量（快照）
- **判据**：review-checklist §13「文档与实现相反」、§11「契约与实现不符」
- **证据**：静态确定 —— 转储以「首格 == 0」判定未填；入口函数 `fnId` 合法值为 0，若按文档写 0，缓冲永远「看起来未填」，外层传播帧会覆盖它，报告里的 `fnId` 与变量清单来自错误帧（「最深失败帧获胜」失效）
- **描述**：这是「文档协议对合法输入不可实现」，不是措辞问题；实现已订正但只写在代码注释（「§9.16 的实现订正，见 `design-m1.md` §E」），规范读者拿不到
- **建议**：§9.16 改为「`[dbgBase] = fnId + 1`（0 为哨兵，读出减 1）」，并在 T50 验收口径写「入口 `fnId=0` 的转储必须可与未填区分」

### [一般][存量] #7 §12.4「0x90–0xBF 全量路由表」缺 A5–A8 与 H58/H59/H72；`LOOP_BACK` 行仍写无条件 `H22`（与 §5 及实现相反）

- **位置**：`doc:2180-2188`（标题即「**全量** `CALL_HELPER` 路由表」）、`doc:2147`（`LOOP_BACK` = `STACK_GUARD` + `call H22` + `jmp`）、`doc:500`（§5「v0.19 起安全点按需执行…读 `ctx.flags` 的 `DEADLINE` 位」）、`doc:52`（§1 `flags` 位表只有 bit0/bit1/bit2）
- **来源**：存量；其中 `LOOP_BACK` 属**改一处漏一处** —— `git show 51866c43d -- f_jit/doc/jit-bytecode-m1.md` 只改了 §5 两个 hunk（`@@ -488`、`@@ -497`），§12.4 与 §1 未同步
- **判据**：review-checklist §13（自相矛盾）、§14.1（指令有 ISA 行却无降低路由）
- **证据**：静态确定 —— `src/backend/X86Lower.cj:1167-1170` `0xA5→helper(24)`…`0xA8→helper(27)` 有实现，路由表无 A5–A8；`src/compiler/Lowerer.cj:3071-3081` 以 `callHelper(58/59/72)` 直呼正则替换，路由表亦无；`src/backend/X86Lower.cj:1039`、`src/backend/A64Lower.cj:376`、`src/runtime/JitContext.cj:85`（`DEADLINE = 8`）证明按需安全点已落地
- **描述**：① 四条 DEC 指令与三个替换 helper 在「全量」表里缺席——照表实现的第三方/新后端会得到无路由或误判 `ERR_NOT_IMPL`；② §12.4 要求每条回边无条件 `call H22`，与 §5 的 v0.19 语义、与两后端实现都相反，照表实现会重新引入 44× 的循环退化（§5 引 `optimize-call-path.md` §14：662→15 ns/轮）；③ §1 `flags` 位表未含 `DEADLINE`（bit3），§5 却直接依赖它，而 §1 又把 bit0 标为「历史位，运行期不读」——位分配成为单一真相缺口；④ §5 写「v0.19 起」，文档头版本是 v0.18.39，读者无法判断该行为是否已生效
- **建议**：路由表补 A5–A8（H24–H27）与 H58/H59/H72；`LOOP_BACK` 行改为「`STACK_GUARD` → `flags & DEADLINE ? H22 : nop` → `jmp`」；§1 `flags` 补 `bit3=DEADLINE（桥按本次调用 deadline 写入）`；把「v0.19 起」改为当前版本或标注「已实现（`CtxFlags.DEADLINE`）」

### [一般][存量] #8 §12.4 模板 B（`CALL_FUNC`）的收参写法会丢返回值并破坏栈平衡

- **位置**：`doc:2195-2198`（「返回后：`CHECK_ERR`、重写 `fnId`、**结果压栈**、`add rsp,8*argc` 收参」）
- **来源**：存量（快照）
- **判据**：review-checklist §11「语义与实现不符」、§13
- **证据**：静态确定 —— 与同节模板 A（`doc:2192`：结果写回 `args[0]` 槽再 `add rsp,8*(argc-1)`）不一致；实现 `src/backend/X86Lower.cj:437-466`：`movQwordCtx(40, fnId)` → `moveRaxToMemRsp(disp)`（`disp = 8*(argc-1)`，写回 `args[0]` 槽）→ `addRsp(disp)`；`argc=0` 时改为 `pushReg(0)`
- **描述**：按文档字面「先 push 结果、再 `add rsp,8*argc`」，结果格在 `args[0]` 之下，`add` 会把它与全部实参一起弹掉：内部调用返回值丢失、栈净深少 1（`RET` 取到的是实参）。argc=1 时最直观
- **建议**：模板 B 收参改为「`mov [rsp+8*(argc-1)],rax`；`add rsp,8*(argc-1)`；`argc=0` 时 `push rax`」，并注明「结果占用 `args[0]` 槽，与模板 A 同构」

### [一般][存量] #9 句柄槽回收契约四处表述互相矛盾；按 §9.6 字面实现会让槽位单调增长至上限

- **位置**：`doc:903-908`（§8.1 保活矩阵：B「`pin` 至调用结束」、D「`call<T>` 至解包完成自动回收」）、`doc:899`（规则 6①「A/B 的 ID 不在回收之列…`gen` +1 允许复用」）、`doc:936`（§8.2「`finally` 释放本次调用登记的**非常量槽**」）、`doc:1327`（§9.6 末句「**逃逸槽占用的表项不参与任何后续分配重用**」）
- **来源**：存量（快照）
- **判据**：review-checklist §2（同规则多副本导致漂移）、§11（资源不对称）、§5（无界增长的拒绝路径）
- **证据**：静态确定 —— 四处文本对「B 槽是否在调用结束释放」「D 槽释放后能否复用」给出三种答案；实现取「窗口记账 + 代数归还」：`src/runtime/HandleTable.cj:104-131`（`Win.pins` 注释：不占窗口、不随窗口重置释放，由 `CallMarshal.cleanup`/宿主释放）、`:194-200`（`gen` 上限 `0x7FFF`，触顶退休）、`:452-470`（`pin` 走窗口内去重）
- **描述**：① 按规则 6① 「A/B 不回收」，每次调用的参数槽永不复用 → 稳态槽数 = 调用次数 × 参数个数，必然触顶 `capacityLimit`（默认 2^20）→ 16，而 §9.6 又把 16 定性为「峰值容量错误、不是泄漏」，会掩盖真实泄漏；② 按 §9.6「逃逸槽不参与重用」，每次返回一个对象永久占一槽，同样单调增长；③ 按 §8.2 释放 B 槽，则必须写明「宿主已持有对象引用」这一前提由谁保证（当前由 `CallMarshal.cleanup` 承担，规格未写）
- **建议**：§8.1 立单一「槽归属与释放点」表（A=单元卸载；B=调用 cleanup；C=窗口重置；D=解包后自动回收且 `gen`+1 可复用），§8.2/§9.6 只引用；删掉 §9.6 与规则 6① 直接冲突的那句

### [一般][存量] #10 AArch64 帧与 ABI 有三处未入规范：`locals` 偏移 −40、`x20`、`FPCR`；`frameSize` 末项 `+8` 亦无语义定义

- **位置**：规范 `doc:2053`（「`locals[i]` = `[rbp-32-8i]`（a64 `[x29,#-32-8i]`）」）、`doc:116`（`frameSize = 32 + 8*nLocals + 8*maxStack + 8`）、`doc:141`（「帧布局本身两后端共享」）、`doc:1980-1996`（§12.2 ABI 表无 `x20`/`FPCR`）、`doc:2019-2032`（§12.3 a64 序言只保存 `x19`）、`doc:2056`（「a64 依赖 FPCR.DN=1（**引擎初始化**显式置位）」）
- **来源**：存量（快照）
- **判据**：review-checklist §13（规格与实现漂移）、§12.1（寄存器具名与保存义务）
- **证据**：静态确定 —— `src/backend/A64Lower.cj:140-146` `ldr/str [x29, #-40-8i]`（同一文件 `:29` 注释仍写 −32）；`src/backend/A64Compiler.cj:37-45` `FRAME = align16(40 + 8*(nLocals+maxStack+1))`（x86 为 32，`src/backend/BackendSelector.cj:1731-1737`）；`src/backend/A64Emitter.cj:265-285` 保存/恢复 `x20`（`[x29,-16]`）与 `FPCR`（`[x29,-24]`，置 DN=1）
- **描述**：① 规范把 `x29-32` 给 `locals[0]`，实现用 −40：a64 的 `x29-32` 保留给 `CALL_CLOSURE` 的 fnId 暂存（`A64Lower.cj:657-658`），照规范布局会被暂存覆盖闭包句柄 `locals[0]`；② `x20` 是 a64 的操作数栈指针（`A64Compiler.cj:76`）且 callee-saved，规范 §12.2/§12.3 完全没提，照规范实现会破坏调用方 `x20`；③ `FPCR` 是**线程**状态，规范写「引擎初始化置位」，实现是**每次调用**保存/恢复——按规范全局置 DN=1 会污染宿主浮点环境（宿主 NaN 从带 payload 变 canonical，属可观察变化），且违反 §11.3「payload 不参与可观察语义」只对 JIT 内部成立的隐含前提；④ `frameSize` 末项 `+8` 未说明。实现注释给出原因：helper 模板把 `TO_STR` 标签等静态操作数压栈，物理峰值 = `maxStack+1`，并记载「缺少这一格时该槽落在 `sp` 之下被 helper 帧覆盖（实测：插值串 `TO_STR` 标签读回垃圾 ⇒ 14）」
- **建议**：§12.4 通用约定改为「x86 `locals[0]@rbp-32`、a64 `@x29-40`（`x29-32` 保留 `CALL_CLOSURE` fnId 暂存）；`FRAME` 基址 32/40，末项 `+8` = 转瞬实参槽（`maxStack` 不含它）」；§12.2 增 `OPSTACK=x20`、`FPCR` 行并写「序言/尾声成对保存恢复，禁止全局置位」；修 `A64Lower.cj:29` 注释

### [轻微][存量] #11 helper hid 值域与 `MAX_FIXED` 过期：文档「1–62、69–72，73–255 保留」，实现已用到 84

- **位置**：规范 `doc:351`、`doc:1094`；实现 `src/runtime/HelperId.cj:92-121`（63 `host_call_trampoline`、64/65 字段读写、69–72、73–76 时间构造、77 `cast_fail`、78–83 Any/JSON、84 `ipow`）、`:124-125`（`MAX_FIXED = 72` 且注释称「`CALL_HELPER` 的 hid 合法值域」）
- **来源**：存量（快照）
- **判据**：review-checklist §13「文档过期」、§14.1「值域漂移」
- **证据**：静态确定 —— `MAX_FIXED` 全仓仅定义处命中、无引用；但注释把它定义为合法上界，一旦被校验代码采用，73–84 的已实现 helper 会被判非法
- **描述**：M2/M3 并入同模块后 hid 已扩到 84，m1 文档与 `MAX_FIXED` 停在 72；对读规范写加载器/汇编器的人是错误值域
- **建议**：§5/§8.4 改为「固定 helper 1–62、63–84（按 m2/m3 登记）、用户 helper `[0x0100,0xFFFF]`」；`MAX_FIXED` 删除或改为按 `HelperId.isFixed` 判定

### [轻微][存量] #12 规范声明的若干机制在实现中不存在（4 个伪指令、token 加载期校验、`HAS_LOOP`、H10/H21/H23、`RET_NULL`）

- **位置**：规范 `doc:663-668`（`GUARD_HANDLE`/`PUSH_KH_HINT`/`CHECK_ERR_OFF`/`BAIL_SITE`）、`doc:618`（「加载器遇未知 token 拒绝」）、`doc:52`（bit2=hasLoop）、`doc:554/565/567`（`H10 h_ref_eq`、`H21 err_raise`、`H23 hw_check`）、`doc:360`（`RET_NULL` 与 `RET_VOID` 同为 `rax=0`）
- **来源**：存量（快照）
- **判据**：review-checklist §1（无调用者 / 注册了但永不触发）、§14.1（承诺未实现）
- **证据**：静态确定 —— 四个伪指令全仓符号搜索 0 命中；`src/bytecode/FbcReader.cj` 对 `CAST/IS_TYPE/GUARD_TYPE/TO_STR/DT_FIELD` **零命中**（不校验 token 操作数），只做容器/目录/类型表/站点/名字与 `CALL_HOST` 门禁；`CtxFlags.HAS_LOOP` 只定义（`src/runtime/JitContext.cj:77-78`），写入点 `create` 只写 `DEADLINE`（`:178`），无后端读取；`grep "H_REF_EQ|ERR_RAISE|HW_CHECK" src --include=*.cj | grep -v HelperId.cj` **零命中**（`EQ_H` 走内联 `cmp`，`src/backend/X86Lower.cj:999-1000`）
- **描述**：① §7 把四个语法糖写成汇编器能力，本实现没有汇编源层（`BytecodeBuilder` 直接产字节码）；② token 不校验 ⇒ 含未知 token 的 `.fbc` 能通过加载、到执行期才以 7/8 失败，与「加载期拒绝」契约相反，失败 site 也漂到运行期；③ `hasLoop` 是死位却被列为 ctx 固定位语义；④ `H10/H21/H23` 无任何发射点（属 M2 预留但未标注），`RET_NULL` 与 `RET_VOID` 无任何可观察差异，只多一条 lowering 分支
- **建议**：§7 四项标「未实现（预留语法糖）」或删除；§6 token 校验在 `FbcReader` 落地（v1 0–9 / v2 0–11 / v3 0–12）或改文档为「运行期 helper 判 8」；§1 bit2 标「未使用」；H10/H21/H23 标「M2 预留」或删，`RET_NULL` 合并进 `RET_VOID`

### [轻微][存量] #13 §5 的 0xA0–0xAF 表混入 0xBE `MAP_ITER_STEP`，与 §10.3 和实现不一致

- **位置**：规范 `doc:420`（`BE MAP_ITER_STEP` 紧接 `AF` 之后，仍在「0xA0–0xAF 分配/变更区」标题下）；对照 `doc:1615`（§10.3 放在 0xB8–0xBF 段）与 `src/bytecode/OpInfo.cj:331`
- **来源**：存量（快照）
- **判据**：review-checklist §13「文档自相矛盾」、§10「可读性」
- **证据**：静态确定 —— 表头区段与行内 Hex 直接冲突；同时 0xB0–0xBF 表缺 `BE`
- **描述**：按章节读的人会认为 0xAF 之后还有一条 `u8 mode` 指令，误判区段边界（0xB0–0xBF 实际还含 `BE`/`BF`）
- **建议**：该行移入 0xB0–0xBF 表（`BF` 前），节标题补「Map 迭代步进 / 串建 Regex」

### [轻微][存量] #14 比较类 helper 的失败码列列入不可能产生的码（`CMP_DT`→11、`CMP_DUR`→12）

- **位置**：规范 `doc:338-339`、`doc:557`、`doc:559`；实现 `src/runtime/Helpers.cj:254-258`（`htCmp`）、`:280-284`（`hdurCmp`）
- **来源**：存量（快照）
- **判据**：review-checklist §13「规格与实现漂移」、§2「状态码表复制漂移」
- **证据**：静态确定 —— 两 helper 只做 `fetchDateTime`/`fetchDuration` + `compare`，无时间/时长算术，11/12 不可达；`DT_FIELD` 的 11 是可达的（`Helpers.cj:276` `case _ => failWith(ErrCode.DT_RANGE)`），故不在本条
- **描述**：错误码是宿主分派依据；写入不可达码会诱导宿主写永不执行的 `case 11/12`，并掩盖真正会出现的 8
- **建议**：改为 `6, 8`；若要保留「公共项略写」，在表头统一注明并删 11/12

### [轻微][存量] #15 §8.1 的 `pin` 契约（「同表内同对象复用同 ID」）与规则 4 及实现三方不符

- **位置**：规范 `doc:878` vs `doc:897`（规则 4「跨调用仅常量句柄保证同 ID」）；实现 `src/runtime/HandleTable.cj:452-495`（只在 `currentWinOf(rs)` 的 pin 列表内去重，非容器用 `canonKeyOf` **值键**比较；`HOST_CLOSURE`/`ANY` 才走 `refEq`）
- **来源**：存量（快照）
- **判据**：review-checklist §13（自相矛盾）、§11（契约与语言语义）
- **证据**：静态确定 —— `pinWith` 的去重上界是本调用窗口而非全表，且以值相等合并（两个等值 String 会合并；容器则每次新槽，因为仓颉无引用相等运算符）
- **描述**：一句话同时承诺「同表」（跨调用）与「同对象」（身份），实现两个都不满足。按文档推理会得出「同一对象跨调用 `pin` 得到稳定 ID」，而这正是规则 4 与 §8.3 禁止表明令禁止的用法；对可变容器若真按值合并，还会把 `f([], [])` 的两个实参变成同一对象（写入互相可见）
- **建议**：§8.1 改为「`pin` 在**本次调用窗口内**按类型去重（不可变值按键、容器每次新槽）；跨调用不保证同 ID（见规则 4）」

### [轻微][存量] #16 §8.4 预定义函数的类型面与 T23「全 LocalType 组合」冲突

- **位置**：规范 `doc:1068`（「0–8 与 10–11；9=Regex、12=Closure 非法」）、`doc:2280`（T23「参数/返回 marshal × 全 LocalType 组合」）、与 `doc:172`/`doc:1801`（Regex「LocalType 9 全位置合法」）
- **来源**：存量（快照）
- **判据**：review-checklist §13（文档内部矛盾 / 测试项不可落地）、§14
- **证据**：静态确定 —— `src/base/PredefinedFunction.cj:64-80` 构造期校验明确排除 9 与 12（注释「9 Regex 沿 M1 预定义面不加入」），且非法类型抛 `JitException(CALL_CONTRACT)` 而非文档 §8.4 暗示的编译期 `SourceCompileException`
- **描述**：同一文档「9 全位置合法」与「预定义函数 9 非法」并存，T23 又要求覆盖「全 LocalType」——测试项无法落地（漏 9/12 或与 §8.4 冲突）；注册期异常类型也没有统一
- **建议**：§8.4 明写「user helper 签名面 = 0–8、10–11（M1）/13、14（M2），不含 9 与 12；跨桥 Regex 只走 `call<T>` 与 `CALL_FUNC` 链」；T23 的「全 LocalType」改为「各通道合法类型集」，并写死注册期异常类型

### [轻微][存量] #17 同一规范规则被复制 3–5 处，已产生实际漂移

- **位置**：分配型 helper 集合 5 份（`doc:15`、`doc:58`、`doc:612`、`doc:870`、`doc:2186`）；变更型三规则 4 份（`doc:614`、`doc:1343`、`doc:2187`、`doc:2224`）；`hwCap` 默认 128 / 倍增 / 无分配=0 共 5 份（`doc:49`、`doc:58`、`doc:885`、`doc:1327`、`doc:2208`）；常量同 ID 与「单元存活期」4 份（`doc:897`、`doc:912`、`doc:1267`、`doc:1327`）
- **来源**：存量（快照）
- **判据**：review-checklist §2（跨节复制 / 字面量复制，且已出现差异）
- **证据**：静态确定 —— 本报告 #7（路由表漏 A5–A8、`LOOP_BACK` 只改一处）、#9（槽回收三种说法）、#10（帧公式两份）都是复制漂移的产物；集合本身也已有形态差异（§0/§1/§6/§8.1 用区间写法，§12.4 逐项列名并漏项）
- **描述**：每版演进要同改 5 处，而 `51866c43d` 已经证明会漏改。这不是可读性偏好，是缺陷来源
- **建议**：各收敛为「一张表 + 一处定义」，其余章节改「见 §X」；§12.4 路由表与 §6 表做装配期一致性自检（参照 §10.3 的 256 项自检）

### [轻微][存量] #18 非尾递归的栈溢出未纳入 §8.2.3 的异常面

- **位置**：`doc:213`（§4「非尾位置递归深度受宿主线程栈限制…不插深度检查」）、`doc:704`（§8.0 同）、`doc:971`（§8.2.3「`call` 绝不让非 `JitException`/非 `InterruptedException` 的底层异常逃逸」）
- **来源**：存量（快照）
- **判据**：review-checklist §4（无界递归）、§11（契约不符）
- **证据**：静态确定 —— 深度由源程序实参决定（`f(n-1)`，n 来自入参），规格无深度计数、无上限、互递归同样逐层压栈；栈耗尽时表现为 SIGSEGV 或宿主 `StackOverflowError`，二者都不在 §8.2.3 列举的两类异常内
- **描述**：规格有意不加防护（与仓颉原生一致），但没把该边界写进调用契约，宿主无法据此处理；`§9.16` 的单次转储在栈溢出路径上也可能二次失败
- **建议**：二选一——插显式深度计数并给可捕获码；或 §8.2.3 增一行「栈溢出属宿主级错误，不转码」，并在 §8.3 调用契约边界里点名

<!-- 第 5 部分 -->

### [严重][存量] §12.2 字段类型范围 0–14 未排除 12：H65 可把内部闭包写入宿主字段，绕过 §1/§14.6 的逃逸禁令

- **位置**：`f_jit/doc/jit-bytecode-m2.md:338`（字段类型范围 0–14）、`:399`（降级表只列「句柄型 / 14 / 13 字段」）、`:536`（§14.6「12/13 禁止存入容器」）
- **来源**：存量（快照 `120fd2542`，`git diff` 为空；文件最后改动 `5c5dfb6ec`）
- **判据**：review-checklist §11（契约与实现不符 / 资源生命周期）、§13（规格与实现漂移）；与本文 §1 逃逸边界表、§14.6 直接冲突
- **证据**：静态确定 —— 规格写「字段类型范围 LocalType 0–14」；实现同样放行 `code <= 14`（`f_jit/src/base/ClassRegistration.cj:27-30`）。`fieldToken(12)` 映射到 `TypeToken.CLOSURE`：H64 对 12 走 `handleFieldCell` 并 `allocValue`（`f_jit/src/runtime/HostField.cj:191-202`）；H65 对 12 走 `case _`，`HandleTable.fetchAny(cell, CLOSURE)` 取出 `JitClosure` 后交给宿主 setter（`HostField.cj:231-237`）。
- **描述**：12 是**内部闭包值**，其 `captured` 数组装的是窗口 ID（本文 §14.7 术语校准）。一旦允许 `type=12` 的实例字段，H65 就把世界内闭包写进宿主对象；宿主对象的生命周期可跨调用、跨单元，窗口重置后 `captured` 里的 ID 失效或被复用，之后 H64 读回并 `CALL_FUNC` 会读到被复用的槽（对象身份错乱）或落到 19/99。这与本文 §1「存入容器 ✗（窗口重置 → 悬空 ID）」、§14.6「12/13 禁止存入容器」的纪律同源——字段与容器都是「宿主长期持有」通道，规格却按 0–14 全量放行。触发前提是手工注册一个 `type=12` 字段（反射自动注册不会产出 12），但规格本身把它写成合法面。
- **建议**：字段类型范围收窄为「0–11、13、14」，并在 §12.2/§14 增补一句「内部闭包只能经 §14 提升组 + 包装器承接，不得经字段/容器驻留 12」；实现侧 `isRegistrationLocalType` 与 `fieldToken` 同步拒绝 12（范围外提示，未计入本部分统计）。

### [一般][存量] §13-1 / §16.4 仍把 `is` 整体判定当作验签主线，与 v0.8.33 已订正的 §4 相反

- **位置**：`f_jit/doc/jit-bytecode-m2.md:229`（「P1 实测确认……⇒ 主线验签通道成立」）、`:460`（§13-1「验签按此设计；强类型入口降为备用」）、`:656`（§16.4「函数类型整体判定（P1）覆盖 14 槽之具体类」）
- **来源**：存量
- **判据**：review-checklist §13（同一文档两处结论相反）、§11（契约与实现不符）
- **证据**：静态确定 —— 同文 `:107-112` 的 v0.8.33 订正明确「单次 `is (T1..Tn) -> R` 语言上不可实现（`T/R` 是运行期数据，`is` 右侧须静态类型）」，并注明原 `is` 方案「对 14 只能比大类」；同仓设计回写把该项列为实施偏差 #1（`f_jit/doc/design-m2.md:474`），实现改为 `FunctionTypeInfo` 逐位比对。
- **描述**：§9.1 把旧结论包在「历史记录」小节里尚可，但 §13-1 是活台账、§16.4 是活条款，二者仍宣称「`is` 主线成立」「P1 覆盖 14 具体类」——后者恰好是 v0.8.33 否定的能力（`is` 无法做 14 的类名精确比对）。实现者若按 §16.4 设计验签，会退回已废止方案。
- **建议**：§13-1 改成「`is` 路线废止（历史）；现行 = `FunctionTypeInfo` 逐位」；§16.4「验签」条改为「§4 的 `FunctionTypeInfo` 逐位比对，14 按类名精确」。

### [一般][存量] §14.3「非闭包包装实例 `close` → 19」与实现相反：实际会卸载整个单元；`unload` 名称也已过期

- **位置**：`f_jit/doc/jit-bytecode-m2.md:521`（「非闭包包装实例：`close` → 19、`isClosed` = false；`unload` 仍为单元级」）、`:515`（「单元 `close()` 进入终态」）、`:558`（「`unload` 协议……原名 `close`」）
- **来源**：存量（实现侧最后改动 `5c5dfb6ec`「JitFunction 实现 std.core.Resource，unload 更名 close」）
- **判据**：review-checklist §13（文档与实现相反）、§11（契约不符）
- **证据**：静态确定 —— `JitFunction.close(timeoutMs)` 在 `owner == None`（普通单元实例）时直接置 `state = 1 → 2` 并 `CompileCache.remove(k)`（`f_jit/src/JitFunction.cj:227-268`），`close()` 等价 `close(0)`（`JitFunction.cj:523`）；全路径无 19 分支。
- **描述**：文档说「非闭包包装实例：`close` → 19、`isClosed` = false」，实现是「`close` = 单元卸载（含编译缓存逐出）」。使用者按文档在普通 `JitFunction` 上调 `close` 期望被拒，实际把单元打成终态，后续调用一律 19（`JitFunction.cj:200-204`），且该 key 的缓存产物被逐出。另：§14.3 说 `unload` 是单元级、§14.2 又说「单元 `close()`」，而实现已把单元级 API 统一为 `close(timeoutMs)`，`unload` 不再存在（提交 `5c5dfb6ec`）。三处命名/语义互相打架。
- **建议**：统一为「`close(timeoutMs)` 对单元实例 = 卸载（幂等、超时回退）；`close()` / `Resource.close` 对闭包包装 = 释放该闭包；`isClosed` 分别对应单元终态 / 闭包已释放」；删除 `unload` 旧名。若确需「非包装拒绝」，则实现补 19 并同步 `Resource` 语义（需用户裁定）。

### [一般][存量] §12.4「类注册表在 Compiler 实例内」与实现（进程级静态字段表）不符，且未定义并发注册语义

- **位置**：`f_jit/doc/jit-bytecode-m2.md:372`（「类注册表（最小形态；Compiler 实例内，快照语义同 §8.4）」）、`:335`（字段表注册）
- **来源**：存量
- **判据**：review-checklist §13（作用域与实现不符）、§12.1（共享可变状态与隔离）
- **证据**：静态确定 —— 字段访问器存放于**进程级** `HostFieldTable`（`private static let current = AtomicReference<FieldSnapshot>`，`f_jit/src/runtime/HostField.cj:85-113`），反射注册直接写入该全局表（`f_jit/src/ReflectRegistrar.cj:180`）；`find` 按 index 分桶后逐个 `accepts` 扫描（`HostField.cj:121-133`）。
- **描述**：规格承诺「每个 `Compiler` 一份注册表 + 快照隔离」，实现是「描述符在 Compiler 实例内、运行期访问器表进程级共享」。后果：① 多个 `Compiler` 实例（或多测试用例）的字段注册互相可见且不可撤销；② 同 index 分桶随注册量线性增长，`find` 逐个 `accepts`；③「注册变更不影响已编译单元」只在描述符层成立，访问器层不成立。文档完全没有提这层全局状态与其并发发布方式（原子快照替换）。
- **建议**：在 §12.4/§12.2 明确「字段访问器表为进程级、注册不可撤销；index 为类内序号，冲突由 `accepts` 首命中消解」，并说明原子快照发布（读不取锁）与「注册需在编译前完成」的纪律；否则改为 per-Compiler 实例表。

### [一般][存量] `PublicField` / `ClassDescriptor` 结构落后实现；13 型字段的「签名外置」无落点；三处重复定义已漂移

- **位置**：`f_jit/doc/jit-bytecode-m2.md:337`、`:377`（`PublicField` 仅 `name/type/index/mutable/typeRef`）、`:419`（生成物表）、`:391`（「13 型字段读取后按既有闭包调用语法使用（签名外置，不受影响）」）；`:481-494`（§13-8 立项留档）与 `:498-522`（§14 正式条款）
- **来源**：存量
- **判据**：review-checklist §13（API 结构与源码不符）、§2（重复逻辑：结构复制已漂移）、§14.1（规格不足以支撑其承诺的语义）
- **证据**：静态确定 —— 实现 `PublicField` 已增 `sigParams/sigParamNames/sigRet/sigRetName`（`f_jit/src/base/ClassRegistration.cj:62-71`），`ClassDescriptor` 已增 `ctors`/`parents`/`isInterface`（`:160-188`）；同仓设计回写把「`PublicField` 增可选 `sigParams/...`」列为实施偏差 #4（`f_jit/doc/design-m2.md:477`）。而 H63 取不到 `sig` 直接 99（`f_jit/src/runtime/HostCall.cj:45-52`）。三处 `PublicField` 字段列表逐字相同且都缺 `sig*`；§14.3 的「备选路线留档」与 §13-8 的同一段逐字重复（`:492` 与 `:522`）。
- **描述**：规格里的字段项只有 5 个字段，无法承载 13 型字段的调用签名；「签名外置，不受影响」没有说明外置到哪。照规格实现，`u.cb(a)` 拿不到 `SignatureDescriptor` → 运行期 99。实现是靠规格外的 `sig*` 字段补齐的，文档未回写；自动注册给不出函数类型时该字段调用退回 `argc` 分派这一关键退化也没写。重复定义已经产生真实漂移（三处都缺 `sig*`），说明维护成本已发生。
- **建议**：把 `sig*` 与 `ctors`/`parents` 回写进 §12.2/§12.4/§15 的结构定义；在 §12.4 补「13 型字段：手工注册须给全签名；反射自动注册缺省留空 ⇒ 该字段调用退回 argc 分派」。`PublicField`/`ClassDescriptor` 只在 §12.4 定义一次，§12.2/§12.5 改为引用；§13-8 收敛为「正式条款见 §14」+ 立项依据摘要。

### [一般][存量] 正文未回写 M2.1/M2.2/M2.3：版本行与变更记录矛盾，且 §12.5 的 `public func` 覆盖缺 GAP-13 例外

- **位置**：`f_jit/doc/jit-bytecode-m2.md:3`（版本行 v0.8.33，但同一行变更记录已列到 v0.8.34）、`:6`（范围只列 ①–⑤，无 M2.3）、`:135`（H63 第 3 步固定为 `FunctionTypeInfo.apply`）、`:210-212`（4.6–5.8× 与「M2.1 展望」）、`:412`（覆盖面含 `public func`）、`:447`（「`apply` … 是全系统中唯一的执行期反射点」）
- **来源**：存量
- **判据**：review-checklist §13（文档过期）、§14.1（已交付能力/限制未入规格）
- **证据**：静态确定 —— 实现已有两条快路径：类型化 adapter（`f_jit/src/runtime/HostCall.cj:62-65`）与 per-signature `SignaturePlan`（`:66-71`），adapter 命中时**完全不走反射**；M2.3 的 `H77 cast_fail`（`f_jit/src/runtime/HelperId.cj:197`）与 `@JitSignatures` 宏（`f_jit/src/macros/JitSignature.cj:47`）已落地，正文无对应章节。另：M2.1 起对**引用型（String 等）方法绑定**默认拒绝并跳过（`f_jit/doc/spec/f-jit-m2/verify.md:62`、`f_jit/doc/design-m2.md:483`；测试见 `f_jit/src/CompilerRegistration_test.cj:172-175`），而 §12.5 的 `public func` 覆盖面未写这条例外。
- **描述**：① 版本号与变更记录自相矛盾（头部 v0.8.33 / 末条 v0.8.34）；② 「唯一执行期反射点」只在未命中 adapter 时成立，正文没写快路径；③ §8 的 4.63×/5.75× 基线与 10× 回归门禁是按反射路径测的，快路径落地后门禁失真；④ v0.8.34 的 H77/as/`@JitSignatures` 只有一行变更记录、无正文，规格不可实施；⑤ 按 §12.5 注册带 String 形参/返回值的方法会得到「Warn + 跳过」，文档却承诺 `public func` 全覆盖。
- **建议**：版本行升到 v0.8.34+，补 M2.1/M2.2/M2.3 小节（或明确「M2.1–M2.3 见 `doc/spec/f-jit-m2.1/`、`f-jit-m2.3/` 与 `jit-bytecode-m3.md` §13」）；§12.5 的「零反射」条改为「默认路径为反射 `apply`；命中类型化 adapter / plan 时无反射；引用型方法绑定默认拒绝（GAP-13）」；§8 补「快路径基线待测」。

### [一般][存量] H63 重入链无深度上限、无栈余量检查，栈溢出只留给宿主线程栈

- **位置**：`f_jit/doc/jit-bytecode-m2.md:153`（「深度受宿主线程栈限制（同自递归，M1 §8.0）」）
- **来源**：存量
- **判据**：review-checklist §4（无界递归 / 每帧大对象）
- **证据**：静态确定（无深度计数、无余量探测）；崩溃阈值待实测 —— 全仓 `STACK_GUARD` 只出现在循环回边（`f_jit/src/backend/X86Lower.cj:1020`、`f_jit/src/backend/BackendSelector.cj:1611`），调用入口与 H63 转发器均无深度/余量判断（`f_jit/src/runtime/HostCall.cj:39-79`）。
- **描述**：重入被冻结为合法语义：「宿主闭包 → JIT → 宿主闭包……」每层新增原生帧 + 新 ctx。同一运行时对循环回边用 `STACK_GUARD(15)` 把栈不足转成 deopt，但重入链没有对应检查，深链会直接撞 native 栈（进程崩溃，拿不到 15/21 语义）。规格仅一句「受宿主线程栈限制」，既没给上限，也没说崩溃是不是预期行为。
- **建议**：桥入口加调用深度计数或栈余量探测，超限返回 15（或 21 + cause）并写进 §5 重入语义与 T31/T32 用例；同时在规格里给出「最大重入深度」的可测口径。

### [一般][存量] H64/H65 失败码表与实现不符：`let` 写实际 20 而非 19，H64 还漏 6/21

- **位置**：`f_jit/doc/jit-bytecode-m2.md:345`（H64「失败 8, 99」）、`:346`（H65「失败 8, 19, 99」）、`:401`（降级表「`let` 字段裸 H65 防御 → 19」）
- **来源**：存量
- **判据**：review-checklist §13（错误码与源码不符）、§11（契约与实现不符）
- **证据**：静态确定 —— 实现 `mutable=false` 时 `failWith(ErrCode.READONLY)`（`f_jit/src/runtime/HostField.cj:222-223`，`READONLY` 值为 20），文件头注释明写「A7/P3-4 口径统一：实现与用例一直是 20」（`HostField.cj:207-208`）；用例断言 `ErrCode.READONLY`（`HostFieldSet_test.cj:162`，而同文件 :147 的注释仍写 19）。H64 侧：`obj` 为 null → 6（`fetchHostObject` 语义）、访问器抛异常 → 21（`HostField.cj:162-170`）。
- **描述**：文档承诺的 19 与实现固化的 20 相反，且该 20 已被用例锁死；按文档写测试或写适配器会得到相反断言。H64 的失败面还漏了 6（null obj）与 21（宿主访问器异常，v0.8.19 统一码），实现者无法从表里推出完整失败集。
- **建议**：把 H65 失败集改为「8, 20, 99」并在 §12.4 降级表同步（如需回到 19，属错误码契约变更，需用户裁定）；H64 补「6, 8, 21, 99」。

### [一般][存量] §12.5 承诺「继承成员访问器按继承逐级向上」，实现只支持精确类

- **位置**：`f_jit/doc/jit-bytecode-m2.md:451`（「继承成员——访问器经反射按继承关系逐级向上解析（v0.8.25）」）、`:392`、`:637`（§16.1）
- **来源**：存量
- **判据**：review-checklist §13（文档承诺与实现相反）、§14.1（承诺但未实现）
- **证据**：静态确定 —— 同仓设计回写把该项列为实施偏差 #5：「类型判定按 `superClass` 链（接受子类实例）；但执行层 `InstanceVariableInfo.getValue(子类实例)` 抛 `IllegalTypeException`（实测）⇒ 自动注册的字段访问器只对精确类有效」（`f_jit/doc/design-m2.md:478`）；并固化为用例 `T36/reflect-getvalue-exact-class-only`（`f_jit/src/ReflectRegistrar_test.cj:439`）。
- **描述**：规格说「祖先类注册 + 子类实例」可经反射逐级向上访问字段，实际是「类型判定接受子类、执行层只接受精确声明类」。使用时：父类 `registerType<Base>()` 后把 `Derived` 实例交给 `u.f`，字段读写会在访问器内抛异常（走 21），而不是按文档工作。§13-5② 与 §16.1 复述同一承诺，放大了误导面。
- **建议**：§12.5/§13-5②/§16.1 统一改为「类型判定沿父链（接受子类）；字段读写执行层仅精确类，跨继承需手工访问器（`o is C`）或宏」，并指向 `T36/reflect-getvalue-exact-class-only`。

### [一般][存量] §11 HostObject「仅公共实例成员变量 / 纯数据类」定义与 §12.1/§12.5 的方法、属性能力矛盾

- **位置**：`f_jit/doc/jit-bytecode-m2.md:263`（「仅在仓颉侧声明、仅含公共实例成员变量、仅用来传递数据」）、`:271`（「通道所用类须为纯数据类（仅公共实例成员变量）」）、`:319`（§12.1 实例方法包装示例 `u.save(t)`）、`:412`（§12.5 覆盖 `public func` / `prop` / `mut prop`）
- **来源**：存量
- **判据**：review-checklist §13（同一文档定义与能力面相反）、§11（契约待确认）
- **证据**：静态确定 —— §11 把 HostObject 的适用范围定义为「仅公共实例成员变量」并写成「须为纯数据类」；§12.1 的示例类 `User` 同时有 `save(t)`、`name`、`age`（`:319-321`），§12.5 又自动注册 `func`/`prop`/`mut prop`（`:412`、`:421`）。同一类不可能同时满足「仅字段」与「有方法/属性」。
- **描述**：读者无法判断「带方法的 DTO」是否允许进入 HostObject 通道。若 §11 是「不透明通道的推荐纪律」，应写成建议而非「须」；若它是硬约束，则 §12.1/§12.5 的方法/属性能力自相矛盾。当前措辞会让实现者在注册期错误拒绝带方法的类，或让使用者误以为方法可用但字段通道受限。
- **建议**：把 §11 的「纯数据类」降为「仅使用不透明通道时的推荐纪律」；明确「§12 成员访问增量允许类带方法/属性，但字段通道的长期驻留纪律仍建议纯数据」。若确实要硬约束，则 §12.1/§12.5 必须删除方法/属性面。

### [一般][存量] `registerType<T>()` 文档签名缺 `enabled!` / `bindings!`，`JitBindings` 未文档化

- **位置**：`f_jit/doc/jit-bytecode-m2.md:410`（`public func registerType<T>(): Unit where T <: Object`）、`:450`（「关闭反射的构建下 `registerType` 不可用 → 明确报错」）
- **来源**：存量
- **判据**：review-checklist §13（API 签名与源码不符）、§14.2（公开 API / 参数未文档化）
- **证据**：静态确定 —— 实现签名为 `public func registerType<T>(enabled!: Bool = true, bindings!: JitBindings = JitBindings.empty()): Unit where T <: Object`（`f_jit/src/Compiler.cj:134-136`）；`JitBindings` 是公开类型（`f_jit/src/base/JitBindings.cj:44` 起），用于给 `@JitBind` 提供显式绑定，规格正文未提。
- **描述**：文档给的签名少两个命名参数。`enabled=false` 是「关闭反射的构建」这条契约的实际入口，正文只用自然语言提了行为、没给参数；`bindings` 是 `@JitBind` 绑定合并的入口，完全没写。使用者按签名调用无法关闭反射或补充绑定，只能读源码。
- **建议**：§12.5 的签名改为完整形式，并补一段「`enabled=false` 用于关闭反射的构建；`bindings` 与 `@JitBind` 生成的绑定合并，同成员以显式为准」。

### [一般][存量] CALL_HOST lowering 的求值顺序与栈布局矛盾：§3 说「实参先入栈再 LOADL」，§2/§5 要求 `[h_fn, a1..an]` 且句柄在栈底

- **位置**：`f_jit/doc/jit-bytecode-m2.md:93`（「实参表达式从左到右入栈 → `LOADL fn`（句柄压栈底）→ `CALL_HOST 2`」）、`:71`（栈布局 `[h_fn, a1..n]`）、`:133`（H63 第 1 步「fetch 栈底句柄」）
- **来源**：存量
- **判据**：review-checklist §13（同一文档调用约定自相矛盾）、§11（契约与实现不符）
- **证据**：静态确定 —— 在压栈式操作数栈上，先压 `a1..an` 再压 `h_fn`，栈顶是 `h_fn`、栈底是 `a1`，与 `[h_fn, a1..an]` 相反。同仓设计回写已把该项列为实施偏差 #9：「`CALL_HOST` 栈布局在 §3 与 §5 自相矛盾；定案 `[h_fn, a1..an]`，`h_fn` 先压（栈底）」（`f_jit/doc/design-m2.md:482`）；实现 `lowerHostClosureInvoke` 正是先 `LOADL` 句柄、再逐个降低实参（`f_jit/src/compiler/Lowerer.cj:2904-2919`）。
- **描述**：按 §3 的字面顺序生成，`h_fn` 会落在栈顶，H63 的「fetch 栈底句柄」会取到第一个实参，随后 `tag != 10` 直接 8，或把实参当句柄解引用。§3 还自称「与内部闭包调用完全平行」，而 M1 `CALL_CLOSURE` 的布局也是 `[闭包句柄, a1..an]`（`jit-bytecode-m1.md:361`、`:1188`），进一步说明 §3 的顺序写反了。
- **建议**：§3 改为「先 `LOADL fn`（句柄压栈底）→ 实参从左到右求值入栈 → `CALL_HOST n`」；若 `fn` 是可能带副作用的表达式，另起临时槽先求值再压栈底，并明确「被调表达式先于实参求值」。

### [一般][存量] 逃逸提升组的运行期输入未闭环：捕获描述符只在编译期内存、不入 `.fbc`，分发加载的单元无法安全构建提升组

- **位置**：`f_jit/doc/jit-bytecode-m2.md:510`（「哪些捕获为句柄型由前端**静态捕获描述符**给出」）、`:493`（§13-8「已定：捕获描述符不入 `.fbc`、无格式变更」）、`:515`（§14.2「组在**产生处**登记」）
- **来源**：存量
- **判据**：review-checklist §5（长期持有 / 有界性）、§11（生命周期契约不完整）、§13（规格与格式不一致）
- **证据**：待确认 —— `.fbc` 的读写实现没有捕获描述符段（`f_jit/src/bytecode/` 下无 capture 相关字段；搜索 `capture` 在 `FbcReader`/`FbcWriter` 无命中）；编译期描述符由 `Lowerer.captureDescriptors()` 交给 `SourceCompiler`（`f_jit/src/compiler/Lowerer.cj:158`、`:308-309`；`SourceCompiler.cj:149`），只存在于进程内编译产物。
- **描述**：提升组在交付边界要判断「闭包自身槽 + 哪些捕获是句柄型」，并区分路径 A 常量（不入组、不释放）与路径 B/C（提升、close 计数释放）。规格把「哪些捕获是句柄型」交给前端静态描述符，却明确不把它写进 `.fbc`。对**同进程编译**的单元，描述符还在；对**经分发入口加载的 `.fbc`**，加载器只有字节码，无法知道捕获类型，也无法区分路径 A/B/C。此时若允许返回带句柄捕获的闭包，桥只能按值猜测：把值 cell 当 ID 提升（错误提升/悬空）或把 ID 当值（漏提升，窗口重置后失效）。另外「组在产生处登记」的「产生处」未定义是 `closure_new` 还是交付边界；若是前者，每个闭包都登记，未承接的组要等到单元 close 才释放，属长期持有。
- **建议**：二选一并写进 §14.8：① 把捕获描述符纳入 `.fbc`（与「零格式变更」冲突，需升 verMinor）；② 明确「经无捕获描述符的分发入口加载的单元不得返回带句柄捕获的闭包」→ 加载期拒绝（同 §15/§16 的无注册表规则）。同时明确「产生处 = 交付边界，不是 closure_new」，以及路径 A/B/C 的运行期判据（句柄条目带来源标记，或描述符带路径位）。

### [轻微][存量] helper 编号基线三处不一致，且 v0.8.34 的合法域把 H63–H65 所在的 63–68 排除在外

- **位置**：`f_jit/doc/jit-bytecode-m2.md:31`（§0「helper 白名单 H01–H62」+ H63）、`:536`（§14.6 引 M1 的 H70/H71）、`:3`（v0.8.34「hid 合法域扩为 1–62 / 69–77」）
- **来源**：存量
- **判据**：review-checklist §13（同一文档编号基线不一致）
- **证据**：静态确定 —— §0 把 M1 白名单写成 H01–H62，但 §14.6 自己引用 M1 v0.18 的 H70/H71；实现里 M1 还占 H69/H72/H73–H76（`f_jit/src/compiler/Ops.cj:230-239`、`f_jit/src/runtime/HelperId.cj:190-204`）。v0.8.34 的「1–62 / 69–77」与 63–68 未衔接，而本稿的 H63（`host_call_trampoline`）、H64/H65（字段读写）正好落在 63–65。
- **描述**：三句话互相矛盾，读者无法从规格推出「哪些 hid 合法」。实现侧的固定 helper 表已经到 H83（M3），但本稿只描述 M2；至少应把 M2 的合法域写成「H01–H62 + H63–H65 + M1 后期 H69/H70/H71/H72–H76」，并说明 66–68 的保留状态。
- **建议**：在 §0 或 §2 放一张权威 helper 编号表，标注 M1/M2/M3 归属与保留区；§14.6 与 v0.8.34 改为引用该表。

### [轻微][存量] §3/§10 仍把 9=Regex 排除在 HostClosure 签名 T/R 之外，与 §12.2/§12.3 的开放理由冲突（待确认是否有意）

- **位置**：`f_jit/doc/jit-bytecode-m2.md:81`（「T/R ∈ LocalType 0–8/10–11 与 14（9=Regex 与 12/13 函数类型仍不合法）」）、`:244`（T30 覆盖 0–8/10–11）、`:338`（字段面 0–14）、`:364`（§12.3「Regex 字段自 v0.8.20 开放」）
- **来源**：存量
- **判据**：review-checklist §13（同一文档判定不一致）、§11（契约待确认）
- **证据**：待确认 —— §12.2/§12.3 已按 v0.8.20 把 9 并入字段面，理由写明「原『仅常量/不可作参数或返回』排除理由随 m1 v0.17 消灭」；同一理由对闭包签名同样成立，但 §3 未同步，也未写「签名面暂不含 9」的原因。运行时类型名映射已支持 `Regex`（`f_jit/src/base/TypeNames.cj:43`）。
- **描述**：读者无法判断「`(Regex) -> Bool` 的宿主闭包」是应被拒绝（§3）还是可用（§12.2 的同一前提）。若是有意保留（例如验签侧 Regex 类型名映射未覆盖），应写明；否则是漏同步。
- **建议**：确认后二选一——把 9 并入 §3 的 T/R 域并补 T30 用例，或在 §3 注明「签名面暂不含 9，原因：…」并指向对应 GAP。

### [轻微][存量] §10 测试矩阵标题、T 编号归属与性能用例标签不一致

- **位置**：`f_jit/doc/jit-bytecode-m2.md:240`（标题「T30–T36、T49、T54、T55」）、`:463`（§13-4 引「差分 T30–T36 + T56」）、`:168`（§5.1「三引擎逐位一致（I7；T60 断言）」）、`:211`（§8 用 `T32/host-call-overhead-ratio` 作性能用例）
- **来源**：存量
- **判据**：review-checklist §13（文档内部编号失效）
- **证据**：静态确定 —— 表体实际含 T57/T58/T59/T60（`:254-257`），标题漏列；T56 定义在 `f_jit/doc/jit-bytecode-m3.md:193`，本表既无条目也无指针；T60 的定义是「宿主异常专用码与异常栈」（`:257`），不是报告呈现；§10 的 T32 是「与既有机制交互」（`:246`），而 §8 把性能比值测试标成 `T32/host-call-overhead-ratio`（`doc/perf-m2.md:42`）。
- **描述**：标题漏列 v0.8.19 新增的 T57–T60；T56 只在本模块另一篇里存在，读者在本规格内找不到；§5.1 把报告呈现一致性归给一个讲异常码的测试；T32 同时承担「机制交互」与「性能比值」两个身份，回归门禁无法按编号定位。
- **建议**：标题改为「T30–T36、T49、T54、T55、T57–T60」；T56 处补「见 `jit-bytecode-m3.md` §10」；§5.1 的报告呈现断言补一个专门用例编号（不要复用 T60）；§8 的性能用例改用独立标签（如 `PerfM2/host-call-overhead-ratio`）。

### [轻微][存量] M1 章节引用未加 `M1` 前缀，且「§9 附则 9」「§7 校验 11」在本稿不存在

- **位置**：`f_jit/doc/jit-bytecode-m2.md:450`（「32 位宿主本就不支持（§9 附则 9）」）、`:348`（「§7 校验 11 触发清单」）、`:161`（「§9.16 的报告模板」）
- **来源**：存量
- **判据**：review-checklist §13（链接/锚点失效）
- **证据**：静态确定 —— 本稿 §9 只有 §9.1 前提与 §9.2 兼容矩阵，无「附则 9」；本稿 §7 是三引擎一致性，无「校验 11」；`§9.16` 实为 M1 §9.16。对应内容在 `jit-bytecode-m1.md:1336`（附则 9）、M1 §7 校验 11、M1 §9.16。
- **描述**：同号章节在本稿与 M1 含义不同，缺前缀时读者会跳到错误章节；「§9 附则 9」直接指向不存在的锚点。
- **建议**：统一写成 `M1 §7 校验 11` / `M1 §9.16`，并把「§9 附则 9」改为 `M1 §9 附则 9`。

> 范围外提示（不计入本部分统计）：`f_jit/src/compiler/Ops.cj:244` 的注释写「H66 `cast_fail`」，但常量值是 `77`（`CAST_FAIL: UInt16 = 77`），与 M2.3/`HelperId.cj:197` 的 H77 记述不一致，属实现侧注释笔误，建议单独核对。

<!-- 第 6 部分 -->

> 编号索引（正文与「文件覆盖」「覆盖自检」的 `#n` 均指此处）：#1 容器转型键值校验缺失（严重）· #2 签名表 128 上限与 T56 计数 · #3 `enabled` 非原子开关 · #4 perf-m1 aarch64 基线失效 · #5 perf-m2 口径自相矛盾 · #6 `isJitBacked` 断言缺失 · #7 `ti` 惰性化的成本转移 · #8 签名表作用域「桥实例级」 · #9 H63 执行流漏 adapter · #10 perf-m2 待决表过期 · #11 过期引用（1.5–3× / 三钉子）· #12 `AdapterRegistry` 论证对象不存在 · #13 行号漂移与头部索引 · #14 空 C3 行与 TLS 计数 · #15 实验规则重复且漂移 · #16 审计表两套隔离机制 · #17 JSON 常量上限未文档化 · #18 `json_set` 写值域与实现不符 · #19 helper 编号沿革注记 · #20 错误码映射范围 · #21 探针路径不存在 · #22 14 目标 aux 规则。

### [严重][存量] §5/§9.1/T39 承诺的「容器转型元素/键值校验」实现里不存在：Map 键型完全不判，`is Map<String,Any>` 对 Int64 键表为真

- **位置**：`f_jit/doc/jit-bytecode-m3.md:113`（§5「容器转型的元素/键值校验（前提 P2）……命中条件 = 是 List 且元素类型一致」）、`:171`（§9.1「落地形态 = 按 `(typecode, aux)` 的有限分支表……`case 10_0 => box is ArrayList<Bool>` 形式的静态分支」）、`:190`（T39 断言「元素/键值不符 → 拒绝」）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §13（文档承诺与实现相反）、§11（契约与实现不符）、§3（承诺的行为在实现中为空）
- **证据**：静态确定 —— 实现只做固定形态判定：`case 10 => v is ArrayList<Any> && listAuxMatches(aux)`、`case 11 => v is HashMap<ConstMapKey, Any> && mapAuxMatches(aux)`（`f_jit/src/runtime/AnyHelpers.cj:156-158`）；`listAuxMatches` 仅接受 `aux=15` 或 `0xFFFF`（`:207-209`），`mapAuxMatches` **只比较低字节（值码）**，注释明写「键码被 `ConstMapKey` 包装**擦除**……无法也不应校验」（`:217-223`）。世界内 `Map<Int64,Any>` 与 `Map<String,Any>` 运行期同形（`HashMap<ConstMapKey, Any>`）。用例也只锁定了值码：`mapAuxChecksValueType` 断言 `1039`(String→Any) 命中、`1024`(String→Int64) 不命中，**没有任何键码对拍**（`f_jit/src/runtime/AnyHelpers_test.cj:223-241`）
- **描述**：把一个 `Map<Int64,Any>` 装进 Any 后，`is Map<String,Any>` 返回 1、`as Map<String,Any>` 成功（规格承诺这里是 22）。随后按 String 键读会落到「缺键 5」，写会造出 Int64/String 混键的同一张表——规格 §5/§9.1/T39 冻结的键型校验在实现中是**空**的。List 侧同理只有「元素 = Any」命中，`List<Int64>` 恒不命中，与 §9.1 的「枚举元素码 0–3 / 4–11 / 14 / 16–19」完全不同。文档把 P2 实测（`:157`「泛型实参参与运行期判定」）当成「走校验路径」的依据，但实测只证明「`is` 能区分泛型实参」，推不出「键型可判」——键在 M1 就被 `ConstMapKey` 擦除了。
- **建议**：二选一并写进 §5/§9.1/T39：① 收窄承诺为「容器转型只保证**元素为 Any**（世界内唯一形态）；Map 键型不可判，`as Map<K,Any>` 只校验值码」；② 若确需键型安全，给 Map 句柄条目增加键码 tag 并在 `as` 时比对（格式/内存增量需单独立项）。T39 补负向用例「`as Map<String,Any>` 对 `Map<Int64,Any>` → 22」，当前缺这条断言。

### [一般][存量] §13.1「签名空间有界、无需淘汰」与实现 `MAX_ENTRIES = 128` 不符，T56 的「构建计数 = 不同签名数」在超限后失效

- **位置**：`f_jit/doc/jit-bytecode-m3.md:314`（「签名键 = 类型码序列（T/R ∈ 0–8/10–11……）——表条目数**天然有界、无需淘汰**」）、`:193`（T56「同签名只建一次〔构建计数 = 不同签名数〕」）、`:309`（Layer A 生命周期「桥实例级；只读共享」）
- **来源**：存量
- **判据**：review-checklist §13（文档与实现不符）、§14.1（规格不足以支撑其断言）、§11（契约不符）
- **证据**：静态确定 —— `SignatureTable.MAX_ENTRIES = 128`，超限分支「不缓存，但计数仍 +1」，且每次超限 `getOrBuild` 都在写锁内 `SignaturePlan(sig)` + `current.store(PlanSnapshot(...))`（`f_jit/src/runtime/SignaturePlan.cj:138`、`:166-181`）；上限本身有用例（`f_jit/src/runtime/SignaturePlan_test.cj:224-229`）。而 M3 自己已把 9、14、16–19 并入可转集与签名面（`jit-bytecode-m3.md:46`、`:238`「可直接作参数/返回/局部变量、进签名（含跨桥形参/返回）」），文档 `:314` 的 T/R 范围停留在 M2 口径
- **描述**：三处后果。① 文档说「无需淘汰」，实现有 128 条上限且**没有**淘汰——超限后退化成「每次调用现造 plan + 取写锁 + 分配新快照」，是未记录的性能台阶；② T56 的「构建计数 = 不同签名数」只在 `entryCount < 128` 时成立，超过后每次调用都 +1，按断言写用例会假红/假绿；③ `:314` 的签名空间估算与 `:46`/`:238` 自相矛盾，读者无法判断签名表到底有多大。
- **建议**：§13.1 补「条目上限 128；超限不缓存、每次现造（写锁 + 快照分配），行为等价但无加速」，T56 的计数断言限定 `entryCount < MAX_ENTRIES`，并把 T/R 范围改为「0–19（M3 合法集）」。

### [一般][存量] §13.1「读路径无锁（不可变发布）」漏掉进程级 `public static var enabled`：热路径读非原子开关，并发切换语义未定义

- **位置**：`f_jit/doc/jit-bytecode-m3.md:317`（「SignatureTable 首建 = 锁 + 双检……读路径无锁（不可变发布）」）、`:193`（T56「强制通用 / 强制特化双路径」）
- **来源**：存量
- **判据**：review-checklist §12.1（共享可变状态无保护 / 可见性）、§13（文档未覆盖实现的状态）
- **证据**：静态确定 —— `public static var enabled = true`，`getOrBuild` 首行读它（`f_jit/src/runtime/SignaturePlan.cj:135`、`:141-144`）；`resetForTest()` 与宿主/测试都会写（`:194-199`；用例 `SignaturePlan_test.cj:105/123-127/177-179`）。文档只描述「不可变快照发布」，未提这个**不在快照里**的可变开关
- **描述**：开关的读者在每次 H63 调用上，写者可以是任意线程（T56 要求能切换两条路径，宿主侧也可关）。普通 `var` 跨线程读写没有 happens-before，`enabled` 的翻转可能对不同线程长时间不可见，甚至与正在进行的首建交叉出「本应通用却拿到 plan / 本应特化却拿到 None」的混合观测。文档对此完全没有定义（也没有说明「只在无并发调用时切换」）。
- **建议**：把开关纳入 `PlanSnapshot`（原子替换），或改 `AtomicBool`；§13.1 增一句「开关仅在无并发调用时切换（启动期/测试）」，并把该纪律写进 T56。

### [一般][存量] `perf-m1.md` 的 aarch64 JIT 基线已被后续优化推翻且无日期/SDK，与 x86 表差 88×，不能再作为 M1 性能基线

- **位置**：`f_jit/doc/perf-m1.md:8-17`（aarch64 表：JIT 200,867,356 ns，n=200000×5 轮 → 200 ns/轮；相对 cjnative 1949%）、`:19-31`（x86 真机表：JIT 2,276,989 ns → 2.3 ns/轮，比 cjnative 快 29%）
- **来源**：存量
- **判据**：review-checklist §13（文档过期 / 基线不可复现）、§6.1（无对照数据的性能结论不成立）
- **证据**：静态确定 —— 同一份栈机产物、同一用例，两架构单轮成本差 88×，文档没有任何解释；aarch64 表**没有日期与 SDK 版本**，x86 表有（`:21`）。同仓 `f_jit/doc/optimize-call-path.md:402-412` 在同一台 aarch64 上实测：`interrupt_poll` 回边 poll 让空循环从 15 ns/轮 涨到 662 ns/轮（占 97.7%），修复后回到 15 ns/轮（`:439-447`）。perf-m1 的 200 ns/轮正落在「修复前」量级
- **描述**：aarch64 那组数写在 `optimize-loop-safepoint` 之前，主体开销是已被删除的逐回边 helper 调用，不是代码生成质量。它给出的「JIT 相对 cjnative 约 19× 慢」是**历史结论**，按当前实现复跑应显著收敛；继续当作 M1 基线会误导后续判断（例如以为 aarch64 代码生成有结构性问题）。
- **建议**：aarch64 表补日期/SDK 并按当前实现复跑 `PerfCompare_test`；若确认被 safepoint 修复取代，标注「历史基线（pre-`optimize-loop-safepoint`）」或直接替换数值；两架构数值并列时必须写明差异归因。

### [一般][存量] `perf-m2.md` 的方法、列头单位与单次换算三者互相矛盾，所述方法无法复现该基线

- **位置**：`f_jit/doc/perf-m2.md:10-11`（「预热 64 次……随后各跑 **2000** 次」）、`:15-18`（列头「user helper（ns/10k）」15,271,110 / 70,732,890）、`:20`（「换算单次：user helper 约 **153 ns**，宿主闭包约 **707 ns**」）
- **来源**：存量
- **判据**：review-checklist §13（数据单位/口径与自述不符）、§6.1（基线缺可复核口径）
- **证据**：静态确定 —— 15,271,110 ns ÷ 2000 = 7 636 ns/call，与 153 差 50×；按「10k 次」记则是 1 527 ns/call，仍不等于 153；只有按 **100k 次**才是 152.7 ns（70,732,890/100k = 707.3 ns，与 707 完全对上）。现行用例已不是文档所述口径：`rounds = 4000`、`MonoTime`、3 轮比值取中位数（`f_jit/src/PerfM2_test.cj:54-113`）
- **描述**：三个数字只能同时成立于「每臂 100k 次」，而正文写 2000 次、列头写 ns/10k。读者按文档方法重跑得不到同一数量级，也无法判断 4.63×/5.75× 的比值是在什么迭代规模下取的（比值本身不受影响，绝对 ns 受影响）。
- **建议**：方法段改为「每臂 100k 次、3 轮取中位数、`MonoTime`」，列头改「每臂总 ns」或直接给 ns/call；并注明这组数是旧版用例（2000 次两轮）的历史留档。

### [一般][存量] `optimize-call-path.md` §2.2 承诺给 `ParallelThroughput_test` 补 `@Assert(f.isJitBacked(), true)`，实现只有打印；S2/S4/S8 的「机器码基线」缺护栏

- **位置**：`f_jit/doc/optimize-call-path.md:61-62`（「补 `@Assert(f.isJitBacked(), true)`——当前 734 ms / 2M 次循环很可能走解释器」）、`:111`（「`jitBacked=1`：……基线不是解释器数据」）、`:253`（「`S4` 仍 < 2.6× ⇒ 先查 `isJitBacked`」）
- **来源**：存量
- **判据**：review-checklist §14.1（承诺了但未实现）、§13（文档与测试不符）
- **证据**：静态确定 —— 用例只有 `println('PAR-BENCH jitBacked=…')`，没有任何 `@Assert`（`f_jit/src/ParallelThroughput_test.cj:52`）；文件注释还明确「本用例不设吞吐门槛」（`:28-33`），但 `isJitBacked` 是正确性护栏、不是吞吐门槛
- **描述**：整份调用路径优化的第一层前提是「执行本身已无锁，机器码承载」；一旦环境变化导致单元回退解释器，`S2/S4/S8` 会静默变成解释器并行度，而用例仍然全绿、`PAR-BENCH` 里的 `jitBacked=0` 只出现在日志里。文档 §3.1 的基线结论与 §8 的停止条件都依赖这个值。
- **建议**：补 `@Assert(f.isJitBacked(), true)`（或在 `Off` 模式下显式跳过并打印原因）；文档同步说明「该断言不是吞吐门槛」。

### [一般][存量] §15.4 的 `ti` 惰性化把 `FunctionTypeInfo.of` 从「每条目一次」变成「每次反射/plan 调用一次」，文档只写「行为等价」，未记录成本转移

- **位置**：`f_jit/doc/optimize-call-path.md:498-512`（「`cb.ti` 只在反射路径用……带签名的构造却无条件 `probeType`——纯浪费」「`reflectiveInvoke*` 本就接受 `cached = None` 并现场探测，**行为等价**」）、`:461-465`（`TypeInfo.of`(probeType) 116 ns、4 线程扩展比 0.31–0.35×）
- **来源**：存量
- **判据**：review-checklist §6.1（性能结论缺对照）、§13（文档遗漏实现的成本变化）
- **证据**：静态确定 —— 带签名构造把 `ti` 置 `None`（`f_jit/src/runtime/Signature.cj:389`），而两条非 adapter 路径在 `cached == None` 时**每次**都现场 `FunctionTypeInfo.of(fn)`（`f_jit/src/runtime/ReflectiveCall.cj:34-42`；`f_jit/src/runtime/SignaturePlan.cj:202-219`）。`HostCallback` 是**per 桥调用**创建、在一个 JIT 调用内的 5 万次回调循环里被复用（`PerfM2_test`/`HostClosureAdapter_test` 的形态），因此缓存从「每条目一次」退化为「每次回调一次」
- **描述**：文档的 A/B 只测了 `HostCallback` **构造**，结论「单线程几乎不变」成立；但它没有说明被搬走的 `TypeInfo.of` 现在落在**每次反射调用**上，且 §15.4 自己测到该调用 4 线程扩展比只有 0.31–0.35×（std 反射元数据缓存的内部争用）。也就是说：无 adapter 的回调密集场景，构造变快了，循环里每次回调多了一次元数据查找与争用。这是「行为等价」掩盖下的成本转移，报告把它当纯收益收口（`:516-517` 只给构造数据）。
- **建议**：文档补一句「反射/plan 路径每次调用一次 `FunctionTypeInfo.of`；adapter 未登记的密集回调场景需单独实测」；若确认有回退，可在首次探测后回填条目缓存（`ti` 改 `var` 或加旁路缓存，条目在单次调用内复用）。

### [轻微][存量] §13.1 把 `SignatureTable` 写成「桥实例级」，实现是进程级静态表（多 `Compiler`/多用例共享、无卸载回收）

- **位置**：`f_jit/doc/jit-bytecode-m3.md:309`（Layer A 生命周期「**桥实例级**；只读共享」）、`:318`（「SignatureTable / plan 不入 `.fbc`」）
- **来源**：存量
- **判据**：review-checklist §13（作用域与实现不符）、§12.1（共享状态的隔离）
- **证据**：静态确定 —— `private static let current = AtomicReference<PlanSnapshot>(...)`、`private static let writeMtx`，全进程唯一，只有 `resetForTest()` 能清（`f_jit/src/runtime/SignaturePlan.cj:130-132`、`:194-199`）
- **描述**：plan 身份无关，所以「共享」本身安全；但「桥实例级」会让实现者以为多 `Compiler`/多租户之间天然隔离、卸载单元会回收对应条目——实际是进程级常驻（≤128 条），且没有任何按单元/按实例的清理点。
- **建议**：改为「进程级、进程生命周期；不随单元卸载回收（身份无关、容量 128 封顶）」，或按 `Compiler` 持有实例表（需评估跨实例构建重复成本）。

### [轻微][存量] §13.1 / §13.3 的 H63 执行流漏掉类型化 adapter 层：实现顺序是 adapter → plan → 反射，「唯一可观察差异是性能」未覆盖「根本不进 plan」

- **位置**：`f_jit/doc/jit-bytecode-m3.md:313`（「H63 新执行流：fetch → `entry.plan`（命中则跳过 ② 的解释循环……）→ 调用 `fn`」）、`:334`（§13.3「每个转换器直接复用 H63 通用流程的同一转换函数」）
- **来源**：存量
- **判据**：review-checklist §13（文档与实现流程不符）
- **证据**：静态确定 —— 实现先 `match (cb.adapter)`，命中直接 `ad(cb.fn, convertArgs(sig, a))`，**完全不看 plan**；未命中才 `match (cb.plan)`，再退反射（`f_jit/src/runtime/HostCall.cj:63-74`）。`HostCallback` 构造同刻两者都绑定（`f_jit/src/runtime/Signature.cj:390-392`）
- **描述**：对已登记签名，T56 测的 plan 路径根本不会执行（adapter 先命中），「特化 ≡ 通用」的对拍实际是三方对拍。§13 只写 plan 一处快路径，实现者按文档接入会漏掉 adapter 优先级，也无法从文档判断某个用例到底走了哪条路。
- **建议**：§13.1 的执行流补成三级「adapter（若登记）→ plan（若启用且未超限）→ 通用反射」，并说明 T56 的两条强制路径如何与 adapter 共存（是否需要在 T56 里禁用 adapter）。

### [轻微][存量] `perf-m2.md` 的「可选路径（待决）」与「`SignatureRegistry` 当前已无调用方」已过期：同文后节已交付，且它已在生产路径上

- **位置**：`f_jit/doc/perf-m2.md:33-38`（方案 A/B/C 表；B 行「`SignatureRegistry` 复活（**当前已无调用方**）」）、`:41`（「当前代码停在 A 的实现形态」）、`:79`（「M2 仍按用户裁定停在现状（4.6×）」）
- **来源**：存量
- **判据**：review-checklist §13（文档过期 / 内部结论相反）、§14.1（已交付能力未回写）
- **证据**：静态确定 —— `SignatureRegistry.adapterOf` 已是 `HostCallback` 带签名构造的必经调用（`f_jit/src/runtime/Signature.cj:390`），H63 命中 adapter 时静态调用（`HostCall.cj:63-65`）；同文 `:135-170` 三节（M2.2/M2.3）已给出 adapter 3.25–3.56× / 2.83× 的实测，与 `:33-41` 的「待决 / 停在 A」互斥
- **描述**：读者读到 `:33-42` 会以为快速路径仍未决、`SignatureRegistry` 是死代码；实际它已是默认路径的一环，且 B 方案（静态绑定）只以 adapter 形态部分落地。文档缺少「本节结论已被后节取代」的指针。
- **建议**：`:33-42` 改为历史留档并加指针「结论见本文件后三节（M2.1–M2.3）」，删除「当前已无调用方」这类会随时间腐烂的现状断言。

### [轻微][存量] 过期引用：`perf-m2` 与 m3 §13 仍引已被废止的「1.5–3×」估算；m3 §12-9 仍称三个钉子待裁

- **位置**：`f_jit/doc/perf-m2.md:3`（「规格 `jit-bytecode-m2.md` §5 的估算为 **1.5–3×**」）、`:37`（「把 §5 的估算改为实测区间」）；`f_jit/doc/jit-bytecode-m3.md:299`（承接 m2 §8「估算为 user helper 调用的 1.5–3×」）、`:292`（§12-9「其开放钉子（plan 构建时点 / argc 展开阈值 / 调用级身份缓存的三条启用门槛）见 §13.5」）
- **来源**：存量
- **判据**：review-checklist §13（引用已废止数据 / 状态过期）
- **证据**：静态确定 —— m2 头部变更记录与 §8 已写明「实测 4.6–5.8×，**原估 1.5–3× 废止**」（`f_jit/doc/jit-bytecode-m2.md:3`、`:210`）；m3 §13.5 里前两个钉子已裁定（`:346-347`），只剩 Layer C（`:351`）
- **描述**：m3 §13 是 CALL_HOST 特化的活规格，开篇用废止数字描述需求，会让读者低估特化收益上限（真实差距比 1.5–3× 更大）；§12-9 的「三个钉子待裁」与 §13.5 的「两个已裁」矛盾，追进度的人会去等已经结束的裁定。
- **建议**：`perf-m2.md:3/:37` 与 `m3:299` 统一改为「4.6–5.8×（1.5–3× 已废止）」；`m3:292` 改为「钉子 ①② 已裁（§13.5），仅 Layer C 待定」。

### [轻微][存量] `optimize-compile-path` / `optimize-call-path` 对 `AdapterRegistry` 的锁与 UAF 分析指向一个生产零引用、且不存代码地址的表

- **位置**：`f_jit/doc/optimize-call-path.md:196-203`（P3.2「`AdapterRegistry.lookup` 都在全局锁内；……在编译/注册/查适配器时用」）、`:205-209`（P3.3「`AdapterRegistry` 存的是**代码地址**；COW 读者若持有旧快照，必须在代码释放前离开」）、`:219`（「P3.2 × 卸载 | 适配器是代码地址；依赖 close 排空，否则 UAF」）
- **来源**：存量
- **判据**：review-checklist §13（文档描述与实现不符）、§11（契约不符）
- **证据**：静态确定 —— `AdapterRegistry` 是 `protected class`，全仓 `.cj` 里除自身与 `AdapterRegistry_test.cj` 外只有 `Root.cj:21` 的一行注释命中，**无生产调用点**；表值是 `Int64`（`HashMap<String, Int64>`），不是代码地址（`f_jit/src/AdapterRegistry.cj:27-60`）
- **描述**：P3.2/P3.3 用「代码地址 + 旧快照 → UAF」的论证否决/约束一个改造项，但该表既不在执行路径上（P3.2 自己也承认），也不持有地址，UAF 前提不成立。这条分析既不能作为「不做」的证据，也不能作为「做」的设计约束，属无效论证。同时它掩盖了真正的问题：该类型是否应删除或收窄可见性（仅测试使用）。
- **建议**：把 P3.2/P3.3 标注为「分析对象已无生产调用点，结论作废」，改为「`AdapterRegistry` 是测试专用残留，建议删除或降为测试内工具」；若保留，则按实际存储（Int64 id）重写失效分析。

### [轻微][存量] `optimize-call-path` 的行号引用已漂移，头部状态摘要停在 §14、未收录 §15–§18 的四个 keep

- **位置**：`f_jit/doc/optimize-call-path.md:399`（「临时注释 `A64Lower.cj:368` 的 `helperCall0(22)`」）、`:449-450`（「`X86Lower.cj:1032` 一直有 `helper(22, 0, 0)`」）、`:3-10`（状态行只写「§14 是新的量级发现」，关联归档只列到 phase2）
- **来源**：存量
- **判据**：review-checklist §13（链接/位置失效）、§14.1（已交付项未入索引）
- **证据**：静态确定 —— 回边 poll 实际在 `f_jit/src/backend/A64Lower.cj:379`（`this.helperCall0(22)`）与 `f_jit/src/backend/X86Lower.cj:1043`（`this.helper(22, 0, 0)`）；§15/§16/§17/§18 共四处 keep（签名两表 −52%/−84%、TLS −32~36%、helper 表 −96%）与 `optimize-signature-tables`/`optimize-runtime-tls`/`optimize-helper-table`/`optimize-call-alloc2` 均未进头部
- **描述**：按文档去定位变异点会打空；按头部判断会认为调用路径优化止于 §14，实际后面还有三项数量级收益——这是文档的「索引层」失效，影响的是后来者对该模块性能现状的判断。
- **建议**：行号改为符号引用（`A64Lower` 回边 `helperCall0(22)` 调用点）或同步到 379/1043；头部状态行补 §15–§18 的一句话结论与归档名。

### [轻微][存量] `optimize-compile-path` 决策日志残留空 C3 行；§11.4 与 §12.2 的 TLS 调用次数估算不一致

- **位置**：`f_jit/doc/optimize-compile-path.md:91`（`| | C3 | 4 线程扩展比 | | | | |` 空行）、`:268-270`（§11.4「每函数约 **1000** 次 ⇒ 约 **0.3 ms**（预期 −8%）」）、`:286-295`（§12.2「**598** 次 TLS get × 约 300 ns ≈ 180 µs」）
- **来源**：存量
- **判据**：review-checklist §13（文档内部数据不一致 / 模板残留）、§3（占位空行）
- **证据**：静态确定 —— 同一份文档对同一次改动给出 1000 次与 598 次两个计数；§6 已判 C3 取消（`:98-109`），决策日志末尾仍留着未填的 C3 模板行
- **描述**：C3 空行会被后续填写者当成「待办」；TLS 次数从 1000 改成 598 说明 §11.4 的估算口径有误，而 §12.2 的结论（未测得收益）正是靠 598 推出来的——两个数并列会让读者怀疑结论的算术基础。
- **建议**：删掉空 C3 行（或填「取消，见 §6」）；§11.4 改为「598 次（实测计数）」，并注明 1000 是早期估算。

### [轻微][存量] 两份 `optimize-*.md` 重复定义同一套实验硬规则，且已漂移（假失败豁免、≥8 核复测只在一份里有）

- **位置**：`f_jit/doc/optimize-call-path.md:17-31`（硬规则 1–7：先基线后改码 / 一次一项 / 三项同时满足 / MOV / 共享机只初筛、`8 线程 ≥5×` 必须专用 ≥8 核复测 / 语义改动走 OpenSpec）、`f_jit/doc/optimize-compile-path.md:75-80`（测量协议：MOV、5 次、≥2% 回退、全量零失败）、`:93-96`（停止条件）
- **来源**：存量
- **判据**：review-checklist §2（表现形式不同的重复逻辑：同一套规则两处措辞、字面量复制）
- **证据**：静态确定 —— 两份文件各自定义 `MOV = max(3%, 2×离散度)`、5 次取中位数、其它指标回退 ≤2%、全量零失败；差异：call-path 给 `PerfOverride_test` 高负载假失败豁免（「单跑 3 次至少 2 次通过」，`:24`）并要求 ≥8 物理核复测（`:26-27`），compile-path 两者都没有
- **描述**：同一治理规则写两遍，已经出现实质漂移：按 compile-path 的口径，`PerfOverride_test` 在共享机上的假失败会直接否决改动；按 call-path 的口径则允许保留。两个台账对「达标」的定义不一致，跨文档比较结论时会冲突。
- **建议**：抽一份 `doc/optimize-protocol.md`（或让 compile-path 直接引用 call-path §1/§2.2），只保留「编译路径特有」的部分（如同进程 A/B、双峰分峰比较），并显式说明假失败豁免是否适用于编译路径。

### [轻微][存量] 两个后端的发射审计表用两套隔离机制（A64 实例字段 / x86 `ThreadLocal`），且 §8 的「改为 ThreadLocal」已被 §12 取代但未标注历史

- **位置**：`f_jit/doc/optimize-compile-path.md:120-129`（§8 C0「`A64Emitter.noteMemBase` 的 `ArrayList.add`……改为 `ThreadLocal`」）、`:275-283`（§12.1「`A64Emitter.auditTls`（`ThreadLocal<ArrayList<Int64>>`）→ 实例字段 `audit`」）、`:351-353`（§14.2「选 ThreadLocal 而非实例字段，是因为 x86 的发射助手是静态函数、`EmitAudit_test` 也依赖静态采集 API」）
- **来源**：存量
- **判据**：review-checklist §2（同一能力两套实现）、§13（被取代的表述未标注）
- **证据**：静态确定 —— A64 侧现为实例字段 `private let audit: ArrayList<Int64>`（`f_jit/src/backend/A64Emitter.cj:460`，`resetAudit`/`auditSnapshot` 为实例方法 `:466-470`）；x86 侧为 `private static let auditTls = ThreadLocal<ArrayList<Int64>>()`（`f_jit/src/backend/BackendSelector.cj:258`）
- **描述**：同一「审计表生命周期 = 一次 `compileOnce`」的不变量，一处靠对象生命周期、一处靠线程生命周期；§12.2 已实测实例字段「严格更少工作」但没收益，§14.2 仍以「静态助手」为由保留 TLS，两处理由并列但没有统一裁定。§8 的「改为 `ThreadLocal`」在 A64 侧已不成立，却没有任何历史标注。
- **建议**：在 §8 该条加「已被 §12 取代（A64 改实例字段）」；补一句统一口径「审计表隔离优先用实例字段，仅在发射助手必须为静态时用 `ThreadLocal`」，并把 x86 的静态助手迁到实例作为后续项（需先测）。

### [轻微][存量] m3 §11 未记录 JSON 常量的 16 MiB 与空串拒绝上限，读者按规格会以为只受 `u32` 长度约束

- **位置**：`f_jit/doc/jit-bytecode-m3.md:231`（「发射常量引用：kind 11 = Json（payload = **u32 长度** + UTF-8 原始字节串）」）、`:236`（加载期「防御性再校验失败 → 加载期拒绝」）、`:224`（常量/运行期构造的区分）
- **来源**：存量
- **判据**：review-checklist §13（限制条件缺失）、§5（资源上限未文档化）
- **证据**：静态确定 —— 拼装期硬拒绝「JSON 常量载荷为空」「超长 > 16 MiB」（`f_jit/src/bytecode/ConstRegistry.cj:258-268`），加载期另有长度一致性校验（`:620-631`）；m3 §11 全文无 16 MiB 与「空串必拒」的记载
- **描述**：`u32` 上限是 4 GiB，但实际可用上限是 16 MiB，且空 JSON 字面量（`` `` ``）在两个阶段都被拒。作者按规格写大 JSON 字面量时会在编译期拿到「超长」而不是 §11 描述的「加载期拒绝」，错误面与文档不符；OOM 面因此是有界的（好事），但边界没写在契约里。
- **建议**：§11「编译期」条补「常量载荷 1 B–16 MiB（空串与超长在拼装期拒绝，码 18）」，并在 §10 T41 的负向集里加一条超长用例。

### [一般][存量] §11/T61 的 `json_set` 写值域仍写「值型 0–3」，实现与前端已收窄为 Int64/Bool/String/JSON 节点，Float64 编译期拒绝

- **位置**：`f_jit/doc/jit-bytecode-m3.md:268`（§11「写（H82 `json_set`；变更型）：`v` ∈ 值型 **0–3**（Unit 除外）/ String / JSON 节点（码 16–19）」）、`:194`（T61「写值域（值型/String/JSON 节点……）」）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §13（文档承诺与实现相反）、§11（契约与实现不符）
- **证据**：静态确定 —— 前端 `checkJsonWriteValue` 只接受 `LocalType.I64` / `BOOL` / `STRING` / `16–19`，Float64 直接 `diagFail`，消息明写「JSON 无二进制浮点」（`f_jit/src/compiler/Lowerer.cj:1927-1943`）；运行期 `jsonValueOf` 也只分派 `0 / 2 / 4 / 16–19`，Float64（1）与 Decimal（5）落 `case _ => 8`（`f_jit/src/runtime/JsonHelpers.cj:136-154`）。用例把裁定写死了：「收窄为 `Int64 / Bool / String / JSON 节点`，**Float64 编译期拒绝**」（`f_jit/src/compiler/A7JsonSet_test.cj:28-41`），并断言 `1.5f64` 与 `2.5` 都报 `TYPE_MISMATCH`（`:33-41`）
- **描述**：`0–3` 去掉 Unit 就是 `Int64 / Float64 / Bool`，按规格 Float64 是可写值，实际是编译错误。`A7JsonSet_test` 的标题就是「值域在**规格 / 前端 / 运行期**三处一致」，但规格这一方没有随 P3-3 收窄——三方一致性只剩两方。用户按 m3 §11 写 `o.k = 1.5` 会拿到与文档相反的拒绝，且 T61 仍写「值型」而非具体集合，无法从测试矩阵看出边界。
- **建议**：§11 与 T61 统一改为「Int64 / Bool / String / JSON 节点（Float64/Decimal 编译期拒绝：JSON 无二进制浮点；小数写 JSON 字面量或字符串）」；T61 负向集补 Float64/Decimal 两条，与 `A7JsonSet_test` 对齐。

### [轻微][存量] m3 的 helper 编号沿革注记三处互相矛盾（「接 H65」「原 H72–H82」「H72/H81/H82」），与 H69–H83 的实际占位不符

- **位置**：`f_jit/doc/jit-bytecode-m3.md:103`（「编号接 H65——H78–H80」）、`:14`（版本行「v0.3.12 再 +3 helper：**原 H72–H82**；v0.3.15 顺延为 H81–H83」）、`:3`（v0.3.12 条「+3 helper（**H72** `json_get` / **H81** `json_set` / **H82** `json_new`）」）、`:272`（「编号顺延——H72 已被 M1 v0.18.19 的 `regex_replace_range` 占用」）
- **来源**：存量
- **判据**：review-checklist §13（文档内部不一致 / 编号引用过期）
- **证据**：静态确定 —— 实际占位：H66–H68 保留、H69–H72 为 M1 v0.17/0.18 的 `str_to_regex/list_new/map_new/regex_replace_range`、H73–H76 时间构造、H77 `cast_fail`、H78–H83 为 M3（`f_jit/src/runtime/HelperId.cj:69-112`）。H72 确实是 `REGEX_REPLACE_RANGE`（`:112`），所以「接 H65」既跳过 H66–H77，也与 H78 的实际起始不符；「原 H72–H82」是 11 个编号，不可能是「+3 helper」；v0.3.12 条又把 `json_get/json_set/json_new` 写成 H72/H81/H82（应为连续的 H72–H74，v0.3.15 后为 H81–H83）
- **描述**：实现者按「接 H65」会从 H66 起编号，按 v0.3.12 条会得到不连续的三号；正文 §5/§11 虽然给出 H78–H83，但沿革注记没有一处能自洽地解释为什么是这六个数。
- **建议**：统一为一句「M3 顺延为 H78–H80；JSON 面 H81–H83（v0.3.15 自 H72–H74 顺延，H72 已被 `regex_replace_range` 占用）；H66–H68 保留、H69–H76 为 M1 扩展、H77 `cast_fail`」，并把版本行的「原 H72–H82」改为「原 H72–H74」。

### [轻微][存量] §4/附表的「§2 错误码映射 1–22」遗漏已登记的 23（`ERR_CONCURRENT_MOD`）

- **位置**：`f_jit/doc/jit-bytecode-m3.md:97`（「§2 错误码映射 `1–22`」）、`:370`（附表「§2（映射 1–22）」）、`:373`（「§2 映射 1–22」）
- **来源**：存量
- **判据**：review-checklist §13（文档内部不一致）
- **证据**：静态确定 —— 文档 §2 自己的错误码行已写「0–21、**23** / -1 / -2 / 99」，M3 只追加 22（`:61`）；实现 `ErrCode.CONCURRENT_MOD = 23` 且 `describe` 有 `case 23`（`f_jit/src/base/ErrCode.cj:87`、`:124`）
- **描述**：§2 的集合含 23，实施注记却把映射范围截到 22，照注记实现会漏掉 23 的描述/分支；三处同错说明是同一个过期模板。
- **建议**：三处统一改为「映射 `1–23`（含 M2 的 23 `ERR_CONCURRENT_MOD`）」。

### [轻微][存量] §9.1/§13.5 引用的探针目录 `.autocode/tmp/p2probe`、`.autocode/tmp/argcprobe` 已不存在，「可重跑」不可兑现

- **位置**：`f_jit/doc/jit-bytecode-m3.md:159`（「探针 `.autocode/tmp/p2probe/`，`run_all.sh` 一键重跑」）、`:348`（「探针 `.autocode/tmp/argcprobe/`，可重跑」）
- **来源**：存量
- **判据**：review-checklist §13（链接/路径失效、证据不可复现）
- **证据**：静态确定 —— 两个目录均不存在（`ls .autocode/tmp/p2probe` / `argcprobe` 均 No such file or directory；`.autocode/tmp` 下只剩其他历史文件）。P2 结论（`:155-169`）与 N=4 阈值（`:348`）都以这两组探针为唯一原始证据
- **描述**：文档把两个关键实测（「泛型实参参与运行期判定」「argc ≤ 4 占 99.7%」）标成可一键重跑，实际只剩结论数字；后续若要复核 P2 是否仍成立（换 SDK/平台），没有可执行的入口。
- **建议**：把探针脚本收进 `f_jit/scripts/`（可复现），或按 `optimize-call-path.md` 的写法标注「临时探针，已删除，数据留档」并给出复现步骤而不是死路径。

### [轻微][存量] §5 的 aux 规则写「其余类型 0xFFFF」，与 §3/§12 的「14 目标 aux=typeRef」及实现（`$as$<C>` 的 hid）不一致

- **位置**：`f_jit/doc/jit-bytecode-m3.md:111`（「`aux` = 容器附加码——List(10)……Map(11)……**其余类型 aux = 0xFFFF**」）、`:81` / `:284`（14 目标「转换点携类身份（`typecode=14 + aux=typeRef`）」）
- **来源**：存量
- **判据**：review-checklist §13（同文档内描述符规则互相矛盾）、§11（按 §5 实现会弱化类界）
- **证据**：静态确定 —— 前端 `auxOf` 对 `HOST_OBJECT` 目标是取 `$as$<类名>` 的 helper id，只有取不到类名才回退 `0xFFFF`（`f_jit/src/compiler/Lowerer.cj:2664-2689`）；运行期 `anyMatches` 的 14 分支把 `aux` 当 `$as$<C>` 的 hid 用，`0xFFFF` 是「任意非 JSON 宿主对象」的兼容口径（`f_jit/src/runtime/AnyHelpers.cj:159-161`）。§5 的规则只给 List/Map 开了口，按字面实现会对 14 也发 `0xFFFF`
- **描述**：`0xFFFF` 在 14 上不是「无附加信息」，而是**关闭类界校验**；§5 把它写成所有非容器的默认值，与 §3「无继承关系不得转型」和 §12「任意 HostObject 不开放」直接冲突。实现用 `$as$` hid 而不是文档说的 `typeRef`，命名也对不上。
- **建议**：§5 表格改为「List → 元素码；Map → `(键码<<8)|值码`；14 → `$as$<C>` 的 hid（取不到类名时 `0xFFFF` 兼容口径，仅限无法携带类名的调用点）；其余 → `0xFFFF`」，并在 §3/§12 把「typeRef」改成与实现一致的「`$as$<C>` helper id」。

<!-- 第 7 部分 -->

### [一般][存量] `close(timeoutMs)` 的「超时」实为无时钟源的自旋次数预算，排空循环每轮都抢同一把单元锁

- **位置**：契约描述 `f_jit/doc/spec/align-jitfunction-close-naming/design.md:22-23`（「入口实例的 `close(timeoutMs)` 是**单元卸载**：排空全部在飞调用、进入终态、逐出缓存；超时回退可用并返回 `false`」）；实现对照 `f_jit/src/JitFunction.cj:237-253`（单元）与 `:309-326`（闭包包装）
- **来源**：存量（快照模式无 diff）
- **判据**：review-checklist §13「契约与实现不符」+ §11「语义与命名不符」+ §12.1（无时间源的忙等、与在飞调用退出路径争锁）
- **证据**：静态确定 —— 两处排空循环均为 `let limit = if (timeoutMs <= 0) { 0 } else { timeoutMs * 100000 }`，循环体只做 `synchronized(this.mtx) { active == 0 }` / `{ e.active == 0 }` 并把 `spins` 加一（`:238-252`、`:310-325`）；该文件内检索 `now()` / `Stopwatch` / `sleep` / `yield` 均为 0 命中，即**没有任何时钟源**，也没有让出 CPU 的动作
- **描述**：参数名与设计文档都表示毫秒级超时，实际等待时长 = 迭代预算 ÷（单轮「取锁 + 读计数」耗时）。机器越快、竞争越轻，等待越短；`close(5000)` 在快机上可能几十毫秒就返回 `false`（单元仍可用，语义安全），在慢机/高负载下则可能空转远超声明的毫秒数。空转期间该线程持续抢 `mtx`，而在飞调用退出时 `exitUnit`/`exitClosure`（`:197-212`）需要同一把锁，形成「关闭者越抢、调用者越难退」的互相拖慢。`close(0)` 只判一次即返回，与文档「不等待」一致，不受此条影响。
- **建议**：排空改为以单调时钟为基准（`Stopwatch` / `DateTime.now()` 差值），循环内 `sleep` 一小段或改用条件变量在 `active` 归零时唤醒；若确实要保留迭代预算，则把参数改名为 `spinBudget` 并在 design/spec 写明单位，避免下游按毫秒做超时预算。

### [轻微][存量] `plan-m1.md` 的实施记录仍称 x86_64 后端未完成、降级解释器，与现状相反

- **位置**：`f_jit/doc/plan-m1.md:276`
- **来源**：存量（该行属 2026-10-18 的「§5 实施记录」，此后未随 x86 后端落地更新）
- **判据**：review-checklist §13「文档过期——写着"暂不支持"其实已支持」；§11「契约与实现不符」
- **证据**：静态确定 —— `f_jit/src/backend/BackendSelector.cj:65-67` 对 Linux/x86_64 直接返回 `(Engine.Jit, Some(BackendX86_64()))`；`:89-104` 的 `BackendX86_64.compile` 逐函数调 `X86Compiler.compileFunction` 并把产物写入 `sink`（失败才 `false`）；`f_jit/src/compiler/X86Exec_test.cj:27-60` 有 `@When[arch == 'x86_64' && os == 'Linux']` 的原生执行用例（最小单元/算术/分支/常量折叠等）
- **描述**：原文为「**S5.4 未完成**：`BackendX86_64.compile` 仍降级解释器……待 x86_64 原生 CI 上补」。这是 §5 里唯一一条「剩余工作」，读者会据此认为 JIT 只在 aarch64 生效，做平台选型或性能预期都会得出相反结论。
- **建议**：改写为结项记录并注明补齐它的变更目录（`doc/spec/fix-f-jit-x86-*`、`align-x86-loop-back-stack-guard` 等），或在 §5 标题显式标注「截至 2026-10-18 的状态快照」。

### [轻微][存量] 三份计划的「阶段总览」步骤数与步骤清单行数不符，且 S2.16 行序倒置

- **位置**：`f_jit/doc/plan-m1.md:68`（P2 记 15 步）、`f_jit/doc/plan-m2.md:26`（Q3 记 8 步）、`f_jit/doc/plan-m3.md:26`（R3 记 9 步）；行序问题在 `f_jit/doc/plan-m1.md:123-124`
- **来源**：存量
- **判据**：review-checklist §13（文档内部自洽）+ §14.1（计划承诺与实际产物对不上）
- **证据**：静态确定 —— 机械计数（去重后按阶段分组）：S0=3、S1=11、**S2=16**、S3=22、S4=22、S5=14、S6=12、S7=8；Q0=3、Q1=6、Q2=4、**Q3=10**、Q4=12、Q5=12、Q6=7；R0=3、R1=3、R2=5、**R3=10**、R4=12、R5=5、R6=7。`plan-m2.md:138` 自写「54/54 全部完成」，而 3+6+4+**10**+12+12+7=54——只有按 10 步才成立，反证总览表的 8 是追加 Q3.9/Q3.10 后漏更新；P2 同理（S2.15/S2.16 后补）。另 `plan-m1.md:123` 是 S2.16、`:124` 才是 S2.15，与 §0.5「步骤号稳定，便于引用」冲突。
- **描述**：数字对不上会让「还剩几步 / 是否全部完成」失真；行序倒置让按编号顺序阅读/勾兑的人多跳一次。
- **建议**：三处改为 16 / 10 / 10（或总览只写范围 `S2.1–S2.16`，把计数交给脚本）；S2.16 与 S2.15 两行互换。建议在 `f_jit/scripts/` 增加与 `check_tmap.sh` 同风格的「总览计数 vs 步骤行数」自检。

### [轻微][存量] `plan-m1.md` 的模块骨架与依赖清单缺 `macros` / `surface` / `userapi` 三包与 `f_macros` 依赖

- **位置**：`f_jit/doc/plan-m1.md:39-53`（§0.4「模块骨架与构建（P0 产物）」+ 依赖声明列表）
- **来源**：存量
- **判据**：review-checklist §14.1「能力未接入 / 新模块没进模块索引」+ §13「关键段落缺失」
- **证据**：静态确定 —— §0.4 只列 `Root.cj` + `base/` `bytecode/` `compiler/` `runtime/` `backend/` `test/diff/` 六个包，依赖只列 `f_base` / `f_regex` / `f_util`（+「M3 追加 `f_data`」）；实际 `f_jit/src/` 另有 `macros/`（`JitBind.cj`、`JitSignature.cj`、`IgnoreJitBinding.cj`）、`surface/`、`userapi/`，且 `f_jit/cjpm.toml` 的 `[dependencies]` 含 `"fountain::f_macros"`。三份计划全文检索 `JitBind|macros|宏`，只有 S1.3 的「无宏，硬编码映射」一处，与宏包无关
- **描述**：§0.4 被写成可执行的 P0 产物（「按 §0.4 建目录与 package 声明」），照此建模块会漏掉宏包；`S6.11`「再导出与用户面冒烟 / 用户面 API 冻结」也没覆盖 `@JitBind` / `@JitSignature` / `@IgnoreJitBinding` 这三个对外注解入口，读者无法从计划判断它们是否属于用户面契约。
- **建议**：§0.4 补三行包目录与 `f_macros` 依赖，并在 S6.11 的导出一览里点名宏入口；若宏包由后续变更引入，注明对应 `doc/spec/<change>/`。

### [轻微][存量][待确认] `plan-m2.md` §4.3「`cjpm test` 必须带 `--parallel 1`」的成因可能已从注册面消除

- **位置**：`f_jit/doc/plan-m2.md:166-171`
- **来源**：存量
- **判据**：review-checklist §13「文档过期」（约束的理由已不成立，但约束仍被写成强制）
- **证据**：待确认 —— 静态可确认：该段理由是「反射 `InstanceFunctionInfo.apply` 的 MCC 路径在引用型参数上触发 SIGSEGV（GAP-13）」；而 `f_jit/src/ReflectRegistrar.cj:265-276` 现在对「引用型参数/返回且无 overrides」的方法**默认跳过**（`skip(..., '引用型参数/返回在反射 apply 上会 SIGSEGV（GAP-13）...')`），即默认不再生成这条绑定。缺的信息：① 走 `overrides` 的用例是否仍会触碰 MCC 路径；② 去掉 `--parallel 1` 后并发 GC 是否引入其他不稳定（`f_jit/doc/spec/f-jit-m2/verify.md:295` 另记「测试口径另加 `--parallel 1`（降低并发 GC 干扰）」）。
- **描述**：现状下这条约束更像"稳定性保险"而非"必须"，但文档用「**必须**」并给出已失效的技术理由，后续维护者无法判断能否放开并行。
- **建议**：补一句「GAP-13 已在注册面拦下；`--parallel 1` 仅作稳定性保险（待复测）」；有条件时补一次默认并发的全量结果。

> 存量缺陷共 5 条（一般 1、轻微 4），是否纳入修复待用户决定。

<!-- 第 8 部分 -->

### [一般][存量] A64 回边守卫的「frame 语义」论证前提与 AArch64 编码事实相反，掩盖了守卫恒不触发的真实原因

- **位置**：`f_jit/doc/spec/align-x86-loop-back-stack-guard/design.md:8`（序言行）、`:9-11`、`proposal.md:16-19`、`specs/f-jit-backend/spec.md:5-6`
- **来源**：存量（工作区快照；该目录时间戳 2026-10-22，实现为 `A64Lower.cj:363-373`，`git log -L 363,381:A64Lower.cj` 显示守卫序列在本次变更之前就已存在，故其分析对象就是当前代码）
- **判据**：review-checklist §13（文档与实现/语言事实不符）、§12.1（判「安全」必须给对同步与余量路径）、§4（余量守卫失效）
- **证据**：静态确定 —— 文档写「aarch64：`sub sp, sp, frame`（**`x31` 上的减法在该编码中不落实**，真实 `sp` 仍在帧顶附近）」，据此推出回边 `(fp - frame) - sp` 为负值、守卫「退化为恒不触发」。核对编码：`A64Emitter.cj:322-324` 的 `subImm` 用 `0xD1000000`（Add/subtract **immediate**，Rd=31 即 **SP**），`A64Compiler.cj:75` 发射 `sub sp, sp, frame` 是**生效**的；`A64Emitter.cj:279-287` 的尾声用 `mov sp, x29` 复位（不是 `add sp, sp, frame`），只有帧真的被扣掉才需要这样复位。真正让守卫失效的是 `A64Lower.cj:368-373`：`subReg(11, 11, 31)` 走 `0xCB000000`（Add/subtract **shifted register**，Rm=31 是 **XZR**，`A64Emitter.cj:330-332`），等价于 `sub x11, x11, xzr`，于是 `r11 = fp - frame`（一个远大于 `frame` 的栈地址），比较恒不成立。同一序列还出现在 `A64Lower.cj:167-174`（opcode `0x07` 的 STACK_CHECK），同样是空操作。
- **描述**：① 文档把「守卫不触发」归因于序言不扣栈，这是错的；若后来者按此「修正」，会去改序言/尾声（真实扣栈一旦被改坏，helper 帧会覆盖 locals，变成真崩溃）。② 更关键的是，即便把 `subReg(...,31)` 改成正确的形式，A64 的操作数栈指针是 `x20` 而不是 `sp`，`(fp - frame) - sp` 在 A64 上恒为 0（正常帧已扣），仍会**每个回边都 deopt**；文档「两侧共同语义 = 操作数栈溢出保留区达一个全帧」的结论在 A64 上无法成立。因此规格 Scenario「两架构语义一致」（`specs/f-jit-backend/spec.md:35-38`）只对拍结果/错误码，永远无法证伪守卫是否存在。③ 本部分不重复 part5 已报的「重入链无深度守卫」（`part5.md` 发现 #9）——本条只说：**已有的回边守卫在 A64 上是空指令，且文档把原因写错**。
- **建议**：把 design §1 的 A64 行改成事实描述——「A64 的操作数栈指针是 `x20`，`sp` 只做帧分配；`sub (shifted register)` 的 Rm=31 是 XZR，当前 A64 守卫实际比较的是 `fp - frame` 与阈值，恒不触发」；并把 A64 守卫要么按 `x20` 重写（`sub x11, x11, x20` 需 extended-register 编码）、要么在 spec 里明确「A64 不发 STACK_GUARD，余量由 `x20` 静态上界 `maxStack` 保证」，去掉「两侧对齐」的措辞。

### [一般][存量] x86 回边守卫的规格阈值与跳转助记符同实现（以及同仓 `jit-bytecode-m1.md`）都不一致，按规格写出的阈值使守卫恒不触发

- **位置**：`f_jit/doc/spec/align-x86-loop-back-stack-guard/specs/f-jit-backend/spec.md:14-17`、`20-21`；`design.md:9`、`22-33`、`48-49`；`tasks.md:5-7`、`11-13`
- **来源**：存量（工作区快照；`git log -L 1019,1035:X86Lower.cj` 显示 2026-10-22 的落地提交 `bc3718d38` 用的就是 `reserve + jbe`，即规格从第一天起就与代码不符，不是后续漂移）
- **判据**：review-checklist §13（规格与实现漂移）、§3（文档描述的分支实际不可达）、§14（机制护栏与规格脱节）
- **证据**：静态确定 —— 规格要求阈值 `frame = frameSize(nLocals, maxStack)`（**全帧**）且「`overflow < frame` ⇒ 继续」。实现 `X86Lower.cj:1026-1031`：`frame` 只用于算帧底，阈值另取 `reserve = 8 * (maxStack + 1)`，判定用 `jbe`（`0F 86`，`BackendSelector.cj:311-313`），即「`overflow <= reserve` ⇒ 继续」。同仓当前设计文档 `doc/jit-bytecode-m1.md:2045` 与 `doc/spec/f-jit-m1/verify.md:252-254` 写的都是 `reserve + jbe`，只有本变更的 spec/design/tasks 还写 `frame + jb`。按规格的阈值推：`frame = align16(40 + 8*(nLocals+maxStack))`，正常路径最大溢出 `8*maxStack`，恒小于 `frame` ⇒ 规格 Scenario「溢出超过全帧才 deopt」（`spec.md:29-33`）在实现里**不可能发生**；只有实现采用的 `reserve` 阈值才可能触发。字节级护栏也对不上：`design.md:48-49` 说断言 `0F 82`（`jb`）、把方向改回 `0F 8D`（`jge`）会红，实际 `X86Lower_test.cj:96-106` 断言的是 `0F 86`（`jbe`），且 `emitJb()`（`BackendSelector.cj:306-308`）已无调用者。
- **描述**：规格把「全帧」当阈值并写成硬要求，与实现（保留区）语义不同：按规格实现会让守卫永远不触发（等于删掉），按实现理解规格则会误判「守卫比实际更松」。当前唯一可执行的护栏（字节断言）也与文档描述的方向/助记符不一致，后续任何人「按规矩对齐」都会把 `jbe` 改回 `jb` 并改阈值，进而把守卫改成死分支。
- **建议**：以实现为准改三处——`spec.md` 阈值改 `8 * (maxStack + 1)`（操作数栈保留区）、判定改「`overflow <= reserve` ⇒ 继续」，Scenario 改「超出保留区才 deopt」并在 Purpose 里删掉「全帧」的共用语义；`design.md` §2 的伪码与 §4 的 `0F 82/0F 8D` 同步为 `jbe`/`0F 86`；`tasks.md` 1.1/2.1 的「`jb ok`」同步。

### [一般][存量] 「正常回边不退化」的验收证据不成立：引用的用例在首个安全点就被 deadline 中断，另两个「护栏」只断言字节或只打印

- **位置**：`f_jit/doc/spec/align-x86-loop-back-stack-guard/design.md:50-51`、`tasks.md:21-22`、`proposal.md:42-43`；`specs/f-jit-backend/spec.md:23-27`
- **来源**：存量（快照；实现与用例均未变）
- **判据**：review-checklist §6.1（热点/退化结论必须有可复核数据）、§13（验收口径与证据不符）、§14（门禁形同虚设）
- **证据**：静态确定 —— ① 被判据引用的 `p0_6_deadlineInterruptsLoop`（`AnyBridgeCall_test.cj:118-134`）以 `deadline = DateTime.UnixEpoch`（已过期）调 `n = 100000000` 的循环，回边安全点第一时间返回 −2，循环体远未跑完；即使守卫每回边 deopt，桥也会透明重放解释器并照样抛 `InterruptedException`，用例仍然绿。「1.3 ms / 毫秒级完成」只证明「中断很快」，不证明「未退化」。② `PerfCompare_test.jitVsInterpVsCjnative`（`src/compiler/PerfCompare_test.cj:96-104`）只 `println` 比值，没有任何阈值断言。③ `X86Lower_test.loopBackStackGuard`（`X86Lower_test.cj:96-106`）只断言指令字节；A64 侧没有任何守卫相关用例（`grep STACK_GUARD|deopt src/backend/A64*_test.cj` 为 0 命中）。
- **描述**：该变更的风险表写「方向写反 ⇒ `p0_6`/`PerfCompare` 立刻暴露」，实际两条路径都不会红：`p0_6` 在首回边即退出，`PerfCompare` 无断言，字节断言只能证明「发了几条指令」，不能证明「正常路径不 deopt」。于是一个「每回边 deopt」的回归（循环全落解释器，结果仍正确）在 CI 里完全静默——这正是本次改动声称要防的那类事故。
- **建议**：补一条真正的行为护栏：不带 deadline 调 `{ n => while (i < n) {...} }`（如 `n = 2_000_000`），断言端到端耗时低于解释器的某个宽松倍数（例如 < 1/4），或直接埋点比较「JIT 调用次数 / deopt 次数」（`ctx.errCode` 不落盘，可在桥侧计 `-1` 次数，断言为 0）；A64 侧同样加一条「守卫不因正常回边触发」的计数断言。`p0_6` 只保留为中断语义用例，不再引用为性能证据。

### [一般][存量] 规格承诺的「值型键承载形态无关、异值必异键」在实现上不成立：跨类型同形 + 未覆盖类型的装箱键塌成空串

- **位置**：规格 `f_jit/doc/spec/close-f-jit-out-of-checklist-findings/specs/f-jit-bytecode-format/spec.md:7`（另见 `design.md:26-32` 的 D3 不变式）；实现对照 `f_jit/src/bytecode/CanonKey.cj:30-43`、`52-54`，`f_jit/src/runtime/HandleTable.cj:371-384`，`f_jit/src/runtime/IterTable.cj:240-251`，`f_jit/src/bytecode/ConstRegistry.cj:412-414`
- **来源**：存量
- **判据**：review-checklist §11（契约与实现不符、静默错值）、§13（规格与实现漂移）、§2（同一格式两处各写一份）
- **证据**：静态确定（键生成）+ 待确认（触发面）—— 规格写「同值必同键、异值必异键；同一个 `Float64` 无论裸 cell 还是 `Any` 盒承载，键文本 SHALL 相同」。实现里 `CanonKey.i64(v)` 与 `CanonKey.cell(v)` 都是 `i:${v}`（两函数体逐字相同），`f64(bits)` 也落到 `cell(bitsAsI64(bits))`：于是 `Int64 4609434218613702656` 与 `Float64 1.5`（位模式即该整数）得到同一 token。另一面，`HandleTable.canonKeyOf`（`:374-383`）只列了 String/Float64/Decimal/DateTime/Duration/Range/JitRegex，`Int64`、`Bool`、`List`、`Map` 全落 `case _ => ''`；`IterTable.mapKeyOf`（`:245-249`）解开 `JitAnyBox` 后正是把内层值交给它。而 `ConstMapKey` 的相等与哈希**只按 token**（`ConstRegistry.cj:408-414`），token 相同即同键。
- **描述**：两条可判定的后果。① 跨类型撞键：`Map<Any, V>` 里同时存在 `1.5f64` 与 `Int64(0x3FF8000000000000)` 时，后写覆盖前写、两者互查命中同一条目，静默返回错值（规格的「异值必异键」不成立）。② 装箱键塌成空串：`Any` 盒里的 `Int64`/`Bool`/`List`/`Map` 键全部得到 `''`，任意两个这样的键互相覆盖——这与 X2 修掉的「`JitAnyBox` 未解包导致装箱键塌成一个键」（`verify.md:34`）是同一类缺陷，只是解包之后仍未覆盖内层类型。规格里「List/Map → 递归 `l[...]`/`m[...]`」的分支在运行期键路径上也没有对应实现。触发面待确认的点：前端是否会在 `Map<Any, …>` 里把值型键装箱（若总是直传裸 cell，则 ② 只在宿主手工 `pinAnyBox` 作键时可达）。
- **建议**：把键域补成满射且单射——`canonKeyOf` 补 `Int64`(`cell`)、`Bool`、`List`/`Map`（递归）分支，`case _` 改为返回带类型名的兜底键（如 `?<runtimeType>:${hash}`）或直接抛契约错，不要返回 `''`；若要保留「承载无关」，则要求 token 至少带类型段（`i:`/`f:` 的取舍需重新裁定：真正需要统一的是「同一值两条承载路径」，而不是「不同值同键」）。同时把 `i64` 合并进 `cell`（两者函数体已逐字相同，见证据），避免同一格式三处维护。

### [一般][存量] 用例登记表与任务表两张表各自维护、内容已漂移：一个承诺的用例不存在，另一批用例名/落点全不对

- **位置**：`f_jit/doc/spec/close-f-jit-out-of-checklist-findings/test-plan.md:9-19` 与 `tasks.md:7-27`、`verify.md:21-26`；规格 `specs/f-jit-differential-acceptance/spec.md:5`
- **来源**：存量
- **判据**：review-checklist §2（同一张表跨文件复制后漂移）、§13（文档与实现不符）、§14（承诺的用例缺失）
- **证据**：静态确定 —— ① `test-plan.md:18` 登记 X2-c `constMapFloatKeyHitWithBoxedKey`（落点 `A5MapKey_test`），全仓 grep 只有这一行文档命中，用例不存在；`verify.md:22` 却写「新增「装箱键命中常量条目」用例」。② `test-plan.md:12` 写 `strictFpEmitsFdivChk` / `strictFpChangesDivisionByZero` 在 `StrictFp_test`，实际发射级用例在 `src/compiler/StrictFpCodegen_test.cj:43`（`strictEmitsFdivChk`）、`:62`、`:70`，行为级是 `src/StrictFp_test.cj:51/61/76`；`test-plan.md:15` 的 `callContextHasOnlyCallLevelOptions` 实际叫 `CallContext_test.cj:33 defaultsFollowSpec`；`test-plan.md:16-17` 的 `f64KeyEqualsCellKey` / `boxedAndRawFloatKeyAgree` 实际带 `x2_` 前缀（`CanonKey_test.cj:68/82`）。③ 规格要求「用例名 SHALL 含缺陷编号」，但 X1 的 5 条（`CompileOptions_test.cj:34/43`、`CompilePipelineVersion_test.cj:37/52/64`）与 X3 的 6 条都没有 `x1_`/`x3_` 前缀，只有 X2 加了。
- **描述**：`tasks.md` 的用例名是对的，`test-plan.md` 是自己另写的一张表，两表并行维护后各自漂移；对外说「每条缺陷都有用例」时，按 test-plan 去点验会点不到（最典型是 X2-c 根本不存在）。这直接削弱该变更自己立的「清单外发现同等留痕」门槛。
- **建议**：删掉 `test-plan.md` 的用例名副本，改为指向 `tasks.md` 的条目号（单一事实来源）；若保留，按实际符号名重写并补 `x1_`/`x3_` 前缀；X2-c 要么补一条 `A5MapKey_test` 的端到端用例（装箱键命中常量 Map 条目），要么在 `verify.md` 里把「已新增」改成「由 `x2_*` 覆盖键层、未覆盖端到端」。

### [轻微][存量] `align-x86-loop-back-stack-guard` 缺 `verify.md`，而 tasks 4.2 已勾选「verify.md 追加记录」

- **位置**：`f_jit/doc/spec/align-x86-loop-back-stack-guard/tasks.md:32-33`；目录清单 `f_jit/doc/spec/align-x86-loop-back-stack-guard/`（无 `verify.md`）
- **来源**：存量
- **判据**：review-checklist §14（半成品 / 勾选与产物不符）、§13（审计链断裂）
- **证据**：静态确定 —— 该目录只有 `design.md`、`proposal.md`、`tasks.md`、`specs/`；`ls` 无 `verify.md`。同批其他四个变更目录都有 `verify.md`。
- **描述**：项目自己的规矩是「不允许出现任务已勾选但没有对应产物」（`doc/spec/f-jit-m1/design.md:171`），这里恰好相反：勾了「verify.md 追加 2026-10-22 第三轮记录」，产物不存在，于是这轮唯一的文字证据（方向教训、回归数字）只剩 design/proposal 里的转述。
- **建议**：补 `verify.md`（哪怕只有「回归 1099/1099、`p0_6` 毫秒级、方向教训」三行），或把 4.2 改为未完成并注明「记录并入 design §5」。

### [轻微][存量] `Version.LATEST` 以字面量 `3` 复制 `M3_MAJOR`，与设计文档「`LATEST = M3_MAJOR`」不符

- **位置**：`f_jit/doc/spec/close-f-jit-out-of-checklist-findings/design.md:11`；实现 `f_jit/src/base/Version.cj:59-62`
- **来源**：存量
- **判据**：review-checklist §2（字面量复制）、§13（文档与实现不符）
- **证据**：静态确定 —— 文档写「新增 `Version.LATEST = M3_MAJOR`」，代码是 `public static const LATEST: UInt16 = 3u16`，与 `M3_MAJOR: UInt16 = 3u16` 各写一遍；`supportedMajors()`（`:70-72`）用的又是 `M3_MAJOR`，两处将来扩版本会分叉。
- **建议**：`LATEST` 直接引用 `M3_MAJOR`（常量引用常量），保持文档口径；若刻意用字面量表达「对外承诺值」，就在注释里写明并要求同步检查。

### [一般][存量] 设计把 `JitContext` 记为「已结案 `protected`」，实现是 `public`：机器码 ABI 类型对外可达

- **位置**：`f_jit/doc/spec/f-jit-m1/design.md:54`（D2：「`JitContext` / `Engine` / `JitValue` … 用户面无消费路径（`protected`）」）、`:81`（D6：「`JitContext` 是 `protected` 访问器类」）；实现 `f_jit/src/runtime/JitContext.cj:114`（`public class JitContext`）、`:147`（`public static func wrap`）、`:304`/`:309`（`public readAt` / `writeAt`），同文件 `:27`（`public class NativeMem`）、`:72`（`public class CtxFlags`）
- **来源**：存量（`git log -S "public class JitContext" -- f_jit/src/runtime/JitContext.cj` 只命中建模块提交 `8d1b1900a`，自 M1 起即为 `public`，之后无改判提交）
- **判据**：review-checklist §11（契约与实现不符）、§13（文档与实现不符）、§12.1（ABI 契约的可见性边界）
- **证据**：静态确定 —— 修饰符与设计文本直接冲突；「跨模块不可见」的可判定性在 `BaseVisibility_test.cj:35-41` 有明文：「本文件位于本模块内，`protected` 在模块内必然可见，因此「跨模块不可见」无法用运行期用例表达」——即 `public` 就等于对外可达，`protected` 才是模块内可见。同类设计声明里 `CompileCache`/`AdapterRegistry`/`CompilePipeline` 至今仍是 `protected`（`CompileCache.cj:30`、`AdapterRegistry.cj:27`、`CompilePipeline.cj:51`），说明该档位可用，不是被迫公开。`doc/design-m1.md:1017`/`:1026` 把这条写成「**已结案 2026-10-11 裁定：`protected`**」，与实现相反。
- **描述**：`JitContext` 承载 64 B 非托管 ctx，设计、字节码规格与类注释三处都写明「机器码按固定偏移直接读写，用户写坏即破坏不变量」。现在它是 `public` 且带 `public wrap/readAt/writeAt`，下游 `import fountain::f_jit.runtime.JitContext` 即可绕过桥直接改错误槽、窗口基址、`hwCap` 等字段——设计宣称的「用户能管句柄 ≠ 能碰 ctx」在可见性层面不成立。旁证显示放宽可能并非有意：后续 `feat-f-jit-parallel-call/design.md:73` 把 `JitContext.mallocCount/freeCount` 当 `public static var` 使用，但没有任何一份设计记录了「`protected` → `public`」的改判，因此这更可能是落地时的疏漏而非裁定变更。
- **建议**：二选一并留痕——① 收窄为 `protected`（与 `Engine`/`JitValue`/`CompileCache` 一致；测试在模块内不受影响，`BaseVisibility_test` 已验证 `protected` 在模块内可用）；② 若确为计数/测试需要而有意公开，在 `doc/design-m1.md` D2 结案条目与 `f-jit-m1/design.md` D2/D6 写明改判理由与暴露边界，并至少把 `wrap/readAt/writeAt` 收窄为 `protected`，只留计数器公开。

> 存量缺陷共 8 条（一般 6、轻微 2），是否纳入修复待用户决定。

<!-- 第 9 部分 -->

### [一般][存量] M1「用户面再导出」清单与实现不一致：`CallMarshal` 被说成用户面、`HandleTable` 从未再导出

- **位置**：`f_jit/doc/spec/f-jit-m1/specs/f-jit-facade-bridge/spec.md:137`、`f_jit/doc/spec/f-jit-m1/proposal.md:43`；实现侧 `f_jit/src/CallMarshal.cj:41`、`f_jit/src/runtime/JitContext.cj:114`、`f_jit/src/Root.cj:23`–`f_jit/src/Root.cj:46`、`f_jit/src/runtime/HandleTable.cj:142`
- **来源**：存量（工作区快照，无基线可比）
- **判据**：review-checklist §13（API / 契约与实现不符）、§14.2（公开 API 未按契约暴露）
- **证据**：静态确定 —— ① spec:137 的 requirement 原文要求「用户 SHALL 能通过一次导入见到全部用户面声明（门面、产物句柄、**封送**、**句柄表**、类型与错误码常量…）」；② `CallMarshal` 实际是 `protected class`（`CallMarshal.cj:41`），根包 `Root.cj:23-46` 的 19 条 `public import` 里既无 `CallMarshal` 也无 `runtime.HandleTable`；③ `HandleTable` 是 `public class`（`runtime/HandleTable.cj:142`）但只存在于子包，用户 `import fountain::f_jit.*` 后不可见，必须自己猜到 `fountain::f_jit.runtime.HandleTable` 才能用；④ `proposal.md:43` 同一行既把 `CallMarshal` 列进「新增用户面」，又把它列进「为 `protected`，不进用户面」，自相矛盾；⑤ 项目自己的设计文档 `f_jit/doc/design-m1.md:679`、`:925` 明确 `HandleTable` 属用户面（宿主需 pin/release 逃逸句柄）、`CallMarshal` 为 `protected`（同文件 `:863`）；⑥ 同一条 `proposal.md:43` 还把 `JitContext` 写成「`protected`，不进用户面」，实际声明是 `public class JitContext`（`runtime/JitContext.cj:114`），其它包可直接 `import fountain::f_jit.runtime.JitContext` 引用——同句中 `Engine`/`JitValue` 确为 `protected`（`base/Engine.cj:29`、`base/JitValue.cj:42`），说明只有 `JitContext` 一条漂移
- **描述**：规格把两类声明都写进用户面，但实现只放行其一、且放行的那个不是规格点名的那个。后果：宿主按 spec / design 写 `HandleTable.pin(...)` 时，照「一次导入」的习惯写法编译不过；而 `CallMarshal` 被 spec 承诺可见、实际不可见（这一侧代码是正确的，错在文档）。同时暴露一个真实缺口：`HandleTable` 目前只能经子包路径访问，与「用户唯一入口」的门面设计不一致。`JitContext` 的可见性错标则相反：文档说内部、代码是 `public`，若后续按文档收窄，会被下游当作破坏性变更。
- **建议**：二选一并回写文档：① 在 `Root.cj` 补 `public import fountain::f_jit.runtime.HandleTable`（与 design §7.6 一致，同时确认不连带导出 ctx/IterTable）；② 若后续已决定收紧用户面，则把 `facade-bridge/spec.md:137` 的「封送、句柄表」删掉，并从 `proposal.md:43` 的用户面清单里移除 `CallMarshal`。无论哪种，`proposal.md:43` 的双重列举都必须改。

### [一般][存量] 两份 M1 规格对「编译缓存键」给出互斥定义，且实现含规格未写的维度

- **位置**：`f_jit/doc/spec/f-jit-m1/specs/f-jit-facade-bridge/spec.md:90`、`f_jit/doc/spec/f-jit-m1/specs/f-jit-backend/spec.md:108`、`f_jit/doc/spec/f-jit-m1/verify.md:38`；实现 `f_jit/src/CompilePipeline.cj:59`、`f_jit/src/CompilePipeline.cj:96`
- **来源**：存量（工作区快照）
- **判据**：review-checklist §13（规格与实现漂移、同名概念两套口径）、§11（契约与实现不符）
- **证据**：静态确定 —— ① facade spec:90 写「编译缓存 SHALL 为进程级并以源码（或整份字节码）的 128 位指纹为键」；② backend spec:108 写「编译缓存键 SHALL **仅包含**架构、处理器特性与字节码指纹」（对应 `src/backend/CompileCacheKey.cj:24`，三字段实现确实是 arch/cpuFeatures/fingerprint，此侧自洽）；③ 门面层真正的缓存键是 `'src/${modeKey(jit)}/v${verMajor}/fp${strictFp}/${fnv1a128(source)}'` 与 `'fbc/${modeKey(jit)}/${fnv1a128(raw)}'`（`CompilePipeline.cj:59`、`:96`），含 **JIT 模式、verMajor、strictFp** 三个规格里没有的维度；④ `verify.md:38` 自己记录了「缓存键加入引擎维度：`src/<off|auto|force>/<fingerprint>`」以修掉 CRITICAL-01，但两份 spec 均未回写
- **描述**：同一个术语「编译缓存键」在 mirror 内出现两个互不相容的定义（一个是纯指纹、一个是 arch+features+fingerprint），而实现是第三种（指纹前缀 + 引擎/版本/严格浮点）。这不是措辞问题：按 facade spec 写断言（同源不同 `JitMode` 命中同一条目）会得到错误结论；history 里 Off 与 Auto 串用同一产物正是这个「按指纹做键」的直接后果（verify.md:32）。
- **建议**：facade spec 的 requirement 改为「以 `(JitMode, verMajor, strictFp, 源码/整份字节码 128 位指纹)` 为键」，并在 scenario 里补一条「同源不同 `JitMode`/`strictFp` 不共享条目」；backend spec 的「编译缓存键」改称「后端代码缓存键（`CompileCacheKey`）」，与门面缓存区分命名。

### [轻微][存量] `verify.md` 自报的 requirement 总数（40）与文件实际（77）不符

- **位置**：`f_jit/doc/spec/f-jit-m1/verify.md:4`；对照 `verify.md:181`–`verify.md:191` 的逐 capability 表
- **来源**：存量
- **判据**：review-checklist §13（文档内部数据不自洽）
- **证据**：静态确定 —— `verify.md:4` 写「9 份 spec（**40 requirement** / 156 scenario）」；同文件逐 capability 表 9 行的 requirement 列相加为 7+4+8+10+10+11+10+10+7 = **77**；对 `doc/spec/f-jit-m1/specs/*/spec.md` 统计 `^### Requirement` 亦为 **77**（scenario 156 与文档一致）
- **描述**：校验报告开头把被校验对象规模写小了一半，读者据此会低估覆盖面（也会让「9 份 spec 全绿」的结论失去量纲）。scenario 数正确，说明是 requirement 一处陈旧值未随规格扩写更新。
- **建议**：改为 77，并在 `scripts/check_scenarios.sh` 输出里同时打印 requirement 计数，避免下轮再手写。

### [轻微][存量] `verify.md` 第五 / 第六轮的用例增量与总数算术不自洽

- **位置**：`f_jit/doc/spec/f-jit-m1/verify.md:281`–`verify.md:284`（第五轮）、`verify.md:304`（第六轮）；基线 `verify.md:272`（1108/1108）
- **来源**：存量
- **判据**：review-checklist §13（文档内部数据不自洽）、§8（基线可复现性）
- **证据**：静态确定 —— 第五轮结论写「f_jit 全量 **1112/1112**，新增 **3 例**」，但 1108→1112 是 +4，且同一张表实际列出 4 个新用例（`EmitAudit_test.absoluteAddressIsExempt` + `JitBacked_test` 的 `plainUnitStaysJitBacked`、`constMirrorUnitStaysJitBacked`、`recursiveUnitStaysJitBacked`）；第六轮写「`Pow_test` 6 例 + `NumberLitSci_test` 3 例；全量 **1123/1123**」，但 1112 + 9 = 1121
- **描述**：两处都有 2 例的口径差。若确有未列出的用例（如 `***` 词法、负指数分支），文档应补列；若没有，则总数记错。无论哪种，「用例数单调增长」这条验收口径都失去可核对性。
- **建议**：列出每轮新增用例名与数量，使 `上一轮总数 + 新增 = 本轮总数` 恒成立；或直接引用 `cjpm test` 输出原文。

### [轻微][存量] `tasks.md` 的完成口径与 `verify.md` 的未完成项并存，INFO-01 只订正了标题

- **位置**：`f_jit/doc/spec/f-jit-m1/tasks.md:125`、`tasks.md:127`、`tasks.md:150`；对照 `verify.md:23`（INFO-01）、`verify.md:162`–`verify.md:177`
- **来源**：存量
- **判据**：review-checklist §14.1（进度口径 / 半成品）、§13（文档自相矛盾）
- **证据**：静态确定 —— S5.4 同一个 `[x]` 条目内，括号里仍写「x86 执行证据因 x86 SDK alpha.07 缺 stdx.effect **未取**，按非原生跳过记录，待同版本 SDK/CI 补」，紧随的子项却写「已完成（口径更正 2026-10-19）… 真机 x86_64 **全绿**」；`verify.md:23` 的 INFO-01 已点名这处矛盾但状态是「留档」而非「已修复」，且只改了标题口径
- **描述**：tasks 115 项全勾，而 verify 明确写「apply 的 115/115 不等于规格全绿」（7 条 scenario 无断言、5 条部分覆盖、JIT 全局串行、非 Linux 无执行证据）。两者并存时，后续里程碑按 `[x]` 复用「已完成」印象的风险是真实存在的（INFO-01 原文即为此担忧）。
- **建议**：S5.4 的括号改为「框架/单指令断言已完成；整单元执行证据见 §5.8 与 verify 真机记录」，并把 verify 的 7 条缺口在 tasks 里以 `[ ]` 补登记（或加一节「未覆盖清单」），避免全勾假象。

### [轻微][存量] `tasks.md` 的构建与镜像对照命令指向已不存在的路径

- **位置**：`f_jit/doc/spec/f-jit-m1/tasks.md:7`–`tasks.md:8`、`tasks.md:173`
- **来源**：存量
- **判据**：review-checklist §13（链接 / 路径失效，复现命令不可执行）
- **证据**：静态确定 —— `tasks.md:7-8` 让读者 `cd /mnt/linux_share/.../.worktrees/f_jit/f_util && cjpm build`，当前仓库已无 `.worktrees/` 目录；`tasks.md:173` 声称镜像「与 `openspec/changes/f-jit-m1/` 逐字节一致」，当前 `openspec/changes/` 下只有 `archive/`（其内 5 个与本模块无关的变更），`git ls-files openspec` 返回 0（`openspec/` 被 `.gitignore:62` 忽略）
- **描述**：这两处是文档里唯一的「怎么复现」入口，都不可执行；镜像与源的「逐字节一致」结论也就无法复核。
- **建议**：把路径改为相对模块根（`cd f_jit && cjpm build`），并把「与 openspec 逐字节一致」改为「镜像时点的一次性校验记录（openspec 不入库）」。

### [轻微][存量] M1 门面「六步调用」把「解包」同时放在第 3 步与第 4 步

- **位置**：`f_jit/doc/spec/f-jit-m1/specs/f-jit-facade-bridge/spec.md:53`、`spec.md:67`；实现 `f_jit/src/JitFunction.cj:555`
- **来源**：存量
- **判据**：review-checklist §13（契约描述自相矛盾，步骤边界不清）
- **证据**：静态确定 —— 三态收尾的定义（spec:53）已含「成功则**解包**返回」；统一调用包装（spec:67）又列「六步：参数个数校验 → 封送 → 三态收尾 → **解包** → 返回类型一致性校验 → 返回与清理」，解包出现两次、且第 5 步「返回类型一致性」在实现里被前置到封送之前（`JitFunction.cj:555` 起：先校验 `T` 与 `retType`，再开窗口/封送）
- **描述**：实现顺序与文档叙述不同（第 5 步前置是合理优化：早失败、省窗口与转储分配），但规格仍按「1→6」线性描述，且把解包拆成两步。按文档写用例的人会去断言「第 3 步不应已解包」，与实现冲突。
- **建议**：把六步改为「① 实参个数 ② 返回类型契约（前置） ③ 封送 ④ 执行 + 三态收尾（含解包） ⑤ 清理（全路径）」，并注明第 2 步前置的理由。

### [轻微][存量] `f-jit-m2.2` 归档缺 `verify.md`，1 条 partial 与 2 条 N/A 无书面理由

- **位置**：`f_jit/doc/spec/f-jit-m2.2/`（目录无 `verify.md`）、`f_jit/doc/spec/f-jit-m2.2/scenario-map.tsv`（`返回类名驱动静态解析` = partial；`下转型拒绝`、`无法静态判定拒绝` = N/A）；对照 `f_jit/doc/spec/f-jit-m2.1/verify.md:1`
- **来源**：存量
- **判据**：review-checklist §14.1（验收记录缺失）、§13（结论无法复核）
- **证据**：静态确定 —— m2.1 有 `verify.md` 且逐条解释 partial 的成因；m2.2 目录只有 design / proposal / scenario-map / specs / tasks，`proposal.md:22` 用「验收证据见同级 `verify.md`（**若存在**）」规避，于是 partial 与 N/A 的判定依据（为什么这两条无法用例化）在整个变更内无处可查
- **描述**：同一批次的三个里程碑验收体例不一致：M1 有完整 verify、M2.1 有收口 verify、M2.2 没有。`methodResultChain` 为何只是 partial（是结构性属性还是漏测）无法判断，下轮重审只能重新取证。
- **建议**：补一份最短 `verify.md`：列出 21 条映射的 full/partial/N/A 分布、partial 与 N/A 的理由、当时全量用例数；或把理由写进 `scenario-map.tsv` 的第 5 列。

### [轻微][存量] 后端规格中的繁体字笔误

- **位置**：`f_jit/doc/spec/f-jit-m1/specs/f-jit-backend/spec.md:25`
- **来源**：存量
- **判据**：review-checklist §13（拼写 / 格式）
- **证据**：静态确定 —— 「镜像 SHALL 连续按 8 **字節**排布」，同文件其余处均为「字节」
- **描述**：不影响语义，属文档编辑残留。
- **建议**：改为「字节」。

### [轻微][存量] M2.x 镜像 spec 的公共结构字段清单落后于实现（`JitBindings` 六字段、`ClassDescriptor` 六字段）

- **位置**：`f_jit/doc/spec/f-jit-m2.1/specs/f-jit-facade-bridge/spec.md:20`（「`JitBindings` SHALL 携带四张表」）、`f_jit/doc/spec/f-jit-m2.2/specs/f-jit-base-contracts/spec.md:8`（`ClassDescriptor` 枚举 5 字段）；实现 `f_jit/src/base/JitBindings.cj:47`–`JitBindings.cj:66`、`f_jit/src/base/ClassRegistration.cj:155`–`ClassRegistration.cj:177`
- **来源**：存量（归档期后由后续里程碑扩展，非本次改动）
- **判据**：review-checklist §13（API 清单与源码不符 / 文档过期）、§14.2（公开 API 未文档化）
- **证据**：静态确定 —— `JitBindings` 现有 6 个 `public let`：`methods`(47)、`fields`(48)、`ctors`(49)、`statics`(56)、`parents`(59)、`ignored`(66)，spec 只写「四张表」；`ClassDescriptor` 现有 6 个 `public let`（含 `isInterface`，`ClassRegistration.cj:177`），spec 只枚举 5 个。`parents` 是接口父接口名（宏登记），`ignored` 是 `@IgnoreJitBinding` 的成员级退出名单（D10：「既不由宏登记，也不退回反射包装」），两者在镜像里都没有说明。
- **描述**：两份镜像自称「该里程碑归档时的最终口径」（各自 `proposal.md` 的归档说明），但公共结构已比文档多两个字段。宿主按 spec 构造 `JitBindings` 不会知道 `ignored` 可以让某成员彻底退出绑定（这是「想跳过某个成员」的唯一入口）；手工构造 `ClassDescriptor` 漏填 `isInterface` 会默认 `false` 而走类分支诊断。镜像与主规范「互补、不重复」（`f-jit-m2.1/specs/f-jit-facade-bridge/spec.md:3-8`）的承诺因此出现空白。
- **建议**：按归档边界只补一句前向指引（「后续里程碑追加 `parents`/`ignored`（`JitBindings`）与 `isInterface`（`ClassDescriptor`），字段全集以 `src/base` 声明为准」），不重写当时验收口径；若希望镜像长期可读，把逐项枚举改为引用声明，只保留语义约束。

### 范围外提示（不计入本部分统计，供 `.cj` 部分接手）

- `src/runtime/HelperId.cj:121` 已登记 `IPOW = 84`，但 `name()` 的 `match` 只到 `83`（`:129`–`:203`），`84` 落到兜底 `'unknown(84)'`（`:213`–`:219`），`isFixed(84)` 因此为 `false`；同文件 `MAX_FIXED = 72`（`:125`）在 `src/` 内零引用且注释「M1 登记的 hid 合法值域」已与 H73–H84 的现状不符 —— 建议由运行期部分确认诊断文本与 `isFixed` 的消费面。
- `src/runtime/Interp.cj:603`（`CALL_FUNC`）与 `:664`（`runClosure`）都以宿主函数递归实现，`:212` 又把 `STACK_GUARD` 当 NOP；非尾递归深度由用户源码决定（`recursive` 仅尾位置改写为 `LOOP_BACK`），规格与实现均无深度上限或环检测 —— 属 §4 栈溢出面，建议由运行期 / 解释器部分评估可达深度。
- `doc/spec/feat-f-jit-pow-and-sci-notation/`（不在本部分）内部矛盾：`design.md:24`–`:25` 与 `proposal.md:30` 写 `IPOW = 77` / 「H77」，而 `tasks.md:14` 与实现是 `H84`（`HelperId.cj:121`）；77 实际已被 `CAST_FAIL` 占用（`HelperId.cj:99`）。

<!-- 第 10 部分 -->

### [一般][存量] m2 设计把验签写成「单次 `is (T1..Tn) -> R`」，与同变更 runtime spec、权威规格、实现全部相反

- **位置**：`f_jit/doc/spec/f-jit-m2/design.md:62-66`（D3）、`:238`（Risks 行「验签依赖 P1」）、`:9`（「`jit-bytecode-m2.md` **v0.8.32**」）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §13「规格与实现漂移」、§11「契约与实现不符」
- **证据**：静态确定 —— 同变更 `f_jit/doc/spec/f-jit-m2/specs/f-jit-runtime/spec.md:122` 已改为 `SignatureVerifier.verifyReflective`（`std.reflect.FunctionTypeInfo.of` 取真实签名逐位比对、14 按具体类名），并明写「原 `verify`（分步核对、仅 0–2 元）SHALL NOT 作为验签主路」；权威规格 `f_jit/doc/jit-bytecode-m2.md:3` 的 v0.8.33 条目写「原『单次 `is (T1..Tn) -> R`』语言上不可实现（T/R 是运行期数据、`is` 右侧须静态类型，物化路径 11^(n+1) 分支）」；实现 `f_jit/src/runtime/Signature.cj:111`（`verifyReflective`）、`f_jit/src/runtime/ReflectiveCall.cj:29`（`FunctionTypeInfo.apply`）；本变更 `verify.md:218` 亦记「规格 §4 的『单次 `is`』语言上根本不成立……改用 `std.reflect.FunctionTypeInfo`」
- **描述**：D3 是「怎么做」的权威锚点（`design.md:6` 自述），却保留了被 GAP-04/GAP-05 否决的方案，并把「P1 已实测」列为已缓解风险；读者照 D3 实现会回到 11^(n+1) 分支表或 0–2 元上限——正是验收里被判阻塞的两条。`:9` 的权威版本指针也已落后（现 `jit-bytecode-m2.md` 为 v0.8.34）
- **建议**：D3 改为「验签 = `FunctionTypeInfo.of` 取形参类型名序列 + 返回类型名逐位比对（元数不限、14 位置按具体类名逐字相等）；调用 = `apply(fn, args)`」，把「单次 `is`」标为已否决方案并给否决理由；Risks 行改为「反射签名取用与参数打包的固定开销（见 `doc/perf-m2.md`）」；`:9` 改 `v0.8.33` 起并注明后续增补

### [一般][存量] 两份 spec delta 的签名类型定义没有类名载体，与同一 spec 的「14 按具体类名判定」不可兼容

- **位置**：`f_jit/doc/spec/f-jit-m2/specs/f-jit-runtime/spec.md:113`（`SignatureDescriptor(params: Array<UInt16>, ret: UInt16, validate())`）；`f_jit/doc/spec/f-jit-m2/specs/f-jit-compiler-frontend/spec.md:127-129`（`HostClosureT(Array<UInt16>, UInt16)`）
- **来源**：存量
- **判据**：review-checklist §13「文档与实现不符 / 文档内部矛盾」
- **证据**：静态确定 —— 同 spec `specs/f-jit-runtime/spec.md:127` 的场景要求「14 位置的具体类名不符 → None」，仅凭类型码无法比对类名；同 spec `specs/f-jit-compiler-frontend/spec.md:129` 自己解释「`(User) -> R` 与 `(Order) -> R` 的码完全相同（都是 `[14] -> R`）」。实现已是四元：`f_jit/src/compiler/Ast.cj:80-84`（`HostClosureT(Array<UInt16>, Array<String>, UInt16, String)`）、`f_jit/src/base/HostSignature.cj:44-63`（`paramNames` / `retName` / `display` / `adapter`）、`sameShape` 逐位比对（`:74-86`）
- **描述**：这是 GAP-04 的文本根因（`verify.md:200-208` 原文即「`SignatureDescriptor` 只有 `params`，无类名」）。结案时只补了代码与 `verify.md`，delta 的结构声明没回写，后来者读 spec 会得出「14 只能比大类」的相反结论
- **建议**：`runtime` spec 补 `paramNames: Array<String>` / `retName: String`（空串 = 只比大类），`compiler` spec 的 `HostClosureT` 改四元并写明参数序；两处都注明「14 位置按类名逐字比对」

### [一般][存量] m2.2 的 `as` 语法面与转型面与自家验收矩阵、后继里程碑相反

- **位置**：`f_jit/doc/spec/f-jit-m2.2/specs/f-jit-compiler-frontend/spec.md:8`（requirement：下转型/无法静态判定「SHALL 编译期拒绝」；「裸 `as`（缺 `??`）与裸 `??` SHALL 以语法错误拒绝」）、`:15-18`、`:25-28`、`:35-38`（Scenario 语法拒绝面）
- **来源**：存量
- **判据**：review-checklist §13「文档承诺与实现相反」、§2「同一规则在两处给出相反结论」
- **证据**：静态确定 —— ① 裸 `as`：`f_jit/src/compiler/CastOrParse_test.cj:64-67` 的 `bareAsIsRecognized` 断言 `x as Int64` 解析为 `castor(var(x) as Int64)`（**合法**），同变更 `scenario-map.tsv:15` 把「语法拒绝面」映射到 `bareAsIsRecognized,...` 且强度 `full`，`f-jit-m2.3/specs/f-jit-compiler-frontend/spec.md:49-50` 明写裸 `as` 合法；② 下转型/类名未跟踪：同变更 `scenario-map.tsv:9-10`、`:12-13` 已标「本条已作废（M2.3 改为运行期判定）」，spec 正文仍是无条件 SHALL 编译期拒绝
- **描述**：同一份归档里 spec、验收矩阵、后继 delta 三方对 `as` 的语法面与转型面各说一套；矩阵还把「合法 + 非法」两种输入塞进同一条「均以语法错误拒绝」的场景并给 `full`，该强度因此不成立。按 spec 实现会拒掉今天合法的 `x as Int64`
- **建议**：requirement 改为「裸 `as` 合法（失败报 7 `BAD_CAST`）；裸 `??` 与 `?` 为语法错误」，转型判定改为「编译期优先、判不了落 `$as$<C>` 运行期」；两条已作废场景加「（M2.3 起…）」注记

### [一般][存量] m2.2 / m2.3 的验收声明不可复核：`verify.md` 不存在，m2.2 矩阵条目数写错且 1 条用例名已改名

- **位置**：`f_jit/doc/spec/f-jit-m2.2/tasks.md:13`、`f_jit/doc/spec/f-jit-m2.3/tasks.md:13`（「全量测试通过（见 `verify.md` / `scenario-map.tsv`）」）；`f_jit/doc/spec/f-jit-m2.2/scenario-map.tsv:2`（「21 条 scenario」）、`:19`（`closeIsIdempotentAndReleasesGroup`）
- **来源**：存量
- **判据**：review-checklist §13「链接 / 路径失效」、§3「承诺无实体（验收声明没有可核对证据）」
- **证据**：静态确定 + 已执行只读校验 —— 两个目录都只有 `design.md` / `proposal.md` / `tasks.md` / `scenario-map.tsv` / `specs/`，无 `verify.md`。`bash f_jit/scripts/check_scenarios.sh m2.2` 实测输出：`MISSING test: f-jit-facade-bridge / close 协议 -> closeIsIdempotentAndReleasesGroup`，末行 `20 条映射（full 17 / partial 1 / 缺口 0 / N/A 2），未映射 0，缺失 1`——即表头自写 21 条、实际 20 条；该用例现名 `wrapperUnloadIsIdempotentAndReleasesGroup`（`f_jit/src/JitFunctionClosure_test.cj:101`）
- **描述**：归档 tasks 用「全量测试通过」作完成判据，但证据文件不存在；m2.2 矩阵本身解析不过，说明归档时没重跑脚本，而 `check_scenarios.sh` 正是本变更声明的验收手段
- **建议**：两个 tasks 改成「见 `scenario-map.tsv`（`check_scenarios.sh m2.2|m2.3`）」；表头改 20；`:19` 改用例现名；若要保留 `verify.md` 口径，补一份含总数/失败数/平台的最小 verify

### [一般][存量] 两份 tasks 的归档反写不可复核：m2.2 粘的是 M2 任务清单，m2.3 溯源到不含 M2.3 内容的 `plan-m2.md`

- **位置**：`f_jit/doc/spec/f-jit-m2.2/tasks.md:3-9`；`f_jit/doc/spec/f-jit-m2.3/tasks.md:3`、`:5-9`
- **来源**：存量
- **判据**：review-checklist §14「承诺源与缺失证据」、§13「文档自相矛盾」
- **证据**：静态确定 —— m2.2 的五条任务是「`SignatureDescriptor` 与验签 / `CALL_HOST` 发射与 H63 / 特化 trampoline / 捕获分析 `CaptureDescriptor` / 提升组计数与 `close`」，而 `SignatureDescriptor`、`CaptureDescriptor`、`trampoline` 在 m2.2 三份 spec 里 **grep 0 命中**（`H63` 与「提升组」只作为被复制条款的定语出现，不是本变更的 requirement 主题）；反而本变更真正的改动（`ClassDescriptor.parents`、`PublicMethod.bind.retName`、`as T ?? F` 静态收窄、`JitHost.registerSignature` 类型化 adapter）无一条任务。m2.3 五条（`castRelation` 三态、`$as$<C>` 合成、H77、`SignaturePlan`/adapter、`as T ?? V` 求值时机）在 `f_jit/doc/plan-m2.md` 中不存在：该文件只有 `### Q0`–`### Q6`（:35–:112），全篇 grep `castRelation|$as$|H77|SignaturePlan|JitSignatures` **0 命中**
- **描述**：m2.2 的任务表等于宣称「本变更做的是宿主闭包通道与提升组」，与 proposal/design/spec（父链 + `as` 静态收窄 + 类型化 adapter）冲突；m2.3 的溯源链断裂，「全部已完成」对不到任何步骤表。两份 tasks 都失去审计价值
- **建议**：m2.2 按 5 条 requirement 重写任务（父子链与 `retName`、`as` 三态判定、adapter 登记与查找时机、回归口径）；m2.3 溯源改为 `design-m2.md §12.4/§16` + `jit-bytecode-m2.md` v0.8.34（或补 `plan-m2.3.md`）

### [一般][存量] `CALL_HOST` 降低语序：requirement 写「实参 → `LOADL fn`」，同文件 scenario 与实现是「`LOADL fn` → 实参」

- **位置**：`f_jit/doc/spec/f-jit-m2/specs/f-jit-compiler-frontend/spec.md:59`
- **来源**：存量
- **判据**：review-checklist §13「文档自相矛盾」、§11「与规格冲突」
- **证据**：静态确定 —— 同文件 `:63-64` scenario 写「产物依次为 `a1`、`a2` 的求值指令、`LOADL fn`、`CALL_HOST 2`、`CHECK_ERR`」；实现 `f_jit/src/compiler/Lowerer.cj:2904` 注释「先求句柄存临时槽 → `LOADL`（栈底）→ 实参左→右 → `CALL_HOST`」、`:2946` 同口径；本变更 `verify.md:303-305` 已判「偏差 A（可接受偏离）」并明确建议「archive 前把 frontend delta 的语序改为『`LOADL fn` → 实参左→右』，纯文档修订」——该修订未执行
- **描述**：`[h_fn, a1..an]` 要求句柄在栈底（最先压栈），与 requirement 的「实参左→右入栈 → LOADL」互斥。规格是验收口径，保留矛盾会让正确实现被判违规，或反向改成错的发射顺序
- **建议**：requirement 改为「`LOADL fn`（句柄压栈底）→ 实参左→右 → `CALL_HOST u8 argc` → 自动 `CHECK_ERR`」

### [一般][存量] m2.3 设计不变量「执行路径零反射」与 `$as$` / 字段访问器的实现、以及本变更自己的 spec 相反

- **位置**：`f_jit/doc/spec/f-jit-m2.3/design.md:19`（不变量第 2 条）
- **来源**：存量
- **判据**：review-checklist §13「规格与实现漂移」、§12.1（执行期类型判定的实际手段）
- **证据**：静态确定 —— 同变更 `specs/f-jit-compiler-frontend/spec.md:15` 自己写「`$as$<类名>`……**按反射父链判定**，子类实例算命中」；实现 `f_jit/src/ReflectRegistrar.cj:384-390` 合成的 `$as$` 闭包体调用 `isInstanceOfClass`，后者 `:972-987` 用 `ClassTypeInfo.of(o)` + `superClass` 逐级走查；字段/属性访问器的 `accepts`（`:181`、`:544`）也落到同一函数（`:1001`）
- **描述**：「所有判定在注册期绑定」讲的是**绑定时机**，但绑定出来的函数体在执行期仍调用 `std.reflect`。于是每次 `as`、每次 H64/H65 字段匹配都要付一次反射取用 + 父链走查（上限 64 层）。「零反射」会让后续性能审计与 local mode 评估拿到相反前提
- **建议**：改为「执行路径**无动态成员解析**（注册表查找 / bind / 访问器选择都在注册期完成）；类型判定仍用 `std.reflect.ClassTypeInfo` 的父链走查」，并在 spec 里给出父链长度上界

### [轻微][存量] `HostCallback.sig` 文档类型非可选，实现是 `?SignatureDescriptor`，与同 spec 的「未验签返回 None」不自洽

- **位置**：`f_jit/doc/spec/f-jit-m2/specs/f-jit-runtime/spec.md:113`；`f_jit/doc/spec/f-jit-m2/design.md:70`（D4 tag 10：`HostCallback{fn: Any, sig: SignatureDescriptor}`）
- **来源**：存量
- **判据**：review-checklist §13「类型与实现不符 + 文档内部矛盾」
- **证据**：静态确定 —— 实现 `f_jit/src/runtime/Signature.cj:351-355` 为 `public let sig: ?SignatureDescriptor`（注释「`None` = 尚未验签」）；同 spec `:122`、`:132` 要求「未验签时 `cached` 返回 None」——非可选字段无法表达该状态
- **描述**：三处（spec 定义、design D4、spec 缓存语义）对同一字段给出两种类型
- **建议**：文档类型改 `?SignatureDescriptor`，补「pin 时未验签为 None，验签后写入」

### [轻微][存量] 公开 API 名写作 `callFor`，实现是 `callForFn`

- **位置**：`f_jit/doc/spec/f-jit-m2/specs/f-jit-facade-bridge/spec.md:64`、`:78`、`:112`；`design.md:124`（D13）、`:238`；`proposal.md:16`、`:32`、`:38`；`tasks.md:71`
- **来源**：存量
- **判据**：review-checklist §13「API 名与源码不符」
- **证据**：静态确定 —— 仓内只有 `public func callForFn<Fn>(args: Array<Any>): JitFunction`（`f_jit/src/JitFunction.cj:491`），全仓搜不到 `callFor<`；同变更 `scenario-map.tsv:101` 已用 `callForFnReturnsWrapperAndRejectsWrapperArg`，`f-jit-m2.2/specs/f-jit-facade-bridge/spec.md:8`、`:22` 亦已是 `callForFn`（更名见 `jit-bytecode-m2.md:3` v0.8.28）
- **描述**：按 m2 规格写的调用无法编译。根因是 m2.2 把「统一调用包装」整段复制（逐行 diff 后唯一差异就是 `callFor`→`callForFn`），改名只改了复制件；两份镜像从此各说一套
- **建议**：m2 的 7 处统一为 `callForFn`；m2.2 删除这条未改动的复制件（引用主 spec 的 requirement 名），镜像只留本变更真正改动的条文

### [轻微][存量] `close` 协议文本已被后续实现推翻，归档 spec 无取代标注

- **位置**：`f_jit/doc/spec/f-jit-m2/specs/f-jit-facade-bridge/spec.md:64`、`:81-84`；`f_jit/doc/spec/f-jit-m2.2/specs/f-jit-facade-bridge/spec.md:8`、`:27-28`
- **来源**：存量
- **判据**：review-checklist §13「文档过期」、§2（同一段 requirement 在两份 spec 中逐字复制，实现变更后两份同时失真）
- **证据**：静态确定 —— 两份 spec 都写「非闭包包装实例 `close` → 19（site=-1）、`isClosed` 恒 false」；实现 `f_jit/src/JitFunction.cj:227-236` 对入口实例执行的是**单元卸载**并返回 `Bool`，`:471-484` 的 `isClosed()` 对入口实例返回 `state == 2`，`:523-525` 的 `close(): Unit` 即 `close(0)`；用例 `f_jit/src/JitFunctionClosure_test.cj:138-143`（`entryCloseIsUnitLevel`）断言入口实例 `close(0)` 后 `isClosed()` 为真
- **描述**：按文档写用例必然失败；此类契约变更只存在于提交与测试注释里，`doc/spec/` 下没有任何 delta 记录
- **建议**：在两处 requirement 上加「已由 `JitFunction` 资源/close 对齐变更取代」，并在最近一个 milestone 的 delta 里登记新契约（入口实例 `close` = 单元卸载、返回 `Bool`、`isClosed` 随单元状态）

### [轻微][存量] `verify.md` 的总结论行未随结案更新，且 826 与 849 两套基线未标关系

- **位置**：`f_jit/doc/spec/f-jit-m2/verify.md:46`（对照 `:17`、`:376`）；`:366`（826/826）对照 `:43`（当前基线 849/849/0）
- **来源**：存量
- **判据**：review-checklist §13「同一文档结论相反 / 数据口径不明」
- **证据**：静态确定 —— `:17` 写「9/9 全部解决，可进入 archive」，`:46` 写「**总结论：需先补 9 项，暂不可进入 archive。**」，`:376` 写「**可以进入 archive。**」；`本轮执行的校验` 表记 826/826，而「当前基线」记 849/849/0，表格未标注已被取代
- **描述**：这是 archive 门禁的唯一证据文件，结论段自相矛盾会让下游（CI/归档脚本/下一轮审查）无法判断是否放行；两套数字并列也分不清哪次是终态
- **建议**：`:46` 改为「（历史结论，已由上方结案表推翻）」或直接删除；`本轮执行的校验` 加注「首轮 826；结案后 849」

### [轻微][存量] `@JitSignatures` 承诺可标注「任一 `func`」，宏生成名不含所属类型

- **位置**：`f_jit/doc/spec/f-jit-m2.3/specs/f-jit-facade-bridge/spec.md:9`
- **来源**：存量
- **判据**：review-checklist §14「承诺了但实现受限」、§13
- **证据**：待确认 —— 静态可读出生成名相同：`f_jit/src/macros/JitSignature.cj:62-70` 以 `'__jitSigRegister_' + funcNameOf(input)` 生成顶层 `public func` 与 `private let __jitSigApply_<同名>`；`funcNameOf`（`:110-115`）只取被标注声明的函数名、不带类型。故同包内两个同名方法各标注一次即产生两个同名**零参**顶层声明。未编译验证「仓颉对同名零参顶层函数是否报重定义」，故不定为缺陷严重度；现有用例只标注顶层函数（`f_jit/src/JitSignature_test.cj`）
- **描述**：spec 用「任一 `func`」描述能力面，实际可用面是「同包内函数名唯一」。该限制未出现在 spec 的边界段
- **建议**：生成名加入所属类型（`__jitSigRegister_<Type>_<func>`），或在 spec 边界写明「顶层 func 或同包内函数名唯一」，并让宏对重名给出显式诊断

> **范围外提示（不计入统计，均为读文档取证时撞见）**
> 1. `f_jit/src/compiler/Lowerer.cj:2695-2738`（`castRelation`，供 `is` 用）与 `:2802-2846`（`lowerCastOr`）是同一「左值/目标类型关系」判定的两份实现且已漂移：前者把 JSON 上行 `17/18/19 → 16` 判为静态放行，后者只判 `sCode != tCode` 就报「类型不相容」，`o as JsonValue` 疑似编译失败（未跑编译，待确认）。
> 2. `f_jit/src/runtime/HelperId.cj:21-22` 注释仍写「64–68 仍保留」，实际 64/65 已是 H64/H65、77–84 已登记；`isFixed` 实现为「名字已登记」（`:223-226`），与注释「63–68 与区间外 ⇒ false」不符；`MAX_FIXED=72`（`:125`）无任何使用；`f_jit/src/compiler/Ops.cj:244` 注释写「H66 `cast_fail`」，实际是 H77。
> 3. `f_jit/src/base/HostSignature.cj:98-99` 与 `f_jit/src/JitHost.cj:75` 注释写「未命中即编译错误」，与 m2.2 spec（未登记回退反射）及 `JitSignature_test.reflectionStillWorksWhenUnregistered` 相反。
> 4. `f_jit/src/ReflectRegistrar.cj:975` 的 `depth < 64` 是运行期父链硬上限，超出后 `$as$` 恒假，而 m2.3 spec 写的是无条件的「子类实例算命中」。

<!-- 第 11 部分 -->

### [严重][存量] `any_box`/`any_as` 的 Float64 分支用 `Int64(x.toBits())` 编码，负浮点必然溢出成 `99 HELPER_PANIC`

- **位置**：`f_jit/src/runtime/AnyHelpers.cj:83`（`any_as` 的 `case 1u16 => Int64(f.toBits())`）；同型写法另见 `f_jit/src/runtime/HostCall.cj:91`、`f_jit/src/runtime/HostField.cj:177`、`f_jit/src/runtime/HandleTable.cj:1409`、`f_jit/src/runtime/Helpers.cj:425`
- **来源**：存量（快照模式无基线）
- **判据**：checklist §11「边界 / 空值 / 契约不符」；文档侧 `doc/spec/f-jit-m3/specs/f-jit-base-contracts/spec.md:66`（可转集含 `0–8`，即 `1 = Float64` 是合法装箱/转型目标）、`doc/spec/f-jit-m3/specs/f-jit-runtime/spec.md:39-42`（「装箱往返 THEN 值型逐位相等」）、`doc/spec/f-jit-m3/design.md:20`（「helper 边界不抛异常：失败一律转错误码」）
- **证据**：静态确定
  - `Float64.toBits(): UInt64`（本机 `cangjie-coding` 知识库签名表 `toBits(): UInt64`，文档 `std.core`）；拿最高位为 1 的位模式去做 `Int64(...)` 是**整型转换**，而仓颉默认策略 `@OverflowThrowing` 明确作用于「函数内的整数运算和整型转换」，溢出抛 `ArithmeticException`（本地文档 `language/reflect_and_annotation/1-注解/1-1-整数溢出注解.md`）。全仓 `f_jit/src` 无任何 `@OverflowWrapping` / `@OverflowSaturating`（逐文件 grep 命中 0）。
  - 同仓已有 3 处**符号安全**的等价实现：`f_jit/src/runtime/Interp.cj:451-457`（`fromBits`：`b >= 0x8000…u64` 时 `Int64(b - 2^63) + Int64.Min`）、`f_jit/src/CallMarshal.cj:399`（`bitsOfCell2`）、`f_jit/src/runtime/Interp_test.cj` 的同名测试辅助。两条口径不可能同时正确。
  - helper 外层的 catch-all 会把非契约异常兜成 `ErrCode.HELPER_PANIC(99)`（`f_jit/src/runtime/HelperCore.cj` 的转码模板，见 `design.md:20` 的约定），不会落到 8/22。
- **描述**：任何负 Float64 走 `any_as` 拆箱（`any_box(-1.5)` 后取回、宿主闭包返回负浮点、读负浮点字段、`dec_to_f64` 得到负数）都不是取值失败而是**引擎缺陷码 99**，宿主会看到 `JitException(99)`；`-0.0`、负 NaN 同路径。现有用例只覆盖正值（`HostCallTrampoline_test` 用 `1.25+0.5`、`AnyBridgeCall_test` 用 `0.0`），5 处全部没被负值触发过，所以归档时的「装箱往返值型逐位相等」仍然全绿。
- **建议**：5 处统一改用已有的补码转换（`Interp.fromBits` / `CallMarshal.bitsOfCell2`，或在 `HandleTable` 收一个 `f64Cell`），并在 `AnyHelpers_test` / `HostCallTrampoline_test` 各补 `-1.5`、`-0.0`、负 NaN 三条。复核成本极低：一条 `call<Float64>([-1.5])` 用例即可证实或证伪。
- **移交说明**：本部分只审文档；该缺陷落在 `.cj`，请与负责 `runtime/AnyHelpers.cj`、`runtime/HostCall.cj`、`runtime/HostField.cj` 的分部分报告去重，定稿级别以那边为准。

### [一般][存量] 未注册的父接口被静默跳过：spec 要求「一并登记」、design 承诺「注册期诊断并拒绝」，只有 verify 说了实话

- **位置**：`f_jit/doc/spec/feat-f-jit-interface-and-inheritance/specs/f-jit-facade-bridge/spec.md:9`、`.../design.md:36`、`.../verify.md:32`；代码 `f_jit/src/ReflectRegistrar.cj:421-432`
- **来源**：存量
- **判据**：checklist §13（文档集内部不自洽）+ §3（静默降级）
- **证据**：静态确定
  - spec `:9`：「注册类或接口时，**父类型的公共成员 SHALL 一并登记**：…接口沿 `superTypes` 链」。
  - design `:16`/`:36`：父接口须先注册，未注册时「注册期诊断并**拒绝**，不做静默降级」。
  - verify `:32`：「父接口必须先注册，否则其方法不会并入（**当前静默跳过**；`verify` 记录为已知边界）」。
  - 代码 `ReflectRegistrar.cj:421-432`：`match (into.resolve(pname)) { case Some(pd) => …; case None => () }`，且 `parents` 仍原样写入描述符（`:438-440`）。
- **描述**：同一变更的三份文档三种口径（必须登记 / 拒绝注册 / 静默跳过）。实现选的是 design 明确排除的那一种，且 `parents` 仍保留 `Named`，于是前端按接口名查方法时才报「类 Greeter 未注册方法 name」——调用方拿不到「父接口没注册」这一诊断。
- **建议**：按 design 的承诺改成注册期抛 `RegistrationException`（`ReflectRegistrar.cj:415-418` 已有「接口必须用 @JitBind」的先例）；若确实要保留宽容语义，则 spec `:9` 必须写明「父接口未注册时其方法缺失」，并把 `parents` 的记载与「已并入」解耦，同时改掉 design `:16`/`:36`。

### [一般][存量] JSON 写入值域在规格里含 Float64，前端与运行期都拒绝：按文档写 `j['k'] = 1.5` 必然编译错误

- **位置**：文档 `f_jit/doc/spec/f-jit-m3/specs/f-jit-runtime/spec.md:70`、`f_jit/doc/spec/f-jit-m3/specs/f-jit-compiler-frontend/spec.md:88`；实现 `f_jit/src/compiler/Lowerer.cj:1927-1943`、`f_jit/src/runtime/JsonHelpers.cj:136-155`
- **来源**：存量
- **判据**：checklist §13（规格与实现漂移）+ §2（同一张值域表多处枚举）
- **证据**：静态确定
  - 文档两处：「值域 = 值型 0–3（Unit 除外）/ String / JSON 节点（码 16–19）」，「值型 0–3 除 Unit」= `{0, 1, 2}`，含 `F64(1)`。
  - 前端 `checkJsonWriteValue`（`Lowerer.cj:1928-1929`）只收 `I64(0)`/`Bool(2)`/`String(4)`/`16–19`，并对 `F64` 专门给诊断「JSON 无二进制浮点」（`:1931-1932`）。
  - 运行期 `jsonValueOf`（`JsonHelpers.cj:144-155`）只有 `0/2/4/16/17/18/19` 分支，其余 `failWith(HANDLE_TYPE)`；其注释（`:140-142`）自述「旧实现放行 Float64、这里落到 `case _` 报 8，正是 P3-3 的『规格-前端-运行期』三处不一致」。
- **描述**：P3-3 收口只改代码、没回写 spec。值域这张表在 4 处分别枚举（两份 spec + 前端 + 运行期），是漂移的直接成因；按 spec 写浮点写入会编译失败，绕过前端直接调 helper 则得 8。
- **建议**：两份 spec 改为「`Int64`(0)/`Bool`(2)/`String`(4)/JSON 节点(16–19)；`Float64` 与 `Decimal` 不在值域内」；若要把值域变成单一来源，在 `base` 收 `isJsonWritable(code)` 供两端引用。`JsonHelpers.cj:136` 的「0–3（Unit/Float64 除外）」字面也不成立，一并改。

### [一般][存量] 反引号 JSON 字面量的取界机制与文档相反：文档写「JSON 字符串感知 + 括号配平」，实现是「扫到下一个反引号」

- **位置**：`f_jit/doc/spec/f-jit-m3/specs/f-jit-compiler-frontend/spec.md:47`（另 `:48`「无匹配闭合 SHALL 交解析器报错」）；实现 `f_jit/src/compiler/Lexer.cj:432-452`
- **来源**：存量
- **判据**：checklist §13（规格与实现漂移）
- **证据**：静态确定
  - 文档 `:47`：「取界规则 = JSON 字符串感知 + 括号配平（`{"a":"}"}`、`["]"]`、嵌套 `[{…}]` 均正确取界）」。
  - 实现 `scanJson`（`Lexer.cj:439-452`）：`while (!isEof() && bs[cur] != 0x60) bump()`，纯反引号终结，无字符串状态机、无括号计数；同文件 `:436-437` 注释直接写「取界 = **下一个反引号**」。
  - 未闭合时在**词法层**报 `UNTERMINATED_STRING`（`:445-448`），`JsonLit_test.rejectsUnterminatedJson` 断言的也是词法错误，与 `:48` 的「交解析器报错」不符。
- **描述**：文档列举的三个用例（字符串内含 `}`、`]`、嵌套）在「扫到下一个反引号」下恰好也通过，机制差异被 scenario 掩盖。真实后果只有一条：JSON 字符串里出现**反引号**（U+0060，JSON 合法字符）时字面量提前截断，后续字节按源码语法报错，合法 JSON 无法书写（只能写 `\u0060` 规避）。属「承诺的健壮性未实现」，不是数据损坏。
- **建议**：二选一并同步 scenario：①实现字符串感知 + 配平的取界；②把 `:47` 改成「取界 = 下一个反引号；字符串内的反引号须写 `\u0060`」，`:48` 改为「词法错误」。倾向 ②，成本最低且行为可预期。

### [一般][存量] 「父类型的公共成员一并登记」未记录已知限制：父类方法含引用型参数/返回时被跳过

- **位置**：`f_jit/doc/spec/feat-f-jit-interface-and-inheritance/specs/f-jit-facade-bridge/spec.md:9`、`.../design.md:15`；实现 `f_jit/src/ReflectRegistrar.cj:589-605`、`:722-731`
- **来源**：存量
- **判据**：checklist §13（承诺面大于交付面）+ §14.1（只处理部分输入）
- **证据**：静态确定 —— 父类方法无 `@JitBind` 时走反射；若 `unsafeForReflect(sig, ret)` 为真（参数/返回落在引用型码，`:722-731`）则 `skip(diag, …, '引用型参数/返回在反射 apply 上会 SIGSEGV（GAP-13），请给父类加 @JitBind')` 并 `continue`，该成员不进子描述符。
- **描述**：design `:15` 写「方法用『父类 `@JitBind` 登记』**或父类反射 `FunctionInfo`**（具体方法可 apply，子实例可上转）」，读起来二选一皆可；实际反射路只对值型签名成立。spec 的「SHALL 一并登记」因此有例外，而例外只写在代码注释（GAP-13）里。归档 scenario（`c.parentMethod() + c.parentField`）不含引用型参数，用例不暴露。
- **建议**：spec `:9` 与 design `:15` 各补一句「父类方法含引用型参数/返回时必须 `@JitBind`，否则注册期记诊断并跳过」，并列入 verify「语义边界」。

### [轻微][存量] 特化开关的落点与 plan 生命周期：文档写 `CompilePipeline` + per-call，实现是 `SignatureTable.enabled` + 条目级常驻缓存

- **位置**：`f_jit/doc/spec/f-jit-m3/specs/f-jit-facade-bridge/spec.md:55`（开关落点）、`:108`（`HostCallback.plan` per-call）；实现 `f_jit/src/runtime/SignaturePlan.cj:129-138`、`f_jit/src/runtime/Signature.cj:383-392`
- **来源**：存量
- **判据**：checklist §13（API 位置 / 生命周期与文档不符）
- **证据**：静态确定
  - 文档 `:55`：「桥 SHALL 在 `CompilePipeline` 暴露特化开关（强制通用 / 强制特化），默认开启特化」；`:108`：「`HostCallback` SHALL 增加 `plan` 绑定，生命周期 **per-call**（随条目 try/finally 释放）」。
  - 实现：开关是 `public static var enabled`（`SignaturePlan.cj:134-135`），读点 `getOrBuild`（`:141-144`）；`CompilePipeline` 无任何特化成员（全仓 grep `specializ|forceGeneric|planMode` 命中 0，只命中文档与测试注释）。
  - `plan` 是 `HostCallback` 的 `public let`（`Signature.cj:383`，构造期 `:391` 赋值），并被 `SignatureTable` 以不可变快照**跨调用长期持有**（`SignaturePlan.cj:129-138`，`MAX_ENTRIES = 128`），没有 per-call 释放。
- **描述**：能力齐备且默认开启，「双路径对拍」用例也成立，但落点与生命周期与文档相反：按文档去 `CompilePipeline` 找开关会扑空；按「per-call 释放」推断内存模型会高估释放频率（实际 128 条常驻）。`plan` 身份无关，常驻不构成泄漏。
- **建议**：文档改为「开关位于 `SignatureTable.enabled`（运行期）；plan 归属条目并由 `SignatureTable` 快照常驻，上限 128」，或在 `CompilePipeline` 加一层转发属性以兑现原措辞。

### [轻微][存量] 并行调用变更的「完成态」描述与实现不符：`state/active` 未原子化、`lastEscaped` 仍是单元级字段

- **位置**：`f_jit/doc/spec/feat-f-jit-parallel-call/proposal.md:14`、`:15`、`design.md:60`（D6）、`tasks.md:37`（P5.1）；实现 `f_jit/src/JitFunction.cj:86-87`、`:109`、`:198-212`、`:539-545`
- **来源**：存量
- **判据**：checklist §13（设计决策 / 任务清单 / 实现三方不一致）
- **证据**：静态确定
  - `proposal.md:14`「`lastEscaped`（改为 `callForFn` 的返回值，**不再是单元级字段**）」；字段仍在（`JitFunction.cj:109`），仍由 `synchronized(this.mtx)` 写入（`:668-670`），并由 `internal func lastEscapedClosure()`（`:539-545`）读出，供单线程手工包装/诊断。
  - `proposal.md:15` 与 `design.md:60` D6 都写「`state`/`active` 改原子」；实现仍是普通 `private var Int64`（`:86-87`），读写全在 `mtx` 内（`:198-212`、`:336-349`）。
  - `tasks.md:37` P5.1 勾 `[x]` 但正文写「原子化**留待 P6 视瓶颈**」，P6（`:40-45`）没有任何原子化条目。
- **描述**：三处口径互相打架：proposal/design 写成已定决策，tasks 承认延后，代码保持 `mtx`。当前实现是安全的（同锁内访问），所以这是记录不一致而非并发缺陷；风险在于后人按 D6 认定「已无锁」而在锁外读 `active`。
- **建议**：design D6 / proposal 补「实施口径：保留单元 `mtx`，未原子化（P5.1 裁定）」；或把原子化补回 P6 任务。`lastEscaped` 的「仅单线程手工包装」限定目前只写在 `JitFunction.cj:536-538`，应上移到 proposal。

### [轻微][存量] 接口变更 design 自相矛盾：父类字段「追加到尾部」对「子类字段排在继承字段之后 / 先占号」

- **位置**：`f_jit/doc/spec/feat-f-jit-interface-and-inheritance/design.md:15`（D2）对 `:34`（风险表）、`verify.md:21`/`:27`；实现 `f_jit/src/ReflectRegistrar.cj:140`、`:526`
- **来源**：存量
- **判据**：checklist §13（同一文档内结论相反）
- **证据**：静态确定
  - `:15`：「字段**追加到子描述符尾部并重新编号**」。
  - `:34`：「仅在**子类**描述符内追加，父类描述符编号不变；**子类新增字段排在继承字段之后**」。
  - verify `:21`/`:27`：「`mergeAncestorFields`（**自有字段之前**，先占号）…自有字段从 k 开始编号」，并记录了顺序写错导致的 `32≠33` 缺陷。
  - 代码与后者一致：`mergeAncestorFields` 先于自有字段被调用（`:140`），编号为 `fields.size` 递增（`:526`）。
- **描述**：D2 的「追加到尾部」是笔误级错误，但它描述的正是本变更踩过的坑（字段全局 index 空间 + `accepts` 区分），按 D2 实现会直接复现 32≠33。
- **建议**：`:15` 改为「父类字段先登记（先占号 0..k-1），自有字段从 k 起编号；父类描述符自身编号不变」，并删掉与 `:34` 的重复表述。

### [轻微][存量] JSON 读出口的 requirement 文本与自身 scenario / 实现不符（`JsonDecimal → Decimal`）

- **位置**：`f_jit/doc/spec/f-jit-m3/specs/f-jit-runtime/spec.md:68`（requirement）对 `:74-77`（scenario）；实现 `f_jit/src/runtime/JsonHelpers.cj:116-128`
- **来源**：存量
- **判据**：checklist §13（同文件内 requirement 与 scenario 相反）
- **证据**：静态确定
  - `:68` 写「`JsonInt` 落 Int64 域内 → Int64 / 超域 → Decimal、`JsonDecimal` → Decimal」。
  - `:76-77` 的 scenario 却要求 `{"i":3}` 读出 **Int64 盒**、超大整数读出 Decimal 盒。
  - 实现 `JsonHelpers.cj:116-128`：`JsonDecimal` 若 `isInteger()` 且在 Int64 域内则返回 `Int64`，否则 `Decimal`；注释 `:117-119` 说明 `f_data` 把所有 JSON 数字都解析成 `JsonDecimal`，`JsonInt` 分支实际走不到。
- **描述**：实际规则是「整数且在 Int64 域内 → Int64，否则 Decimal」，与 scenario 一致、与 requirement 文本相反。按文本实现会把 `{"i":3}` 读成 Decimal，源级 `as Int64` 立刻 22（代码注释记载过这个坑）。
- **建议**：requirement 改为「数字节点：整数值且在 Int64 域内 → Int64，否则 Decimal（不区分载体内 `JsonInt`/`JsonDecimal`）」。

### [轻微][存量] `tasks.md` 的验收引用指向不存在的 `verify.md`，3 条 partial 既非 full 也未标 GAP

- **位置**：`f_jit/doc/spec/f-jit-m3/tasks.md:14`；对照 `.../specs/f-jit-differential-acceptance/spec.md:26-29`
- **来源**：存量
- **判据**：checklist §1（无下文的引用）/ §13（路径失效）/ §14.1
- **证据**：静态确定 —— `doc/spec/f-jit-m3/` 只有 `design.md` / `proposal.md` / `scenario-map.tsv` / `tasks.md` / `specs/`；同族 `f-jit-m1`、`f-jit-m2`、`f-jit-m2.1` 均有 `verify.md`。`scenario-map.tsv` 80 行、`GAP` 计数 0，但有 3 条 `strength=partial`（「宿主值不可常量化」「一次解析」「冷路径回退」）。
- **描述**：`proposal.md:22` 用「（若存在）」对冲，`tasks.md:14` 无条件引用，归档后成为断链。差分规格要求「未覆盖的 scenario 显式标 GAP，不得静默」，而缺口说明的唯一指定落点就是那个不存在的 `verify.md`，3 条 partial 因此悬空。
- **建议**：补 `verify.md`（全量计数、三引擎结论、GAP 清单），或把 `tasks.md:14` 与 `spec.md:28` 改为只引用 `scenario-map.tsv` 并给 3 条 partial 标 GAP。

### [轻微][存量] 「桥的错误码映射静态表 / 22 行独立存在」在实现中没有对应结构

- **位置**：`f_jit/doc/spec/f-jit-m3/specs/f-jit-base-contracts/spec.md:57-60`；实现 `f_jit/src/JitReport.cj:38-55`
- **来源**：存量
- **判据**：checklist §13（文档描述的结构不存在，scenario 不可执行）
- **证据**：静态确定 —— `throwJit` 只对 `-2`（`InterruptedException`）与 `21`（附 `HostFault` cause）特判，其余一律 `throw JitException(code, site, fnId, None, report)` 原码透传；不存在逐码行表，22 也没有「独立一行」。`scenario-map.tsv` 把该 scenario 映射到 `fullPositiveCodeRangeMapsToJitException`（`JitReport_test.cj:125-150`），它是**循环验码**，不是遍历静态表。
- **描述**：要求写的是实现结构，而实现选了更简的通用透传；真正有价值的约束（22 不折叠成 7/21）只是靠两条独立代码路径成立，文档却声称存在可审计的映射表。
- **建议**：requirement 改为「桥 SHALL 按原码透传 1–23/99，仅 -2 转 `InterruptedException`、21 附原始异常；SHALL NOT 把 22 折叠为 7/21」，删掉「静态表 / 22 行」的说法。

<!-- 第 12 部分 -->

### [一般][存量] 幂运算优先级的验收值与实现相反：规格写 `-2 ** 2` = -4，实现与测试给 4

- **位置**：文档 `f_jit/doc/spec/feat-f-jit-pow-and-sci-notation/specs/f-jit-runtime/spec.md:16`（`` `-2 ** 2` = `-(2 ** 2)` = -4 ``）、`f_jit/doc/spec/feat-f-jit-pow-and-sci-notation/design.md:60`（语法层用例「`-2 ** 2` = -4」）；实现 `f_jit/src/compiler/Parser.cj:972-980`（`parsePower` 左操作数取 `parseUnary`）、`f_jit/src/Pow_test.cj:53-57`（断言 4）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §13「规格与实现漂移」「示例代码不能用」；§11「与规格 / README 冲突」；语言侧仓颉文档 `cangjie_docs/docs/dev-guide/source_zh_cn/Appendix/operator.md`「操作符优先级表」——`-`（一元）为 **3**、`**` 为 **4**，且该表明写「优先级一栏数值越小，对应操作符的优先级越高」
- **证据**：静态确定 —— 一元负号比 `**` 更紧 ⇒ `-2 ** 2` = `(-2) ** 2` = 4；`Parser.cj:973` 的 `let left = this.parseUnary()` 正是这个结合方式，`Pow_test.cj:57` 断言的也是 4，`README.md:481` 同样写 4。仓颉文档给出的顺序与实现一致，只有 spec/design 两处写成 Python 语义的 -4；`design.md:8` 自己的「优先级 4（> `*`，< 一元 `-`）」也与同行结论自相矛盾
- **描述**：按 spec 的 Scenario 写验收用例（`{ => -2 ** 2 }` 期望 -4）必然红；反过来，读 spec 的人会认为方言与仓颉在负号结合上不一致。这条是规格给出的**可执行验收值**，不是措辞问题
- **建议**：`spec.md:16` 与 `design.md:60` 改为 `` `-2 ** 2` = `(-2) ** 2` = 4（一元 `-` 优先级 3 高于 `**` 的 4） ``，与 `README.md:481` / `Pow_test.cj:57` 对齐；若要保留「与仓颉一致」的论证，把 `operator.md` 的两行优先级一并引到 spec 里

### [一般][存量] 负指数字面量：proposal/design 承诺「编译期拒绝」，spec 与实现是「运行期 14」

- **位置**：文档 `f_jit/doc/spec/feat-f-jit-pow-and-sci-notation/proposal.md:21`（「字面量负指数**编译期拒绝**」）、`design.md:9`（「字面量负值 → 编译期拒绝；运行期负值 → 14」）、`design.md:23`（Lowerer「字面量负指数 → 编译期拒绝」）；对照 `specs/f-jit-runtime/spec.md:17-18`（两条都写「指数为负（**含字面量**）⇒ 运行期 `ERR_ARG_MISMATCH(14)`」）；实现 `f_jit/src/compiler/Lowerer.cj:1393-1401`（`case StarStar` 只判两侧类型 + `setSite` + `callHelper(H84)`，无字面量负值特判）、`f_jit/src/Pow_test.cj:76-88`
- **来源**：存量
- **判据**：review-checklist §13「规格与实现漂移」；§14.1「承诺了但没实现」
- **证据**：静态确定 —— `Lowerer` 的 `case StarStar` 分支 9 行内没有任何「右操作数是负 `Lit`」的判断，负指数一律落到 helper；`spec.md:18` 还把 `:17` 的同一件事重写了一遍（`含字面量` 与 `运行期指数为负` 两条 Requirement 内容重叠）
- **描述**：同一变更的两份文档对同一输入给出两种时机（编译期异常 vs 运行期 `JitException(14)`）。两者都「能拦住」，但错误面不同：写 `2 ** -1` 的宿主若按 proposal 处理 `SourceCompileException`，实际拿到的是运行期 `JitException`；反之按 spec 写测试则与 design 的落点表不符
- **建议**：二选一并三处同步——推荐保留实现的「统一运行期 14」（少一条特判、与「常量折叠不特判 `2 ** 63`」口径一致，见 `design.md:10`），把 `proposal.md:21`、`design.md:9,23` 改为「负指数（含字面量）运行期 14」；若坚持编译期拒绝，则 `Lowerer` 需在 `:1396` 前加 `Lit(Int64, v) && v < 0` 分支并补编译期用例

### [一般][存量] H84 未升 `verMinor`，但「取舍记入 verify.md 与 README 已知限制」两处落空；旧加载器仍会接受含 H84 的单元

- **位置**：文档 `f_jit/doc/spec/feat-f-jit-pow-and-sci-notation/tasks.md:32-33`（`verMinor` **不升级**，「取舍记入 `verify.md` 与 README「已知限制」」）；对照 `design.md:27`、`proposal.md:31`（仍写「`verMinor` **14 → 15**，旧加载器不该接受含 H77 的单元」）；代码 `f_jit/src/base/Version.cj:74`（写出 `verMinor = 14`）、`f_jit/src/runtime/Helpers.cj:139-146`（`case 84 => ipow`；`case _` 且 `hid < USER_BASE` ⇒ `failWith(ErrCode.NOT_IMPL)`）
- **来源**：存量
- **判据**：review-checklist §13「链接 / 路径失效」「文档过期」；§14.1「版本与依赖漂移」；`fountain-baseline.md` §1（模块版本与产物版本要对齐）
- **证据**：静态确定 —— `ls f_jit/doc/spec/feat-f-jit-pow-and-sci-notation/` 只有 `design.md` / `proposal.md` / `specs/` / `tasks.md`，**没有 `verify.md`**（同批 5 个 `fix-*` 变更都写了 verify，只有这个没有）；`README.md` §8「已知限制」（:603-612）逐条核对无 `verMinor` / H84 相关条目；`specs/f-jit-runtime/spec.md` 与 `tasks.md` 都没有把「不升级」写进规格
- **描述**：设计阶段识别出的风险是「版本门保护」：旧版运行期只认到 H83，遇到 H84 会走 `case _` → `NOT_IMPL`，而不是版本拒绝。`tasks.md` 决定不升级版本（理由是 6 个 Golden 指纹 + 2 个常量表断言要改），这个决定本身可以接受——**但它把「记录」这件事标了 `[x]`，而两个记录点都不存在**。后果：跨版本交换 `.fbc`（README §1 明说 `.fbc` 是纯数据、可移植）时，含 `**` 的单元会被旧运行期当成格式合法单元接下，再以 `NOT_IMPL` 失败，排障时看不出是版本问题
- **建议**：二选一——① 补写 `feat-f-jit-pow-and-sci-notation/verify.md`（记「不升级的理由 + 影响面 + 6 个 Golden 指纹清单」）并在 `README.md` §8 加一条「含 `**` 的单元要求同版本运行期（H84 不在旧版白名单，旧版会以 `NOT_IMPL` 失败）」；② 或改为在 `FbcHeader` 侧给「使用 H84」加一条能力位，让加载期直接 `rejectFormat('该单元需要 H84')`。同时把 `design.md:27` / `proposal.md:31` 标注为「已被 tasks 4.2 取代」

### [一般][存量] 注册失效与在飞编译交错时，失败缓存仍会在 `invalidateFailures()` 之后被重新固化（H2 的「注册后同源可重试」在并发下不成立）

- **位置**：`f_jit/src/CompileCache.cj:98-105`（`fail()` 无条件写 `failures[key]`）、`:114-118`（`invalidateFailures()` 只做 `clear()`）、`:60-70`（`claim()` 在 `failures.contains(key)` 时拒绝认领）、`:128-160`（`awaitReady` 立即返回 `None`）；注册侧 `f_jit/src/Compiler.cj:82`、`:96`、`:129`、`:141`、`:156`；管线侧 `f_jit/src/CompilePipeline.cj:70-89`（`claim` → `c.snapshot()` → 失败 → `catch` → `CompileCache.fail`）
- **来源**：存量（`fix-compile-failure-cache-sticky` 引入的失效机制本身；此处是其并发边界未被覆盖）
- **判据**：review-checklist §12.1「检查-然后-写入」「可见性 / 发布顺序」；§11「并发正确性」
- **证据**：静态确定（窗口存在，命中概率需实测）——`runSource` 不持 `Compiler.mtx` 跑管线，快照在 `claim` 之后单独取（`CompilePipeline.cj:72`）；注册线程只清 `failures`，不阻断已在飞的编译。时序：T1 `claim(key)` + 旧快照 → T2 `registerClass`（`Compiler.mtx` → `invalidateFailures()`，此时表为空）→ T1 编译失败 → `fail(key)` 写入「未注册的类名」→ 之后同一源码 `claim` 恒 `false`、`awaitReady` 恒 `None`、`missingResult` 复述旧文本，与 `proposal.md:19-22` 描述的原缺陷完全一致，只是窗口从「永久」缩到「一次注册与一次在飞失败之间」
- **描述**：`fix-compile-failure-cache-sticky` 修的是「失败结论被永久固化」，实现手段是「注册时清表」。但清表与写表之间没有先后约束：谁的锁后到谁生效。宿主的典型用法正是「编译失败 → 补注册 → 重试」，若补注册与首次编译并发（多线程宿主、或多请求各自编译），补注册可能先清表、首次编译后写表，重试依旧拿到注册前的错误文本
- **建议**：给注册表加**代际**（epoch）而不是用 `clear()` 表达失效：`Compiler` 侧维护 `registryEpoch`（注册/注销 +1，读值与 `snapshot()` 同一临界区取），`fail()` 写入 `(epoch, msg)`；`claim()` / `failureOf()` 只认 `epoch == 当前值` 的条目，过期条目视为不存在（顺带让 `failures` 的上限清理可以从「整表清空」变成「按代际淘汰」）。回归护栏：4 线程交替 `compile` 与 `registerClass`，循环若干轮后断言「注册后的同源编译成功」

### [轻微][存量] `HelperId` 名称表与 `isFixed` 未登记 H84，hid 值域用例仍以 83 为上限

- **位置**：`f_jit/src/runtime/HelperId.cj:121`（`IPOW = 84u16`）与 `:130-221`（`name()` 的 case 表止于 `83u16`，`case _` ⇒ `'unknown(${hid})'`）；`f_jit/src/runtime/Helpers_test.cj:110-131`（`expected` 列表止于 83，断言 `size == 80`）；`f_jit/src/compiler/Ops.cj:210`（注释仍写「`1–62`、`69–83` 为固定 helper」）；文档侧 `design.md:25`（「`IPOW = 77` + 名称表」）、`tasks.md:16`
- **来源**：存量
- **判据**：review-checklist §13「文档与代码一致性」；§14.1「接线缺失」（新增线上码未接入名称表与值域守卫）；§2「重复逻辑」（`Ops.HelperCodec` 与 `runtime.HelperId` 两份 hid 常量的唯一守卫失效）
- **证据**：静态确定 —— `HelperId.name(84u16)` 落入 `case _` ⇒ `unknown(84)`，`isFixed(84u16)` ⇒ `false`；全仓 `HelperId.IPOW` 引用数为 0（`Helpers.cj:139` 用字面量 `case 84` 分派），因此没有任何代码或用例会把 84 补进名称表
- **描述**：`Ops.cj:214-218` 明写「hid 两侧各持一份常量…由「hid 合法值域」用例（`HelperId.isFixed`）在差分层守住一致性」，这条不变量对 H84 已经失效：若 `Ops.IPOW` 与 `Helpers.cj` 的 `case 84` 将来漂移，没有任何用例会红。当前可见影响只到诊断面（`name(84)` 打印 `unknown(84)`；`isFixed` 无生产调用点，仅测试与注释引用）
- **建议**：`HelperId.name` 补 `case 84u16 => 'ipow'`，`Helpers_test.helperIdsCoverSpecRange` 的 `expected` 追加 84 并把 `size` 改 81，`Ops.cj:210` 注释改 `1–62`、`69–84`；顺带在 `Helpers.cj:139` 用 `HelperId.IPOW` 替掉字面量 `84`

### [轻微][存量] H6 的三态判定分两次取锁，`failureOf` 与 `isCompiling` 之间状态可变，会给出错误 kind

- **位置**：`f_jit/src/CompilePipeline.cj:129-141`（`missingResult` 先 `failureOf` 再 `isCompiling`，两把锁分别进出）
- **来源**：存量
- **判据**：review-checklist §12.1「检查-然后-写入」「可见性」；§11「契约与实现不符」
- **证据**：静态确定 —— 两个读各自 `synchronized(mtx)`，中间没有持锁；`CompileCache.cj:132-137`（`awaitReady` 的 `done` 与 `ready.get` 也分两次取锁，同一模式）
- **描述**：本变更的卖点是「调用方能区分『源码有问题』与『等太久』」。在 `awaitReady` 返回 `None` 到 `missingResult` 判定的间隙，另一线程可能刚 `claim` 同一 key（`compiling` 由假变真）⇒ 报 `CompileTimeout`「等待超时（30 s）」；或刚 `fail` 写入文本 ⇒ 本该复述原文却回落到 fallback。都是诊断文本层面的误判，不影响是否抛异常
- **建议**：把三态判定收进一次临界区（`CompileCache.classify(key): (kind, msg)` 内部读 `failures` / `compiling` / `ready`），或让 `awaitReady` 直接返回 `(state, ?JitFunction)` 三元结果，把「为什么是 None」在锁内定型

### [轻微][存量] `feat-f-jit-parallel-call/verify.md` 的「未完成 / 风险」与同文件「实施内容」自相矛盾（P1.5 计数器、P1.2d `freeSlots`、`unloadFn`）

- **位置**：`f_jit/doc/spec/feat-f-jit-parallel-call/verify.md:46`（「`NativeMem.malloc/freeCount` 改 `AtomicInt64`」）对 `:98`（「P1.5：`NativeMem.mallocCount/freeCount` 仍为普通静态计数」）；`:45`（「`freeSlots` 争用评估…保持全局短锁」）对 `:30`（P0 分块存储）与 `f_jit/src/runtime/HandleTable.cj:983`（`freeSlots` 只剩一条注释）；`:101-102`（「主规格 `f_jit-facade-bridge` 的 `unloadFn` 仍待单独立项」）对 `doc/spec/align-jitfunction-close-naming/verify.md:12`（主规格 `unloadFn` / `unload(` 已 0 处）
- **来源**：存量
- **判据**：review-checklist §13「文档过期」「规格与实现漂移」
- **证据**：静态确定 —— `f_jit/src/runtime/JitContext.cj:29-30` 是 `AtomicInt64(0)`，`:36-43` 走 `load()`；全仓 `freeSlots` 仅剩注释一处，槽位由段式 `alive/gens` 管理（`HandleTable.cj:174-178`），空闲索引已改为 `FreeStripes(64)` 分片（`HandleTable.cj:86-103`、`:202`，由 `doc/spec/optimize-call-path-phase2/verify.md:22` 记录）；`unloadFn` 对齐已由 `align-jitfunction-close-naming` 完成
- **描述**：「未完成 / 风险」这一节看起来是 P1 阶段写的快照，P5/P6 落地后没回填。读者据 :98 会认为并发计数存在丢更新，据 :96 会认为槽回收仍是全局 `ArrayList`，据 :101-102 会把已完成的命名对齐继续排期 —— 三条都与现状相反，也会让人误判 P0/P1.5 其实没做完
- **建议**：把 `:96-98` 两条改成「已完成」并指向落点（`JitContext.cj:29-30`、`HandleTable.cj:86-103`），`:101-102` 加「已由 `align-jitfunction-close-naming` 完成（见其 verify §一致性检查）」，只保留仍然成立的 `:99`（吞吐目标与专用机器复测，仍未完成）

### [轻微][存量] H5 计划里的护栏规模（4 线程 × 100 类、每类 2 方法）与 tasks / verify / 实际用例（4 × 20、每类 1 方法、80 次编译）不一致

- **位置**：`f_jit/doc/spec/fix-compiler-register-lock/proposal.md:43-45`；对照 `tasks.md:6`、`verify.md:36-38`、`f_jit/src/CompilerRegistrationConcurrency_test.cj:45`（`per = 20`）、`:60`（每类 1 个 `PublicMethod`）
- **来源**：存量
- **判据**：review-checklist §13「文档过期 / 计划与落地不一致」
- **证据**：静态确定 —— 三处数字直接可读：proposal 100/2、tasks 20/1、代码 20/1
- **描述**：proposal 写的是「计划时的护栏」，落地缩了 5 倍（100 类 → 20 类）。缩规模本身可能是有意的（4×100 注册会显著拖慢全量），但 proposal 没有回填，读者会以为并发注册的覆盖面比实际大
- **建议**：`proposal.md:43-45` 改成与落地一致（4 线程 × 20 类 × 1 方法 + 80 次编译），并注明「规模化到 100 类会显著拖慢全量，故取 20」

### [轻微][存量] `test-plan.md` 的 8 条计划用例有 6 条在仓内不存在，门槛「单线程与 `9357e98f` 逐位一致」也没有对应证据

- **位置**：`f_jit/doc/spec/feat-f-jit-parallel-call/test-plan.md:7-14`（`concurrentWindowsDoNotInterfere` / `pinDedupeStaysInWindow` / `iterTablePerCallIsolation` / `sameUnitParallelCalls` / `wrapperCrossThread` / `unloadDuringParallelCalls` / `parallelThroughput` / `deadlineIsThreadLocal`）、`:15`（门槛「单线程路径与 `9357e98f` 逐位一致；无句柄/内存泄漏」）
- **来源**：存量
- **判据**：review-checklist §13「链接 / 路径失效」，§14.1「承诺了但没实现（验收门槛无证据）」
- **证据**：静态确定 —— 全仓搜这 8 个名字只有 `deadlineIsThreadLocal` 命中（`src/runtime/ThreadLocalEnv_test.cj`）；实际用例名见 `verify.md:71-75`（`concurrentWindowsKeepSeparateAccounting`、`iterTablesAreThreadPrivate`、`resetWindowDoesNotKillSlotReusedByAnotherThread`、`concurrentReleasesDropRefcountExactly` 等）。`verify.md` 全文无 `9357e98f`、无「逐位 / 逐字节对比单线程路径」的记录，只有全量用例数与 `liveCount` / `NativeMem.outstanding()` 回基线（`:47`）
- **描述**：计划与落地各用一套名字，追踪「哪条断言被哪个用例覆盖」时必须人工对照；`pinDedupeStaysInWindow`（窗口内去重）与 `sameUnitParallelCalls`（同单元 4×500）在落地用例里找不到同名对应物，无法判断这两条计划断言是否被放弃
- **建议**：`test-plan.md` 顶部加一行「已被 `verify.md` 取代，用例名以 verify 为准」，并把 8 条映射到实际用例名（缺的标 GAP）；门槛里的「与 `9357e98f` 逐位一致」若未执行，改为「同单元单线程结果与改造前用例集合一致（见 `ParallelCall_test`）」

### [轻微][存量] 设计文档写 `mulChecked` 用「显式边界判断」，实现是 try/catch 兜底

- **位置**：`f_jit/doc/spec/feat-f-jit-pow-and-sci-notation/design.md:43-44`（「`mulChecked(a, b)`：显式边界判断（`MinInt64 * -1`、符号组合的 `MIN/…`、`MAX/…` 阈值）」）；实现 `f_jit/src/runtime/PowHelper.cj:60-72`（只特判 `0` 与 `Min * -1`，其余走 `try { a * b } catch (_: Exception) { failWith(OVERFLOW_I64) }`）
- **来源**：存量
- **判据**：review-checklist §13「规格与实现漂移」；§3「静默吞异常」（`catch (_: Exception)` 会把非溢出异常也归一成 3）
- **证据**：静态确定 —— 函数体 13 行，显式阈值判断只有 `a == 0 || b == 0` 与 `Min * -1` 两处；`MAX/…` 分支不存在
- **描述**：两种写法在「溢出 → 3」这一契约上等价（默认溢出策略是抛异常），所以不算行为缺陷；但 `catch (_: Exception)` 的捕获面比「溢出」宽，未来若 `a * b` 因其它原因抛异常（例如调试断言），会被伪装成溢出码 3；另外异常控制流在 hot helper 里的开销也没有数据
- **建议**：要么按 design 改成显式阈值（`a > 0 == b > 0` 时比较 `a > MAX / b`，异号时比较 `a < MIN / b`），要么把 design 改成「以溢出异常为准，捕获后归一为 3」并把 `catch` 收窄到 `ArithmeticException`

### [轻微][存量] 幂变更承诺的词法错误面用例（`***` 切分、`1e`、`1e+`、`1.5f32`）一个都没有落地

- **位置**：`f_jit/doc/spec/feat-f-jit-pow-and-sci-notation/design.md:59`（词法层用例清单）、`:71`（风险表「`***`、`**=` 需覆盖」）、`proposal.md:35`、`specs/f-jit-runtime/spec.md:50,58-61`（非法形态 SHALL 词法错误）；实现 `f_jit/src/compiler/Lexer.cj:817-820`（`***` → `**`+`*`）、`:354-367`（指数缺数字 ⇒ `BAD_NUMBER`）、`:379-382`（数字紧邻标识符 ⇒ `BAD_NUMBER`）
- **来源**：存量
- **判据**：review-checklist §14.1「半成品 / 承诺的护栏缺失」；§13「规格与实现漂移」
- **证据**：静态确定 —— 全仓搜 `***`、`1.5f32`、`f32`、`'1e'` 在 `src/**/*.cj` 只有 `Lexer.cj:818` 的注释命中，无任何用例；`Lexer_test.cj:146` 只是 token 名映射表里的 `StarStar` 分支，不是切分用例。`Pow_test.cj` / `NumberLitSci_test` 6+5 条全是执行层用例
- **描述**：实现侧三条错误面**确实存在**（缺数字、紧邻标识符、`***` 贪心 2 字符），但 spec 把它们写成 SHALL，且 design 明确要求词法层用例，落地为零。一旦有人改 `scanOp` 的匹配顺序（`**` 与 `*`），无护栏会红
- **建议**：`Lexer_test` 补 4 条：`2**3` → `[Int, StarStar, Int]`、`2***3` → `[Int, StarStar, Star, Int]`、`1e`/`1e+` → `BAD_NUMBER`、`1.5f32` → `BAD_NUMBER`；`spec.md:58-61` 的 Scenario 引用这些用例名

### [轻微][存量] 锁序论证句「两条路径各自只持一把锁」与 `close` 实际持两把锁不符

- **位置**：`f_jit/doc/spec/fix-compilecache-lock-order/verify.md:29`（「改后 `finish` 不再在缓存锁内取单元锁，两条路径各自只持一把锁，ABBA 消失」，同结论见 `proposal.md:24-25`）
- **来源**：存量（快照模式）
- **判据**：review-checklist §13「文档与代码一致性」；§12.1「判安全要指出具体同步手段与顺序」
- **证据**：静态确定 —— `f_jit/src/JitFunction.cj:256-263`：`close` 在 `synchronized(this.mtx)` 内调用 `CompileCache.remove(k)`，仍持「单元锁 → 缓存锁」两把锁。ABBA 结论本身成立（反向的「缓存锁 → 单元锁」已由 `CompileCache.cj:80-87`「先 bind 后进锁」消除），但「各自只持一把锁」这句不成立
- **描述**：结论对、论证句错。后续有人依据「close 只持一把锁」在 close 路径再嵌一层锁，就会重新造出相反顺序
- **建议**：改为「`finish` 只持缓存锁（bind 在锁外）；`close` 仍持单元锁再取缓存锁（单向）；两条路径不再出现相反顺序」

### [轻微][存量] 并行吞吐表的「加速比」口径未注明，按墙钟直算会得到相反符号

- **位置**：`f_jit/doc/spec/feat-f-jit-parallel-call/verify.md:84-92`（同表复制到 `doc/spec/feat-f-jit-parallel-call/design.md:115`）
- **来源**：存量（快照模式）
- **判据**：review-checklist §6.1「性能结论必须可复核：输入规模 + 工具 + 对照 + 口径」；§13「数据口径」
- **证据**：静态确定（表内数字自算）—— 1 线程 734 ms、2 线程 1154 ms：按「单次调用延迟」读是 **0.64×（变慢）**，只有按「每线程各跑同一 2M 单元、加速比 = 线程数 × 734 / 墙钟」才得到 1.27×（2×734/1154）、2.40×（4×734/1220）、1.91×（8×734/3061）；文档未写这个定义
- **描述**：同一张表按最常见的「单线程耗时 / 并行耗时」读法，2 线程那一行（墙钟 734 → 1154 ms）与「1.27×」相反。数据自洽，缺的是口径，复核者无法直接重算
- **建议**：表头补「每线程各执行 1 个 2M 循环单元；加速比 = N × 734 ms / 墙钟（聚合吞吐）」，并注明 2 线程墙钟上升是共享 VM 干扰，不代表单调用变慢

<!-- 第 13 部分 -->

### [一般][存量] 缺陷→用例登记表在三处重复维护且已漂移：条数 27 vs「26 条」，6 组用例名与 tasks/verify 不一致，`p1_4_` 前缀被两组不同缺陷共用

- **位置**：`f_jit/doc/spec/fix-f-jit-audit-defects/test-plan.md:1`（标题「26 条」）、`:8-34`（实际 27 行）；`tasks.md:12`（A0.2 注「`test-plan.md`，26 行」）；`tasks.md:38-52` 与 `verify.md:27-51`（实际用例名）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §2「字面量复制 / 近似重复：两块内容相似但已漂移」、§13「规格与实现漂移」、§14.1「验收矩阵口径」
- **证据**：静态确定 —— `grep -c "^| P" test-plan.md` = 27（P0-1a、P0-1b 拆行，P2-2a/2b 合并），而 design.md / proposal.md / tasks.md 均称 26 条；逐条比对三份清单，6 组用例名不一致：P0-2（`p0_2_callAnyAndJsonAreReachable` ↔ `p0_2_callAnyIsReachable` + `p0_2_callJsonReturnsAreReachable`）、P0-6（`p0_6_nestedInvokeRestoresDeadline` ↔ `p0_6_deadlineRestoredAfterCall`）、P1-7（`p1_7_constMapFloatDecimalKeysHit` ↔ `p1_7_constMapFloatKeysHit` + `p1_7_constMapDecimalKeysHit`）、P2-2（`p2_2_iterTableClearedPerCall` ↔ `p2_2_bridgeClearsIterTableAtCallEnd` + `p2_2_iterTableClearInvalidatesCursor`）、P2-5（`p2_5_a64Imm9SlowPath`，此名全仓不存在）、P3-3（`p3_3_jsonSetFloat64Domain` ↔ `p3_3_jsonSetFloat64RejectedAtCompileTime` + `p3_3_jsonSetAcceptsValueDomain`）；另 `p1_4_` 前缀同时被 `f_jit/src/compiler/AnyCastAux_test.cj:42`（`p1_4_auxCarriesAsHelperId`，aux 承载 helper id，属 P0-1 面）与 `f_jit/src/compiler/A4Frontend_test.cj`（`p1_4_elseIfParses`，才是 P1-4）占用
- **描述**：`test-plan.md` 是本变更自我规定的「A0.2 唯一缺陷清单」，但同一份事实在 `tasks.md`（每任务括注真实用例名）与 `verify.md`（落点表）各存一份副本，三份已经不同步。后果是**清单不能用作检索入口**：按 `test-plan.md` 的 `p2_5_a64Imm9SlowPath` 搜不到任何用例，按 `p0_2_callAnyAndJsonAreReachable` 也搜不到；`p1_4_` 前缀冲突则让「每条缺陷有唯一用例名」这条自定纪律失效（P1-4 是 `else if` 语法，aux 是 P0-1）。同一次审查在 P3-4 里刚把「矩阵虚报」列为必须消灭的形态，本表自身却复现了轻量版本
- **建议**：把 `test-plan.md` 定为唯一登记源（用例名列写**最终**名字），`tasks.md` / `verify.md` 只引缺陷 ID、不复制用例名；`p1_4_aux*` 三条重命名为 `p0_1_aux*`；把 26/27 的口径写清（「26 个缺陷 ID，P0-1 拆 1a/1b 展开为 27 行」）

### [一般][存量] 本变更自身 spec 要求「用例名 SHALL 含缺陷编号」，P2-5 的三个落点用例名全都不含

- **位置**：`f_jit/doc/spec/fix-f-jit-audit-defects/specs/f-jit-differential-acceptance/spec.md:7`（`用例名 SHALL 含缺陷编号（P0-1 … P3-5）`）；落点 `tasks.md:64`、`verify.md:45`（`imm9OverflowUsesScratchRegister` / `largeOffsetIsChunked` / `deepFrameExceedsImm9`）
- **来源**：存量
- **判据**：review-checklist §14.1「承诺了但没实现」、§13「规格与实现漂移」
- **证据**：静态确定 —— `grep -rn "func p2_5_" f_jit/src` 零命中；三个用例实际定义在 `f_jit/src/backend/A64Emitter_test.cj:225` / `:248`（前两条）与 `f_jit/src/compiler/A64Exec_test.cj:221`（第三条），名字均不含 `P2-5`；同型反例还有 P0-3 的 `bnotInvertsAndPopsOperand`（`f_jit/src/runtime/Interp_test.cj:390`）与 P2-3 的 `releaseReclaimsEscapedSlot`（`f_jit/src/runtime/HandleTableM2_test.cj:201`），即 26 条里至少 5 条落点用例无可检索的编号
- **描述**：这是「本变更自己的验收规格未被自己的交付满足」的完整双证（承诺源 `spec.md:7`，缺失证据是 0 命中的函数名搜索）。危害不在编译期，而在于按编号追溯：「P2-5 是否有语义断言用例」这个问题，从用例名无法回答，只能靠 `verify.md` 的人工映射；而 `verify.md:45` 与 `test-plan.md:28` 又给了不同名字，追溯链断在两处
- **建议**：把三条改名为 `p2_5_imm9OverflowUsesScratch` / `p2_5_largeOffsetIsChunked` / `p2_5_deepFrameExceedsImm9`（保持 diff 最小），或把 `spec.md:7` 的要求改为「登记表须能按 ID 检索到用例」（弱化到清单层）；二者选一，不要让规格与实现各说一套

### [一般][存量] 零回归门槛的数字自相矛盾：`tasks.md` 写「1076 用例 / 1075 通过 / 0 失败 / 0 error」，`verify.md` 写 1076/1076

- **位置**：`f_jit/doc/spec/fix-f-jit-audit-defects/tasks.md:74`（A7.6）；对照 `verify.md:8`（「1076 用例 / 1076 通过 / 0 失败 / 0 error / 0 skipped」）、`verify.md:7`（基线 1026/1026）、`verify.md:9`（新增 50 条 = 4+14+7+10+6+5+4）
- **来源**：存量
- **判据**：review-checklist §13「文档过期 / 记录与结论不符」、§11「契约与实现不符」；本变更的门槛条款见 `specs/f-jit-differential-acceptance/spec.md:9`（用例数与失败数 SHALL 与基线对照留档）
- **证据**：静态确定 —— 算术上 1076 − 1075 = 1，而同一行又写「0 失败 / 0 error」，`verify.md:8` 还显式写「0 skipped」，三者不能同时成立；`tasks.md:74` 括注「`PerfOverride_test` 负载下假失败，单跑通过」与「0 失败」也互斥
- **描述**：A7.6 是本变更的唯一总验收口，也是「零回归」这一硬门槛的唯一证据。1075 与 1076 差的那一条要么是漏跑、要么是假失败未计入，两种解释都意味着**门槛当时是带缺口通过的**；读者无法从这两份记录判断到底是哪一种。由于本变更的核心主张是「26 条缺陷全部收口且零回归」，这条数字矛盾直接影响结论可信度
- **建议**：二选一并写清口径 —— 若 `PerfOverride_test` 计入失败，则记「1076 / 1075 通过 / 1 失败（负载敏感，单独复跑通过）」；若不计入，则 `verify.md:8` 与 `tasks.md:74` 统一为 1076/1076 并删掉「1075」，同时在 `verify.md` 注明该用例的处置方式（排除 / 重跑通过）

### [一般][存量] `fix-f-jit-x86-stack-align` 的 `design.md` 未随实现调整回写：手写栈效应表、字节级断言、1091 绿判据三项都与最终实现相反

- **位置**：`f_jit/doc/spec/fix-f-jit-x86-stack-align/design.md:57-67`（§3.1 声明 `public struct StackEffect`、`stackEffect(op, operands)`、`analyzeDepth(code, codeOff, codeLen)`）、`:75`（§5 缓解列「表完整性用例守护」）、`:103-105`（§4.1③ 要求 `48 83 EC 08` 字节级断言）、`:113`（§4.3「全量 1091/1091」）；对照 `tasks.md:10-12`（1.3「原计划的字节级对齐断言改为 `X86Depth` 的 5 个单测」）、`tasks.md:16-20`（2.1「**（实现方式调整）** 不维护手写栈效应表：改由探针遍采集 `delta[off]`」）、`tasks.md:33`（4.1 实测 1098 例 / 1094 过）；代码 `f_jit/src/backend/X86Depth.cj:28-29`、`:57-65`
- **来源**：存量
- **判据**：review-checklist §13「规格与实现漂移」「文档过期」
- **证据**：静态确定 —— `X86Depth.cj:28-29` 注释明写「指令的栈增量由 `X86Lower` 的探针遍采集（`delta[off]`），因此**不维护第二份手写栈效应表**」；实际签名 `analyze(code, codeOff, codeLen, delta: HashMap<Int64, Int64>)`（`X86Depth.cj:64-65`），`f_jit/src/backend` 下 `grep "stackEffect\|analyzeDepth"` 零命中；**同名的 `StackEffect` 只存在于前端** `f_jit/src/compiler/Ops.cj:305`（`BytecodeBuilder` 用），与后端无关，因此按 design 去 backend 找这张表会先撞上这个同名类
- **描述**：`tasks.md` 用「（实现方式调整）」如实记了三次偏离（表→探针遍、字节断言→单测、1091→1098），但 `design.md` 一字未改，仍以「新方案 A：CFG 前扫 + 逐指令深度表 + 栈效应表」叙述，并把「表完整性用例」写成风险缓解手段。读到 design 的人会以为存在一张需要维护的 opcode 栈效应表、以及一条字节级对齐断言；两者都不存在。§4.3 的绿判据「1091/1091」也与最终 1098 例不符（1091+2 同型 +5 单测 = 1098，说明是 design 未跟上新增用例）
- **建议**：`design.md` §3.1 改为「`internal class X86Depth` + `analyze(code, codeOff, codeLen, delta)`，增量由 `X86Lower` 探针遍采集」；§5 风险行改为「探针遍与发射遍同源，不会漂移；未识别指令 ⇒ 放弃 JIT」；§4.1③ 改为「`X86Depth_test` 五形态单测」；§4.3 数字改为终态实测值

### [一般][存量] 常量键规格写 `Float64 → f:<位模式>`，与本变更自己的修复结论（`i:<bits>`）相反

- **位置**：`f_jit/doc/spec/fix-f-jit-audit-defects/specs/f-jit-bytecode-format/spec.md:7`；对照 `tasks.md:57`（A5.1 括注）、`f_jit/src/bytecode/CanonKey.cj:45-58`、`:80-96`
- **来源**：存量
- **判据**：review-checklist §13「规格与实现漂移」；§2「字面量复制：同一张表散落多处」
- **证据**：静态确定 —— spec:7 把 `Float64 → f:<位模式>` 写成 SHALL；tasks A5.1 却记「**Float64 的真正根因**：常量表用 `f:<bits>`、运行期裸 cell 走 `i:<cell>` —— 值型键统一为 `CanonKey.cell`（Float64 常量键 ⇒ `i:<bits>`）」；`CanonKey.f64` 实现为 `return cell(bitsAsI64(bits))`（`CanonKey.cj:56-58`），其注释明写「若这里另立 `f:` 前缀，同一个 `Float64` 在裸 cell 与 Any 盒两条路径上会得到两个键，装箱键永远查不到常量条目」。Decimal 亦不同形：规格写 `d:<规范化文本>`，实现是 `d:<sign>|<scale>|<coeff 去尾零>`（`CanonKey.cj:96`）
- **描述**：规格条款复述的正是本变更判定为「P1-7 根因」的旧格式。任何按 spec:7 重写 `tokenOf` 的实现都会原样重现「`Map<Float64,…>` 常量键永不命中」，而按实现写的 `p1_7_canonKeyIsSingleSource` 会红——规格与自己的验收用例互相排斥。这也是「同一契约多副本」在本次唯一造成实质错误的一条
- **建议**：`spec.md:7` 改为「`Float64 → i:<位模式按补码重解释为 Int64>`（与裸 cell 同键，**不另立 `f:` 前缀**）」、`Decimal → d:<sign>|<scale>|<coefficient（去尾零）>`；并在小节里点明「值型键一律 `i:`」，避免下一个常量类型再分叉

### [一般][存量] `fix-f-jit-strictfp-deadline-x86` 勾选了 STACK_GUARD，同模块回归记录却写「本变更未做」，且其判据被次日变更推翻

- **位置**：`f_jit/doc/spec/fix-f-jit-strictfp-deadline-x86/tasks.md:17-18`（3.1 `[x]`「`case 0x74u8` 增 STACK_GUARD（`(rbp-frame)-rsp < frame ⇒ errCode=-1 + jmp epilogue`）」）、`design.md:38-62`（§2.2 汇编 `cmp rax, rdx; jge ok`，rdx = `frame`）、`specs/f-jit-backend/spec.md:31`（`(rbp - frameSize) - rsp < frameSize` ⇒ deopt）；对照 `f_jit/doc/spec/f-jit-m1/verify.md:245-247`（「**遗留（本变更未做）**：x86 `LOOP_BACK` 的 **STACK_GUARD** … 尚未补」）与 `:249-258`（第三轮 `align-x86-loop-back-stack-guard` 改按「溢出量 ≤ 操作数栈保留区 `8*(maxStack+1)`」用 `jbe` 放行）；实现 `f_jit/src/backend/X86Lower.cj:1019-1034`
- **来源**：存量
- **判据**：review-checklist §14.1「承诺了但没实现」、§13「规格与实现漂移」、§4（守卫判据反了会让每次正常回边都 deopt）
- **证据**：静态确定 —— 同模块 `verify.md` 明确把 STACK_GUARD 列为该变更未做项（只做了 H22），次日由 `align-x86-loop-back-stack-guard` 补齐；实现比较的是 `rbp - frameSize - rsp`（溢出量）与**保留区** `8*(maxStack+1)`，判据为 `jbe ok`（`X86Lower.cj:1026-1031`），注释写明「x86 帧是预分配的 ⇒ 正常路径 overflow == 8*depth <= 保留区，恒不 deopt」（`:1023-1025`）——与 spec:31 / design:49-50 的「阈值 = frameSize、`jge` 放行」方向相反
- **描述**：这是本部分最实质的一处记录失真。`tasks.md` 的勾选与 design 的汇编片段都表示「安全点已完整落地」，而当时的回归记录承认只做了 H22；更关键的是 design/spec 给出的守卫判据在 x86 预分配帧上会把**正常回边**判成溢出，从而每轮 deopt——次日的变更正是因为这点改成了「阈值 = 保留区 + `jbe`」。按归档 design 复刻这段代码会得到一个恒 deopt 的循环，这正是「文档把未验证的机制写成结论」的代价
- **建议**：`tasks.md:17-18` 拆成 3.1a（H22 已完成）与 3.1b（STACK_GUARD 移交 `align-x86-loop-back-stack-guard`，附原因「阈值须按保留区而非 frameSize」）；`design.md` §2.2 汇编与 `spec.md:31` 的判据按次轮更正后的口径回写，并注明「首轮按 frameSize 比较是错的，会恒 deopt」

### [轻微][存量] 同一变更里新增调用入口有两个名字：`proposal.md` 写 `call<T>(args, options)` 与 `tryInvoke`，`design/spec/tasks/verify` 写 `invoke<T>` 且明令「SHALL NOT 引入 tryInvoke」

- **位置**：`f_jit/doc/spec/fix-f-jit-audit-defects/proposal.md:21`（「新增 `JitFunction.call<T>(args, options: CallContext)`」）、`:38`（「`invoke/tryInvoke` 与 deadline 接线」）、`:46`（Impact「新增 `JitFunction.call<T>(args: Array<Any>, options: CallContext)`」）；对照 `design.md:26`（P0-6 修法「新增 `invoke<T>(args, options)`（**不引入 `tryInvoke`**）」）、`design.md:81`（D3 同结论）、`specs/f-jit-facade-bridge/spec.md:113`（`SHALL NOT 引入 tryInvoke`）、`tasks.md:40-41`、`verify.md:31`
- **来源**：存量
- **判据**：review-checklist §13「文档自相矛盾」、§10「契约与实现不符」
- **证据**：静态确定 —— 同一份变更的 proposal 与 design/spec 对「新增几个入口、叫什么」给出相反答案；当前代码只有重载形态 `public func call<T>(args: Array<Any>, options: CallContext)`（`f_jit/src/JitFunction.cj:159`），且 `f_jit/src/base/JitValue.cj:25` 注释「原 `invoke` / `tryInvoke` 已并入同名重载」可证 `invoke` 已不存在
- **描述**：最终形态与 proposal 一致、与 design/spec/tasks/verify 相反，说明「proposal 里的两种写法（`call` 重载、`tryInvoke`）当时被当成笔误忽略，真正实施的是 `invoke`，随后又被并入 `call`」。归档记录因此留下三处失效引用：`tasks.md:41` 的 `a3_4_invokeMatchesCall`、`tasks.md:42` 的 `a3_5_strictFpDoesNotChangeFdivChk` 在仓内均不存在（现名 `a3_4_callOverloadsAgree`、`a3_5_bridgeKeepsDivisionSemantics`，见 `f_jit/src/AnyBridgeCall_test.cj`）。按编号检索验收证据的人会在这一步断掉
- **建议**：在 `design.md` D3 与 `spec.md:113` 加一行「后续变更将 `invoke` 并入 `call` 重载（见 `align-call-entry-spec`），本条保留原裁定」，并把 proposal 的 `tryInvoke` 一句改为「不引入独立入口」；`tasks.md` / `verify.md` 的旧用例名保留但加「现名」括注

### [轻微][存量] `verify.md` 的归档与主规格结论在当前工作区不可复核（归档路径、9 个 capability、镜像 diff 一致三项均无对应物）

- **位置**：`f_jit/doc/spec/fix-f-jit-audit-defects/verify.md:69-72`（归档路径 `openspec/changes/archive/2026-10-21-fix-f-jit-audit-defects/`、`openspec list` 无活动变更、主规格 9 个 capability、镜像逐文件 `diff` 一致）、`:74-88`（`validate --all --strict` 4 passed / 5 failed 的既有债务表）
- **来源**：存量
- **判据**：review-checklist §13「链接 / 路径失效」
- **证据**：待确认 —— 当前 `openspec/changes/archive/` 仅有 5 个 2026-11-20 的目录（`fix-dataassist-local-mode` 等），`openspec/specs/` 仅有 `data-assist-compare` / `jwt-signature` / `orm-result-type-mapping` / `uring-async-io` / `data-assist-supertypes` 五个，无任何 `f-jit-*`；`git log --all -- "openspec/changes/archive/2026-10-21-fix-f-jit-audit-defects"` 与 `-- "openspec/specs/f-jit-backend"` 均为空。缺的信息：`verify.md:15` 提到「复现命令（融合侧）」，若该归档落在另一套工作树/分支，需要写明路径
- **描述**：本变更最有力的两条结论（「18 条 delta 全量落地」「镜像与归档逐文件一致」）依赖一个本仓不存在的目录树。若它确实在「融合侧」工作树，则本仓的 `f_jit/doc/spec/` 只是单向镜像，「diff 一致」这句话在本仓永远无法验证；若归档曾在本仓而后被清理，则 §74-88 的 lint 债务表也失去对照锚点。两种情况下读者都会卡在同一处
- **建议**：在该段补一句来源路径（「归档位于融合侧仓库 `<path>`，本仓仅保留镜像」），或把结论改为「本仓镜像自洽；openspec 归档见外部工作树」；若本仓 `openspec/` 已重新初始化（当前 `openspec/changes/` 只有 `add-f-a2a`），建议在 `f_jit/doc/spec/README` 级别说明「本目录为历史归档镜像，不再与 `openspec/specs` 对应」

### [轻微][存量] proposal 未登记 A2 实施中的附带修复（默认产物 `verMajor` M2 → M3）

- **位置**：`f_jit/doc/spec/fix-f-jit-audit-defects/proposal.md:45-48`（Impact / 格式与兼容）；记录在 `design.md:134-137`、`tasks.md:24-26`
- **来源**：存量
- **判据**：review-checklist §13「变更说明与实施不一致」；§14.1「接线缺失——能力变化未进变更说明」
- **证据**：静态确定 —— design 的「A2 实施中新增的必要修复」与 tasks 的「本批附带修复」都写明 `CompilePipeline.runSource` 的 `verMajor` 由 `M2_MAJOR` 改为 `M3_MAJOR`（此前公开 `Compiler.compile` 完全编不了 `Any`，报「局部槽类型码非法: 15」）；proposal 的 What Changes 与 Impact 全篇未提，且 Impact 仍写「`.fbc` verMajor 1/2/3 及规则集校验**零变化**」
- **描述**：这是本变更里唯一改变「公开入口默认产出什么版本产物」的行为——格式没变，但同一源码产出的 `verMajor` 从 2 变 3。下游按 proposal 评估兼容性时会漏掉这一项；按 tasks/design 才知道「加载器要能吃 3」。记录分散在设计与任务里，恰好是 proposal（对外变更说明）最该写的地方
- **建议**：proposal Impact 增一行「默认产物 verMajor：2 → 3（`.fbc` 结构不变；消费方需支持 3）」，或在 What Changes 里把该附带修复单列

<!-- 第 14 部分 -->

### [一般][存量] #1 D3（`!` 按类型分派）未回写到「不做的事」与「兼容性」结论，文档说「字节码不变」，实现改了字节码

- **位置**：
  - `f_jit/doc/spec/fix-jit-unary-not/proposal.md:25`（「**不改**：Parser / Lexer / Lowerer 的既有行为（已证伪，见 design §2.2）」）
  - `f_jit/doc/spec/fix-jit-unary-not/proposal.md:44`（「同一源单元前后只差 `NOT_B` 的 4 个机器字节；字节码、verMajor、规则集、helper 编号、缓存键全部不变」）
  - `f_jit/doc/spec/fix-jit-unary-not/design.md:110-111`（§3.4「不做的事：不改 `Lowerer`、`Parser`、`Lexer`、`Interp`（已证伪）」）
  - `f_jit/doc/spec/fix-jit-unary-not/design.md:169-171`（影响表「`.fbc` / 规则集 / 缓存键 | 不变（只改机器码生成）」）
  - `f_jit/doc/spec/fix-jit-unary-not/specs/f-jit-compiler-frontend/spec.md:7`（「前端对 `!operand` SHALL 产出……+ 单条 `NOT_B`」）
- **来源**：存量（快照；`git blame`：这些行均为 `d71346a21` 初版，D3 修订 `ca05c75c5` 只改了 proposal:20 / design §3.3 / spec:21-24，未覆盖上述五行）
- **判据**：review-checklist §13「文档承诺与实现相反 / 规格与实现漂移」、§14.1「承诺与实现不一致」
- **证据**：静态确定 — 实现 `f_jit/src/compiler/Lowerer.cj:1727-1740` 已按 `LocalType` 分派：`BOOL → NOT_B`、`I64 → BNOT_I`、其余 `diagFail(TYPE_MISMATCH)`。于是 `{ n: Int64 => !n }` 的字节码由 `NOT_B` 变为 `BNOT_I`（D3 自己的要求），`{ s: String => !s }` 由「能编译」变为编译期报错；两者都与 proposal:44 / design:169-171 的「字节码不变」「只改机器码生成」直接矛盾，也与 proposal:25 / design:111 的「不改 Lowerer」矛盾（同文 design:94-107 的 D3 又明确要改）。`spec.md:7` 的 SHALL 是全称的，而同一文件 21-24 行自证 Int64 走 `BNOT_I`。
- **描述**：这不是措辞洁癖：后续审计若引用「同一源单元只差 4 个机器字节」，`BNOT_I` 分支的差分/形状回归会被判为「无需覆盖」；按 `spec.md:7` 验收则会把正确的 `BNOT_I` 判成违规。缓存层面本身安全——`CompileCacheKey`（`src/backend/CompileCacheKey.cj:21-46`）以 `(arch, cpuFeatures, bytecodeFingerprint)` 为键且仅驻内存，字节码变了键自动变——但文档给出的理由（「字节码不变」）是错的，正确理由没写。
- **建议**：proposal:25 与 design:111 改为「不改 Parser / Lexer / Interp；`Lowerer` 仅改 `Bang` 分支（D3）」；proposal:44 与 design:169-171 改为「Bool 分支只差 `NOT_B` 的 4 个机器字节；Int64 分支字节码由 `NOT_B` 改为 `BNOT_I`，非法类型改为编译期 `TYPE_MISMATCH`；缓存键随字节码指纹自动变化」；`spec.md:7` 的 SHALL 收窄为「BOOL 操作数产出单条 `NOT_B`」或改述为「按类型分派后恰好一条取反指令」。

### [一般][存量] #2 `f-jit-compiler-frontend` 的 spec delta 有一个空 scenario：`!~` 的验收项被「类型分派形状」截断

- **位置**：`f_jit/doc/spec/fix-jit-unary-not/specs/f-jit-compiler-frontend/spec.md:19-27`（19 行标题「正则取反同样单条」后直接是 21 行「类型分派形状」；属于正则的 26-27 行 `WHEN 编译 re !~ s` / `THEN … 恰好一条 NOT_B` 落在「类型分派形状」名下）
- **来源**：存量（快照；标题与正文为 `d71346a21`，`ca05c75c5` 在两者之间插入新 scenario 造成错位）
- **判据**：review-checklist §13「验收口径不可执行」、§14.1「只做了一半的分支」
- **证据**：静态确定 — 按 `#### Scenario:` 标题切分时，19 行标题与下一个标题（21）之间没有任何正文，构成空 scenario；26-27 的正文追加在已有自己 WHEN/THEN（23-24）的「类型分派形状」之后，同一 scenario 出现两组 WHEN/THEN。`tasks.md:51`（N5.2）声称「三个 capability 的 delta 全量落地」。
- **描述**：`re !~ s` 追加恰好一条 `NOT_B` 这条验收在契约层是悬空的：实现侧（`Lowerer.cj:3049-3056`）与用例 `bytecodeShapeOfRegexNegation` 都有，缺的只是 spec 表述；逐 scenario 核对或做严格校验时会读到一个空场景。
- **建议**：把 26-27 两行移回 19 行标题之后，「类型分派形状」只保留 23-24；顺手对三份 delta 各跑一次 `openspec validate --strict`，避免「归档即通过」。

### [轻微][存量] #3 `fix-handle-gen-exhaustion` 任务书把旧实现失败形态写成「负 ID」，与同批 verify 的 `OverflowException` 矛盾

- **位置**：`f_jit/doc/spec/fix-handle-gen-exhaustion/tasks.md:7-9`（G1.1「旧实现第 32768 轮返回负 ID ⇒ `id > 0` 断言失败」）；对照 `f_jit/doc/spec/fix-handle-gen-exhaustion/verify.md:13-22`（Red 实测为 `OverflowException`）、`design.md:9-10`（「`Int64(u)` 是受检转换，直接抛 `OverflowException`；若换成非受检位转换则会得到负 ID」）
- **来源**：存量（`55ddaca48` 一次写入，verify 回填时未回改任务书）
- **判据**：review-checklist §13「规格与实现漂移」、§11「证据与结论不符」
- **证据**：静态确定 — verify 的 Red 原始输出是 `OverflowException: The result would be greater than Int64.Max`，栈落 `HandleTable.makeId`；负 ID 只存在于「非受检位转换」这个假想分支，且 design:9-10 与 proposal:8-9 都把它写作备选路径。
- **描述**：按任务书复跑的人会等不到「负 ID」，或误以为 Red 用例没命中溢出点；`id > 0` 的断言红实际以异常（ERROR）形式出现，统计口径也不同。
- **建议**：`tasks.md:8` 改为「旧实现抛 `OverflowException`（受检转换，ERROR 而非断言红）；若改非受检位转换则得到负 ID」，并把 G1.1 的「确认是断言红」改为「确认命中 `makeId`」。

### [轻微][存量] #4 `x86-verification.md` 的预期总数与任务闭合数与产物不符（1163 vs 1171、24/24 vs 任务书 23/24）

- **位置**：`f_jit/doc/spec/fix-jit-unary-not/x86-verification.md:40`（「`cjpm test` 全量 `1163 passed / 0 failed`」）、同文件 `:64`（「`fix-jit-unary-not` 的 24/24 任务闭合」）；对照 `verify.md:91-92`（x86 实测 `TOTAL 1171`）、`tasks.md:52`（`- [ ] N5.3 合并`）
- **来源**：存量（快照；`aae68ebe9` 回填 x86 证据时只改了头部，未同步预期表与任务书）
- **判据**：review-checklist §13「同一变更内两份文档结论相反 / 文档过期」
- **证据**：静态确定 — 同文件 6-7 行的头部已回填「全量 1171 首跑全绿」，与 40 行预期表自相矛盾；`tasks.md:52` 仍未勾选，但 `git log -1 f5498e554` = `2026-10-31 15:26:37 merge: 合入 fix-jit-unary-not`，`git branch --contains f5498e55` 含 `master`/`sts/1.3.x`，`git merge-base --is-ancestor f5498e554 HEAD` 为真（归档 15:18 早于合并，N3.4 回填 16:39 晚于合并）。
- **描述**：x86 与 AArch64 用例数不同本身正常（条件编译），错在把 AArch64 的 1163 写成 x86 的预期判据；「24/24」与任务书的一处未勾选并存，会让接手人误判变更状态——实际合并已完成，是任务书漏勾，不是未完成。
- **建议**：40 行改为「与 AArch64 侧同量级（实测 1171，差异见 verify §4）」；勾选 N5.3 并注明「由 `f5498e554` 完成」（或保留未勾选但补一句「合并已由该提交完成」）。

### [轻微][存量] #5 `design.md` §4.2 的期望值笔误未回写，verify 的「两处笔误」只有一处可定位

- **位置**：`f_jit/doc/spec/fix-jit-unary-not/design.md:132`（比较族 `!(n != 5)` 在 `n = 5` 期望 `0`）；对照 `verify.md:155-157`
- **来源**：存量（`d71346a21` 写入 design；`bf8d7bc31` 在 verify 中记录订正，未回改 design）
- **判据**：review-checklist §13「规格与验收口径不一致」
- **证据**：静态确定 — `5 != 5` 为假，取反得 `1`，不是 `0`；verify:155 承认「`!(!=)` 在 `n = 5` 上取反得 `1` 而非表中 `0`」。但 verify 同时声称第二处是 `!(a || b)` 在 `(true,false)` 期望 `1`，而 `design.md:135` 只有「各类 / 与 `&&`/`||` 真值取反一致」的定性描述、**没有**数值行 —— 该第二处**待确认**（可能镜像与 openspec 侧文本不同，或缺原始表）。
- **描述**：错误期望值会被下一个写用例的人抄走，制造「按规格写、按语义红」的假失败；verify 已知道却只改用例不改规格，订正链在归档时断开。
- **建议**：`design.md:132` 改为 `0 / 0 / 1`；核对 `openspec/changes/archive/**/fix-jit-unary-not` 与镜像是否同源，若第二处笔误只存在于 openspec 侧则同步回写，否则删掉 verify 中无法定位的半句。

### [轻微][存量] #6 `NOT_B` 的「三引擎逐位一致」承诺缺前置不变量：等价只在 `{0,1}` 域成立，spec 未写明

- **位置**：`f_jit/doc/spec/fix-jit-unary-not/specs/f-jit-backend/spec.md:7`（「两侧 SHALL 只翻转 bit0」）、`:29-31`（「三引擎 SHALL 对同一源码给出逐位一致的结果」）；对照 `design.md:81`（「在 `{0,1}` 域上完全等价」）、`design.md:87-89`（D2 否决理由：「x86 侧不同构（`xor 1` 只在 `{0,1}` 域等价）」）
- **来源**：存量（快照）
- **判据**：review-checklist §14.1「契约前置条件缺失」、§13「规格与实现漂移」
- **证据**：静态确定 — 解释器 `Interp.cj:533` 为 `a == 0 ? 1 : 0`，A64 `A64Lower.cj:326-329` 为 `eor #1`、x86 `X86Lower.cj:975` 为 `xor qword [rsp],1`；若 Bool cell 非规范 0/1（如 2），解释器给 `0`、两后端给 `3`，桥按 `cell != 0` 解包即 `false` vs `true`。当前所有 Bool 生产者（比较 `cset`、`PUSH_BOOL`、host 参数解包）都产 0/1，故现在不可达。
- **描述**：契约比实现强。将来任何非规范 Bool 来源（新 helper 直接回写宿主返回值、常量池伪造 Bool 常量、优化把 `!=0` 折叠成原值）都会让 `!` 静默分歧，而 spec 里没有能拦住它的条款。
- **建议**：在该 requirement 补一句「Bool cell SHALL 规范化为 0/1；`NOT_B` 的三引擎等价以该不变量为前提」；若要彻底摆脱前提，按 design §3.2 / D2 改 `cmp + cset eq`（需同时改 x86 与 Interp 契约，另立变更）。

### [轻微][存量] #7 native-assets 的护栏声称「旧实现必须红」，并发丢增量并不能保证每次复现

- **位置**：`f_jit/doc/spec/fix-native-assets-atomic/proposal.md:31`（「护栏在旧实现上必须**红**（并发增量丢失）」）、`tasks.md:4`（T1.2「必须 FAILED」）、`verify.md:13-25`（仅一次 `left: 396 / right: 400`）
- **来源**：存量（`e785109e7d` 一次写入）
- **判据**：review-checklist §11（并发验证证据）/ §12.1（数据竞争的可观测性）
- **证据**：需实测 — `allocs = allocs + 1` 的丢增量依赖调度与核数；在单核、低竞争或编译器把读改写优化成单条指令的宿主上，同一用例完全可能得到 400，护栏漏报。
- **描述**：护栏是本次变更唯一的并发证据来源；若它在错误实现上可能通过，回归价值就取决于环境，「改前红」不再成立。变更本身的 `AtomicInt64` 修法正确（`NativeAssets.cj:35-54`），风险仅在证据强度。
- **建议**：改成多轮（如 ≥50 轮统计失败率）或做变异验证（临时换回普通 `Int64` 跑 N 轮），verify 记录「旧实现 N 轮中 M 轮失败」；也可用可控屏障放大竞争窗口。

<!-- 第 15 部分 -->

### [严重][存量] 关闭状态机缺「卸载者仲裁」：排空判定与置终态分处两个临界区，并发 `close()` 的回退可让新调用在已释放的机器码上继续执行

- **位置**：
  - 单元路径 `f_jit/src/JitFunction.cj:227-286`：`:231-236` 置 `state=1`（只判 `==2`）、`:237-253` 自旋排空、`:246-251` 超时回退置 `state=0`、`:254-286` 置终态 + 级联 + 取 `release`；
  - 闭包路径 `f_jit/src/JitFunction.cj:302-333`：`:303-308` 置 `e.state=1`、`:311-326` 排空、`:318-323` 回退置 `e.state=0`、`:327-331` 置 `e.state=2` 并 `releaseAll()`；
  - 放行侧 `f_jit/src/JitFunction.cj:198-206`（`enterUnit`）、`:336-349`（`enterClosure`）
  - 承诺源：`f_jit/doc/spec/jit-closure-unload-cascade/design.md:88-113`（D5「卸载中 → 排空 → 已释放」）、`:152-159`（§5「同一闭包：调用 vs 释放」「锁序：全流程只有单元 `mtx` 一把锁，无嵌套」）、`specs/f-jit-facade-bridge/spec.md:39`（「释放 SHALL 先排空该闭包自身的在飞调用再归还提升组」）、`:63`（「超时回退路径 SHALL NOT 释放任何闭包」）
- **来源**：存量（快照模式无 diff）
- **判据**：review-checklist §12.1「检查-然后-写入」「可见性」、§11「并发正确性：检查后写入非原子」；严重度表「数据竞争 / 死锁 / 同步缺失」
- **证据**：静态确定 —— `state` 只是共享标记，没有「本次卸载者」身份；任一 `close()` 都能把 `state` 复位成 `0`（`:247-249`、`:320-322`），而「观测 `active==0`」(`:240-242`、`:312-314`) 与「置终态」(`:256-277`、`:327-330`) 是两个独立临界区，中间**不复检** `active`/`e.active`
- **描述**：可构造的交错（单元路径）：
  1. 线程 A `close(t)`：`:235` 置 `state=1`，进入排空循环；
  2. 线程 B `close(0)`：`:232` 见 `state!=2` ⇒ `:235` 再次置 `state=1`；`limit=0` ⇒ `:246-250` 把 `state` 回退成 `0` 并返回 `false`；
  3. 线程 C 此刻 `call()`：`enterUnit`（`:200`）见 `state==0` ⇒ `active+1` 开始执行；
  4. 线程 A 在「已读过 `active==0`、尚未进入 `:256`」的窗口内恢复执行：`:257` 置 `state=2`，`:275-276` 取出 `release`，`:282-285` 调用它。
  `release` 即 `JitExecutor.release()`（`CompilePipeline.cj:255-258` → `JitExecutor.cj:185-193`），会 `table.free()` / `mirror.free()` / `buf.free()` —— **释放 C 正在执行的机器码**。闭包路径同理，`:331` 的 `releaseAll()` 会归还 C 正在读的句柄槽。规格 §5 声称「置 `state=1` 后新调用一律 19」，但回退无条件复位使该保证失效；`UnloadConcurrency_test` 只覆盖「单卸载者 + 在飞调用」，没有「两个并发 `close()` + 一次回退」的用例（`src/UnloadConcurrency_test.cj:45-90`、`:91-111`）
- **建议**：给卸载加**仲裁**而非仅状态位：进入时以令牌/代际（`closerId`、`epoch`）认领卸载权，第二个并发 `close()` 直接返回 `false` 或等待前者结论；回退只允许令牌持有者复位。更稳的做法是把「复检 `active==0` + 置终态 + 取 `release`」合成**同一个** `synchronized` 块（置终态时 `active!=0` 即回退），锁外只做真正的 `releaseAll()`/`release()`。补 ≥4 线程、每线程 ≥1k 次 `close` 与一次超时回退的压力用例，断言「终态后无在飞调用、无 `isJitBacked()` 单元被释放后又执行」

### [一般][存量] `timeoutMs` 用「自旋次数 × 100000」冒充毫秒：函数内无任何时钟，等待既可能提前也可能迟到，且纯自旋与在飞调用抢同一把锁

- **位置**：`f_jit/src/JitFunction.cj:238`（`let limit = if (timeoutMs <= 0) { 0 } else { timeoutMs * 100000 }`）、`:309-310`（同构）
- **来源**：存量（快照）
- **判据**：review-checklist §11「契约与实现不符」、§6.3「高竞争自旋」、§12.2（自旋抢锁）；承诺源 `f_jit/doc/spec/jit-closure-unload-cascade/specs/f-jit-facade-bridge/spec.md:39`（「`timeoutMs` 内未排空 SHALL 回退为可用并返回 `false`」）、`design.md:100-103`
- **证据**：静态确定 —— `close`/`unloadClosure` 内无 `MonoTime`/`DateTime`/`sleep` 调用，只有 `spins = spins + 1` 与整数比较；`100000` 与「毫秒」无换算依据（A64 侧的审计注释给的是另一种量级）。具体偏差幅度需实测（见待验证假设 #3）
- **描述**：三点后果：
  1. **提前超时**：无竞争时一次取锁约数十至数百纳秒，`1 ms` 只够约 10⁴ 次迭代，`close(1000)` 可能在十几毫秒内就返回 `false`，按「等 1 秒」写的重试逻辑全部落空；
  2. **迟到超时**：竞争激烈时单次取锁可达微秒级，`timeoutMs=10000`（`UnloadConcurrency_test.cj:67` 的真实用法）意味着上限 10⁹ 次取锁，实际可能以分钟计；
  3. **溢出**：`timeoutMs > 9.2e13` 时 `*100000` 溢出为负 ⇒ `spins >= limit` 首轮即真，超长等待参数变成立刻失败。
  另外排空每轮都要 `synchronized(this.mtx)`，而在飞调用收尾（`exitUnit`/`exitClosure`）也需要这把锁，自旋持续抢占会拉长被等待者的收尾时间；`CompileCache.awaitReady` 已因同类问题从「每轮取全局锁」改成指数退避（`src/CompileCache.cj:124-127` 注释），本处未同步
- **建议**：改为基于时钟的截止时间（进入前取 `now() + timeoutMs`，每轮比较），等待期间让出而非满速自旋；`timeoutMs` 先做上限判定或饱和运算。修改后补计时用例（`close(0)` 立即返回、`close(50)` 落在 40–60 ms），否则同类偏差无法回归

### [一般][存量] `Resource.close(): Unit` 丢弃 `close(0)` 的 `Bool`：有在飞调用时静默不释放，`try (f) {}` 的调用方无从得知

- **位置**：`f_jit/src/JitFunction.cj:523-525`（`public func close(): Unit { let _ = this.close(0) }`；`JitFunction <: Resource` 见 `:59`）
- **来源**：存量（快照）
- **判据**：review-checklist §3（返回值被丢弃）、§11「错误处理缺失或静默」；承诺源 `jit-closure-unload-cascade/specs/f-jit-facade-bridge/spec.md:39`（`false` 表示「未释放」）、`:63`（级联只在进入终态时发生）
- **证据**：静态确定 —— `close(0)` 在 `active>0` 时按 `:238`/`:246-251` 必然走立即回退分支并返回 `false`，而 `let _ =` 把它丢掉
- **描述**：`Resource.close()` 是 `try (res = f) { ... }` 唯一能自动调用的入口。并发调用存在时，自动关闭既不置终态、不级联释放逃逸闭包、也不逐出编译缓存，但调用方拿到 `Unit`。注释已写明「不等待在飞调用（等价 `close(0)`，丢弃排空结果）」，即这是有意为之；但与 `Resource` 的「释放资源」契约相反，后果是句柄/提升组继续驻留、缓存继续命中一个本应死亡的单元
- **建议**：在 `close(): Unit` 内对 `false` 做可观测处理（`f_log` 一条 `warn`，带单元 id/在飞计数），或额外提供 `tryClose(): Bool` 供显式路径使用；README 的释放协议段补一句「`try` 自动关闭不等待在飞调用，生产代码应显式 `close(timeoutMs)` 并检查返回值」

### [一般][存量] G5 规格写「记录**每条**内存访问的基址」，实现是抽样：`CALL_CLOSURE` 的 4 条访存（含 H57 返回的 `fnTable` 基址）与 A64 的 `ldrD/strD/ldrReg` 完全不登记

- **位置**：
  - 规格 `f_jit/doc/spec/harden-f-jit-object-lifetime/specs/f-jit-backend/spec.md:32-39`（「降低期 SHALL 记录每条内存访问的基址寄存器」）、`design.md:31-38`（采集点清单，只列 8 个 x86 发射器与 `A64Emitter.ldrOff/strOff`）
  - x86 实现 `f_jit/src/backend/X86Lower.cj:633-661`：`:645` `mov [rbp-16],rax`、`:655` `mov [rbp-24],rax`、`:657-659` `mov rax,[rbp-16]; mov rcx,[rbp-24]; rax=[rcx+rax*8]` 都是裸字节发射，无 `noteMemBase`/`noteAbsMem`（对照 `:452` 的 `callFunc` 有 `noteAbsMem()`、`:793` 的 `PUSH_KH` 有 `noteAbsMem()`）
  - a64 实现 `f_jit/src/backend/A64Emitter.cj:543-549`（`ldrD`/`strD` 不 `note`）、`:638-640`（`ldrReg` 不 `note`）；使用点 `f_jit/src/backend/A64Lower.cj:670`（`ldrReg(10, 12, 9)`，基址 `x12` 来自 H57）
  - 允许集表述冲突：`harden-f-jit-object-lifetime/.../spec.md:36-39` 规定「x86 基址 ∈ {rsp,rbp,r15}，集合外一律放弃 JIT」；`harden-x86-audit-and-futil-tests/.../spec.md:10-24` 以 **ADDED**（而非 MODIFIED）形式追加「哨兵 `-1` 视为合规」
- **来源**：存量（快照）
- **判据**：review-checklist §13「规格与实现漂移」、§11「契约与实现不符」、§14.1「只做了一半的分支」；§2「字面量复制导致行为漂移」（同一允许集在 4 份文档各写一遍）
- **证据**：静态确定 —— `auditAllows([])` 为真（`src/backend/EmitAudit_test.cj:37` 断言），因此**未登记即视为合规**；`callClosure:657-659` 的解引用基址是 `rcx`（H57 返回值），不在 `{4,5,15,-1}`，若补登记会直接判违规。`X86Lower.lower` 只在结束时对快照做一次 `auditAllows`（`:150-154`），抽样漏项不会被发现
- **描述**：G5 的威胁模型原文是「机器码不得把 helper 返回的 `cell` 当指针解引用」，而 `CALL_CLOSURE` 恰恰是「H57 返回 `fnTable` → 寄存器偏移解引用」——它没走任何登记点，所以审计对它恒为真。`harden-x86-audit-and-futil-tests` 专门为 `CALL_FUNC`/`PUSH_KH` 补过同类缺口，却漏了 `CALL_CLOSURE`；A64 的浮点访存与 `ldrReg` 同理。两份 delta 对允许集的表述也互相否定（前者「集合外一律拒绝」，后者接受 `-1`），因为后者用了 ADDED 而非 MODIFIED。审计只在降低期生效、不影响产物，所以不是生产缺陷；但文档给出的结论「审计通过 ⇒ 机器码只碰受控基址」目前是**抽样结论**，不是全覆盖
- **建议**：二选一并写进规格——(a) 补全采集：`callClosure` 的 `fnTable` 解引用按 `noteAbsMem()`（或新增「表基址」类别，语义比「绝对地址」准确）登记，`:645`/`:655`/`:657-658` 补 `noteMemBase(5)`，`A64Emitter.ldrD/strD/ldrReg` 补 `noteMemBase`；(b) 把 Requirement 改成可执行口径「采集点 = `{movQwordCtx, movRaxMemRsp, leaRdxRsp, pushMemRsp, moveRaxToMemRsp, ucomisdRM, pushMemRbp, popMemRbp}` + 显式绝对地址，其余路径不采集」。同时把允许集的追加改成 MODIFIED 条款，避免两份规格字面冲突。选 (a) 需先跑 `JitBacked_test`/`X86Lower_test`，确认补登记后没有整单元回退

### [轻微][存量] `jit-closure-unload-cascade/proposal.md` 的生命周期结论与同变更 design/实现相反：单元**不**强引用包装实例，却被写成「持强引用」

- **位置**：`f_jit/doc/spec/jit-closure-unload-cascade/proposal.md:33`（「单元对登记在册的包装实例持强引用，直到该闭包被释放或单元卸载」）；对照 `design.md:35`（「条目只引用组与计数，不引用包装实例 ⇒ 单元不再强引用包装对象」）、`design.md:166-168`（§6 差异表「单元 → 包装强引用：上一版有 / 本版无」）；实现 `f_jit/src/JitFunction.cj:106`（`private let escaped = ArrayList<EscapedClosure>()`）、`f_jit/src/EscapedClosure.cj:29-42`（只有 `seq`/`group`/`state`/`active`）
- **来源**：存量（快照）
- **判据**：review-checklist §13「同一变更内文档自相矛盾」、§11「语义与注释不符」；本条直接关系 f_jit 专项「句柄与资源生命周期」
- **证据**：静态确定 —— 三处文本与实现的字段集合互斥：proposal 说单元钉住包装对象，design 与代码都表明只钉住提升组
- **描述**：B3 修复的目的就是「宿主丢弃包装后包装对象可被 GC」，proposal 的 Impact 段却把被修复的旧行为当作结果写出来。只读 proposal 的调用方会误以为包装实例不会被回收，从而错误评估内存驻留
- **建议**：把该句改为「单元持有的是条目（组 + 计数），**不**引用包装实例；包装对象随宿主引用消失可回收，提升组按契约驻留到闭包释放或单元卸载」

### [轻微][存量] `harden-f-jit-object-lifetime` 同一变更内对 G1 的定性相反：proposal/design 称「真缺陷、每次泄漏 1 槽」，tasks/verify 称「RED 不可得、防御性加固」

- **位置**：`f_jit/doc/spec/harden-f-jit-object-lifetime/proposal.md:9`（表格「**G1** … **真缺陷**」）、`design.md:5-15`（「每次契约失败泄漏 1 槽」）；对照同变更 `tasks.md:7-8`（「**RED 不可得**（unbox 前的静态契约检查先拦下 ⇒ 泄漏路径不可达……该用例保留为回归护栏）」）与 `f_jit/doc/spec/f-jit-m1/verify.md:265`（「RED 不可得……本条属**防御性加固**，用例修前修后皆绿」）
- **来源**：存量（快照）
- **判据**：review-checklist §13「同一变更内文档自相矛盾」、§11「语义与注释不符」
- **证据**：静态确定 —— 实现先按 `T` 与 `retType` 定 `unboxCode`（`f_jit/src/JitFunction.cj:578`，静态契约检查之后），再做解包（`:649-654`）；`try/catch` 只覆盖 `unboxRet` 自身抛错的残余分支，与「声明类型不符即泄漏」不是同一条路径
- **描述**：读者若只看 proposal/design，会以为这是已复现的泄漏并按高优先级排期；tasks/verify 说明它只是防御性加固。归档文档按「当时结论是否自洽」核对，此处不自洽
- **建议**：proposal/design 补一句「静态契约检查已拦下声明不符路径；本修复覆盖 `unboxRet` 因无效句柄抛出的残余分支，RED 构造不出来」；或把 G1 从「真缺陷」降为「加固项」，与 tasks/verify 统一

### [轻微][存量] `fix-x86-audit-isolation` 把 aarch64 现状写成 ThreadLocal，实际是实例字段；`A64Emitter` 内还留着互斥的旧注释

- **位置**：`f_jit/doc/spec/fix-x86-audit-isolation/proposal.md:16-17`（「A64 侧……已经修过同一个缺陷（改 `ThreadLocal`）」）、`:33`（「与 A64 侧同一设计（每内存操作一次 TLS get）」）、`verify.md:28-30`、`:48-50`（「与 aarch64 侧长期使用的设计一致……该成本低于本机测量分辨率」）；对照 `f_jit/src/backend/A64Emitter.cj:456-458`（「用**实例字段**而不是 ThreadLocal……ThreadLocal 只是把成本摊到每次内存操作上（实测 598 次/编译，约 180 µs）」）、`:463`（`private let audit`）、`:452`（「放在 ThreadLocal 里零锁、零共享」旧注释）
- **来源**：存量（快照）
- **判据**：review-checklist §13「文档过期 / 与实现不符」；本条是选型依据，依据错则结论适用性存疑
- **证据**：静态确定 —— 文档与 `A64Emitter.cj:456-458` 直接对立；`grep ThreadLocal src/backend/A64Emitter.cj` 只命中注释，无字段
- **描述**：x86 选 `ThreadLocal` 的理由是「与 A64 同一设计、A64 实测无显著成本」，但 A64 现行实现是实例字段，且其注释明确说 ThreadLocal 因每访存一次 TLS `get`（598 次/编译、约 180 µs）被放弃。这不影响 x86 修复本身的正确性（`BackendSelector.cj:258-268` 的线程隔离有 `X86AuditIsolation_test` 佐证），但论证不成立；后续若照此把 A64 回改成 ThreadLocal 会白付 180 µs/编译。`A64Emitter.cj:452` 的旧注释与 `:456-458` 并存，读者无法判断哪个是现状
- **建议**：proposal/verify 改为「A64 用实例字段（生命周期 = 一次 `compileOnce`）；x86 的发射助手是静态函数且 `EmitAudit_test` 依赖静态 API，只能用 ThreadLocal，代价为每访存一次 TLS `get`，本机未测出显著差异」；同时删掉 `A64Emitter.cj:452` 的「放在 ThreadLocal 里零锁、零共享」

### [轻微][存量] `harden-x86-audit-and-futil-tests/design.md` 用不存在的行号作为「方言支持 `recursive`」的证据

- **位置**：`f_jit/doc/spec/harden-x86-audit-and-futil-tests/design.md:49`（「方言**支持** `recursive`（`Lowerer.cj:805/2492/2542/3242`）」）
- **来源**：存量（快照）
- **判据**：review-checklist §13「关键证据失准」；该条正是文档自我纠正「检索漏 `-Recurse`」后的**订正结论**，证据本身却不可复核
- **证据**：静态确定 —— `grep -n "recursive" f_jit/src/compiler/Lowerer.cj` 只命中 `:804`（文档注释），`:2492/:2542/:3242` 与 `recursive` 无关（文件共 3923 行）。真实支持点：`f_jit/src/compiler/Lexer.cj:310`（`case 'recursive'`）、`PredefinedSnapshot.cj:146`（`if (name == 'recursive')`）、`Lowerer.cj:804`（尾位置 `recursive(args)` 降低）
- **描述**：结论（支持 `recursive`）正确且有 `JitBacked_test.recursiveUnitStaysJitBacked`（`src/JitBacked_test.cj:51-59`）佐证，但引用的 4 个行号有 3 个不存在、第 1 个也不是代码实现点
- **建议**：改为 `Lexer.cj:310` / `PredefinedSnapshot.cj:146` / `Lowerer.cj:804`，并注明「行号随重构漂移，以符号检索为准」

### [轻微][存量] `jit-closure-unload-cascade/design.md` §5 的「全流程只有单元 `mtx` 一把锁，无嵌套」与同文 D7 及实现矛盾（锁内取缓存锁）

- **位置**：`f_jit/doc/spec/jit-closure-unload-cascade/design.md:159`（「锁序 | 全流程只有单元 `mtx` 一把锁，无嵌套」）；对照 `design.md:131-148`（D7 伪码在 `synchronized(this.mtx)` 内「… 逐出缓存 …」）、实现 `f_jit/src/JitFunction.cj:256-277`（`:260-265` 在锁内 `CompileCache.remove(k)`）、`f_jit/src/CompileCache.cj:71-84`（`finish` 明确把 `bindCacheKey` 移到缓存锁外以避开 ABBA）
- **来源**：存量（快照）
- **判据**：review-checklist §12.2「锁序」、§13「规格与实现漂移」；不变量写错会让后来者按「单锁」假设改代码
- **证据**：静态确定 —— `close` 持 `this.mtx` 期间调用 `CompileCache.remove`（取全局缓存锁），构成 unit.mtx → cache.mtx 的嵌套；反向路径已被 `CompileCache.finish` 的锁外 `bindCacheKey` 规避，但该规避只写在缓存侧注释里，规格未记
- **描述**：实际不变量是「两把锁，固定顺序 unit.mtx → cache.mtx，且 cache 侧不得在持锁时回调单元」，不是「单锁无嵌套」。当前实现安全（`CompileCache.finish` 的注释与 `:74-84` 的顺序保证），但规格把安全前提写没了
- **建议**：把 §5「锁序」改为「两把锁：单元 `mtx` 与 `CompileCache.mtx`，只允许 unit.mtx → cache.mtx；`CompileCache.finish` 必须在缓存锁外调用 `bindCacheKey`」，并在 `spec.md:61-63` 的卸载状态机 Requirement 补一句锁序约束

### [轻微][存量] 归档规格的 `unload()` / `unloadFn()` / `isUnloaded()` 已整体改名 `close(timeoutMs)` / `closeClosure` / `isClosed`，规格未回填

- **位置**：`f_jit/doc/spec/jit-closure-unload-cascade/specs/f-jit-facade-bridge/spec.md:39`（「唯一释放入口 SHALL 为 `unload()`」「`unloadFn()` SHALL 为内部私有实现」）、`:22-25`（「卸载弱语义」Scenario）、`design.md:8`、`:72-86`（D4 `unload()` 分派）、`:175-182`（§8 API 影响）；现状 `f_jit/src/JitFunction.cj:227`（`close(timeoutMs)`）、`:294`（`closeClosure`）、`:471`（`isClosed`）、`:523`（`close(): Unit`）
- **来源**：存量（快照）
- **判据**：review-checklist §13「文档过期：描述的功能已改名」；`reviewer.md` 对归档 `doc/spec/` 的豁免只要求「当时结论自洽」，故只记轻微
- **证据**：静态确定 —— `grep -rn "isUnloaded\|\.unload(" f_jit/src` 零命中；现行公开 API 与 README 统一使用 `close`
- **描述**：后续变更把 `unload` 改名为 `close`（与 `Resource` 对齐，合理），但本规格未回填。按规格写代码或按名检索会找不到入口；规格里「`unload()` 在包装实例上释放本闭包」的语义现在挂在 `close(timeoutMs)` 上，读者无从对应
- **建议**：在规格顶部加一行「**后续变更**：`unload()`/`unloadFn()` 已更名为 `close(timeoutMs)`/`closeClosure`，`isUnloaded()` 并入 `isClosed()`；语义不变」，或由主 Agent 合并时统一记一条「归档 spec 的 API 名称未随重命名更新」

### [轻微][存量] 规格的多条验收 Scenario 没有对应用例：越界基址「整单元回退」、G6 的「中断」出口、运行期错误路径的 `NativeMem.outstanding()`

- **位置**：
  - `f_jit/doc/spec/harden-f-jit-object-lifetime/specs/f-jit-backend/spec.md:48-51`（「越界基址被拒绝 … 单元降低失败并退回解释器，结果/错误码/site 与纯解释一致」）—— `src/backend/EmitAudit_test.cj` 只测 `auditAllows` 纯函数与采集/重置，无用例驱动 `X86Lower`/`A64Lower` 真正失败
  - 同文件 `:53-62`（四个出口都要满足三项归零）—— `src/Lifetime_test.cj:82-99`（运行期错误）只断言 `liveCount` 与 `windowUsed`，缺 `NativeMem.outstanding()`（`:69`/`:77` 只出现在成功路径）；全文件无「中断 / deadline」出口用例（`grep deadline src/Lifetime_test.cj` 零命中）
- **来源**：存量（快照）
- **判据**：review-checklist §14.1「只做了一半的分支」「接线缺失」、§13「验收口径与实现不一致」
- **证据**：静态确定 —— 上述两处函数体内无相应调用；`Lifetime_test` 的出口集合只有「成功 / `DIV_ZERO` / 契约失败」三类
- **描述**：`DIV_ZERO` 这类运行期错误会经过 `JitReport.finish` 的 replay/诊断分支，是最可能产生原生内存不对称的出口，恰恰没有断言原生内存；「中断」出口完全无覆盖。G5 的「越界即回退」只有纯函数级断言，无法证明整单元真的退回解释器且结果与解释一致
- **建议**：`runtimeErrorCallsKeepResourcesFlat` 增加 `NativeMem.outstanding()` 基线与收尾断言；补一条以过去 `deadline` 触发 `−2` 的用例并断言三项；补一条构造性用例（让 `noteMemBase(0)` 参与一次 lowering，断言 `success()` 为假且调用结果/错误码与解释器一致）

<!-- 第 16 部分 -->

### [一般][存量] `optimize-call-alloc`：设计的「`pins` 残留 → `resetWindow` 误释放」与实现相反，且与同变更 `verify.md` 结论互相矛盾

- **位置**：`f_jit/doc/spec/optimize-call-alloc/design.md:45`、`f_jit/doc/spec/optimize-call-alloc/proposal.md:36`；对照 `f_jit/doc/spec/optimize-call-alloc/verify.md:42`
- **来源**：存量（快照模式无基线；`git log -1 -- f_jit/doc/spec/optimize-call-alloc` = 2026-11-27）
- **判据**：review-checklist §13（文档与实现不符）+ §2（同一变更内多处复述同一结论，结论本身错误）
- **证据**：静态确定 —— `resetWindow` 的释放循环只遍历 `w.appendIds`（`f_jit/src/runtime/HandleTable.cj:1064`），并在循环上方的注释里明确写「路径 B 的 pin 是桥侧资产，**窗口收尾不得动它**」（`HandleTable.cj:1062-1063`）；`w.pins` 只在 `HandleTable.cj:1083` 被 `clear()` 清记账，从未被用于释放槽。因此「`pins` 残留在 `resetWindow` 里误释放别的调用 pin 的槽」这条因果不成立。`verify.md:42-43` 自己也写「`pins` 残留不会造成功能错误……陈旧 ID 直接跳过（只是多扫一条）」，并据此判定「不清 `pins`」不是有效变异形态——与 `design.md:45` / `proposal.md:36` 的「必须清、否则误释放」直接对立。
- **描述**：同一个变更的三份文档对「`pins` 要不要清、为什么清」给出相反结论：design/proposal 说 `pins` 残留会造成跨调用误释放（把它列为 5 个字段里最危险的两个之一），verify 说 `pins` 残留无害、不是有效变异。实际实现里真正的风险字段只有 `appendIds` 与 `used`（`appendIds` 决定 `resetWindow` 释放哪些槽、`used` 决定 `hwTop` 镜像与容量），`pins` 只影响 `winPinSize` 的去重扫描长度（`HandleTable.cj:262-274`）。按错误因果读文档的维护者会做两件错事之一：把「清 `pins`」当成不可删的必要保护（保留冗余、掩盖真正的不变量），或在其它路径复用 `Win` 时以为「只要清了 `pins` 就安全」而漏清 `appendIds`。
- **建议**：把 `design.md:45` 与 `proposal.md:36` 的风险描述改成「残留 `appendIds` / `used` 会让新窗口继承上一次的释放清单与记账」，`pins` 标注为「仅为去重列表，残留只增加扫描、不影响正确性」；同时把 `recycleWin` / `acquireWin` 里清 `pins` 的注释写成防御性（或直接说明与 `resetWindow:1083` 冗余）。护栏用例无需新增（现 `reusedWindowStartsClean` 已覆盖 `used`/`appendIds` 口径）。

### [一般][存量] `optimize-call-alloc2` 的验证表把快/慢两种模式混在一行，`+2.3%` 没有基线，两轮相差 1.85× 却被判为「噪声内」

- **位置**：`f_jit/doc/spec/optimize-call-alloc2/verify.md:5-12`（对照 `f_jit/doc/spec/optimize-call-alloc2/tasks.md:3`、`f_jit/doc/spec/optimize-call-path-phase1/design.md:56-60`）
- **来源**：存量（目录最后提交 2026-11-27）
- **判据**：review-checklist §13（文档结论与所列数据不符）+ §6.1（判定必须给对照与离散度，中位数而非单次最好值；无数据的结论只能进「待验证假设」）
- **证据**：静态确定 —— 表里 `改前` 只有一组 `3036 ns / 329k calls/s`，`改后（两轮）` 是 `2975 / 5516` 与 `336k / 181k`；结论段写「快模式 3036 → 2975（−2.0%），**慢模式 +2.3%**，均在噪声内且低于 MOV(3%)」。慢模式的改前值在表里不存在（按 +2.3% 反推应约 5392 ns，文档未给）；而同一臂的两轮值 2975 与 5516 相差 **85%**，按项目自己在 `optimize-call-path-phase1/design.md:56-60` 定的口径（`MOV = max(3%, 2d)`；`d ≥ 10%` ⇒ 工具不稳定，**先修工具，不进入任何优化**），这组数据连「工具稳定」都不成立，无法支撑「在噪声内」的判断。
- **描述**：`−2.0%` 与 `+2.3%` 分别取自两个不同模式的值，却与同一行基线比较；慢模式基线缺失，`+2.3%` 不可复核。文档随后以「本轮不宣称加速」收尾，结论方向没问题，但「均在噪声内」的措辞掩盖了真实情况：**两轮之间差 85%，属于模式/环境切换，不是噪声**。这类记录会被下一轮优化当作「已有基线」，把不同机器状态的数据并到一条序列上。另有一处口径不一致：`proposal.md:27` 与 `tasks.md:7`（K3.2）写「同进程 5 万次 × **3 轮**取最小」，`verify.md:5` 写「**5 轮**取最小」，轮数无法互证。
- **建议**：拆成两行两列（快模式 / 慢模式各自给改前与改后），慢模式补基线值与环境行（`uname -a`、`load average`、`taskset`）；结论改成「快模式 −2.0%，低于 MOV；慢模式因缺改前基线，本轮不判定」。若坚持「两轮同模式」，则按 `d ≥ 10%` 规则宣布工具不稳定、不作任何结论。

### [轻微][存量] `optimize-call-alloc` 验证表样本不对称，且「`L1` 约 −300~370 ns」与表中数据算不出来

- **位置**：`f_jit/doc/spec/optimize-call-alloc/verify.md:15-25`
- **来源**：存量（目录最后提交 2026-11-27）
- **判据**：review-checklist §13（文档数据与结论不符）+ §6.1（对照必须同环境、同口径）
- **证据**：静态确定 —— A/B 表两臂样本数是 3 vs 2（`复用 241 / 236 / 430`，`每次 new 632 / 333`），配对关系（哪一对是同轮）没有写；结论「慢峰 632 → 430（−32%）」「快峰 333 → 236（−29%）」只用掉其中两对，`241` 未被使用。随后一句「`L1` 约 **−300~370 ns**」与表内数据不符：以历史基线 601 ns 计，对 430 是 −171 ns、对 241 是 −360 ns、对 236 是 −365 ns，任何配对都得不到 −300 的下界（若按配对 632→430 则是 −202 ns）。`−32%` / `−29%` 本身算得对（631.96 / 29.1）。
- **描述**：`keep` 判定成立（远超 MOV），但收益区间写大了约 1.8 倍，且 3 个复用值里有一个未参与任何对比，读者无法重现「−300~370」。这类区间会被后续汇总当成窗口池的真实收益上界。除数值外，判定判据本身也缺数据：`tasks.md:24`（W4.1）要求「5 次 + `Q4` 回退 ≤2% + `windowRs` ≤300 ns」，而 `verify.md` 全篇没有 `Q4`，慢峰 430 ns 也超过自定的 300 ns 上限且未作说明 ⇒ 三条判据里有两条没有数据支撑。
- **建议**：A/B 表改成「同轮配对」两列（第 1/2 轮各自的复用值 vs new 值），删掉未配对样本；收益区间按实际配对重算，或直接写「−171 ~ −365 ns（相对历史 601 ns 基线）」；并补 `Q4` 的改前/改后值，把 W4.1 的「≤300 ns」改成可判定形式（或注明慢峰 430 ns 未达标、判定只依据相对 MOV）。

### [轻微][存量] `WindowPool_test` 实际 3 条用例，tasks/verify 两处记 2 条，且 verify 的护栏清单漏掉变异验证所依赖的那一条

- **位置**：`f_jit/doc/spec/optimize-call-alloc/tasks.md:13`、`f_jit/doc/spec/optimize-call-alloc/verify.md:29-32`（对照 `tasks.md:29`、`verify.md:40`）
- **来源**：存量
- **判据**：review-checklist §13（文档与实现数量不一致）+ §14（验收记录与实际护栏不匹配）
- **证据**：静态确定 —— `f_jit/src/WindowPool_test.cj` 有 3 个 `@TestCase`：`repeatedOpenResetKeepsState`(`:36`)、`liveCountReturnsToBaseline`(`:53`)、`reusedWindowStartsClean`(`:68`)。`tasks.md:13` 记「新增 `WindowPool_test` 2 条」并只列「连续 1000 次开合」「`append` 残留不串」；`verify.md:29` 记「新增 2 条」，`verify.md:31-32` 列的 2 条是 `repeatedOpenResetKeepsState` 与 `liveCountReturnsToBaseline`——**漏掉 `reusedWindowStartsClean`**，而 `tasks.md:29` 的变异项（W5.1）正是以「`reusedWindowStartsClean` 变红」为验收，`verify.md:40` 的变异表也引用了它。
- **描述**：同一变更里「用例数」有三处口径（2 / 2 / 隐含 3），而 verify 的「护栏」小节把唯一的变异靶子漏在清单外，读起来像变异验证打在一条不存在的用例上。
- **建议**：三处统一为 3 条并补全用例名与断言要点（`reusedWindowStartsClean` = 复用窗口从 `used==0` 开始、`append` 残留不串）；`verify.md:31-33` 的清单与 §4 变异表对齐。

### [轻微][存量] `optimize-arg-staging` 的「394 ns 拆解」四项合计 411–489 ns，比被拆解的总量还大

- **位置**：`f_jit/doc/spec/optimize-arg-staging/design.md:5-14`、`f_jit/doc/spec/optimize-arg-staging/tasks.md:10-11`、`f_jit/doc/spec/optimize-arg-staging/verify.md:14-19`
- **来源**：存量（目录最后提交 2026-11-27）
- **判据**：review-checklist §13（数据核算错误）+ §6.1（拆解必须闭合，否则不能作为判定依据）
- **证据**：静态确定 —— 四段估算为 `~170` + `50–100` + `~170` + `21–49`，合计 **411–489 ns**；被拆解的端到端差值是 394 ns（`f_jit/doc/optimize-call-path.md:329` 原文 `+394（实参路径）`）。下界已超出 17 ns，上界超出 95 ns（4%–24%）。同一份 verify 还用「单参调用约 3.5–6 µs」作分母（`verify.md:23`），而 `optimize-call-path.md:329` 的单参单元是 8977 ns，两个分母相差近一倍。
- **描述**：判定结论（`invokeOff` 自身 21–49 ns < MOV，**不做**）不受影响——错误方向是把小项估大，不会把小项变成大项。但「拆解」不闭合意味着四段的归属占比（`<1.5%`）不可复核，而这正是本变更唯一的交付物（纯测量/判定）。
- **建议**：把四段改成「其中可归因段 + 未归因残差」的形式（例如列出 411–489 的估算区间并注明与 394 的差额为估算误差/未测量段），或按实测把 `Array<Any>` 构造与 `cells` 分配两段的 170 ns 重新标定；分母统一取 `optimize-call-path.md:329` 的同一场景值。

### [轻微][存量] `jit-closure-unload-cascade/tasks.md` 的归档项未勾选，但四件套镜像已落盘（且该变更已被后续 `close` 改名取代）

- **位置**：`f_jit/doc/spec/jit-closure-unload-cascade/tasks.md:36`（C4.5）
- **来源**：存量（目录最后提交 2026-10-27）
- **判据**：review-checklist §13（文档过期 / 状态与事实不符）
- **证据**：待确认 —— `ls -R f_jit/doc/spec/jit-closure-unload-cascade` 显示 `design.md` / `proposal.md` / `specs/f-jit-facade-bridge/spec.md` / `tasks.md` 四件齐全，即 C3.4「四件套落盘」与 C4.5「归档后用最终版覆盖」在效果上已完成；但 `openspec/changes/archive/` 下只有 5 个非 jit 条目，仓内也没有其它 jit 变更的归档记录，因此「归档」在本仓到底指 `openspec archive` 还是「镜像到 `doc/spec/`」无法从文档判定。缺的是归档落点的定义。
- **描述**：这是本变更唯一未勾选项。下一轮若按「存在未完成项」回看，会误以为该变更是半成品；实际它已被 `jit-function-resource-close`（`close` / `isClosed` 改名）整体取代（对照 `tasks.md:21` 的 `unloadFn` 与现源码 `JitFunction.cj:294` 的 `closeClosure`）。旧名残留的检索面已由 part15 #9 报出，此处只记状态不一致。
- **建议**：勾选 C4.5 并在文件头加一行「已被 `jit-function-resource-close` 取代（`unload*` → `close*`），仅作历史记录」；若确未执行 `openspec archive`，把该项改为「不适用」并说明本仓归档口径。

### [一般][存量] `jit-function-resource-close` 的 delta spec 把 `close()` 写成无条件卸载，缺「存在在飞调用时静默不关闭」这一分支

- **位置**：`f_jit/doc/spec/jit-function-resource-close/specs/f-jit-facade-bridge/spec.md:5`（Requirement）、`:7-10`（Scenario「入口实例关闭」）
- **来源**：存量（spec 与实现同属 `5c5dfb6ec`）
- **判据**：review-checklist §13（文档承诺与实现相反）+ §3（公开契约承诺有行为、实现可空转）
- **证据**：静态确定 —— spec 写「入口实例的 `close` SHALL 卸载单元（终态、逐出缓存、级联释放逃逸闭包）」，Scenario 写「WHEN 调用 `close()` 或 `close(timeoutMs)` THEN 单元进入终态」；实现 `close()` 体为 `let _ = this.close(0)`（`JitFunction.cj:523-525`），`close(0)` 在 `active != 0` 时第一次判空失败即 `state = 0` 回退并 `return false`（`JitFunction.cj:234-243`），返回值被丢弃。
- **描述**：代码侧后果（`try-with-resource` 下漏释放、调用方拿不到任何信号）已由 part15 #1/#3 记录，此处只记**文档面**：Requirement 与 Scenario 都没有「存在在飞调用」这一分支，而 `design.md:32` 却把它写成「已知边界」。按 spec 编写测试的人会写出「并发调用未返回时 `close()` 后 `isClosed()` 为真」这类必然失败的用例；按 spec 写调用方的人会以为 `Resource.close()` 一定完成释放。
- **建议**：Requirement 补条件句「无在飞调用时 SHALL 进入终态；存在在飞调用时 SHALL 保持可用（`isClosed()` 为 false、后续调用仍成功），该情形由 `close(timeoutMs)` 显式表达」；Scenario 增加一条「一次调用未返回时 `close()` → 单元仍可用、`isClosed()` 为 false」。

### [轻微][存量] `makeRetUnboxer` 只剩测试引用却保留 `public`，而 `optimize-call-alloc2` 以「测试在用」作为保留理由

- **位置**：`f_jit/doc/spec/optimize-call-alloc2/verify.md:14`、`proposal.md:17`；符号 `f_jit/src/CallMarshal.cj:41`（`protected class CallMarshal`）、`:187-190`
- **来源**：存量（`a05c5df7f`）
- **判据**：review-checklist §1「仅测试使用 → 可见性建议（不算死代码）」
- **证据**：静态确定 —— `CallMarshal` 是顶层 `protected` 类，其 `public` 成员对外不可达；`makeRetUnboxer` 的 8 处引用全在 `*_test.cj`（`CallMarshal_test.cj:97/101/105/133/169/187`、`CallMarshalAny_test.cj:90`、`JsonBridge_test.cj:93`），生产路径走 `unboxRet`（`JitFunction.cj:650`）。
- **描述**：验证记录把「测试在用」当成保留一个已被判定为纯开销形态（现建闭包 + 一次间接调用）的理由，等于让产品类为测试便利背一个 `public` 入口；后续读者会把 `makeRetUnboxer` 误认成对外契约。
- **建议**：把 `{ cell => this.unboxRet(t, cell) }` 下沉到测试侧（或测试直接调 `unboxRet`）后删除；若必须保留，收窄为 `internal` 并注明「测试辅助，非契约」。

<!-- 第 17 部分 -->

### [一般][存量] 规格把「逃逸提升 ↔ 释放/收窗」并发划出承诺范围，但同一槽位字段由两把不同锁写、且无任何线程约束校验

- **位置**：
  - 文档：`f_jit/doc/spec/optimize-call-path-phase2/design.md:36-37`（"`escapeFlags` 仍由 `mtx` 侧（`moveOutGroup`/`escape`）写；同槽「提升」与「释放」并发属调用方非法用法…不在本变更承诺范围"）、`f_jit/doc/spec/optimize-call-path-phase2/verify.md:75`
  - 代码：`f_jit/src/runtime/HandleTable.cj:1034-1040`（`escape` 在 `synchronized(mtx)` 内写 `escapeFlags`）、`HandleTable.cj:1109-1117`（`moveOutGroup` 在 `mtx` 内写）、`HandleTable.cj:1072-1077`（`resetWindow` 在**分片锁**内读 `escapeFlags`）、`HandleTable.cj:1020-1024`（`releaseEscaped` 在**分片锁**内清 `escapeFlags`）、`HandleTable.cj:670-678`（`isEscaped` 完全无锁读）
- **判据**：review-checklist §12.1（共享可变状态无统一同步手段）/ §11（契约与实现不符）
- **证据**：静态确定 —— `escapeFlags[off]` 的写者分属 `mtx` 与「`idx & 63` 分片锁」两把互不排斥的锁，读侧又分别在分片锁内（`resetWindow`）与完全无锁（`isEscaped`）下进行，三者之间不存在任何 happens-before。触发面为待确认：需要「同一句柄在一个线程 `escape`/`promote`、同时另一线程 `release` 或该句柄所属窗口收尾」。
- **描述**：该字段承载的是「**槽已提升 ⇒ 窗口收尾不得释放**」这一句柄生命周期不变式。`mtx` 侧的 `escape` 与分片锁侧的 `resetWindow` 不互斥，最坏情形是收窗读到旧值 `false`，把一个已提升（`PromotionGroup` 仍在册、引用计数 > 0）的槽释放掉：此后闭包调用读到 `gen` 不匹配 → 抛 6 `NULL_HANDLE`（判定口径见 `HandleTable.cj:965-976`），或者槽被别的对象复用后经旧 ID 落到失败路径，属于**句柄生命周期错误**而不是性能问题。规格用「调用方非法用法」把它排除，但三点支撑不足：
  1. `promote` / `escape` / `release` / `releaseEscaped` 都是 `public` API（`HandleTable.cj:986`、`:1006`、`:1029`、`:1138`），`f_jit/README.md` 只写了「`IterTable` 游标线程私有」（`:596`），全模块公开文档没有写「同一句柄不得跨线程同时提升与释放」这条前置条件；
  2. 同模块的并发设计把这件事当成**已支持**：`f_jit/doc/design-parallel-call.md:168` 的 P4 写「跨线程包装 + `PromotionGroup` 原子化 | A 建包装、B/C 调用、D 释放」，`:196` 的风险表把「提升/释放跨线程」列为已用「`PromotionGroup` 原子引用计数」处置的风险项。也就是说，phase2 用「调用方非法用法」排除的正是另一份设计文档承诺要保护的场景。
  3. `moveOutGroup` 用的是**调用线程的窗口**（`HandleTable.cj:1107-1108` `currentWin()`），对「槽不属于本线程窗口」既无校验也不报错：`moveOutGroup` 内层只有 `w.appendIds` 命中才扣记账（`:1118-1130`），跨线程调用时静默不扣、也不提示。`PromotionGroup` 的类注释（`f_jit/src/runtime/PromotionGroup.cj:39-44`）恰恰声明支持「A 线程创建、B/C 调用、D 线程释放」。
- **建议**：三选一并落到规格里：(a) 把 `escapeFlags` 的读写统一到分片锁（`escape`/`moveOutGroup` 在写前取 `mtx → 分片锁`，与 `releaseConst` 现有锁序一致，见 `HandleTable.cj:651-654`），代价是提升冷路径多一次分片锁；(b) 保留现状但在 `escape`/`moveOutGroup`/`release` 的公开注释与 README 明确线程约束，并在 `moveOutGroup` 检测「槽不在本线程任何窗口」时显式记诊断而不是静默；(c) 若确认桥接层存在「调用中把闭包/句柄交给宿主、宿主再跨线程提升」的路径，则本条应升为**严重**并优先修锁。

### [一般][存量] 四份规格的 keep 判定与 `doc/optimize-call-path.md` §1 自定的 MOV 闸门不可复算（闸门被事后放宽或绕过）

- **位置**：
  - `f_jit/doc/spec/optimize-call-path-phase2/verify.md:60-65`（S4 4 线程中位 **2.40 → 2.17**，即 −9.6%，判「噪声而非回退」）
  - `f_jit/doc/spec/optimize-call-path-phase4/proposal.md:41`（B 项验收："维持 2.2–2.4×（当前 2.28×）不回退"）vs `optimize-call-path-phase4/tasks.md:25-26`（"不得低于 2.0×"）vs `optimize-call-path-phase4/verify.md:66-69`（实测 **2.00×**，keep）
  - `f_jit/doc/spec/optimize-compile-copy/verify.md:31-33`（"中位数 −18.0%（12.20 → 10.01，**5.0× 离散度**内一致方向）…均 ≥ MOV"）vs `optimize-compile-copy/proposal.md:37`（预期"−25~35%"）
  - `f_jit/doc/spec/optimize-compile-hotpath/verify.md:21-24`（"点估计 **−1~8%**…按 MOV 判定为 keep（边际）"）
  - `f_jit/doc/spec/optimize-compile-lookup/tasks.md:8-10`（同一场景基线 **47.7 / 24.9 / 24.9 ms**，据此算「名字查找 ≤50 µs ≈ 0.2%」）
  - 判据源：`f_jit/doc/optimize-call-path.md` §1 规则 3（"其它指标中位数回退 ≤ 2%"、"不可协商"）、MOV = `max(3%, 2×离散度)`
- **判据**：review-checklist §13（规格与实现/规格自身漂移）+ `scope.md`「每条发现必须可复核」；判定闸门是后续所有性能改动的验收契约
- **证据**：静态确定 —— 文档内数字与文档自定的闸门直接冲突，且冲突处没有记录任何「闸门变更」决策：
  1. 规则 3 要求「其它指标中位回退 ≤ 2%」，phase2 的 S4 中位回退 −9.6% 仍保留，解释为「两次低值同时伴随 Q1/F1/F4 变差（机器负载）」；该噪声豁免在规则文档里不存在。phase1 的 P1.3 也记录了 S4 −9.9%（`optimize-call-path-phase1/verify.md:10`），但那次 revert 的主因是「无指标达 MOV」，S4 只是附带数据——真正的口径问题是 phase2 单方面以噪声解释越过「回退 ≤2%」，文档没给噪声判据。
  2. phase4 B 项的验收线在 proposal（2.2–2.4×）与 tasks（≥2.0×）之间被下调，最终值恰好落在下调后的下限 2.00×，verify 以「单线程基线大幅变快导致扩展比下降」解释。绝对成本减半是真的，但「扩展比不回退」这一条实际未达成，文档未标注为「指标口径变更」。
  3. compile-copy 自报「5.0× 离散度」，而 MOV = max(3%, **2×离散度**)：若 5.0× 就是离散度，−18% 达不到该闸门；「5.0×」未定义（是极差比？5 次测量？），算式无法复算。同时实测 −18% 低于 proposal 承诺的 −25~35%，verify 未点明未达预期。
  4. hotpath 点估计下沿 −1%、三分之二的「阶段 × 模式」配对只有 −0.3% ~ −1.3%，低于 3% 的 MOV 下限；判 keep（边际）时未给 2× 离散度的具体数值。
- **描述**：这些归档件是「为什么保留这段代码」的唯一凭据。闸门可被事后解释绕开后，后续同类改动的「保留/回滚」失去共同基准；更实际的风险是：phase2 的 S4 回退与 phase4 的扩展比下降都被归因为机器噪声，但两次归因都没有给出线程状态或独占机复测（规则 5 要求的专用 ≥8 核复测至今是遗留项，`optimize-call-path-phase1/verify.md:60`）。
- **建议**：在 `doc/optimize-call-path.md` §1 增补「噪声豁免」的判定条件（例如：同一臂 ≥3 次、配对样本、给出 BLOCKED/WAITING 或 load 证据），并在每份 verify 的判定行旁标注「本条闸门：keep 依据 = 指标 X 中位 a→b、离散度 d、MOV=…」。未达原承诺的项（compile-copy −18% vs −25~35%、phase4 扩展比 2.00×）显式写「未达预期但按 MOV 保留」。

### [轻微][存量] 规格文本与仓库事实不符（符号名、测试路径、声称的断言）

- **位置**：
  - `f_jit/doc/spec/optimize-call-path-phase2/proposal.md:24`：「常量路径（**`markConst`** / `releaseConst`）保留 `mtx`」——仓内无 `markConst` 函数，实际为 `HandleTable.pinConst`（`f_jit/src/runtime/HandleTable.cj:606`）；`markConst` 全仓仅出现在 `HandleTable.cj:139` 的注释里
  - `f_jit/doc/spec/optimize-compile-copy/proposal.md:41`：「+ 护栏 `src/backend/CompileCopy_test.cj`」——同变更 `tasks.md:11` 写的是 `src/compiler/CompileCopy_test.cj`，实际文件在 `f_jit/src/compiler/CompileCopy_test.cj`（`src/backend/` 下不存在该文件）
  - `f_jit/doc/spec/optimize-call-path-phase4/tasks.md:19-20`：B1 声称护栏断言「返回值单调不减**且最终等于高水位**」——`f_jit/src/runtime/HandleTableStripeConcurrency_test.cj:89-104` 只断言单调不减与 `liveCount==0`，无「等于高水位」
  - `f_jit/doc/spec/optimize-call-path-phase2/design.md:44`：「退休槽不进任何分片（**`retiredCount` 不变**）」——`HandleTable.cj:1153-1156` 每次退休 `retiredSlots.fetchAdd(1)`，且 `retiredCount()`（`:1271-1273`）对外暴露该递增计数；同变更 `verify.md:25` 又写「`retiredSlots` 改 `AtomicInt64`」，两处口径相反
- **判据**：review-checklist §13（API / 路径 / 断言与源码不符）
- **证据**：静态确定 —— 逐条全仓搜索：`markConst` 0 个函数定义；`CompileCopy_test.cj` 仅存在于 `src/compiler/`；测试文件正文无高水位相等断言；`retiredSlots` 有 `fetchAdd`。
- **描述**：四处均为归档记录的**事实性错误**，不影响当前运行行为，但会把后续维护者引到不存在的符号/路径上；`retiredCount` 一处还与同变更的 verify 自相矛盾，读者无法判断「退休槽数到底变不变」。
- **建议**：把 `markConst` 改为 `pinConst`；`proposal.md:41` 的路径改为 `src/compiler/CompileCopy_test.cj`；`tasks.md` B1 的断言描述改成实际断言，或给用例补 `slotCount()==高水位`；`design.md:44` 的括注改为「退休槽不进任何分片（`retiredCount` **+1**，槽位永久不可复用）」。

### [轻微][存量] `optimize-compile-copy` 全量计数与「临时探针已删除」互斥，并被下一份 verify 当基线沿用

- **位置**：`f_jit/doc/spec/optimize-compile-copy/verify.md:62-63`；传播到 `f_jit/doc/spec/optimize-compile-hotpath/verify.md:47`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §13（规格内部数字不自洽）
- **证据**：静态确定 —— copy/verify.md:62 记 `1241 / 1241，0 失败 0 错误`，:63 括注 `较改前 1239 多出本次新增的 1 条护栏，另 1 条为临时探针，已删除`。按该括注自身算术：1239 + 1 护栏 + 1 探针 = 1241，探针删除后应为 **1240**；若坚持 1241 为收口值，则「改前 1239」写错（应为 1240）。两个数字必有一个错，文档未给第三种解释。hotpath/verify.md:47 又以 `较改前 1241 多出本次新增的 3 条护栏` 得 1244，把该口径继续往下传
- **描述**：全量用例总数是各变更「零失败」结论的唯一量化凭据；此处无法判断 1241 是否含已删除的探针，后续基线（1241→1244）随之不可复核。不影响运行代码，属归档记录缺陷
- **建议**：按该提交实测 `TOTAL` 回填两处：copy/verify.md:62-63 写成「改前 1239 / 新增 1 条护栏（1240）/ 临时探针 1 条另计、收口已删」，hotpath/verify.md:47 改用同一基线；若确有并行增补，把该条用例写进文档

<!-- 第 18 部分 -->

### [一般][存量] 两份 design 的护栏清单列了仓内不存在的用例（合计 3 条），且与同变更 tasks / verify 的条数冲突

- **位置**：
  - `f_jit/doc/spec/optimize-emit-fixup/design.md:84-92`：表列 5 条，其中 `:92` 的 `missingLabelStillResolvesLikeBefore`（未绑定名字 → `labelOffset == -1`、`finishOrNull` 不 panic）**全仓只有这一行文档**
  - `f_jit/doc/spec/optimize-helper-table/design.md:60-67`：表列 4 条，其中 `:66 buildTableKeepsHidOrder`、`:67 pushTableDoesNotCopy` 同样只存在于本文档
  - 同变更自相矛盾：`optimize-emit-fixup/tasks.md:11-12`（E2.1「五条用例（见 design §4）」/ E2.2「4 条全绿（PASSED: 4）」）、`tasks.md:22`（E4.1「护栏四条全绿」）、`optimize-emit-fixup/verify.md:40-47`（只列 4 条）；`optimize-helper-table/tasks.md:10`（H2.1「3 条」）、`verify.md:26-32`（3 条）
- **来源**：存量（快照模式无 diff 基线）
- **判据**：review-checklist §14.1（承诺了但没实现）+ §13（同一变更内数字/断言自相矛盾）
- **证据**：静态确定 —— `missingLabelStillResolvesLikeBefore` / `buildTableKeepsHidOrder` / `pushTableDoesNotCopy` 全仓 grep 0 命中（仅两份 design.md）；实际用例数：`f_jit/src/backend/A64EmitterFixup_test.cj` 4 个 `@TestCase`（`:39/:68/:79/:101`），`f_jit/src/HelperTableScope_test.cj` 3 个（`:52/:65/:82`，第三条实际名 `hidOrderIsPreserved`）
- **描述**：两份 design 的论证方式都是「护栏描述既有语义，改前也必须全绿」，护栏是等价性证明的主要凭据，缺两条后论证不闭合：
  1. `missingLabelStillResolvesLikeBefore` 缺失。`labelOffset` 由线性扫改为 `HashMap.get(...) ?? -1`（`A64Emitter.cj:90-95`），未绑定标签直接进入 `delta = labelOffset(r.label) - r.at`（`:136`）；`checkRange=false` 时 `finish()` 会把 `delta = -1-at` 无条件回填（`:150-161`）。旧实现同样如此，属既有语义，但正是需要一条断言钉住的边界，现在 `finishOrNull` 在未绑定标签上的行为没有任何用例覆盖
  2. `pushTableDoesNotCopy` 缺失。design 自己在 `:69` 承认「把 `pushTable` 改回每次 `buildTable`，功能仍绿」——说明该改动的引用语义本来就没有功能护栏；少这一条后，`pushTable` 退化成「压一份拷贝」不会被任何用例发现（性能回退无声，只能靠 A/B 数据）
- **建议**：二选一并落到文档 —— (a) 补两条用例（`missingLabelStillResolvesLikeBefore`：`bind` 后对未绑定名断 `labelOffset == -1` 且 `finishOrNull()` 返回 None 不抛；`pushTableDoesNotCopy`：同一张表 push 两次、pop 一次后 `find` 仍命中）；(b) 把两份 design 的表改成实际条目，并显式写「未绑定标签边界未覆盖、`pushTable` 引用语义仅由 A/B 数据判定」，同时统一 tasks / verify 的条数。不要留「设计 5 条 / 任务 5 条 / 验证 4 条」三份口径

### [一般][存量] compile-path 的 D2 伪代码仍是「空转次数」退避，与 verify 和实现（墙钟 1 µs→500 µs）差一个数量级

- **位置**：`f_jit/doc/spec/optimize-compile-path/design.md:30-46`（`:37 backoff = min(backoff * 2, 8192)`、`:38` 纯 CPU 空转、`:44`「最坏等待粒度 = 8192 次空转（数十 µs），远小于一次编译（0.4–0.9 ms）」）vs 同变更 `verify.md:41`（「墙钟退避（1 µs → 500 µs，预算 30 s）」）vs 实现 `f_jit/src/CompileCache.cj:130`（`backoffNs = 1000`）、`:143-147`（空转到 `backoffNs` 再翻倍，上限 `500000`）、`:43`（`awaitTimeoutNs = 30000000000`）
- **来源**：存量
- **判据**：review-checklist §13（同一变更内设计与验证结论不一致）
- **证据**：静态确定 —— 设计伪代码的退避单位是「次数」，实现与 verify 的单位是「纳秒」；最坏粒度 8192 次空转（数十 µs）vs 500 µs，相差一个数量级
- **描述**：归档件是后来者判断「这段自旋为什么这么写」的唯一依据。按 design 读会以为最坏只等数十 µs；按实现读最坏 500 µs，已是「一次编译 0.4–0.9 ms」的同一量级（占比 55%–125%），design `:44` 的核心论据（等待粒度远小于一次编译）在实现口径下不成立。同一份计划的另一副本 `f_jit/doc/optimize-compile-path.md:45-55`（本部分范围外）也是 64/8192 版本，而该文件 `§4` 决策日志与 `§7` 已按「1 µs→500 µs」记录 —— 一份文档内部两套参数
- **建议**：design D2 的伪代码与 `:44` 结论改成实现口径，并补一句「最坏 500 µs ≈ 半次编译，单 key 等待者唤醒延迟上限 0.5 ms 量级」；若认为 500 µs 过大，写明「上限由 8192 次空转改为 500 µs 的理由」。`doc/optimize-compile-path.md §2` 同步

### [一般][存量] compile-path 的「4 线程扩展比 ≥2.0×」目标未达成，规格与模块文档都没有「按停止条件结项」的结论句

- **位置**：`f_jit/doc/spec/optimize-compile-path/verify.md:10,61,74-75`
- **来源**：存量
- **判据**：review-checklist §13（文档结论与目标冲突）、§14.1（承诺与实现）
- **证据**：静态确定 —— 同一变更的 `proposal.md:3` 以「扩展比只有 1.3–1.7×」立题；`f_jit/doc/optimize-compile-path.md:21-22`（§1，范围外）把目标写成「提到 ≥2.0×（本机上限 2.2–2.4×）」；verify 实测 **1.84×**（`:61`），`:74-75` 只说「剩余差距不在 mmap、不在本变更的锁，需要专用机 + profile」，没有「目标未达成 / 按 §5 停止条件结项」的判定。模块文档顶部 `:3` 标「状态：**全部完成并归档**」
- **描述**：「全部完成」指 M0/C1/C2 工作项，容易被读成目标达成。实际停止条件（`§5`：C1/C2 连续两项未达门槛 ⇒ 停止）被触发了一半（C2 达门槛、整体扩展比未达 2.0×），但没有记录这个判定 —— 下一轮无法从文档判断「编译路径优化是否已关闭、还要不要再立项」
- **建议**：verify 结论表加一行「4 线程扩展比目标 ≥2.0×：未达成（1.84×），剩余差距按 §5 停止条件挂起，需专用机 profile」；模块文档 §1 目标行标注实际值

### [轻微][存量] `normalizeNewlines` 的调用次数与调用方记错（写 4 次、实为 5 处，且写错一个组件）

- **位置**：`f_jit/doc/spec/optimize-emit-fixup/design.md:79-80`（「`normalizeNewlines` 在整条管线被调 **4 次**（`SourceCompiler` / `Parser` / `Lexer` / `NameResolver` / `DefiniteAssignment` 各一次），实测合计 38 µs」）
- **来源**：存量
- **判据**：review-checklist §13（文档与实现不一致；一行内自相矛盾）
- **证据**：静态确定 —— 一行里既说「4 次」又列了 5 个组件；实际调用点 **5 处**：`f_jit/src/compiler/SourceCompiler.cj:115`、`Parser.cj:51`、`Lexer.cj:57`、`DefiniteAssignment.cj:51`、`PredefinedSnapshot.cj:141`（定义在 `Lexer.cj:123`）；`NameResolver` **0 处**
- **描述**：「4 次 / 38 µs / 占改后总延迟 0.5%」这三个数互相依赖，次数错了分母就不可复算；第 5 处落在 `PredefinedSnapshot.cj`（design 未列的组件），意味着「顺手去掉重复 normalize」的改造面比文档写的大。这是后续决定「要不要动它」的直接依据，属会误导立项的漂移
- **建议**：改成「5 处（`SourceCompiler` / `Parser` / `Lexer` / `DefiniteAssignment` / `PredefinedSnapshot`），合计 38 µs」；若 38 µs 是按 4 次测的，重测或注明「按 4 处测得，第 5 处未计」

### [轻微][存量] emit-fixup 护栏的标签规模：design 写 200，verify 与用例都是 300

- **位置**：`f_jit/doc/spec/optimize-emit-fixup/design.md:88`（「建 200 个 `L<k>` 标签」）vs 同变更 `verify.md:44`（「300 条 `b`」）vs 实现 `f_jit/src/backend/A64EmitterFixup_test.cj:43`（`while (k < 300)`，断言 `:60` 为 `1 + k % 4`）
- **来源**：存量
- **判据**：review-checklist §13
- **证据**：静态确定 —— 用例循环上界 300，design 表写 200
- **描述**：单看是数字笔误，但它是「护栏覆盖多大标签表」的唯一描述，与 `branchesResolveToExactOffsets` 的强度直接相关（200 vs 300 决定是否覆盖到 `L2xx` 三位数名字的比较路径 —— 旧实现的字符串比较成本正来自同长度共享前缀）
- **建议**：design 改为 300，或注明「设计时按 200 估算，落地用 300」

### [轻微][存量] 已被本模块自己否证的「`ThreadLocal.get ≈ 300 ns」仍被后续规格当作决策依据

- **位置**：`f_jit/doc/spec/optimize-helper-table/design.md:56`（§2.4「收益仅为每次 find 省一次 TLS get（~300 ns），风险不成比例」）；源头 `f_jit/doc/spec/optimize-emit-audit/verify.md:18-24`、`proposal.md:7`
- **来源**：存量
- **判据**：review-checklist §13（模块内文档结论互相冲突）、§8（无基线的成本估算不得当依据）
- **证据**：静态确定（文档对文档）—— emit-audit 的 verify 明确写「『`ThreadLocal.get ≈ 300 ns`』的估算在本场景**未兑现**（598 × 300 ns ≈ 180 µs 应能在快模式看出 ~8%，实测没有）」，并把「跨场景外推微基准单项成本不可靠」写成教训；helper-table 的 design 仍用同一数字论证「不做 TLS 迁移」
- **描述**：结论方向（不做）安全，但依据已被同模块证伪，等于把一次失败的外推再用一次；后来者若据此外推别的热点（300 ns × N 次）会重复同一个错误
- **建议**：helper-table §2.4 改为「单项收益未测（emit-audit 已证该外推不可靠），故不以性能为由改契约」；`doc/optimize-call-path.md` 若引用同一数字，一并标注

### [轻微][存量] emit-fixup 的 tasks 只留最优配对性能数，与 verify 的保守口径不一致

- **位置**：`f_jit/doc/spec/optimize-emit-fixup/tasks.md:25-26`
- **来源**：存量
- **判据**：review-checklist §8 验证要求（不接受只报最优值）、§13（同一变更内记录口径不一致）
- **证据**：静态确定 —— `tasks.md:25` 记「端到端 44.32 ms → 6.42 ms（−85.5%）」，未标注是最优配对；`verify.md:29-36` 给出同批三次运行（44.32/24.06/45.07 → 11.06/11.10/6.42），并明确「保守取两臂最差配对（24.06 → 11.10）也有 −53.9%」
- **描述**：tasks 是被当作「已达成指标」扫读的文件，只留 −85.5% 会掩盖同批数据 3.7× 的离散度（改前 24.06–45.07 ms）。verify 做法正确，tasks 没跟上
- **建议**：`tasks.md:25` 补「（最优配对；保守配对 −53.9%，见 verify §3）」

### [轻微][存量] `A64Emitter` 的审计注释前半段仍主张 ThreadLocal，与后半段「用实例字段」及字段实现直接矛盾

- **位置**：文档 `f_jit/doc/spec/optimize-emit-audit/proposal.md:20`（「`ThreadLocal` 字段与 `auditList()` 删除」）、`design.md:16-29`（改实例字段的等价性论证）；代码 `f_jit/src/backend/A64Emitter.cj:446-452`
- **来源**：存量（`optimize-emit-audit` 落地时漏改上文注释）
- **判据**：review-checklist §13（注释/文档与实现不符）
- **证据**：静态确定 —— `A64Emitter.cj:450-452` 写「审计必须**按编译线程隔离**……放在 ThreadLocal 里零锁、零共享」，紧接着 `:453-459` 的字段注释写「用**实例字段**而不是 ThreadLocal」，`:460` 是 `private let audit: ArrayList<Int64>`；全文 `auditTls` / `auditList` 在 `A64Emitter.cj` 0 命中
- **描述**：前 3 行是 `optimize-compile-path` C0（并发编译 `IndexOutOfBoundsException`）时期的旧论证，留着会让后来者以为并发隔离靠 TLS，进而可能把 `audit` 改回静态/TLS；与紧随其后的实现说明直接矛盾，属可读性缺陷而非行为缺陷
- **建议**：删 `:446-452` 中的「放在 ThreadLocal 里零锁、零共享」，把「C0 曾用 TLS、后被 `optimize-emit-audit` 改为实例字段」压成一句历史注记，保留 `:453-459` 的实例字段说明

### [轻微][存量][待确认] 五份 tasks 勾选的 openspec 归档 / `validate --strict` 在仓库里没有对应产物

- **位置**：`f_jit/doc/spec/optimize-compile-path/tasks.md:23-24`（X.1「`openspec validate --strict`；归档 `2026-11-27-optimize-compile-path`」）、`optimize-emit-fixup/tasks.md:32-33`（E5.2/E5.3）、`optimize-emit-audit/tasks.md:28`（I5.2/I5.3）、`optimize-decode-alloc/tasks.md:9`（J4.2/J4.3）、`optimize-helper-table/tasks.md:28-29`（H5.2/H5.3）
- **来源**：存量
- **判据**：review-checklist §14.1（记录不可复核 / 接线缺失）
- **证据**：待确认 —— `openspec/changes/` 下只有 `add-f-a2a/` 与 `archive/`；`openspec/changes/archive/` 只有 5 个 `2026-11-20-*` 目录；全仓无 `2026-11-27-optimize-*` 产物。缺的信息：这些变更是否在别的机器/分支做过 openspec 归档后被清理，或从未真正归档
- **描述**：五份规格都把「归档 + `validate --strict`」勾成已完成，仓库里唯一产物是 `f_jit/doc/spec/<change>/` 镜像。`optimize-compile-path/tasks.md:3` 的 `skip_specs: true` 能解释「`openspec/specs/` 没有能力条目」，解释不了「`changes/archive/` 没有变更目录」。后果是归档链断在那里：复核「当时 accept 的是哪版 proposal」只能依赖镜像，而镜像本身没有校验记录
- **建议**：补回归档目录，或把这五处勾改成「归档产物仅保留 `f_jit/doc/spec/` 镜像（`skip_specs: true`）」

### [轻微][存量][待确认] 「多线程并发只读同一张 `HashMap` 是安全的」是断言，缺标准库依据

- **位置**：`f_jit/doc/spec/optimize-helper-table/design.md:31-32`（§2.2）；实现 `f_jit/src/JitFunction.cj:612-613`、`f_jit/src/runtime/UserHelper.cj:83-86,101-113`
- **来源**：存量
- **判据**：review-checklist §12.1（共享可变状态的并发访问需给出同步手段或证明线程封闭）
- **证据**：待确认 —— 本机没有仓颉 std 文档（`~/.autocode` 不存在，`cangjie-doc-lookup` 的本地文档源不可用），无法核对 `std.collection.HashMap.get` 的读路径是否纯读；仓内也没有并发 `find` 同一张表的用例
- **描述**：改后每个单元只建一张表，所有线程、所有嵌套调用共享同一 `HashMap` 实例（`helperTableCache` 在 `bindUserHelpers` 写入，`callLocked` 反复读）。发布本身有 happens-before（`CompileCache` 的 `synchronized(mtx)` 就绪门），这一点没问题；缺的是「并发 `get` 无副作用」的依据。若 `get` 内部有惰性写（统计/扩容），这里就是无同步的数据竞争
- **建议**：查 std `HashMap` 文档确认 `get` 不写；若要彻底消除该类风险，可在 `bindUserHelpers` 把表固化为 `Array<(Int64, UserHelperEntry)>`（hid 连续可直接下标）或有序数组二分，`pushTable` 压只读数组

> **存量 10 条（0 严重 / 3 一般 / 7 轻微），是否纳入修复待用户决定。**

<!-- 第 19 部分 -->

### [一般][存量] `optimize-loop-safepoint` 的 x86 侧把 ctx 寄存器写成 `rdi`，与代码、测试、同组 verify 全部相反

- **位置**：
  - 文档：`f_jit/doc/spec/optimize-loop-safepoint/design.md:75`（`mov rax, [rdi+48]      // ctx.flags（x86 侧 ctx 在 rdi）`）、`proposal.md:36`（`mov rax,[rdi+48]`）、`tasks.md:36`（`mov rax,[rdi+48] / mov rdx,8 / test rax,rdx / jz skip`）
  - 代码事实：`f_jit/src/backend/X86Lower.cj:29`（`约定：r15 = ctx、rbp = 帧指针、rsp = 操作数栈顶`）、`X86Lower.cj:1038-1041`（回边用 `noteMemBase(15)` + `emitCtxFlagsToRax()`）、`X86Lower.cj:412`（`movImm(7, hid)` —— `rdi` 在 x86 侧是 helper 的 hid 实参）
  - 同组反证：`f_jit/doc/spec/optimize-loop-safepoint/verify.md:10`（`mov rax,[r15+48] → test rax,8 → jz 跳过`）、`verify.md:27`（字节断言 `498B4730` = `mov rax,[r15+0x30]`）、`f_jit/src/backend/X86Lower_test.cj:65-66`、`f_jit/doc/optimize-call-path.md:435`
- **来源**：存量（快照模式无 diff；三处文本均为该变更 2026-11-27 归档时写入）
- **判据**：review-checklist §13（示例代码不能用 / 文档与实现相反）
- **证据**：静态确定 —— `0x30 = 48` 且 ModRM `47` 的 base 是 `r15`，`498B4730` 只可能是 `mov rax,[r15+48]`；`rdi`（`rdi` 编码 base=7）在该后端的约定是 helper 第一实参，`X86Lower.cj:412/450` 分别用它传 `hid` 与 ctx（`movReg(7, 15)`）。三份文档与代码、测试、同变更 verify 全部矛盾，不是编码歧义。
- **描述**：按 design/proposal/tasks 的序列实现，回边会读 `[hid+48]` 而不是 `ctx.flags`：hid 是小整数（`0x0100+` 量级），解引用会读到非法地址或无关内存，`test` 结果与 deadline 无关。两种后果都错：恒不置位则带 deadline 的循环**永不被中断**（安全点失效，无限循环无法取消）；偶发置位则无期限循环被误中断/误 deopt。同一变更的 verify 与字节断言却是对的，说明只有三份"设计侧"文本没跟着实现走。
- **建议**：三处统一改为 `mov rax,[r15+48]`；同时把 `design.md:10` 的 `X86Lower.cj:1032` 绝对行号改成符号引用（该行现在是 `movQwordCtx(0, -1)` 的 deopt 分支，回边 poll 已移到 `:1035-1045`），避免下次再按行号找不到位置。

### [一般][存量] `optimize-runtime-tls` 的 design 仍以「`ctx.flags` 开 ITER/FAULT 两位」为实现，实际落地方案已被同组 tasks 改成字段门控

- **位置**：
  - 文档：`f_jit/doc/spec/optimize-runtime-tls/design.md:43-55`（§D3 标题「`IterTable` / `HostFault` 用 `ctx.flags` 门控」，`:50` bit4=ITER、`:51` bit5=FAULT）、`design.md:113`（「3. `RuntimeStateFlags_test`：健康调用不置 `ITER/FAULT` 位…」）、`proposal.md:37`
  - 同组反证：`tasks.md:25-26`（T2.4「门控改为**字段检查**（`rs.iters` 为空 / `rs.faults` 为 None）而不是新增 ctx flags 位」）、`tasks.md:51`（T6.1「不新增 ctx flags 位」）、`verify.md:61-63`
  - 代码事实：`f_jit/src/runtime/JitContext.cj:72-86`（`CtxFlags` 只有 `STRICT_FP/TRACE/HAS_LOOP/DEADLINE` 四个常量，无 ITER/FAULT）、`f_jit/src/runtime/RuntimeState.cj:50`（`iters: IterState`）、`:53`（`faults: ?HashMap<...> = None`）；仓内无 `RuntimeStateFlags_test.cj`（`ls src` 无此文件，`grep -rn "RuntimeStateFlags_test" --include=*.cj` 0 命中，该名字只出现在 design.md 自己）
- **来源**：存量（归档时 design 未按 T2.4/T6.1 的决策变更回填）
- **判据**：review-checklist §13（文档承诺与实现相反）+ §14.1（承诺了但没实现）
- **证据**：静态确定 —— 位定义表、消费时机表、新增护栏用例三者都不存在；同组 tasks 与 verify 明确写了相反方案，且代码与 tasks/verify 一致。属"文档内部结论相反"，不是缺信息。同一份 design 的 D2 字段表（`design.md:21-28`）还漏了两个实际存在的字段：`freeWins`（`RuntimeState.cj:47`，池化空闲 `Win`）与 `freeHint`（`:56`，`popFree` 的提示），而 `tasks.md:30`（T3.1）的字段清单里明确有 `freeHint` —— 字段级同样停在实施前版本。
- **描述**：一处设计决策在实施中被替换（flags 位 → 判空字段），但 design 正文、位域表、D7 护栏清单、变异验证（`:119`「去掉 `ITER` 门控（恒清）⇒ …」）全部保留旧方案。后果是双重的：后续若照 D3 实现，会在冻结的 64 B ctx 上多开两位（`CtxFlags` 注释与 `jit-bytecode-m1.md` §1 都按位域冻结管理）；按 D7 去找 `RuntimeStateFlags_test` 的人会扑空，误以为护栏缺失。（同类偏差：`design.md:32` 写 `internal static func current()`，代码 `RuntimeEnv.cj:36` 是 `public static func current()`——按仓内「源码写 public、模块内按 protected 收口」约定等价，不单独计数。）
- **建议**：在 design §D3 顶部加一行决策变更横幅（「实施时改为字段门控：`rs.iters` 空 / `rs.faults` 为 None，不新增 flags 位，见 tasks T2.4/T6.1」），把位域表与 D7 第 3 条删除或标「未采用」，`:119` 的变异说明改指向 `IterLifecycle_test`/`HostFaultTls_test`（verify §5 已是这个口径）。

### [轻微][存量] `optimize-signature-tables` 的 design D2/D4 仍以 `byKey` 键索引写伪代码，与 D1 结论、实现、proposal 表格相反

- **位置**：
  - 文档：`f_jit/doc/spec/optimize-signature-tables/design.md:64-71`（`SigSnapshot { entries; let byKey: HashMap<String, Int32> }`）、`:84-112`（D4 的 `getOrBuild` 全程 `snap.byKey.get(k)` / `copy(s2.byKey)` / `PlanSnapshot(plans, byKey, builds)`）、`design.md:119`（风险表自己写「最终实现不含键，直接复用 `sameShape`」）、`proposal.md:1`（标题「不可变快照 + 结构键索引」）、`proposal.md:26`
  - 代码事实：`f_jit/src/base/HostSignature.cj:111-117`（`SigSnapshot` 只有 `entries`）、`f_jit/src/runtime/SignaturePlan.cj:119-127`（`PlanSnapshot` 只有 `plans`/`builds`）、`SignaturePlan.cj:145-152`（命中路径是 `while + sameShape` 线性扫）
  - 同组反证：`verify.md:8`（「`AtomicReference<PlanSnapshot>`（含 `builds`）」）、`verify.md:23-35`（键索引版 790/554 ns 被否决）
- **来源**：存量（D1 在实施中反转后，D2/D3/D4 的代码块未改，只有「原 D1 草案」一节被标注为不采用）
- **判据**：review-checklist §13（示例/设计描述与实现相反）
- **证据**：静态确定 —— 两个快照类的实际字段与 D2/D4 伪代码逐字段对比即知；`byKey` 在全仓 0 处使用（`grep -rn "byKey" f_jit/src` 无命中）。
- **描述**：D1 用实测（`adapterOf` 349 → 790 ns）否决了键索引，并在 D2/D3 保留了旧 `SigSnapshot` 与 `byKey` 写时复制伪代码；D4 的 `getOrBuild` 也仍以 `byKey` 为第一判据。读者若按 D4 实现，会重现实测到的 −2.3 倍退化，并让 `MAX_ENTRIES` 之外的 `builds:+1` 语义与现状（不缓存但计数）分叉。proposal 的标题/总述句同样停留在被否决的方案上，只有正文 §实施中发现 一段纠正。
- **建议**：D2/D4 的代码块替换为与 `SignaturePlan.cj:141-182` 等价的线性扫版本（或整段加「已否决，仅存档」标记）；`proposal.md:1` 标题改「不可变快照（无键索引）」，`:26` 那句删掉「结构键 `HashMap`」。

### [轻微][存量] `optimize-marshal-rs` 的 verify 用例数与全量数与 tasks 不一致（verify 写于第 5 条用例加入之前）

- **位置**：
  - `f_jit/doc/spec/optimize-marshal-rs/verify.md:44`（「新增 `MarshalRs_test` **4 条**」）、`:46`（「全量 **1235/1235**」）
  - 同组反证：`tasks.md:13-14`（M2.1「`MarshalRs_test` **5 条**」）、`tasks.md:41`（M5.3「恢复后 5 条全绿」）、`tasks.md:45`（M6.1「全量 **1236/1236**」）、`tasks.md:47`（`[ ] M6.3 归档…提交并推送` 未勾选）
  - 代码事实：`f_jit/src/MarshalRs_test.cj:47/59/72/91/105` 五个 `@TestCase`（`valueCallsStayCorrect`、`stringArgRoundTrip`、`hostObjectRoundTrip`、`contractFailureLeavesNoResidue`、`droppedArgIsReleasedByCleanup`）；verify 自己在 `:53` 引用第 5 条 `droppedArgIsReleasedByCleanup`
- **来源**：存量（快照模式；verify 定稿早于 M5 补的第 5 条用例）
- **判据**：review-checklist §13（同一变更内记录互斥）
- **证据**：静态确定 —— 用例数可直接数 `@TestCase`；verify 同文件内 §4 说 4 条、§5 引用第 5 条，自相矛盾。
- **描述**：`MarshalRs_test` 的实际条目是 5 条（第 5 条是变异验证补的），verify §4 的「4 条 / 1235」是补测前的快照；tasks 的「5 条 / 1236」才对。另 M6.3（归档+提交）未勾选，而 `doc/spec/optimize-marshal-rs/` 已镜像存在——归档是否真的完成无法从仓内判定（`待确认`）。
- **建议**：verify §4 回填为 5 条、`:46` 改为 1236/1236；M6.3 补勾或写明当前状态（未归档则注明镜像目录为预放置）。

### [轻微][存量] `optimize-jitcontext-pool` 的 proposal 无「已回退」标记，且引用了不含该断言的测试文件作为口径依据

- **位置**：
  - `f_jit/doc/spec/optimize-jitcontext-pool/proposal.md:1-48`（全文仍以「What Changes / Impact / 预期收益 L1 −7~10%」陈述）
  - 同组反证：`tasks.md:1`（「（实验后 **revert**）」）、`:9-10`（T2.4 不 adopt、T2.5 代码全部回退）、`verify.md:5`（「**不 adopt。**」）、`verify.md:32-41`（回退清单）
  - 证据性错误：`proposal.md:29-36` 称「现有 `ParallelCall_test` / `T40Account_test` 等十余处「`outstanding() == base`」断言」；实际 `f_jit/src/runtime/T40Account_test.cj` 中 `NativeMem` / `outstanding` 出现 **0 次**（`grep -n "NativeMem\.\|outstanding" src/runtime/T40Account_test.cj` 无输出），全仓 `outstanding()` 共 13 处——其中 12 处落在 6 个测试文件（`Lifetime_test`、`ParallelCall_test`、`Q6Acceptance_test`、`runtime/DbgDump_test`、`runtime/HostCallTrampoline_test`、`runtime/JitContext_test`），另 1 处是 `JitContext.cj:61` 的定义）
  - 代码事实（回退已生效，与 tasks/verify 一致）：`f_jit/src/runtime/JitContext.cj:170`（`LibC.malloc<Int64>(count: WORD_COUNT)`）、`:194-203`（`free` 直接 `LibC.free`，无池）；`NativeMem`（同文件 `:1-64`）无 `realMallocCount` / `residentBlocks`（`grep` 0 命中）
- **来源**：存量（proposal 为实验前文档，回退结论只写在 tasks/verify）
- **判据**：review-checklist §13（文档过期 / 与结论相反）、§11（决策依据与事实不符）
- **证据**：静态确定 —— 回退状态、代码现状、`T40Account_test` 内容均可直接核对。
- **描述**：三份文档同目录、proposal 排在最前，读者先看到的是「收益 13.7% 的 malloc/free 占比、预期端到端 −7~10%」，没有任何「已实测否决」的提示；实际结论是池化让 L1 变慢 6–15%。这类"只有结论页纠正、动机页照旧"的目录，最容易被后续复用为「已评估可做」的依据。另外，proposal 用「十余处 `outstanding()==base` 断言」支撑「借出口径」这一关键决策，但点名的 `T40Account_test` 里一条都没有（该文件断言的是 `HandleTable.windowUsed()` 与 T40 账目），决策依据被夸大。
- **建议**：标题改「`JitContext` 线程私有池化（实验后回退，未采纳）」，并在 Why 首段加一行「结论见 `verify.md`：C1 降 14% 无法传导到 L1，两个版本均变慢，代码已回退」；把 `T40Account_test` 换成实际含该断言的文件（`ParallelCall_test` / `Lifetime_test` / `Q6Acceptance_test`）。

### [轻微][存量] `optimize-signature-tables` 的 tasks 点名 `SignatureRegistryVerification` 测试类，仓内不存在

- **位置**：
  - 文档：`f_jit/doc/spec/optimize-signature-tables/tasks.md:15`（S2.1「`SignatureRegistryVerification` 六条」）、`:24`（S2.3 又写「`JitHost_test` / `Signature*`」，口径不同）
  - 代码事实：六条用例实际在 `f_jit/src/SignatureTableConcurrency_test.cj`（类 `@Test` 于 `:35`，用例 `registerIsIdempotent:49`、`idsAreDistinctAndOrdered:58`、`classNameDistinguishes:71`、`lookupsAgree:85`、`concurrentRegisterAndFind:100`），加 S2.2 的 `planIsBuiltOnce:155`、`planRespectsSwitch:169` 共 7 条
  - 同组反证：`verify.md:9`（新增文件写的是 `src/SignatureTableConcurrency_test.cj`）、`verify.md:39-47`（7 条用例名与该文件逐一对应）
- **来源**：存量（任务清单按设计时的假想类名写，落地时合并成一个测试类后未回填）
- **判据**：review-checklist §13（名称与源码不符）
- **证据**：静态确定 —— 全仓 `grep SignatureRegistryVerification` 在 `.cj` 中 0 命中，该名字只出现在 `tasks.md` 自己。
- **描述**：按 tasks 去检索「六条护栏」会得到「文件不存在」，从而误判 S2.1 未落地；实际六条全在，只是与 `SignatureTable` 的四条合并在同一个测试类里。同一页的 S2.3 又换成通配 `Signature*`，同一文档内三种口径。
- **建议**：S2.1 改为「`SignatureTableConcurrency_test` 前六条」，S2.3 的名册改为实际存在的 `JitHost_test` / `HostSignature_test` / `SignatureTableConcurrency_test`，与 verify 的文件名口径统一。

<!-- 第 20 部分 -->

### [一般][存量] `AdapterRegistry` 生产路径零接线：整类只在测试里被调用，`size()` 连测试都不用

- **位置**：`f_jit/src/AdapterRegistry.cj:27`（类声明）、`:33`（`register`）、`:50`（`lookup`）、`:58`（`removeUnit`）、`:74`（`size`）
- **来源**：存量（`git blame` 显示 `048fb7624f 2026-10-18` 引入类，`328c7d32e1` 引入字段）
- **判据**：review-checklist §1「注册了但永不触发」「非 public 顶级声明里的成员无使用即死代码」+ §14.1「接线缺失」
- **证据**：静态确定 ——
  1. 全仓（排除 `.worktrees`）`grep -rn "AdapterRegistry" --include=*.cj` 仅命中 `AdapterRegistry.cj` 自身、`AdapterRegistry_test.cj`、`Root.cj:21`（注释）三处，**没有任何生产代码写入或读取**；
  2. `design-m1.md:862` 把 `AdapterRegistry` 定义为「`(单元指纹, fnId, T)` → 单态化适配器」，`design-m1.md:915` 写明调用关系是「call 第 5 步；卸载」，`design-m1.md:961` 写「跨模块/动态 → AdapterRegistry 运行期校验 → 19」；
  3. `size()`（`:74`）在测试与生产代码中均无调用者 —— 属于「protected 类里的 public 成员，全项目无使用」。
- **描述**：`protected class` 对外不可见，其 `public` 成员只是包内放宽。该注册表当前完全靠 `AdapterRegistry_test.cj` 自证：测试注册、测试查找、测试移除，生产路径（`Compiler.compile` / `JitFunction.call` / `unload`）一次都没接线。对照 `design-m1.md:961`，`call` 第 5 步的「跨模块/动态 T 一致性运行期校验」实际由别处完成（`CallMarshal`/`isInstanceOfHost` 等），本类没有承担其设计的职责。
- **建议**：二选一并写清结论 ——（a）按设计接线：在 `call` 第 5 步失败分支与卸载终态各调一次 `register`/`removeUnit`；（b）确认职责已由 `CallMarshal` 承担则删除本类与 `AdapterRegistry_test.cj`，同步 `design-m1.md:862/915/961` 的描述。无论哪种，都应补 `resetForTest()`——同包的 `SignatureRegistry` 已有同名复位钩子（`HostClosureAdapter_test.cj:62` 处约定「每个用例结束都要 resetForTest」），本类缺这个钩子，正是它测试污染的原因（见下一条）。

### [一般][存量] 根包再导出缺 `CallContext` 与 `InterruptedException`，而二者都在 public 调用契约里

- **位置**：`f_jit/src/Root.cj:23-46`（再导出清单，缺这两项）；契约侧 `f_jit/src/JitFunction.cj:159`（`public func call<T>(args: Array<Any>, options: CallContext)`）、`f_jit/src/JitReport.cj:41`（`throw InterruptedException(...)`）
- **来源**：存量（`Root.cj` 与 `JitFunction.cj` 均为既有文件，快照无 diff）
- **判据**：review-checklist §13（文档承诺与实现不符）+ §14.1（公开 API 能力接不上）
- **证据**：静态确定 ——
  1. `design-m1.md:923` 明确承诺 `public import fountain::f_jit.base.*` 再导出含 `CallContext`（原文列举「…SourcePos、CallContext、SourceUnit…」）；
  2. 实际 `Root.cj:23-46` 是逐项 `public import`，清单里没有 `CallContext`，也没有 `InterruptedException`（`grep "^public import" f_jit/src` 全量 19 行，无此二者）；
  3. 仓内用例已实证该缺口：`AnyBridgeCall_test.cj:22` 必须额外写 `import fountain::f_jit.base.CallContext` 才能调用带选项的重载。
- **描述**：下游只写 `import fountain::f_jit.*` 时，无法构造 `CallContext(deadline: …)`，也就**用不了** `call<T>(args, CallContext)` 这条公开重载（deadline 中断是本模块对外承诺的能力）；`deadline` 到期抛出的 `InterruptedException`（`JitReport.cj:41`，类定义 `base/InterruptedException.cj:26`）同样无法按名捕获，只能退化成 `catch (e: Exception)`。这与 `design-m1.md:27`「`import fountain::f_jit.*` 后能做编译 → 调用 → 卸载」的目标直接冲突。`SourceUnit` / `TypeToken` / `Version` 也在设计清单里但当前没有公开签名承载（`Compiler` 只剩 `compile(source: String)`，`CompileOptions.verMajor` 是 `UInt16`），故只报 `CallContext` / `InterruptedException` 两项确有后果的缺项。
- **建议**：在 `Root.cj` 补 `public import fountain::f_jit.base.CallContext` 与 `…base.InterruptedException`（并补一条只导根包的用户面用例，参照 `surface/FacadeSurface_test.cj` 的做法）；若刻意不导出，则改 `design-m1.md:923` 与 `doc` 的表述，别让文档承诺与可见性相反。

### [一般][存量] `BaseVisibility_test` 无法验证它自称守护的「再导出清单不缺项」

- **位置**：`f_jit/src/BaseVisibility_test.cj:20`（`import fountain::f_jit.base.*`）、`:28-31` 与 `:36-41`（自述目的）
- **来源**：存量
- **判据**：review-checklist §3（契约测试失效，等价「看起来能编译」）+ §13（文档/注释与实现不符）
- **证据**：静态确定 ——
  1. 文件头写「缺任一项本文件即编译失败」，但测试自己对 `base` 做了通配导入（`:20`），`CallContext`、`SourceUnit`、`TypeToken`、`Version`、`DiagCode` 等符号**无论根包是否再导出都能解析**，断言恒成立；
  2. 项目自己在别处已承认这一点：`f_jit/src/surface/FacadeSurface_test.cj:18-23` 的注释写「根包内的文件可以自己 `import …base.*`（那样测不出再导出缺失，**M1 的 `BaseVisibility_test` 正是如此**）」，并另建独立包做真正的用户面探针；
  3. 结果就是上一条的缺口长期未被这张「护栏」发现：`FacadeSurface_test` 只钉住注册协议 8 个符号，`CallContext` / `InterruptedException` 两边都没覆盖。
- **描述**：这条用例实际只证明「base 包里的这些声明存在且可用」，证明不了「根包把它们再导出了」。它守的是用户面冻结验收（S6.11），但目前是假绿；同时文件头 `:28-31` 的「用户面清单」已与 `Root.cj` 实际清单不符（少了 `DiagCode`、`DummyDiagnosticsSink` 与注册协议 7 个类型，多了实际未导出的 `CallContext`/`SourceUnit`/`TypeToken`/`Version`）。
- **建议**：把该用例迁到独立包（如 `surface`）并改成只 `import fountain::f_jit.{…}` 的显式列举，让缺项变成编译错误；文件头清单改为引用 `Root.cj` 而不再手抄一份。若保留在根包，则把注释改成「仅验证 base 声明可用」，别再声称守再导出。

### [一般][存量] 规格承诺「卸载中到达的同键编译会等待后重编」，设计与实现都不做

- **位置**：`f_jit/doc/spec/refine-f-jit-unload-api/specs/f-jit-facade-bridge/spec.md:49`（`SHALL`）；反证 `…/design.md:23-27`（D3 明确不在本次范围）、`…/verify.md:43-47`（已知边界）
- **来源**：存量
- **判据**：review-checklist §13「规格与实现漂移」+ §14.1「承诺了但没实现」
- **证据**：静态确定 —— 规格原文要求「卸载期间到达的同键编译 SHALL **等待卸载完成后**按未命中重新编译并产出新句柄」；同一变更的 `design.md:25` 写「`state == 1`（卸载中）期间到达的同键编译，仍可能从缓存拿到正在卸载的单元并立即被 19 拒绝」，`verify.md:45` 重复同一结论并说明「要彻底解决需要给缓存项引入代次/状态维度」。即：规格的验收条款比落地范围宽，且**没有随范围收窄而改写**。同一句还镜像在 `doc/spec/f-jit-m1/specs/f-jit-facade-bridge/spec.md` 与 `doc/spec/jit-closure-unload-cascade/…/spec.md`（范围外，同根因）。
- **描述**：并发「卸载 + 同源编译」的窗口内，编译方会拿到一个正在卸载的单元并在调用时收到 19（契约类错误），而不是排队到卸载完成后拿到新单元。属**瞬态失败**，不是数据损坏；但按规格它是失败场景，按实现它是预期行为。两者不一致会让下一轮按规格写的验收用例必然红。
- **建议**：二选一——（a）把规格该句改成「**终态之后**到达的同键编译 SHALL 未命中重编；卸载中窗口内到达的编译 MAY 以 19 失败」，与 `design.md` D3 对齐；（b）立项做「缓存项代次/状态」维度，落地后再恢复现有 `SHALL`。别让 `SHALL` 长期悬空。

### [轻微][存量] `register` 对同一键重复登记会重复入 `units` 列表：与「同键覆盖；幂等」注释不符，`removeUnit` 计数虚高

- **位置**：`f_jit/src/AdapterRegistry.cj:40`（无条件 `list.add(k)`）、`:67`（`removeUnit` 返回 `list.size`）
- **来源**：存量
- **判据**：review-checklist §11「语义与命名/注释不符」+ §5「无界容器（潜在）」
- **证据**：静态确定 —— `register`（`:33-47`）对 `adapters[k]` 是覆盖写，但对 `units[u]` 是**追加**，没有去重；同一 `(fingerprint, fnId, tName)` 登记两次后 `units` 里就有两个相同 `k`，`removeUnit` 返回 2（实际只有 1 条适配器），列表也会随重复登记线性增长。
- **描述**：注释声称「注册（同键覆盖；幂等）」，覆盖与幂等只对 `adapters` 成立。若按设计接线到「每次调用前 pin 一次」的路径，重复登记会让 `units` 无界增长（§5 无界容器），`removeUnit` 的返回值也不再是「移除条数」。当前该类无生产调用者，故只按轻微计；一旦接线即升级为一般。
- **建议**：登记前先判 `list.contains(k)`，或把 `units` 的值换成 `HashSet<String>`；`removeUnit` 用「实际从 `adapters` 移除成功的次数」返回，而不是 `list.size`。

### [轻微][存量] `p0_6_deadlineRestoredAfterCall` 的空 `catch` 让用例在「根本没中断」时也能通过

- **位置**：`f_jit/src/AnyBridgeCall_test.cj:145-148`
- **来源**：存量
- **判据**：review-checklist §3「静默吞异常」+ 用例有效性
- **证据**：静态确定 —— `try { f.call<Int64>([Int64(100000000)], expired) } catch (_: InterruptedException) {}` 之后唯一断言是 `RuntimeEnv.deadlineNanos == -1`；若实现**压根没抛**中断（例如 −2 生产点回归），`f.call` 会跑完 1e8 次循环、`finally` 仍把期限恢复成 −1，断言照旧通过——用例名承诺的「内层调用（成功或中断）返回后期限恢复」中的「中断」分支没有被验证。
- **描述**：这条用例的设计意图（期限栈式恢复）只在「外层无期限 + 内层抛中断」这一组合下成立，而该组合恰由空 `catch` 抹掉了可观测证据。「中断确实发生」目前只由另一条用例 `p0_6_deadlineInterruptsLoop`（`:120-134`）覆盖，本用例的回归价值因此打折。
- **建议**：`catch (_: InterruptedException) { interrupted = true }` 后 `@Assert(interrupted, true)`；或把内层调用改成有界次数 + 断言抛出类型与 site。

### [轻微][存量] 三个用例文件对全局静态状态无复位或复位不彻底

- **位置**：`f_jit/src/AdapterRegistry_test.cj:77-78`（只移除 `100`/`103`，`101`/`102` 留在静态表里）；`f_jit/src/AnyHostCast_test.cj:100`（`HandleTable.resetForTest()` 清空全局句柄表且无 `finally` 恢复）、`:121-122`（对全局 `slotCount`/`liveCount` 断言）
- **来源**：存量
- **判据**：review-checklist §12.1（共享可变状态）+ 用例可重复性
- **证据**：静态确定（残留事实）；「是否真导致 flaky」需实测 —— 未知 CI 上 `cjpm test` 的 `--parallel` 取值
- **描述**：`AdapterRegistry` 没有 `resetForTest()`（同包 `SignatureRegistry` 有），用例只能靠「删掉自己造的键」收尾，`concurrentRegisterAndLookup` 漏了 `101`/`102` 两个指纹；`AnyHostCast_test` 则整体清空进程级 `HandleTable`（`resetForTest` 会把 `totalSlots` 复位为 1，`HandleTable.cj:1307`），若与持活句柄的用例并发执行，会造成假失败或假通过。当前项目默认 `--parallel 1`（`doc/spec/test-f-jit-parallel-calls/design.md:36`），所以现实风险低。
- **建议**：给 `AdapterRegistry` 加 `resetForTest()` 并在每条用例的 `finally` 里调用；`AnyHostCast_test` 的全局复位改为用例级独立上下文（或统一在 `@BeforeAll/@AfterAll` 复位），并把并行度假设写进用例注释。

### [轻微][存量] 两份 spec 目录内的统计口径互相冲突（变异结论、改名处数）

- **位置**：`f_jit/doc/spec/optimize-type-cache/verify.md:44-49` 与 `…/tasks.md:32-36`；`f_jit/doc/spec/refine-f-jit-unload-api/proposal.md:29`、`…/test-plan.md:12`、`…/tasks.md:5`、`…/verify.md:15-22`
- **来源**：存量
- **判据**：review-checklist §13（同一变更内文档自洽性）
- **证据**：静态确定 ——
  1. `optimize-type-cache`：`tasks.md:35-36` 写变异「`refEq` 恒 true ⇒ `alternatingTypesDoNotCross` ERROR，已恢复，重跑绿」，而 `verify.md:49` 同一变异写「待补（见下）」，且文中并无「见下」小节（§5 直接是「影响文件」）；`design.md:36-38` 的护栏描述用 `Int64` vs `Probe`，`verify.md:40` 用 `Int64` vs `Bool`。
  2. `refine-f-jit-unload-api`：同一个「`close()` 改名处数」有四个值 —— `proposal.md:29`=18、`test-plan.md:12`（16 处 + 3 条具名）=19、`tasks.md:5`=20、`verify.md:15-22` 表内合计 21。
- **描述**：结论型文档（tasks / verify）对同一实验给出相反状态，会让下一轮「按 verify 补数据」重复劳动；改名处数的四个值使「剩余调用点是否清零」无法机械核对。两处都不影响代码行为。
- **建议**：以 `verify.md` 为唯一结论源，`tasks.md` 只勾选状态；改名处数统一取 `grep -c` 的实测值并注明统计命令。注：`refine-f-jit-unload-api` 的 `unloadFn` 旧名属归档惯例（`align-jitfunction-close-naming/verify.md:16` 已说明历史归档不回改），**不判**。

<!-- 第 21 部分 -->

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

<!-- 第 22 部分 -->

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

<!-- 第 23 部分 -->

### [严重][存量] 并发 `close` 的超时回退无条件把状态写回 0，可让已卸载单元重新变为「可调用」

- **位置**：`f_jit/src/JitFunction.cj:246-251`（单元级）、`f_jit/src/JitFunction.cj:318-324`（闭包级，同一根因）
- **来源**：存量（快照模式无基线）
- **判据**：checklist §12.1（共享可变状态「检查-然后-写入」非原子）/ §11（并发正确性）；README:592-596 承诺「`close(timeoutMs)` 超时则回退到可用态」，回退必须只在「本次 close 仍是 Unloading 的持有者」时发生
- **证据**：静态确定 —— 超时分支是 `synchronized(this.mtx) { this.state = 0 }`，不校验当前状态是否仍为 1（Unloading）。两个线程并发 `close` 时存在如下交错：A 的 `spins >= limit` 成立后阻塞在 `mtx` 上；B 拿到 `mtx` 置 `state = 2` 并在锁外执行 `release()`（释放码内存，`JitFunction.cj:278-285`）；A 随后拿到 `mtx` 把 `state` 覆盖成 0 并返回 `false`。此后 `enterUnit`（`:198-206`）看到 `state == 0` 放行，调用方在**已释放的机器码**上执行 ⇒ 崩溃 / 未定义行为。闭包侧同理：`e.state = 0` 覆盖 `unloadClosure` 已置的终态 2（`:327-331` 已执行 `e.group.releaseAll()`），此时靠 `callLocked` 的 `HandleTable.isLiveHandle(this.closureId)`（`:559`）才降级为 19（句柄槽若被复用则仍不确定），属于偶然缓解而非同步
- **描述**：状态机 `0 Ready → 1 Unloading → 2 Unloaded` 的回退迁移缺少「来源校验/世代号」，因此「一次超时 close」与「一次成功 close」并发时可以把终态改写回 Ready。触发条件：同一 `JitFunction` 被两个线程以不同 `timeoutMs` 调用 `close`（例如 `Resource.close()` = `close(0)` 与运维侧 `close(5000)` 同时发生）。
- **建议**：回退前校验 `if (this.state == 1) { this.state = 0 }`（成功路径置 2 后不再回退），或给每次 close 分配递增 token，回退时比对 token；`unloadClosure` 同样对 `e.state` 加同一守卫。补一条并发用例：两线程分别 `close(0)` / `close(50)`，断言终态只能是 2 且之后调用一律 19。

### [一般][存量] `close(timeoutMs)` 用「自旋次数」代替毫秒超时，且纯自旋占满一核

- **位置**：`f_jit/src/JitFunction.cj:237-253`（`limit = timeoutMs * 100000`）、`f_jit/src/JitFunction.cj:309-326`（闭包侧同形）
- **来源**：存量
- **判据**：checklist §11（语义与命名/契约不符）、§6.2（临界区反复取锁形成争用）
- **证据**：静态确定（计量单位是循环次数，不是时间）+ 需实测（实际墙钟相对 `timeoutMs` 的放大倍数）
- **描述**：形参名与 README:595「超时则回退」都表示时间预算，实现却是「每 1 ms 折 100 000 次 `synchronized` 取锁 + 读 `active`」。单轮取锁/放锁在无争用时约数十纳秒，`timeoutMs = 5000` 实际可自旋数十秒；机器越慢、核越忙，同一 `timeoutMs` 的墙钟差异越大。在此期间该线程 100% 占用一个核，并持续与正在 `exitUnit` 的调用方抢同一把 `mtx`，把「等排空」变成「抢锁」。
- **建议**：用 `MonoTime.now() + Duration.millisecond * timeoutMs` 作真截止时间，循环里用 `sleep`（毫秒级退避）或条件变量等待 `active == 0`；`timeoutMs <= 0` 保留「只查一次」语义。

### [一般][存量] `parseFnType` 不跟踪括号/泛型深度，泛型与高阶闭包签名被错误拆分

- **位置**：`f_jit/src/JitFunction.cj:795-852`（关键：`:836` 仅按 `,` 切分；`:800-803` 前缀剥离；`:847` 返回类型取 `arrow + 2`）
- **来源**：存量
- **判据**：checklist §10（正确性/边界）、§11（边界解析）
- **证据**：静态确定
- **描述**：`callForFn<Fn>` 用 `TypeInfo.of<Fn>().name` 反解签名，解析器只找**第一个** `->`、只按裸逗号切形参、不跳过 `<>`/嵌套括号：
  1. `(HashMap<String, Int64>) -> Int64` 会被切成两个形参 `HashMap<String` 与 `Int64>`，`codeOfTypeName` 对前者返回 `MAP`、对后者落到兜底 `HOST_OBJECT` ⇒ 包装器认为该闭包有 2 个形参，`w.call<Int64>([m])` 恒报「实参个数不符」（`:564-566`）；
  2. `((Int64) -> Int64) -> Int64` 的第一个 `->` 属于内层闭包，`retName` 被取成 `Int64) -> Int64` ⇒ 返回码落到 `HOST_OBJECT`，`call<Int64>` 报「T 与返回类型不符」（`:571-577`）。
  两条路径都不会静默算错值，但对合法签名一律误判为契约错误，属「合法输入被拒」。
- **建议**：解析时维护 `<>`/`()` 深度，仅在深度 0 处按 `,` 与 `->` 切分；解析失败（含残留 `>`/`)`）直接返回 `None` 退化为动态签名（`:517-518` 已支持），不要让 `codeOfTypeName` 的兜底把坏串记成 `HOST_OBJECT`。

### [一般][存量] 名字 → `LocalType` 映射有两份实现且已漂移（`JitClosureId` 只在一份里）

- **位置**：`f_jit/src/JitFunction.cj:895-927`（`codeOfTypeName`）与 `f_jit/src/JitFunction.cj:945-1010`（`computeTypeCode`，`JitClosureId` 在 `:983`）
- **来源**：存量
- **判据**：checklist §2（重复逻辑：同一张码表两种写法，差异造成行为漂移）
- **证据**：静态确定 —— `:907` 的注释自称「与 `localTypeOf` 同表」，但 `codeOfTypeName` 缺 `JitClosureId → CLOSURE`，兜底把任意未知非空名字记成 `HOST_OBJECT`（`:922-924`），而 `computeTypeCode` 对非类/接口类型返回 `None`（`:1005-1009`）
- **描述**：同一份「类型名 → 码」知识存在两套判定，且判定结果不一致：闭包签名里出现 `JitClosureId`（返回嵌套闭包、或把闭包 id 当形参）时，`parseFnType` 记 14，而 `call<JitClosureId>` 的 `localTypeOf` 记 12 ⇒ 包装器一创建就注定在 `:573` 报「T 与返回类型不符」；`Int32`/`UInt8` 一类不可封送类型在签名侧被记成 14 而不是被拒。
- **建议**：合并为单点表（`name -> ?UInt16`），`codeOfTypeName` 与 `computeTypeCode` 都只做「取 simple name + 查表 + 类/接口兜底」，兜底逻辑只保留一处；补 `JitClosureId` 与「未知类型返回 None」两条断言。

### [一般][存量] 卸载逐出前的窗口：编译缓存仍返回已进入终态的单元

- **位置**：`f_jit/src/JitFunction.cj:256-265`（`state = 2` 之后才 `CompileCache.remove(k)`，同一临界区内）；读取侧 `f_jit/src/CompilePipeline.cj:61-62`、`:97-98`（命中即返回，不校验 `isClosed()`）
- **来源**：存量
- **判据**：checklist §11（并发正确性：陈旧引用发布）、§12.1
- **证据**：静态确定（窗口存在）；发生频率需实测
- **描述**：`close` 先置终态再从缓存删除，而缓存查找只取缓存锁、不与单元锁互斥。窗口内另一线程 `Compiler.compile(同源)` 命中 `ready[key]` 拿到该单元并直接返回（`CompilePipeline.cj:62`），随后每次 `call` 都以 19 失败，且该调用方没有任何「已卸载则重编」的重试路径。窗口只有几条指令，但在「编译 + 卸载」交替的负载下会产生可观测的偶发 19。
- **建议**：查找侧拿到单元后校验 `isClosed()`，已关闭则按未命中重走管线；或让 `close` 先从缓存摘除再置终态（摘除后不可能再被发布），并把 `state` 读取纳入同一同步点。

### [轻微] `callLocked` 的 `options` 形参从未被读取

- **位置**：`f_jit/src/JitFunction.cj:555-556`（形参），全函数体内零引用（`options` 仅出现在 `:159/:164/:171` 与签名处）
- **来源**：存量
- **判据**：checklist §1（死参数 / 读了不用）
- **证据**：静态确定（`grep -n "options" JitFunction.cj` 只有 4 处，`callLocked` 内无 `options.`）
- **描述**：deadline 实际由 `call` 写入 `rs.deadlineNanos`，`callLocked` 只读 `rs`。因此 `callForFn` 传 `DEFAULT_CONTEXT`（`deadline = None`）**并不**表示「无期限」，而是继承线程当前 deadline——读者按形参推断会得出相反结论。
- **建议**：删除该形参，或在 `callLocked` 内自行应用 `options.deadline` 并让 `call` 不再改 `rs`；同时在 `callForFn` 处注释「沿用线程 deadline」。

### [轻微] 两处注释与声明错位（复制粘贴残留）

- **位置**：`f_jit/src/JitFunction.cj:91-94`（「本单元的 user helper 表…」注释挂在 `EMPTY_CELLS` 上，真正的 `helperEntries` 在 `:94` 无注释）、`f_jit/src/JitFunction.cj:390-392`（「便捷重载（默认为不等待活跃调用）」挂在 `isJitBacked()` 上）
- **来源**：存量
- **判据**：checklist §10（可读性/可维护性）
- **证据**：静态确定
- **描述**：`isJitBacked` 上方两条相邻注释，第一条描述的是已不存在的重载；字段区同理。按文档读代码会把 `EMPTY_CELLS` 误认成 helper 表。
- **建议**：把 helper 表注释移回 `helperEntries`，删除「便捷重载」这行残留注释。

### [轻微] 宿主异常路径直接 `printStackTrace()` 到标准输出，不走 `f_log`、不可关闭

- **位置**：`f_jit/src/JitReport.cj:44-48`
- **来源**：存量
- **判据**：`fountain-baseline.md` §6（日志走 `f_log`，热点/库内不直接打印）
- **证据**：静态确定
- **描述**：每个 `HOST_EXCEPTION`（21）都会打印一次完整仓颉栈，输出目标由运行时决定、调用方无法重定向或关闭；库被嵌入服务端后表现为进程 stdout 污染，且栈里可能含业务数据。
- **建议**：把原始异常交给上层报告构造器（`JitException.cause` 已有字符串通道），或注入可配置的 sink；至少加一个开关，默认关闭。

### [轻微] 基准与门禁用墙钟计时，易受 NTP/负载影响

- **位置**：`f_jit/src/PerfAdapter_test.cj:82`、`:91`（`DateTime.now()`）、`:102-105`（3× 时序门禁）；`f_jit/src/ParallelThroughput_test.cj:36-38`（`DateTime.nowUTC()` 计算 wall）
- **来源**：存量
- **判据**：checklist §6.1（基准口径：同环境、可复核）；同仓 `LoopSafepoint_test.cj:82` 已用 `MonoTime` 作正例
- **证据**：需实测（共享 VM 上的抖动幅度）
- **描述**：墙钟可被校时跳变，且 `DateTime` 分辨率/开销高于 `MonoTime`；`PerfAdapter_test` 还把「类型化 adapter 至少快 3×」写成单测硬门禁，共享构建机负载高时属于假失败源（文件注释自己也承认只在 release 实测过 36×）。
- **建议**：统一用 `MonoTime.now()`；把 3× 门禁移到 `cjpm bench` 或加环境变量开关（默认只打印不失败）。

### [轻微] 测试内的死局部变量与无意义重复谓词

- **位置**：`f_jit/src/JitClosureLifecycle_test.cj:172`（`let box = ArrayList<JitFunction>()`）、`:180`（只 `add`，全用例无读取）；`:197`、`:199`、`:203`（`x.isClosed() && x.isClosed()` 同一谓词连写两次）
- **来源**：存量
- **判据**：checklist §1（读了不用）、§2（无差异重复）
- **证据**：静态确定
- **描述**：`box` 是从另一个用例（`:111-120`）复制过来的残留；`isClosed() && isClosed()` 让 `wrapperStatePredicatesAgree` 的「状态谓词一致」看起来在比较两个来源，实际只有一个来源。
- **建议**：删除 `box`；重复谓词改为对「自释放」与「级联释放」两条真实不同路径各取一次。

### [轻微] `HOST_EXCEPTION`(21) 的异常旁路分支无任何用例覆盖

- **位置**：`f_jit/src/JitReport.cj:43-53`（`exceptionOf` + `takeCause` 分支）对照 `f_jit/src/JitReport_test.cj:124-154`（1–23 逐码用例）
- **来源**：存量
- **判据**：checklist §10（异常路径未覆盖）；`fullPositiveCodeRangeMapsToJitException` 走 21 时没有 `HostFault` 记录，只覆盖了「无 cause」的退化分支
- **证据**：静态确定（用例未构造 `HostFault.record` + 未断言 `cause.isSome()`）
- **描述**：`throwJit` 里唯一「打印栈 + 通过 cause 带出原文」的分支恰好没有被测；该分支正是 M2 桥接最易回归的地方（异常类型、`cause` 是否被取走、重复打印）。
- **建议**：补一条用例：先 `HostFault.record(ctx, ex)` 再以 21 收尾，断言 `e.cause.isSome()`、`takeCause` 只生效一次。

<!-- 第 24 部分 -->

### [一般][存量] `mapType` 按简单名前缀判定容器/区间类型，用户类名撞前缀即被误映射成句柄码

- **位置**：`f_jit/src/ReflectRegistrar.cj:792`、`f_jit/src/ReflectRegistrar.cj:795`、`f_jit/src/ReflectRegistrar.cj:798`
- **来源**：存量（`git blame` → `bb87fa03af`，2026-10-19）
- **判据**：checklist §11「契约与实现不符」+ 本模块专项「typecode 分支表正确性」
- **证据**：静态确定 —— `let n = info.name`（`mapType` 用的就是**简单名**），随后 `n.startsWith('Range')` → `LocalType.RANGE`（8）、`n.startsWith('ArrayList')` → `LIST`（10）、`n.startsWith('HashMap')` → `MAP`（11），没有分隔符或包名约束。
- **描述**：`ClassRegistry.isBuiltinName` 只拦住了 `Range`/`ArrayList`/`HashMap` 这几个**精确**名字（`f_jit/src/ClassRegistry.cj:145-153`），所以 `RangeFinder`、`ArrayListCache`、`HashMapShard` 这类类名可以正常注册（非内建、非关键字）。注册时 `mapType` 会把它们的字段/参数/返回码判成 8/10/11，而运行期 `hostGetField` 会按 `fieldToken(code)` 期望 `TypeToken.RANGE/LIST/MAP`（`f_jit/src/runtime/HostField.cj:196-202`）→ 类型不符 → `failWith(HELPER_PANIC)`（99）。后果是「类注册成功、字段访问恒 99」，且诊断里看不到任何线索。
- **建议**：改成精确匹配 —— `n == 'Range'`，或对泛型形态用 `n.startsWith('Range<')`；更稳的是用 `info.pkgName`（若 SDK 暴露，需先查 `std.reflect` 文档确认签名）限定 `std.core`/`std.collection` 后再判前缀。`isRefCode` 同理应改为复用 `LocalType.isHandle`（见下条重复逻辑）。

### [一般][存量] 父类字段并入子描述符后，无 `@JitBind` 的反射访问器在子类实例上必然抛异常 → 21

- **位置**：`f_jit/src/ReflectRegistrar.cj:541`（`pending.add` 注册）、`f_jit/src/ReflectRegistrar.cj:545`（`getter`）、`f_jit/src/ReflectRegistrar.cj:548`（`member.getValue(o)`）
- **来源**：存量（`git blame` → `069e6e37c1`，2026-10-23）
- **判据**：checklist §11「契约与实现不符」；本模块专项「句柄与资源生命周期 / 桥接正确性」
- **证据**：静态确定 —— 该访问器的 `accepts` 是 `isInstanceOf(o, rowAncestry)`，`rowAncestry[0]` = **子类**名，故任何子类实例都会命中；而 `getter` 回退路径是父类 `InstanceVariableInfo.getValue(o)`。同一个仓库里的用例自己固定了这条硬限制：`f_jit/src/ReflectRegistrar_test.cj:423-441`（`reflectGetValueRejectsSubclassInstance`）断言 `acc.getter(admin)` 抛 `IllegalTypeException`。
- **描述**：`ClassRegistry`/`Descriptor` 层面「子类可访问父类字段」是成立的（`mergeAncestorFields` 的注释 `f_jit/src/ReflectRegistrar.cj:499-504`），但执行层对纯反射访问器做不到。`hostGetField` 把该异常记为 `HostFault` 并返回 21（`f_jit/src/runtime/HostField.cj:163-170`），所以脚本读子类实例的继承字段会稳定拿到 `ERR_HOST_EXCEPTION`，而不是值，也不是「字段不存在」这类可诊断错误。只有宿主给了 `@JitBind`（`typedField` 命中）时才真正可用。
- **建议**：在 `mergeAncestorFields` 里对 `typed == None` 的父类字段**不注册**并记 `RegistrationSkipped`（理由写清「反射 getValue 不支持子类实例，请给父类加 @JitBind」），让失败提前到注册期；或在描述符里标记「仅 typed 可用」，由前端在编译期拒绝。当前形态等于把注册期可判定的限制推迟成运行期 21。

### [一般][存量] 性能门禁写在单元测试里，且两臂相减的算法在噪声下会假失败

- **位置**：`f_jit/src/PerfOverride_test.cj:110`（假失败记录）、`f_jit/src/PerfOverride_test.cj:121-131`（`rc`/`oc` 钳到 1）、`f_jit/src/PerfOverride_test.cj:152-155`（`median >= 800` 即 `@Fail`）；`f_jit/src/PerfM2_test.cj:104`、`f_jit/src/PerfM2_test.cj:121-124`
- **来源**：存量（`git blame` 落在 2026-10-19/20 的性能用例提交）
- **判据**：checklist §6.1（比值必须同环境对照、不能只看一次结果）+ §11「错误处理/判定不对称」
- **证据**：静态确定 —— 用例注释自己记录过假失败（`PerfOverride_test.cj:111`：「实测出现过比值 0.82 > 0.80 的假失败」）。算法上：`let rc = if (r > b) { r - b } else { 1 }`，一旦反射臂因调度抖动比空壳臂还快（`r <= b`），`rc` 被钳成 `1`，`q = oc * 1000 / 1` 必然 ≫ 800 → 直接 `@Fail`；`oc` 侧同理。即「噪声导致差值为负」被转成「确定性的门禁失败」。
- **描述**：`PerfOverride_test` / `PerfM2_test` 分别对 `JitFunction.call<T>` 的 6–9 µs 量级净成本、`user helper` vs 宿主闭包比值做硬门禁。这类比值对 CPU 频率、同机其他进程、GC 时机高度敏感，而它们跑在普通 `cjpm test` 里（不是 `cjpm bench`），CI 上并行跑其他用例时抖动更大；一旦假红，需要人工辨识，长期会让人习惯性重跑，门禁失效。`PerfM2` 的 1×–10× 区间相对宽松，风险低于 `PerfOverride` 的 800/1000 阈值。
- **建议**：把比值门禁移到 `cjpm bench -O2` 的独立作业（同机、同输入、中位数 + 离散度），单元测试只保留「两臂都能跑通且结果正确」；若必须留在用例里，给 `rc`/`oc` 加绝对下限（如 `rc < rounds * 200ns` 判为「无效测量」并跳过判定而非 `@Fail`），并对失败做一次重测再判。

### [轻微][存量] 死代码：无引用的 `sceneOk`、未使用的 import、写了不读的局部变量

- **位置**：
  - `f_jit/src/Q6Acceptance_test.cj:297-299`（`private static func sceneOk`：全仓 `grep -rn "sceneOk" f_jit/src` 仅命中定义处）
  - `f_jit/src/Q6Acceptance_test.cj:20`（`import std.reflect.TypeInfo`：文件内 `TypeInfo` 只出现在第 411 行注释里）
  - `f_jit/src/Q6Acceptance_test.cj:395`+`:400`（`var kind` 赋值后从不读取，断言只用 `msg`）
  - `f_jit/src/Q6Acceptance_test.cj:866`（`let base = HandleTable.liveCount()` 之后直接 `resetForTest()`，`base` 未读）
  - `f_jit/src/ReflectRegistrar.cj:172`+`:198`（`let rowName = name` 只为第 198 行 `let _ = rowName` 存在）
  - `f_jit/src/RuntimeStateIsolation_test.cj:91-95`、`f_jit/src/RuntimeStateIsolation_test.cj:126-130`（`var i` 只自增，从未参与断言）
- **来源**：存量（`git blame`：`sceneOk` → `5ef620d752`）
- **判据**：checklist §1「无调用者 / 未使用的 import / 读了不用」
- **证据**：静态确定 —— `private` 符号按「全仓搜索仅命中定义处」判；局部变量按「赋值后无读取」判。
- **描述**：`sceneOk` 是 `TCase.hit` 的薄包装，但 40 余处调用点都直接写 `TCase.hit(...)`，包装体已成孤儿；`kind`/`base`/`i` 属于旧断言残留，会让读者以为还有额外校验。
- **建议**：删除 `sceneOk` 与未用 import；删除 `kind`/`base`/`i`/`rowName`（`rowName` 若原本想用于诊断信息，应真正拼进 `skip(...)` 的 `member` 参数）。

### [轻微][存量] 重复逻辑：`median3` 三份；`code<T>`/`codeOf`、`codeOpt<T>`/`codeOptOf` 两两同义

- **位置**：`f_jit/src/PerfM2_test.cj:43`、`f_jit/src/PerfOverride_test.cj:70`、`f_jit/src/CallPathBench_test.cj:52`（三份 `median3` 逐行相同）；`f_jit/src/ReflectMap_test.cj:166` 与 `f_jit/src/ReflectMap_test.cj:181`（`code<T>` / `codeOf`）、`f_jit/src/ReflectMap_test.cj:173` 与 `f_jit/src/ReflectMap_test.cj:177`（`codeOpt<T>` / `codeOptOf`）
- **来源**：存量
- **判据**：checklist §2「只改类型名 / 换签名但语义相同」
- **证据**：静态确定 —— `median3` 三处函数体逐字一致；`code<T>()` 与 `codeOf(TypeInfo.of<T>())` 的输入输出完全等价（都是 `mapType` → `Some(c) => c` / `None => NONE`）。
- **描述**：`median3` 是本模块性能用例的公共判定工具，三份副本意味着后续若调整（例如改 5 轮取中位数）只改一处会造成判定口径漂移。`ReflectMap_test` 的四个 helper 里有两个纯属泛型/非泛型同名重复。
- **建议**：把 `median3`（以及 `PerfOverride_test.measure` 这类计时骨架）移到 `f_jit/src/test/` 下的测试辅助（如 `test/PerfSupport.cj`），三处引用同一实现；`ReflectMap_test` 只保留 `codeOf`/`codeOptOf`，泛型版直接写成 `codeOf(TypeInfo.of<T>())`。

### [轻微][存量] 重复的双实现：数组「替换/追加」与「类型码区间」各写两套

- **位置**：`f_jit/src/ReflectRegistrar.cj:693-714`（`appendMethod`/`appendFunction`）、`f_jit/src/ReflectRegistrar.cj:742-755`（`copyMethods`/`copyFunctions`）、`f_jit/src/ReflectRegistrar.cj:757-773`（`replaceFunction`）对照 `f_jit/src/base/JitBindings.cj:137-156`（`replaceMethod`）、`f_jit/src/base/JitBindings.cj:199-218`（`replaceStatic`）；`f_jit/src/ReflectRegistrar.cj:717-719`（`isRefCode` 4–14）对照 `f_jit/src/base/LocalType.cj:125-127`（`isHandle` 4–19）
- **来源**：存量
- **判据**：checklist §2「字面量复制 / 换类型名」
- **证据**：静态确定 —— `appendMethod`/`appendFunction`、`copyMethods`/`copyFunctions` 函数体逐行相同，仅元素类型不同；`replaceFunction` 与 `JitBindings.replaceStatic` 是同一语义（找同名 → 替换 → 未命中则追加）；`isRefCode` 是 `isHandle` 的手写子区间。
- **描述**：同一「按名替换/追加」能力存在两套实现，修改其中一处（例如改成稳定去重、或改成返回同一数组以避免拷贝）不会同步到另一处。`isRefCode` 与 `isHandle` 的上界不同（14 vs 19）目前是**有意**的（GAP-13 只针对 4–14 的反射 apply），但没有注释说明这层差异，后续加 15（Any）时很容易被误改。
- **建议**：上提一个泛型辅助（`replaceByName<T>(xs, name, v)`）或让 `ReflectRegistrar` 直接复用 `JitBindings` 的静态方法；`isRefCode` 改为 `c >= LocalType.STRING && c <= LocalType.HOST_OBJECT` 时补一句「与 `LocalType.isHandle` 刻意不同：GAP-13 只覆盖 4–14」的注释。

### [轻微][存量] `Skeleton_test` 的「六包齐备」护栏恒真，且注释与 import 不符

- **位置**：`f_jit/src/Skeleton_test.cj:24-34`（注释）、`f_jit/src/Skeleton_test.cj:39-46`（用例体）
- **来源**：存量
- **判据**：checklist §3「空实现 / 恒真断言」+ §11「注释与实现不符」
- **证据**：静态确定 —— 注释写「本文件顶部 import 了 `base`/`bytecode`/`compiler`/`runtime`/`backend`，任一个包声明文件缺失都会编译失败」，但该文件实际只 import 了 `f_base.*`/`f_regex.*`/`f_util.*`（`Skeleton_test.cj:20-22`）；用例体只有一个字面量数组 `layout`，断言 `layout.size == 6`。
- **描述**：这条用例无论子包是否存在、是否成环都会通过（数组是本地构造的），等于没有护栏；而注释会让后来者以为「删子包会红」。
- **建议**：改成真实引用各子包符号（如 `LocalType.I64`、`SourceCompiler(...)`、`HandleTable.windowUsed()`、`Assembler` 等），或直接删除该用例并把「包结构」交给 `cjpm build` 的编译失败来保证。

### [轻微][存量] `Q6Acceptance_test` 的注释与当前实现矛盾（19/20 口径、残留思考记录、两段互相否定的 doc）

- **位置**：`f_jit/src/Q6Acceptance_test.cj:406` 与 `:407-413`（同一函数上叠了两段 doc，前者说「>2 元是已知限制」，后者说已被解除）；`f_jit/src/Q6Acceptance_test.cj:474`（`// outer -> unitB -> leaf(10) + 10 = 20 -> +? 见下`）；`f_jit/src/Q6Acceptance_test.cj:1121`（「let 写 → 19」）、`f_jit/src/Q6Acceptance_test.cj:1195`（「裸 H65 → 19」）
- **来源**：存量
- **判据**：checklist §11「语义与命名/注释不符」
- **证据**：静态确定 —— `ErrCode.READONLY = 20`、`ErrCode.CALL_CONTRACT = 19`（`f_jit/src/base/ErrCode.cj:69-71`），而同文件 `t35FieldTypeMatrixAndDefense` 断言的正是 `ErrCode.READONLY`（`:1132`）；`runtime/HostField.cj:207-209` 也明确「`mutable=false` ⇒ **20（READONLY）**（A7/P3-4 口径统一）」。
- **描述**：`let` 字段写入的失败码是 20，注释两处写成 19（19 是调用契约错误）。这两处恰好是「口径统一」项目明确治理过的点，注释保留旧值会把下一个读者引向错误码。`474` 行的 `-> +? 见下` 是写作过程中的推演残留。406/407 行两段相邻 doc 结论相反（限制存在 / 限制已解除）。
- **建议**：删掉 `:406` 的旧限制段；`474` 行注释改为陈述最终结果（`outer -> b(=unitB(1)+10=11) -> 11`）；把两处 19 改成 20 并写明 `ErrCode.READONLY`。

### [轻微][存量] `RecReflectSink.onlySkipped()` 名不符实，两条断言实际只验证「诊断条数 > 0」

- **位置**：`f_jit/src/ReflectRegistrar_test.cj:366-368`（`diag` 丢弃 `level`/`code`）、`f_jit/src/ReflectRegistrar_test.cj:383-385`（`onlySkipped` 只判 `size > 0`）、调用点 `:117`、`:166`
- **来源**：存量
- **判据**：checklist §11「契约与实现不符」+ 本模块专项「重复逻辑/装配正确性」
- **证据**：静态确定 —— 函数体 `this.messages.size > 0`；`diag(level, code, message)` 的三个形参里只有 `message` 被保存。
- **描述**：用例名与断言意图是「**全部**诊断都是 `RegistrationSkipped`（没有 Error 级）」，实现只能证明「至少有一条诊断」。若注册期混入 `DiagCode` 其他码或 `DiagnosticLevel.Error`，`skipsStaticMutableMembersWithDiagnostics` / `nameConflictSkipsOnlyThatName` 仍然绿。
- **建议**：`messages` 改为存 `(DiagnosticLevel, DiagCode, String)` 三元组，`onlySkipped()` 判「非空且每条的 `code == DiagCode.RegistrationSkipped`」；顺带补一条「无 Error 级」的断言。

### [轻微][存量] `registerInterface` 对未注册的父接口静默跳过，无任何诊断

- **位置**：`f_jit/src/ReflectRegistrar.cj:421-432`（`match (into.resolve(pname)) { case None => () }`）
- **来源**：存量（`git blame` → `069e6e37c1`）
- **判据**：checklist §3「`case None => ()` 把缺失吃掉」
- **证据**：静态确定 —— 父接口名已在 `effective.parents` 里（说明宏侧认为它是父接口），此处解析不到只是 `()`，既不 `skip` 也不抛 `RegistrationException`。
- **描述**：父接口未注册（注册顺序问题或漏注册）时，子接口的描述符会少掉整组父方法，编译期表现为「函数未注册」，注册期没有任何提示。同一函数里其他拒绝路径都会抛 `RegistrationException`（`:415-418`），这条不一致。
- **建议**：`case None => ReflectRegistrar.skip(diag, '${name} extends ${pname}', '父接口未注册，父方法未并入')`；若要强约束则抛 `RegistrationException(RegistrationRejectKind.ReflectionUnavailable, ...)`。

### [轻微][存量] 祖先链遍历上限不一致（32 vs 64），超限静默截断

- **位置**：`f_jit/src/ReflectRegistrar.cj:509`（`mergeAncestorFields`，`depth < 32`）、`f_jit/src/ReflectRegistrar.cj:577`（`mergeAncestorMethods`，`depth < 32`）、`f_jit/src/ReflectRegistrar.cj:959`（`ancestryOf`，`depth < 64`）、`f_jit/src/ReflectRegistrar.cj:975`（`isInstanceOfClass`，`depth < 64`）
- **来源**：存量
- **判据**：checklist §11「边界」+ §4（有界递归/循环的上界必须与其它路径一致）
- **证据**：静态确定 —— 同一条祖先链在 `ancestryOf` 里取到 64 层，在字段/方法并入里只走到 32 层，且两处都没有诊断。
- **描述**：声明链深于 32 的类，`parents` 里有该祖先，但祖先的字段/方法没被并入子描述符：脚本按 `parents` 语义写 `c.grandField` 会编译失败，或落到 99。触发条件苛刻（>32 层继承），但两处常量没有注释说明为什么不同，容易被误认为笔误。
- **建议**：抽一个模块级常量（如 `ANCESTRY_LIMIT`）供四处共用；到达上限时 `skip(...)` 记一条「祖先链超过 N 层，后续祖先未注册」的诊断。

### [轻微][存量] 父类成员不可映射时静默 `continue`，与自有成员路径（有诊断）不对称

- **位置**：`f_jit/src/ReflectRegistrar.cj:521-524`（父类字段 `codeOpt.isNone()` → `continue`）、`f_jit/src/ReflectRegistrar.cj:626-629`（父类属性同上）对照 `f_jit/src/ReflectRegistrar.cj:153-157`、`:214-218`（自有字段/属性 `skip(diag, ...)`）
- **来源**：存量
- **判据**：checklist §2「近似重复但少一条边界处理」（差异导致行为漂移）
- **证据**：静态确定 —— 两条路径的类型映射逻辑逐行同构，唯独失败分支一条 `skip` 一条 `continue`。
- **描述**：父类有一个不可映射类型的字段时，注册完全静默：既不报「跳过」，使用者也不知道该字段在子类上不可用，排查成本落在运行期 99 上。
- **建议**：与自有成员路径对齐，补 `ReflectRegistrar.skip(diag, '${p.name}.${v.name}', '父类字段类型不可映射')` / `'父类属性类型不可映射'`；`mergeAncestorMethods` 的属性分支同理。

### [轻微][存量] `T40Deopt_test` 用裸数字当 helper id、`TCase.hit` 传常量 `true`、改写全局 `HandleTable` 配置不复位

- **位置**：`f_jit/src/T40Deopt_test.cj:51`（`invokeHelper(c, 78, ...)`）、`:56-57`（79/80）、`:65`（`TCase.hit('T40/deopt-replay', true)`）、`:45-46`（`HandleTable.initialCapacity = 128` / `capacityLimit = 1048576` 无 `finally` 复位）
- **来源**：存量（`git blame` → `204f1bc1e6`，2026-10-20）
- **判据**：checklist §11「字面量复制」+ `TCase` 自身契约（`f_jit/src/test/TCase.cj:22-28`：标签必须与它守卫的断言同生共死）+ §12「测试间全局状态」
- **证据**：静态确定 —— `HelperId.ANY_BOX/ANY_IS/ANY_AS` 就是 78/79/80（`f_jit/src/runtime/HelperId.cj:102-104`）；`:65` 的 `ok` 参数是字面量 `true`，与前一行的 `@Assert` 无耦合；`:45-46` 直接改静态字段，`HandleTable.resetForTest()`（`:44`）只清句柄不还原容量配置。
- **描述**：三处都属于「测试自身不严谨」：裸 78/79/80 在 `HelperId` 重排后会静默测错 helper（且报错信息里看不出来）；恒真标签违反 `TCase` 的设计意图（标签删改不会被发现）；容量配置泄漏到同进程后续用例（`RuntimeStateIsolation_test.cj:67` 就读 `HandleTable.initialCapacity` 当基准）。
- **建议**：改用 `Int64(HelperId.ANY_BOX)` 等常量；标签改为 `TCase.hit('T40/deopt-replay', f.isJitBacked() || true)` 这类真实条件或直接并入上一行 `@Assert`；容量配置放进 `try/finally` 复原（参考 `SignatureTableConcurrency_test.cj:171-176` 对 `SignatureTable.enabled` 的处理）。

### [轻微][存量] 字段访问器登记无去重/无上限；注册被拒时保活表仍留条目

- **位置**：`f_jit/src/ReflectRegistrar.cj:376-378`（`pending` 逐字段 `HostFieldTable.register`）、`f_jit/src/ReflectRegistrar.cj:129`（`retainClass` 早于 `:375` 的 `into.register`）
- **来源**：存量
- **判据**：checklist §5「无界容器 / 长期持有」+ §11「资源不对称」
- **证据**：静态确定 —— `HostFieldTable.register` 每次无条件 `list.add(acc)` 并整表重建（`f_jit/src/runtime/HostField.cj:96-113`），没有任何「同 (index, accepts, 类) 已登记」的判重；`ClassRegistry.register` 的 `DuplicateClass` 拒绝（`f_jit/src/ClassRegistry.cj:72-85`）拦不住「同一类注册进两个不同的 `ClassRegistry`」这一形态（`ReflectRegistrar_test.cj:454-464` 正是这么用的）。
- **描述**：每多注册一次同类，全局表就多一组访问器（`find` 线性扫变长、内存常驻），且先命中的那组生效——若两次注册的绑定来源不同（一次带 `@JitBind`、一次纯反射），行为取决于注册顺序。`retainClass` 在 `into.register` 之前执行，注册被拒时 `retainedNames/retained` 仍多一条，`retainedCount()` 与「已注册类数」不再等价。
- **建议**：`pending` 里登记前先查一次「同 index + 同类」是否已存在（或让 `HostFieldTable.register` 支持幂等键）；把 `retainClass(cls)` 移到 `into.register(descObj)` 成功之后；`retained` 增删与注册表生命周期对齐，或至少提供 `release(name)`。

<!-- 第 25 部分 -->

### 1. [严重][存量] A64 帧尺寸与操作数栈基址按 imm12 裸编码，超过 4095 被静默截断

- **位置**：`f_jit/src/backend/A64Compiler.cj:75`、`f_jit/src/backend/A64Compiler.cj:77`（发射侧 `f_jit/src/backend/A64Emitter.cj:318-324`）
- **来源**：存量（快照模式无基线可比；这两行与 `addOff` 的分块逻辑同批存在，未被 `git blame` 到任何本次改动）
- **判据**：review-checklist §11（边界越界 / 静默错误）+ §6.4（已知规模却用受限编码）
- **证据**：静态确定 —— `A64Emitter.subImm` / `addImm` 只把立即数写进 imm12：`UInt32(imm & 0xFFF) << 10`，既不分块也不报错；而同文件 `addOff`（`A64Emitter.cj:522-541`）对内存偏移明确做了「按 4095 分块累加」并注明「`add/sub` 的 imm12 只有 4095」。`A64Compiler` 对帧尺寸与 x20 基址用的正是未分块的 `subImm`
- **描述**：`frame = align16(40 + 8*(nLocals + maxStack + 1))`（`A64Compiler.cj:37-40`），`nLocals` / `maxStack` 都是 `UInt16` 且**全链路没有上限校验**（`FbcReader` 只校验类型表长度、`Assembler` 只校验槽索引 < nLocals，均不限制槽数；README 也未记载局部槽上限）。触发条件与后果：
  - `nLocals >= 507` ⇒ `40 + 8*nLocals >= 4096` ⇒ `e.subImm(20, 29, 4096)` 的低 12 位为 0，`x20 = x29`，操作数栈基址落在帧指针上；随后 `pushX`（`A64Lower.cj:135-138`）第一次压栈就写 `[x29-8]`，覆盖 `prologue` 保存的 x19（`A64Emitter.cj:270`），helper 返回后寄存器状态即被破坏
  - `nLocals + maxStack >= 506` ⇒ `frame >= 4096` ⇒ `e.subImm(31, 31, frame)` 截断，真实 `sp` 只下移 `frame & 0xFFF`（如 4112 → 16），局部槽 `[x29-40-8i]` 全部落在已分配帧之外，写到调用者栈帧里
  - 两条都不会降级解释器（`compileOnce` 照样返回 `Some`），属于静默内存破坏：轻则错值，重则 SIGSEGV
- **建议**：`compileOnce` 在算完 `frame` 后加显式拒绝路径 —— `if (frame > 4095 || 40 + 8*nLocals > 4095) { return None }`（退回解释器，与 `A64Lower` 其余「不支持即降级」一致）；或改用 `movImm64 + subReg`（`A64Emitter.cj:299-312`、`330-332`）构造任意 64 位帧调整，彻底去掉 imm12 约束

### 2. [一般][存量] 引擎选择链（`BackendSelector` / `Backend` / `Engine`）不在生产路径上，`JitFallback` 诊断永不触发

- **位置**：`f_jit/src/backend/BackendSelector.cj:40-74`（选择器）、`:89-104`（`BackendX86_64.compile`）、`:1843-1858`（`BackendAArch64.compile`）
- **来源**：存量（快照模式）
- **判据**：review-checklist §14（接线缺失）+ §13（契约与实现不符）+ §3（`entryThunk*` 恒 0 的占位实现）
- **证据**：静态确定 —— 全仓 `grep` 结果：`BackendSelector.select` 唯一调用点是 `BackendSelector_test.cj:77`；`Backend.compile` / `abiSummary` 在 `f_jit/src` 内**零调用**（只有 `Backend.cj:26/29` 的接口声明与两个实现体）；`prepareThunks` / `entryThunkBase` / `entryThunkFor` / `thunkBytes` 只被 `X86Thunk_test.cj` 引用。生产路径是 `CompilePipeline.cj:236-241` → `JitExecutor.create(unit, entryFn)` → `JitCompiler.compileUnitWith`（`JitCompiler.cj:86-89` 走 `Arch.current.toString()` 的 arch 分支），与 `BackendSelector` 完全并行
- **描述**：三处后果（同一根因：一套契约层没人用，另一套在生产里另写一遍）：
  1. **诊断承诺未兑现**：`f_jit/src/base/Engine.cj:26-27` 写「用户要感知降级只能经 diagnostics 的 `(Warn, JitFallback)` 事件」，`DiagCode.cj:23` 也把它定义为「非 Linux / 架构不支持」的唯一出口；但生产门禁在 `JitExecutor.cj:55-60` 直接 `return None`，**不发任何 diag**。全仓 `DiagCode.JitFallback` 的发射点只有 `BackendSelector.cj:61/71` 两处，而它们不会被调用 ⇒ 非 Linux 平台静默降级，`(Warn, JitFallback)` 永远不会出现
  2. **契约层与生产实现漂移**：`BackendAArch64.compile`（`:1843`）调的是 `A64Compiler.compileFunction`（constBase/fnTableBase 恒 0），任何含 `PUSH_KH` / `CALL_FUNC` 的单元都会 `None`；生产用的 `JitCompiler.compileUnitWith` 却能传常量镜像与 fnTable 基址。`BackendAArch64.entryThunkBase/For`（`:1860-1866`）恒返回 0，而接口注释（`Backend.cj:31-35`）承诺「入口 thunk 区基址 / 某函数的入口 thunk 地址」，没有说明 0 是「无 thunk」哨兵
  3. `CompileCacheKey`（`CompileCacheKey.cj:24`，doc 注释指向 §8.7 / S5.13 的编译缓存键）在 `f_jit/src` 内零引用；实际存在的是 `CompileCache.cj:30`，它以源码 FNV-1a-128 为键（`CompilePipeline.cj:48`），既不带 arch 也不带 cpuFeatures ⇒ 该类当前是对外可达但无消费方的 API，不是死代码（硬原则一），但设计文档 `doc/design-m1.md:203`「`BackendSelector.select` 由桥管线第 3 步调用」与实现不符
- **建议**：二选一并写清：① 让 `JitExecutor.create` 复用 `BackendSelector`（拿到 `(Engine, ?Backend)` 并把 `JitFallback` diag 透出到 `CompileOptions.diag`），`Backend.compile` 作为唯一编译入口；② 明确废弃 `Backend`/`BackendSelector`/`CompileCacheKey`，同步删掉 README:241-242、`design-m1.md:203/776-784` 的描述。无论哪条，都要修 `JitExecutor.create` 的静默降级（至少补一次 `Warn/JitFallback`）

### 3. [一般][存量] `fRoundOp` 的 round-half-even 收尾在 |小数部分| < 0.5 时会多加减 1

- **位置**：`f_jit/src/backend/BackendSelector.cj:1175-1183`（`fRoundOp` 的 `kind == 3` 分支）
- **来源**：存量（快照模式）
- **判据**：review-checklist §11（逻辑错误）+ §2（与同语义实现 `roundsd` 漂移）
- **证据**：静态确定 —— 按字节序列推演（`rax = trunc(x)`、`xmm1 = double(t)`、`xmm2 = x - t`）：
  ```
  test rax,1 ; jz .store        ; t 偶数 → 直接存 t（正确）
  xorpd xmm3,xmm3 ; ucomisd xmm2,xmm3 ; ja .plus ; jmp .minus
  ```
  即 t 为奇数时**无条件**按小数部分的符号做 ±1，缺少「|frac| < 0.5 应保持 t」这一判定。结果：`round(3.0) = 2.0`、`round(3.3) = 4.0`、`round(-3.3) = -4.0`；只有 t 为偶数的输入才碰巧正确
- **描述**：`fRoundOp(3)` 是 `emitFRound`（`:1232`）的实现，doc 注释自称「取整族基线序列（§12.4）」。当前**尚未接线**：生产 lowering 的 `0x4D` 走 `X86Lower.cj:960 → floatRoundChecked → floatRound`（SSE4.1 `roundsd`，`:534-539`），而 README:269 明确「缺 SSE4.1 时含取整指令的单元整体退解释器」。所以现在不影响运行结果，但这一族（`emitFTrunc/FFloor/FCeil/FRound` + `fRoundOp`，`:1100-1234`）只被 `X86Lower_test.cj:576-590` 的字节级断言引用 —— 一旦有人按注释把它当基线接上，就是静默算错
- **建议**：要么删除这一族（与 README:269 的「退解释器」决策保持一致），要么补上 `|frac| == 0.5` 判定（`ucomisd` 与 ±0.5 比较，非等值即 `.store`）后再接线，并补一条 `round(3.0)/(3.3)/(2.5)/(-2.5)` 的差分用例（对拍解释器）

### 4. [一般][存量] `CodeBuffer.flushCounter` 是无同步的静态可变计数，并发 `seal()` 会丢失更新

- **位置**：`f_jit/src/backend/CodeBuffer.cj:156`（自增）、`f_jit/src/backend/CodeBuffer.cj:173-180`（读/清零）
- **来源**：存量（快照模式）
- **判据**：review-checklist §12.1（共享可变状态无保护 / 检查-然后-写入）+ §11（并发正确性）
- **证据**：静态确定 —— `private static var flushCounter: Int64 = 0`，`flushICache()` 里 `CodeBuffer.flushCounter = CodeBuffer.flushCounter + 1` 是读-改-写，无锁无原子；`flushICache` 是 `public` 且由 `seal()`（`:131-146`）调用，而 `seal` 的并发调用是本模块明确支持的场景（`A64AuditIsolation_test.cj:22-28` 的注释就在讨论「并发编译」）
- **描述**：两个线程同时 `seal()` 两个不同 `CodeBuffer` 时，计数可能只 +1；`resetFlushCount()` 也会把另一线程刚累加的值清零，`CodeBuffer_test.sealFlushesICache`（`:74-82`）在测试并行跑时因此可能间歇失败。后果只落在诊断计数上（无业务状态、无内存安全），故定一般
- **建议**：改成 `AtomicInt64`（`fetchAdd(1)` / `store(0)` / `load()`），或把计数设为 `@When[test]` 专供测试；不要把可变的进程级计数留在生产类里

### 5. [一般][存量] `emitSetSite` 用 `C7 /0 imm32` 写 64 位 site，注释与编码自相矛盾

- **位置**：`f_jit/src/backend/BackendSelector.cj:1694-1702`
- **来源**：存量（快照模式）
- **判据**：review-checklist §11（语义与注释不符 / 截断）
- **证据**：静态确定（截断）—— `49 C7 4F 08 imm32` 是 `mov qword [r15+8], imm32`，立即数按 32 位符号扩展；`BackendX86_64.w32(out, i32bits(site))` 只写低 32 位。注释却写「site 是 Int64，不能只写低 32 位」
- **描述**：`site >= 2^31` 时实际写入 `site - 2^32`（负数），`ctx.site` 被写成非法偏移；`site` 在 `JitContext` 里是 Int64（`OFF_SITE`），字节码偏移与 site 表索引当前都远小于 2^31，所以是潜在问题而非现网故障（可达性待确认：需确认 site 是否会取 `Int64` 级的值）
- **建议**：改成 `movabs rcx, imm64; mov [r15+8], rcx`（4+11 字节），或把断言写进注释「site 由 siteTable 索引限定 < 2^31」，并在生成侧加钳制

### 6. [轻微][存量] 死代码：4 个函数 + 6 个条件码常量全仓零引用

- **位置**：`f_jit/src/backend/A64Emitter.cj:255-257`（`ret`）、`f_jit/src/backend/A64Emitter.cj:362-364`（`neg`）、`f_jit/src/backend/A64Lower.cj:68-71`（`bailLabel`）、`f_jit/src/backend/A64Lower.cj:121-123`（`u32`）、`f_jit/src/backend/A64Emitter.cj:645-658`（`A64Cond.HS/MI/PL/VC/HI/LS`）
- **来源**：存量（快照模式）
- **判据**：review-checklist §1（`private` 全仓搜、`internal` 本包及子包搜）
- **证据**：静态确定 —— 搜索范围与命中：
  - `\.ret()` 全仓只命中 `Assembler.ret` / `Builder.ret`（`src/compiler/Lowering*.cj`、`Assembler_test.cj`），无一处是 `A64Emitter.ret`
  - `\.neg(` 全仓 0 命中；`bailLabel` 仅在定义处 `A64Lower.cj:68` 命中；`A64Lower.u32` 0 命中（`u8/i8/u16/i32/i64` 均有调用）
  - `A64Cond.<cond>` 计数：EQ 13、NE 6、LO 2、VS 5、GE 5、LT 8、GT 5、LE 2；`HS/MI/PL/VC/HI/LS` 各 0
- **描述**：`A64Cond` 是 `internal class`，其 `static const` 对外不可达，未使用的 6 个条件码按硬原则二属死代码；不过「条件码枚举保持与 ISA 一一对应」也可能是有意为之（待确认）。`ret`/`neg` 是可被 `word(0xD65F03C0)` / `word(0xCB0003E0)` 直接替代的遗留原语
- **建议**：删掉 `ret`/`neg`/`bailLabel`/`u32`；`A64Cond` 若不打算补全为完整条件码表，就删掉未用项，否则在类注释里写明「完整枚举，非按需添加」

### 7. [轻微][存量] 重复逻辑 6 处：同一语义在一份文件里写了两三遍

- **位置与形态**：
  1. 错误收敛序列（`ldr err; cbz ok; dump; ret0; b epilogue; ok:`）三份：`A64Lower.cj:542-551`（`helperCall` variant 0）、`:563-570`（`helperCall0`）、`:574-583`（`checkErr`）
  2. 栈护栏序列（`movReg(11,29); subImm(11,11,frame); subReg(11,11,31); movImm64(12,need); cmpReg; bCond(LO,'deopt')`）两份：`A64Lower.cj:167-174`（0x07）、`:367-373`（0x74）
  3. 条件码取反表（14 case 的 `cond^1`）两份：`A64Emitter.cj:225-243`（`invert`）、`:410-429`（`cset` 内联 match）
  4. `emitDump` 序列（`subImm(4,29,40); ldr [x19+56]; ldr [x19]; fnId; nLocals; movImm64 dump; blr`）两份：`A64Compiler.cj:133-141`、`A64Lower.cj:79-87`
  5. x86 位运算三对完全同体：`emitBAnd/emitBOr/emitBXor`（`BackendSelector.cj:407-417`）与 `emitAndB/emitOrB/emitXorB`（`:1518-1528`）逐字节相同
  6. `bitBin(kind)`（`A64Lower.cj:821-823`）是 `boolBin` 的纯别名，`translate` 里 `0x5F-0x61`（bool）与 `0x62-0x64`（bit）因此走两条完全相同的路径
- **来源**：存量（快照模式）
- **判据**：review-checklist §2（换控制流 / 只改类型名 / 字面量复制）
- **证据**：静态确定 —— 上述各对逐行比对：指令序列与操作数完全相同，仅插入位置/函数名不同，无边界、错误文案或精度差异
- **描述**：重复本身不改变行为，但已有可见漂移：(1) 的三份里只有 `checkErr` 被 `callFunc`/`callClosure` 复用，(2) 的两份 `need` 取值不同（一处 `u16` 立即数、一处 `this.frame`），(6) 让「按位与/或/异或」与「布尔与/或/异或」在编码层面无法分别优化
- **建议**：把 (1) 抽成 `emitErrCheck()`（`helperCall`/`helperCall0` 直接调用 `checkErr`）；(2) 抽成 `emitStackGuard(need)`；(3) 让 `cset` 调 `invert`；(4) 让 `A64Compiler.emitDump` 调 `A64Lower.emitDump` 的公共静态版（或反过来下沉到 `A64Emitter`）；(5) 保留一对、另一对改为转调；(6) 删掉 `bitBin`，`0x62-0x64` 直接 `boolBin`

### 8. [轻微][存量] ctx 布局偏移以魔数 40/56/0 硬编码，与 `JitContext.OFF_*` 常量并存

- **位置**：`f_jit/src/backend/A64Compiler.cj:135-136`、`f_jit/src/backend/A64Lower.cj:81-82`（`56`/`0`）、`A64Lower.cj:637`、`A64Lower.cj:676`（`40`）
- **来源**：存量（快照模式）
- **判据**：review-checklist §2（字面量复制）+ §10（可维护性）
- **证据**：静态确定 —— `JitContext.cj:115-122` 已定义 `OFF_ERR_CODE=0 / OFF_SITE=8 / OFF_HW_BASE=16 / OFF_HW_CAP=24 / OFF_HW_TOP=32 / OFF_FN_ID=40 / OFF_FLAGS=48 / OFF_DBG_BASE=56`；同文件 `A64Lower.cj:375` 用的是具名常量 `JitContext.OFF_FLAGS`，其余 5 处仍是魔数
- **描述**：ctx 布局一旦调整（例如在 fnId 前插字段），只有 `OFF_FLAGS` 那处会跟着改，`dbgBase` 与 `errCode` 的读取会静默读错字段 —— 表现为 dump 内容错位而不是编译失败
- **建议**：5 处改用 `JitContext.OFF_DBG_BASE / OFF_ERR_CODE / OFF_FN_ID`；`A64Compiler.emitDump` 与 `A64Lower.emitDump` 合并时一并替换

### 9. [轻微][存量] `emitCallHelperNC` 用 `full.size - 10` 硬编码尾长，与 CHECK_ERR 字节序列隐式耦合

- **位置**：`f_jit/src/backend/BackendSelector.cj:1572-1575`（配合 `:1801-1806` `appendCheckErr`、`:1705-1707` `emitCheckErr`）
- **来源**：存量（快照模式）
- **判据**：review-checklist §2（字面量复制）+ §10（可维护性）
- **证据**：静态确定 —— `emitCallHelperNC` 返回 `full[0..(full.size - 10)]` 来「去掉尾随 CHECK_ERR」，10 是 `49 83 3F 00 0F 85 rel32` 的长度；两个 CHECK_ERR 发射点各写一遍同样的 10 字节字面量，无共享常量
- **描述**：任一侧字节顺序变化（例如把 `cmp [r15],0` 换成 `test`），切片长度就不再对齐，结果是**半条指令**被截断、机器码错位且测试仍只断言长度 10 的旧序列
- **建议**：抽 `const CHECK_ERR_LEN: Int64 = 10`（或 `emitCheckErr()` 直接返回该数组长度），`emitCallHelper` 单独提供「不带尾」变体而不是切片；`appendCheckErr` 复用 `emitCheckErr` 的字节数组

### 10. [轻微][存量] `strD`/`ldrD` 不做偏移校验也不走慢路径，与 `strOff`/`ldrOff` 不对称

- **位置**：`f_jit/src/backend/A64Emitter.cj:543-549`
- **来源**：存量（快照模式）
- **判据**：review-checklist §11（边界未处理）+ §10（API 对称性）
- **证据**：静态确定 —— `strOff`/`ldrOff` 有 `off % 8 == 0 && off <= 32760` 的 scaled-imm12 判定、`-256..255` 的 imm9 判定、以及 scratch 慢路径；`strD`/`ldrD` 直接 `UInt32(off / 8) << 10`，负偏移或非 8 倍数会得到错误 imm12（`off = -8` ⇒ `UInt32(-1) << 10` 污染整个高字段）。另外两者都不调 `noteMemBase`，G5 审计看不到浮点槽访问
- **描述**：当前调用点只有 `off = 0/8`（`A64Lower.cj:188-311`、`404`、`685`、`840-890`），所以未造成故障；一旦浮点局部槽偏移变大（`nLocals` 增大后的 `[x29-40-8i]` 走 `ldrD`），就会静默编码错
- **建议**：给 `strD`/`ldrD` 加与 `emitLdr` 同构的范围判定（含 scratch 慢路径）与 `noteMemBase`，或把它们改成 `strOff`/`ldrOff` 的浮点重载，明确注释「仅支持 8 字节对齐、scaled imm12 范围」，调用侧加断言

### 11. [轻微][存量] `finish()` 在范围校验失败后静默返回部分回填的字节

- **位置**：`f_jit/src/backend/A64Emitter.cj:166-171`（配合 `:131-163` `resolve`）
- **来源**：存量（快照模式）
- **判据**：review-checklist §3（`Option` 被静默丢弃）
- **证据**：静态确定 —— `resolve` 在 `checkRange` 中途 `return None` 时，**已经回填过的 reloc 保持已写状态**、未处理的保持 0；`finish()` 的 `case None => this.bytes()` 把这个 `None` 吞掉，返回一份「部分回填 + 越界截断」的码流
- **描述**：生产路径只用 `finishOrNull()`（`A64Compiler.cj:112`），所以现网不受影响；`finish()` 只被测试（`A64Emitter_test.cj:33` 等）当「宽松版」使用。但同名 API 一个返回校验结果、一个吞结果，后续若有人用 `finish()` 拿机器码，会拿到越界截断的分支（与 `optimize-emit-fixup` 想防的 `off & 0x1FF` 截断是同一类事故）
- **建议**：`finish()` 改成返回 `?Array<UInt8>`，或在文档里明确「仅供不校验的测试/诊断，越界分支会静默截断」并把名字改成 `finishUnchecked()`

### 12. [轻微][存量] `A64Lower.bail` 与 `A64Compiler.bindBail` 对 k>0 的转储行为不一致

- **位置**：`f_jit/src/backend/A64Lower.cj:61-66`（不转储）vs `f_jit/src/backend/A64Compiler.cj:121-130`（k>0 转储）
- **来源**：存量（快照模式）
- **判据**：review-checklist §11（语义与注释不符 / 同类路径行为不一致）
- **证据**：静态确定 —— `bindBail` 的注释（`:115-120`）声明「写错误槽 → （`k > 0` 时）单次转储 → 返回 0」，实现里 `if (k > 0) { emitDump(e, fn) }`；`A64Lower.bail(k)` 写同样的错误槽但**没有** dump，用于 `bail(18)`（HW_OPEN）、`bail(13)`（TO_I64）、`bail(7)`（CAST）、`bail(17)`、`bail(6)`、`bail(u8)`（ASSERT/THROW）
- **描述**：同一个错误码走「跳到 `bail1/2/3`」还是「内联 `bail(k)`」决定了失败帧是否进 `DbgDump` 报告 —— 例如 CAST 失败（7）不产生 dump，而 DIV_ZERO（1）产生。`DbgDump` 的「首个收敛点获胜」规则（`DbgDump.cj:33`）会让报告内容依赖 lowering 的实现选择，用户看到的诊断与被调指令无关（需确认这是有意为之：`DbgDump` 内部是否还有别的补偿规则）
- **建议**：`A64Lower.bail(k)` 在 `k > 0` 时也调 `emitDump()`（与 `bindBail` 对齐），或在两处注释里写明「内联 bail 不参与 dump」的理由

<!-- 第 26 部分 -->

### [严重][存量] x86 `NE_F`（0x59）NaN 语义与解释器相反：`NaN != x` 被判为 false

- **位置**：`f_jit/src/backend/X86Lower.cj:553`（`floatCmp` 的 `case 4u8` 分支）、调用点 `f_jit/src/backend/X86Lower.cj:970`（`case 0x59u8 => this.floatCmp(4u8)`）
- **来源**：存量（快照模式无基线；该函数由 `optimize-x86-cfg-depth` 系列提交引入，全仓无第二版）
- **判据**：review-checklist §11「契约与实现不符」+ 规范 I7「解释器语义是规范，JIT 是等价加速器」（`f_jit/doc/jit-bytecode-m1.md:31`）+ `:318`「`NE_F`：NaN ≠ 任意 → true」
- **证据**：静态确定 —— `floatCmp(4)` 发射 `0F 95 C0`（`setne al`）→ `0F 9B C2`（`setnp dl`）→ `20 D0`（`and al,dl`）。`ucomisd` 对无序操作数置 `ZF=PF=CF=1`，因此 `setne` 得 0，`and` 后仍为 0。而三处对照全部给出 1：
  1. `f_jit/src/runtime/Interp.cj:513-516`（0x59）`f.push(if (x != y) { 1 } else { 0 })`，注释「NaN ≠ 任意 ⇒ true」；
  2. `f_jit/src/backend/BackendSelector.cj:934` `emitCmpNeF()` → `fCmpOp(false, 4u8)`，`:905` 注释「无序语义：NE=true」，`cmpsd xmm0,xmm1,4`（NEQ_UQ）对 NaN 返回 1；
  3. `f_jit/src/backend/A64Lower.cj:884-895` 用 `fcmp + cset NE`，ARM64 `FCMP` 无序时 `Z=0`，`cset ne` 得 1。
- **描述**：生产路径 `JitCompiler.compileUnitWith`（`JitCompiler.cj:87`）在 x86_64 走 `X86Compiler` → `X86Lower`，即上表这段内联编码。任何 `if (nanVal != x)` 在 x86_64 上被编译成 false，与解释器/A64 结果相反（数据错误）；当前 CI 机器为 aarch64（`X86Frame_test.cj:24` 注释），字节级用例只断言 `emitCmpNeF`（未被生产路径调用的那份，见下一条），所以该分叉不会被现有测试发现。
- **建议**：把 `floatCmp` 的 NE 分支改成与 `fCmpOp` 同样的语义：`setne al; setp dl; or al,dl`（或直接复用 `BackendX86_64.fCmpOp` 的 `cmpsd imm8=4` 模板）。补一条 x86_64 差分用例（NaN != 1.0 应为 true），并放在真实执行路径而不是字节断言上。

### [一般][存量] 两套 x86 编码器并存：生产路径内联重写，单测只钉住未被调用的那一套（已发生漂移）

- **位置**：`f_jit/src/backend/X86Lower.cj:351-374`（`binOp`/`cmpOp`）、`:542-563`（`floatCmp`）、`:376-383`（`bail`）对照 `f_jit/src/backend/BackendSelector.cj:395`（`emitIAdd`）、`:930-938`（`emitCmpEqF`/`emitCmpNeF`）、`:1710`（`emitBail`）；断言侧 `f_jit/src/backend/X86Lower_test.cj:78`、`:236-237`
- **来源**：存量
- **判据**：review-checklist §2「表现形式不同的重复逻辑：只改类型名 / 近似重复，其中一块少了边界判断」+ §14.1「接线缺失」
- **证据**：静态确定 —— `BackendX86_64` 共 141 个 `internal static func emit*`，被非测试代码引用的只有 11 个（`emitPrologue`/`emitEpilogue`/`emitCmpI`/`emitIPopcnt`/`emitJz`/`emitJbe`/`emitLoopBackGuardPrefix`/`emitCtxFlagsToRax`/`emitDeadlineMaskToRdx`/`emitTestRaxRdx` 等），其余约 130 个只被 `X86Lower_test.cj` 引用；`X86Lower.translate` 对同一批指令（IADD/ISUB/IMUL/IDIV/IMOD/FADD…FROUND/CMPS/CMP_NE_F/CAST/TO_I64…）逐条内联重编码。
- **描述**：两套实现已经不同步，且差异不是等价改写：
  1. `emitIAdd` 用 `jo <bail:3>`（`0F 80`），`X86Lower.binOp` 用 `jno ok; bail(3)`（`0F 81`）——语义等价、字节不同；
  2. `floatCmp(NE)` 与 `emitCmpNeF` 语义不等价（见上一条），说明"测试断言的那份"和"实际跑的那份"已经分叉；
  3. `X86Lower_test.cj` 23 个字节级用例断言的都是 `BackendX86_64.emit*`，生产编码器 `X86Lower.translate` 只有 `f_jit/src/compiler/X86Compile_test.cj` 的少数端到端用例覆盖。
- **建议**：二选一并写进注释——(a) `X86Lower` 改为调用 `BackendX86_64.emit*`（模板方法保持无分配需先解决 `Array<UInt8>` 返回值分配），或 (b) 删除仅测试使用的 `emit*` 集合，把字节断言改为对 `X86Lower` 产物的断言。无论哪种，NE_F 的差异必须由真实执行用例兜住。

### [一般][存量] `JitExecutor.invokeOff` 对 `LibC.malloc` 返回值未判空，内存不足时空指针写入

- **位置**：`f_jit/src/backend/JitExecutor.cj:157`（`let raw = LibC.malloc<Int64>(count: n)`）→ `:160`（`unsafe { raw.write(i, cells[n - 1 - i]) }`）
- **来源**：存量
- **判据**：review-checklist §11「空值 / 资源」「崩溃」+ 类注释 `JitExecutor.cj:30`「任何一步失败都返回 `None`，调用方静默退回解释器」
- **证据**：静态确定 —— 同文件 `FnTable.alloc`（`NativeAssets.cj:76`）与 `ConstMirror.build`（`NativeAssets.cj:160`）都用 `p.isNull()` 做了检查并降级，唯独热路径这次 `malloc` 直接解引用。
- **描述**：`n = cells.size > 0` 且 `malloc` 返回空指针时，`raw.write(...)` 立即段错误（不是可捕获异常），进程崩溃；这与模块"分配失败即退回解释器"的整体约定不一致。触发条件是宿主内存压力（大实参个数或 OOM 边缘），概率低但后果是崩溃而非降级。
- **建议**：`if (raw.isNull()) { return 0 }` 并置 `ctx.errCode`（或抛出桥侧约定的资源错误），由桥决定重放/报错；更彻底的做法见「优化可行性方案 · CPU-2」（去掉每次调用的 malloc）。

### [一般][存量] `DEC_TO_I64`（0x9D）的错误收敛路径 x86 与 A64 不一致（一边转储、一边不转储）

- **位置**：`f_jit/src/backend/X86Lower.cj:1143-1160`（mode≠1 走 `helper(30,1,0)` ⇒ `CHECK_ERR` ⇒ `checkfail` 转储）对照 `f_jit/src/backend/A64Lower.cj:458-476`（恒 `helperCall(30,1,1)`，失败直接 `mov x0,0; b epilogue`，不转储）
- **来源**：存量
- **判据**：规范 I7（`jit-bytecode-m1.md:31`：结果、错误码、site 与**错误报告文本**必须逐位一致）+ review-checklist §2「近似重复：一块少了边界判断」
- **证据**：静态确定（两侧发射路径可逐行对照）；转储是否真的产生文本取决于 `ctx.dbgBase≠0`，该条件属待确认项。
- **描述**：mode=0（普通 DEC_TO_I64）且 helper 写错误码时，x86 经 `helper` variant 0 → `cmp [r15],0; jne checkfail` → `jit_dump` → 返回 0；A64 走 variant 1（NC）后手工判定，只要 `errCode != 0` 就 `mov x0,0; b epilogue`，不调用 `emitDump`。mode=1 且 `errCode∉{0,9}` 时同样是一边 `checkfail`、一边裸返回。桥拿到的错误码相同，但源位置 + 变量清单（§9.16 报告面）只有 x86 有。
- **建议**：A64 侧 0x9D 的失败分支改为跳 `checkfail` 等价块（写槽后先 `emitDump` 再返回 0），与 x86/`CHECK_ERR` 的统一收敛路径对齐；若确认 mode 0 不该转储，则反过来在文档与 x86 侧同步。

### [一般][存量] GAP-05 字段签名四元组全仓无消费点，与「CALL_HOST 走精确签名」的承诺不符

- **位置**：`f_jit/src/base/ClassRegistration.cj:55-71`（`sigParams`/`sigParamNames`/`sigRet`/`sigRetName` 字段与注释）、`:97-99`（`hasSignature`）
- **来源**：存量
- **判据**：review-checklist §14.1「承诺了但没实现 / 接线缺失」；功能缺失双证要求
- **证据**：静态确定 —— 承诺源 `ClassRegistration.cj:56-62`「手工注册可显式给出，`CALL_HOST` 因此能带 `sigId` 走精确签名」；缺失证据：全仓（排除 `.worktrees`）`grep -E "sigParams|sigParamNames|sigRetName|hasSignature"` 除定义文件与 `ClassRegistration_test.cj` 外**零命中**，`CALL_HOST`（`f_jit/src/compiler/Ops.cj`，0x79 `u16 fid, u8 argc`）编码里也没有 `sigId` 字段。
- **描述**：注册面允许填一套函数签名并通过构造期校验（长度不一致即抛 `CALL_CONTRACT`），但没有任何读取方：编译期 `LowererM2` 不读，运行期 `CALL_HOST` 降低（`X86Lower.cj:1054` / `A64Lower.cj:386` 的 `helper(63, argc+1, 0)`）也不读。使用者按注释填了签名不会产生任何效果，属"静默无效的公开契约"。
- **建议**：要么把签名接进 `CALL_HOST` 的解析/分派（需要 opcode 或旁路表承载 `sigId`，属格式变更），要么在字段注释里明确标注「M2 预留、当前无消费点」，并考虑不再对它做构造期强校验以免误导；`hasSignature` 是仅测试使用的公开方法，见「可见性建议」。

<!-- 第 27 部分 -->

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

<!-- 第 28 部分 -->

### [严重][存量] Decimal 常量 Map 键在 |v| < 1 时运行期永不命中（规范化不一致）

- **位置**：`f_jit/src/bytecode/CanonKey.cj:80`（`dec` 只去尾零，不去前导零）、`f_jit/src/bytecode/CanonKey.cj:107`（`decFromText`）、`f_jit/src/bytecode/ConstRegistry.cj:197`（`tokenOf` 直接用载荷 `coeff`）、`f_jit/src/bytecode/ConstRegistry.cj:482`（`addValue(Decimal)` 路径）；对侧证据 `f_jit/src/compiler/Lowerer.cj:3861`（拼装期去前导零）、`f_jit/src/runtime/HandleTable.cj:377`（运行期键走 `v.toString()`）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §11（契约与实现不符 / 数据错误）+ §2（同一规则三套实现）；契约源 `f_jit/src/bytecode/CanonKey.cj:21`「常量表的 `ConstRegistry.tokenOf` 与运行期 `HandleTable.canonKeyOf` 共用本类」、`:25`「同值不同写法必须同键」
- **证据**：静态确定 —— 三条路径逐行推演可闭合：
  1. 拼装期 `Map` 常量：`Lowerer.decimalParts` 把 `0.5` 拆成 `digits="05"` 后**剥掉前导零**（`Lowerer.cj:3861` 的 `while (j + 1 < digits.size && digits[j] == 0x30)`）⇒ `PDec(0, 1, "5")` ⇒ `tokenOf` → `CanonKey.dec(0,1,"5")` = `"d:0|1|5"`；
  2. 运行期查找：`HandleTable.canonKeyOf` 对 `Decimal` 用 `CanonKey.decFromText(v.toString())`（`HandleTable.cj:377`），`Decimal.toString()` 不带指数形式（`stdlib/doc/libs/std/math_numeric/.../math_numeric_package_structs.md:4595`「以不带指数形式打印」），`0.5` 的首字符就是 `0` ⇒ `decFromText` 得到 `digits="05"` ⇒ `CanonKey.dec(0,1,"05")` = `"d:0|1|05"`；
  3. `dec`（`CanonKey.cj:83-86`）只剥尾零，`"05"` 与 `"5"` 得到两个不同 token。运行期文本确实带前导零：`f_jit/src/runtime/Helpers_test.cj:320-321` 断言 `-0.5`、`0.25` 的输出即为带前导零形态。
- **描述**：`let m: Map<Decimal, Int64> = {0.5: 7}; m[0.5]` 这类常量键查表必然落空，走 `ErrCode.KEY_MISSING`（对照 `f_jit/src/compiler/A5MapKey_test.cj:49-56` 里的 miss 断言）。`|v| < 1` 的 Decimal 键全部命中此路径（`0.25`→`"d:0|2|25"` vs `"d:0|2|025"`）。现有 `A5MapKey_test.p1_7_constMapDecimalKeysHit` 只用 `1.5`/`1.50`，恰好绕开了前导零。这正是 `CanonKey.cj:21-23` 自述要修的 P1-7 的残留面。
- **建议**：把规范化收到 `CanonKey.dec` 一处：进入函数即剥前导零（保留至少一位）、再剥尾零、全零归并为 `d:0|0|0`；`decFromText` / `Lowerer.decimalParts` / `ConstRegistry.decimalParts` 只负责切分 `sign/scale/digits`，不再各自处理零。补 `{0.5: 7}` / `{0.25: 7}` / `{-0.5: 7}` 三条命中用例。

### [严重][存量] 常量 DAG 的实例化与键展开递归无深度上限，构造的 `.fbc` 可在加载期栈溢出

- **位置**：`f_jit/src/bytecode/ConstRegistry.cj:146`（`makeInstance`，`PList`/`PMap` 递归 `instanceAt`）、`f_jit/src/bytecode/ConstRegistry.cj:178`（`tokenOf`，`PList`/`PMap` 递归自身）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §4（无界递归：深度由输入决定）/ §5（递归 + 每层分配）
- **证据**：静态确定 —— `decode`（`ConstRegistry.cj:345-376`）唯一的图约束是 `checkChildIndices`（`:378`）要求「子索引 < 自身索引」，即**只排除环与前向引用，不限制链长**；`instantiateAll`（`:120`）与 `tokenOf` 的递归深度 == DAG 最长链，等于条目数。条目数上界由文件字节数决定：一条 `PList` 载荷 = 1（kind）+ 4（count）+ 4（每子索引）≈ 9 字节，即 **约 0.9 MB 的常量段就能造出 10⁵ 层嵌套**，远超默认线程栈可容纳的帧数（具体帧大小需实测，故这里只断言「深度由输入线性决定、无上限」）。
- **描述**：这是加载期**崩溃**而非拒绝：`FbcReader` 文档（`FbcReader.cj:32-51`）承诺 11 类非法情形一律 `rejectFormat`（18），但栈溢出会以非 `JitException` 的形式终止进程；`tokenOf` 还会在 `PMap` 键上触发第二次同样的递归。
- **建议**：`decode` 阶段顺带算每个条目的拓扑深度（既然已要求 `子索引 < 自身`，一趟线性扫描即可：`depth[i] = 1 + max(depth[children])`），超过阈值（如 1024）直接 `rejectFormat('常量嵌套过深')`；`makeInstance`/`tokenOf` 改为显式栈迭代，或在深度已受限后保留递归。

### [一般][存量] DateTime 常量的负 epochNanos 会抛 `IllegalArgumentException`（绕过 JitException 错误码体系）

- **位置**：`f_jit/src/bytecode/ConstRegistry.cj:165`
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §11（边界差一 / 空值 / 契约不符）；API 语义见 `stdlib/doc/libs/std/time/time_package_api/time_package_structs.md:1037-1060`——`ofEpoch(second:nanosecond:)` 的 `nanosecond` 必须落在 `[0, 999999999]`，否则抛 `IllegalArgumentException`
- **证据**：静态确定 —— `nanos / NANOS_PER_SECOND` 与 `nanos % NANOS_PER_SECOND` 都是截断除法；`nanos < 0` 时余数为负（如 `-1_500_000_000` ⇒ `second=-1, nanosecond=-500000000`），直接违反该 API 的前置条件。负值可达：`addValue(v: DateTime)`（`:280-282`）用 `v.toUnixTimeStamp().toNanoseconds()`，1970 年以前的时间戳为负。
- **描述**：任何含 1970 年前 `DateTime` 字面量/常量的单元，在 `load` 的 `instantiateAll` 阶段抛 `IllegalArgumentException`，既不是 `JitException(18/14)`，也没有可读的容器定位信息；宿主按错误码分支的降级逻辑全部失效。
- **建议**：改为 `let s = nanos / NANOS_PER_SECOND; let n = nanos - s * NANOS_PER_SECOND; if (n < 0) { s - 1 / n + NANOS_PER_SECOND }` 的欧几里得拆分；若规格确实不支持 1970 前时间，则在 `decodePayload` 的 kind 7 显式 `rejectFormat`，别把宿主异常漏出去。

### [一般][存量] `regexCompileCount` 是无同步的 `public static var`，并发加载丢计数

- **位置**：`f_jit/src/bytecode/ConstRegistry.cj:62`（定义）、`f_jit/src/bytecode/ConstRegistry.cj:455`（`= ... + 1`）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §12.1（共享可变状态无保护 / 检查-然后-写入）
- **证据**：静态确定 —— `read-modify-write` 非原子；共享路径明确：任何两个线程各自调用 `FbcReader.load`（`FbcReader.cj:102`）且单元里含正则常量，都会在 `instantiateAll` → `compileRegex` 里对同一静态字段自增。`FbcReader_test.cj:647-660` 正是靠这个计数器断言「编译次数 == 常量数」，并发跑测试时会偶发不等。
- **描述**：可观测性指标失真，T20 的「一次编译」断言在多线程下不可靠；不影响业务数据。
- **建议**：换成实例字段（跟 `ConstRegistry` 生命周期绑定，语义也更准）或 `AtomicInt64`；若只为测试，改为按注册表实例计数并提供 `resetForTest()`。

### [一般][存量] `instanceAt` 的惰性缓存是「检查-然后-写入」，无同步

- **位置**：`f_jit/src/bytecode/ConstRegistry.cj:133-144`
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §12.1（惰性初始化 / 迭代与修改并发）
- **证据**：静态确定（代码形态）；共享路径：`ConstRegistry.decode`（`:345`）是 `public`，宿主可以只 `decode` 不 `instantiateAll`，随后多线程共享该实例调 `instanceAt`（`FbcReader.load` 走 `instantiateAll` 预热，所以主路径安全，但公开面不安全）。后果：同一常量被构造两次（`compileRegex` 多编译一次 + 计数 +1）、对 `ArrayList<Any>` 元素做无同步写。
- **描述**：当前 `load` 路径因为先 `instantiateAll` 而不暴露；一旦宿主按公开 API 自建注册表并多线程取常量，就会出现重复实例化与计数漂移（同一 `PRegex` 常量拿到两个不同 `Regex` 对象，违反 `:127-132` 注释承诺的「同一对象」）。
- **建议**：`decode` 末尾直接 `instantiateAll()`（与 `load` 一致），或在文档里明确「`instanceAt` 非线程安全，需先 `instantiateAll`」。

### [一般][存量] `TypeNames.codeOf` 的容器/泛型分类与桥实际承载类型不一致（验签会误放/误拒）

- **位置**：`f_jit/src/base/TypeNames.cj:50-60`（容器分支）、`:42`（`Range` 分支）；调用方 `f_jit/src/runtime/Signature.cj:159`
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §10（正确性 / 契约一致）+ §14.1（接线后语义与规格不符）
- **证据**：静态确定部分 —— `Array<...>` 与 `List<...>` / `ArrayList<...>` 一起被归为 `LocalType.LIST`；但 LIST 句柄在运行期只对应 `ArrayList<Any>`（`f_jit/src/runtime/HandleTable.cj:185`），`Array<Int64>` 是值类型、永远不会以句柄形态出现，于是「宿主函数签名写 `Array<Int64>`」这种不可能成立的桥接会被 `codeOf` 判为 LIST 而通过长度/类型比对。待确认部分 —— `Range` 只匹配裸名 `'Range'`，而 `std.reflect` 对 `Range<Int64>` 报告的 `TypeInfo.name` 很可能是泛型实例名（含 `<Int64>`），那样合法签名会落到 `HOST_OBJECT` 被误拒；`Int32`/`UInt16` 等不支持类型同样落 `HOST_OBJECT`，靠后续类注册表比对才失败，错误信息会指向「宿主对象不匹配」而不是「该类型不支持」。
- **描述**：这是 typcode 分支表（本轮专项）里唯一用于「类型名字符串 → typecode」的映射，误判的两种后果分别是「验签放行不可能成立的调用」（运行期 CAST/取值失败）与「合法签名被拒」。
- **建议**：`Array<` 从 LIST 分支移除（返回 `NONE` 让验签直接失败，与 `:56-57` 对函数类型的处理一致）；`Range` 改 `startsWith('Range<')`；补一条 `Int32`/`UInt16`/`Array<UInt8>` 的单测把「不支持即 NONE」钉住（`f_jit/src/runtime/Signature.cj:159` 的比对目标就是 `LocalType` 码）。

### [一般][存量] 常量段坏载荷校验不全：`PDec.sign` 未限 0/1、`PRange.isClosed` 接受任意非零

- **位置**：`f_jit/src/bytecode/ConstRegistry.cj:593-606`（kind 6）、`:609-614`（kind 9）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §11.5 表示（`sign: u8`、`isClosed: u8` 0/1）+ §11 边界
- **证据**：静态确定 —— `decodePayload` 只校验系数是 ASCII 数字与长度非 0，`sign = r.u8()` 原样存入；`decimalFromParts`（`:418-424`）把 `sign != 0` 一律当负，而 `CanonKey.dec`（`CanonKey.cj:98`）把 `sign` 的**数值**拼进键：`sign=2` 的常量实例化成负数，键却是 `d:2|...`，与运行期 `d:1|...` 永不同键，值语义与键语义分叉。`isClosed` 同理：`closed != 0` 把 2..255 都当 `..=`，但线上表示只定义了 0/1，重新编码时会写出 `1`（`:538-542`），加载-重写不再字节保真。
- **描述**：畸形但能被 CRC 覆盖的容器可以制造「同一常量两种解释」，属于 §11.5 校验点缺口。
- **建议**：`if (sign > 1u8) rejectFormat(...)`；`if (closed > 1u8) rejectFormat(...)`；两者都放在 `decodePayload`，并各配一条拒绝用例。

### [轻微][存量] 重复逻辑：Decimal 文本解析三套实现，规范化口径不一致

- **位置**：`f_jit/src/bytecode/CanonKey.cj:107-178`、`f_jit/src/bytecode/ConstRegistry.cj:482-504`、`f_jit/src/compiler/Lowerer.cj:3823-3877`
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §2（换控制流 / 跨层复制）
- **证据**：静态确定 —— 三者输入都是「十进制文本 → (sign, scale, digits)」，差异点：`decFromText` 处理指数且保留前导零；`ConstRegistry.decimalParts` 忽略指数、保留前导零；`Lowerer.decimalParts` 处理指数且**剥前导零**。第一条发现即由此差异产生。
- **建议**：只保留一处「文本 → (sign, scale, digits)」的切分（放 `CanonKey` 或 `bytecode` 内 `internal` 函数），三处调用方共用；`Lowerer` 位于下层模块的编译期路径，允许依赖 `bytecode` 的 internal 函数，不会反向依赖。
- **备注**：`Lowerer.cj` 不在本部分文件清单内，此处只作为重复逻辑的对侧证据，改动落点在 `CanonKey` / `ConstRegistry`。

### [轻微][存量] 重复逻辑：常量索引/图校验各写两套，判据与文案不同

- **位置**：`f_jit/src/bytecode/ConstRegistry.cj:315-321`（`checkChildren`，上界 = `payloads.size`）vs `:378-384`（`checkChildIndices`，上界 = `selfIndex`）；`f_jit/src/bytecode/ConstRegistry.cj:86-91`（`get`）vs `:133-136`（`instanceAt`）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §2（同一规则两处实现）
- **证据**：静态确定 —— 前两者都回答「子索引是否越界」，只是拼装期与解码期的上界不同、错误文案不同（`常量子索引越界` vs `常量图成环或前向引用`）；后两者都回答「索引是否在 `[0, size)`」，文案一处带 `PUSH_KH` 提示、一处不带。
- **建议**：抽 `private func requireIndex(i: Int64, upper: Int64, msg: String)` 与 `checkChildIndices(children, upper)` 复用，把「拼装期上界 = size / 解码期上界 = self」作为参数显式化，避免两套判据将来漂移。

### [轻微][存量] 重复逻辑：`hexOf32`/`hexOf64`、`CanonKey.i64`/`cell`、legacy 判据、正则 flags 校验各复制一份

- **位置**：`f_jit/src/bytecode/FbcReader.cj:442-448` vs `f_jit/src/bytecode/ConstRegistry.cj:647-654`（十六进制）；`f_jit/src/bytecode/CanonKey.cj:30-32` vs `:41-43`（函数体完全相同 `'i:${v}'`）；`f_jit/src/bytecode/FbcHeader.cj:157` 内联复制 `:111-113` 的 `isLegacyLayout` 判据；`f_jit/src/bytecode/ConstRegistry.cj:301-303` vs `:617-619`（正则 flags 位域校验）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §2（字面量复制 / 只改宽度）
- **证据**：静态确定 —— `hexOf32`/`hexOf64` 是同一循环换宽度（4/8）与位移常量；`i64` 与 `cell` 返回同一字符串，命名却暗示两种语义；`FbcHeader.read` 无法调实例方法却把判据抄了一遍，版本规则改动时两处必须同步；flags 位域 `0xF8` 校验与文案在两处重复。
- **建议**：`hexOfN(v, bytes)` 单实现；保留 `CanonKey.cell` 为唯一实现、`i64` 改为转调并加注释（或直接用 `cell` 删除 `i64`，注意 `i64` 是 public 需保留）；`FbcHeader` 加 `static func isLegacy(verMajor, verMinor)` 供 `read` 与实例方法共用；flags 校验抽成 `checkRegexFlagsBits(flags)`。

### [轻微][存量] 手工逐字节拷贝重复 `sliceOf`，且自带一套越界判断

- **位置**：`f_jit/src/bytecode/FbcReader.cj:302-306`（`readTypes`）、`:232-238`（`checkCrc32`）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §2（同语义两种写法）
- **证据**：静态确定 —— 同文件 `sliceOf`（`:430-439`）做的就是「越界检查 + `Array(n)` + 逐字节拷贝」，`readTypes` 与 `checkCrc32` 各抄一遍，越界判断口径还不同（`readTypes` 用 `Int64(off)+Int64(n) > code.size`，`sliceOf` 用 `off<0||len<0||off+len>raw.size`）。
- **建议**：两处改调 `sliceOf`；`readTypes` 现有判断保留一条（`localTypesOff + nLocals` 的 UInt32 溢出面只有 `Int64` 版本能挡），其余删掉。

### [轻微][存量] `bytecode/Bytecode.cj` 是空占位文件（仅一行注释，无任何声明）

- **位置**：`f_jit/src/bytecode/Bytecode.cj:18`
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §3（占位残留）
- **证据**：静态确定 —— 全文 18 行，除版权头与 `package` 外只有 `// P0 骨架占位：模型层…`，无类型、无函数；同包其余文件已实现该职责。
- **建议**：删除该文件，或改成真正的包级文档（`doc/` 注释）并说明它为何必须存在。

### [轻微][存量] `decode` 的条目数预检写成 `Int64(count) * 1`，意图不可读

- **位置**：`f_jit/src/bytecode/ConstRegistry.cj:353`
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §10（可读性 / 必要注释）
- **证据**：静态确定 —— `count * 1` 只能是「每条至少 1 字节（kind）」的意思，但 `* 1` 让读者无法判断是有意还是漏改。
- **建议**：写成 `if (Int64(count) > r.remaining())` 并补一句「每条至少 1 字节 kind，先粗筛再逐条解」。

### [轻微][存量] `instantiateAll` 连续两次丢弃返回值

- **位置**：`f_jit/src/bytecode/ConstRegistry.cj:121-124`
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §10（可读性）
- **证据**：静态确定 —— `let unused = instanceAt(i); let _ = unused` 两跳，第二行唯一的用途是压掉未使用告警；`let _ = instanceAt(i)` 一步即可。
- **建议**：合并为 `let _ = instanceAt(i)`，并补注释「预实例化，失败即加载期拒绝」。

### [轻微][存量] `compileRegex` 的计数在真正构造之前自增，编译失败也计数

- **位置**：`f_jit/src/bytecode/ConstRegistry.cj:455-460`
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §11（语义与注释不符）
- **证据**：静态确定 —— 注释（`:57-60`）写「每真正构造一次 `Regex` 就 +1」，实现是先 `+1` 再 `pattern.regex(...)`，`catch` 里直接 `rejectRegex`。
- **建议**：把自增移到 `try` 成功之后（或在 catch 里回退），并在注释里点明「失败不计」。

### [轻微][存量] `flags.bit0`（UTF-8 恒 1）从未校验

- **位置**：`f_jit/src/bytecode/FbcReader.cj:199-204`
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §11（规格与实现不符）；规格源 `f_jit/src/bytecode/FbcHeader.cj:47-48`「bit0：UTF-8 语义（§11.6 记为「恒 1」）」
- **证据**：静态确定 —— `validate` 只拒「未知位」与 `bit1`，`flags = 0` 或 `flags = 4` 都能通过；`assert` 表（`FbcReader.cj:35-47` 的 11 类）里也没有这一条。
- **描述**：写方恒置 1（`FbcWriter`/测试都这么写），读方不校验属宽松接受，不改变语义；仅在与「恒 1」的冻结决策对齐上留了缺口。
- **建议**：若要守「恒 1」，加 `if ((h.flags & FbcFlags.UTF8) == 0u32) rejectFormat(...)` 并补用例；若有意宽松，在 `:198` 注释里写明「bit0 不校验，语义固定 UTF-8」。

### [轻微][存量] 测试与实现漂移：kind 11 已被接受，用例注释仍称「M3 才登记」

- **位置**：`f_jit/src/bytecode/ConstPayload_test.cj:319-330` vs `f_jit/src/bytecode/ConstRegistry.cj:623-632`
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §13（测试注释作为契约描述已过期）/ §2（同一事实两处不一致）
- **证据**：静态确定 —— `ConstRegistry.decodePayload` 的 `case 11u8` 已把 JSON 当合法 kind（`ConstKind.JSON`，`ConstPayload.cj:53`），用例注释却写「非法 kind 11（M3 才登记）」；该用例真正被拒的原因是只写了 `kind` 没有载荷字节（`ByteReader` 越界），断言「拒绝」成立但验证的是错的东西。
- **建议**：把该分支改成两类用例：kind 12+ 才算「未知 kind 拒绝」；kind 11 补一条合法 JSON 载荷的正向用例，注释同步 M3 口径。

### [轻微][存量] 测试命名/注释/导入的三处小漂移

- **位置**：`f_jit/src/base/TypeToken_test.cj:90-105`（函数名 `tokensCoverExactlyTheNineHandleTypes`，断言却是 11 个）、`f_jit/src/base/TypeToken.cj:21-26`（类注释的 token 表未列 12=Any，而 `:61` 有 `ANY = 12`）、`f_jit/src/bytecode/FbcHeader_test.cj:22`（`import fountain::f_base.*` 全文无使用）、`f_jit/src/base/SourceCompileException_test.cj:91`（`text.contains('1')` 断言过弱，消息里任意含 `1` 的字符都满足）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §1（未使用 import）/ §13（注释与实现不一致）/ §10（测试断言有效性）
- **证据**：静态确定 —— `FbcHeader_test.cj` 全文无 `f_base` 符号（`Version`/`SourcePos` 来自 `f_jit.base`，`Crc32` 单独 import）；`hit` 断言为 11、循环 `4..15` 也是 11 项，函数名里的 Nine 是旧版残留；`TypeToken` 类注释表止于 11。
- **建议**：改名 `tokensCoverExactlyTheHandleTypes`、类注释补 `12=Any`、删无用 import、把 `contains('1')` 换成对 `MissingArrow` 与行号 `1` 的精确断言（如 `text.contains('1:10')`）。

<!-- 第 29 部分 -->

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

<!-- 第 30 部分 -->

### [一般] 终结语（RET/RET_VOID/ABORT）之后的簿记不重置，且汇编期对栈下溢只钳位不拒绝

- **位置**：`f_jit/src/compiler/BytecodeBuilder.cj:332`（`ret`）、`:337`（`retVoid`）、`:349`（`bail`）、`:241`（`place` 置 `reachable = true`）；`f_jit/src/compiler/Assembler.cj:255`（`depth` 钳位）
- **来源**：存量（快照无基线）
- **判据**：review-checklist §11（语义与注释不符 / 缺少边界校验）+ §7 校验 3 的落地声明
- **证据**：静态确定 —— ① `BytecodeBuilder` 字段注释（`BytecodeBuilder.cj:52`）明写「无条件跳转 / 终结语之后…为伪 dead code」，但 `emitRel`（`:182`）只对 `JMP`/`LOOP_BACK` 置 `reachable = false`，`ret`/`retVoid`/`bail` 三个终结语一个都没置，也未清 `slots`/`depth`（`ret` 只是 `this.depth = 0`，`slots` 保留跨 RET 的陈旧槽号）；② `StackEffect.isTerminator`（`f_jit/src/compiler/Ops.cj:501`）本就存在却零调用（全仓 grep 仅定义处命中），构建器没有用它；③ 汇编期 `Assembler.validateFunc` 的 `if (pop >= 0)` 分支里 `depth = if (depth >= pop) { depth - pop + push } else { push }`，下溢被静默改写而非 `codeFail`，`slots` 的弹出循环也有 `!slots.isEmpty()` 兜底；④ `Ops.cj:303` 注释声称「终结语的 `pop` 只用于 validator」，实际 validator 从不因下溢拒绝。
- **描述**：`RET` 在 `OpInfo` 里是 `(pop=1, push=0)`。如果降低器（或任何调用方）在栈上没有返回值时发 `RET`，`BytecodeBuilder` 因为绕开 `account()` 不会报错，`Assembler` 也只会把深度钳回 0，于是「sink 前回到帧基线」这条校验在**唯一的出口指令上不成立**；同理，终结语之后若再发指令（目前 Lowerer 不这么做），`place()` 会以 RET 留下的 `depth=0` 与跳转点深度比对，可能报出误导性的「分支汇合栈深不等」，而 `Assembler` 的 `CALL_HOST` 判据会读到跨 RET 的陈旧 `slots` 槽号，校验结论不可信。
- **建议**：`ret`/`retVoid`/`bail` 统一走 `account()`（或显式调用 `StackEffect.isTerminator`），在其中置 `reachable = false` 并清空 `slots`；`Assembler.validateFunc` 把 `depth < pop` 改成 `codeFail`（与 `BytecodeBuilder.account` 同一口径），不要钳位。

### [轻微] 生产代码里的死成员与不可达辅助函数

- **位置**：
  - `f_jit/src/compiler/BytecodeBuilder.cj:245` `fixupRel`、`:389` `constsOf`、`:394` `fnIdOf`、`:365` `setSlotType`
  - `f_jit/src/compiler/Capture.cj:114` `CaptureDescriptor.describe`、`:89` `invalidEntries`、`:47` `CaptureOrigin.isInvalidIfEscapes`
  - `f_jit/src/compiler/Capture_test.cj:187` `err`
- **来源**：存量（快照无基线）
- **判据**：review-checklist §1（无调用者 / 恒假分支 / 兼容残留）
- **证据**：静态确定 —— 全仓（排除 `.worktrees`）grep：`fixupRel`、`constsOf`、`fnIdOf`、`setSlotType`、`.describe()` 均只命中定义处；`BytecodeBuilder`/`CaptureOrigin` 都是 `internal`/`protected` 顶层类型，其 `public` 成员对外不可达，按硬原则二应判死代码。`Capture_test.err` 是 `private static`，本文件内与被引处均无调用（Q3.10 放开捕获白名单后，拒绝面用例已被删除，此辅助函数是残留）。`invalidEntries`/`isInvalidIfEscapes` 的唯一调用点是 `Lowerer.cj:3248` 的 `if (desc.escaping && !Lowerer.ALLOW_ESCAPING_HANDLES)`，而 `ALLOW_ESCAPING_HANDLES` 是 `private static const ... = true`（`Lowerer.cj:162`）⇒ 该分支恒假（Lowerer 属范围外，此处只作为可达性证据引用）。
- **描述**：`fixupRel` 的文档注释写「保留该成员是为了让「回填时机」可被用例观察」，但仓内没有任何用例调用它；它的函数体与 `patchAll`（`BytecodeBuilder.cj:522`）逐行同语义（同为「按 label 过滤 fixups 并 patch」），属「文档声明保留 + 实际无用」的双重残留。`describe()` 生成的 `name:来源` 文本与 `Lowerer.cj:3253` 内联拼装的错误文案重复，但没有任何调用方。
- **建议**：删除 `fixupRel`/`constsOf`/`fnIdOf`/`setSlotType`/`describe`；`invalidEntries`+`isInvalidIfEscapes` 与 `ALLOW_ESCAPING_HANDLES` 一起清掉或改成显式开关（保留则补注释说明为何留着恒假路径）；删 `Capture_test.err`。

### [轻微] `AstExpr.MemberName` 无任何构造点，14 处 `match` 分支为死分支

- **位置**：`f_jit/src/compiler/Ast.cj:244`（构造器声明）、`:302`（`pos()` 分支）；死分支另见 `AstShape.cj:106`、`DefiniteAssignment.cj:293`、`:424`、`Lowerer.cj:578`、`:1132`、`:2265`、`:2329`、`:2584`、`:3369`、`:3433`、`:3492`、`:3801`、`Parser.cj:607`
- **来源**：存量（快照无基线）
- **判据**：review-checklist §1（兼容残留 / 恒假 case）
- **证据**：静态确定 —— `grep -rn "AstExpr.MemberName("`（排除 `.worktrees`）共 14 处，**全部**是 `case AstExpr.MemberName(...)` 模式匹配，没有一处是 `AstExpr.MemberName(...)` 构造；`Parser.cj` 只产出 `FieldGet`/`FieldSet`/`MethodCall`/`CtorCall`（`Parser.cj:605-606`、`:1014-1018`、`:1034`），仅剩 `:607` 的 `case AstExpr.MemberName(...) => Assign` 一条依赖该节点。
- **描述**：`Ast.cj:244` 的注释写「M1 成员访问的预留位（M2 解析器改为产出 `FieldGet`；保留供旧路径/诊断）」，但「旧路径」已不存在，14 处分支永远不可达，占用四个文件的 `match` 篇幅，且 `Lowerer` 里 9 处分支会误导读者以为还有一条成员访问路径。
- **建议**：删除该构造器及其 14 处分支（含 `Parser.cj:607` 的改写规则），若确需保留则加 `@Deprecated` 语义的注释并补一个「不可达」用例说明。

### [轻微] `Assembler.cj` 两个 import 未使用

- **位置**：`f_jit/src/compiler/Assembler.cj:21`（`DecodedInsn`）、`:27`（`InsnDecoder`）
- **来源**：存量（快照无基线）
- **判据**：review-checklist §1（未使用的 import）
- **证据**：静态确定 —— 文件内 `DecodedInsn`/`InsnDecoder` 只在注释 `:181`「不再调用 `InsnDecoder.decode`」出现，代码无引用；`effectArgc`/`loadedSlotOf` 已改为直读字节（`:294`、`:306`）。
- **描述**：`optimize-compile-hotpath` 改造把 `InsnDecoder.decode` 换成了下标直读，但 import 没跟着删，属改造残留。
- **建议**：删这两行 import。

### [轻微] `BytecodeBuilder.place` 中 `!labelIsSink[label]` 恒真，且若成立会留下未回填 fixup

- **位置**：`f_jit/src/compiler/BytecodeBuilder.cj:214`
- **来源**：存量（快照无基线）
- **判据**：review-checklist §1（恒真恒假分支）
- **证据**：静态确定 —— `labelIsSink.add(false)` 在 `newLabel`（`:194`）对每个标签写 `false`，唯一把它置 `true` 的是 `placeBail`（`:428`）对 `bailLabel`（0）；`bailLabel` 由构造函数私有持有（`:67`、`:82`），从不传给 `place`，因此 `place` 执行时该位恒为 `false`。
- **描述**：这个守卫永远不生效；更糟的是它**反向**保护了一片危险逻辑——一旦 `place` 遇到 sink 标签，`if` 体内的回填+过滤整段被跳过，`fixups` 会残留到 `finish()` 并报「存在未回填的跳转目标」，即该分支若被触发是错误行为而不是安全兜底。
- **建议**：删掉条件（直接执行回填）或改成 `if (this.labelIsSink[label]) { codeFail(...) }`，让不可达路径显式失败。

### [轻微] 栈账的 `argc` 口径两份逐字相同的实现

- **位置**：`f_jit/src/compiler/Assembler.cj:293`（`effectArgc`）与 `f_jit/src/compiler/BytecodeBuilder.cj:484`（`argcOfInsn`）
- **来源**：存量（快照无基线）
- **判据**：review-checklist §2（只改类型名/位置的重复）
- **证据**：静态确定 —— 两函数体语义完全一致：`CALL_HELPER|CALL_HELPER_NC|CALL_HELPER_V|CALL_FUNC → code[off+3]`，`CALL_CLOSURE|CALL_HOST → code[off+1]`，其余 `0`；差异只有「读 `this.code` 还是参数传入的 `code`」。
- **描述**：`Ops.cj:299` 明确要求「`BytecodeBuilder` 与 `Assembler` 的栈账必须同源，否则会出现永假分支」，而 `argc` 的取法恰恰是同源的**唯一例外**——新增一个 `CALL_*` 家族指令时，只改一处就会让构建期 `maxStack` 与汇编期校验口径漂移（前者按 argc 弹栈，后者按 0 弹栈）。
- **建议**：把 `argc` 提取抽成包内一个函数（如 `StackEffect.argcOf(op, code, at)`），两处共用。

### [轻微] 同包/跨包已有原语却又各写一份：hex 格式化 3 套、LE-u16 读 2 套、补码转换 2 套

- **位置**：
  - `f_jit/src/compiler/Assembler.cj:334`（`hex`）、`:340`（`hexDigit`）、`:317`（`u16At`）、`:496`（`toU32`）、`:505`（`toU64`）
  - `f_jit/src/compiler/CodeDump.cj:144`（`hex2`）、`:150`（`digit`）、`:165`（`u16At`）
  - `f_jit/src/compiler/Lexer.cj:906`（`hex2`）、`:910`（`hexDigit`）
  - `f_jit/src/bytecode/ByteCodec.cj:50`（`i32ToU32`）、`:68`（`i64ToU64`）
- **来源**：存量（快照无基线）
- **判据**：review-checklist §2（字面量/换算复制）+ §11（注释与实现不符）
- **证据**：静态确定 —— `Assembler.hexDigit` 与 `Lexer.hexDigit` 都是同一个 16 分支 `match`（前者大小写 A–F，后者 `case 0..13` + `case _`）；`CodeDump.hex2` 是同一算法的第三份（小写 a–f，`v < 10` 走 `toString()`）；`Assembler.u16At` 与 `CodeDump.u16At` 同在小端 u16 读取上重复；`BytecodeBuilder.toU32/toU64` 与 `ByteCodec.i32ToU32/i64ToU64` 表达式逐字相同（`UInt32(v + 2147483647 + 1) + 0x80000000u32` 等）。
- **描述**：① 诊断文本的 hex 大小写已经漂移：`Assembler` 的错误消息是大写（`0x${Assembler.hex(...)}`），`CodeDump` 的 dump 文本是小写（`Builder_test.cj:65` 断言 `11feffffff`），同一次编译的两类输出风格不一致；② `BytecodeBuilder.cj:495` 的注释理由「与 bytecode 包同款，不引入跨包依赖」不成立——本文件已 import 该包三个类型（`:20-22`），真实原因是 `ByteCodec` 的转换函数是 `internal`（包内可见）无法跨包复用；③ 重复的直接后果在范围外文件上已经显现：`Lexer.hexDigit` 的分支写成了 `case 0..13` + `case _ => 'F'`，**14（0xE）会输出 `F`**（`Lexer.cj:910-930`，范围外提示，不计入本部分统计）。
- **建议**：包内收敛到一份 `hex2`/`hexDigit`/`u16At`（`CodeDump` 已在小写口径上被多处断言，建议以它为准并让 `Assembler` 复用）；把 `ByteCodec` 的 `i32ToU32`/`i64ToU64` 提为 `public` 后删掉 `BytecodeBuilder.toU32/toU64`，同时修正那条不成立的注释。

### [轻微] `boxesAtAnyReturn` 名不副实：声称覆盖 ③「Any 返回装箱」，实际只断言 0 装箱

- **位置**：`f_jit/src/compiler/AnyFrontend_test.cj:128`（文档注释）与 `:130`（断言）
- **来源**：存量（快照无基线）
- **判据**：review-checklist §14（承诺与实现不符：测试承诺的覆盖面不存在）
- **证据**：静态确定 —— 用例体只有两条 `countOf(..., 'CALL_HELPER 78,2') == 0` 的断言（`:133`、`:136`），一处是「无 Any 目标」对照、一处是「形参已是 Any 同型直传」；全文件 `grep 'CALL_HELPER 78,2'` 的正向断言只覆盖 ①初始化/赋值、②实参、④容器元素，没有任何用例断言「闭包尾表达式需要装箱到 Any」这一插入点。
- **描述**：`AnyFrontend_test.cj:31-36` 头注释把「四类装箱插入点」列为断言口径，③ 这一类实际只做了负向对照，测试名与注释会让人误判 M3 §3 第 ③ 类插入点已被验证。
- **建议**：补一条正向用例（形如 `{ f: (Int64) -> Any => ... }` 的宿主闭包签名 + 返回值装箱，或在 `Any` 形参调用后取回），或把用例名/注释改成「③ 无装箱对照」。

### [轻微] 恒真断言：`TCase.hit(..., true)` 7 处 + `t1GoldenUnitLoad` 的尺寸自比

- **位置**：`AnyCast_test.cj:171`、`:184`；`AnyContainer_test.cj:53`、`:65`；`AnyFrontend_test.cj:209`、`:219`、`:270`；`Acceptance_test.cj:62`（`let id = raw.size == copy.size`，`:63` 断言）
- **来源**：存量（快照无基线）
- **判据**：review-checklist §11（弱断言）+ §14（覆盖率虚报）
- **证据**：静态确定 —— `TCase.hit` 的实现是 `public static func hit(id: String, ok: Bool): Bool { if (id.isEmpty()) { return false }; ok }`（`f_jit/src/test/TCase.cj:32-37`），不登记任何全局状态；上述 7 处第二个实参直接写字面量 `true`，因此 `@Assert(..., true)` 恒成立，`id` 字符串不产生任何可核查的覆盖记录。`Acceptance_test.t1GoldenUnitLoad` 的 `copy` 由 `Array<UInt8>(raw.size, ...)` 构造，`raw.size == copy.size` 恒真。
- **描述**：这些行只产出「测试通过」的噪声：它们既不校验行为，也不登记 T 矩阵，与本模块自己在 `Acceptance_test.cj:305-308` 批评的「矩阵虚报」是同一种形态。
- **建议**：把第二个实参换成该用例真正的判据（多为上方已有断言），或让 `TCase.hit` 真正登记 id 并在结束时校验；`t1` 的尺寸自比删掉或改成对内容逐字节相等（`raw == copy`）。

### [轻微] `A64Exec_test.runUnit` 失败路径资源不对称

- **位置**：`f_jit/src/compiler/A64Exec_test.cj:276`（`CodeBuffer.alloc` 失败即 `return`）、`:319`（`compileUnitWith` 返回 `None` 即 `@Fail`，`table` 未释放）
- **来源**：存量（快照无基线）
- **判据**：review-checklist §11（资源不对称：成功路径 `table.free()`/`mirror.free()` 在 `:312-316`，失败路径没有）
- **证据**：静态确定 —— `FnTable.alloc`（`:270`）与 `ownMirror`（`:265-267`）在 `:276-279` 与 `:319` 两个早退/失败分支上都没有对应 `free()`，只有 `:312-316` 的 `case Some(art)` 尾部释放。
- **描述**：单次运行泄漏一个原生 FnTable 与一个常量镜像；测试进程内重复跑失败用例会累积（`A64Exec_test` 只在小架构下跑，影响有限，但形态与生产代码的资源治理一致，应修）。
- **建议**：用 `try/finally` 或在两个失败分支补 `table.free()` / `ownMirror` 的 `free()`。

### [轻微] 可读性：重复的 doc 注释块与错位缩进

- **位置**：`f_jit/src/compiler/A64Exec_test.cj:213`（孤立注释）+ `:214`（真正的用例注释）；`f_jit/src/compiler/BytecodeBuilder.cj:315`（孤立注释）+ `:320`（真正的成员注释）；错位缩进 `A64Exec_test.cj:301-307`、`:332-344`
- **来源**：存量（快照无基线）
- **判据**：review-checklist §10（可读性 / 必要注释）
- **证据**：静态确定 —— 两处都是两个相邻的 `/** ... */` 块：前者（`A64Exec_test.cj:213`「编译整单元 → 单块 CodeBuffer → …」、`BytecodeBuilder.cj:315`「`CALL_HOST argc`：栈 `[h_fn, a1..an]`…」）后面紧跟另一条注释，被孤立；`A64Exec_test` 的 `let argv = if (...)` 与 `result = unsafe { f(...) }` 段缩进比所属代码块浅 4 格，视觉上像是跳出了 `if`/`match` 块（仓颉按花括号定界，语义不受影响）。
- **描述**：孤立注释会被误读为「该函数/该用例的说明」，错位缩进会让读者误判作用域，属维护成本。
- **建议**：删除被孤立的注释块（内容已被后一条覆盖），修正 `A64Exec_test.cj:301-307`、`:332-344` 的缩进。

### [轻微] `Ast.cj` 的构造器清单注释缺 8 个构造器

- **位置**：`f_jit/src/compiler/Ast.cj:195`（「参数序（与设计稿一致，末位为位置）」清单）
- **来源**：存量（快照无基线）
- **判据**：review-checklist §11（注释与实现不符）
- **证据**：静态确定 —— 注释列了 18 个构造器（`Lit`…`Index`、`MemberName`），`AstExpr` 实际有 26 个；缺 `IndexTarget`、`FieldGet`、`FieldSet`、`MethodCall`、`CtorCall`、`CastOr`、`IsType`、`JsonLit`（各自在 `:243`、`:247`、`:249`、`:251`、`:253`、`:262`、`:270`、`:279` 有独立文档行，但总清单没跟上）。
- **描述**：读者按头部清单核对参数序时会漏掉 M2/M3 新增的 8 个节点。
- **建议**：把清单补全（或改成指针「见各构造器文档行」，避免二次维护）。

### [轻微] `Assembler` 类注释声称 `FbcReader` 复核「数据流」，与实现和自身函数注释矛盾

- **位置**：`f_jit/src/compiler/Assembler.cj:45`（「数据流与类型表合法性由 `FbcReader` 加载期复核（同一口径的双保险）」）
- **来源**：存量（快照无基线）
- **判据**：review-checklist §11（注释与实现不符）
- **证据**：静态确定 —— `FbcReader` 侧只有结构/目录/类型表/常量/站点覆盖校验（`FbcReader.cj:32-45` 的 11 类拒绝清单），全文件没有 `StackEffect`、没有栈深或分支汇合分析（grep `StackEffect|depth` 零命中）；同一文件 `:150` 又写「3 由 `BytecodeBuilder` 构建期即时拒绝」——两句对「校验 3 落点」的说法互相冲突，而实际落点只有 `BytecodeBuilder`。
- **描述**：这条注释会让人以为「手写/异常字节流在加载期还有第二道栈平衡防线」，实际上加载期不做数据流校验（与「发现 #1」叠加后，`RET` 的栈不平衡没有任何环节拒绝）。
- **建议**：把「数据流」改为「目录/类型表/站点覆盖」，或在 `FbcReader` 侧补栈平衡校验后再保留该表述。

<!-- 第 31 部分 -->

### [严重] `DefiniteAssignment.walkExpr` 对 AST 深度无上限递归 → 编译期栈溢出

- **位置**：`f_jit/src/compiler/DefiniteAssignment.cj:197`（`walkExpr`）、`:219-221`（`Binary` 递归左右子树）、`:241-243`（`Closure` → `analyzeClosureAt` → `walkBlockWithOuter` 递归）
- **来源**：存量
- **判据**：review-checklist §4（无界递归 / 深度由输入决定）
- **证据**：静态确定 —— 深度上界推导：`Parser.parseAdditive` 等二元层是 `while` 循环（`f_jit/src/compiler/Parser.cj:907-911`），所以 `a + a + a + …` 形成**左深链** `Binary(Binary(…), r)`，节点数 = 运算符个数，而 `walkExpr` 每层递归只下探一个子节点。链条长度由源码长度直接决定，`SourceCompiler.compile` 与 `Lexer`/`Parser` 全链路**没有任何源码长度或 AST 深度上限**（`grep "MAX_\|maxSource" src/Compiler.cj src/CompilePipeline.cj` 无命中）。DA 在管线中先于降低执行（`f_jit/src/compiler/SourceCompiler.cj:124` vs `:128`），因此它是「Parser 成功后第一个全 AST 递归遍历」，溢出点落在本文件而不是 Lowerer
- **描述**：宿主把一段含数万个 `+` 项（或数万层嵌套闭包 / 列表字面量）的源码交给 JIT 时，`walkExpr` 递归深度与项数同阶；按常见 8MB 线程栈与 `walkExpr` 每帧数十~上百字节估算，量级在数万层即可能触顶（**具体阈值未实测**）。后果是栈溢出导致编译进程崩溃，而设计文档要求编译期错误只有一个出口（`SourceCompileException`，`Diag.cj:22-30`），栈溢出绕过了该出口
- **建议**：给 `walkExpr`/`walkStmt` 加显式深度计数（如 `depth: Int64` 形参，超过常量上限抛 `SourceCompileException(CODE_GEN)`）；或改为显式工作栈迭代。同类问题在 `Lowerer` 也存在，建议作为一条统一的「AST 遍历深度上限」改造，而不是只在 DA 打补丁

### [一般] DA 用平铺名字表，和 Lowerer 的块作用域不一致 → 同名遮蔽时既漏拒也误拒

- **位置**：`f_jit/src/compiler/DefiniteAssignment.cj:83-87`（`walkBlock` 全程共用同一个 `state`）、`:167`（`AstStmt.Block` 直接复用外层 `state`）
- **来源**：存量
- **判据**：review-checklist §11（契约与实现不符）/ §10 正确性；对照实现 `f_jit/src/compiler/Lowerer.cj:94-113`（`pushScope`/`popScope` + 只在**同一层**查重名）、`:517-521`（块语句 push/pop 作用域）
- **证据**：静态确定 —— 降低期把 `{ … }` 当独立作用域（同名可遮蔽，仅同层重复定义报错，`Parser.cj:483-486` 允许 `{ … }` 作为独立语句），而 DA 的 `state` 是「名字 → 是否已赋值」的**单层**表，块内声明直接改写外层同名条目
- **描述**：两处偏差方向相反，都可由合法源码触发（`Lowerer` 接受这两种写法）：
  - 漏拒（读到 0 填充）：`{ => var x: Int64\n { let x: Int64 = 1 }\n x }` —— 内层遮蔽声明把 `state[x]` 置 `true`，外层 `x` 的读取被放行；降低期外层 `x` 是另一个槽且从未赋值，读到 prologue 的 0，违反 §3.1「零值填充不可观察」（`doc/jit-bytecode-m1.md:145`）
  - 误拒（合法程序被拒）：`{ => let x: Int64 = 1\n { var x: Int64 }\n x }` —— 内层 `var x` 把 `state[x]` 置 `false`，外层 `x` 的读取报 `NOT_ASSIGNED`
- **建议**：给 DA 引入与 `Lowerer` 对齐的作用域栈（`Array<HashMap<String,Bool>>`，进出块 push/pop；未命中再向外层查），`walkStmt(Binary)` 的 `ForIn`/`While` 体克隆语义保持现状

### [一般] 闭包体遍历与主遍历是两份平行实现且已漂移，闭包内 `for-in` / 多重赋值 / 下标目标 不校验外层捕获

- **位置**：`f_jit/src/compiler/DefiniteAssignment.cj:350-448`（`walkExprWithOuter`，兜底 `case _ => this.walkExpr(e, state)` 在 `:447`）、`:451-485`（`walkStmtWithOuter`，兜底 `case _ => this.walkStmt(s, state)` 在 `:483`）
- **来源**：存量
- **判据**：review-checklist §2（重复逻辑导致的行为漂移，同一判据必须两处同步）+ §11（契约不符）
- **证据**：静态确定 —— 两处 `match` 的差异点逐个比对：① `AstStmt.ForIn` / `AstStmt.MultiAssign` 无外层版本分支 → 落兜底，用**内层** `state` 走 `walkStmt`，外层名字查不到即 `return`（`:212-218` 的「未声明就放行」）；② `AstExpr.IndexTarget` 同样落兜底；③ `AstExpr.Interp` 两版口径不同（外层版 `:387-390` 遍历全部 parts，主版 `:249-255` 只走奇数下标）
- **描述**：契约要求「捕获未赋值变量 → 编译错误」（`doc/jit-bytecode-m1.md:1152`、T24），且捕获确实由降级期从父作用域解析（`Lowerer.cj:250` `findIn(parent, …)`、`:3324`），说明**读外层名不报错就是被捕获**。于是 `{ => var t: Int64\n let f = { => for (i in [1]) { let _ = t } }\n 0 }` 这类源码不会被 DA 拒绝，闭包捕获到的是未赋值槽的 0 值 —— 正是 §3.1 声明「不可观察」的那个值。差异点的存在意味着两版遍历必须人工同步，后续新增 AST 形态必然继续漏
- **建议**：把两版遍历合并为一版，用「内层/外层两层查找函数」参数化（`lookup: (String) -> ?Bool`），彻底消除平行实现；或至少把兜底分支改成「上报未处理形态」的 `codeFail`，避免静默降级

### [一般] 空安全规则 3 在「赋值语句」路径上恒放行（`typeOf` 被接成常量 `NONE`）

- **位置**：`f_jit/src/compiler/DefiniteAssignment.cj:495-521`（`checkNullStore`，`:514` 取 `this.typeOf(name)`）、`:102-109`（`Assign` 走 `checkNullStore(n, None, …)`）；接线点 `f_jit/src/compiler/SourceCompiler.cj:120`（`{ _ => LocalType.NONE }`）
- **来源**：存量
- **判据**：review-checklist §11（契约与实现不符）/ §14.1（接线缺失）；契约源：本文件 `:32-33`「空安全：句柄型局部恒为有效句柄 ⇒ `PUSH_NULL` 不得作为其赋值源直存」+ `doc/jit-bytecode-m1.md:683`（校验 10）
- **证据**：静态确定 —— `SourceCompiler` 传入的 `typeOf` 是恒返回 `LocalType.NONE` 的闭包（源码注释自认「保守放行」），所以 `Assign` 分支的 `code` 恒为 `NONE`、`LocalType.isHandle(code)` 恒假，该分支**永不报错**；只有 `Decl` 带显式类型注解（`ty: Some`）时才真正生效。Lowerer 侧也不补这道检查（`emit(Op.PUSH_NULL)` 在 `Lowerer.cj:1261-1262`，无目标槽类型校验）
- **描述**：``{ => var o: JsonArray = `[]`\n o = null\n 0 }`` 通过编译并把 0 写进句柄型槽，违反「句柄型局部恒为有效句柄（≠0）」；后续使用该槽只能落到 helper 边界的 0 句柄防御码（6），把编译期错误降级成运行期错误。规则 3 只在「声明即初始化且带注解」这一条窄路径成立
- **建议**：`Assign` 分支同样需要变量的静态类型：把 `typeOf` 接到 Lowerer 已有的槽类型表（`FnCtx.scopes` 的 `VarSym` 带 `LocalType`），或至少在 `Assign` 目标类型未知时改为「查不到就拒」的显式策略，并把 `NONE` 兜底写进注释与规格，避免块注释继续承诺已实现

### [一般] `\u{…}` 码点转义无上界校验，可生成非法 UTF-8，绕过「编译错误唯一出口」

- **位置**：`f_jit/src/compiler/Lexer.cj:550-566`（`escapeLen` 允许 1–6 位十六进制，最大 `0xFFFFFF`）、`:668-685`（`decodeEscapes` 的 `\u` 分支）、`:699-715`（`appendUtf8` 无 `U+10FFFF` / 代理区校验）
- **来源**：存量
- **判据**：review-checklist §11（缺少边界校验、错误处理不一致）；契约源：`Diag.cj:22-26`「全部失败统一走 `SourceCompileException`」
- **证据**：静态确定 —— `digits > 6` 是唯一上界（`:563`），`appendUtf8` 对 `cp ≥ 0x10000` 直接按 4 字节编码（`:709-714`），对 `0xD800–0xDFFF` 按 3 字节编码，两者都不是合法 UTF-8；`0xFFFFFF` 会编出 `0xFF…` 首字节
- **描述**：`"\u{110000}"` / `"\u{FFFFFF}"` 在词法层被判为合法转义，随后 `String.fromUtf8(out.toArray())`（`:695`）收到非法字节序列，行为取决于标准库（抛非 `SourceCompileException` 异常或替换字符），与「非法转义 → `BAD_ESCAPE`」的既有策略和「唯一出口」契约都不一致；同一段非法字节还会进入常量表
- **建议**：在 `escapeLen` 的 `\u{…}` 分支补 `cp <= 0x10FFFF && !(0xD800..=0xDFFF)` 校验并抛 `DiagKind.BAD_ESCAPE`（与 `digits == 0` 同级），`appendUtf8` 保留为「调用点已保证合法」的内部函数

### [轻微] `ClassRegistryView` 三个成员全模块零引用（对外不可达的 `public`）

- **位置**：`f_jit/src/compiler/ClassRegistryView.cj:185`（`registeredList`）、`:201`（`isHostObjectCode`）、`:206`（`isValueCode`）
- **来源**：存量
- **判据**：review-checklist §1 硬原则二（顶层声明是 `protected class`，其 `public` 成员对外不可达 → 全项目无使用即死代码）
- **证据**：静态确定 —— `grep -rn "isHostObjectCode\|isValueCode\|registeredList" f_jit/src` 只命中定义处本身（`registeredList` 的另外 3 处命中属 `PredefinedSnapshot.cj:101/162/181` 的同名方法，与视图无关）
- **描述**：三者均为诊断/分析辅助，实现完成后没有接线。`registeredList` 与 `PredefinedSnapshot.registeredList` 同名同形，容易被误认为已在错误消息里使用（实际错误消息用的是 `PredefinedSnapshot` 那份）
- **建议**：删除三者；若 `isHostObjectCode` / `isValueCode` 是给 Lowerer 预留的类型码判定，改为在 Lowerer 内直接比较 `LocalType` 常量并补用例，不要留悬空 API

### [轻微] `Lexer` 两处不可达分支（恒定不成立）

- **位置**：`f_jit/src/compiler/Lexer.cj:466-468`（`scanRawString` 的 `if (hashes < 1)`）、`:515-519`（`findBodyEnd` 三引号分支里的 `oddBackslashesBefore` 判定）
- **来源**：存量
- **判据**：review-checklist §1（恒真恒假分支 / 不可达语句）
- **证据**：静态确定 —— ① `scanRawString` 只由 `scanOne` 在 `bs[cur] == '#'` 时分派（`:260-262`），进入时 `hashes ≥ 1`；② `findBodyEnd` 每遇到 `\` 就用 `escapeLen` 连吃 ≥2 字节（`:507-509`，返回值恒 ≥2），所以游标 `p` 不可能停在一个「前一个字节是反斜杠」的引号上，`oddBackslashesBefore` 恒为 `false`
- **描述**：两处都是防御性写法但当前扫描路径下不可达，会让读者误以为存在「转义后不终止」的路径；`oddBackslashesBefore` 还引入了一次不必要的反向扫描
- **建议**：删除 `hashes < 1` 与 `oddBackslashesBefore` 调用；若担心未来扫描路径变化，改为注释说明「当前不可达，保留原因」

### [轻微] `f_jit/src/compiler/Compiler.cj` 是只剩 `package` 与占位注释的空骨架文件

- **位置**：`f_jit/src/compiler/Compiler.cj:16-18`
- **来源**：存量
- **判据**：review-checklist §1（兼容残留）/ §3（空实现）
- **证据**：静态确定 —— 文件仅 `package fountain::f_jit.compiler` 与一行「P0 骨架占位」注释，无任何声明；真正的门面是 `f_jit/src/Compiler.cj:34`（`public class Compiler`），`grep "compiler.Compiler" f_jit/src` 无命中
- **描述**：同一模块内存在同名文件（`src/Compiler.cj` 与 `src/compiler/Compiler.cj`），且后者内容为空，检索/阅读时极易走错；对构建也没有任何贡献
- **建议**：删除该文件（或改成真正的包级文档注释文件并明确它是文档而非骨架）

### [轻微] `checkNullStore` 的 `TypeRef → LocalType` 映射与 `TypeRef.code()` 完全重复，且用裸字面量

- **位置**：`f_jit/src/compiler/DefiniteAssignment.cj:504-513`；既有实现 `f_jit/src/compiler/Ast.cj:90-102`（`TypeRef.code()`）
- **来源**：存量
- **判据**：review-checklist §2（只改类型名的重复逻辑 / 字面量复制）
- **证据**：静态确定 —— 两段 `match` 分支一一对应（`Builtin(c)`、`AnyT`、`ListOf`、`MapOf`、`HostClosureT(_,_,_,_)`、`HostObjectT(_)`），返回码也相同；DA 侧还把 `15/10/11/13/14` 写成裸字面量，而 `LocalType.ANY/LIST/MAP/HOST_CLOSURE/HOST_OBJECT`（`f_jit/src/base/LocalType.cj:50-63`）已有同名常量
- **描述**：同一映射两处维护；`TypeRef` 增删变体时两处都必须改（编译器会因 `match` 非穷尽报错，不会静默漂移，但改动成本与误读成本翻倍）
- **建议**：`checkNullStore` 改为 `case Some(v) => code = v.code()`，删掉本地 `match`

### [轻微] `DefiniteAssignment.analyze` 返回恒为 `true` 的 `Bool`，三处调用全部丢弃

- **位置**：`f_jit/src/compiler/DefiniteAssignment.cj:66-77`（`:76` 直接 `true`）；调用点 `f_jit/src/compiler/SourceCompiler.cj:124`、`f_jit/src/compiler/Semantics_test.cj:184`、`f_jit/src/compiler/AstM2_test.cj:72`（后两处忽略返回值，前者写 `let _ =`）
- **来源**：存量
- **判据**：review-checklist §1（读了不用 / 返回类型无意义）
- **证据**：静态确定 —— 函数体唯一出口是 `true`，失败一律抛异常；三个调用点没有一个使用返回值
- **描述**：`Bool` 返回类型暗示「通过/不通过」，实际语义是「不抛即通过」，容易诱导调用方写 `if (analyze(...))`
- **建议**：改为 `Unit`，并同步三处调用点（`SourceCompiler.cj:124` 的 `let _ =` 可一并去掉）

### [轻微] `DiffExec_test.cj` 存在未使用的 import

- **位置**：`f_jit/src/compiler/DiffExec_test.cj:21`（`import fountain::f_jit.test.diff.AArch64Runner`）
- **来源**：存量
- **判据**：review-checklist §1（未使用的 import）
- **证据**：静态确定 —— 文件内 `DiffSession([InterpRunner(), NativeRunner()])`（`:67`、`:134`、`:144`），全文无 `AArch64Runner` 标识符
- **描述**：AArch64 差分由 `NativeRunner` 内部按平台选择，这个 import 是旧写法的残留；注释（`:28-31`）仍在描述 `AArch64Runner` 的「跳过」语义
- **建议**：删除该 import，并把注释改成指向 `NativeRunner`/`DiffSession` 的跳过口径

### [轻微] `CodeDump` 的逐行转储对截断字节流没有边界检查

- **位置**：`f_jit/src/compiler/CodeDump.cj:98-110`（`operandsOf`）、`:165-187`（`u16At`/`i32At`/`i64At` 直接读 `bs[off + k]`）、`:40-48`（`p = p + info.len` 不做 `p + info.len <= code.size` 校验）
- **来源**：存量
- **判据**：review-checklist §11（边界越界）
- **证据**：静态确定 —— `dump`/`ops` 只按 `info.len` 前移，`operandsOf` 对 `i64` 读 `code[p+1..p+8]`、对 `u16 u8` 读 `code[p+3]`，均未比较 `code.size`；`OpInfo` 表内没有 `len = 0` 项（`grep "len: 0" src/bytecode/OpInfo.cj` 无命中），因此不会死循环，但会越界
- **描述**：`CodeDump` 是「字节码断言/诊断」工具（`:22-32`），恰好在产物异常（被截断）时要使用；此时它会抛索引越界异常，把「产物不合法」伪装成工具崩溃。生产侧只有 `CodeDump.hex([op])` 被调用（`BytecodeBuilder.cj:457/461`），不受影响
- **建议**：`dump`/`ops` 在 `p + info.len > code.size` 时输出 `<truncated @p>` 并中断；`operandsOf` 先判 `code.size - p >= info.len`

### [轻微] `Lexer.tokenize` 的注释与生产调用不符（「生产路径只用 `next()`」）

- **位置**：`f_jit/src/compiler/Lexer.cj:100-111`
- **来源**：存量
- **判据**：review-checklist §11（语义与注释不符）
- **证据**：静态确定 —— 生产路径 `f_jit/src/compiler/Parser.cj:52` 就是 `this.ts = Lexer(this.src).tokenize()`，即 Parser 一次性物化全量 token（前瞻需要，`looksLikeClosure`/`looksLikeMapLiteral` 都基于 `this.ts`）
- **描述**：注释会让读者以为 `tokenize` 可以随时删除或改签名，实际上它是 Parser 的唯一入口；也掩盖了「每次编译物化全量 `Token` 数组」这一内存特征（见「优化可行性方案 · 堆内存」）
- **建议**：改写为「Parser 批量取词（前瞻需要）；`next()` 供流式/单测使用」

### [轻微] 可见性建议：`Lexer` 的 4 个访问器仅被测试引用

- **位置**：`f_jit/src/compiler/Lexer.cj:62`（`position`）、`:67`（`line`）、`:72`（`column`）、`:77`（`lastRegexFlags`）
- **来源**：存量
- **判据**：review-checklist §1「仅测试使用 → 可提可见性建议，不判死代码」
- **证据**：静态确定 —— `grep "\.position()\|\.line()\|\.column()" f_jit/src` 只命中 `Lexer_test.cj:304-306`；`lastRegexFlags` 只命中 `Lexer_test.cj:506/510/514/518`（`Lexer.cj:771-772` 的注释已说明 flags 改为随 `Token.flags` 送出）
- **描述**：`Lexer` 是 `internal class`，这 4 个 `public` 成员实际上只服务测试；`lastRegexFlags` 更是被 `Token.flags` 取代后的兼容面
- **建议**：`lastRegexFlags` 直接删除（并改测试断言 `ta.flags`）；`position/line/column` 若要保留为诊断辅助，建议加注释说明「仅测试/诊断」——**不建议**在不确认下游的情况下改可见性

<!-- 第 32 部分 -->

### [严重][存量] 无初始化的局部声明发射 `STOREL` 但求值栈上没有任何值

- **位置**：`f_jit/src/compiler/Lowerer.cj:406-411`（`initE == None` 分支只做类型检查）+ `:444-445`（无条件 `allocSlot` + `emitU16(Op.STOREL, …)`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11（缺省路径未处理 / 崩溃）；§3（分支缺实现）
- **证据**：静态确定 —— `Parser.cj:499-510` 允许 `let/var x: T` 不带 `=`（只要求带类型注解）；`DefiniteAssignment.cj:98-100` 明确支持并登记为「声明 ≠ 赋值」；`SourceCompiler.cj:117-129` 管线为 Parser → DefiniteAssignment → Lowerer → Assembler，中间**没有**补默认值的 pass。`initE == None` 时 Lowerer 既不 `PUSH_*` 也不写默认 cell，直接 `STOREL`。
- **描述**：`var x: Int64`（合法语法）降低为「空栈 + `STOREL slot`」。`Ops.cj:364` 声明 `STOREL` 的栈效应是 `(1, 0)`，但 `Assembler.cj:255-272` 对下溢只做 `depth = push` 的钳位（注释写明"分支造成的偏差不在此拒绝"），不会拒绝该函数；于是字节码进入运行期：`Interp.cj:310` 为 `f.locals[i] = f.pop()`，而 `f.pop()` 是 `stack.remove(at: size - 1)`（`Interp.cj:51-53`），空栈时下标为 -1；原生后端对应 `pop qword [rbp-32-8idx]`（`BackendSelector.cj:345`）读到栈外。后果是该单元第一条无初始化声明即崩溃，或把栈外脏值写进槽位，后续读取静默出错。
- **建议**：`initE == None` 分支按 `declared` 发射类型零值（`PUSH_I64 0` / `PUSH_F64` / `PUSH_BOOL 0` / `PUSH_NULL` 句柄 0），与 §11.7「值型槽存原始 cell、句柄型 0=null」一致；或在 Parser/前置校验直接拒绝此类声明（二选一，必须与 DefiniteAssignment 的口径统一）。同时给 Assembler 增加**严格**栈下溢拒绝（仅对非分支汇合点），避免同类问题再被钳位掩盖。

### [一般][存量] `& | ^ << >> ~` 没有类型校验，对 Float64 / Decimal / String / 句柄型直接发整型指令

- **位置**：`f_jit/src/compiler/Lowerer.cj:1426-1452`（`Amp` / `Pipe` / `Caret` / `Shl` / `Shr`）、`:1741-1743`（`Tilde`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11（语义与类型不符，静默产出错值）；§10 语言特性（类型分派不全）
- **证据**：静态确定 —— `promote`（`:1458-1475`）只在 `lt == rt` 时原样返回，因此 `1.5 & 2.5` 得到 `t == F64`、`"a" & "b"` 得到 `t == STRING`、`d1 & d2`（Decimal）得到 `DECIMAL`；随后 `Amp` 分支只有 `t == BOOL ? AND_B : BAND_I`（`:1426-1432`），`Shl`/`Shr` 完全无条件发 `SHL_I`/`SHR_I`（`:1447-1452`），`Tilde` 无条件 `BNOT_I`（`:1741-1743`）。
- **描述**：`F64`/`Decimal`/`String`/`DateTime`/`List` 等槽内是位模式或句柄 id，按整型做位运算后**类型码不变**：值型得到无意义的浮点/十进制位模式；句柄型得到越界或指向其它对象的句柄 id，后续 `STR_*`/`DEC_*` helper 按该 id 取句柄。编译期不报错，运行期静默错值或抛无关错误码。对照 `rejectStringArithmetic`（`:1289-1316`）只覆盖 `- * / %`，`rejectAnyOperand`（`:1275-1280`）只覆盖 15 型，二者都拦不住这条路径。
- **建议**：在 `lowerBinary` 的 `Amp|Pipe|Caret|Shl|Shr` 与 `lowerUnary` 的 `Tilde` 前置校验：`& | ^` 只允许 `(I64,I64)` 与 `(Bool,Bool)`（后者已实现），`<< >> ~` 只允许 `I64`；其余走 `diagFail(TYPE_MISMATCH)`。校验放在 `lowerExpr(l)`/`lowerExpr(r)` **之前**用 `staticTypeFull` 判定，避免先发指令再报错。

### [一般][存量] `if` 表达式用单一 `last*` 旁路传类型知识，多分支时取最后一支

- **位置**：`f_jit/src/compiler/Lowerer.cj:1013-1016`（每次 `lowerExpr` 入口重置 `lastObjectName` / `lastHostRet`）、`:1027-1041`（`IfExpr` 依次降低两分支后直接返回 `t1`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11（类型跟踪与实际不符）；§10 设计合理性（隐式单槽旁路）
- **证据**：静态确定 —— `let v = if (c) { a } else { b }`：两分支类型都为 `CLOSURE`（`t1 == t2` 校验通过）或都为 `HOST_OBJECT`，但 `lastClosureFnId`（`:156`）/`lastObjectName`（`:152`）只保留**后降低的那一支**（`else`），`Decl` 分支 `:403-405`、`:412-423` 用它写 `VarSym`。
- **描述**：`let f = if (c) { { => 1 } } else { { => "s" } }` 之后 `f(0)` 的静态返回类型取 else 分支的签名（String），而运行期可能走 then 分支返回 Int64；`let u = if (c) { user } else { addr }` 之后 `u.field` 按 `addr` 的字段表解析，命中即静默取错字段索引，未命中则误报「未注册字段」。`lastHostRet` 同理（13 型两个不同签名的宿主闭包）。这是「靠 `lowerExpr` 副作用回传」这一设计的必然缺陷，不是个别分支漏写。
- **建议**：把类型知识改为**返回值**（例如 `Lowered(evalType, objectName, hostRet, closureFnId)` 结构随 `lowerExpr` 一起返回），或在 `IfExpr`/分支结构里显式做「同类名取公共类、不同类名降级为 None」的合并；最省事的临时修法是 `IfExpr` 出口把 `lastObjectName` / `lastHostRet` / `lastClosureFnId` 全部清空（宁可丢知识也不要错知识）。

### [一般][存量] `lowerHostMethodCall` 把 HostObject 返回值一律记成**接收者类**，与 `hostObjectClassOf` 的 `retName` 口径矛盾

- **位置**：`f_jit/src/compiler/Lowerer.cj:2240-2245`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11（契约与实现不符 / 类型混淆）；§2（同一语义两套口径）
- **证据**：静态确定 —— 同文件 `hostObjectClassOf(MethodCall)` 已按注册期 `m.bind.retName` 取类名，并在注释里明确「旧实现返回**接收者**的类名……那是猜的，会让 `u.getAddr() as User` 通过静态检查（类型混淆）」（`:2298-2314`）；但 `lowerHostMethodCall` 仍写 `this.lastObjectName = if (m.bind.retType == HOST_OBJECT) { Some(className) } else { None }`。
- **描述**：`let v = u.getAddr()` 经 `Decl` 分支把 `v` 的 `objectName` 记成 `u` 的类。之后 `v.street` 走 `hostObjectClassOf(Var)` → `sym.objectName` → 用**错的类**查字段表：字段名恰好在两个类里都有时静默读错索引（数据错误），否则误报「未注册字段」（合法代码编译不过）。`retName` 为空（注册期未记返回类）时同样硬安接收者类，比「不知道」更危险。
- **建议**：与 `hostObjectClassOf` 对齐——`m.bind.retType == HOST_OBJECT && m.bind.retName != ''` 才写 `Some(m.bind.retName)`，否则 `None`（并让 `VarSym.objectName` 为 `None` 时下游按「类名未知」保守处理）。

### [一般][存量] 自递归/尾递归调用不校验实参个数，尾递归路径静默写错槽位

- **位置**：`f_jit/src/compiler/Lowerer.cj:805-842`（`tryLowerTailRecursive`，判据只有 `:812-814` 的 `args.size + base > slotCount()`）、`:2511-2520` / `:2569-2572`（非尾路径 `callFunc(entryFn, args.size)`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11（缺少边界校验，静默破坏状态）；§4（递归）
- **证据**：静态确定 —— `DefiniteAssignment.cj:286` 对 `RecursiveValue` 不做任何检查，`Parser.cj:1170` 只产出节点；Lowerer 中 `topParamTypes` / `closureParamsOf(fnId)` 已有真实形参个数可用，但两条路径都没比对。
- **描述**：`func f(a, b) { … f(x) }` 尾位置：`args.size=1`、`base=0`，只写 slot0，`b` 保留上一轮旧值，`LOOP_BACK` 后语义错乱且无任何诊断；多传时 `STOREL (i+base)` 覆盖到非形参槽（循环计数器、临时槽），破坏同帧状态。非尾位置则由 `Assembler.cj:228-231` 的 `codeFail('CALL_FUNC argc 不符…')` 兜住——那是**内部错误**文案，用户看到的是 codeFail 而不是源位置诊断。
- **建议**：`tryLowerTailRecursive` 与 `lowerCall` 的 `RecursiveValue` 分支共用一处 `requireArity(expected, args.size, pos)`：`expected = ctx.isClosure ? closureParamsOf(ctx.fnId).size : topParamTypes.size`，不等即 `diagFail(SYNTAX_ERROR, '自调用实参个数不符: 需要 n，实际 m')`；`slotCount` 启发式可随之删除。

### [一般][存量] `for-in` 对非 Range/Map/String/List 的可迭代表达式不报错，按 List 发 `LEN`/`GET_IDX`

- **位置**：`f_jit/src/compiler/Lowerer.cj:744-786`（`else` 分支：`isStr = itTy == STRING`，其余一律当 `LIST`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11（缺少边界/类型校验 → 运行期崩溃或脏值）
- **证据**：静态确定 —— 该分支只区分 `isStr`，`hSlot` 类型写死为 `LIST`（`:750`），随后无条件 `Op.LEN`（`:755`）与 `Op.GET_IDX`（`:774`）；`itTy` 为 `F64`/`BOOL`/`DATETIME`/`HOST_OBJECT`/`NONE` 时不进入任何 `diagFail`。
- **描述**：`for (x in 3)`、`for (x in someHostObj)` 编译通过，运行期对非容器句柄/位模式执行 `LEN` → 句柄越界或返回无意义长度，再按该长度循环 `GET_IDX`。用户拿到的是运行期错误码而不是源位置诊断，且 `NONE`（类型推不出）时会静默按 List 走。
- **建议**：在分支入口加白名单校验：`itTy ∈ {LIST, STRING}` 才走该分支，`NONE` 给出「无法推导可迭代表达式类型」的 `diagFail`，其余类型明确报「不支持 for-in 的类型：`${LocalType.name(itTy)}`」。`containerInfoOf` 对 `Index`/成员链返回 `NONE`，因此 `NONE` 分支必须报错而不是降级。

### [一般][存量] `parseInt64` 的上界检查把 `Int64.Min` 判成越界

- **位置**：`f_jit/src/compiler/Lowerer.cj:3904`（`if (v > 922337203685477580 || (v == 922337203685477580 && d > 7))`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11（边界差一）
- **证据**：静态确定 —— 逐位累加不区分符号，`-9223372036854775808` 的数值部分正好是 `9223372036854775808`，`v == 922337203685477580 && d == 8` 命中 `d > 7` ⇒ 返回 `None`。
- **描述**：`-9223372036854775808` 是合法 `Int64`，但 `parseInt64` 返回 `None`，`lowerLiteral`（`:1222-1231`）与 `constIndexOf`（`:3168-3173`）都退化为 Decimal 常量。于是 `let x: Int64 = -9223372036854775808` 报类型不匹配，整数边界值只能写 `Int64.Min` 之外的等价形式；同一字面量在常量表里与在表达式中形态还可能不同（Decimal vs I64）。
- **建议**：负数分支允许 `v == 922337203685477580 && d == 8`（`neg` 为真时），即按有符号范围判定；或在解析前特判 `-9223372036854775808` 字面量返回 `Some(Int64.Min)`。

### [轻微][存量] `ALLOW_ESCAPING_HANDLES` 恒 `true`，逃逸闭包校验块是恒假分支

- **位置**：`f_jit/src/compiler/Lowerer.cj:162`（`private static const … : Bool = true`）、`:3248-3256`（`if (desc.escaping && !ALLOW_ESCAPING_HANDLES) { … invalidEntries() … }`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §1（恒假分支 / 死配置）
- **证据**：静态确定 —— 常量 `true` ⇒ `!true == false`，块内 `diagFail` 永不可达；`CaptureDescriptor.invalidEntries()`（`Capture.cj:89`）全仓仅此一处调用。
- **描述**：m2 §14.7 的「逃逸闭包不得捕获句柄型」目前在降低期**完全没有校验**，只留下一个看起来在把关的 `if`。与第 30 部分对 `Capture.cj` 的结论同源（`invalidEntries` / `isInvalidIfEscapes` 死代码）。
- **建议**：要么把开关改为可配置（构造参数 / 编译选项）并保留校验，要么整块删除并把「不校验逃逸捕获」写进注释与 README 的限制段；不要保留恒假分支。

### [轻微][存量] `fnRetType` 无任何调用者

- **位置**：`f_jit/src/compiler/Lowerer.cj:312-317`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §1（`private` 方法全仓搜引用仅定义处）
- **证据**：静态确定 —— 全仓 `fnRetType` 仅 `:312` 一处（`captureDescriptors` :308、`closureRetType` :319 是另两个不同符号，均有调用）。
- **描述**：死方法，且其语义（`parent == None ? topRetType : closureRetType(fnId)`）与 `lowerLambda` 收尾处的实际登记逻辑（`:285-290` 按实际产物覆盖）已不一致，留着会误导后续维护者。
- **建议**：删除。

### [轻微][存量] `AstExpr.MemberName` 全仓无构造点，Lowerer 里 8 处分支不可达

- **位置**：`f_jit/src/compiler/Lowerer.cj:578`、`:1132`、`:2265`、`:2329`、`:2584`、`:3369`、`:3492`、`:3801`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §1（不可达分支 / 兼容残留）
- **证据**：静态确定 —— 全仓 `MemberName(` 只有 `Ast.cj:245` 的定义；`Parser.cj:1034` 点号一律产出 `FieldGet`，`Parser.cj:1014-1015` 再由 `FieldGet` 产出 `MethodCall`；其余命中全是模式匹配（`AstShape.cj:106`、`DefiniteAssignment.cj:293/424`、`Parser.cj:607`）。
- **描述**：AST 双形态（`FieldGet` / `MemberName`）只保留了 `FieldGet` 一形态，`MemberName` 的整套分派（字段读写、成员调用、类名跟踪、静态类型、捕获来源、自由变量扫描）都是死代码。维护风险在于两套分支已开始漂移：`hostObjectClassOf` 的 `Call(MemberName)` 分支（`:2329-2342`）仍返回**接收者类**，而 `MethodCall` 分支已改用 `retName`——若将来真的启用 `MemberName`，会立刻复现上面第 4 条的缺陷。
- **建议**：删除 `MemberName` 构造器及全部匹配分支（`FieldGet` 已覆盖同一语义），或在 Ast.cj 注释里写明「保留形态 + 未接线」，并把 `:2329-2342` 的 `Some(cls)` 先改成 `retName` 口径。

### [轻微][存量] `emitArith` 的 `STRING → STR_CAT` 分支不可达

- **位置**：`f_jit/src/compiler/Lowerer.cj:1649-1651`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §1（恒不成立分支）
- **证据**：静态确定 —— `emitArith` 的三个调用点：`Plus` 在 `t == STRING` 时已走独立拼接路径（`:1357-1367`，含 `SWAP` 与逐侧 `TO_STR`），只在非 String 时调 `emitArith`（`:1369-1370`）；`Minus`/`Star`/`Slash` 的 String 组合分别被 `rejectStringArithmetic`（`:1289-1316`）与 `STR_REPEAT` 分支（`:1377-1387`）截断；`Percent` 单独实现。
- **描述**：该分支本身也是错的（没有 `TO_STR`，栈序也不对），一旦将来被走到会静默拼出错误内容。留着等于埋雷。
- **建议**：删掉 `t == STRING` 分支，`emitArith` 尾部直接 `diagFail`（类型集合收窄为 I64/F64/Decimal）。

### [轻微][存量] 重复逻辑：`MemberName`/`FieldGet` 与「装箱列表/映射字面量」两组实现逐行重复

- **位置**：
  - `f_jit/src/compiler/Lowerer.cj:2265-2278` 与 `:2279-2292`（`hostObjectClassOf` 两分支逐行相同）
  - `f_jit/src/compiler/Lowerer.cj:3369-3383` 与 `:3384-3398`（`staticTypeFull` 两分支逐行相同）
  - `f_jit/src/compiler/Lowerer.cj:578-590` 与 `:591-603`（`lowerAssign` 的字段写分派，仅错误文案与 `name`/`field` 变量名不同）
  - `f_jit/src/compiler/Lowerer.cj:873-889` 与 `:3108-3119`（`lowerListLitBoxed` 与 `lowerListLit` 非 const 路径：`MAKE_LIST` → 落槽 → 逐元素 `LOADL/lower/LIST_APPEND/POP` → 回取）
  - `f_jit/src/compiler/Lowerer.cj:892-916` 与 `:3149-3159`（`lowerMapLitBoxed` 与 `lowerMapLit` 非 const 路径，同上）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §2（换控制流 / 只改类型名的重复）
- **证据**：静态确定 —— 逐行比对函数体的「输入-输出-副作用」后摘要一致；唯一差异是 `lowerListLitBoxed`/`lowerMapLitBoxed` 在元素位置调 `lowerBox` 而非 `lowerExpr`，`lowerAssign` 两分支的错误消息不同。
- **描述**：`MemberName`/`FieldGet` 的 4 组重复可随上一条（删 `MemberName`）一并消掉；列表/映射的 2 组重复会随「装箱插入点」规则演进漂移（例如 §3 再加一类装箱点时容易只改一处）。
- **建议**：列表/映射合成一个 `lowerListLit(elems, isEmpty, boxElems: Bool)` / `lowerMapLit(pairs, isEmpty, keyTy, valTy, box: Bool)`；`lowerAssign` 的字段写分支抽 `lowerFieldWrite(tg, field, rhs, pos, what: String)`，错误文案作为参数保留（文案差异是业务要求，不应抹平）。

### [轻微][存量] 闭包值调用在 `fnId` 未知时静默按 `I64`，与 IIFE 的「未登记即报错」口径不一致

- **位置**：`f_jit/src/compiler/Lowerer.cj:2548-2552`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11（静默降级）；§2（同一语义两套口径）
- **证据**：静态确定 —— IIFE 在 `closureRetOf(fnId) == None` 时 `diagFail('IIFE 的闭包返回类型未登记…')`（`:1059-1065`），注释明确「报错而不是静默当 I64（A4/P1-5）」；而 `Var` 形态的闭包值在 `sym.closureFnId == UInt32.Max` 时直接返回 `LocalType.I64`，既不报错也不告警。
- **描述**：`let f = <某无法追踪 fnId 的闭包来源>; let s = f(1)` 之后 `s` 被当成 Int64——若闭包实际返回 String，后续 `.size`/`+` 按 Int64 分派，静默错值。
- **建议**：与 IIFE 对齐：`sym.closureFnId == UInt32.Max` 时 `diagFail(TYPE_MISMATCH, '闭包值的返回类型未登记（fnId 未知）——请显式标注或避免该形态')`；若确有必须有 I64 兜底的场景，在注释与 README 里写明调用面限制。

### [轻微][存量] `==` / `!=` 对 List / Map / JSON 节点落到 `EQ_H`（句柄相等）

- **位置**：`f_jit/src/compiler/Lowerer.cj:1681-1689`（`emitCompare` 的 `else` 分支）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11（语义与预期不符）；§10 契约
- **证据**：待确认 —— 代码路径静态确定（`t == LIST/MAP/JSON_*` 没有专门分支，落到 `EQ_H`/`NE_H`）；缺的是规格口径：`doc/design-m3` §11 只承诺 JSON 的 `is`/`as` 与访问糖，未见「节点相等」定义，因此无法判定这是有意（引用相等）还是漏实现（结构相等）。
- **描述**：`j1 == j2`（两个内容相同的 `JsonObject`）为 `false`，`l1 == l2` 亦为引用比较；对 HOST_OBJECT 引用相等是合理的，对 JSON/容器则与仓颉侧 `==` 的结构语义不符，用户极易误用。
- **建议**：先定规格：若只支持引用相等，在 §11 与 README 写明并在诊断里保持现状；若要结构相等，新增 helper 分支（`JSON_EQ` / `LIST_EQ`），并在 `emitCompare` 里按 `t` 分派。规格未定前不要动实现。

<!-- 第 33 部分 -->

### [一般][存量] 插值内表达式用裸 `Parser` 子解析：丢类注册表、且不校验尾随 token

- **位置**：`f_jit/src/compiler/Parser.cj:1285`（`let sub = Parser(innerSrc)`，尾随 `sub.parseExpr()` 在 1286）
- **来源**：存量（快照模式无基线可比；该行属 M1 期实现的插值切分）
- **判据**：review-checklist §11（契约与实现不符 / 静默丢弃）、§10（`Option`/结果被静默丢弃的同类）
- **证据**：静态确定 —— `Parser.init` 的 `registered` 参数默认 `{ _ => false }`（`Parser.cj:50`），子解析器未传入父解析器的回调；`parsePostfix` 的构造调用分支依赖 `this.registered(callee)`（`Parser.cj:1017`），`parseTypeRef` 的已注册类名判定依赖 `this.registered(nameTok.text)`（`Parser.cj:317`）
- **描述**：两个可复现后果。①`'{ => "v=${User()}" }'`（或插值内出现 `x as User`）在顶层形式上合法，但子解析器认为 `User` 未注册 ⇒ `parsePostfix` 只能产出普通 `Call`，`NameResolver.resolve` 于是报 `UnregisteredFunction`；`as User` 更直接报 `BadParameterList`「未注册的类名」。同一表达式写在插值外可以编译。②`parseExpr()` 之后没有 `EOF` 校验（对比 `parseLambda` 在 169 行的检查），所以 `'{ => "${1; 2}" }'` 只取 `1`、`; 2` 被静默丢弃，不报错。此外子解析器的诊断以 `innerSrc` 为源串，`lineText` 取到的是片段而非原源码行（`diagFail` 的 `src` 参数），插值内的语法错误定位也随之失真。
- **建议**：`Parser(innerSrc, registered: this.registered)`；子解析后检查 `this.atKind(TokenKind.EOF)`，非 EOF 即 `diagFail(SYNTAX_ERROR, …, '插值内只允许单个表达式')`；诊断位置需要把片段坐标平移回父串（`buildStringExpr` 已算 `lastLine/lastCol`，可复用）。

### [一般][存量] 普通赋值右值以 `(` 开头被当作多重赋值，括号开头的算术表达式无法编译

- **位置**：`f_jit/src/compiler/Parser.cj:671`（`if (grouped || this.atKind(TokenKind.LParen))`）
- **来源**：存量
- **判据**：review-checklist §11（边界差一 / 文法误判导致合法源码被拒）
- **证据**：静态确定 —— 只有分组 LHS（`(a, b) = …`）才应进多重赋值分支，`grouped` 已能为该形态定性；`||` 右侧把「RHS 恰好以 `(` 开头」也推进了同一分支
- **描述**：`'{ => var x = 0\n x = (1 + 2) * 3\n x }'`：`parseMaybeMultiAssign` 在 `=` 后看到 `(` 即 `expect(LParen)` → 解析 `1 + 2` → `expect(RParen)` → 返回 `MultiAssign([x], [1+2])`，剩余的 `* 3` 留给 `parseBlockBody` 当新语句 ⇒ `parsePrimary` 报「表达式位置遇到无法起头的词法单元「*」」。即**任何** `lhs = (…) …` 形态的赋值都编不过（`x = (a) && b`、`x = (f(y)) + 1` 同理）；`x = (1)` 虽能过但被降成 1:1 多重赋值，语义承载与 `Assign` 不同。测试面完全没覆盖这种写法（`Parser_test.cj:125-131` 只测 `(a, b) = (b, a)`）。
- **建议**：删掉 `|| this.atKind(TokenKind.LParen)`，只在 `grouped` 为真时走元组 RHS；顺带为 `x = (1 + 2) * 3` 与 `x = (a)` 各加一条用例。

### [一般][存量] 三等分除法链 `a / b / c` 被判为正则替换段

- **位置**：`f_jit/src/compiler/Parser.cj:949`（乘法级尝试替换段）、`:1089-1115`（无修饰符 ⇒ `n = Some(0)`）、`:1044`（后缀位置同款尝试）
- **来源**：存量
- **判据**：review-checklist §11（语义与注释/规格不符）、§6.4（语法层歧义导致合法表达式不可用）
- **证据**：静态确定 —— `tryParseReplace` 在拿到 `s`、`r` 后，若没有第三段修饰符就按「省略 g 等价第 0 个」直接判成功（`Parser.cj:1113-1116`）；`/s/r` 与「除以 b 再除以 c」在 token 流上同形，唯一区分手段（能否完整解析出替换段）对两段除法同样成立
- **描述**：`'{ n: Int64 => n / 2 / 3 }'` 解析为 `RegexOp(Slash, n, 2, 3, n=0)`，降低期 `lowerRegexOp`（`Lowerer.cj:3061-3064`）对 `s` 走 `lowerExprAs(s, STRING)` ⇒ `Int64` 字面量报 `TypeMismatch`，合法算术被拒；若两侧恰好是字符串（`"a" / "b" / "c"`）则通过类型检查并真的发 `REGEX_REPLACE_*`，语义完全走偏。四段 `a / b / c / d` 也会把后两段吞成替换段。注释里「唯一可靠的区分是能否完整解析出替换段形」（`Parser.cj:1069-1071`）对 `a/b/c` 不成立。
- **建议**：把「是否替换段」绑定到**静态可定的正则来源**——左值必须是 `RegexLit` 字面量或静态 `Regex` 槽（`AstExpr.Lit` 的 `RegexLit` 分支、或降低期回填的类型）；否则一律按除法。若设计坚持「省略修饰符 = /0」，需在语法层要求至少一个修饰符（`g` 或数字），并把该形态写进 §11.9 与 README。

### [一般][存量] 替换段序号解析无范围校验，超长字面量抛非诊断异常或得到负序号

- **位置**：`f_jit/src/compiler/Parser.cj:1135`（`parseDigits`），调用点 `:1104`、`:1108`
- **来源**：存量
- **判据**：review-checklist §11（边界 / 错误处理缺失破坏对外契约）
- **证据**：静态确定（无任何长度或范围校验）；具体异常类型待确认 —— 仓颉 `Int64` 的 `*`/`+` 在检查语义下抛 `OverflowException`（旁证：`f_jit/src/bytecode/CanonKey.cj:56-60` 明确写「`Int64(bits)` 是检查型转换，`-0.0` 常量就足以让编译器崩」，`HandleTable` 亦为规避此点手写补码折返），回绕语义下则得到负数
- **描述**：`'{ => re/s/r/99999999999999999999 }'` 的 `n` 被 `parseDigits` 逐位累乘，20 位十进制必然越过 `Int64.Max`。若按检查语义，抛出的 `OverflowException` 不是 `SourceCompileException`，违背 `SourceCompiler.cj:113` 注释承诺的「编译期错误一律抛 `SourceCompileException`」，调用方（`CompilePipeline.runSource` 只 `catch Exception` 后原样重抛）拿到的是无法归类到源码位置的宿主异常；若按回绕语义，`n` 变成负数并被烘进 `REGEX_REPLACE_NTH`。正常源码不该触发任何一种。
- **建议**：`parseDigits` 用受检累加（先判 `v > (Int64.Max - d) / 10`）并在越界时 `diagFail(SYNTAX_ERROR, …, '替换序号超出 Int64 范围')`；`m < n` 也一并拒。

### [一般][存量] 表达式解析递归深度无上限，深嵌套源会让宿主栈溢出

- **位置**：`f_jit/src/compiler/Parser.cj:767`（`parseExpr` 入口）→ `:1181-1195`（`(` 递归回 `parseExpr`）、`:972-980`（`**` 右递归）、`:983-991`（一元递归）、`:1310-1326`（`if` 值形态递归）、`:1337`（嵌套闭包递归）
- **来源**：存量
- **判据**：review-checklist §4（无界递归：深度由输入决定）
- **证据**：静态确定（无深度计数、无长度上限：`f_jit/src/Compiler.cj` 与 `f_jit/src/CompilePipeline.cj` 都不校验源码长度，`Lexer` 也没有层数限制）；崩溃阈值需实测
- **描述**：每层括号经 `parseExpr → parseCastOr → parseOr → parseAnd → parseCompare → parseBitOr → parseBitXor → parseBitAnd → parseShift → parseRange → parseAdditive → parseRegexOp → parseMultiplicative → parsePower → parseUnary → parsePostfix → parsePrimary` 约 17 个栈帧。源码由 `Compiler.compile(source)` 直接接收，`'{ => ' + '('×N + '1' + ')'×N + ' }'` 的 4·N+8 字节输入即可把深度线性推到 N；栈溢出在仓颉侧不可捕获，宿主进程直接终止。当前严重度按「源码由开发者自写、非远端不可信输入」定一般；若调用方把它接到配置中心 / 远端下发的表达式串，应按严重处理。
- **建议**：`Parser` 增 `depth: Int64` 与上限常量（如 256），在 `parseExpr` / `parseUnary` / `parsePrimary` 的递归入口 in/out 增减并在超限时 `diagFail(SYNTAX_ERROR, …, '表达式嵌套过深')`；同一上限复用到 `tailValueOf` / `scanExpr` 侧的 AST 递归。

### [一般][存量] 测试直接改全局 `SignatureTable.enabled` 且不恢复，造成数据竞争与顺序相关

- **位置**：`f_jit/src/compiler/SpecializationFmt_test.cj:39`、`:41`
- **来源**：存量
- **判据**：review-checklist §12.1（共享可变状态无同步）、§11（测试隔离）
- **证据**：静态确定 —— `SignatureTable.enabled` 是 `public static var`（`f_jit/src/runtime/SignaturePlan.cj:135`），运行时在每次特化判定处无同步读取（`SignaturePlan.cj:142` `if (!enabled)`，命中路径靠 `AtomicReference` 但开关本身是裸 `var`）；本用例置 `false` → 编译 → 置 `true`，无 `finally`、无原值恢复
- **描述**：①若测试进程内其他用例（或宿主）依赖 `enabled = false`，本用例跑完后状态被改成 `true`，结果依赖执行顺序；②多线程并发跑测试时，一边写 `var` 一边在别的线程读，是未定义可见性 + 数据竞争（`SignatureTableConcurrency_test.cj` 恰好在验证该类的并发读）。本用例想证明的「开关不影响产物」其实不需要真的翻转全局开关之外的状态，代价却外溢到了整个进程。
- **建议**：`let old = SignatureTable.enabled` + `try { … } finally { SignatureTable.enabled = old }`；更彻底的做法是把开关做成构造期参数或 `AtomicBool`（`SignaturePlan.cj` 侧），避免运行期裸 `var` 跨线程读写。

### [轻微][存量] `Ops.cj` 三个判定函数无调用者，语义在 `BytecodeBuilder` 内联重写

- **位置**：`f_jit/src/compiler/Ops.cj:501`（`StackEffect.isTerminator`）、`:506`（`StackEffect.isUncondJump`）、`:276`（`HelperCodec.needsAutoCheck`）
- **来源**：存量
- **判据**：review-checklist §1（非 public 顶级类型里的 `public` 成员全项目无使用）、§2（同一判定两处实现）
- **证据**：静态确定 —— 三者均只在 `Ops.cj` 定义处出现（`grep -rn "\b(isTerminator|isUncondJump|needsAutoCheck)\b" --include=*.cj` 仅命中定义行）；`isUncondJump` 的语义被内联在 `BytecodeBuilder.cj:182`（`if (op == Op.JMP || op == Op.LOOP_BACK) { this.reachable = false }`），`needsAutoCheck` 的语义由调用方选 `callHelper` / `callHelperNoCheck` / `callHelperVoid` 决定（`BytecodeBuilder.cj:288-305`）
- **描述**：`Op` / `StackEffect` / `HelperCodec` 都是 `internal class`，其 `public` 成员在本模块外不可达，仓内零引用即为死代码。三处注释（`Ops.cj:500`、`:505`、`:275`）仍在描述"这两处必须同源"的契约，实际只有一个消费者。
- **建议**：删除三者，或反过来让 `BytecodeBuilder.cj:182` 与 `callHelper*` 调用它们（保留单一判定源，符合注释原意）。

### [轻微][存量] `StackEffect.TABLE` 中 `CALL_HOST` 的条目不可达，且与 `of()` 的返回值相反

- **位置**：`f_jit/src/compiler/Ops.cj:433`（`t[Int64(Op.CALL_HOST)] = (0, 0)`）对 `Ops.cj:326-328`（`of()` 对 `CALL_HOST` 返回 `(arg + 1, 1)`）
- **来源**：存量
- **判据**：review-checklist §1（恒不生效的分支 / 读不到的表项）
- **证据**：静态确定 —— `of()` 在 `TABLE` 查表前就 `return` 了 `CALL_CLOSURE || CALL_HOST` 分支，唯一读者是 `of()`（`Assembler.cj:254`、`BytecodeBuilder.cj:459`）
- **描述**：表中这一格永远读不到；注释（`Ops.cj:307`）说"未登记者保持 `(-1,-1)`，由调用方转为拒绝"，而这里登记的是合法但错误的 `(0,0)`。若将来有人把 `CALL_HOST` 从 `of()` 的特判里移走，校验会静默放行一个弹参错误的指令（`argc` 不为 0 时下越界或深度漂移）。同类"看似登记、实则走特判"的还有 `CALL_CLOSURE`（表里没有，反而安全）。
- **建议**：删掉该行，改为与 `CALL_CLOSURE` 一致的"不登记 + `of()` 特判"，并在 `of()` 上加一行注释说明 `CALL_*` 家族一律不进表。

### [轻微][存量] 两份码表靠人工同步；注释声称的自检函数不存在，两个 opcode 常量是惰性残留

- **位置**：`f_jit/src/compiler/Ops.cj:21-25`（注释）、`:180-181`（`DT_NEW` / `DUR_NEW`）、`:213-219`（`HelperCodec` 注释）
- **来源**：存量
- **判据**：review-checklist §1（未使用常量 / 兼容残留）、§13（注释与代码不符）
- **证据**：静态确定 —— `grep -rn "agreeWithOpInfo"` 全仓零命中，该函数不存在；`OpInfo.selfCheckOk()`（`f_jit/src/bytecode/OpInfo.cj:100`）只校验表自身（长度、`code == i`、`len`），不比对 `compiler/Ops.cj` 的常量；`HelperId.isFixed`（`f_jit/src/runtime/HelperId.cj:223-226`）只判名字不是 `reserved(`/`unknown(`，同样不比对 `HelperCodec` 的取值
- **描述**：注释「数值口径仍只有一处权威……`Ops.agreeWithOpInfo()` 再比助记符」描述了一道并不存在的防线。我按机械比对核过当前数据：`Op` 的 157 条常量与 `OpInfo.OPCODE_TABLE` 的 `code`/名字**逐条一致**，`HelperCodec` 的 13 个 hid 与 `runtime/HelperId` 也一致，因此当前没有实际漂移；风险在于下一次单边修改不会被任何用例拦住。另外 `DT_NEW`(0xA9) / `DUR_NEW`(0xAA) 全仓无发射点、也不在 `StackEffect.TABLE`（发射即 `codeFail`），属 `OpInfo` 标为 `CAT_FORBID` 的保留码（`f_jit/README.md:276`），保留尚可，但两个常量在 `compiler` 侧没有任何读者。
- **建议**：补一条 `@TestCase` 做 `Op` 常量 ↔ `OpInfo.OPCODE_TABLE`（名字后缀 + 数值）与 `HelperCodec` ↔ `HelperId` 的双向比对（断言形式是遍历而非逐条写死）；把注释里的 `Ops.agreeWithOpInfo()` 改成该用例名，或删掉 `DT_NEW`/`DUR_NEW` 常量。

### [轻微][存量] `CompiledSourceUnit.fingerprint` / `funcCount` 无读者，且每次 compile 白算一次整源哈希

- **位置**：`f_jit/src/compiler/SourceCompiler.cj:53`（`funcCount`）、`:55`（`fingerprint`）、`:130-132`（计算）、`:148`（填充）
- **来源**：存量
- **判据**：review-checklist §1（死字段：赋值后无人读）
- **证据**：静态确定 —— 全 `f_jit/src` 搜 `.fingerprint` 只命中 `backend/CompileCacheKey.cj` 自己的同名字段；`cu.funcCount` / `cu.fingerprint` 零命中（`FbcReader.load` 从 `.fbc` 头取函数数，缓存键由 `CompilePipeline.cj:60` 另算 `Fingerprint.fnv1a128(source)`）
- **描述**：`fingerprint` 每次编译都整串跑一遍 `Fnv128.fnv1a128(src)` 再取低 64 位（`:130-132`），结果无人使用；同一份源码在 `CompilePipeline.runSource` 里又被 `Fingerprint.fnv1a128` 算了一遍（另一套实现）。`funcCount` 同理只是把 `sess.funcCount` 抄进产物结构体。属于"读了不用"的死字段 + 每编译一次多一次全源哈希。
- **建议**：删两个字段；若保留 `fingerprint` 供外部去重，则让 `CompilePipeline` 复用它，避免同源两次哈希。

### [轻微][存量] 换行规范化在同一条编译链上做 4 次，且有两份独立实现

- **位置**：`f_jit/src/compiler/SourceCompiler.cj:115`、`Parser.cj:51`、`Lexer.cj:57`（`init`）、`PredefinedSnapshot.cj:141`（`NameResolver` 构造）；实现 `Lexer.cj:123-140` 与 `f_jit/src/bytecode/Fingerprint.cj:90`
- **来源**：存量
- **判据**：review-checklist §2（换算/规范化复制）
- **证据**：静态确定 —— `Lexer.normalizeNewlines` 无条件 `ArrayList` 累积 + `toArray()` + `String.fromUtf8`（即使源码里没有 `\r` 也整串复制两份）；`bytecode/Fingerprint.normalizeSource` 是第二份同语义实现（逐字节 CRLF/CR→LF）
- **描述**：一次 `compile` 里 `normalizeNewlines` 被调 4 次（`SourceCompiler` 一次 → `Parser` 一次 → `Lexer` 构造一次 → `NameResolver` 一次），每次 2 份整串副本，源码 10 KB 时约 80 KB 纯瞬态垃圾，且 4 次结果完全相同。两份实现还带来"改一处漏一处"的风险（`Fingerprint` 那份被 `Fingerprint.sourceKey` 使用，`Lexer` 那份被编译链使用）。
- **建议**：在 `SourceCompiler.compile` 入口规范化一次，`Lexer` / `Parser` / `NameResolver` 接收已规范化的串（构造参数或 `internal init` 重载）；实现上让 `compiler` 复用 `Fingerprint.normalizeSource`（`compiler` 已依赖 `bytecode` 包）。

### [轻微][存量] `NameResolver.snapshotOf()` 无调用者

- **位置**：`f_jit/src/compiler/PredefinedSnapshot.cj:185`
- **来源**：存量
- **判据**：review-checklist §1（`internal` 类里的 `public` 成员全项目无使用）
- **证据**：静态确定 —— 全仓 `grep -rn "snapshotOf" --include=*.cj` 只命中定义行；`NameResolver` 的消费者（`Lowerer`）直接用 `this.sess.registry`
- **描述**：`NameResolver` 是 `internal class`，该 `public` 方法对外不可达，仓内零引用。注释「注册表快照（降低阶段取签名用）」描述的角色实际由 `CompileSession.registry` 承担。
- **建议**：删除；若确有外部取快照需求，应在 `CompileSession` 上暴露而不是绕 `NameResolver`。

### [轻微][存量] `assignFrom` 的 `MemberName` 分支不可达

- **位置**：`f_jit/src/compiler/Parser.cj:607`
- **来源**：存量
- **判据**：review-checklist §1（恒假分支）
- **证据**：静态确定 —— 全仓 `MemberName(` 只出现在声明（`Ast.cj:245`）与 `match` 模式中（`AstShape.cj:106`、`DefiniteAssignment.cj:293/424`、`Lowerer.cj` 8 处、`Parser.cj:607`），**没有任何构造点**；`Parser` 产出成员访问一律是 `AstExpr.FieldGet`（`:1034`）
- **描述**：该分支把 `MemberName` 原样放进 `Assign`，看起来是"属性赋值"的兼容路径，实际永远走不到；`assignFrom` 的 `_ =>` 兜底（`:608-611`）才是真实行为。范围外提示：`AstExpr.MemberName` 整个变体（含 `Lowerer` / `DefiniteAssignment` / `AstShape` 的 9 处匹配）都因缺构造点而失效，`Ast.cj:36` 注释写的是"保留 M2 的 MemberName"——若不再计划引入，应整体删除；若计划引入，需要在这里补构造。
- **建议**：删除 `Parser.cj:607` 分支（让 `MemberName` 落到显式报错），并在 `Ast.cj` 上标注该变体当前不可达。

### [轻微][存量] 四段"配对扫描"近似重复；两处文档注释整段复制

- **位置**：`f_jit/src/compiler/Parser.cj:515`（`indexFollowedByAssign`）、`:542`（`looksLikeMapLiteral`）、`:615`（`groupFollowedByAssign`）、`:1359`（`looksLikeClosure`）；文档 `:1066-1082`、`:371-377`
- **来源**：存量
- **判据**：review-checklist §2（换控制流 / 近似重复）
- **证据**：静态确定 —— 四个函数都是"从 `from` 起按 `depth` 扫到配平，再回答一个是非问题"，差异仅在开括号集合（`[` / `{(` / `({[` / `{([`）、提前返回条件（`:` at depth 1 / `=>`）与 EOF 处理
- **描述**：目前四份判据各自正确（我逐条核了深度增减与 `depth <= 0` 语义，未发现行为漂移），但改词法（例如新增 `TokenKind` 分组符）时必须同改四处，这是典型的近似重复升级为缺陷的路径。文档侧：`tryParseReplace` 的 doc 注释在 `:1066-1071` 与 `:1073-1082` 连续写了两遍（第二遍补了"禁止嵌套"），`parseTypeComponent` 在 `:371` 与 `:372-377` 也是两段。
- **建议**：抽一个 `scanGroupEnd(ts, from, opens: Array<TokenKind>, stops: Array<TokenKind>): Int64` 返回配平位置与停止原因，四个判定改为在其上做一层谓词；重复的文档注释删旧留新。

### [轻微][存量] AST 位置取值不准：赋值语句取右值之后的 token，插值片段按字节且不累计换行

- **位置**：`f_jit/src/compiler/Parser.cj:591`、`:593`（`SourcePos(this.peek().line, this.peek().column)` 在 RHS 解析之后取）、`:609`（同）、`:1287-1288`（`lastCol = t.column + j + 2`）
- **来源**：存量
- **判据**：review-checklist §1（读了不用 / 值错）、§11（注释承诺"AST 节点携带位置"与实际不符）
- **证据**：静态确定 —— 三处 `pos` 都是 RHS 解析完、`peek()` 已指向下一条语句首 token 时才取值；`j` 是插值串内的**字节**偏移，`+ 2` 按定界符宽度硬编码，且 `lastLine` 在循环里从不更新（多行插值串所有后续片段都落在首行）
- **描述**：当前是"错值未被读"：`AstStmt.ExprStmt` 的位置在 `Lowerer.cj:510`、`DefiniteAssignment.cj:166` 都被 `_` 丢弃，所以现在没人受害；但 `Parser_test.cj:233-241` 的用例名就是"AST 节点携带位置"，一旦有人按语句位置报诊断，行号会指到下一条语句。插值侧同理：`'''a${x}b${y}'''` 里 `b`、`y` 的 column/line 都会偏（非 ASCII 前缀还会按字节多算）。
- **建议**：在 `parseAssignOrExprStmt` 入口就用 `t = this.peek()` 存一份位置（`:572` 已有 `save`，顺手存 `SourcePos`）；`buildStringExpr` 里改为按码点推进并遇到 `0x0A` 时 `lastLine += 1, lastCol = 1`。

### [轻微][存量] 测试断言强度不足：恒真断言、不校验错误码、未使用的辅助函数

- **位置**：`f_jit/src/compiler/Semantics_test.cj:103`、`:130`、`:150`、`:156`（`daOf(...)` 断言）；`Pipeline_test.cj:131-137` 与 `Lowerer_test.cj:215-222`（`runInt` 忽略 `ctx.errCode`）；`LowererM2_test.cj:389`（`compileKindV2` 无调用者）
- **来源**：存量
- **判据**：review-checklist §1（无调用者）、§11（失败路径被当成功）
- **证据**：静态确定 —— `DefiniteAssignment.analyze` 的每个 `diagFail` 都是 `Nothing`（抛异常），末尾无条件 `true`（`DefiniteAssignment.cj:66-77`，其唯一调用点 `SourceCompiler.cj:124` 也用 `let _ =` 丢弃返回值）⇒ `@Assert(daOf(...), true)` 这 4 条**不可能失败**，正向用例实际上什么都没验；`compileKindV2` 全仓零引用
- **描述**：正向路径退化成"不抛异常即通过"，与同文件 `expectDaError`（`Semantics_test.cj:187`）的强度不对等。`runInt` 不看 `errCode` 的后果是：`Pipeline_test.cj:76` 期望 `0` 的尾递归用例，若运行期报错、`interp.run` 恰好返回 `0`，断言照样通过，"1e6 次不爆栈"的结论无法与"提前错误退出"区分。
- **建议**：`analyze` 改成返回 `Unit`（或删除布尔返回）；`runInt` 统一断言 `ctx.errCode == 0`（需要错误码的用例显式取 `errCode`）；删除 `compileKindV2`。

### [轻微][存量] `PerfCompare_test` 的基线数字不可复核

- **位置**：`f_jit/src/compiler/PerfCompare_test.cj:46-108`（`rounds = 5`、单次计时、只 `println` 一次汇总）
- **来源**：存量
- **判据**：`references/fountain-baseline.md` §8（基准必须给绝对值、单位、中位数、离散程度与构建配置）、review-checklist §6.1
- **证据**：静态确定 —— 每组只测一轮（5 次累加后取总时长），无预热轮次统计、无中位数/离散度、无 `-O2` 记录；`@When[os == 'Linux']`（`:33`）
- **描述**：该用例产出的是"体系结构与副作用一致"的回归证据（结果逐位相等，这部分是有价值的），但打印的 `jit_vs_interp` / `jit_vs_native` 百分比无法当作性能基线引用——单次采样、无离散度，机器噪声与 JIT 预热都可能主导。报告里任何基于它的"JIT 比解释器快 N 倍"都缺证据等级。
- **建议**：每组重复 R 轮（≥5）并打印中位数 + 极值，或改成 `cjpm bench` 用例；在输出里带上 `-O2` 与轮数，便于留档对照。

> 存量缺陷 17 条（一般 6 / 轻微 11），是否纳入修复待用户决定。

<!-- 第 34 部分 -->

### [一般][存量] setter 名生成规则有两套实现，非 ASCII 属性名会得到两个不同的绑定名

- **位置**：`f_jit/src/macros/JitBind.cj:380`（`capitalize`）↔ `f_jit/src/ReflectRegistrar.cj:895`（`upperFirst`）；调用点 `JitBind.cj:352` 与 `ReflectRegistrar.cj:232`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §2（表现形式不同的重复逻辑，「只改实现/近似重复且其中一处缺少边界判断」）+ §11（边界未处理）
- **证据**：静态确定
  - 宏侧：`s[0..1].toAsciiUpper() + s[1..]`。`String[Range<Int64>]` 是**按 UTF-8 字节下标**切片且「起止点必须位于字符边界上」（std `core_package_structs.md` §`operator func [](Range<Int64>)`，第 9380 行起），首字符为多字节时 `s[0..1]` 切在字符中间，得到非法 UTF-8 片段。
  - 反射侧：`unsafeBytes().clone()` 后仅当首字节是 `0x61..0x7A` 才减 `0x20`，再用 `String.fromUtf8` 还原——多字节首字符原样保留。
  - 「标识符可用中文」有文档依据：`docs/dev-guide/source_zh_cn/basic_programming_concepts/identifier.md:12`（`XID_Start` 含中文，示例含 `仓颉`）。
- **描述**：同一条约定（`mut prop foo` 的 setter 名为 `setFoo`）被实现两遍。ASCII 名下两者一致；中文/全角名（如 `mut prop 名字`）下宏生成 `"set" + 半个汉字 + "字"`，反射侧生成 `"set名字"`。反射注册会先按 `set名字` 占名并成功（`ReflectRegistrar.cj:231-244`），宏侧那条 `set<非法字节>` 名字不与它冲突，于是同时进表：被引用的 `set名字` 仍然是反射包装（`InstanceVariableInfo.setValue` 的 MCC 路径），宏承诺的「类型化静态赋值」静默失效，函数表里还多出一个永远不会被调用的非法 UTF-8 名字。`capitalize` 只用 ASCII 转换、其余原样保留，即可与反射侧完全对齐。
- **建议**：把「首字符大写」抽为单一规则并让两处同源——宏侧改为 `s.unsafeBytes()` 级操作或 `String.fromUtf8` 重建（非 ASCII 首字符不转换），或干脆规定「属性名必须是 ASCII 起始」并在宏里 `diagReport(ERROR)` 明确拒绝；补一条中文 `mut prop` 的 `JitBind` 用例（现有 `JitBindIgnore_test.cj` 只用了 ASCII 名）。

### [一般][存量] `@IgnoreJitBinding` 标在 `init` 上完全无效

- **位置**：`f_jit/src/macros/JitBind.cj:77`（`if (f.identifier.value == 'init')` 先于 `:83` 的 `ignored.contains`）；反射侧 `f_jit/src/ReflectRegistrar.cj:358`（构造器合并路径不查 `isIgnored`）
- **来源**：存量
- **判据**：review-checklist §3（「开关打开后走进空分支」/契约承诺但实现为空）+ §11（契约与实现不符）
- **证据**：静态确定 —— `Ignored` 名单在 `:69-72` 收集完成，构造函数分支在 `:77-82` 直接 `buildCtor` 并 `hasCtor = true`，`else if (ignored.contains(...))` 位于 `:83` 只覆盖普通方法与 `:95/:106/:118/:130/:137` 的静态/字段/属性分支；`ReflectRegistrar` 的 11 处 `isIgnored` 调用（`:144`、`:210-211`、`:250`、`:286`、`:308`、`:330`、`:518`、`:586`、`:619-620`）无一条在 `:358` 的构造器循环里。
- **描述**：`@IgnoreJitBinding` 的契约是「成员级退出标记，按名字跳过」（`IgnoreJitBinding.cj:22-30`），但 `@IgnoreJitBinding public init(...)` 仍会生成 `PublicCtor` 并进注册表（宏侧），反射侧也会退回 `ConstructorInfo.apply` 的自动包装（`ReflectRegistrar.cj:820-826`）。用户按文档标注后「编译通过、脚本仍能构造该类型」，属于静默失效。
- **建议**：把 `ignored` 判定提到 `init` 分支之前（`if (ignored.contains(f.identifier.value)) { () } else if (f.identifier.value == 'init') ...`），并在 `ReflectRegistrar` 的构造器循环里按同一名字过滤；或明确在宏注释与 README 里写「`init` 不支持忽略」，同时在 `IgnoreJitBinding` 里对 `init` 直接 `diagReport(WARNING)`。

### [一般][存量] `@JitBind` 静默丢弃接口的静态成员（不告警、不进 `statics`）

- **位置**：`f_jit/src/macros/JitBind.cj:94`、`:105`、`:117`（三条静态分支都带 `!isIface`）
- **来源**：存量
- **判据**：review-checklist §3（`match` 落到 `_ => ()` 吞掉分支）+ §14（只做了一半的分支 / 能力未接线）
- **证据**：静态确定 —— 宏文档 `JitBind.cj:40` 承诺「静态函数 / 静态只读字段 / 只读静态属性 → `PredefinedFunction`（进 `statics`）」，未排除接口；三条分支的 guard 显式加了 `!isIface`，落空后走 `:147 case _ => ()`，无 `diagReport`。仓颉接口允许静态函数：`docs/dev-guide/source_zh_cn/class_and_interface/interface.md:162`（`static func typename(): String`）。
- **描述**：`@JitBind` 修饰接口时，接口里的 `static func` / `static let` / 只读 `static prop` 既不进 `methods` 也不进 `statics`，也不像 `static var`（`:107-109`）那样发 WARNING。用户会以为「宏已覆盖」，实际脚本侧调不到，只能靠运行期「未注册函数」发现。
- **建议**：去掉静态分支上的 `!isIface`（接口静态成员生成 `$clsName.$nameTok(...)` 同样成立），或至少在 `case _ =>` 前补一条「接口静态成员未纳入注册面」的 `diagReport(WARNING)`，并在宏注释的「覆盖面」清单里写清接口静态成员的归属。

### [一般][存量] 宏内类型码表未含 15–19，`Any` / JSON / 泛型实参一律落成 14（HOST_OBJECT）

- **位置**：`f_jit/src/macros/JitBind.cj:430`（`codeOf`）、`f_jit/src/macros/JitSignature.cj:268`（`codeOf`，逐项复制）
- **来源**：存量
- **判据**：review-checklist §11（契约与实现不符 / 语义与命名不符）+ §2（字面量复制的码表）
- **证据**：`待确认` —— 宏侧静态可确定「表里只有 0–11 与 `_ => 14`」，与 `LocalType`（`f_jit/src/base/LocalType.cj:57-71`：`HOST_CLOSURE=13`、`ANY=15`、`JSON_VALUE..JSON_NULL=16..19`）不同步；缺的是「运行期是否按码严格比对绑定形参」的证据（`PredefinedFunction.params` 的消费点不在本部分）。
- **描述**：`@JitBind` / `@JitSignatures` 里写 `Any`、`JsonObject`、`Option<Int64>` 之类的形参或返回值时，`codeOf` 返回 14，`classNameOf` 返回 `'Any'`/`'JsonObject'`/`'Option'`。若注册/调用侧按「码 + 类名」查 id（`TypeRef_test.cj:50-53` 的注释与 `JitHost.registerSignature` 口径），这些签名会去查一个不存在的注册类，或被当成 `HOST_OBJECT` 参与类型匹配；M3 新增的 15–19 完全没有入口。
- **建议**：把码表收敛成**一份**（宏包内共享 `private func typeCodeOf(name)`），补齐 `12/13/15/16/17/18/19`；对仍无法静态映射的形态（`Option<T>`、`Array<T>`、复合类型）不要静默落 14，改为 `diagReport(ERROR)` 指明「不支持的类型形参」。

### [一般][存量] `DbgDump.report` 文档承诺 `dump` 为 null 时只输出行号，实现直接解引用

- **位置**：`f_jit/src/runtime/DbgDump.cj:148`（注释 `:146`）、解引用 `:168-169`
- **来源**：存量
- **判据**：review-checklist §11（契约与实现不符 + 空值未处理）
- **证据**：静态确定 —— `:167-170` `unsafe { let p = dump; if (p.read(0) == 0) { return out } }`，此前无 `dump.isNull()` 判定；同文件的 `writeOnceStackRaw:95` 有 `dump.isNull()` 前置检查，`JitFunction.cj:608/689` 也都先判 null。
- **描述**：注释与 `report` 的第二个重载共同承诺「`dump` 为 null ⇒ 只有行号」，但 7 参重载对 null 会直接 `read(0)`，是空指针解引用（崩溃），而不是降级。当前两个生产调用点（`CompilePipeline.cj:350`、`test/diff/RealRunners.cj:449`）只传已分配的缓冲，所以问题潜伏；一旦有人按注释「传 null 省一个分支」就会炸。
- **建议**：`let p = dump; if (p.isNull() || p.read(0) == 0) { return out }`；5 参重载改为 `report(..., dump: CPointer<Int64>(0))` 的直接转发（见下条重复逻辑）。

### [一般][存量] `DbgDump.allocateDump` 不检查 `malloc` 失败就写首两格

- **位置**：`f_jit/src/runtime/DbgDump.cj:49`
- **来源**：存量
- **判据**：review-checklist §11（错误处理缺失 / 资源分配未判空）
- **证据**：静态确定 —— `:50` `let p = LibC.malloc<Int64>(count: HEADER_WORDS + maxNLocals)`，`:51-54` 立即 `p.write(0, 0); p.write(1, 0)`，无 `isNull()`；同仓同类分配都判空并降级：`f_jit/src/backend/NativeAssets.cj:75-78`（「失败 → None」）、`NativeAssets.cj:160`、`backend/CodeBuffer.cj:61`（还额外判 `UIntNative.Max`）。
- **描述**：`maxNLocals` 取自字节码目录全域（`CompilePipeline` 的 `maxNLocalsOf`），是可信值，但分配失败仍可能发生（容器内存吃紧 / 大函数）。失败时不是返回错误码，而是写地址 0 → 进程崩溃，绕过「编译期/运行期单一错误出口」的设计。该路径每次都分配（`JitFunction.cj:605`）。
- **建议**：`if (p.isNull()) { NativeMem.bumpMalloc(); return CPointer<Int64>(0) }`，调用方已有 `dump.isNull()` 判定（`JitFunction.cj:608`），按「无转储」降级即可；同时保持 `NativeMem` 计数对称（失败也计数或不计数要写清）。

### [一般][存量] `@JitSignatures` 只按函数名生成符号名，同包同名函数/成员函数会导致重定义或登记不生效

- **位置**：`f_jit/src/macros/JitSignature.cj:66`（`'__jitSigRegister_' + owner`）、`:67`（`'__jitSigApply_' + owner`）、`:68-74`（插入位置）
- **来源**：存量
- **判据**：review-checklist §11（契约与实现不符）+ §14（接线缺失）
- **证据**：`待确认` —— 静态可确定生成名只由 `funcNameOf(input)`（`:107-116`，取 `func` 后第一个标识符）决定，无文件/位置/唯一化后缀；缺的是「宏系统对成员函数上的宏展开把声明插在类体内」这一行为的实证（当前仓内唯一用例 `JitSignature_test.cj:31` 是包级函数）。
- **描述**：两种触发面。(1) 同包内对**同名**函数（重载，或不同类的同名方法）各标一次 `@JitSignatures` ⇒ 生成两个同名的包级 `func __jitSigRegister_f`，直接重定义报错，且报错位置指向宏生成物而非标注处。(2) 标注在**成员函数**上时，生成的 `public func` / `private let` 落在类体内：登记不再发生在包初始化，而是每次构造实例时执行一次（`private let` 是实例字段初始化器），与文档「只要该包被初始化过，签名就已在表里」（`:64-65`）相反，并会重复登记同一条签名。
- **建议**：生成名加入唯一化成分（宏上下文里的声明位置/序号），或在 `expandSignatures` 里对 `owner` 做「已被占用则追加序号」；对成员函数标注直接 `diagReport(ERROR, input, '@JitSignatures 只能标注包级函数', ...)`，把限制写进宏注释的「边界」段。

### [一般][存量] `splitTopLevel` 只跟踪圆括号深度，泛型实参里的逗号会切断签名

- **位置**：`f_jit/src/macros/JitSignature.cj:119`（深度只在 `:126-130` 处理 `LPAREN`/`RPAREN`）
- **来源**：存量
- **判据**：review-checklist §11（边界未处理）+ §3（错误路径给出误导信息）
- **证据**：静态确定 —— 只有 `(`、`)` 增减 `depth`，`<`/`>`/`[`/`]`/`{`/`}` 一律不参与；`<` 在 `std.ast` 里是 `LT`/`SUB` 之类的普通 token。
- **描述**：`@JitSignatures[(HashMap<String, Int64>) -> Int64]` 会在 `<String, Int64>` 的逗号处切断，得到两组：第一组 `(HashMap<String`、第二组 `Int64>) -> Int64`；第一组进入 `parseSignature` 后报「签名必须写成 `(T1, T2) -> R`」（`:147-149`），错误文案与真实原因（不支持泛型实参）无关，标注者要自己猜。同类边界：`@JitSignatures[]`（空属性）不告警、静默生成一个空登记函数。
- **建议**：`<`/`>`/`[`/`]` 一并计入深度（注意 `>>` 与嵌套模板的配对），或对出现 `<` 的组直接给出「形参只支持单个类型名，不支持泛型实参」的定向诊断；`groups.size == 0` 时复用无属性重载的 WARNING。

### [一般][存量] `@JitSignatures` 与 `@JitBind` 同一张类型码表各写一份

- **位置**：`f_jit/src/macros/JitBind.cj:436-450` 与 `f_jit/src/macros/JitSignature.cj:269-283`（12 个 `case` + `_ => 14`，逐行同形）；`classNameOf` 亦然：`JitBind.cj:454-460` ↔ `JitSignature.cj:286-292`
- **来源**：存量
- **判据**：review-checklist §2（「字面量复制」：同一张状态码表散落多处）
- **证据**：静态确定 —— 两段 `match` 的 case 顺序、返回码、默认值完全一致，只有入参类型不同（`TypeNode` vs `String`）。二者同属 `macro package fountain::f_jit.macros`，可直接共享 `private` 工具函数。
- **描述**：`LocalType` 的码表已经是「唯一来源」（`base/LocalType.cj:141-149` 的注释也这么写），宏侧却有两份手抄副本，且都不含 15–19。任何一侧漏改都只会在运行期表现为「签名查不到」，编译期无任何报错。上一条（码表缺 15–19）只要两处不同步修，就会退化成「`@JitBind` 与 `@JitSignatures` 对同一类型给出不同码」。
- **建议**：抽到宏包内的共享文件（如 `macros/TypeCodes.cj`）并只保留 `typeCodeOf(name: String)` / `classNameOf(name, code)`；`JitBind` 侧先 `t.toTokens()[0].value` 再调同一函数。

### [轻微][存量] `MacroExpandDecl` 逐层下钻的循环在两个宏文件里各写一份

- **位置**：`f_jit/src/macros/JitBind.cj:199`（`unwrapMemberMacro`，循环在 `:203-205`）与 `f_jit/src/macros/IgnoreJitBinding.cj:39`（`identifierOf`，循环在 `:43-45`）
- **来源**：存量
- **判据**：review-checklist §2（同语义不同落点：一个返回声明、一个返回名字，前两步完全一致）
- **证据**：静态确定 —— 两处都是 `var inner: Decl = m.macroInputDecl; while (let md: MacroExpandDecl <- inner) { inner = md.macroInputDecl }`，随后一处 `inner`、一处 `inner.identifier.value`；区别只在返回类型。
- **描述**：同一「剥掉未展开的嵌套成员宏」的规则有两份。谁将来支持新的包装形态（例如再加一层 `MacroExpandDecl` 之外的转发），漏改一处就会出现「宏展开顺序不同 → 成员被重复绑定或被漏掉」，且极难复现。
- **建议**：合并为 `private func unwrapDecl(d: Decl): Decl`（`IgnoreJitBinding` 侧 `unwrapDecl(decl).identifier.value`），放在两个宏文件都能用的共享文件里。

### [轻微][存量] `DiagKind.DUPLICATE_REGISTRATION` 全仓零引用，实际诊断改用硬编码字符串

- **位置**：`f_jit/src/compiler/Token.cj:304`
- **来源**：存量
- **判据**：review-checklist §1（硬原则二：`internal class DiagKind` 的 `public static const` 成员，全项目无使用即死代码）+ §2（字面量复制）
- **证据**：静态确定 —— 全仓 `grep -rn "DiagKind.DUPLICATE_REGISTRATION"` 命中 0；同一错误实际以裸串抛出：`f_jit/src/Compiler.cj:71` `throw SourceCompileException('DuplicateRegistration', ...)`、`:75` `'NotImpl'`（后者也有现成常量 `DiagKind.NOT_IMPL`）。其余 17 个 `DiagKind` 常量均有 ≥2 处引用。
- **描述**：注释自称「常量在本包登记，供 §4.3.9 清单完整」，但注册冲突的实际诊断走字面量，常量永不产生。既有「常量无人用」，又有「字面量与常量并存」——改文案时漏改常量、或测试按常量断言会拿不到。
- **建议**：`Compiler.cj:71/75` 改用 `DiagKind.DUPLICATE_REGISTRATION` / `DiagKind.NOT_IMPL`；若确实不再需要该 kind，删除常量并同步 §4.3.9 清单注释。

### [轻微][存量] 三段「形参装配」循环逐行重复（三处仅差 `args` 偏移与前缀码）

- **位置**：`f_jit/src/macros/JitBind.cj:232-248`（`buildMethod`）、`:394-410`（`buildCtor`）、`:471-487`（`buildStaticFunc`）
- **来源**：存量
- **判据**：review-checklist §2（只改类型名/只改常量的重复）
- **证据**：静态确定 —— 三段结构相同：遍历 `params` → `codes += codeToken(p.paramType)` → `prelude += let $p = match (args[$(i)] as $pType) {...} + NL` → `callArgs += pTok`；差异仅两点：`buildMethod` 用 `args[i + 1]` 且 `codes` 预置 `14`（接收者），另两处用 `args[i]`。同一文件内 `buildMethod:251-260` 与 `buildStaticFunc:489-498` 的 `retCode`/`retName` 双重 `try/catch` 也是复制。
- **描述**：三个入口任一处改判据（例如给形参加 `retName`、或改 `typeMismatch()` 的降级方式）都要同步三遍；`args` 偏移差一处就变成「接收者被当成第一个形参」的错误绑定，且只在运行期表现为类型不符。
- **建议**：抽 `private func paramPrelude(params: Array<FuncParam>, offset: Int64, codes: Tokens): (Tokens, Tokens)` 一处生成 `codes`/`prelude`/`callArgs`，`buildMethod` 传 `offset = 1` 并在外面拼接收者码；`retCode`/`retName` 合并为 `private func retTokens(t: TypeNode): (Tokens, Tokens)`。

### [轻微][存量] `DbgDump.report` 两重载的整体结构逐行复制

- **位置**：`f_jit/src/runtime/DbgDump.cj:157-165` ↔ `:193-201`
- **来源**：存量
- **判据**：review-checklist §2（换控制流/同语义两份）
- **证据**：静态确定 —— 首行模板 `'（code=${code}，site=${site}）'`、`site < 0` 早退、`siteTable.lookup` 的 `Some/None` 两条文案，两处一字不差。
- **描述**：5 参重载存在的唯一理由是「没有转储缓冲」，而这正好可以用 `dump.isNull()` 在 7 参重载里覆盖（见上文空指针条）。现在两份模板各自维护，改模板（「逐字节冻结」的模板是三引擎对拍基准）时漏改一处就会让「有 / 无转储」两条路径的报告格式不一致。
- **建议**：5 参重载保留为便捷壳（`report(code, site, fnId, types, siteTable, nameTable?, dump)` 传空指针），把模板与站点查询收敛到一处；`slotText` 已按 `nameTable` 可缺省处理，`types` 在无转储时用不到。

### [轻微][存量] `X86Compile_test` 自建 `hex`/`nib`，与 `CodeDump.hex` 及另两个测试文件同款

- **位置**：`f_jit/src/compiler/X86Compile_test.cj:138`（`hex`）、`:149`（`nib`）
- **来源**：存量
- **判据**：review-checklist §2（字面量复制：同一张十六进制表）
- **证据**：静态确定 —— `CodeDump.hex`（`f_jit/src/compiler/CodeDump.cj:69`）同输入同遍历；差异只有大小写：`CodeDump.hex` 经 `hex2` 产出小写，本文件 `nib` 产出 `'A'..'F'`（断言里用的也是大写常量）。同名私有副本还有 `backend/X86Frame_test.cj:71`、`backend/X86Lower_test.cj:597`（各自带 `nib`）。
- **描述**：四个文件各持一份「字节数组 → hex 串」，是本部分最典型的复制粘贴。测试断言里 30 多个大写十六进制常量依赖大写形态，所以不能直接换 `CodeDump.hex` 而不改断言。
- **建议**：给 `CodeDump` 增加 `hexUpper`（或 `hex(bs, upper!: Bool = false)`），三个测试文件统一调用；顺带把 `recursiveCompilesWithFnTable:42-50` 内联复制的 `compile()` 加载流程（`:170-178`）改为「`compile(src, constBase, fnTableBase)` 增加一个参数」。

### [轻微][存量] 测试里的 `errKind`/`errText`/`countOf` 在 8+ 个文件里各写一份

- **位置**：`f_jit/src/compiler/TypeRef_test.cj:112`（`errKind`）、`:122`（`errText`）；`f_jit/src/compiler/UnaryNotShape_test.cj:101`（`countOf`）
- **来源**：存量
- **判据**：review-checklist §2（跨文件复制；「测试里的准备代码」是误报边界，但这里是**断言口径**的复制，会漂移）
- **证据**：静态确定 —— `grep "func errKind"` 命中 `A4Frontend_test.cj:236`、`A7JsonSet_test.cj:66`、`AnyCastAux_test.cj:99`、`AnyCast_test.cj:222`、`AnyFrontend_test.cj:286/290`、`AstM2_test.cj:65`、`JsonAccess_test.cj:304/308`、`JsonLit_test.cj:235`、`NameResolver_test.cj:88`、`TypeRef_test.cj:112`；`grep "func countOf"` 命中 `A4Frontend_test.cj:310`、`AnyFrontend_test.cj:315`、`StrictFpCodegen_test.cj:79`、`UnaryNotShape_test.cj:101`。`TypeRef_test` 内部 `errKind`/`errText` 只有「取 `e.kind` / 取 `e.message`」一行之差。
- **描述**：同一段「跑 Parser、捕获 `SourceCompileException`、取字段」被复制十余份；其中 `AnyCastAux_test`/`AnyFrontend_test` 已出现「带 `PredefinedSnapshot` 的重载版本」，说明副本已经开始各自演化。断言口径（例如是否要求「必须抛出」而不是「拿到空串就通过」）无法统一收紧。
- **建议**：放进已有测试支撑包 `fountain::f_jit.test`（仓内已有 `test/TCase.cj` 等），提供 `DiagProbe.kindOf(src)` / `textOf(src)` / `countOf(text, pat)`；`TypeRef_test.errKind`/`errText` 先合并为 `errField(src, field)`。

### [轻微][存量] `buildStaticValue` 的 `fromVar` 形参从未被读取

- **位置**：`f_jit/src/macros/JitBind.cj:513`（声明）、`:114`（传 `true`）、`:126`（传 `false`）
- **来源**：存量
- **判据**：review-checklist §1（读了不用 / 死参数）
- **证据**：静态确定 —— 函数体 `:515-531` 只用到 `ident`、`t`、`clsName`；`fromVar` 无任何出现。两个调用点分别来自 `VarDecl` 与只读 `PropDecl`。
- **描述**：这是「静态 `let` 与只读 `static prop` 共用一条生成路径」的残留参数；保留它会让人以为两种来源有差别（实际上 `v.declType` / `p.declType` 已在调用点选好）。
- **建议**：删参数与两个实参；若将来要按来源生成不同绑定，再显式加回来。

### [轻微][存量] `anyIs` 用 `let unused = ctx; let _ = unused` 占位

- **位置**：`f_jit/src/runtime/AnyHelpers.cj:53`
- **来源**：存量
- **判据**：review-checklist §1（局部变量赋值后只被丢弃）+ §10 可读性
- **证据**：静态确定 —— `:53-54` 两行只为消化未使用的 `ctx` 形参，函数体其余部分不再引用 `ctx`。
- **描述**：H79 是纯读算子、不需要 ctx，两行占位式「消除未使用告警」比直接 `let _ = ctx` 多一次无意义绑定；同类写法在 `anyValueOf`/`anyMatches` 都没有。
- **建议**：合并为一行 `let _ = ctx // H79 纯读，不使用 ctx`，或把 `ctx` 形参在调度表里统一忽略。

### [轻微][存量] `anyBox` 里 `code == LocalType.ANY` 是恒假条件，同一谓词在 Lowerer 也复制了三份

- **位置**：`f_jit/src/runtime/AnyHelpers.cj:44`
- **来源**：存量
- **判据**：review-checklist §1（恒真恒假分支）+ §2（同一判定多处复制）
- **证据**：静态确定 —— `LocalType.isConvertible`（`f_jit/src/base/LocalType.cj:141-149`）对 `12`、`13`、`15` 显式返回 `false`，故 `!isConvertible(code)` 已覆盖 `15`，`|| code == LocalType.ANY` 永不单独成立；同款冗余谓词见 `compiler/Lowerer.cj:1005`（`&& code != LocalType.UNIT`）与 `:2646`（`&& code != LocalType.ANY`）。
- **描述**：注释「可转集之外（含 12/13/15）不得装箱」本身说明作者知道 15 已在集合外；多出来的判断让人误以为 `isConvertible` 会放行 15。三处重复也意味着「可转集」规则改一次要改三处。
- **建议**：删掉 `|| code == LocalType.ANY`，只留 `isConvertible` 一处判据；若想保留防御性写法，改为在 `isConvertible` 里断言并用同一个 helper（如 `LocalType.isBoxable(code)`）。

### [轻微][存量] `Token.cj` 的注释表与实现不一致（构造器数、运算符数、用例覆盖承诺）

- **位置**：`f_jit/src/compiler/Token.cj:24-33`（表格：5+16+12+24+1=58）、`:133-137`（「60 项两两比对」）
- **来源**：存量
- **判据**：review-checklist §10 可读性 / §13 文档一致性（同文件注释即契约）
- **证据**：静态确定 —— 枚举实际 63 个构造器（`grep -c "^    | "` 得 63）：关键字族含 `KwAs`、`KwIs`（19 项含 `Ident`），另有 `JsonLit`；运算符含 `StarStar`、`QuestionQuestion`（26 项）。`ordinal` 表 63 行。`Token.cj:136` 声称「写漏任何一项都会在 `Lexer_test.allSixtyKindsAreConstructible` 暴露」，但该用例（`Lexer_test.cj:50-110`）只列 60 项、断言 `n == 60`，`StarStar`/`KwIs`/`JsonLit` 均未列入；`ordinal` 编号互异性没有任何用例（若两项写重，`==` 会把两个不同 kind 判成相等）。
- **描述**：读者按注释会以为「58 个构造器、全表有测试兜底」。实际是 63 个，且有 3 个 kind 的 `==` 语义与编号唯一性完全无覆盖（当前编号确实互异，属「恰好正确」）。
- **建议**：更正表格为实际数量并注明 M2/M3 增量；把遗漏的 3 个 kind 补进 `Lexer_test` 的构造清单（断言 63）；加一条「63 个 kind 的 `ordinal` 两两互异」的用例，把 `ordinal` 的唯一性从「人工保证」变成「测试保证」。

### [轻微][存量] `HEADER_WORDS` 注释描述的是 3 格布局，实际是 2 格

- **位置**：`f_jit/src/runtime/DbgDump.cj:45`
- **来源**：存量
- **判据**：review-checklist §10 可读性 / §13（注释与实现不一致）
- **证据**：静态确定 —— 注释「首格哨兵 + fnId + nLocals（nLocals 占 1 格）」暗示 3 格，常量值为 `2`；实际布局是 `[0] = fnId + 1`（哨兵与 fnId 合并，`writeOnceStackRaw:102`）、`[1] = nLocals`（`:103`），函数头注释 `:34-35` 与 `:45-46` 的说明正确，只有这一行把「哨兵」当独立格。
- **描述**：`HEADER_WORDS` 是 `allocateDump` 与所有 `write` 偏移的唯一来源，注释差一格容易让人写出 `HEADER_WORDS + 1` 之类的偏移错误。
- **建议**：改为「首格 `fnId+1`（同时充当未填哨兵）+ 次格 `nLocals`，共 2 格」。

### [轻微][存量] `AnyHelpers_test` 同一用例挂了两个 doc 注释，`call` 只是转发

- **位置**：`f_jit/src/runtime/AnyHelpers_test.cj:177-185`（`:177-184` 与 `:185` 两段 `/** */` 紧邻）、`:110`（`call` 直接 `return invokeHelper(...)`，无额外语义）
- **来源**：存量
- **判据**：review-checklist §2（重复）/ §10 可读性
- **证据**：静态确定 —— `:184` 的注释块没有跟任何声明，`:185` 是第二条 doc；`call` 与 `invokeHelper` 签名同构（`ctx, hid, args` → `Int64`）。
- **描述**：孤儿注释块描述了「容器不变语义」，紧接的第二条只有一句，读者会以为是两个用例；`call` 这层包装让全文 40 余处调用多一跳，也掩盖了「测试直接驱动 helper 表」的意图。
- **建议**：合并两段注释；删除 `call`，全文直接调 `invokeHelper`（或把它改名成 `callH` 只差一字，不如去掉）。

### [轻微][存量] `X86Compile_test` 8 个用例只断言「产物非空」

- **位置**：`f_jit/src/compiler/X86Compile_test.cj:30`、`:37`、`:50`、`:57`、`:63`、`:69`、`:76`、`:83`
- **来源**：存量
- **判据**：review-checklist §10 可测试性 / §11（断言不覆盖契约）
- **证据**：静态确定 —— 这些用例统一 `@Assert(code.size > 0, true)`；真正验证编码内容的只有 `:88-136` 的 `checkedArithmeticUsesJno` / `ctxStoresAreQword` / `goldenFloatDivCastClosureLen`。
- **描述**：`branchCompiles` / `containerCompilesWithConstMirror` / `floatAndCompareCompiles` 等名字承诺「分支/容器/浮点比较能编出来」，但任何「编出错误指令序列」的回归都能通过——只要 `compileFunctionWith` 返回非空。这与同目录 `UnaryNotShape_test` 的「结构断言要落到具体 op 序列」口径不一致。
- **建议**：至少对每条用例断言一个特征字节（如分支用例断言 `Jcc` 的 `0F 8x`、容器用例断言 `H18/H01` 的 mov 立即数），或统一改为 `CodeDump.ops` 的助记符断言。

<!-- 第 35 部分 -->

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

<!-- 第 36 部分 -->

### [严重][存量] 浮点 cell 用「检查型数值转换」处理，负浮点/NaN 直接抛异常（H63 返回、H64 读、H65 写）

- **位置**：`f_jit/src/runtime/HostCall.cj:91`（`Int64(v.toBits())`）、`f_jit/src/runtime/HostField.cj:177`（同）、`f_jit/src/runtime/HostField.cj:227`（`UInt64(cell)`）
- **来源**：存量（快照模式无基线；三处均为 M2 时期代码，功能行未在本次改动内）
- **判据**：review-checklist §11「边界 / 契约与实现不符」；语言语义见 `cangjie_docs/docs/dev-guide/source_zh_cn/basic_data_type/integer.md:137`「类型转换时可能发生溢出……否则根据默认的溢出策略将抛出异常」
- **证据**：静态确定 —— 仓内已有同一结论的注释：`f_jit/src/bytecode/CanonKey.cj:58` 写明「`Int64(bits)` 是**检查型**转换：负浮点与 NaN 的位模式 ≥ 2^63，会在编译期抛 `OverflowException`（`-0.0` 常量就足以让编译器崩）」，并因此专门实现了 `CanonKey.bitsAsI64`。而这三处仍用裸转换：
  - `HostCall.cj:84-93`：`ret == 1u16` 分支对 `Float64` 返回做 `Int64(v.toBits())`；返回值 `-1.0`（位模式 `0xBFF0000000000000` ≥ 2^63）→ 抛 `OverflowException`。
  - `HostField.cj:171-183`：H64 读 `type == 1` 的字段同样 `Int64(f.toBits())`。
  - `HostField.cj:225-237`：H65 写 `type == 1` 时 `Float64.fromBits(UInt64(cell))`，负 cell → `UInt64(cell)` 抛异常；且该转换在 `try`（238 行）之外，不归属 21。
- **描述**：三处异常都不在 `try` 内（`HostCall.cj:80` 的 `hostResultCell` 在 `try` 之后；`HostField.cj:225-237` 在 `try` 之前），会被 `invokeHelper` 的兜底 `catch (e: Exception)` 吞成 **99（HELPER_PANIC）**（`f_jit/src/runtime/HelperCore.cj:70-72`、`:54-56`）。后果：宿主闭包返回任意负 `Float64`、或宿主字段是负浮点（读/写）时，调用以「引擎不变式破坏」失败，而不是拿到值；同一单元的纯解释器路径（`Interp.fromBits`，`Interp.cj:451-457`）却正确，JIT 与语义基准出现分歧。现有用例只覆盖正浮点（`HostCallTrampoline_test.cj:171-177` 用 `1.25`），因此长期未被发现。
- **建议**：三处统一改走位型重解释工具（`CanonKey.bitsAsI64`，或把 `Interp.toBits/fromBits` 提升到 `runtime` 公共工具并被 `bytecode` 复用），禁止在 cell↔`Float64` 边界使用 `Int64(UInt64)` / `UInt64(Int64)`；并补 `-1.0` / `-0.0` / `NaN` 的 H63 返回、H64 读、H65 写用例。

### [严重][存量] `INEG` 对 `Int64.Min` 既不报 3，还把 `OverflowException` 抛出解释器

- **位置**：`f_jit/src/runtime/Interp.cj:353`（`case 0x35u8 => f.push(checked((0 - a).checkedSub(0), ctx))`）
- **来源**：存量（`git blame` 落在解释器首版 compare/int 指令块，非本次改动）
- **判据**：review-checklist §11「边界差一 / 错误处理缺失」；ISA 权威 `f_jit/doc/jit-bytecode-m1.md:276`（`35 | INEG | -a | 3`）与 `:2106`（机器码 `neg rax; jo <bail:3>`）
- **证据**：静态确定 —— `0 - a` 是默认检查型算术（`std.overflow` 概述：「默认情况下，出现溢出时会抛出异常」），`a == Int64.Min` 时 `0 - Int64.Min` 先溢出抛 `OverflowException`；`intOp`/`exec`/`run` 全程无 `try`（`Interp.cj:201-263`、`:125-136`），异常一路穿出 `CompilePipeline` 的 `body`（`CompilePipeline.cj:247-250`）直到 `JitFunction.call`，`ctx.errCode` 始终为 0，`JitReport.finish` 也被跳过。等价写法 `a.checkedSub(0)` 之外的 `checkedSub(0)` 是死操作（`0 - a` 的结果再减 0 不可能溢出）。
- **描述**：`-x`（`Lowerer.cj:1714` 确实发射 `Op.INEG`）在 `x == Int64.Min` 时：机器码返回错误码 3，解释器/DEOPT 重放路径抛出未捕获的 `OverflowException`（既不是 3 也不是 21），三态收尾（errCode/site/窗口复位）全部失效。`Interp_test.cj:303-304` 只测了 `IABS`（0x36）的溢出，未覆盖 `INEG`，所以用例是绿的。
- **建议**：改 `a.checkedSub(0)` 语义等价形式 `0.checkedSub(a)`（返回 `?Int64`，走现有 `checked(...)`），并补 `INEG(Int64.Min) → 3` 的用例（与 `IABS` 用例并列）。

### [一般][存量] `IADD_WRAP` 用检查型 `+`，与「显式无检查」契约相反

- **位置**：`f_jit/src/runtime/Interp.cj:365`（`case 0x39u8 => f.push(a + b) // 显式无检查`）
- **来源**：存量
- **判据**：review-checklist §11「契约与实现不符」；ISA `f_jit/doc/jit-bytecode-m1.md:278`（`39 | IADD_WRAP | a+b 无检查（显式选择） | —`）
- **证据**：静态确定 —— 默认整数算术溢出抛异常（`std.overflow` 概述；同文件 `intOp` 其它分支一律用 `checkedAdd/checkedSub/checkedMul`，说明作者清楚默认语义），故 `a + b` 在溢出时抛 `OverflowException` 而非回绕。应使用 `std.overflow` 的 `wrappingAdd`。
- **描述**：语义基准在溢出输入下从「回绕」变成「抛异常穿出解释器」（同上的收尾失效路径）。当前前端未发射 0x39（全仓搜 `Op.IADD_WRAP` 只有 `compiler/Ops.cj:384` 的类型表登记，无 emit 点），属潜伏分歧，一旦 deopt/新前端启用即暴露。
- **建议**：改 `a.wrappingAdd(b)`；并在 `intOp` 补 `IADD_WRAP(Int64.Max, 1) == Int64.Min` 的用例。

### [一般][存量] `FFLOOR`/`FCEIL`/`FTRUNC`/`FROUND` 产出整数 cell，与 `CAT_F64` 契约相反

- **位置**：`f_jit/src/runtime/Interp.cj:433-436`（`f.push(floorF(a))` 等）与 `:967-1012`（四个 helper 返回 `Int64`）
- **来源**：存量
- **判据**：review-checklist §11「契约与实现不符」；ISA `f_jit/doc/jit-bytecode-m1.md:299-302`（「向下取整（保留 NaN/±Inf）」，失败码列为空）与 `:1487-1490`（`OpInfo(0x4A…, CAT_F64)`）、`:2123`（机器码 `roundsd` / `frintm`，且「`|x|≥2^63` 直通、NaN 走 NaN 尾」）
- **证据**：静态确定 —— 同函数 `0x40–0x49` 全部经 `fromBits(canon(...).toBits())` 写**位型**（`Interp.cj:418-432`），而 `0x4A–0x4D` 直接写**整数值**；`truncF` 对 NaN 返回 0、对 `|x| ≥ 2^63` 饱和到 `Int64.Max/Min`（`:983-994`），与「保留 NaN/±Inf / 直通」直接冲突。
- **描述**：对 `-1.7` 取整，机器码栈上是 `-2.0` 的位型 `0xC000000000000000`，解释器栈上是整数 `-2`；后续任何浮点指令（`FADD`）把 `-2` 当位型解出 6e-323 级次正规数 → 结果彻底错误。`Interp_test.cj:343-347` 把该整数形态写进断言，等于把分歧固化成「期望值」，用例无法暴露问题。该族指令当前同样没有前端发射点（`grep Op.FFLOOR` 只命中 `Ops.cj` 类型表与 ISA 表），属潜伏缺陷。
- **建议**：四个 helper 返回 `Float64` 并统一 `fromBits(canon(...).toBits())`；NaN/±Inf 分支原样透传；同步修正 `Interp_test.cj:343-347` 的期望值为位型比较。

### [一般][存量] `TO_I64` 拒绝合法的 `-2^63`（边界差一）

- **位置**：`f_jit/src/runtime/Interp.cj:717-718`（`v <= Float64(-9223372036854775808.0)` ⇒ `FP_INVALID`）
- **来源**：存量
- **判据**：review-checklist §11「边界差一」；ISA `f_jit/doc/jit-bytecode-m1.md:2161`（「结果 = INT64_MIN 时与 `−2^63` 双精度比较区分（**合法 −2^63** vs 越界哨兵）」）
- **证据**：静态确定 —— `Float64(-9223372036854775808.0)` 恰为 `-2^63`，`<=` 把合法值判成越界；同文件 `truncF`（`:990-992`）对同一值返回 `Int64.Min`，可见两处口径不一致。
- **描述**：`Int64(-9.223372036854775808e18)` 这一合法转换在解释器返回 13（`FP_INVALID`），机器码返回 `Int64.Min`。`TO_I64` 由前端正常发射（`Lowerer.cj:1600`、`:1764`），所以这是可达的边界失败。
- **建议**：下界改 `< Float64(Int64.Min)`（上界 `>= Float64(Int64.Max)` 保持不变，因 `Float64(Int64.Max)` 已被舍入到 `2^63`）；补 `-2^63 → Int64.Min` 与 `-2^63 - 2048 → 13` 两条用例。

### [一般][存量] 解释器无调用深度/栈余量保护，深递归直接爆原生栈

- **位置**：`f_jit/src/runtime/Interp.cj:211-212`（`STACK_GUARD` 当 NOP）、`:560-682`（`CALL_FUNC`/`CALL_CLOSURE` 递归 `this.run`）、`:124-136` + `:664-682`（每层新建 `InterpFrame` 与 `ArrayList`）
- **来源**：存量
- **判据**：review-checklist §4「无界递归 / 每帧大对象」+ §11
- **证据**：静态确定（缺保护）+ 需实测（崩溃深度）—— `exec → ctrlOp → run → exec` 每层消耗 3 个仓颉栈帧，且每层在堆上新建 `InterpFrame` + `ArrayList<Int64>`（`:37-45`、`:667-675`）；`0x07 STACK_GUARD` 被显式当作空操作（注释「解释器无机器栈余量概念」，`:212`），全类无深度计数器。文档 `jit-bytecode-m1.md`（§4 内部调用段）对机器码的口径是「深度受宿主线程栈限制，不插深度检查」，但机器码每层仅 `frameSize`，解释器每层是 3 个原生帧 + 2 个堆对象，**实际可达深度远低于机器码**。
- **描述**：同一段递归源码在 JIT 下能跑完、在 DEOPT 重放/纯解释器下以 `StackOverflowError`（或不可捕获的栈溢出）终止，属于两后端行为不一致的崩溃面；OOM 与栈溢出谁先到取决于 `maxStack`。
- **建议**：`Interp` 增加 `depth` 计数（上限取配置，超限写 `ERR_ARG_MISMATCH` 或专用码并 `bail`），或至少把 `STACK_GUARD` 的 `need` 与剩余栈对比后 `bail -1`（DEOPT）——与机器码同语义；顺带把每帧 `ArrayList` 按 `maxStack` 预分配。

### [一般][存量] 迭代器表 `gen` 恒为 1，陈旧游标防护实际未生效

- **位置**：`f_jit/src/runtime/IterTable.cj:63-66`（`st.gens.add(1u32)`）、`:123-141`（`makeCursor/genOfCursor`）、`:143-157`（`entryOf` 的 gen 校验）
- **来源**：存量
- **判据**：review-checklist §11「契约与实现不符」；承诺源 `IterTable.cj:31-32`「`gen` 防陈旧游标：DEOPT 重放后旧游标一律失效 ⇒ 99 防御」
- **证据**：静态确定 —— 全文件只有 `st.gens.add(1u32)` 一处写入 `gens`，无自增、无按 map 句柄派生、无 `+1` 复用位；因此 `(gen << 32) | idx` 的 gen 分量恒为 1。
- **描述**：`clearAll` 后新建的迭代器从 `idx = 0` 重新排队；若某段字节码持有一个跨 `clearAll`（DEOPT 交接/重放）的旧游标，且此后同一调用内又打开了新迭代器，`entryOf` 的 gen 校验会**通过**并读到另一张 map 的表项（静默错误数据），而不是按契约报 99。`IterLifecycle_test` 未覆盖「clearAll 后旧游标仍被使用」的场景。
- **建议**：`gens` 改为按表项生命周期递增（每 `clearAll` 后把线程级 epoch +1 并写入新表项；或 `gens[idx] = gens[idx] + 1` 复用槽），`makeCursor` 取当前 epoch；补「clearAll → 新 open → 旧游标 next ⇒ 99」用例。

### [一般][存量] Map 迭代每步都登记句柄且不释放，与「不占用句柄窗口」的注释冲突

- **位置**：`f_jit/src/runtime/IterTable.cj:202-211`（`advance` 里 `HandleTable.anyToCell(kv[0].value)` / `anyToCell(kv[1])` 覆盖 `curKey/curValue`）
- **来源**：存量
- **判据**：review-checklist §11「资源不对称」、§7「缩短生命周期」
- **证据**：静态确定 —— `HandleTable.anyToCell` 对非 `Int64/Float64/Bool` 一律 `pin`（`f_jit/src/runtime/HandleTable.cj:1406-1413`），而 `advance` 直接覆盖旧 cell、没有对应 `release`；`pin` 内部还会扫本窗口全部 pin 做去重（`HandleTable.cj:464-495`），每次带 `canonKeyOf` 字符串比较。
- **描述**：一次调用内遍历 n 个「键或值非标量」的 Map 条目 ⇒ 最多 2n 个句柄槽只增不减，直到 `capacityLimit` 触发 16（窗口满）或调用结束才由 `resetWindow` 回收；单次迭代的总代价变成 O(n²)（每步扫已有 pin）。文件头注释「**不占用句柄窗口**（记账零新增）」只对游标成立，对元素 cell 不成立，会误导后续维护者。
- **建议**：`advance` 在覆盖前释放上一组 cell（若句柄由本表持有），或复用两个固定槽并原地改写；无法释放时把注释改为「每步最多新增 2 槽（元素 cell）」，并在文档标注大 Map 的窗口预算。

### [一般][存量] `HostFieldTable.register` 不校验 `type` 合法域，非法码延迟到调用期才 99

- **位置**：`f_jit/src/runtime/HostField.cj:91-114`（register）、`:196-202`（`handleFieldCell` 的 `RESERVED → 99`）
- **来源**：存量
- **判据**：review-checklist §11「缺少边界校验」、§14「契约」；合法域见 `f_jit/src/base/LocalType.cj:30-79`（0–14，15=Any 为装箱搬运类型，20–255 保留）
- **证据**：静态确定 —— `register` 只把 `type` 原样存入 `HostFieldAccessor`，无任何范围/白名单判断；`HostFieldAccessor.init`（`:52-59`）同样不校验。
- **描述**：宿主注册 `type = 15/20/65535` 时注册成功，直到第一次 H64/H65 命中该 index 才以 99 失败，且失败点远离注册点（字段访问热路径），排查成本高；`type = 12/13`（闭包）虽然 `fieldToken` 有映射，但字段访问是否允许闭包类型没有在注册期表达。
- **建议**：`register` 入口加断言：`type <= LocalType.HOST_OBJECT(14)` 且不等于 `ANY(15)`，非法即 `failWith(ErrCode.CALL_CONTRACT)`（注册期失败优于运行期 99）；若闭包字段合法则显式放行 12/13 并补用例。

### [一般][存量] `JitContext.readAt/writeAt` 无偏移校验，越界写非托管内存

- **位置**：`f_jit/src/runtime/JitContext.cj:303-311`
- **来源**：存量
- **判据**：review-checklist §11「边界/越界」、§12.1「跨线程资源」
- **证据**：静态确定 —— 实现为 `this.p.read(off / 8)` / `write(off / 8, v)`：`off` 不校验 `0 ≤ off ≤ 56`、不校验 8 的整除性（`off = 60` 落到下一字、`off = 64` 直接越界写 8 字节），两个方法都是 `public`（注释写「供测试与偏移断言用例使用」）。
- **描述**：误用即破坏 ctx 后面的堆块（非托管 `malloc` 区），表现为随机崩溃/静默数据损坏，且无法被 GC 或边界检查发现。
- **建议**：加 `if (off < 0 || off >= SIZE_BYTES || off % 8 != 0) { failWith(CALL_CONTRACT) }`（或用 `assert`），或把这两个方法收窄为 `internal` 并仅在测试包使用（属可见性建议，需确认无下游依赖）。

### [轻微][存量] 三处死分支：`0x30..0x08` 恒假条件、`hostResultCell` 的 `13`、`mapToken` 的 `14`

- **位置**：`f_jit/src/runtime/Interp.cj:227-228`；`f_jit/src/runtime/HostCall.cj:107-110`；`f_jit/src/runtime/HostCall.cj:145`
- **来源**：存量
- **判据**：review-checklist §1「恒真恒假分支 / 不可达分支」
- **证据**：静态确定 ——
  1. `op >= 0x30u8 && op <= 0x08 && false`：区间本就不可能成立，再与 `false` 合取，整条分支永不进入；且它与后续 `0x30–0x3B` 分支的判定完全重复。
  2. `hostResultCell` 的 `case 13u16`（`HOST_CLOSURE`）不可达：进入本函数前已过 `sig.validate()`（`HostCall.cj:53`），而 `SignatureDescriptor.isLegalCode` 只放行 `≤8 / 10 / 11 / 14 / 16–19`（`f_jit/src/runtime/Signature.cj:80-83`），13 恒被拒绝 ⇒ 早退 99。
  3. `HostCall.mapToken` 的 `case 14u16` 不可达：`mapToken` 唯一调用点是 `allocHandleResult`（`:126`），而 14 在 `hostResultCell` 里走独立分支（`:111-114`），不会传进 `allocHandleResult`。
- **描述**：三处都让「分支表」看起来比实际覆盖面大，误导后续按表核对 typecode 的人（本模块本轮专项正是 typecode 分支表）。
- **建议**：删 1；2/3 若要保留作为防御，加注释写明「不可达，仅为对称性/防御」并补一条断言用例钉住 `isLegalCode(13) == false`。

### [轻微][存量] 死代码群（12 个 `as*` 转换、`isContainerToken`、`Interp.typesOf`、`IterEntry.mapHandle` 等）

- **位置**：`f_jit/src/runtime/HostCall.cj:160-207`；`f_jit/src/runtime/IterTable.cj:264-267`；`f_jit/src/runtime/Interp.cj:186-195`；`f_jit/src/runtime/IterTable.cj:168`；`f_jit/src/runtime/Interp.cj:266`；`f_jit/src/runtime/Interp.cj:423-426`
- **来源**：存量
- **判据**：review-checklist §1（`internal` 按本包及子包、`private` 按全仓搜索；「读了不用」「不可达语句」）
- **证据**：静态确定 —— 全仓 `grep -rn "\basI64\b" --include=*.cj .`（排除 `.worktrees/`）只命中定义处，`asF64/asBool/asUnit/asStr/asDec/asDt/asDur/asRange/asList/asMap/asObj` 同理；`isContainerToken` 全仓只命中定义；`Interp.typesOf` 为 `private`，全仓只命中 `Interp.cj:186`（测试里的 `typesOf` 是另一个恒等函数）；`IterEntry.mapHandle` 只在构造器赋值（`:176`），无任何读取；`bail(ctx, f, _: Int64)` 的第三参所有调用点都传 `0`；`floatOp` 的 `case 0x44u8` 在 `failWith(...)`（返回 `Nothing`，必定抛出）之前 `f.push(0)`，该压栈效果永不可观测。
- **描述**：`as*` 一族是早期「逐参 cell → 仓颉值」设计的残留（现在统一走 `convertArgs`/`reflectiveInvoke`），11 个函数加 `asUnit` 共 48 行纯噪声；`Interp.typesOf` 还与 `CompilePipeline.cj:354-363`、`test/diff/RealRunners.cj:426-435` 三份实现同形（见下条）。
- **建议**：删除 `as*`、`isContainerToken`、`Interp.typesOf`、`mapHandle` 字段、`bail` 的第三参与 `0x44` 的 `f.push(0)`；`Interp.typesOf` 若确需保留，改为复用 `CompilePipeline` 已有的查找并标注唯一入口。

### [轻微][存量] 重复逻辑：LocalType→TypeToken 双表、位型重解释四份实现、JSON 码 16–19 四连分支

- **位置**：`f_jit/src/runtime/HostCall.cj:135-153` vs `f_jit/src/runtime/HostField.cj:250-263`；`f_jit/src/runtime/Interp.cj:154-158` / `:442-457` vs `f_jit/src/bytecode/CanonKey.cj:62-71` vs `Interp_test.cj:168-183`；`f_jit/src/runtime/JsonHelpers.cj:149-152`
- **来源**：存量
- **判据**：review-checklist §2（「只改类型名 / 字面量复制 / 换算复制」）
- **证据**：静态确定（逐行比对）——
  1. `HostCall.mapToken` 与 `HostField.fieldToken` 是同一张「LocalType 4–13 → TypeToken」映射表的两份拷贝，差异只有：`mapToken` 多 14/16–19、少 12/13；`fieldToken` 多 12/13 且 14 交调用方单独处理。任何一侧新增码位都会漂移。
  2. `UInt64 ↔ Int64` 位型重解释的手工补码折算出现 4 次：`Interp.constHandle` 内联（`:154-158`）、`Interp.toBits/fromBits`（`:442-457`）、`CanonKey.bitsAsI64`（`bytecode/CanonKey.cj:62-71`）、测试 `cellOfBits/bitsOfCell`。语义相同、约束相同（都必须避开检查型转换，见首条发现）。
  3. `jsonValueOf` 的 `case 16u16/17u16/18u16/19u16` 四支函数体逐字相同（都 `asJson(HandleTable.fetchHostObject(cell))`）；`hostResultCell` 与 `hostGetField` 的 marshal 分派（值型 0/1/2/3 + 句柄型批量）也是同一套形状的两份展开。
- **描述**：属于「表现形式不同/复制粘贴」的重复；其中第 1、3 条已经造成认知负担（读 typecode 分支要对照两张表），第 2 条已经导致首条发现的缺陷（有一份没走安全实现）。
- **建议**：抽出 `LocalType.toCellToken(code): UInt16`（`internal`，两个 helper 共用；14/16–19 的差异用参数表达）；位型重解释统一到 `CanonKey.bitsAsI64` + 新增 `bitsAsU64` 并让 `Interp`/`HostCall`/`HostField` 复用；JSON 码 16–19 合并为 `case 16u16..=19u16 =>`（若语言不支持区间模式则保留四支但加一行注释说明「码级继承，实现相同」）。

### [轻微][存量] 注释与实现漂移（错误码 19/20、visibility 收口说法、CtxFlags 位表、缩进与孤立注释块）

- **位置**：`f_jit/src/runtime/HostFieldSet_test.cj:29`；`f_jit/src/runtime/JitContext.cj:110-112`；`f_jit/src/runtime/JitContext_test.cj:164`；`f_jit/src/runtime/HostCall.cj:320`；`f_jit/src/runtime/JsonHelpers.cj:136-143`
- **来源**：存量
- **判据**：review-checklist §13（文档/注释与实现一致性）
- **证据**：静态确定 ——
  1. `HostFieldSet_test.cj:29` 写「`mutable=false` ⇒ 19」，而实现 `HostField.cj:222-224` 返回 `ErrCode.READONLY`（20），同文件 `:162` 的断言也是 20；`HostField.cj:208` 注释已经记录「口径统一为 20」，测试注释未同步。
  2. `JitContext.cj:110-112` 称「本包源码里写 `public`，由模块内 `protected` 规则收口」—— 仓颉没有把 `public` 自动降级为 `protected` 的规则，这段描述会让人误判 `JitContext` 的对外可见性（实际是 `public class` + `public` 成员）。
  3. `JitContext_test.cj:164` 的注释只列 bit0/1/2，漏 `CtxFlags.DEADLINE`（`JitContext.cj:85`，且 `create` 会写该位，`:178`）。
  4. `HostCall.cj:320` 的文档注释顶格（其余成员均在 4 空格缩进内），破坏文件格式一致性。
  5. `JsonHelpers.cj:136`「写入侧的值域……」孤立成块，紧跟其后的 `:137-143` 又是同一函数的另一段文档注释，两段并存易被当成两个声明。
- **描述**：都是低成本可修的一致性瑕疵；第 2 条影响可见性判断，优先级略高。
- **建议**：逐条改注释（20 而非 19；删/改 visibility 段落为「机器码 ABI 契约，用户面不承诺」；补 bit3）；`HostCall.cj:320` 与 `JsonHelpers.cj:136` 合并/缩进对齐。

### [轻微][存量] 可读性：`helperOp` 裸数字代替 `HelperId`、无意义局部变量、测试顺序耦合

- **位置**：`f_jit/src/runtime/Interp.cj:776-962`（`invokeHelper(ctx, 1/3/7/24/…/70, …)` 共 40+ 处）；`f_jit/src/runtime/Interp.cj:749-750`；`f_jit/src/runtime/JsonHelpers.cj:67-68`、`:94-95`；`f_jit/src/runtime/Interp_test.cj:163-165`；`f_jit/src/runtime/JitContext_test.cj:47-61`
- **来源**：存量
- **判据**：review-checklist §10「可读性 / 可维护性」
- **证据**：静态确定 —— `ctrlOp` 用 `HelperId.CLOSURE_CAP`/`HelperId.INTERRUPT_POLL` 等命名常量（`Interp.cj:318`、`:578`），而 `helperOp`/`typeOp` 全用裸整数（`18` 在两处出现，`:769`、`:817`）；`typeOp` 的 `case 0x85` 写 `let unused = code; let unused2 = unused` 只为消警告；`jsonSet`/`jsonNew` 用 `let unused = ctx; let _ = unused`；`Interp_test.typesOf` 是恒等函数，凭空多一层；`JitContext_test.createWritesInitialFields` 断言 `flags == 0` 依赖线程 TLS 的 deadline 已被清（`HostCallTrampoline_test` 的 setup 才 `RuntimeEnv.clearDeadline()`），单独/乱序跑会红。
- **描述**：裸 hid 让「ISA 0x9x → hid」的对应关系只能靠人工对照 `HelperId.cj`，是本模块 typecode 分支表最易出错的地方之一（本次已核对 0x90–0xBF 全部映射，未发现错配）；测试顺序耦合会让失败信息指向错误原因。
- **建议**：`helperOp`/`typeOp` 全部换 `HelperId.*`；`let unused` 改为 `_ = code`；`Interp_test.typesOf` 直接删（参数原样传）；`JitContext_test` 在断言前显式 `RuntimeEnv.clearDeadline()`。

<!-- 第 37 部分 -->

### [一般][存量] 提升组引用计数仅实例内有效，跨包装共享的闭包槽会被先关闭的一方提前释放

- **位置**：`f_jit/src/runtime/PromotionGroup.cj:37`（`refs` 是实例字段）、`:92-93`（计数归零即 `HandleTable.releaseEscaped`）、`:118-127`（`releaseAll` 逐条减到 0）；组创建点 `f_jit/src/CallMarshal.cj:261`（每次返回闭包新建一个组）；释放点 `f_jit/src/JitFunction.cj:331`（单个包装 `close` 只 `releaseAll` 自己那一组）
- **来源**：存量（`git blame`：`refs` 字段 2026-10-19 `bb87fa03`；组创建/关闭路径同批）
- **判据**：review-checklist §11（资源生命周期 / 契约与实现不符）+ §12.1（跨线程共享状态）
- **证据**：待确认 —— 代码层面确定：计数表是**每实例**的 `HashMap`，两个 `PromotionGroup` 各自对同一 `id` 计 1；任一实例 `releaseAll` 会走到 `releaseEscaped`（gen+1 释放槽）。缺的是「同一闭包槽被两个包装同时持有」的可达路径确认（需要一次 `callForFn` 两次返回同一 12 号捕获闭包，然后 `close()` 其中一个包装再调用另一个）
- **描述**：类注释（`:23-34`）称「重复 `add`（**多闭包共享捕获**）只提升一次、计数 +1」，但计数与清单都在实例内。若同一 `JitClosure` 槽（或同一句柄型捕获槽）被两个包装的组同时登记，先 `close()` 的包装会把计数降到 0 并 `releaseEscaped` 释放该槽；另一个包装的闭包仍持有同一个 `cell`，后续 `HandleTable.getAs(cell, CLOSURE)` 或捕获读取得 `NULL_HANDLE`/`HANDLE_TYPE`（表现为 `CALL_CONTRACT` 19），即「关掉一个包装，另一个包装的调用开始失败」。另：生产路径只有 `releaseAll`（`JitFunction.cj:280`、`:331`），单条 `release` 仅测试调用，因此注释承诺的「共享捕获计数保护」在生产路径上从未生效
- **建议**：二选一并在注释里写清语义——① 把清单/计数上移到单元级（`JitFunction.escaped` 维度，键 `id`，跨组共享），组只做「本次返回涉及的 id 集合」；② 保持实例内计数，但在 `releaseAll` 前判定该 `id` 是否仍被其他存活组登记（需要单元级引用表）。同时补一条「两包装共享同一捕获槽，先关一个再调另一个」的用例，把结论从「待确认」钉成「静态确定」

### [轻微][存量] `signatureToken` 的 9/12/13 分支在宿主闭包路径上不可达

- **位置**：`f_jit/src/runtime/ReflectiveCall.cj:99-112`（`case 9u16 / 12u16 / 13u16`）
- **来源**：存量
- **判据**：review-checklist §1（恒不可达分支 / 两套合法集口径）
- **证据**：静态确定 —— 进入 `cellToHostValue` 的两条路径都以 `SignatureDescriptor.validate()` 为前提：`HostCall.cj:53` 每次 `host_call_trampoline` 都校验，`CallMarshal.cj:177` 在注册期用 `verifyReflective` 校验（其首行 `Signature.cj:113` 同样 `validate()`）；而 `Signature.cj:80-83` 的 `isLegalCode` 只放行 `0–8/10/11/14/16–19`，9/12/13 必被拒 ⇒ 这三个 case 永不命中
- **描述**：`signatureToken` 与 `isLegalCode` 是两套合法集表述：前者覆盖 4–13，后者拒 9/12/13，形成「映射表支持、校验表禁止」的双口径。改动任一侧（例如后续放开 Regex 作宿主回调形参）时只改一处就会静默出现「注册通过、调用 99」
- **建议**：把 `signatureToken` 的合法域收敛到 `isLegalCode` 放行的集合（删 9/12/13，或改为显式注释「防御性保留，`validate` 已拒」并与之共用同一常量表）

### [轻微][存量] `pos1/pos2a/pos2b` 的 `case 14u16` 分支不可达

- **位置**：`f_jit/src/runtime/Signature.cj:241`、`:259`、`:277`（`case 14u16 => true`）；提前返回点在 `:202-205`
- **来源**：存量
- **判据**：review-checklist §1（被前面分支完全覆盖的 case）
- **证据**：静态确定 —— `paramMatches` 首句 `if (code == LocalType.HOST_OBJECT) { return true }`，14 号码永远到不了 `pos1/pos2a/pos2b`
- **描述**：三张逐位判定表里各留一个死 case；同时它掩盖了口径差异——参数位 14 是「无条件通过」，返回位 14 是 `value is () -> Object`（`ret0/ret1/ret2`），读代码的人容易以为两侧同源
- **建议**：删掉参数表里的 14 分支，或把「14 形参不校验具体类」的理由集中写在 `paramMatches` 一处

### [轻微][存量] `cellToHostValue` 注释写的失败码与实现不一致

- **位置**：`f_jit/src/runtime/ReflectiveCall.cj:74-76`（注释「这里 `CALL_CONTRACT`」）vs `:92`（实际 `failWith(ErrCode.HELPER_PANIC)`）
- **来源**：存量
- **判据**：review-checklist §11（语义与注释不符）
- **证据**：静态确定 —— `ErrCode.CALL_CONTRACT = 19`（`base/ErrCode.cj:69`），本函数未引用
- **描述**：注释承诺 `CALL_CONTRACT`，实现抛 `HELPER_PANIC`（99）。`hostSetField` 侧同为 99，因此「差异只在失败码」这句反而是错的（两侧码相同）。排障时按注释找 19 会扑空
- **建议**：注释改为「与 `hostSetField` 同码（99），差异只在调用方转码」，或确实需要 19 时改实现（但会改变 `host_call` 的错误码契约，需与对拍用例同步）

### [轻微][存量] `releaseAll` 注释「每个条目各减 1」与实现「减到 0」不符

- **位置**：`f_jit/src/runtime/PromotionGroup.cj:117`（注释）vs `:122-124`（`while (countOf(id) > 0) releaseLocked(id)`）
- **来源**：存量（注释 2026-10-19 `bb87fa03`，方法体 2026-11-26 `187f86c289` 改成循环减到 0，注释未同步）
- **判据**：review-checklist §11（语义与注释不符）
- **证据**：静态确定
- **描述**：实现是「释放整组、逐条清到 0」，不是「各减 1」。这个差别正是上一条（跨包装共享）判断的关键：若真按「各减 1」，计数 2 的槽在组死亡后仍留 1 份永久泄漏；按现在的实现则是「组死即全释」，对共享槽会提前释放。两种语义必须择一并写清
- **建议**：注释改成「组销毁 ⇒ 逐条释放到 0（不做跨组共享保护）」，并与 F1 的修法保持一致

### [轻微][存量] `verify()` 返回的新描述符丢弃 `paramNames/retName`

- **位置**：`f_jit/src/runtime/Signature.cj:187`（`SignatureDescriptor(declared.params, declared.ret)`）
- **来源**：存量
- **判据**：review-checklist §11（契约与实现不符）
- **证据**：静态确定 —— 该构造函数 `paramNames!`/`retName!` 默认空（`:50-51`），故 14 位置的类名被清空
- **描述**：函数注释（`:168`）写「通过 ⇒ 新描述符（由调用方写入句柄条目）」，但新描述符丢了类名；一旦调用方按注释把它写进条目，后续 14 位置就退化成「只比大类」，跨类误配重新变得可能
- **建议**：改为 `SignatureDescriptor(declared.params, declared.ret, paramNames: declared.paramNames, retName: declared.retName)`；若 `verify` 本就是测试专用（见下条），则在注释里明确「不用于写入条目」

### [轻微][存量] 两条验签口径松紧相反，且与「等价于一次 `is`」的注释不符

- **位置**：`f_jit/src/runtime/Signature.cj:92-97`（注释承诺等价）、`:154-166`（`componentMatches` 逆变位按码/名**精确**相等）、`:202-205`（`verify` 对 14 形参**无条件**放行）
- **来源**：存量
- **判据**：review-checklist §11（契约与实现不符）+ §10 语言特性（函数类型逆变）
- **证据**：静态确定 —— 按 `(U1..Un)->S <: (T1..Tn)->R ⇔ ∀i. Ti <: Ui`，`(Object)->Int64`、`(JsonValue)->Int64` 都应是 `(ReflectUser)->Int64`、`(JsonObject)->Int64` 的合法实现；`componentMatches` 走 `TypeNames.codeOf(actualName) != code` 精确比对（`base/TypeNames.cj:28-58` 把 `Any/Object` 一律归 14），配了类名时还要求逐字相等 ⇒ 更宽的合法实现被拒
- **描述**：口径一（生产：`verifyReflective`，`CallMarshal.cj:177`）偏严：更宽形参（`Object`/`Any`/JSON 父类）声明的实参注册即被拒（err 19），但语义上合法；口径二（`verify`，仅测试调用）偏松：14 形参直接返回 true，`(String)->Int64` 也能通过 `(HostObject)->Int64` 的验签，错误被推迟到调用期变成 21。两条路径都自称「与一次 `is` 等价」，实际都不等价
- **建议**：把「14 位置必须精确类名」的理由写成显式策略（安全优先、拒绝父类型），并在 `verify` 的 14 分支改为可判定的检查（`value is (Object) -> Any` 之类）或直接标注 `verify` 为遗留仅供对拍；`componentMatches` 至少放行 `Any`/`Object`（逆变上界）

### [轻微][存量] `SignatureDescriptor` 声明「构造后不变」，但 `params` 暴露可变 `Array`

- **位置**：`f_jit/src/runtime/Signature.cj:30-36`（`public let params: Array<UInt16>`）、`:45`（`paramNames`）
- **来源**：存量
- **判据**：review-checklist §10（值/引用语义、封装）+ §11（契约与实现不符）
- **证据**：静态确定 —— `let` 只固定字段引用，`Array` 元素仍可被任何持有者改写；构造时的防御性拷贝（`:52-58`）只挡住「构造后外部改传入数组」
- **描述**：`SignatureTable.getOrBuild` 用 `sig.params` 现场比对形状（`SignaturePlan.cj:148`），`SignaturePlan` 自己另存 `clone()`；一旦有调用方改了描述符的 `params`，表的键与 `validate` 结果就与已建计划不一致（计划按旧形状建），命中错误计划后 `marshalArgs` 按旧转换器装配 ⇒ 值错误或 99
- **建议**：改成不可变视图：保留内部 `Array`，对外提供 `func param(i: Int64): UInt16` / `size` 访问器，或直接用 `Array` 的只读包装（`finalizer` 语境的 `readonly` 语义按语言能力选择）

### [轻微][存量] `pad4` 对负年份输出畸形串

- **位置**：`f_jit/src/runtime/TextFormat.cj:363-380`
- **来源**：存量（2026-10-17 `8d1b1900`）
- **判据**：review-checklist §11（边界 / 语义与注释不符）
- **证据**：待确认 —— 代码确定：`v < 1000` 分支按「非负数补零」写，`v = -5` 得 `'0' + "00" + "-5"` = `"000-5"`；缺的是 `DateTime.year` 是否允许负值（`doc/jit-bytecode-m1.md §11.9` 与 std `DateTime` 值域）
- **描述**：注释只说「仅值域两端折算后可发生」的 >9999 情形（走 `+` 分支），未处理负年份。若 `inLocal()` 折算后 year < 0，`dateTime()` 会产出 `000-5-03-...` 这类不可解析、不可往返的文本
- **建议**：负值走 ISO 8601 扩展：`'-' + abs(v)` 并按需补零到 4 位；补一条 `DateTime` 负年用例（或明确在注释里写「year 恒 ≥ 1，故不处理」）

### [轻微][存量] `Int64.Min` 期限哨兵被 `deadlineExpired` 当成「无期限」

- **位置**：`f_jit/src/runtime/RuntimeEnv.cj:71-81`（极端过去 ⇒ `Int64.Min`）vs `:89-95`（`deadlineNanos < 0` ⇒ 恒 false）
- **来源**：存量
- **判据**：review-checklist §11（边界 / 语义与实现不符）
- **证据**：静态确定 —— 两个函数对 `<0` 的解释相反：写侧说「已过期（极端过去）」，读侧说「无期限」
- **描述**：`CallContext.deadline` 落在纳秒可表示范围之外（约 1678 年之前）时，`deadlineNanosOf` 返回 `Int64.Min`（注释：退化为哨兵而不是抛异常），但 `deadlineExpired` 把它当「无期限」⇒ 本该「立刻中断」的调用变成**永不中断**（`interrupt_poll` 恒返回 0，死循环只能靠外部手段终止）。虽然只影响异常输入，但方向与注释相反
- **建议**：`deadlineExpired` 先判 `deadlineNanos == Int64.Min => true`；或写侧改用 `Int64.Min + 1` 之外的「已过期」表示（如统一用 `0` 表示 epoch 前即过期，`-1` 保留为无期限）

### [轻微][存量] `shortestDigits` 三元组的首分量恒 `false` 且无任何调用方读取

- **位置**：`f_jit/src/runtime/TextFormat.cj:69`（返回类型 `(Bool, String, Int64)`）、`:79`、`:100`、`:104`（三处均返回 `false`）；调用方 `:60`（`r[1], r[2]`）、`f_jit/src/runtime/Helpers.cj:402`（`r[2], r[1]`）
- **来源**：存量
- **判据**：review-checklist §1（读了不用 / 死返回值）
- **证据**：静态确定 —— 全仓仅两处调用，均未取 `r[0]`
- **描述**：疑似早期用来区分「零值 / 负零」或「是否精确」的标记，现在恒 `false`，属残留契约；保留会让调用方误以为有第三态需要处理
- **建议**：返回类型收成 `(String, Int64)`（或命名 struct），或在注释里说明该位的保留用途

### [轻微][存量] `runtime/Runtime.cj` 是只有一行注释的空文件

- **位置**：`f_jit/src/runtime/Runtime.cj:18`
- **来源**：存量
- **判据**：review-checklist §3（空实现 / 占位残留）
- **证据**：静态确定 —— 全文 18 行，除许可证与 `package` 外无任何声明
- **描述**：`// P0 骨架占位：运行时——ctx/句柄表/helper 实现集/解释器（语义基准）（见 doc/plan-m1.md §0.4）`。真正的运行时已拆分到 `RuntimeEnv/RuntimeState/HandleTable/Helpers`，此文件只剩「看起来有个 Runtime 类」的误导作用
- **建议**：删除该文件（同包无引用），或改成 `doc/` 里的架构说明引用

### [轻微][存量] `SignatureTable.enabled` 是可写全局，读写不同步

- **位置**：`f_jit/src/runtime/SignaturePlan.cj:135`（`public static var enabled = true`）、`:142`（读）、`:198`（`resetForTest` 在锁外写）
- **来源**：存量
- **判据**：review-checklist §12.1（共享可变状态 / 可见性）
- **证据**：待确认 —— 代码确定读写无锁、无 `Atomic`；缺的是「宿主是否会在运行期切换该开关」（注释写「测试与宿主可关」）
- **描述**：`getOrBuild` 在任意调用线程读该字段；`resetForTest`（以及 `SpecializationFmt_test` 之类）在另一线程写。`Bool` 不会撕裂，但无 happens-before ⇒ 打开后可能长时间仍走冷路径（表现为「特化没生效」），且与「`buildCount` 只建一次」的断言类用例存在互扰
- **建议**：改为 `AtomicBool`（或 `static var` + 只允许在初始化期设置，测试用 `@Test` 串行约束），并在注释里写清「仅进程启动期可改」

### [轻微][存量] 冗余薄包装：同一能力两个入口

- **位置**：`f_jit/src/runtime/HandleTable.cj:1139`（`promote(id)` = `moveOutGroup([id])`，全仓零调用，注释自称「M2 提升组占位」）、`f_jit/src/runtime/Signature.cj:341-343`（`cached(entry)` = `entry.sig`，仅测试调用）、`f_jit/src/runtime/UserHelper.cj:88-90`（`push(base, entries)`「兼容入口」，仅测试调用）、`f_jit/src/runtime/RuntimeEnv.cj:56-63` 与 `:46-53`（`setDeadline`/`clearDeadline` 与 prop setter 重复）、`f_jit/src/runtime/RuntimeEnv.cj:120-126`（`setFnTableBase`/`reset` 与 prop setter 重复）
- **来源**：存量
- **判据**：review-checklist §2（同语义两个实现）
- **证据**：静态确定 —— 上述 `promote`/`cached`/`push` 的全仓调用点均为测试或零（`promote` 零调用、`cached` 仅 `Q6Acceptance_test`/`HostCallback_test`、`push` 仅测试）
- **描述**：均为「对外可达的 public」⇒ 按硬原则一不进死代码统计；但同一语义留两条入口会让「谁是权威路径」不明确（`setDeadline` 与 `deadlineNanos` setter 行为完全一致）。`HandleTable.promote` 更是零调用的占位 API，语义与 `moveOutGroup([id])` 完全重复
- **建议**：`promote` 删除或改为 `moveOutGroup` 的别名注释；`push`/`cached` 在注释里标注「测试辅助」并考虑收窄可见性（需用户确认无下游）；`setDeadline` 系列保留一个（prop setter 或函数入口）

### [轻微][存量] 三张 `LocalType → TypeToken` 映射表口径不一致

- **位置**：`f_jit/src/runtime/ReflectiveCall.cj:99-112`（`signatureToken`：4–13，无 16–19）、`f_jit/src/runtime/UserHelper.cj:165-183`（`userHelperToken`：4–13 + 16–19）、`f_jit/src/runtime/HostCall.cj:135-153`（`HostCall.mapToken`：4–11/14 + 16–19，**12/13 落 RESERVED**）
- **来源**：存量
- **判据**：review-checklist §2（同一张码表散落多处，差异未显式参数化）
- **证据**：静态确定 —— 4–11 三段逐行同值；差异只在 12/13 与 16–19 的取舍
- **描述**：三处各写一遍 `case 4u16 => STRING …`。差异本身有业务理由（宿主闭包路径禁高阶、JSON 只在 helper 与返回侧出现），但差异只体现在「漏了几个 case」，没有一句注释说明「为什么这里不映射」，任何一处补码都会造成三路行为漂移（例如给 `signatureToken` 补 16–19 会让 `cellToHostValue` 的默认分支与显式分支重复判断）
- **建议**：抽成一个 `LocalTypeTokenTable.of(code, allowHighOrder: Bool, allowJson: Bool)`（留在 `f_jit.runtime` 内部），三处传不同开关；或至少在三处各加一句「口径来源：`LocalType.isLegal` / `isConvertible`」

### [轻微][存量] `cellToHostValue` 与 `userHelperArg` 是同一套逐参转换的两份实现

- **位置**：`f_jit/src/runtime/ReflectiveCall.cj:77-96` vs `f_jit/src/runtime/UserHelper.cj:148-163`
- **来源**：存量
- **判据**：review-checklist §2（只差一个分支的近似重复）
- **证据**：静态确定 —— 0/1/2/3 分支逐行相同；14 都是 `fetchHostObject`；差异只有 13（helper 取 `fetchHostCallback(cell).fn`，宿主闭包路径不允许 13 形参）与 16–19 的写法（前者显式 `fetchHostObject`，后者走 token 表 → `fetchAny`）
- **描述**：两份实现已出现细节漂移：14/JSON 码在两处走的是不同校验（`fetchHostObject` 校验**槽 tag**，`fetchAny` 校验**对象运行时类**，见 `HandleTable.cj:810-828` 与 `:911-929`）。对 JSON 节点两者恰好都通过（`tokenOf(JsonValue)` 也返回 `HOST_OBJECT`），但错误码与失败条件不同（`NULL_HANDLE` vs `HANDLE_TYPE` 的判定顺序不同）
- **建议**：合并为 `cellToValue(code, cell, allowHostClosure: Bool)`；把「13 只在 helper 路径可用」做成参数而不是复制函数体

<!-- 第 38 部分 -->

### [一般][存量] 三个 `run` 实现逐字节重复（72 行 × 3），且已与生产 `JitExecutor.invokeOff` 漂移

- **位置**：`f_jit/src/test/diff/RealRunners.cj:76-147`（`AArch64Runner.run`）、`:161-232`（`NativeRunner.run`，`@When[arch == 'aarch64' && os == 'Linux']`）、`:245-316`（`NativeRunner.run`，`@When[arch == 'x86_64' && os == 'Linux']`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §2「换控制流 / 只改类型名」+ §12.1「跨线程资源与状态恢复」
- **证据**：静态确定 —— `diff <(sed -n '76,147p') <(sed -n '161,232p')` 与 `diff <(sed -n '161,232p') <(sed -n '245,316p')` 均为空，即三段 72 行完全一致，唯一差异是 `engine()` 的返回值；而生产同一动作 `JitExecutor.invokeOff`（`f_jit/src/backend/JitExecutor.cj:144-182`）比这三份多三件事：`try/finally` 包住调用并释放实参缓冲（`:172-181`）、进入前保存 `MachineEnv.fnTableBase` 退出后恢复（`:147-151`、`:178-180`）、`release()` 里回收常量句柄（`:185-207`）。
- **描述**：同一段 `FbcReader.load → ConstMirror.build → FnTable.alloc → compileUnitWith → CodeBuffer.alloc/write/seal → 逐目录写入口表 → CFunc 调用 → 收尾` 逻辑存在四份（三份测试副本 + 一份生产实现），且测试副本已经落后于生产副本。当前 `DiffSession` 只用 `NativeRunner`（`f_jit/src/compiler/DiffExec_test.cj:67`、`:134`、`f_jit/src/compiler/Acceptance_test.cj:423`、`f_jit/src/Q6DiffCoverage_test.cj:68`），`AArch64Runner` 是同一实现的第二份公开副本；在 Linux aarch64 上两者 `isAvailable()` 同时为真（`:72-74`、`:157-159`），若有人把两者都放进 `DiffSession`，同一台引擎会被跑两遍并计成「2 个证据」，四元组对拍退化为自比。
- **建议**：保留一个 `private static func runNative(c: DiffCase, engine: DiffEngine): DiffOutcome`，三个 `@When` 类只提供 `engine()`/`isAvailable()`；并把 `try/finally`、`MachineEnv` 保存-恢复、常量句柄回收按 `JitExecutor.invokeOff` 的口径补齐（或直接复用 `JitExecutor`，它已具备 `pinnedConstIds()` / `release()`）。

### [一般][存量] 常量句柄只 `pinConst` 不 `releaseConst`，每跑一个用例累积一份引用

- **位置**：`f_jit/src/test/diff/RealRunners.cj:82`（`ids[i] = interp.constHandle(i)`，`AArch64Runner`）、`:167`（同一循环，aarch64 `NativeRunner`）、`:251`（同一循环，x86_64 `NativeRunner`）、`:57`（`InterpRunner.run` 里 `interp.run(...)` 隐式登记）
- **来源**：存量
- **判据**：review-checklist §11「资源不对称」+ §7「注册表不注销」
- **证据**：静态确定 —— `Interp.pinnedConstIds()` 的注释写明「已登记的路径 A 句柄（值型常量为 0；**调用方负责 releaseConst**）」（`f_jit/src/runtime/Interp.cj:91-94`），`constHandle` 内部走 `HandleTable.pinConst`（`Interp.cj:161-169`），`pinConst` 对命中的槽做 `constRefs + 1`（`HandleTable.cj:622`）且只有 `releaseConst` 才归零回收（`HandleTable.cj:633-655`）。本文件 7 个函数体内全仓搜不到任何 `releaseConst` 调用；生产侧的正确写法在 `JitExecutor.release()`（`:185-207` → `releaseConsts` → `HandleTable.releaseConst`）与 `CompilePipeline.cj:154-158`、`:258`。
- **描述**：每个 `DiffCase` 新建 `Interp` 并对该单元**全部**常量登记句柄，跑完只 `JitContext.free` / `DbgDump.freeDump` / `table/mirror/buf.free`，常量句柄永久留在路径 A。等值常量会被 `pinConst` 的规范化键去重（`HandleTable.cj:613-627`），所以不是线性增长；但**每个用例的相异常量各占一个槽且永不回收**，同一进程内跑完整套差分后槽位只增不减（表上限 `capacityLimitAtomic = 1048576`，`HandleTable.cj:169`），且每个 `pinConst` 都要在全局 `mtx` 内线性扫全表（见「待验证假设」#1）。
- **建议**：`run()` 结束（含失败路径）统一 `for (id in interp.pinnedConstIds()) { if (id != 0) { HandleTable.releaseConst(id) } }`，或改成 `Interp(unit, constIds)`（`Interp.cj:96-99`）复用一份跨用例缓存并在套件收尾统一释放；返回值若是引用型句柄，也按生产口径回收。

### [一般][存量] `FnTable.alloc` 失败分支漏 `mirror.free()`（三处同源）

- **位置**：`f_jit/src/test/diff/RealRunners.cj:85-89`、`:170-174`、`:254-258`
- **来源**：存量
- **判据**：review-checklist §11「资源不对称（异常跳过释放）」
- **证据**：静态确定 —— `ConstMirror.build` 成功即 `LibC.malloc` 一块非托管内存并 `NativeAssets.onAlloc()`（`f_jit/src/backend/NativeAssets.cj:154-170`），必须在 `free()` 归还（`:201-210`）。三个 `run` 的顺序都是「先 `build` 后 `alloc`」，而 `FnTable.alloc` 返回 `None` 的分支直接 `return DiffOutcome('JIT_ALLOC_FAILED', ...)`，既不 `mirror.free()` 也不 `NativeMem`/`NativeAssets` 记账回收；同文件后面两个失败分支（`compileUnitWith` → `:90-96`、`CodeBuffer.alloc` → `:97-103`）都成对写了 `table.free()` + `mirror.free()`，可见是遗漏而非设计。
- **描述**：一旦入口表分配失败（`unit.dir.size == 0` 或 malloc 失败），每次调用泄漏一块 `8 × consts.size` 非托管内存，`NativeAssets.liveCount()` 也永久偏移 —— 这类泄漏恰好会污染「原生资产零泄漏」类断言（`NativeAssets_test`）。`unit.dir.size == 0` 是可由**畸形 `.fbc`** 触发的路径（`FnTable.alloc` 在 `n <= 0` 时返回 `None`），不是纯理论分支。
- **建议**：`match (FnTable.alloc(...))` 的 `None` 分支补 `mirror.free()`；更彻底的做法是用 `try/finally` 或统一「资源束」结构，让所有失败出口走同一条清理路径（`JitExecutor.release()` 已把顺序固定为「码内存最后释放」）。

### [一般][存量] `CodeBuffer.write/seal` 与 `FnTable.set` 的 `false` 被静默丢弃，失败后仍跳进不可执行内存

- **位置**：`f_jit/src/test/diff/RealRunners.cj:104-106`、`:189-191`、`:273-275`（`let unused0 = buf.write(...)` / `let unused1 = buf.seal()`）；`:111`、`:196`、`:280`（`table.set(...)` 返回值当语句丢弃）
- **来源**：存量
- **判据**：review-checklist §3「`catch`/返回值被静默丢弃」+ §11「错误处理缺失」
- **证据**：静态确定 —— `CodeBuffer.write` 在 `freed || sealed || off < 0 || 越界` 时返回 `false`（`f_jit/src/backend/CodeBuffer.cj:99-109`），`seal()` 在 `mprotect` 失败时返回 `false`（`:131-147`），`FnTable.set` 在 `freed || fid >= n` 时返回 `false`（`f_jit/src/backend/NativeAssets.cj:107-114`）。三处调用点把返回值命名成 `unused0`/`unused1`（正是「读了不用」的形态），`table.set` 连绑定都不做，随后无条件 `flushICache()` 并用 `CFunc(CPointer<Unit>(buf.rawPointer() + entryOff))` 调用（`:127-134`）。
- **描述**：`seal()` 失败 ⇒ 页仍为 `PROT_READ|PROT_WRITE`（未 `PROT_EXEC`），`f()` 直接触发段错误；`write()` 失败 ⇒ 码内存是未初始化内容，跑出任意结果并进入四元组对拍（比崩溃更难查）。三条都是「失败即静默」而非「失败即报告」，与同文件对 `FnTable.alloc` / `compileUnitWith` / `CodeBuffer.alloc` 都做了 `match` 检查的口径不一致。
- **建议**：`match (buf.write(...))` / `match (buf.seal())` → `false` 时按 `DiffOutcome('JIT_SEAL_FAILED', ...)`（或抛 `DiffMismatchException`）返回并释放 `buf/table/mirror`；`table.set` 的 `false` 同样要报（它意味着该 `fnId` 的跨函数调用会跳到地址 0）。

### [一般][存量] `cells()` 对未支持的实参类型静默填 0，可造成两引擎「同时看到 0」的假绿

- **位置**：`f_jit/src/test/diff/RealRunners.cj:357-376`（兜底分支 `:371` `case _ => out[i] = 0`）
- **来源**：存量
- **判据**：review-checklist §3「`case None => ()` 当兜底把错误吃掉」+ §11「错误处理缺失」
- **证据**：静态确定 —— 只有 `Int64` / `Float64` / `Bool` 三个分支（`:361-372`），其余一律写 0；`DiffCase.args` 的类型是 `Array<Any>` 且注释写「入参（宿主侧封送前的原始形态）」（`DiffHarness.cj:60-61`），并没有约束「必须是已 pin 的 Int64」。仓内确实存在「先手工 pin 再传 Int64」的用法（`f_jit/src/Q6DiffCoverage_test.cj:139-147`），说明调用方需要自己知道这条隐式约定。
- **描述**：若某个用例直接传 `String` / `Decimal` / `DateTime` / 宿主对象实例，两侧引擎都收到 cell `0`，四元组完全一致 ⇒ 对拍「通过」，但实际什么都没验。这是差分 harness 最怕的失效形态（假绿），且不会留下任何日志。
- **建议**：兜底分支改成抛 `DiffMismatchException('${c.id}: 不支持的实参类型 ...')`（或 `DiffOutcome` 的错误码），把隐式约定变成显式失败；若确实要支持「裸 String」，在此处按 `HandleTable.pin` 登记并纳入回收范围。

### [一般][存量] 可用引擎不足 2 个时直接抛异常，与「非原生架构 ⇒ 跳过而不判失败」的契约冲突

- **位置**：`f_jit/src/test/diff/DiffHarness.cj:124-127`（`outcomes.size < 2` 抛 `DiffMismatchException`）、`:187-189`（`DiffSession.assertTripleEqual`）；`:33-34`、`:145-149` 的文档承诺「记入非原生跳过统计而**不判失败**」
- **来源**：存量
- **判据**：review-checklist §11「契约与实现不符」+ §14「承诺了但没实现」
- **证据**：静态确定 —— `runAll` 只把 `isAvailable()` 为真的 runner 放进 `outcomes`（`:173-185`），`assertTripleEqual` 在只剩 1 个时抛异常；而非 Linux 的 `NativeRunner`（`RealRunners.cj:319-332`）与「Linux 但非 aarch64/x86_64」的 `NativeRunner`（`:335-348`）都硬编码 `isAvailable() == false`。调用方 `f_jit/src/compiler/DiffExec_test.cj:67-69`、`f_jit/src/compiler/Acceptance_test.cj:423-425`、`f_jit/src/Q6DiffCoverage_test.cj:68`、`:144` 都是 `DiffSession([InterpRunner(), NativeRunner()])` + 直接 `assertTripleEqual`，其后紧跟的 `@Assert(session.ran() >= 1, true)` 在这些平台上根本执行不到。
- **描述**：在 Windows / macOS / RISC-V 等平台跑 `cjpm test`，这批差分用例会以「可用引擎不足 2 个」失败，而不是像注释与 `TCase` 设计意图那样记为「无证据、跳过」。`DiffExec_test.cj:31` 甚至明写「非 Linux-aarch64 环境下 AArch64Runner 记入「跳过」而非失败（证据由 CI 矩阵补齐）」——实现与该句相反。现有 `diff_test.unavailableEngineIsSkippedNotFailed`（`:86-97`）用三个桩（含一个 `available: false`）验证了「跳过」，恰好绕开了「只剩 1 个」的真实平台情形。
- **建议**：给 `DiffSession` 加一个显式入口 `assertDiffOrSkip(c)`（返回 `DiffVerdict`：`Compared` / `InsufficientEvidence`），调用方断言 `ran() + skipped() == 2` 且在 `skipped > 0` 时记「无证据」而非失败；至少让调用方在 `ran() == 1` 时改断言 `skipped() == 1`，并给 `diff_test` 补一条 `DiffSession([InterpRunner(), unavailable])` 的用例钉住该语义。

### [轻微][存量] `maxNLocals` / `typesOf` / `reportOf` 是 `CompilePipeline` 同名私有函数的逐行副本

- **位置**：`f_jit/src/test/diff/RealRunners.cj:412-423`（`maxNLocals`）、`:426-435`（`typesOf`）、`:443-451`（`reportOf`）
- **来源**：存量
- **判据**：review-checklist §2「跨层复制」
- **证据**：静态确定 —— `CompilePipeline.cj:332-341` 与 `RealRunners.cj:412-423` 逐行相同；`CompilePipeline.cj:354-364` 与 `RealRunners.cj:426-435` 逐行相同（含同样的 `unit.types[0]` 回落）；`CompilePipeline.cj:346-352` 与 `RealRunners.cj:443-451` 只差一行前置守卫（本文件多了 `if (ctx.errCode <= 0) return ''`）。
- **描述**：三个「目录/类型表/报告」辅助函数在测试层被整体复制一遍，两边的回落语义（`types[0]`）与越界假设完全绑定；任一侧修边界（见下一条），另一侧会静默分叉。这不是业务必需的独立演进，属于跨层复制。
- **建议**：把三者提升为 `f_jit` 内部（`internal`）公共工具，例如 `runtime/DumpSupport.cj`（或直接让 `CompilePipeline` 暴露 `internal static`），测试层只调用。落点须在同层或下层，不能反向依赖 `CompilePipeline`（它依赖 `SourceCompiler`，层次更高）。

### [轻微][存量] F64 ↔ Int64 位型重解释在本文件重复两份，仓内共 5 份

- **位置**：`f_jit/src/test/diff/RealRunners.cj:363-369`（`Float64` → cell）、`:400-406`（cell → `Float64`）
- **来源**：存量
- **判据**：review-checklist §2「换算复制」
- **证据**：静态确定 —— 同形实现在 `f_jit/src/CallMarshal.cj:398-416`（`bitsOf` / `bitsOfCell2` / `bitsOfCell`，`private`）、`f_jit/src/runtime/Interp.cj:153-157`、`:444`、`f_jit/src/bytecode/ByteCodec.cj:58-72`、`f_jit/src/bytecode/CanonKey.cj:66` 各自存在；其中 `CanonKey.cj:58` 的注释已指明「`Int64(bits)` 是检查型转换，负浮点/NaN 会抛出」，正是这五份代码都在手写同一套绕行写法。
- **描述**：同一「无溢出位型转换」在本仓有 5 份实现，任何一份写错（少一个 `+ Int64.Min`）都会让 F64 用例在特定符号位上崩；测试层的两份必须与运行时严格一致，却没有任何共享断言。
- **建议**：抽到 `f_jit.base` 的 `internal` 工具（如 `Bits.f64ToCell` / `Bits.cellToF64`），`RealRunners` / `Interp` / `CallMarshal` 全部改调；`ByteCodec`/`CanonKey` 的变体（带 `9223372036854775807` 形式）保留但加一句「语义等价于 Bits.*」的交叉引用。

### [轻微][存量] `text()` 只解码 `STRING` / `F64`，引用型返回会按「句柄 ID」参与对拍

- **位置**：`f_jit/src/test/diff/RealRunners.cj:392-409`（`:394-399` 只处理 `LocalType.STRING`，`:400-407` 只处理 `F64`，其余落 `:408` `TextFormat.i64(cell)`）
- **来源**：存量
- **判据**：review-checklist §11「契约与实现不符」
- **证据**：静态确定 —— `DiffOutcome.result` 的注释是「结果的文本化形态（与 `TO_STR` 同源，见 S4.12）」（`DiffHarness.cj:37-38`），实现只对两类做了文本化；`List`/`Map`/`JsonObject`/13/14 型返回会走到 `TextFormat.i64`，输出的是**句柄 ID**。句柄 ID 在同一进程内由 `pin` 分配（`HandleTable.cj:452-470` 的窗口去重只保证「同一窗口内同对象同 ID」），两个引擎先后运行、各自 pin，ID 不保证相同。
- **描述**：当前差分用例的返回类型只有 Int64 / F64 / String（`DiffExec_test.cj:37-99` 全部如此），所以尚未暴露；一旦给 `List`/`Map`/宿主对象 加入差分用例，两侧会因 ID 不同而报假不一致（或因为 ID 恰好被槽复用而复用而碰巧通过），形成随机红/假绿。
- **建议**：`text()` 增加「引用型走 `TO_STR` helper（`runtime/Helpers.cj` 的 `to_str`）」的分支，或把 `result` 字段改成 `Option<String>` 并在引用型返回时置 `None` + 记「该维度不可对拍」，由 `diffFour` 显式跳过该维度。

### [轻微][存量] 合成失败码用 `-1`（= DEOPT）表示分配/编译失败，语义与 `DiffOutcome` 契约冲突

- **位置**：`f_jit/src/test/diff/RealRunners.cj:88`、`:95`、`:102`（`AArch64Runner`）与 `:173`、`:180`、`:187`（aarch64 `NativeRunner`）与 `:257`、`:264`、`:271`（x86_64 `NativeRunner`）
- **来源**：存量
- **判据**：review-checklist §11「语义与命名/注释不符」
- **证据**：静态确定 —— `DiffOutcome.errCode` 的注释定义「`0` 成功、`-1` DEOPT、`-2` INTERRUPT、`>0` 见 `ErrCode`」（`DiffHarness.cj:39-40`），而 `JIT_ALLOC_FAILED` / `JIT_COMPILE_FAILED` 都返回 `-1`；`reportOf` 又按 `errCode <= 0` 归零报告（`:444-446`），于是「引擎没跑起来」在四元组里表现为「DEOPT 且无报告」，只能靠 `result` 字符串区分。
- **描述**：若未来某用例的解释器侧正常返回 `-1`（DEOPT 是合法语义结果），它与「JIT 根本没编译成功」在错误码维度上相同，对拍能否区分完全依赖 `result` 文案；同时 CI 汇总会把「环境分配失败」统计成 DEOPT。
- **建议**：改用 `ErrCode` 之外的正值保留码（如 `9001`/`9002`）或把这两类改成抛 `DiffMismatchException`，让「引擎不可用」与「引擎给出语义结果」在四元组里天然不同。

### [轻微][存量] `art.entry` 缺失时回落偏移 `0`，语义是「执行别的函数」而不是报错

- **位置**：`f_jit/src/test/diff/RealRunners.cj:117-120`、`:202-205`、`:286-289`（`case None => 0`）；同源 `:112`、`:197`、`:281`（`case None => ()` 跳过写入口表）
- **来源**：存量
- **判据**：review-checklist §1「恒假分支」+ §11「错误处理缺失」
- **证据**：静态确定 —— `JitCompiler.compileUnitWith` 对 `unit.dir` 的每个函数都编译，任一失败整批返回 `None`（`f_jit/src/backend/JitCompiler.cj:84-113`），因此走到本文件时 `art.entry(任一 fnId)` 必为 `Some`；这两个 `None` 分支在构造上不可达。真正的问题是它们的兜底值：`0` 是码缓冲首函数的入口。
- **描述**：分支虽不可达，但一旦未来 `compileUnitWith` 引入「按需编译/裁剪」，`entryOff = 0` 会把入口函数悄悄换成目录首函数，四元组仍能产出结果并参与对拍 —— 排查成本极高。
- **建议**：`case None =>` 改为返回 `DiffOutcome('JIT_ENTRY_MISSING', ...)`（或抛异常），并删掉「跳过一个入口」的 `case None => ()`（改成失败），让不可达分支以「显式失败」而不是「静默降级」收尾。

### [轻微][存量] `RealRunners.nativeRunner()` 全仓零引用（`internal` 类成员 ⇒ 死代码）

- **位置**：`f_jit/src/test/diff/RealRunners.cj:350-354`
- **来源**：存量
- **判据**：review-checklist §1（所属顶层声明 `internal class RealRunners`，成员缺省修饰符即「本包及子包可见」，对外不可达）
- **证据**：静态确定 —— 全仓（排除 `.worktrees`、`target`）`grep -rn "nativeRunner"` 只命中定义处 `:352`；文档注释说它是「当前平台的原生 JIT runner（同名顶级声明按 `@When` 条件编译）」，但所有调用方都直接 `NativeRunner()`（`DiffExec_test.cj:67`、`Acceptance_test.cj:423`、`Q6DiffCoverage_test.cj:68`）。同类的其余成员（`cells` `:357`、`arrayPointer` `:378`、`text` `:392`、`maxNLocals` `:412`、`typesOf` `:426`、`reportOf` `:443`）均有调用者。
- **描述**：这层间接（`internal` 类 + 无条件编译的工厂函数）本来是要「屏蔽 `@When` 差异」，但调用方都写死了 `NativeRunner`，工厂成了空壳；它还会误导读者以为存在统一入口。
- **建议**：删除 `nativeRunner()`；若要保留统一入口，则把全部调用方改为 `RealRunners.nativeRunner()`（此时 `RealRunners` 应改为调用方可见的可见性）。

### [轻微][存量] `TMapping` 类注释与三张表的当前语义矛盾（`inScope` / `owner` 说法过期）

- **位置**：`f_jit/src/test/diff/TCoverage.cj:20-29`（类注释，尤其 `:27-28`）
- **来源**：存量
- **判据**：review-checklist §13「文档过期」/ §11「语义与注释不符」
- **证据**：静态确定 —— 注释写「范围外编号（T30–T41、T49）归属 M2/M3：`owner` 标注为 `M2/M3`、`inScope=false`，**不计入本次完成判据**」；实际三张表里 `T_MAP_M2`（`:102-132`）14 条全部 `inScope=true`、`owner='M2'`，`T_MAP_M3`（`:140-156`）7 条全部 `inScope=true`、`owner='M3'`，且 `diff_test.m2ScopeIsFullyCovered`（`:172-188`）/`m3ScopeIsFullyCovered`（`:150-164`）正是断言「必须 `inScope`」。全表不存在任何 `owner='M2/M3'` 或 `inScope=false` 的条目。
- **描述**：这条注释会让人误以为 M2/M3 仍是「登记但不算完成」，与紧随其后的两张表和两条 `@Fail` 断言直接冲突；后续维护者按注释改表会把 M2/M3 判据打掉。
- **建议**：改写为「M1 = `T_MAP_IN_SCOPE`；M2/M3 各自成表且都是对应里程碑的完成判据；`inScope` 恒为 true，保留该字段只为与 `check_tmap.sh` 的读取口径一致」。

### [轻微][存量] `tMappingHasNoDanglingEntries` 名不符实：只校验非空与 M1，M2 缺 `caseName` 断言

- **位置**：`f_jit/src/test/diff/diff_test.cj:107-125`（只遍历 `T_MAP_IN_SCOPE`）、`:172-188`（`m2ScopeIsFullyCovered` 未断言 `caseName` 非空）
- **来源**：存量
- **判据**：review-checklist §14「用例承诺与实现不符」/ §11「语义与命名不符」
- **证据**：静态确定 —— 用例注释写「每项都能定位到具体步骤 + 用例名，**无悬空项**」（`:107`），但循环只对 `m.steps.isEmpty()` / `m.caseName.isEmpty()` / `owner`/`inScope` 判空，**不检查 `caseName` 对应的测试函数是否存在**；`caseName` 写错成任意非空串也照样通过（真正的存在性校验在 `scripts/check_tmap.sh`）。`m2ScopeIsFullyCovered` 只断言 `steps.size > 0`（`:184`），`m3ScopeIsFullyCovered` 则同时断言了 `caseName` 非空（`:160`），三处口径不一致。
- **描述**：本用例被当作「映射表自证」，实际只自证了「非空」。已人工核对本部分覆盖的 61 条映射：`T1..T29、T42..T48、T50..T53`（M1 40 条）、`T30..T36、T49、T54、T55、T57..T60`（M2 14 条）、`T37..T41、T56、T61`（M3 7 条）的 `caseName` 全部能在 `src/**/*_test.cj` 中 `grep "func <name>("` 命中，且 61 个 `'T<id>/` 标签都在可执行语句里出现 ⇒ **当前数据是干净的**，问题在于用例守不住将来。
- **建议**：要么把用例改名/改注释为「映射项字段非空校验」，要么在测试内做真实存在性校验（仓颉侧可用 `std.reflect` 枚举 `*_test` 类的成员名），或明确写「存在性由 `check_tmap.sh` 负责」；同时给 M2 补 `caseName` 非空断言，与 M3 对齐。

## 优化可行性方案

> 不是缺陷，是「还能更好」；无基线的方案只作待验证假设，不进 tasks。

<!-- 第 1 部分 -->

本部分 4 个文件均为文档，没有可直接落地的堆内存 / CPU 改造对象（性能改造点在 `.cj`，属其他部分）。文档层面的可维护性改进（符号化锚点、公开 API 清单同源生成）已并入各条「建议」，不重复计为方案。

<!-- 第 2 部分 -->

本部分只有一份设计文档，没有可测量的堆内存 / CPU 改造对象，也没有改前基线；不提出优化方案（`0 / 0`）。文档层面的可维护性改进（消除第二份事实、把行号锚点改成符号锚点）已作为缺陷与建议计入发现，不重复计为优化方案。

<!-- 第 3 部分 -->

本部分为设计文档，不含可执行的堆内存 / CPU 改造对象，**0 条**。文档中已有的两组实测数据（CALL_HOST 相对 user helper 4.6–5.8×，`design-m2.md:479`；并行扩展比 1.27×/2.40×/1.91×，`design-parallel-call.md:233`）已转入「待验证假设」，不在此当作结论。

<!-- 第 4 部分 -->

本部分唯一文件是规范文档，没有可测的堆内存 / CPU 改动面，`§7`、`§8`、`§9` 三维度记 0 条（见「覆盖自检」）。

唯一有量级数据的项（回边 `interrupt_poll` 占空循环 97.7%，`optimize-call-path.md` §14：662→15 ns/轮、44×）**已实现**（`CtxFlags.DEADLINE` + 两后端条件调用），因此不构成待做的优化方案，剩余工作只是文档回写——已并入 #7 的建议列。文档层面的"降成本"（opcode/helper 表单一来源、加载期校验前移）同样并入各条建议，不重复计入。

<!-- 第 5 部分 -->

> 本部分只有规格文档，无源码可优化；不产出堆内存 / CPU 方案。文档内已有实测基线（`doc/perf-m2.md`：user helper ≈153 ns/次、宿主闭包 ≈707 ns/次），但它度量的是**反射路径**，已被实现的类型化 adapter / per-signature plan 超越（`HostCall.cj:62-71`），属「待补数据」而非可执行优化项。

（0 条堆内存方案 / 0 条 CPU 方案）

<!-- 第 6 部分 -->

> 本部分只有规格与优化台账，无源码可改；且这四篇文档自身已明确「剩余开销进入测量分辨率以下」（`optimize-call-path.md:635-639`）。按铁律，没有改前基线 + 改后对照的方案不写成结论，本部分不产出堆内存 / CPU 方案。

（0 条堆内存方案 / 0 条 CPU 方案）

<!-- 第 7 部分 -->

本部分 20 个文件均为文档，没有独立的堆 / CPU 可量化改造对象：

- **[堆内存]** 无适用对象——文档不持有运行时对象；`CompileCache` / 句柄表 / 窗口的内存面在对应源码部分评审。
- **[CPU]** 无独立方案——唯一实质性 CPU 面（`close` 排空自旋空转 + 每轮取锁）已作为上面第 1 条缺陷的修法，不另立优化项，避免同一根因重复计数。

<!-- 第 8 部分 -->

本部分 20 个文件均为规格/设计文档，没有独立的堆 / CPU 改造对象：唯一实质性能面（回边守卫的指令开销）已由 `doc/optimize-call-path.md:411` 给出 662→15 ns/轮 的既有基线，但「剩余 15 ns/轮」中守卫占比没有 profile 数据，只能进下方「待验证假设」，不立优化项，也不写成结论。堆内存方向无对象持有描述可评。

<!-- 第 9 部分 -->

本部分 20 个文件全部为规格 / 验收文档，无可执行代码，无堆内存与 CPU 方案可提（0 / 0）。文档层面的可执行改进已并入上面各条「建议」，不重复计入本节。

<!-- 第 10 部分 -->

### [CPU] 让热点宿主闭包签名全部命中类型化 adapter，绕开 `FunctionTypeInfo.apply`

- **现状**：未登记签名走反射路径（`f_jit/src/runtime/HostCall.cj:62-70`）；同构一元 `(Int64)->Int64` 实测宿主闭包 ≈ 707 ns/次 vs user helper ≈ 153 ns/次 = **4.63×**（第二轮 5.75×），留档 `doc/perf-m2.md`，出处 `f_jit/doc/spec/f-jit-m2/verify.md:243`
- **方案**：对热点签名用 `@JitSignatures` / `JitHost.registerSignature` 登记，adapter 在 pin 时按「码 + 逐位类名 + 返回码 + 返回类名」命中（`f_jit/src/base/HostSignature.cj:135-190`），调用期零查找
- **预期**：m2.2 门禁要求 adapter 相对反射 ≥1.3×（`f_jit/doc/spec/f-jit-m2.2/specs/f-jit-facade-bridge/spec.md:59-60`）。注意这是**相对反射**的收益，不等于相对 user helper 的端到端收益
- **代价**：每个热点签名多一份登记与一个 adapter 闭包；未登记仍回退反射（语义不变）；登记面扩大后 14 位置的类名必须写准（错写即不命中）
- **验证**：`cjpm bench -O2`，同输入（回调循环 5 万次）对照 adapter / 反射 / user helper 三路，报绝对值、中位数与离散程度
- **证据状态**：`无基线（待验证）` —— 4.63× 是「闭包 vs user helper」，adapter 覆盖后的端到端降幅没有改前/改后对照，不进 `tasks.md`

<!-- 第 11 部分 -->

本部分 20 个文件全部是 `.md`，不含可执行代码，**无堆内存 / CPU 优化方案（0 / 0）**。文档维护类改进已并入各条「建议」，不单列。

> 本轮未构建、未跑 profile / bench，不存在可引用的性能基线；任何「重构能降 X%」的推断都只会是猜测，按铁律不写入本节。

<!-- 第 12 部分 -->

> 本部分为文档，优化对象是文档所指的实现。两条均无改前/改后对照数据，只能作下一轮补数据的候选。

### [堆内存] 失败缓存每条文本内嵌「全量已注册名列表」，256 条上限下会放大成数 MB 常驻

- **现状**：`CompileCache.failures` 存 `源码指纹 → 失败文本`，上限 256 条（`CompileCache.cj:95,98-105`）。文本来源含 `PredefinedSnapshot.cj:161-163`（`'已注册：${this.snapshot.registeredList()}'`）与 `:178-180`，而 `registeredList()`（`PredefinedSnapshot.cj:101-112`）把注册表**全部**名字拼成一个字符串；注册量上限由 `Compiler.maxPredefined` 决定。粗估：1000 个注册名 × ~15 B ≈ 15 KB/条，256 条 ≈ 3.8 MB 常驻，且这些文本在注册失效前不会再被读取
- **方案**：失败文本只保留「诊断头部 + 注册表代际号」，把 `registeredList()` 从错误消息里摘出来，改为诊断出口按需拼接（`DiagnosticsSink` 渲染时读当前快照）；或把 `registeredList()` 截断到前 N 个并注明剩余数量
- **预期**：单条失败文本从 O(注册名总长) 降到 O(1)，256 条上限下的常驻从数 MB 降到数十 KB；具体比例待测
- **代价**：错误文本不再自包含「完整注册列表」，排障时要多一次查询；`Semantics_test` 中若断言了注册列表全文需同步
- **验证**：注册 1000 个函数 → 制造 256 条不同失败 → 对照 `getAllocatedHeapSize()` / RSS 与 `registeredList().size`
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] `ipow` 的溢出检测走异常控制流，可改显式阈值判断

- **现状**：`PowHelper.cj:60-72` 每次乘法都在 `try { a * b } catch (_: Exception)` 里做溢出判定。快速幂每算一位最多一次乘法（≤ 63 次），溢出用例（`2 ** 63`）会**必然**走一次抛异常路径；正常用例是否为零成本取决于仓颉异常实现（表驱动 vs 栈展开），无数据
- **方案**：按 `design.md:43` 的写法做显式阈值比较，仅在越界时 `failWith(3)`，去掉 try/catch
- **预期**：溢出用例省一次异常构造/展开；正常用例是否受益未知（若 use-landing-pad 实现则收益接近 0）
- **代价**：阈值分支要覆盖同号/异号与 `MIN` 边界，逻辑比 catch 复杂，需配 6 条等价用例（`MIN * -1`、`MAX * 2`、`-2 * MIN/2`、`0 * MIN` 等）
- **验证**：`cjpm bench -O2` 跑 `2 ** 62`（成功路径）与 `2 ** 63`（溢出路径）各 100 万次，取中位数与离散度
- **证据状态**：`无基线（待验证，不进 tasks）`

<!-- 第 13 部分 -->

> 本部分无 `.cj` 代码，不产生堆内存 / CPU 方案。三份 design 里已有的性能自述（`fix-f-jit-strictfp-deadline-x86/design.md:81` 的「回边新增约 12 条指令」、`fix-f-jit-x86-stack-align/tasks.md:37` 的 `native=5,807,847ns / jit=3,435,226ns`）都缺改前对照或占比数据，按铁律只能进「待验证假设」。

（0 条：堆内存 0 / CPU 0）

<!-- 第 14 部分 -->

本部分 20 个文件全部是 `doc/spec/**` 过程文档，没有可执行的 CPU / 堆内存路径，不产出优化方案（0 条）。文档中出现的三处成本/容量数字（`openWindow` 的 1 ns 原子读、`onAlloc` 的原子加、退休槽 3e-5 槽/次）均无基线，列入下方待验证假设，不作结论。

<!-- 第 15 部分 -->

### [CPU] 逃逸闭包登记表按设计用 `HashMap`，把 `dropEscaped` 的线性扫描降为 O(1)

- **现状**：`escaped` 是 `ArrayList<EscapedClosure>`（`f_jit/src/JitFunction.cj:106`、`:359-366` 追加、`:379-388` 线性扫描 + `remove(at: i)` 搬移尾部）；每次关闭一个包装实例走 `unloadClosure → dropEscaped`，代价 O(n)，逐个关闭 n 个逃逸闭包累计 O(n²)。设计 `design.md:41` 本来就写的是 `HashMap<Int64, EscapedClosure>`（`key = 条目序号`），实现退化成了数组
- **方案**：`escaped` 改 `HashMap<Int64, EscapedClosure>`（`seq` 已是唯一键）；`dropEscaped(e)` 改 `escaped.remove(e.seq)`；`:267-273` 的级联改为遍历 `values()`。`lastEscaped` 语义不变
- **预期**：单次 `close` 从 O(n) 降到 O(1)，逐次关闭 n 个闭包从 O(n²) 降到 O(n)。绝对收益取决于 n（单单元未释放的逃逸闭包数），n 较小时应在噪声内
- **代价**：级联释放顺序由插入序变为哈希序（`releaseAll` 幂等、释放顺序无外显语义，但断言顺序的用例需调整）；`HashMap` 桶内存略高于数组
- **验证**：`cjpm bench -O2`，n = 100 / 1 000 / 10 000 个已登记条目，跑「全部 `close()`」与「单条 `close()`」两场景，取中位数与 P95/P99 与现实现对照；同时跑 `Lifetime_test` / `JitClosureLifecycle_test` / `UnloadConcurrency_test`
- **证据状态**：`无基线（待验证，不进 tasks）`

<!-- 第 16 部分 -->

> 本部分无 `.cj`，不产生新的堆内存 / CPU 方案。文档中已有的「不做」判定（`optimize-arg-staging`、`optimize-call-alloc2`、`optimize-call-path-phase1` P1.3）均带数据或明确回滚，本轮不推翻、不新增方案。

<!-- 第 17 部分 -->

> 本部分 20 个文件均为归档规格文档，不含可改造的实现代码；本轮不产出堆内存 / CPU 方案（0 / 0）。文档中残留的「下一步线索」（`optimize-compile-hotpath/verify.md:51-59`：`A64Emitter` 审计表 ThreadLocal、`bind('L${off}')` 字符串建键、`InsnDecoder.decode` 操作数数组）经核对已被后续变更处理或仍在待测状态：审计表已改实例字段（`f_jit/doc/optimize-compile-path.md` §12）、降低期已改直读操作数（`X86Lower.cj:114-120`、`Assembler.cj:181-184`），`bind` 字符串键仍是 `A64Lower` 现状，无论证数据前不列为方案。

<!-- 第 18 部分 -->

本部分 20 个文件均为归档规格，不含可改造实现，**堆内存 0 条、CPU 0 条**。

文档里残留的「下一步线索」已逐条核对去处：`optimize-emit-fixup/verify.md:73-74` 的「`compileUnitWith` 逐字节 `for (x in b) out.add(x)` 拷贝」已由 `optimize-compile-copy` 处理（`f_jit/doc/optimize-compile-path.md §10`）；`design.md:79-80` 的 `normalizeNewlines` 与两组「未测得收益」改动（emit-audit、decode-alloc）都没有同进程改前基线 ⇒ **一律只进待验证假设，不进方案**。

（可读性层面的唯一动作是合并重复段落：同一份 C1 计划现存在 `design.md:30-46` 与 `doc/optimize-compile-path.md:45-55` 两处且已漂移，见发现 #2；这属文档维护，不计入本模块堆/CPU 统计。）

<!-- 第 19 部分 -->

> 本部分 20 个文件均为变更规格与验证记录，不含可改造的实现代码；本轮不产出堆内存 / CPU 方案（0 / 0）。文档内部已记录的残留项（`optimize-marshal-rs/verify.md:68-70`：`escape + getAs + releaseEscaped` 约 0.5 µs、`append` 仍需一次 `current()`、编译 25–48 ms 未分段）都没有改前/改后对照，按铁律只能进「待验证假设」，不列为方案。

<!-- 第 20 部分 -->

> 不是缺陷，是"还能更好"。下列两条都**没有**改前基线 + 改后对照，只能作为下一轮补数据的候选。

### [CPU] `AdapterRegistry` 的字符串键改为结构化键

- **现状**：`key()`（`AdapterRegistry.cj:80-82`）每次 `register` / `lookup` 都做一次三段插值，生成 `"fp/fnId/tName"` 新 `String` 再哈希；`units` 的键又是 `'${fingerprint}'` 的第二次插值（`:38`、`:59`）。若按设计接到 `call` 第 5 步，每次调用 = 2 次字符串分配 + 2 次长串哈希。
- **方案**：键改成 `(UInt64, UInt32, String)` 元组或 `struct AdapterKey { fingerprint, fnId, tName }`（`hashCode`/`equals` 手写，只对 `tName` 做哈希），`units` 用 `HashMap<UInt64, ArrayList<AdapterKey>>` 省掉一次插值。
- **预期**：单次 `lookup` 少 1–2 次堆分配与一次串哈希；绝对值未测。
- **代价**：`HashMap` 键类型变更（`std.collection` 对元组/自定义类型的 `hashCode` 要求需现场核对）；`removeUnit` 的列表元素类型跟着变。
- **验证**：接线后 `cjpm bench -O2`，同输入 50k 次 `call<注册类>`，中位数 + 离散度对照；`cjprof record` 看 `AdapterRegistry.lookup` 自耗时占比。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [堆内存] `units` 列表去重 + 容量上限

- **现状**：`units` 每个单元一条 `ArrayList<String>`，元素为完整键串；`register` 重复登记会重复追加（见「发现」第 5 条），删除只发生在 `removeUnit`，没有容量上限。
- **方案**：值改 `HashSet<String>`（或在 `add` 前 `contains`）；`units` / `adapters` 加总条数上限（复用 `design-m1` 的 `maxPredefined` 风格常量），超限走「不登记、照常走原路径」的降级（与 `RuntimeState.typeCodes` 的 32 条上限同构，`doc/spec/optimize-type-cache/design.md:20-25`）。
- **预期**：稳态条目数 = 存活单元数 × 调用点 T 数，重复登记不再线性膨胀；具体字节量取决于单元数，未测。
- **代价**：超限后 `lookup` 恒未命中 → 走慢路径（语义不变）；需要新增一个「当前条数」诊断入口。
- **验证**：多轮「编译 → 卸载」循环下 `getAllocatedHeapSize()` + `AdapterRegistry.size()` 是否回到基线（`mem §1.2`）。
- **证据状态**：`无基线（待验证，不进 tasks）`

<!-- 第 21 部分 -->

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

<!-- 第 22 部分 -->

本部分未提出有基线的优化方案（无 profile / bench 数据，两条候选均已降级进「待验证假设」，不进 `todo.md` / `tasks.md`）。

<!-- 第 23 部分 -->

> 以下均不是缺陷；无改前/改后对照数据的项只作为下一轮补数据的方向。

### [CPU] `callForFn` 每次调用重新解析 `Fn` 的类型名

- **现状**：`callForFn` 每次执行 `TypeInfo.of<Fn>().name`（字符串）+ `parseFnType`（字节扫描 + `ArrayList<UInt8>` + `toArray` + `String.fromUtf8`，`JitFunction.cj:498`、`:795-865`），而 `Fn` 在单态化后是编译期常量，解析结果恒定；返回闭包的循环（每次迭代 `callForFn` + `close`）里这部分是纯重复工作
- **方案**：以 `TypeInfo` 为键缓存 `?JitFnSig`（含 `None` 的负极缓存），挂在 `RuntimeState` 或模块级 `HashMap<TypeInfo, ?JitFnSig>`（键集合 = 程序里出现的闭包类型数，天然有界）
- **预期**：每次 `callForFn` 省 3–4 个临时对象与一次 O(签名长度) 扫描；对含闭包返回的循环有效，对普通 `call` 无影响
- **代价**：多一张有界缓存表；`Fn` 参数化的包装实例仍需在 miss 时解析
- **验证**：`cjpm bench -O2`，场景「JIT 单元每次返回新闭包、循环 1e6 次」，改前/改后各 5 轮取中位数与离散度
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] `dropEscaped` 的线性扫描在批量释放时退化为 O(m·n)

- **现状**：`escaped` 是 `ArrayList<EscapedClosure>`，`dropEscaped`（`JitFunction.cj:379-388`）按 `seq` 线性查找并在单元锁内 `remove(at:)`；一个单元持有 n 个在册逃逸闭包时，逐个 `close()` 释放 m 个是 O(m·n)，且每次都在单元 `mtx` 内
- **方案**：加 `seq -> 下标` 的 `HashMap`（或把条目改为 `HashMap<Int64, EscapedClosure>`，`close` 时遍历值集），删除从 O(n) 降到 O(1)
- **预期**：n 较大（数百以上）时 `close` 单次耗时下降；n 小时收益在噪声内
- **代价**：多一份索引，需与 `escaped` 同步维护（`registerEscaped` / `dropEscaped` / `clear` 三处）
- **验证**：构造 n = 1k/10k 在册闭包，测连续 `close()` 的总耗时与 `mtx` 持有时间分布
- **证据状态**：`无基线（待验证，不进 tasks）`

### [堆内存] 每次 `call` 的固定分配（cells 数组 + `CallMarshal`）

- **现状**：`callLocked` 每次调用构造 `CallMarshal(rs)`（`JitFunction.cj:595`）与非零实参时的 `Array<Int64>(args.size, repeat: 0)`（`:617-621`）；`JitContext` 已由 `create/free` 池化，cells 与 marshal 没有
- **方案**：按线程复用一块 `Int64` 暂存区（容量 = 最大 nargs，超出则扩容），`CallMarshal` 改为可重置的线程本地对象；前提是确认执行器不把 `cells` 引用存进闭包/提升组（`registerEscaped` 只存 `PromotionGroup`，看起来不持有 cells，但需用执行器侧确认）
- **预期**：每次调用少 1–2 次分配；对高频小实参调用（业务侧表达式求值）有效
- **代价**：DEOPT 重放共用同一块缓冲要求它在一次调用内不被复用；需要 `finally` 归还，语义复杂度上升
- **验证**：`getAllocatedHeapSize()` 前后对照 + 分配计数埋点，同输入 1e6 次调用
- **证据状态**：`无基线（待验证，不进 tasks）`

<!-- 第 24 部分 -->

### [CPU] `HostFieldTable.register` 每字段整表重建，注册 k 个访问器是 O(k²) 拷贝

- **现状**：`pending` 里每个字段调一次 `HostFieldTable.register`；该函数在 `writeMtx` 内把**整个** bucket 映射复制进新 `HashMap`，再把该 index 的数组整体复制一遍后追加（`f_jit/src/runtime/HostField.cj:96-113`）。注册 N 个访问器 ⇒ N 次全量复制，累计 O(N²) 元素拷贝 + N 个 `HashMap`/`ArrayList`/`Array` 的分配。量级：一个 20 类 × 10 字段的宿主约 N≈200 ⇒ 约 2 万次元素拷贝 + 200 次全表重建，全部发生在 `Compiler.mtx` 内。
- **方案**：`registerType` 内先收集本类的 `Array<HostFieldAccessor>`，注册完一次性提交（新增 `HostFieldTable.registerBatch(items)`，在锁内只重建一次快照）；或把内部表示改成 持久化追加（每 index 一个不可变链表头 + 原子发布）。
- **预期**：注册期全表重建次数从 N 降到 1（或按类降到 C），元素拷贝从 O(N²) 降到 O(N)。未测，不给百分比。
- **代价**：新增一个 `internal` API；`register` 单条调用的现有语义（立即可见）需要保留给手工注册路径。
- **验证**：对「100 类 × 20 字段」的宿主跑 `cjpm bench -O2`，量 `Compiler.registerType` 总耗时（改前/改后，中位数 10 轮）；同时用 `getAllocatedHeapSize()` 对照注册期分配量。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] 注册期在 `Compiler.mtx` 内做完整反射枚举

- **现状**：`Compiler.registerType` 在 `this.mtx` 内调用整个 `ReflectRegistrar.registerType`（`f_jit/src/Compiler.cj:137-142`），其中包含 `cls.instanceVariables/instanceProperties/instanceFunctions/staticVariables/staticProperties/staticFunctions/constructors` 全量枚举、每成员一次 `mapType`（`TypeInfo.name` 反射调用）、每字段一次 `HostFieldTable.register`（见上条）、每类一次 `ancestryOf`。临界区长度属毫秒级（未测）。
- **方案**：把「不可变产物」的计算（枚举 + 描述符 + 访问器数组）移到锁外，锁内只做「冲突检查 + 三处登记 + `snapCache` 失效」；或对同一 `Compiler` 的批量注册提供 `registerTypes(list)`，一次持锁。
- **预期**：启动期注册不再是串行尖峰；并发注册不同类的宿主线程不再互相等反射枚举。收益取决于宿主类数量，未测。
- **代价**：锁外计算会读到「注册前」的 `ClassRegistry` 状态，`claimName` 的冲突判定必须留在锁内重做一次（重试/回滚逻辑），复杂度上升。
- **验证**：4 线程各注册 20 个类的启动脚本，量注册总墙钟与 `this.mtx` 等待时间（线程状态证据，CPU profile 看不出锁等待）。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [堆内存] `retained` 保活表与重复访问器都没有上限/淘汰

- **现状**：`retained`/`retainedNames` 每注册一个类名追加一条 `ClassTypeInfo` 强引用，进程生命周期内不释放（`f_jit/src/ReflectRegistrar.cj:62-78`）；重复注册（不同 `ClassRegistry`）会追加重复的字段访问器（见发现最后一节）。二者都以「宿主注册的类数」为上界，正常规模下很小（反射元数据每条数百字节到数 KB）。
- **方案**：`retained` 与注册表同生命周期管理（`release(name)` 对称注销）；访问器登记幂等化。不建议加 LRU——保活本身就是防 GC 的正确性要求，淘汰会重现 GAP-13 的 SIGSEGV。
- **预期**：只有「重复注册同一类」的宿主能观测到收益（访问器数从 k·n 降到 n）。稳态内存收益通常 < 1 MB，属于「防泄漏」而非「省内存」。
- **代价**：需要定义「类何时可释放」——目前没有类注销 API，新增会牵动 `ClassRegistry`/`Compiler` 的契约。
- **验证**：反复注册/注销同一批类 1000 轮，`getAllocatedHeapSize()` 与 `HostFieldTable` 条目数是否停在常数（`mem §1.2` 的有界稳态口径）。
- **证据状态**：`无基线（待验证，不进 tasks）`

<!-- 第 25 部分 -->

> 不是缺陷，是「还能更好」。三条都缺改前/改后对照数据，只作下一轮补数据的方向。

### [CPU] 标签表键从格式化字符串改成整数偏移

- **现状**：`A64Lower.lower` 对**每个字节码偏移**都执行 `this.e.bind('L${off}')`（`A64Lower.cj:94`），`bCond/cbz/cbnz/b` 的跳转目标也是 `'L${next + rel}'`（`:352-381`）；`A64Emitter.labels` 是 `HashMap<String, Int64>`（`A64Emitter.cj:54`）。单函数 2411 条指令 ⇒ 约 2400 次字符串插值 + 哈希（注释里已有「9432 B 机器码」的实测规模）
- **方案**：`labels` 改成 `HashMap<Int64, Int64>`，字节码偏移直接做键；`bail1..3/deopt/epilogue` 这类固定标签改用小的负整数或独立字段（`private var bailSlot: Int64`）；`bind/b/labelOffset` 增加 `Int64` 重载，`A64Compiler` 的 `e.bind('epilogue')` 换成枚举
- **预期**：消除每指令一次短字符串分配与一次字符串哈希；编译期分配量按「指令数」线性下降（数量级可估，收益比例待测）
- **代价**：`A64Lower` 全部 `'L${...}'` 拼接点要改；`A64Emitter` 的测试（`A64EmitterFixup_test.cj:44/50`、`A64EmitterSize_test.cj:39`）要用整数标签重写
- **验证**：`cjpm bench -O2` 编译同一批源码 N 轮取中位数；`cjprof record` 看 `String` 分配与 `bind` 自耗时占比
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] `helperDispatch` 地址常驻寄存器，去掉每次 helper 调用的 4 条 movz/movk

- **现状**：`helperCall` 每次都 `movImm64(9, this.helperDispatch)`（`A64Lower.cj:530`），同一模式还出现在 `helperCall0`（`:561`）、`helperCallHidReg`（`:595`）、`callClosure`（`:655/665`）。`movImm64` 对 64 位地址是 1 条 `movz` + 最多 3 条 `movk`（`A64Emitter.cj:299-312`），而 `helperCall` 在 lowering 里出现频次与指令数同阶（0x90-0xBF 几乎每条都走 helper）
- **方案**：序言把 `HelperAddresses.dispatch()` 物化到 callee-saved 的 `x21`（`prologue` 增 1 条 `stur`、`epilogue` 增 1 条 `ldur`，与 x19/x20 同套路，`A64Emitter.cj:267-287`）；所有 `blr(9)` 改成 `blr(21)`
- **预期**：每处 helper 调用少 1-4 个字（地址低位为 0 时通常 2-3 字），机器码体积与发射指令数同步下降；对 9432 B 量级的函数是可观测的码体积收缩（具体比例待统计）
- **代价**：`x21` 进入保存集（帧布局注释要改）；若 helper 内部破坏 x21（ABI 上不应发生，但 `@C` 入口需核对）会引入极难查的错值
- **验证**：统计 `emit` 字数（编译同一单元前后对比 `art.code.size`），`cjpm bench` 看编译耗时与执行耗时是否同向；`A64Exec_test` 全量回归
- **证据状态**：`无基线（待验证，不进 tasks）`

### [堆内存] 发射审计只记录非法基址

- **现状**：`A64Emitter.noteMemBase` 对**每次** `ldr/str` 都 `audit.add(reg)`（`A64Emitter.cj:462-464`），注释给出「598 次/编译」的实测频次；`audit` 是每次编译新建的 `ArrayList<Int64>`（`:460`），随函数规模扩容，结束后整体丢弃
- **方案**：把判定下推到发射点 —— `noteMemBase` 只在 `reg ∉ {19,20,29,31}` 时记录；`A64Compiler` 改成「快照非空即拒绝」（`auditAllows` 语义等价），或用一个 `Bool` + 首个非法基址。若仍需保留完整轨迹供诊断，用固定容量环形数组（容量 = 常量）替代 `ArrayList`
- **预期**：每次编译少 ~600 次 `add` 与一次容量翻倍拷贝；峰值只多一个固定小数组（对象数从 O(指令数) 降到 O(1)）
- **代价**：审计语义从「记录全部基址」变成「只记违规」，`A64AuditIsolation_test`/`EmitAudit_test` 里断言 `size == 1/2` 的用例要改；诊断能力下降（看不到合法路径）
- **验证**：`getAllocatedHeapSize()` 在「编译 1000 次」场景的前后对照 + RSS；`cjprof heap` 看 `ArrayList` 扩容占比
- **证据状态**：`无基线（待验证，不进 tasks）`

<!-- 第 26 部分 -->

> 全部无改前/改后基线，故只作为方案，不进修复清单。

### [CPU] 消除每个 helper 调用点的第二份 `CHECK_ERR`

- **现状**：`X86Lower.helper` 的 variant 0 在调用后内联发射 `cmp qword [r15],0; jne checkfail`（`X86Lower.cj:432-434`，7 字节 + 一次 errCode 读），而字节码生成器**保证**每条 `CALL_HELPER`/`CALL_HELPER_V` 后面紧跟一条 `CHECK_ERR` 指令（`f_jit/src/compiler/BytecodeBuilder.cj:34-35,434`，并受 `f_jit/src/compiler/Assembler.cj:193-197` 校验）。因此同一检查在每个 helper 调用点执行两遍。A64 侧同构（`A64Lower.cj:542-551`）。
- **方案**：helper 降低只保留结果写回与深度记账，检查交给紧随其后的 0x04 指令；或反之让 0x04 在 lowering 层识别前一条是 CALL_HELPER 时合并。需保留 `_NC`（0x76）不检查的语义。
- **预期**：每个 helper 调用点少约 10 字节机器码、少一次 `[r15]` 读 + 比较 + 条件跳转；`LEN`/`TO_STR` 这类每迭代多次调用的热点收益最大。具体百分比需实测。
- **代价**：对手写/`asm-inline` 且未经 Assembler 校验的字节流失去兜底检查（可用编译期断言恢复）；改动集中在一个函数。
- **验证**：`cjpm bench -O2` 同输入对照（解释器 vs JIT 的 helper 密集用例，如字符串插值/正则循环），并用 `cjprof` 看 `jit_dispatch` 调用次数是否不变、机器码体积统计。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] `JitExecutor.invokeOff` 每次调用 `malloc`/`free` 一次实参数组

- **现状**：`JitExecutor.cj:153-177` 每次 `invoke`/`invokeFn` 都 `LibC.malloc(n*8)`、倒序拷贝、调用、`finally` 里 `free`；`JitFunction.call` 的每次调用都会走这里（`f_jit/src/CompilePipeline.cj:243-250` 的 `body` 闭包）。
- **方案**：线程私有可复用缓冲（与 `MachineEnv` 的 TLS 同寿命）按需增长到 `max(n)`，或在上限内用 `alloca` 等价的栈缓冲；超过上限再退回 `malloc`。注意保留「最深实参在高地址」的倒序布局与 `finally` 恢复语义。
- **预期**：每次调用省 1 次 `malloc` + 1 次 `free`（glibc 快路径约数十纳秒），减少堆碎片与分配计数；对短小函数（JIT 的主要目标）占比可能可观。
- **代价**：新增一块按线程常驻的缓冲（峰值 = 该线程见过的最大实参数 × 8B）；TLS 需要在调用结束时复位以避免长生命周期线程持有大缓冲。
- **验证**：`cjpm bench -O2`（同输入、同并发）测 `call<T>` 吞吐中位数与 P99；`cjprof heap` 看分配次数下降；RSS 对照确认常驻缓冲不成为新峰值。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [堆内存] 编译期同一份机器码峰值存在三份副本

- **现状**：`JitCompiler.compileUnitWith`（`JitCompiler.cj:72-113`）先按函数收集 `bodies`（第一份），再汇总到 `out`（第二份），`JitExecutor.create` 再 `CodeBuffer.alloc(art.code.size+16)` 并把 `art.code` 拷进去（第三份）；`JitArtifacts` 在 `create` 返回后即被丢弃。`X86Compiler.compileFunctionWith` 另外用 `ArrayList<UInt8>` 逐字节 `add` 两次 `toArray()`（`X86Compiler.cj:63-70`），与 `JitCompiler` 已做的「两遍写、避免两倍搬运」优化口径不一致（`JitCompiler.cj:74-76` 注释）。
- **方案**：让 `compileUnitWith` 接受一个目标缓冲/回调（先算总长 → `CodeBuffer.alloc` → 直接写入），省掉 `bodies` 与 `out` 两份；`X86Compiler` 预先 `ArrayList<UInt8>(pre.size + body.size)` 或用数组直写。
- **预期**：编译峰值从约 3× 机器码降到约 1×（单元机器码 10 KB 量级时省 20 KB/次）；`JitArtifacts.code` 的生命周期缩短到 `create` 内部。收益与单元规模线性相关，需实测。
- **代价**：接口形状变化（`JitArtifacts` 仍是差分层 `RealRunners` 的公共产物），需要保留旧入口或同步 3 处调用点。
- **验证**：编译 1000 个中等单元，采 `getAllocatedHeapSize()` 峰值与 RSS；对照 `JitArtifacts` 是否仍被差分层引用（`f_jit/src/test/diff/RealRunners.cj:90,175,259`）。
- **证据状态**：`无基线（待验证，不进 tasks）`

<!-- 第 27 部分 -->

### [堆内存] `JitBindings.withOverrides` 改为「先收集覆盖项，再单趟构建」

- **现状**：`withOverrides`（`JitBindings.cj:99-118`）对每条覆盖项调用一次 `replace*`，而每个 `replace*` 命中时执行 `xs.clone()`（`:142`/`:163`/`:183`/`:204`）——k 条覆盖 ⇒ k 次全表复制 + k 个临时数组，峰值同时存活「原表 + k 个中间表」。表规模 = 类成员数十条，k = 显式覆盖条数（通常 1–3），只在注册期执行一次
- **方案**：先在 `over` 侧建「键 → 覆盖项」的临时 `HashMap`（键同 `replace*` 的匹配键），再对 `this` 的四张表各走一趟：命中则取覆盖值、未命中保留原值，最后一次性 `toArray()`。四个 `replace*` 可同时消掉（与 F6 同源）
- **预期**：注册期数组复制次数由 `k` 降到 1，临时数组峰值由 `k+1` 份降到 2 份；以每类 20 成员、覆盖 2 条估算，单类注册少 2 次全表复制
- **代价**：需要为四张表各写一次「键化」逻辑（或引入键函数），代码行数短期增加；`HashMap` 在小 k 下的常数开销可能吃掉部分收益
- **验证**：`cjpm bench -O2`，注册 1000 个类（每类 20 方法 / 5 字段）的启动耗时与 `getAllocatedHeapSize()` 前后对照，取 10 轮中位数与离散度；同时断言合并语义（同名替换、未命中追加、顺序保持）与现状逐位一致
- **证据状态**：`无基线（待验证，不进 tasks）`

<!-- 第 28 部分 -->

### [堆内存] 删除加载期两处整段副本（副本数 2→0，峰值待实测）

- **现状**：`FbcReader.load`（`FbcReader.cj:102-140`）持有 `raw`（N 字节），随后 `checkCrc32`（`:228-243`）复制整段 payload（N-40），`sliceOf`（`:430`）再复制 code/const/site/name 四段（合计 N-40）。两个副本生命周期不重叠，但都与 `raw` 同时存活 ⇒ 单次 `load` 峰值堆约 `2N`；`LoadedUnit` 长期持有四段副本 + `dir`/`types` 解析结构。
- **方案**：①`f_util.Crc32` 增加 `compute(data: Array<Byte>, off: Int64, len: Int64)`（内部就是现成的 `initRegister/update/finish`，`f_util/src/Crc32.cj:92-119` 已具备增量能力），`checkCrc32` 直接对 `raw[off..]` 的偏移区间计算；②`LoadedUnit` 改持有 `raw` + 段偏移（`header` 已给出四段长度），`code`/`site`/`name` 按需切片，或至少让 `code` 段共享 `raw`。
- **预期**：结构上少两份「约等于文件大小」的副本；对 10 MB 的 `.fbc`，按对象大小折算单次 `load` 峰值堆约可少 10 MB（副本数 2→0；实际降幅取决于 GC 时机与 `raw` 是否仍被持有，**需实测**）。
- **代价**：①要改 `f_util` 的公开 API（新增重载，兼容）；②`LoadedUnit` 改视图语义后，`code` 不再是独立数组，取 `Array` 的调用方要改（`LoadedUnit.code` 是 public 字段，属契约变更，需用户拍板）。
- **验证**：`getAllocatedHeapSize()` + RSS 对照，同 SDK、`-O2`、同一 10 MB `.fbc` 连续 `load` 100 次，取中位数；同时断言 `crc32` 结果与现实现逐位相同（`FbcHeader_test.crc32GoldenVectors` 可复用）。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] 合并 `load` 的三趟指令流扫描为一趟

- **现状**：同一份 code 段被完整解码三次：`checkInstructionSet`（`FbcReader.cj:270-293`，opcode 合法性 + 流边界）、`checkSiteCoverage`（`:320-340`，`SET_SITE` 覆盖）、`LookedUnit.requiresClassRegistry`（`:395-426`，`CALL_HELPER` 的 hid）。每趟都 `InsnDecoder.decode` 一次（decode 返回 `DecodedInsn` 结构，代价见 `bytecode/InsnDecoder.cj`，本部分未覆盖）。
- **方案**：合成一趟：在 `checkInstructionSet` 的 `while` 里同时做「`insn.op == OP_SET_SITE` ⇒ 查 `site`」与「`CALL_HELPER*` ⇒ 记 hid」，把 `requiresClassRegistry` 的第三个循环改成读趟内累积的布尔位。注意顺序：`site` 表当前在指令扫描之后才 decode（`:126-128`），需要把 `SiteTable.decode` 提前到 `readDir` 之后（它只依赖 `siteBytes`，无前置依赖）。
- **预期**：`load` 的指令解码次数 3→1；对 1 MB code 段预计省 2 次全量解码（占比需 profile 定，不预判百分比）。
- **代价**：`checkSiteCoverage` 的「独立拒绝文案 + 互不掩盖」可测性要保留（合成后仍需保证 `SET_SITE` 未覆盖的用例只被该条拦下）；`SiteTable.decode` 提前会让「常量段坏」与「site 表坏」的拒绝顺序变化，需同步 `FbcReader_test` 里依赖顺序的用例。
- **验证**：`cjprof record` 跑「加载 1 MB `.fbc` × 1000 次」，看 `InsnDecoder.decode` 自耗时占比改前/改后；`cjpm bench -O2` 同输入对照。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] `CanonKey.decFromText` 去掉逐字节字符串拼接

- **现状**：`CanonKey.cj:137` 每个数字字符都执行 `digits = digits + String.fromUtf8([b])` —— 每字符 1 个 `Array<UInt8>` 临时对象 + 1 次字符串拼接（O(n²) 复制），一次 Map 键规范化对 D 位有效数字产生 D 次分配。该函数在 `HandleTable.canonKeyOf(Decimal)`（`HandleTable.cj:377`）里**每次 Decimal 键读/写**都会走。
- **方案**：只记录首个数字的下标与结束下标，最后 `s[start..end]` 一次切片（去小数点需要两段：整数段 + 小数段，各切一次后拼一次）；同时把「去前导零」放进这条唯一路径（与第一条发现同修）。
- **预期**：单次键规范化分配次数 D→2；对 `Map<Decimal, _>` 高频读的场景减少 GC 压力（幅度需实测）。
- **代价**：与 `dec` 的规范化逻辑耦合更紧，必须与常量侧键规则同改同测；`decFromText` 的「非数字形态返回 `d:raw|...`」分支要保留。
- **验证**：`cjpm bench -O2` 跑「10 万次 `m[Decimal]` 查找」，对照中位数与 GC 次数；行为等价性用 `A5MapKey_test` + 新增 `{0.5:…}`/`{0.25:…}` 用例。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] `ConstRegistry.tokenOf` 的字符串拼接改为单缓冲

- **现状**：`ConstRegistry.cj:185-196` 对 `PList`/`PMap` 递归拼接 `t = t + tokenOf(...) + ','`，元素数 n 时字符串复制 O(n²)；该函数在 `makeInstance` 建 Map 常量键时对每个键调用一次（`:161`）。
- **方案**：改成「写入 `ArrayList<UInt8>`（或 `StringBuilder`）一趟到底」，递归改为传缓冲；键与值之间写分隔符，避免二义性（现在 `m[a:b,]` 依赖 `,` 与 `:`，字符串值里若含这些字符会产生键碰撞，可用长度前缀）。
- **预期**：n 元素 List 键的键构造从 O(n²) 降到 O(n)（n=1000 时约差两个数量级，需实测确认占比）。
- **代价**：token 文本格式变化会改变 hash 值（不影响正确性，但 `ConstMapKey.token` 是对外可见字段，测试若断言具体文本需同步）。
- **验证**：`cjprof record` 跑「含 1000 元素 List 键的 Map 常量 × 1000 次实例化」，看 `tokenOf` 自耗时与分配量。
- **证据状态**：`无基线（待验证，不进 tasks）`

<!-- 第 29 部分 -->

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

<!-- 第 30 部分 -->

### [堆内存] `assemble()` 期 code 段的两份副本

- **现状**：每个函数体在 `assemble()` 里被 `clone()` 一份（`Assembler.cj:79`），汇总进 `bodies`，再整体写进 `ByteWriter`（`:94`、`:111`）后 `take()`（`:114`）；峰值约等于 **2× code 段 + 常量/站点/名字段**，活到 `assemble()` 返回。
- **方案**：站点回填改为原地下标写入（`f.body.code` 已是本次编译独占的可变数组），省掉 `bodies: ArrayList<Array<UInt8>>`，直接向 `ByteWriter` 顺序写出。
- **预期**：code 段峰值内存减半；对典型单元（几 KB）无感，对 >1 MB 的 code 段才有意义（量级收益，未测）。
- **代价**：`assemble()` 失去幂等性（原地打补丁后二次调用会把 `codeOff` 叠加两次、站点表重复登记）——需在类注释里显式声明「只能调用一次」，或加一个 `assembled` 标志。
- **验证**：同一份源码分别用两种实现编译，`getUsedHeapSize()`/RSS 峰值 + 产物逐字节相等（`fjit` 的 `raw` 对比）。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] `Assembler.nargsOf` 的线性查表

- **现状**：`validateFunc` 每遇一条 `CALL_FUNC` 就调 `nargsOf(fid)`（`Assembler.cj:224`、`:322`），后者线性扫全部函数（`while (i < this.sess.funcCount)`）⇒ 校验阶段复杂度 O(函数数 × `CALL_FUNC` 数)。
- **方案**：`validateAll` 入口先建一次 `fnId → nargs` 的 `HashMap`（或按 fnId 序的稠密数组，fnId 由 `CompileSession` 单调分配），`nargsOf` 改查表。
- **预期**：校验阶段从 O(n·m) 降到 O(n+m)；只在函数数达千级、`CALL_FUNC` 密集时可见。
- **代价**：多一张临时表（n 项）；fnId 稀疏时需要先判上界。
- **验证**：`cjpm bench -O2`，同一份「1000 个闭包 + 递归调用」单元，编译耗时中位数对照；同时断言产物逐字节不变。
- **证据状态**：`无基线（待验证，不进 tasks）`

<!-- 第 31 部分 -->

### [CPU] 源码换行规范化在一次编译里被执行 4 次

- **现状**：`Lexer.normalizeNewlines`（`f_jit/src/compiler/Lexer.cj:123-140`）每次调用都重扫全串并按字节 `ArrayList<UInt8>` 追加，再 `toArray()` + `String.fromUtf8`（≈ 1 份新串 + 1 份临时数组）。一次 `SourceCompiler.compile` 里被调用 4 次：`SourceCompiler.cj:115` → `Parser.cj:51` → `Lexer.cj:57` → `PredefinedSnapshot.cj:141`（`NameResolver`）→ `DefiniteAssignment.cj:51`，入参都已经是同一份已规范化串
- **方案**：规范化只在 `SourceCompiler.compile` 入口做一次，后续构造改为接收「保证已规范化」的串（新增 `normalized: Bool = true` 形参或独立 `Lexer.normalized(src)` 工厂），保留 `Lexer(source)` 的兜底规范化以免破坏现有调用方
- **预期**：每次编译少 3 次全串复制（≈ 6n 字节的临时分配 + 3 次逐字节分支扫描）；对 100KB 源码量级约为每编译 0.6MB 冗余分配。**端到端收益未测**
- **代价**：多一个「调用方必须保证已规范化」的隐式契约，需要在 4 个构造点注释说明；语义零变化（规范化幂等）
- **验证**：`cjpm bench -O2`（同 SDK/同机）对 10KB / 100KB / 1MB 源码各跑 20 轮取中位数，对照编译耗时与 `getAllocatedHeapSize()` 增量；同时跑 `Lexer_test.newlinesAreNormalizedInEveryForm` 等既有用例确认字节不变
- **证据状态**：`无基线（待验证，不进 tasks）`

### [堆内存] 全量 `Token` 物化 + 每 token 一份 `String` 拷贝

- **现状**：`Parser.cj:52` 用 `tokenize()` 一次性持有全部 token；每个 `Token.text` 由 `Lexer.sliceStr`（`Lexer.cj:894-904`）新建 `Array<UInt8>` 再 `String.fromUtf8`，即每个 token 至少 2 次分配（临时数组 + 字符串）。n 字节源码约 n/4 个 token，峰值堆 ≈ 常数 × n，且全部活到解析结束
- **方案**：`Token` 改为持有 `(start, end)` 字节偏移 + 按需切片的访问器（`text()` 惰性构造，或直接返回 `String` 子串视图），`Lexer` 只对需要解码的形态（字符串字面量 `decodeEscapes` 之后）保留实串；`Parser` 的前瞻只读 `kind`，不受影响
- **预期**：峰值堆下降与「token 平均长度 / 单 token 固定开销」同阶（**估算 30%–50%，无实测**）；短源码（<4KB）收益可忽略
- **代价**：`Token` 结构变更波及 Parser / Lowerer / 测试中所有 `t.text` 读取点；`decodeEscapes` 后的串仍需实串（两种表示并存）；错误消息需要用源码 + 偏移现场切片
- **验证**：对 1MB 源码跑 20 轮编译，记录 `getAllocatedHeapSize()` 峰值与 RSS 峰值，改前改后对照（`-O2`，同机）；同时用 `Lexer_test`/`JsonLit_test` 全量用例守字节等价
- **证据状态**：`无基线（待验证，不进 tasks）`

<!-- 第 32 部分 -->

> 非缺陷。以下均**无改前基线**，只作为下一轮补数据的候选，不进 `tasks.md`。

### [堆内存] `flushNames` 先全量复制 `pendingNames` 再排序

- **现状**：`pendingNames`（`:150`）按「每条声明/形参/for 绑定一条」增长，`flushNames`（`:186-211`）先逐条 `add` 到新 `ArrayList`，再在新表上做插入排序，最后逐条写入 `sess.names`。峰值同时持有两份 `(UInt32, Int64, String)` 元组 + 排序期的临时位移。
- **方案**：`pendingNames` 改为在 `add` 处二分插入（声明顺序天然接近有序，插入代价接近 O(1) 摊还），`flushNames` 直接遍历写 `sess.names`，去掉副本。
- **预期**：元组数组峰值减半；排序比较次数从最坏 O(n²) 降到 O(n log n)（n = 本单元声明数）。
- **代价**：`FnCtx.declare` 与 `lowerForIn` 等 6 个 `add` 点改为走统一的 `addName(fnId, slot, name)`；插入排序换成二分需要多一次比较函数。
- **验证**：单测覆盖「形参 + 循环内声明 + 嵌套闭包」三类混排（校验 `(fnId, slot)` 严格升序不变）+ 大单元（≥5k 声明）下 `getAllocatedHeapSize()` 与编译耗时中位数对照。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] 名字查找与静态类型推算的重复线性扫描

- **现状**：`FnCtx.find`（`:116-127`）每次按名查找都从最内层作用域线性扫描；`FnCtx.declare`（`:105-114`）对同层每次声明做一次线性查重；`staticTypeFull` / `hostObjectClassOf` / `containerInfoOf` 对同一子表达式会重复递归（`lowerAssign` 里 `containerInfoOf(target)` + `staticTypeFull(index)` + 再 `lowerExpr(target)` 各算一遍）。
- **方案**：`FnCtx` 维护 `HashMap<String, VarSym>` 栈（与 `scopes` 同步 push/pop），`find`/`declare` 降为 O(1)；`lowerExpr` 返回结构化结果，让调用方复用已算出的静态类型（与上面「`last*` 旁路改造」是同一处改动）。
- **预期**：与声明数 n、表达式数 m 相关的作用域扫描从 O(n·m) 降到 O(m)；深嵌套闭包（每层 `outerNames` 全量扁平化，`:3229-3234`）受益更明显。
- **代价**：`VarSym` 的可见性语义要保留「同层查重 + 遮蔽」两件事；`HashMap` 每次 push/pop 需要 1 次分配，可用 `Array<HashMap>` 复用。
- **验证**：`cjpm bench -O2` 同输入（生成的 10k 行 DSL 源，含 200 个嵌套闭包）对照编译耗时中位数与 P95；`cjprof record` 看 `FnCtx.find` 自耗时占比。
- **证据状态**：`无基线（待验证，不进 tasks）`

<!-- 第 33 部分 -->

### [堆内存] 去掉重复的整源规范化副本

- **现状**：一次 `compile` 对源码串做 4 次 `normalizeNewlines`（`SourceCompiler.cj:115`、`Parser.cj:51`、`Lexer.cj:57`、`PredefinedSnapshot.cj:141`），每次 `ArrayList<UInt8>` + `toArray()` + `String.fromUtf8` 共 3 个对象、约 2 份字节副本；10 KB 源码 ⇒ 约 80 KB 瞬态分配，源码越大线性放大。生命周期仅限一次 `compile`，无跨调用持有。
- **方案**：`SourceCompiler.compile` 规范化一次并向下传递（`Lexer` 增 `init(normalized:)` 或让 `Lexer`/`Parser`/`NameResolver` 接受"已规范化"标记）；实现统一到 `Fingerprint.normalizeSource`。
- **预期**：每次编译少 3 次整串复制（约 -75% 该环节分配），源码 10 KB 时省 ≈60 KB 瞬态；对总分配占比待测。
- **代价**：`Lexer` / `Parser` / `NameResolver` 的构造契约要写明"入参必须已规范化"，否则会出现"两套 CRLF 口径"的回归；改动面 4 个文件但都是内部构造。
- **验证**：同一份 10 KB 源码跑 10k 次 `compile`，对比 `getAllocatedHeapSize()` 峰值与总分配量（`mem §1.2`），同时断言产物 `.fbc` 字节不变。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [堆内存] 解析器的语句数组与 token 数组各留一份

- **现状**：`Lexer.tokenize()` 把整源物化成 `Array<Token>`（`Parser.cj:52`），`splitTailExpr` 又把 `body[0..n-1]` 复制进新 `ArrayList` 再 `toArray()`（`Parser.cj:219-223`）——每条语句被数组头与元素各引用一次，尾部一条额外复制。源码 n 条语句 ⇒ 约 n 个 `AstStmt` 引用槽的冗余（Token 数组本身是解析必需，不在此列）。
- **方案**：`splitTailExpr` 直接用 `body.slice(0, n)`（若 `Array` 有零拷贝视图则用之），或在 `parseBlockBody` 里就地"最后一条留作尾表达式"。
- **预期**：省一份 n 元素的引用数组（每条语句 8 B 量级），对语法树总占用影响小。
- **代价**：`LambdaAst.body` 与 `retExpr` 的构造点要同步改；几乎无语义风险。
- **验证**：`parseLambda` 前后 `getAllocatedHeapSize()` 差值对照，AST 形状用例（`Parser_test`）全绿。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] 预定义函数名查找是线性扫描，且每个调用点查 2–3 次

- **现状**：`PredefinedSnapshot.slotOf`（`PredefinedSnapshot.cj:65-74`）逐项字符串比较；`has` / `paramTypesOf` / `retTypeOf` 各自再调一次 `slotOf`（`:60`、`:76`、`:84`），`Lowerer` 对一个调用点会分别取形参与返回类型（如 `Lowerer.cj:1988/2029/2046`、`:2574-2578`）⇒ 每个调用点 2–3 次 O(n) 扫描、每次 n 次字符串比较。
- **方案**：`PredefinedSnapshot` 内部建一次 `HashMap<String, Int64>` 索引（构造期构建，快照不可变），`slotOf` 走哈希；`paramTypesOf`/`retTypeOf` 合并成一次 `slotOf` + 两次下标。
- **预期**：注册数 n 较大（≥32）时调用点解析从 O(n) 降到 O(1)；n 很小（典型 3–10 个）时收益大概在噪声内。
- **代价**：快照多一个不可变 map（n 个条目，可忽略）；`HashMap` 迭代顺序无关，不影响 slot 语义。
- **验证**：`cjprof record` 跑"单文件 5k 次 compile + 200 个注册函数"的脚本，对比 `slotOf` 自耗时占比与编译总时长中位数；n=10 时同测一次，确认没有变慢。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] 删除死字段顺带去掉一次整源哈希

- **现状**：`CompiledSourceUnit.fingerprint` 每次编译整串跑 `Fnv128.fnv1a128`（`SourceCompiler.cj:130-132`）后无人读；`CompilePipeline` 另算一次 `Fingerprint.fnv1a128(source)`（`CompilePipeline.cj:60`）。
- **方案**：删除该字段（或让 `CompilePipeline` 复用），只保留缓存键那一份哈希。
- **预期**：每次编译少一次 O(len) 哈希 + `UInt128` 装箱；10 KB 源码下约省两次整串遍历（另一份仍要算），端到端占比预计 <2%。
- **代价**：`CompiledSourceUnit` 的 `init` 签名变化，`Capture_test` 等构造点需跟着改。
- **验证**：`cjpm bench -O2` 同输入 1k 次 compile 的中位数对照；顺带断言 `.fbc` 字节不变。
- **证据状态**：`无基线（待验证，不进 tasks）`

<!-- 第 34 部分 -->

> 本部分没有「有基线」的性能方案。以下三条只是「值得下一轮补数据」的方向，按规则同时登记进「待验证假设」，不当作结论。

### [CPU] `DbgDump.report` 的逐条字符串拼接（无基线）

- **现状**：`report:174-181` 每条局部变量一次 `items.add('[i] ...')`，再由 `joinItems:233-244` 用 `out = out + it` 累加；`nLocals` 上界是目录全域（`maxNLocalsOf`），典型函数 < 32。
- **方案**：`ArrayList<String>` + 手写 join 换成一次性 `StringBuilder`（或 `String.join`）。
- **预期**：只在 `nLocals` 较大时减少 O(n²) 复制；错误路径单次执行，端到端可观测收益预计低于噪声。
- **代价**：无（输出必须逐字节不变，`DbgDump_test.reportTemplateIsByteExact` 可守住）。
- **验证**：`cjpm bench -O2` 构造 `nLocals = 64/256` 的伪帧，取 10 轮中位数；同时比对报告文本。
- **证据状态**：`无基线（待验证，不进 tasks）`

<!-- 第 35 部分 -->

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

<!-- 第 36 部分 -->

> 不是缺陷，是「还能更好」。以下均无改前/改后对照数据 ⇒ 只作方案，不进 `tasks.md`。

### [CPU] Map 迭代的每步 pin + 窗口去重扫描构成 O(n²)

- **现状**：`IterTable.advance` 每个条目调用两次 `HandleTable.anyToCell`（`IterTable.cj:204-205`），对非标量键/值走 `pin`；`pin` 在窗口内线性扫描已有 pin 并逐个 `canonKeyOf` 比较（`HandleTable.cj:464-495`）。迭代 n 条 ⇒ O(n²) 次字符串比较 + 2n 个槽。
- **方案**：`IterEntry` 持有两个可复用槽位（`advance` 时原地改写 payload）或按 `advance` 前释放上一组 cell；同时可给 `pin` 增加「调用内不可变对象」的快速路径。
- **预期**：n=10k 的 `Map<String,String>` 迭代从 O(n²) 降到 O(n)；具体降幅待测。
- **代价**：`IterEntry` 增加 2 个槽的释放逻辑，需保证 DEOPT 重放后游标失效语义不变。
- **验证**：`cjpm bench -O2`，构造 1k/10k/100k 条 `Map<String,String>` 全量遍历，取中位数与 P95，对比改前改后；同时记录 `HandleTable.windowUsed()` 峰值。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] `HostFieldTable.register` 每次注册整表复制（O(n²) 启动成本）

- **现状**：`register` 在锁内复制整个 `buckets` 哈希表并重建目标桶数组（`HostField.cj:96-113`），n 次注册 ⇒ O(n²) 次 `add` 与 n 次整表分配。
- **方案**：改用「桶级不可变 + 原子替换单桶」，或注册期用可变 `ArrayList` 累积、`freeze` 时发布一次快照（`HostFieldTable.find` 仍只读快照，语义不变）；`resetForTest` 复用同一路径。
- **预期**：注册总成本从 O(n²) 降到 O(n)；n=数百类时启动期可感知（未测）。
- **代价**：多一个「可变构建态 / 不可变发布态」状态机；`accepts` 重入注册（`HostFieldSnapshot_test.cj:115-135` 已覆盖）必须在构建态下仍不死锁。
- **验证**：`cjpm bench -O2` 注册 10/100/1000 个 `(index, class)` 组合，量测总耗时与分配字节；`HostFieldSnapshot_test` 全绿。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] 每次字段访问的线性桶扫描 + 闭包调用

- **现状**：`HostFieldTable.find` 对同 index 的全部注册项顺序调用 `accepts(obj)`（`HostField.cj:121-133`）；H64/H65 每次访存都要走一次。若 index 上挂多个类（同 index 跨类复用是常态），单次访问是 O(桶长) 次闭包调用。
- **方案**：注册期按「实际类」索引（`typeOf(obj)` → 直接命中），保留 `accepts` 作为兜底；或对桶长 > 1 的桶缓存「上一命中项 + 上次对象类」的一元缓存。
- **预期**：字段访问热点从 O(桶长) 降到 O(1)；收益取决于桶长分布（未测）。
- **代价**：需要 `TypeInfo` 作为键（`RuntimeState` 已有 `typeCodes` 的按引用缓存先例）；语义不变但实现复杂度上升。
- **验证**：`HostFieldGet_test`/`HostFieldSet_test` 全绿 + `cjprof record` 跑字段访问密集负载，看 `HostFieldTable.find` 自耗时占比是否 >5%。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [堆内存] `InterpFrame` 每层两个堆对象、栈容器动态扩容

- **现状**：每次调用新建 `InterpFrame`（`Interp.cj:37-45`：`locals` 数组 + `ArrayList<Int64>`），`ArrayList` 从 0 容量按 `add` 增长；`maxStack` 在 `FuncEntry` 里已知（`:99-109`）却未用于预分配。
- **方案**：`InterpFrame` 按 `(nLocals, maxStack)` 预分配 `ArrayList<Int64>(maxStack)`；或按深度维护帧池（有界，复用 `locals`/`stack`）。
- **预期**：递归/循环密集单元每层减少 1~2 次扩容复制与 2 次分配；峰值内存降幅待测（不改变稳态 RSS 的可能性很大）。
- **代价**：池化需上界（无界池会把峰值变常驻，`mem §2.3`）；预分配对 `maxStack` 很大的函数会略微增加单帧常驻。
- **验证**：`getAllocatedHeapSize()` + RSS 对照，同一单元跑 10 万次调用，记录分配总量与峰值；`cjprof heap` 看 `InterpFrame` 占比。
- **证据状态**：`无基线（待验证，不进 tasks）`
- **local mode 附注**：`InterpFrame` 与 `locals` 会作为成员/返回值逃逸出分配函数（`runClosure` 把 `locals` 赋给 `f.locals`），不满足逃逸检查；`ArrayList` 为 `non-Copyable` 且 std 是否提供 local mode 重载需逐个核对 ⇒ 本模块**不建议**做 local mode 改造（被约束 2/3 卡住）。

<!-- 第 37 部分 -->

### [堆内存] 提升组每次 `add` 的 1 元数组 + 每次返回闭包的 `snapshot()` 数组

- **现状**：`PromotionGroup.addLocked` 每提升一个槽就新建 `Array<Int64>`（`PromotionGroup.cj:69` 的 `moveOutGroup([id])`）；返回逃逸闭包时 `CallMarshal.unboxClosure` 再取一份全量快照数组（`CallMarshal.cj:265` 的 `group.snapshot()`，长度 = 闭包捕获数）。按「N 个捕获的闭包每次返回」估算：N+1 个短命数组 + 一次全量拷贝，生命周期仅一次调用
- **方案**：给 `PromotionGroup` 加 `addAll(ids: Array<Int64>)`（一次 `moveOutGroup(ids)`）与 `forEachId(f: (Int64) -> Unit)`（免快照，锁内回调只做 `removeFrom` 这种 O(1) 动作，或改为返回持久索引）；`CallMarshal.promoteClosureGraph` 先收集 ids 再批量提升
- **预期**：每次返回少 N 次 `Array` 分配与 N 次全局 `HandleTable.mtx` 进出；快照数组归零。数量级是「每次闭包返回 N+1 个对象」，收益随捕获数线性增长（N 通常 1–8）
- **代价**：`addAll` 需要保证与逐条 `add` 相同的幂等语义（`ids` 内重复 id 只能计数一次，去重逻辑上移到调用方或 `moveOutGroup` 内部）；锁内回调要避免重入 `PromotionGroup`（`removeFrom` 只碰 `CallMarshal` 的本地列表，安全）
- **验证**：`cjpm bench` 跑「返回含 1/4/8 捕获的闭包 × 100k 次」，对照 `getAllocatedHeapSize()` 与本轮新增的分配计数；同时断言 `windowUsed`、`size()`、`contains()` 与旧路径一致
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] `TextFormat` 最短往返：`pow5/pow2` 逐次乘法 + 每轮重解析 `BigInt` 常量

- **现状**：`pow5(k)` / `pow2(k)` 用 `while` 循环逐次乘（`TextFormat.cj:243-261`），`k` 最大 1074（denormal）⇒ 单次格式化最多 1074 次「逐渐变大」的 BigInt 乘法；`roundToSignificant`（`:264-292`）每轮又 `BigInt.parse('10'/'2'/'1')` 4 次，外层 `while (p < ds.size)` 最多 17 轮。这是每次 Float64→文本化的固定开销路径（`Helpers.cj:449` 的 `to_str` 与 `:400-406` 的 `decFromF64` 都走它）
- **方案**：① `pow2/pow5` 改二进制幂并缓存 `5^1,5^2,5^4,…`（到 5^1024）为 `static let` 静态表，组合即可；② `roundToSignificant` 的 `ten/two/one` 提成 `static let`；③ 把 `bitsOf(exp, frac)` 提到循环外
- **预期**：单次 f64 文本化减少约 10^3 次 BigInt 乘法与约 70 次 `parse`；端到端收益取决于 f64→string 在负载中的占比（需 profile）
- **代价**：静态表常驻（约 11 个 BigInt，几 KB）；`pow5` 目前是纯函数，改造需保证任意 `k` 仍可取（组合式实现天然支持）
- **验证**：`cjpm bench -O2` 同机对照「10 万次 f64 文本化」中位数与离散度；`TextFormat` 已有 diff 对拍用例（`test/diff/RealRunners.cj:406`）保证逐字节不变
- **证据状态**：`无基线（待验证，不进 tasks）`

<!-- 第 38 部分 -->

### [CPU] 每用例重建常量句柄与编译产物

- **现状**：`runAll` 对每个 `DiffCase` 重新 `FbcReader.load`（`RealRunners.cj:51`、`:77`、`:162`、`:246`）→ 对 `unit.consts.size` 逐个 `constHandle`（`:79-84` 等）→ `ConstMirror.build` → `compileUnitWith` → `CodeBuffer.alloc`。同一份 raw 字节在 `T2/*`、`T33/*`、`Q6/*` 等用例里被重复处理；`pinConst` 每次都要在全局 `mtx` 内线性扫表（`HandleTable.cj:611-629`），表越用越大。
- **方案**：在差分层加一个按 `DiffCase.unit`（同一份 raw 字节）索引的有界缓存，缓存 `(ConstMirror, FnTable, CodeBuffer, entryOff)`，每次用例结束只回收句柄引用；或至少复用 `Interp(unit, constIds)`（`Interp.cj:96-99`）把常量句柄提到套件级。
- **预期**：减少每用例一次的 `malloc/mprotect/__clear_cache` 与 `O(n_slots × n_consts)` 的扫表；套件级耗时降幅未测（不改变单用例语义）。
- **代价**：缓存需有容量上限与失效策略（字节码 → 机器码的映射不可跨进程复用）；共享 `ConstMirror` 后「常量句柄生命周期」从「每用例」变「每套件」，回收点集中，写错会变成更隐蔽的泄漏。
- **验证**：`cjpm bench -O2` 跑同一组 ~50 个用例，比较总耗时中位数（≥5 轮）；`cjprof record` 看 `HandleTable.pinConst` 与 `CodeBuffer` 相关符号自耗时占比；`NativeAssets.liveCount()` 在套件结束时必须回到基线。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] 差分跳过判定前置，避免「先编译再发现引擎不足」

- **现状**：`DiffSession.assertTripleEqual` 先 `runAll`（每个可用 runner 都会完整编译并执行单元），再在 `outcomes.size < 2` 时抛异常（`DiffHarness.cj:124-127`、`:187-189`）。单引擎平台（非 Linux / 非 x86_64 / 非 aarch64）上，唯一可用的 `InterpRunner` 仍会完整跑一遍，然后整例判失败。
- **方案**：`DiffSession` 增加 `availableCount()`（只调 `isAvailable()`，零编译），在 `assertTripleEqual` 入口先判「可用引擎数」，不足时走「无证据」返回；同时把 `ran/skipped` 计数的语义从「引擎执行次数」改成「本次证据判定」。
- **预期**：单引擎平台上跳过 N 个差分用例的全部编译与执行成本（N 为用例数）；对多引擎平台零影响。
- **代价**：`DiffSession` 的 API 需要加返回值类型（`DiffVerdict`），调用方要改断言；`ran()/skipped()` 的既有断言（`diff_test.cj:42-43`、`:94-96`）需同步调整。
- **验证**：在 Windows（`os != 'Linux'` 分支）跑 `cjpm test`，记录差分用例耗时与失败数（应从「失败」变「跳过」）；Linux aarch64 上重跑确认 `ran()==2` 且四元组对拍结果不变。
- **证据状态**：`无基线（待验证，不进 tasks）`

## 待验证假设

<!-- 第 1 部分 -->

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 深度递归的真实崩栈阈值远低于业务预期（机器码帧对运行时栈扩容不可见） | `f_jit/README.md:375-392`；`src/runtime/Interp.cj:603-619`、`src/backend/X86Lower.cj:437-455` | 两引擎各自的崩溃深度与每帧字节数 | 固定 `cjStackSize`（默认 128 KB 与 1 MB 两组），跑 `recursive(n)` 二分 n，记录首个崩溃点与信号；x86_64 / aarch64 各一次 |
| 2 | `CompileCache.awaitReady` 的墙钟自旋在并发编译时吃掉可观 CPU | `src/CompileCache.cj:154-163` | 等待者数 × 自旋时长的 CPU 占比 | `cjprof record`：N=2/4/8 线程同键编译同一长源码（或调大 `awaitTimeoutNs`），看 `awaitReady` 自耗时 |
| 3 | `PowHelper` 用异常判乘法溢出（`try { a * b } catch`）在 `**` 密集负载下比显式检查更贵 | `src/runtime/PowHelper.cj:71-78` | 单次 `**` 耗时与异常路径占比 | `cjpm bench -O2`：`2 ** k` 1e6 次（溢出/不溢出两组），改前改后中位数对照 |
| 4 | 并发审计的调用开销基线（2971 ns/call）与 README 引用的 1.27×/2.40×/1.91× 可作后续对照基线 | `doc/concurrency-audit.md:102-121`、`README.md:597-599` | `-O2`/`-O0` 标注、轮次、中位数与离散度 | 同机 `cjpm bench -O2` 跑 `CallPathBench_test` 3 轮，记录中位数 / P95 / SDK 版本 / 负载；专用 8 核复跑 verify.md 场景 |

<!-- 第 2 部分 -->

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 同键编译等待用「忙等 + 指数退避」，多 waiter 时 CPU 空转可能成为编译期热点 | `f_jit/src/CompileCache.cj:128-151` | waiter 数量与 CPU 占用占比；等待期间的自耗时 | 4/8 线程同时编译同一份大源码，`cjprof record` 看 `awaitReady` 自耗时；记录 P50/P95 等待时长 |
| 2 | `Compiler.registerType` 在全局 `mtx` 内做反射扫描与 `diag` 回调，注册并发度可能被压到 1 | `f_jit/src/Compiler.cj:134-158` | 单类注册耗时、临界区占比、并发注册吞吐 | 100 个类 × 8 线程并发 `registerType`，分段计时锁内/锁外；对比把 `diag` 移出锁后的吞吐 |
| 3 | 失败缓存触顶「整表清空」会在坏源码密集场景造成重编抖动 | `f_jit/src/CompileCache.cj:95-107` | 失败率、清空频率、重编次数放大比 | 持续注入 300+ 种坏源码，统计 `failureCount` 曲线与 `pipelineRuns` 增量；对比 LRU/单条淘汰 |

<!-- 第 3 部分 -->

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 8 线程扩展比 1.91×（低于 4 线程 2.40×）是「共享 7 核 VM 超订」造成，独占核下可继续上升 | `f_jit/doc/design-parallel-call.md:233` | 独占核 / 独占 VM、8 线程 ≥10 轮的绝对值与离散程度 | `cjpm bench -O2` 跑 `ParallelThroughput_test` 1/2/4/8 线程，独占核 VM，取中位数与 P95；同时记录 `liveCount` 回基线 |
| 2 | M2.2 类型化 adapter 命中后，H63 仍余可观反射开销（文档自述 4.6–5.8×） | `f_jit/doc/design-m2.md:479`、`src/runtime/HostCall.cj:62-70` | adapter 命中率、`reflectiveInvoke` 自耗时占比 | 在 `HostCall.cj` 三路（adapter / plan / reflective）加计数埋点，配 `cjprof record` 跑 10 分钟稳态回调负载 |

<!-- 第 4 部分 -->

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | x86_64 侧回边 `H22` 的自耗时占比远低于 aarch64（97.7% 仅 aarch64 实测） | `doc:500`、`doc:2147` | x86 同场景 ns/轮与占比 | 同一空循环单元在有/无 deadline 两组下 `cjpm bench -O2`，10 轮取中位数与 P95 |
| 2 | `DUP2`（#1）在真实产物中的可达性：前端不发射，但仓外/历史 `.fbc` 可能含 0x18 | `src/backend/A64Lower.cj:208-212` | 现有 `.fbc` 语料里 0x18 的出现次数 | 扫 `**/*.fbc` 与 T1 黄金夹具，统计 opcode 直方图；aarch64 上跑含 `DUP2` 的最小单元做三引擎差分 |
| 3 | 句柄槽在长跑下是否真有「不复用 → 触顶 16」风险（文档 #9 的字面读法） | `doc:1327` vs `doc:899` | 10^6 次调用的槽计数曲线 | 长跑 `call<T>`（含容器返回）采样 `HandleTable` 槽数与 RSS，与「不复用」模拟基线对照 |
| 4 | 每帧末项 `+8` 与 16B 对齐在深递归下显著降低可用深度 | `doc:116` | 实际可用递归层数 | 非尾 `recursive` 压到栈溢出记层数，与去掉 `+8` 的对照分支比较 |

<!-- 第 5 部分 -->

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | H63 重入链在默认线程栈下会在某个深度直接崩溃，而不是返回 15/21 | `f_jit/doc/jit-bytecode-m2.md:153` | 崩溃前的最大嵌套深度、栈帧大小、x86_64/aarch64 差异 | 写「宿主闭包 → JIT → 同一宿主闭包」的自递归，逐层加深直到崩溃，记录深度与线程栈配置；同用例在 `-O2` 下重复 10 次取中位数 |
| 2 | 类型化 adapter / per-signature plan 生效后，CALL_HOST 单次开销已显著低于规格记录的 4.6–5.8×，§8 的 10× 回归门禁已失真 | `f_jit/doc/jit-bytecode-m2.md:210-212` | 快路径的单次耗时与相对 user helper 比值 | 同 SDK、`-O2` 复跑 `PerfM2_test`（预热 64、各 2000 次），分别开/关 adapter 与 plan，取中位数与离散度 |
| 3 | 分发加载的 `.fbc` 返回带句柄捕获的闭包时，提升组无法构建（或误提升值 cell） | `f_jit/doc/jit-bytecode-m2.md:510`、`:493` | 是否有加载期拒绝规则；捕获描述符的运行期载体 | 构造最小 `.fbc`：`closure_new` 捕获一个 `pin` 参数与一个窗口分配结果，`RET` 返回；经分发入口加载并调用，观察 19 / 泄漏 / 对象身份 |
| 4 | 循环内读句柄型字段（H64 每次登记 1 槽）会把窗口从 128 倍增到 `capacityLimit`，带来可观的窗口内存与 hwCap 抖动 | `f_jit/doc/jit-bytecode-m2.md:345` | 每轮 `hwCap` 增长率、峰值已用槽数、RSS | 写 `for (i in 0..N) { u.name }` 的基准，埋点记录 `hwCap`/`hwTop`，N = 10/100/1000/10000 |
| 5 | 进程级字段表按 index 分桶线性 `accepts` 扫描，在多类共享同一 index（如都从 0 起编号）时查找成本随注册类数线性上升 | `f_jit/doc/jit-bytecode-m2.md:372` | 单次 H64/H65 的查找耗时 vs 同 index 表项数 | 注册 k 个类（k = 1/10/100）各带 index=0 字段，跑 1e6 次 `host_get_field`，`cjprof record` 取 `HostFieldTable.find` 自耗时 |

<!-- 第 6 部分 -->

> 没有本部分代码的性能数据支撑，以下均不计入统计、不进 `todo.md` / `tasks.md`。

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `ti` 惰性化后，无 adapter 的宿主闭包**每次回调**都做一次 `FunctionTypeInfo.of`（含 std 反射元数据缓存争用），回调循环会比改动前更慢 | `f_jit/doc/optimize-call-path.md:498-512` | 回调循环的 ns/次对照（改前/改后）、`FunctionTypeInfo.of` 自耗时占比 | 用 `HostClosureAdapter_test` 同款 5 万次回调单元、**不登记 adapter**，A/B 各 5 轮取中位数；`cjprof record` 看 `FunctionTypeInfo.of` 自耗时与线程状态 |
| 2 | 签名表超 128 条后每次调用重建 `SignaturePlan` + 写锁 + 快照分配，形成延迟台阶 | `jit-bytecode-m3.md:314` | 第 128/129… 个签名的单次 `getOrBuild` 与端到端 `call` 耗时 | 注册 127/128/200 个不同签名，各跑 1e5 次 `getOrBuild` 与 `call`，埋点 `entryCount`/`buildCount`，对比中位数与 P99 |
| 3 | 按当前实现复跑 aarch64 `PerfCompare_test`，JIT 单轮成本将远低于 200 ns/轮（回边 safepoint 修复后） | `f_jit/doc/perf-m1.md:8-17` | 修复后的 JIT / cjnative / 解释器三侧 5 轮耗时 | 同 SDK `-O2`、同机器复跑 `cjpm test --filter PerfCompare_test --no-capture-output`，5 次取中位数与离散度 |
| 4 | `perf-m2` 的 4.63×/5.75× 在现行用例（4000 次 × 3 轮中位数 + `MonoTime`）下会与旧值有系统偏差 | `f_jit/doc/perf-m2.md:13-21` | 现行用例的 `PERF-M2` 输出（三比值 + 单次 ns） | 跑 `cjpm test --filter PerfM2_test --no-capture-output`，收集 5 次 `PERF-M2 round*` 行，比对 4.63×/5.75× |

<!-- 第 7 部分 -->

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `close(timeoutMs)` 的自旋排空在在飞调用未退出时占满一个核，且与 `exitUnit`/`exitClosure` 抢同一把 `mtx`，是关闭路径的主要 CPU 来源 | `f_jit/src/JitFunction.cj:237-253`、`:309-326` | 单次 `close` 的 CPU 时间占比、线程状态（RUNNABLE vs BLOCKED/WATING）分布 | 一线程持长调用，另一线程 `close(5000)`；分段计时 + `cjprof record`；锁等待另取线程状态证据（CPU profile 看不到） |
| 2 | `plan-m1.md:275` 的 43.8×（Interp 1,759,793,327 ns vs AArch64 40,221,815 ns，200000 次循环）不能外推到 x86_64 | `f_jit/doc/plan-m1.md:275` | x86_64 同结构、同副作用、`-O2`、同输入的对照 | 同一循环用例在 x86_64 上跑 Interp 与 JIT 两路径，≥5 轮取中位数与离散度 |
| 3 | 并发矩阵 5 例（并发度 6、合计约 70 ms）覆盖不到更高竞争下的竞态 | `f_jit/doc/spec/add-concurrency-matrix-tests/verify.md:88-96` | 8–32 线程下的失败率 / 变异存活率 | 沿用该变更的变异手法（M1/M2/M2b）在更高并发下重跑，统计红/绿 |
| 4 | `PerfM2_test` 的阈值型断言在高负载下假失败，说明门槛余量不足 | `f_jit/doc/plan-m2.md:162`、`f_jit/doc/spec/align-call-entry-spec/verify.md:8` | 失败率与阈值余量 | 连续 20 轮全量，记录失败次数与当轮机器负载 |

<!-- 第 8 部分 -->

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | aarch64 空循环「665→15 ns/轮」修复后，回边守卫的 4 条指令（`mov/sub/sub/mov+cmp+b.lo`）可能已占剩余开销的主要部分，修好守卫后还会再涨 | `f_jit/src/backend/A64Lower.cj:367-373`、基线 `doc/optimize-call-path.md:411` | 守卫序列的自耗时占比 | `cjprof record` 跑空 `while(true)`（n=1e8，单线程，`-O2`），与「删掉守卫」的临时产物对照，5 轮中位数 |
| 2 | x86 端 `overflow` 只有在「违背 `maxStack` 保留区」时才非零，真实前端产物里 deopt 恒为 0，守卫是纯防御分支 | `f_jit/src/backend/X86Lower.cj:1023-1031` | 真实负载上的 `-1` deopt 次数 | 桥侧按 `ctx.errCode == -1` 计数，跑全量用例 + 3 个真实业务单元，统计命中数 |
| 3 | 装箱值型键（`Int64`/`Bool`）在 M3 `Any` 容器路径上的实际出现频率低到「塌成 `''`」不会被业务触发 | `f_jit/src/runtime/HandleTable.cj:374-383` | 装箱键调用次数与类型分布 | 在 `mapKeyOf` 的 `case Some` 分支加类型计数埋点，跑含 `Map<Any, …>` 的 M3 用例与差分集 |

<!-- 第 9 部分 -->

> 没有性能测试数据支撑的猜测，不进 `todo.md` / `tasks.md`。

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 文档记载的全量用例基线（560/560 → 859/859 → 1099/1099 → 1108/1108 → 1112/1112 → 1123/1123）在当前 HEAD 仍成立 | `f_jit/doc/spec/f-jit-m1/verify.md:7`、`:198`、`:244`、`:272`、`:284`、`:304` | 当前 HEAD 的 `cjpm test` 总数 / 通过数 / 失败数 | 融合环境（Linux，仓颉 1.3.0）`cd f_jit && cjpm test --parallel 1`，记录 TOTAL/PASSED/FAILED 并与文档对照 |
| 2 | `verify.md` 记录的 JIT 相对解释器吞吐（aarch64 43.8×、真机 x86_64 jit 2.28 ms vs interp 5.99 s）未随后续 `LOOP_BACK` H22 / 窗口池化改动漂移 | `verify.md:170`、`:158`、`:255` | 同机同 SDK 的改后中位数与离散度 | `cjpm bench -O2` 或 `PerfCompare_test`，同输入 200000 次、≥5 轮取中位数 |

<!-- 第 10 部分 -->

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | CALL_HOST 在真实业务回调密度下仍是可测开销 | `f_jit/src/runtime/HostCall.cj:62` | 端到端自耗时占比、调用频次 | `cjprof record` 跑 ≥10k 次/秒回调 10 分钟，看 `apply` 与逐参 marshal 的自耗时 |
| 2 | 签名表线性扫描在 pin 期是否成热点（条目增多后） | `f_jit/src/base/HostSignature.cj:135-190` | 条目数 × pin 频次 | 埋点 `signatureCount()` 与 pin 次数，`cjpm bench -O2` 对照 K=1/10/50 个签名 |
| 3 | `$as$<C>` 的反射父链判定在转型密集循环中的占比 | `f_jit/src/ReflectRegistrar.cj:384-390`、`:972-987` | 自耗时占比、单次耗时 | `cjprof` 跑 10^6 次下转型循环（`-O2`），对比静态可判分支 |
| 4 | 字段访问的 `accepts` 按字段表线性尝试（每次一次反射判定），表项多时可能放大 | `f_jit/src/ReflectRegistrar.cj:181`、`:544`、`:1001` | 同 index 表项数、单次 `u.f` 耗时 | 注册 K 个类（K=1/10/50）后跑 10^6 次 `u.f`，`cjpm bench -O2` 比中位数 |

<!-- 第 11 部分 -->

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 「严重」条的实际落地：负 Float64 拆箱返回 99（而非值或 22） | `f_jit/src/runtime/AnyHelpers.cj:83` 等 5 处 | 运行期异常路径是否真被 catch-all 兜成 99 | `@Assert(f.call<Float64>([-1.5]), -1.5)` 与 `any_as(any_box(-0.0))` 各一条，`cjpm test` 跑一次即定论 |
| 2 | `hasField`/`hasMethod` 线性去重在大成员类注册期占比可观 | `f_jit/src/ReflectRegistrar.cj:456-473` | 自耗时占比、成员数分布 | 注册含 200+ 成员的类 × 1000 次，`cjprof record -O2` 看两函数 self time |

<!-- 第 12 部分 -->

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 注册与在飞编译交错时，旧失败文本会在 `invalidateFailures()` 之后被重新写入（发现 #4 的可复现性） | `f_jit/src/CompilePipeline.cj:70-89`、`CompileCache.cj:98-105` | 实际命中率与窗口宽度 | 4 线程交替 `compile('{ u: LateCls => u.m(1) }')` 与 `registerClass(LateCls)`，每轮结束断言同源编译成功；跑 10 万轮统计失败次数 |
| 2 | 失败缓存 256 条的文本体积是常驻堆的一部分（优化方案 1） | `f_jit/src/CompileCache.cj:95`、`PredefinedSnapshot.cj:101-112` | 单条文本字节数、注册规模分布 | 注册 1000 函数后制造 256 条失败，读 `registeredList().size` 与 `getAllocatedHeapSize()` |
| 3 | `ipow` 的 try/catch 在溢出路径上有可观开销（优化方案 2） | `f_jit/src/runtime/PowHelper.cj:60-72` | 成功/溢出两条路径的单次耗时 | `cjpm bench -O2` 对照显式阈值实现，各 100 万次取中位数 |
| 4 | `HelperId.name(84)` 为 `unknown(84)` 在诊断转储/报告里可见 | `f_jit/src/runtime/HelperId.cj:130-221` | 是否有转储路径打印 hid 名 | 搜 `HelperId.name` 的生产调用点（当前只有测试），或对含 `**` 的单元跑一次诊断转储观察输出 |
| 5 | 三态判定在并发编译同一源码时会误报 `CompileTimeout`（发现 #6） | `f_jit/src/CompilePipeline.cj:129-141` | 误判出现频率 | 2 线程同时编译同一新源码 + 1 线程持续 `registerFunction`，统计 `CompileTimeout` 次数与真实超时次数之比 |

<!-- 第 13 部分 -->

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 回边安全点（STACK_GUARD + H22 `interrupt_poll`）在热循环里的开销可忽略 | `f_jit/doc/spec/fix-f-jit-strictfp-deadline-x86/design.md:81`（自称「约 12 条指令」）；实现 `f_jit/src/backend/X86Lower.cj:1019-1049` | 回边开销占循环体自耗时的比例；改前（无检查）与改后同输入对照 | `cjpm bench -O2` 跑「空循环 1e8 次」与「每轮 1 次整数加」两档，同机同 SDK，各 5 轮取中位数；再用 `cjprof record` 看 `X86Lower` 产物的热点分布 |
| 2 | CFG 深度预扫的 O(指令数) 一次性开销不构成 JIT 编译期退化 | `f_jit/doc/spec/fix-f-jit-x86-stack-align/design.md:115`（「预扫为 O(n) 一次性开销，波动在噪声内」）、`tasks.md:37`（只有修复后的三个数字，无改前对照） | 同一单元「修复前 vs 修复后」的 JIT 编译耗时分段计时；大函数（>2k 指令）下的绝对增量 | 对 20 个不同规模的样例单元各编译 50 次，`Instant` 分段计时 probe 遍 / 数据流 / 发射遍，报中位数与 P95 |

<!-- 第 14 部分 -->

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 「`openWindow` 每次多一次原子读，在 2971 ns/call 里是 1 ns 量级」 | `f_jit/doc/spec/fix-handle-config-race/proposal.md:34-35` | 2971 ns/call 的出处；改前/改后对照 | `cjpm bench -O2` 同机、同输入、≥10 轮取中位数与 P95，分别跑 `mut prop` 版与旧 `static var` 版 |
| 2 | 「`onAlloc`/`onFree` 多一条原子加可忽略」 | `f_jit/doc/spec/fix-native-assets-atomic/verify.md:55-56` | 单次 alloc/free 的绝对耗时与占单单元比例 | 微基准 1e6 次 alloc/free，与普通 `Int64` 自增对照 |
| 3 | 退休槽导致 `totalSlots` 单向增长，「1M × 32767 ≈ 3.4e10 次分配 / 1M QPS 约 9.3 小时」触顶 | `f_jit/doc/spec/fix-handle-gen-exhaustion/design.md:26-30` | 真实分配率、单槽复用分布、触顶后错误 16 的业务影响 | 长跑压测 ≥1 h，埋点 `slotCount()` / `retiredCount()` 斜率与 QPS 一起记录，再乘峰值推算 |
| 4 | A4 分配型基准可作收益判据 | `f_jit/doc/spec/fix-jit-unary-not/verify.md:74-83` | 稳定基线：三次数值 76 / 138 / 79（×100）离散约 1.8× | 专用机器（无共享 VM 噪声）≥10 轮，报中位数/离散度，或改短调用口径重采 |

<!-- 第 15 部分 -->

> 无性能数据支撑，均不作为缺陷，只用于下一轮补数据。

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | x86 审计「每次访存一次 TLS `get` + 结束时 `toArray`」在编译期占比可忽略（A64 注释给的是 598 次/编译、约 180 µs，x86 量级未知） | `f_jit/src/backend/X86Lower.cj:108`、`:150-154`；`BackendSelector.cj:258-280` | 单次编译的审计分配字节数与自耗时占比 | `cjprof record` 编译 1k 个单元，与临时关闭审计的空实现对照耗时与 `getAllocatedHeapSize()` |
| 2 | 逃逸闭包登记表 + 提升组随 `call<JitClosureId>` 次数无界增长（B4 声明为契约），长跑抬 RSS | `f_jit/src/JitFunction.cj:656-674`、`:359-366`、`:106` | 条目数 / `liveCount` / RSS 随调用次数的曲线 | 循环 `call<JitClosureId>` 10 万次不承接，每万次打印 `liveCount`、登记表规模与 RSS |
| 3 | 排空自旋的实际墙钟误差与 CPU 占用（发现 #2 的量化面） | `f_jit/src/JitFunction.cj:237-253`、`:309-326` | 每次 `close` 的墙钟时间、CPU 时间、自旋次数、失败率 | 1/4/16 线程并发 `close(1)` + 一个 200 ms 长调用，统计墙钟分布与线程 RUNNABLE 占比 |
| 4 | `escaped` 改 `HashMap` 的实际收益量级 | `f_jit/src/JitFunction.cj:379-388` | n = 100/1k/10k 时单次与批量 `close` 的耗时 | 按优化方案的 bench 场景采中位数与 P95/P99 |

<!-- 第 16 部分 -->

> 本部分为文档部分，未提出新的热点主张。下列三条是「文档数据不足以复核其自身结论」的补测项，**不进 `todo.md` / `tasks.md`**。

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 窗口池复用收益（601 → 236–430 ns）在同一构建机上可复现，且不会因 `Win` 复用引入抖动 | `f_jit/doc/spec/optimize-call-alloc/verify.md:9-25` | 5 次中位数与离散度 `d`；复用 vs new 的同轮配对 | 同一 commit、`-O2`、`cjpm test --filter 'CallPathBench_test*' --parallel 1` 跑 5 轮，按 `MOV = max(3%, 2d)` 重算 |
| 2 | `optimize-call-alloc2` 的「快模式 / 慢模式」由 VM 负载决定，而非代码路径差异 | `f_jit/doc/spec/optimize-call-alloc2/verify.md:5-12` | 慢模式改前基线、`uname -a` / `load average` / 是否 `taskset` | 同机同场景 5 次，逐轮记录 load 与 L1，看 2975 ↔ 5516 是否与 load 同步 |
| 3 | `RuntimeEnv.current()` 单次 TLS 成本确为 ~300 ns（`optimize-arg-staging` 否决实参暂存区的唯一硬依据） | `f_jit/doc/spec/optimize-arg-staging/design.md:18`、`verify.md:26` | 同 SDK 同机 `-O2` 下单次 TLS 的中位数与离散度 | 微基准：循环 1e7 次 `RuntimeEnv.current()`（`RuntimeEnv.cj:36-44`），5 轮取中位数；同法测 `MachineEnv.fnTableBase` getter 作对照 |

<!-- 第 17 部分 -->

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `escapeFlags` 的跨锁访问在真实负载下可复现为「已提升槽被收窗释放」 | `HandleTable.cj:1038` / `:1074` / `:1117` | 触发频率与后果形态 | 写定向压测：线程 A 循环 `openWindow→append→escape→（延迟）resetWindow`，线程 B 对同一 ID 反复 `promote`/`release`；断言 `isEscaped` 与 `liveCount` 一致；再补同类数据竞争检测工具（若工具链支持）或插桩记录「resetWindow 读到 false 但 PromotionGroup.contains==true」的次数 |
| 2 | `totalSlots` 改 `AtomicInt64` 后，`pinConst` 的常量去重扫描可能漏扫未发布段，导致同一常量重复占槽 | `HandleTable.cj:615`（`pinConst` 扫上界）、`:1202-1212`（`ensureSegLocked` → `totalSlots.store`）、`optimize-call-path-phase4/design.md:76-78` | `AtomicInt64.load/store` 的默认内存序是否 SeqCst；漏扫发生率 | 先查 SDK 实现/文档确认默认内存序（std 文档只写「默认内存排序方式」，未明确 SeqCst）；再压测：多线程并发 `pinConst` 同一字符串 + 触发段增长，统计 `slotCount` 与 `const` 槽数比值 |
| 3 | phase2 S4（2.40→2.17）与 phase4 B（2.28→2.00×）是机器噪声而非真实回退 | `optimize-call-path-phase2/verify.md:60-65`、`optimize-call-path-phase4/verify.md:63-69` | 专用 ≥8 物理核机器上的同臂复测（规则 5 至今未做） | 专用机 `taskset` 绑核，两臂各 5 次，给中位数 + 极差 + 线程 BLOCKED/WAITING 时长；与共享 VM 数据并列 |
| 4 | `optimize-compile-copy` 收口时的真实全量用例数是 1240 而非 1241（或改前基线是 1240 而非 1239） | `optimize-compile-copy/verify.md:62-63`、`optimize-compile-hotpath/verify.md:47` | 提交 `27cfc3116` 与 `8aa56b3ac` 上 `cjpm test --parallel 1` 的 `TOTAL` 行 | WSL 里 checkout 两个提交各跑一次全量，读 `TOTAL`；本轮不改代码、不跑构建 |

<!-- 第 18 部分 -->

> 没有性能测试数据支撑的猜测，**不进 `todo.md` / `tasks.md`**。

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `awaitReady` 的忙等退避在多等待者下会把 CPU 从「正在编译的线程」抢走，抵消 C1 的收益 | `f_jit/src/CompileCache.cj:143-147`（`while ((MonoTime.now() - t)… < backoffNs) {}`，无 `yield`/休眠），依据 `optimize-compile-path/verify.md:41` | 等待者数 → CPU 占用 / 编译线程推进速率的曲线；`MonoTime.now()` 单次成本 | 1 线程占住 key K 不 `finish`，起 1/4/16 个等待者，另一线程对 key X 反复 `claim+finish`；`cjprof record` 取 CPU self time 与线程状态，给 P50/P95 |
| 2 | `CompileCache.ready` 只增不减（按源码指纹键，仅 `JitFunction.close` 时 `remove`），长期运行会累积 `JitFunction` + 已 `mmap` 的机器码 | `f_jit/src/CompileCache.cj:31,81-87`；`f_jit/src/JitFunction.cj:260-263`；文档只给 `failures` 256 上限（`CompileCache.cj:95-105`） | 稳态下 `ready.size` 与 RSS 随编译次数是常数还是有斜率 | 连续编译 10⁴ 份不同源码且不 `close`，每 1 000 次采 `ready` 条数 / `getUsedHeapSize()` / RSS；对照「全部 `close`」组 |
| 3 | 4 线程编译扩展比的剩余差距（1.84× vs 本机上限 2.2–2.4×）在 GC / 分配器而非 codegen 共享状态 | `f_jit/doc/spec/optimize-compile-path/verify.md:74-75` | 编译期 GC 次数、分配量、线程状态（RUNNABLE/BLOCKED 占比） | 专用机（构建机无 `perf` / `strace`）：`cjprof record` 跑「4 线程 × 6 段不同源码」稳态 + 线程状态采样；对照 `JitMode.Off` 的 2.68–3.71× |
| 4 | 降低期直读操作数省下的 250 次小数组分配是否可测（verify 判为噪声内） | `f_jit/doc/spec/optimize-decode-alloc/verify.md:7-15` | `getAllocatedHeapSize()` 前后差、GC 次数差 | 同进程 A/B 各 21 次编译，读 `getAllocatedHeapSize()` 与 GC 次数（±40% 墙钟波动下墙钟无分辨率） |

<!-- 第 19 部分 -->

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 编译段（25–48 ms）仍占端到端大头，且未定位到具体阶段 | `f_jit/doc/spec/optimize-marshal-rs/verify.md:70` | 前端扫描 / AST 分配 / 降低 / 发射各段自耗时占比 | 对 `JitFunction` 首次编译路径分段计时或 `cjprof record`，输入 200 个不同源码单元，取 5 次中位数；与同机 `L1` 对照 |
| 2 | x86 回边「按需 poll」只在字节层验证过，实机收益与语义均未测 | `f_jit/doc/spec/optimize-loop-safepoint/verify.md:53` | x86_64 实机的空循环 ns/轮与有期限中断行为 | x86_64 机器上跑 `LoopSafepoint_test`（3 条）与 `X86Lower_test.loopBackPollGate`，`-O2`、`taskset` 绑核，记录改前/改后每轮 ns 与 `InterruptedException` 命中 |
| 3 | 各组记录的全量用例数（1214 / 1221 / 1224 / 1235 / 1246）与仓内 `@TestCase` 计数对不上（`057097229` 时 1259、HEAD 1278），疑为计数口径差异而非数据错误 | `optimize-helper-table/verify.md:43`、`optimize-loop-safepoint/verify.md:45`、`optimize-signature-tables/verify.md:53`、`optimize-runtime-tls/verify.md:46`、`optimize-marshal-rs/verify.md:46` | `cjpm test` 的计数口径（是否含 `@Disabled` / 是否按 `@Test` 类聚合 / 是否只统计被编译目标） | 同 SDK 跑一次 `cjpm test --parallel 1`，把报告 total 与 `grep -c '@TestCase'` 逐文件对齐，差值定位到具体类；确认后在各 verify 注明口径 |

<!-- 第 20 部分 -->

> 没有性能测试数据支撑的猜测。**不进 `todo.md` / `tasks.md`**，只用于下一轮补数据。

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 若 `AdapterRegistry.lookup` 接到 `call` 第 5 步，全局 `Mutex` + 字符串键会成为并发调用的串行段 | `f_jit/src/AdapterRegistry.cj:50-55` | 临界区持有时间、锁等待占比、并行度上限 | 接线后 `cjprof record` 跑 4 线程 × 50k 次 `call<注册类>`，另取线程状态（BLOCKED 时长）；CPU profile 看不到锁竞争，需线程状态证据 |
| 2 | `HandleTable.resetForTest()` 在 `--parallel > 1` 下会让并行用例互相干扰（假失败/假通过） | `f_jit/src/AnyHostCast_test.cj:100`、`f_jit/src/runtime/HandleTable.cj:1276-1307` | 并行度 > 1 时的失败率 | `cjpm test --parallel 4` 连续 20 轮，统计 `AnyHostCast_test` / 依赖句柄的用例失败次数 |
| 3 | `AdapterRegistry.register` 的重复登记在真实接线后会造成条目数随重编线性增长 | `f_jit/src/AdapterRegistry.cj:40` | 同一 `(fp, fnId, tName)` 的实际重复登记次数 | 接线后加计数埋点，跑「编译 → 卸载 → 同源重编」100 轮，观察 `units` 元素数与 `size()` |

<!-- 第 21 部分 -->

> 没有性能测试数据支撑的猜测，**不进 `todo.md` / `tasks.md`**。

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 封送/解包的类型码 `if` 链是短调用路径的主要自耗时之一 | `f_jit/src/CallMarshal.cj:80-155`、`:198-230` | 该函数 self time 占比、每参平均比较次数 | `cjprof record` 跑 `CallPathBench_test` B1（150k 次、4 线程 3 轮），看 `marshalArg`/`unboxRet` 占比 |
| 2 | `awaitReady` 自旋在多等待者场景下吃掉整核，且放大同键编译的总墙钟 | `f_jit/src/CompileCache.cj:143-147` | 等待线程 CPU%、唤醒延迟分布 | 8 线程同键 `compile`，`cjprof` + 线程状态（RUNNABLE 占比） |
| 3 | `ready` 缓存随源码多样性线性增长，单条约 10–50 KB | `f_jit/src/CompileCache.cj:32`、`f_jit/src/CompilePipeline.cj:246-255` | 1k/5k/10k 份不同源码后的 heapUsed 增量、单条实测占用 | 循环 `compile` 不同源码，采样 `getAllocatedHeapSize()` / RSS（需 WSL 侧跑） |
| 4 | `promoteClosureGraph` 的 `visited.contains` 使深闭包链退化为 O(n²) | `f_jit/src/CallMarshal.cj:288-309` | 链长 1k/5k/10k 时的耗时曲线 | 构造嵌套闭包源码，`call` 返回闭包并计时（`cjpm bench -O2`） |
| 5 | `Compiler.snapshot` 的 O(A·F) 去重与全量拷贝在 F 大时占比显著（注释称 11.6% / 41.5%） | `f_jit/src/Compiler.cj:39-42`、`:196-219` | 复核占比与 4 线程放大倍数 | `cjprof`，F=200 与 F=1000 两组，单线程与 4 线程各 3 轮取中位数 |

**范围外提示**：`f_jit/src/JitFunction.cj:240-256` 的 `close` 也用「`spins` 上限 + 纯自旋」等 drain，与 `awaitReady` 同族；它不在本部分文件清单内，仅提示合并时可能需统一改。

<!-- 第 22 部分 -->

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `acceptsInterface` 在每次「接口类型实参」封送时做 1 次 `AtomicReference.load` + 1 次 `HashMap.get`，可能是封送固定开销的组成部分；若实参封送本身只有几百 ns，这里占比可观 | `f_jit/src/JitBindSupport.cj:147-153` | 自耗时占比、调用频次（每脚本调用几次） | `cjprof record` 跑 10 万次含接口形参的脚本调用（`-O2`），看 `acceptsInterface` self time 占比；同时计数调用次数 |
| 2 | 每次 `enrollOf` 复制整张已登记表（写时复制），N 个 `@JitBind` 类启动期为 O(N²) 次插入；类多时启动耗时可能可见 | `f_jit/src/JitBindSupport.cj:114-122` | 启动期登记总耗时随 N 的变化曲线 | 用 100 / 500 / 1000 个 `@JitBind` 类各跑一次包初始化，分段计时取中位数（`-O2`，同机） |
| 3 | `ConcurrencyMatrix_test.gate` 在低核 CI 上把并发窗口压缩，降低竞态复现率，同时吃掉整段 CPU | `f_jit/src/ConcurrencyMatrix_test.cj:52-58` | 实际交错次数 / 变异命中率 | 2 核与 8 核各跑 100 轮，统计「变异版（故意破坏去重）被检出」的比例与单次耗时 |

<!-- 第 23 部分 -->

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `close(timeoutMs)` 的自旋实际墙钟远超 `timeoutMs`（慢机/高竞争下放大数倍到数十倍） | `f_jit/src/JitFunction.cj:237-253` | 自旋 1e5 次的墙钟耗时、不同 `timeoutMs` 下的实际返回时间 | 注入一个长期在飞调用（`HOST_SRC` + 阻塞回调），测 `close(1/10/100/1000)` 的实际等待时间与 CPU 占用 |
| 2 | `call<T>` 每次调用的 `CallMarshal` + cells 分配是可观测的 GC 压力来源 | `f_jit/src/JitFunction.cj:595-621` | 每秒分配字节数、GC 次数、与调用次数的比例 | 1e6 次 `call<Int64>([n])`，`cjprof heap` + `getAllocatedHeapSize()` 前后差 |
| 3 | `PerfAdapter_test` 的 3× 门禁在共享构建机上会偶发假失败 | `f_jit/src/PerfAdapter_test.cj:102-105` | 同一提交多轮 MR 的 ratio 分布 | 连续跑 20 轮，记录 `applied/typed` 比值的最小值/中位数/P95 |
| 4 | 编译缓存命中已卸载单元的窗口在「编译+卸载」交替负载下可观测 | `f_jit/src/JitFunction.cj:256-265` | 命中旧单元导致 19 的频次 | 两线程循环 `compile(同源)` 与 `close()`，统计 `call` 返回 19 的次数（应接近 0） |

<!-- 第 24 部分 -->

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `HostFieldTable.find` 的线性 `accepts` 扫描在字段访问热路径上占比可观（登记类越多，单次字段读越慢） | `f_jit/src/runtime/HostField.cj:121-133`（范围外文件，由本部分 `pending` 的登记密度驱动） | 自耗时占比、bucket 长度分布 | 注册 20/50/100 个类后，各跑 1e6 次 H64，`cjprof record` 看 `hostGetField`/`accepts` 自耗时；同时打印各 index 的 bucket 长度 |
| 2 | `Compiler.registerType` 的锁内反射枚举是启动期串行尖峰 | `f_jit/src/Compiler.cj:137-142` + `f_jit/src/ReflectRegistrar.cj:96-392` | 单类注册耗时、锁等待时长 | 对「100 类 × 20 字段」宿主分段计时（`MonoTime` 包住 registerType），4 线程并发注册，采集线程 BLOCKED 时长 |
| 3 | `PerfOverride_test` 的 800/1000 门禁在 CI 上假红频率偏高 | `f_jit/src/PerfOverride_test.cj:110-155` | 历史失败率、失败时的三轮原始比值 | 在 CI 里保留每次 `PERF-OVERRIDE round*` 打印，统计 100 次运行的 `medianRatioX1000` 分布（P50/P95/min） |

<!-- 第 25 部分 -->

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 每指令一次 `'L${off}'` 插值是编译期 CPU/GC 的可见成本 | `A64Lower.cj:94`、`A64Emitter.cj:54/82-88` | `bind` 自耗时占比、每秒分配字节数 | `cjprof record` 编译同一 2411 条指令单元 100 次，取 self time；`cjprof heap` 看 `String` 分配 |
| 2 | `helperDispatch` 地址物化占机器码体积的可观比例 | `A64Lower.cj:530/561/595/655` | 每次编译的 `movz/movk` 条数与总字数比 | 在 `word()` 里按 opcode 分类计数，跑 10 个真实单元统计中位数 |
| 3 | `A64Emitter.audit` 的 `ArrayList` 扩容是编译期堆峰值的一部分 | `A64Emitter.cj:460-472` | 单次编译的峰值分配与 `audit` 占比 | 编译前后 `getAllocatedHeapSize()` 差值 + 关闭审计（改 `noteMemBase` 为 no-op）对照 |
| 4 | A64 `resolve` 的 `String` 标签查表在高分支密度单元上变成热点 | `A64Emitter.cj:131-163` | `resolve` 自耗时占比 | 对含大量 `if/while` 的单元跑 `cjprof`，与 `optimize-emit-fixup` 记录的 78-92% 对比 |
| 5 | `BackendX86_64.compile` 的逐字节 `out.add` + `toArray` 双拷贝（若该路径被接线） | `BackendSelector.cj:89-104` | 该路径启用后的编译耗时 | 接线后用 `cjpm bench` 对照 `JitCompiler.compileUnitWith` 的数组下标写入（`JitCompiler.cj:101-112`） |

<!-- 第 26 部分 -->

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `X86Lower.lower` 的「探针遍 + CFG 数据流 + 发射遍」使单函数编译成本约为 A64 的 2–3 倍（每指令一次 `translate` + 一次 `HashMap` 读写 + 一次 `InsnDecoder.decode` 分配） | `X86Lower.cj:105-155`、`X86Depth.cj:91` | 编译期自耗时占比、单函数耗时分布 | `cjprof record` 跑「编译 10k 次同一单元」（`CompilePipeline` warm cache 关掉），看 `lower`/`analyze`/`decode` 的 self time；与 `A64Compiler.compileFunctionWith` 同输入对照 |
| 2 | `invokeOff` 的 malloc/free 在短函数调用中占端到端 10% 以上 | `JitExecutor.cj:153-177` | 每次调用耗时分解 | 分段计时（进入 `invokeOff` 前后 / malloc 前后）跑 1e7 次 `call<Int64>([x])`，取中位数；或 `cjprof` 看 `malloc`/`free` 符号占比 |
| 3 | helper 调用点的双 `CHECK_ERR` 使 helper 密集函数的机器码体积增加 5–10%，并对 I-Cache 有可测影响 | `X86Lower.cj:432-434` | 机器码体积统计 + 吞吐对照 | 统计 `LEN`/`TO_STR`/`STR_CAT` 密集单元在改前/改后的 `art.code.size`，再跑 `cjpm bench -O2` 对照中位数 |

<!-- 第 27 部分 -->

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 注释引用「拼键 790 ns vs 线性扫 349 ns」是注册/查表路径的真实量级，且在本机 SDK 上仍成立 | `f_jit/src/base/HostSignature.cj:107-110` | 测量环境、输入规模、轮数、离散度均未归档 | 对 `SignatureRegistry.find` 跑 `cjpm bench -O2`，表规模 1/4/8/16 条目，各 10 万次取中位数 |
| 2 | `withOverrides` 的 clone-per-override 是启动期堆分配的可观测来源 | `f_jit/src/base/JitBindings.cj:137-218` | 注册期分配量与峰值 | 注册 1000 类场景下 `getAllocatedHeapSize()` 分段计时 + `cjprof heap` |
| 3 | `JitBindings.union` 的 `ArrayList.contains`（`JitBindings.cj:130`）在忽略名单较大时退化为 O(k²) | `f_jit/src/base/JitBindings.cj:121-135` | k 的实际分布与单次耗时 | 埋点统计 `ignored` 条数分布；k=1/10/100/1000 各跑 1 万次 |
| 4 | `cjpm test --parallel=true` 下 `SignatureRegistry.resetForTest` 会与 `HostClosureAdapter_test` 互相清表 | `f_jit/src/base/HostSignature.cj:196` | 并行执行下的失败率 | 以 `--parallel=true` 连跑 20 轮 `cjpm test`，统计 flaky 用例（当前 `f_jit/cjpm.toml` 未开并行，默认串行不受影响） |

<!-- 第 28 部分 -->

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `CanonKey.decFromText` 是 `Map<Decimal,_>` 读写路径的主要自耗时来源 | `f_jit/src/bytecode/CanonKey.cj:107` | 自耗时占比、每次分配量 | `cjprof record` 跑 10 万次 Decimal 键查找，看该函数 self time 与分配 |
| 2 | `tokenOf` 的 O(n²) 拼接在大 List 键常量上是真实瓶颈 | `f_jit/src/bytecode/ConstRegistry.cj:185` | 单次实例化耗时随 n 的曲线 | 构造 n=10/100/1000 的 List 键常量，分段计时取中位数 |
| 3 | `checkCrc32` 的整段复制显著抬高 `load` 峰值 RSS | `f_jit/src/bytecode/FbcReader.cj:232` | 峰值 RSS 对照（有/无该副本） | 10 MB `.fbc` × 100 次 load，`getAllocatedHeapSize()` + RSS 采样 |
| 4 | 三趟指令扫描占 `load` 端到端时间的可观比例 | `f_jit/src/bytecode/FbcReader.cj:270/320/395` | 三趟各自占比 | `cjprof record` 跑 1 MB code 段 load × 1000 |
| 5 | 超长 `PDec` 系数（如 1 MB 数字串）经 `BigInt.parse` 会产生超线性耗时/内存 | `f_jit/src/bytecode/ConstRegistry.cj:419` | parse 耗时与峰值内存 | 构造 1 KB/100 KB/1 MB 系数载荷，计时 + 内存采样 |
| 6 | 常量 DAG 深链在多深时触发栈溢出（决定 §4 的阈值取值） | `f_jit/src/bytecode/ConstRegistry.cj:146/178` | 每帧大小与实际崩溃深度 | 构造 1k/10k/100k 层嵌套常量段，跑 `load` 观察崩溃点 |

<!-- 第 29 部分 -->

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 加载期热点在「两次全函数体解码 + 每指令分配」，而非段拷贝 | `FbcReader.cj:270`、`:320`；`InsnDecoder.cj:71` | `decode` 自耗时占比、GC 次数 | `cjprof record` 加载 10 万指令合成单元，对比 1 万指令 |
| 2 | `NameTable.validate` 的 O(名字数×函数数) 在真实单元已达毫秒级 | `NameTable.cj:192-197` | 加载耗时随规模曲线 | 1k/10k/100k 函数 + 每函数 5 个命名槽的合成单元，分段计时 |
| 3 | `FbcWriter.build` 的 2× 载荷峰值在大单元上可测 | `FbcWriter.cj:98-145` | 峰值 RSS / heapUsed 与载荷大小的关系 | 1 MB / 10 MB 产物，`getAllocatedHeapSize()` 前后差 + RSS |
| 4 | `normalizeSource` 的 ArrayList 扩容是编译期分配大头之一 | `Fingerprint.cj:92-107` | 该函数分配量与总分配占比 | 1 MB 源码 bench + `cjprof heap` |
| 5 | `OpInfo` 的 `Array<struct>`（含 `String` 字段）在解码循环里是否有缓存不友好 | `OpInfo.cj:119`；`InsnDecoder.cj:60` | cache miss / 自耗时占比 | 平台 profiler 跑 1e7 次 `decode` |
| 6 | `Crc32` 是否支持分段 update（决定 O1 能否做到 1× 峰值） | `FbcWriter.cj:89`、`:131` | `f_util.Crc32` 的 API 能力 | 查 `f_util` 源码/文档，确认有无 `update`/`final` |

<!-- 第 30 部分 -->

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `nargsOf` 的二次复杂度在真实单元上是否可测（函数数多大才显现） | `Assembler.cj:322` | 编译耗时占比、函数数分布 | 对 10 / 100 / 1000 函数的单元各跑 30 轮 `cjpm bench -O2`，取中位数 |
| 2 | `assemble()` 期 2× code 副本是否构成峰值内存可观项 | `Assembler.cj:79`、`:114` | 峰值 `getUsedHeapSize`/RSS、code 段占比 | 用 1 MB code 段单元做单次编译，分段记录分配量 |
| 3 | 终结语之后若出现死代码，`place()` 是否会误报「分支汇合栈深不等」 | `BytecodeBuilder.cj:241` | 是否存在触发输入（需逐个 Lowerer 分支排查） | 构造 `if (c) { return x }` 变体并检查产物，或在 `place` 加临时计数埋点跑全量用例 |

<!-- 第 31 部分 -->

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `DefiniteAssignment` 的分支整表克隆（`clone`/`intersectInto`/`snapshotKeys`，每次 `if`/循环迭代分配一个 `HashMap` + 数组）是编译期分配热点 | `f_jit/src/compiler/DefiniteAssignment.cj:131-191`、`:527-568` | 该阶段自耗时占比与分配量 | `cjprof record` 编译 100 个含分支/循环的 lambda，看 `DefiniteAssignment.*` 的 self time；同时统计 `getAllocatedHeapSize()` 增量 |
| 2 | 4 次换行规范化的耗时在编译总耗时中占比 <5%（即上条方案收益有限） | `Lexer.cj:123`、`SourceCompiler.cj:115`、`Parser.cj:51`、`PredefinedSnapshot.cj:141`、`DefiniteAssignment.cj:51` | 分段计时 | 在 5 个调用点插桩累计耗时，跑 1MB 源码 20 轮取中位数 |
| 3 | DA 的 `HashMap<String,Bool>` 字符串键哈希/比较是长函数分析的主要成本（可换 `Int64` 槽位索引） | `DefiniteAssignment.cj:67-70`、`:205-218` | 单次 `analyze` 耗时随局部变量数的增长曲线 | 构造 100/1000 个局部变量的 lambda，`cjprof` 看 `state.get`/`hash` 占比 |
| 4 | 上述 DA 临时结构适合 local mode（`state`、分支克隆、`snapshotKeys` 数组均在函数内创建并随 `analyze` 返回销毁，无逃逸） | `DefiniteAssignment.cj:66-77` | 峰值内存对照 + `--enable-local-mode` 可用性 | 先确认 `std.collection.HashMap` 有 local 构造重载；再测 `getAllocatedLocalObjectSize()` 与 RSS 峰值（需 `-O2`、同输入） |

<!-- 第 32 部分 -->

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `flushNames` 的复制 + 插入排序在大单元上是编译耗时热点 | `Lowerer.cj:186-211` | 该函数自耗时占比、n（声明数）分布 | 生成 5k/20k 声明源，`cjprof record` 后看 `flushNames` self time；同时统计 `pendingNames.size` |
| 2 | 深嵌套表达式（≥1k 层括号/成员链）会让 `scanExpr` / `staticTypeFull` / `hostObjectClassOf` 递归爆栈 | `Lowerer.cj:3355-3446`、`:3646-3820` | 触发深度与栈大小 | 用脚本生成 `((((1))))` 与 `a.b.c.…` 两种深链各 500/2000/5000 层，跑 `SourceCompiler.compile` 记录首次崩溃深度；同时确认 `Parser` 的崩溃深度（决定上限归属） |
| 3 | `lowerExpr` 每个节点都重置 `last*` 三字段，深层链上反复覆盖有可观开销 | `Lowerer.cj:1013-1016` | 该赋值的自耗时 | `cjprof` 跑 10k 表达式单元，看 `lowerExpr` 头部占比（预计 < 1%，若成立则不做） |
| 4 | 常量/键去重路径（`consts.addStr` 在每次 JSON 点号读写都调用）存在重复登记 | `Lowerer.cj:1913`、`:1977` | `ConstRegistry` 条目数 vs 源内唯一字面量数 | 编译一个含 500 次 `j.k` 的单元，dump 常量表统计重复项 |

<!-- 第 33 部分 -->

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 词法/语法解析在端到端编译中的耗时占比可能是最大单项 | `f_jit/src/compiler/Parser.cj:157`、`Lexer.cj:101` | 自耗时占比 + 调用路径 | `cjprof record` 跑 5k 次 `Compiler.compile`（同一 10 KB 源码），看 `tokenize`/`parseLambda` 的 self time |
| 2 | `parseDigits` 溢出在仓颉侧是抛 `OverflowException` 还是回绕 | `f_jit/src/compiler/Parser.cj:1139` | 实际异常类型 | 单测里编译 `'{ => re/s/r/99999999999999999999 }'`，捕获后打印异常类型（不修源码，仅在临时用例里观察） |
| 3 | 深嵌套括号的栈溢出阈值（决定 #5 的实际风险） | `f_jit/src/compiler/Parser.cj:1181` | 不同 N 下是否 abort + 崩溃层数 | 二分 N（1k/4k/16k 层括号）逐次 `compile`，观察进程退出码与栈深 |
| 4 | 4 次 `normalizeNewlines` 在编译总分配中的占比 | `SourceCompiler.cj:115` 等 4 处 | 分配量拆分 | 用 10 KB / 100 KB 两档源码各跑 1k 次 `compile`，对比 `getAllocatedHeapSize()` 增量与重复次数 |
| 5 | `PredefinedSnapshot.slotOf` 线性扫描在注册数大时会成为编译热点 | `f_jit/src/compiler/PredefinedSnapshot.cj:65` | 注册数 n 与编译耗时的关系曲线 | 参数化 n ∈ {10, 100, 1000}，每档编译同一含 500 个调用点的源码，取中位数 |

> 以上均无改前/改后对照数据，不进 `todo.md` / `tasks.md`。

<!-- 第 34 部分 -->

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `report` 的字符串累加在 `nLocals` 大时成为可观开销 | `f_jit/src/runtime/DbgDump.cj:174-181`、`:233-244` | 单次耗时随 `nLocals` 的增长曲线 | 构造 8/32/128/512 槽的帧，跑 1e4 次 `report`，记中位数 |
| 2 | `anyAs` 每次命中都新登记 1 槽，高频 `as` 会先撞窗口（128）而非 CPU | `f_jit/src/runtime/AnyHelpers.cj:92-108` | 真实脚本里 `as` 的调用频次与窗口占用水位 | `WindowPool_test`/`AnyHostCast_test` 加计数埋点，跑典型脚本 10 分钟 |
| 3 | `@JitBind` 生成的「args 数组 → 逐参 match → 静态调用」在成员访问热点上仍有可观开销（相对直接反射路径的收益未量化） | `f_jit/src/macros/JitBind.cj:262-280` | 绑定调用 vs 反射调用的 ns/op | `PerfM2_test` / `CallPathBench_test` 同输入 `cjpm bench -O2` 对照 |

> 以上三条均无可复核基线，不计入模块统计，不进 `todo.md` / `tasks.md`。

<!-- 第 35 部分 -->

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `popFreeWith` 最坏要依次探 64 个分片锁（每片一次 `synchronized`），空闲表偏空时分配路径的锁开销显著 | `HandleTable.cj:1179-1199` | 单次分配的自耗时占比、锁等待时长 | `cjprof record` 跑「多线程高 churn」场景（4 线程 × 20k 轮，已有用例可复用），看 `popFreeWith`/`Mutex.lock` 占比 |
| 2 | `hsLen`/`hsAt`/`strSub` 每次 `toRuneArray()` 全串物化，长串上长度/取字符变成 O(n) 且每次一个新数组 | `Helpers.cj:213-226、465-481` | 长串（≥ 64 KB）下的自耗时与分配量 | 分段计时：1 MB 串上 `hs_len` 1e5 次；`getAllocatedHeapSize()` 前后差 |
| 3 | `pinConst` 在 `mtx` 内线性扫 `1..totalSlots`，常量多的单元（数千常量）装载期退化为 O(n²) | `HandleTable.cj:611-630` | 常量个数 × 单次扫描耗时 | 造 5k 常量单元，计时 `pinConst` 总耗时；同时记录 `totalSlots` |
| 4 | `replaceSpans` 的 10 倍输入放大在真实负载（日志/模板替换）上先于 GC 触发 OOM | `Helpers.cj:959-1005` | 输入规模与 RSS 峰值 | 100 MB 串 + `a` 模式跑 `regex_replace_all`，采 RSS 峰值与耗时段 |
| 5 | 每个 helper 一次 `Array<Int64>` 分配是 GC 压力的主要来源之一 | `HelperEntry.cj:33-44` | 分配速率、GC 次数与停顿 | `cjprof heap` 跑 `PerfM2_test` 的 helper 密集循环，统计分配点排名 |
| 6 | `HelperId.isFixed` 的字符串拼接只在测试/编译期使用，未进运行期热路径（若进则每次一个 String 分配） | `HelperId.cj:222-226` | 生产调用次数 | 全仓确认无生产调用（本轮已确认仅 `Ops.cj:218` 注释与测试），若后续接入编译期校验则不成立 |

<!-- 第 36 部分 -->

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 字段访问 `HostFieldTable.find` 的闭包调用是热点 | `f_jit/src/runtime/HostField.cj:121-133` | `find` 自耗时占比、桶长分布 | `cjprof record` 跑字段读写密集负载（每类 ≥3 字段、1000 万次访问），看 self time 与调用次数 |
| 2 | 注释器每帧分配是 GC 主要来源 | `f_jit/src/runtime/Interp.cj:37-45`、`:667-675` | 每万次调用的分配字节数、GC 次数 | `cjprof heap` + `getAllocatedHeapSize()` 前后差，跑 10 万次解释执行 |
| 3 | Map 迭代窗口槽峰值按 2n 线性增长并在大 Map 触发 16 | `f_jit/src/runtime/IterTable.cj:202-211` | `capacityLimit` 下的实际 n 阈值 | 构造 `Map<String,String>`，n 从 1k 到 100k 迭代，记录 `windowUsed()` 与是否出现 16 |
| 4 | 解释器深递归的可达深度显著低于机器码 | `f_jit/src/runtime/Interp.cj:201-263` | 崩溃深度、每层栈字节 | 递归函数逐级增大深度（1k→100k），对比 JIT / Off 两种模式的崩溃点与栈占用 |

<!-- 第 37 部分 -->

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 提升组 `add` 在锁内取全局 `HandleTable.mtx`（`moveOutGroup`），4 线程并发返回闭包时成为串行段 | `f_jit/src/runtime/PromotionGroup.cj:69`、`f_jit/src/runtime/HandleTable.cj:1107-1112` | 锁等待时长、实际并行度 | 4 线程各 10k 次「返回含 4 捕获的闭包」压测，采线程状态（BLOCKED/WAITING 占比）与吞吐；锁竞争在 CPU profile 里看不到 |
| 2 | `interrupt_poll` 每次轮询读两次 TLS（`deadlineNanos` getter 各一次） | `f_jit/src/runtime/RuntimeEnv.cj:89-95` | 每次 poll 的耗时与调用频次 | 在 `LOOP_BACK` 密集循环上跑 `cjpm bench`，对比「读一次到局部变量」的改后版本；同时给 TLS 访问次数埋点 |
| 3 | f64 文本化（BigInt 展开 + 逐位缩短）在「大量数值插值」负载里占比可观 | `f_jit/src/runtime/TextFormat.cj:69-105` | 自耗时占比 | `cjprof record` 跑 10 万次 `to_str(f64)`，取 `shortestDigits`/`roundToSignificant` 的 self time |

<!-- 第 38 部分 -->

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `pinConst` 的全表线性扫描 + 全局锁成为差分套件的隐性瓶颈（每用例每常量 O(表槽数)） | `f_jit/src/test/diff/RealRunners.cj:79-84`（调用方）/ `f_jit/src/runtime/HandleTable.cj:611-629`（实现） | `pinConst` 自耗时占比、调用次数、表槽数随用例数增长曲线 | `cjprof record` 跑 `cjpm test` 全量差分；另加埋点记录每次 `pinConst` 前的 `totalSlots` 与耗时，跑 100/500/1000 个用例对比 |
| 2 | 每个 `DiffCase` 的 `FbcReader.load + compileUnitWith + CodeBuffer.alloc` 占套件总耗时的主要部分 | `RealRunners.cj:51-106`、`:162-191`、`:246-275` | 编译阶段耗时占比（对比解释执行阶段） | 分段计时：在 `run()` 内打 `load` / `compile` / `invoke` / `report` 四个时间戳，跑 200 个用例取中位数 |
| 3 | 每用例的 `LibC.malloc/free`（args + dump + mirror + table + ctx）在长套件里表现为分配抖动而非泄漏 | `RealRunners.cj:123`、`:126`、`:138`、`:208`、`:211`、`:223` | `NativeAssets.liveCount()` 与 `NativeMem` 计数在套件结束时的稳态 | 套件前后打印 `NativeAssets.liveCount()`；若不为 0 则按「发现」#2/#3 的路径定位 |

## 文件覆盖

> 与 `files/f_jit.txt` 一一对应；分部分报告逐文件确认已读。

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_jit/README.md` | .md | ✅ | — |
| 2 | `f_jit/README_en.md` | .md | ✅ | — |
| 3 | `f_jit/doc/asm-inline.md` | .md | ✅ | — |
| 4 | `f_jit/doc/concurrency-audit.md` | .md | ✅ | — |
| 5 | `f_jit/doc/design-m1.md` | .md | ✅ | — |
| 6 | `f_jit/doc/design-m2.md` | .md | ✅ | — |
| 7 | `f_jit/doc/design-m3.md` | .md | ✅ | — |
| 8 | `f_jit/doc/design-parallel-call.md` | .md | ✅ | — |
| 9 | `f_jit/doc/jit-bytecode-m1.md` | .md | ✅ | — |
| 10 | `f_jit/doc/jit-bytecode-m2.md` | .md | ✅ | — |
| 11 | `f_jit/doc/jit-bytecode-m3.md` | .md | ✅ | — |
| 12 | `f_jit/doc/optimize-call-path.md` | .md | ✅ | — |
| 13 | `f_jit/doc/optimize-compile-path.md` | .md | ✅ | — |
| 14 | `f_jit/doc/perf-m1.md` | .md | ✅ | — |
| 15 | `f_jit/doc/perf-m2.md` | .md | ✅ | — |
| 16 | `f_jit/doc/plan-m1.md` | .md | ✅ | — |
| 17 | `f_jit/doc/plan-m2.md` | .md | ✅ | — |
| 18 | `f_jit/doc/plan-m3.md` | .md | ✅ | — |
| 19 | `f_jit/doc/spec/add-concurrency-matrix-tests/proposal.md` | .md | ✅ | — |
| 20 | `f_jit/doc/spec/add-concurrency-matrix-tests/tasks.md` | .md | ✅ | — |
| 21 | `f_jit/doc/spec/add-concurrency-matrix-tests/verify.md` | .md | ✅ | — |
| 22 | `f_jit/doc/spec/align-base-contracts-callcontext/design.md` | .md | ✅ | — |
| 23 | `f_jit/doc/spec/align-base-contracts-callcontext/proposal.md` | .md | ✅ | — |
| 24 | `f_jit/doc/spec/align-base-contracts-callcontext/specs/f-jit-base-contracts/spec.md` | .md | ✅ | — |
| 25 | `f_jit/doc/spec/align-base-contracts-callcontext/tasks.md` | .md | ✅ | — |
| 26 | `f_jit/doc/spec/align-base-contracts-callcontext/test-plan.md` | .md | ✅ | — |
| 27 | `f_jit/doc/spec/align-base-contracts-callcontext/verify.md` | .md | ✅ | — |
| 28 | `f_jit/doc/spec/align-call-entry-spec/design.md` | .md | ✅ | — |
| 29 | `f_jit/doc/spec/align-call-entry-spec/proposal.md` | .md | ✅ | — |
| 30 | `f_jit/doc/spec/align-call-entry-spec/specs/f-jit-facade-bridge/spec.md` | .md | ✅ | — |
| 31 | `f_jit/doc/spec/align-call-entry-spec/tasks.md` | .md | ✅ | — |
| 32 | `f_jit/doc/spec/align-call-entry-spec/test-plan.md` | .md | ✅ | — |
| 33 | `f_jit/doc/spec/align-call-entry-spec/verify.md` | .md | ✅ | — |
| 34 | `f_jit/doc/spec/align-jitfunction-close-naming/design.md` | .md | ✅ | — |
| 35 | `f_jit/doc/spec/align-jitfunction-close-naming/proposal.md` | .md | ✅ | — |
| 36 | `f_jit/doc/spec/align-jitfunction-close-naming/specs/f-jit-facade-bridge/spec.md` | .md | ✅ | — |
| 37 | `f_jit/doc/spec/align-jitfunction-close-naming/tasks.md` | .md | ✅ | — |
| 38 | `f_jit/doc/spec/align-jitfunction-close-naming/verify.md` | .md | ✅ | — |
| 39 | `f_jit/doc/spec/align-x86-loop-back-stack-guard/design.md` | .md | ✅ | — |
| 40 | `f_jit/doc/spec/align-x86-loop-back-stack-guard/proposal.md` | .md | ✅ | — |
| 41 | `f_jit/doc/spec/align-x86-loop-back-stack-guard/specs/f-jit-backend/spec.md` | .md | ✅ | — |
| 42 | `f_jit/doc/spec/align-x86-loop-back-stack-guard/tasks.md` | .md | ✅ | — |
| 43 | `f_jit/doc/spec/clarify-last-escaped-scope/proposal.md` | .md | ✅ | — |
| 44 | `f_jit/doc/spec/clarify-last-escaped-scope/tasks.md` | .md | ✅ | — |
| 45 | `f_jit/doc/spec/clarify-last-escaped-scope/verify.md` | .md | ✅ | — |
| 46 | `f_jit/doc/spec/close-f-jit-out-of-checklist-findings/design.md` | .md | ✅ | — |
| 47 | `f_jit/doc/spec/close-f-jit-out-of-checklist-findings/proposal.md` | .md | ✅ | — |
| 48 | `f_jit/doc/spec/close-f-jit-out-of-checklist-findings/specs/f-jit-bytecode-format/spec.md` | .md | ✅ | — |
| 49 | `f_jit/doc/spec/close-f-jit-out-of-checklist-findings/specs/f-jit-compiler-frontend/spec.md` | .md | ✅ | — |
| 50 | `f_jit/doc/spec/close-f-jit-out-of-checklist-findings/specs/f-jit-differential-acceptance/spec.md` | .md | ✅ | — |
| 51 | `f_jit/doc/spec/close-f-jit-out-of-checklist-findings/specs/f-jit-facade-bridge/spec.md` | .md | ✅ | — |
| 52 | `f_jit/doc/spec/close-f-jit-out-of-checklist-findings/tasks.md` | .md | ✅ | — |
| 53 | `f_jit/doc/spec/close-f-jit-out-of-checklist-findings/test-plan.md` | .md | ✅ | — |
| 54 | `f_jit/doc/spec/close-f-jit-out-of-checklist-findings/verify.md` | .md | ✅ | — |
| 55 | `f_jit/doc/spec/f-jit-m1/design.md` | .md | ✅ | — |
| 56 | `f_jit/doc/spec/f-jit-m1/proposal.md` | .md | ✅ | — |
| 57 | `f_jit/doc/spec/f-jit-m1/specs/f-jit-backend/spec.md` | .md | ✅ | — |
| 58 | `f_jit/doc/spec/f-jit-m1/specs/f-jit-base-contracts/spec.md` | .md | ✅ | — |
| 59 | `f_jit/doc/spec/f-jit-m1/specs/f-jit-bytecode-format/spec.md` | .md | ✅ | — |
| 60 | `f_jit/doc/spec/f-jit-m1/specs/f-jit-compiler-frontend/spec.md` | .md | ✅ | — |
| 61 | `f_jit/doc/spec/f-jit-m1/specs/f-jit-differential-acceptance/spec.md` | .md | ✅ | — |
| 62 | `f_jit/doc/spec/f-jit-m1/specs/f-jit-facade-bridge/spec.md` | .md | ✅ | — |
| 63 | `f_jit/doc/spec/f-jit-m1/specs/f-jit-module-skeleton/spec.md` | .md | ✅ | — |
| 64 | `f_jit/doc/spec/f-jit-m1/specs/f-jit-runtime/spec.md` | .md | ✅ | — |
| 65 | `f_jit/doc/spec/f-jit-m1/specs/f-util-fnv/spec.md` | .md | ✅ | — |
| 66 | `f_jit/doc/spec/f-jit-m1/tasks.md` | .md | ✅ | — |
| 67 | `f_jit/doc/spec/f-jit-m1/verify.md` | .md | ✅ | — |
| 68 | `f_jit/doc/spec/f-jit-m2.1/design.md` | .md | ✅ | — |
| 69 | `f_jit/doc/spec/f-jit-m2.1/proposal.md` | .md | ✅ | — |
| 70 | `f_jit/doc/spec/f-jit-m2.1/specs/f-jit-facade-bridge/spec.md` | .md | ✅ | — |
| 71 | `f_jit/doc/spec/f-jit-m2.1/tasks.md` | .md | ✅ | — |
| 72 | `f_jit/doc/spec/f-jit-m2.1/verify.md` | .md | ✅ | — |
| 73 | `f_jit/doc/spec/f-jit-m2.2/design.md` | .md | ✅ | — |
| 74 | `f_jit/doc/spec/f-jit-m2.2/proposal.md` | .md | ✅ | — |
| 75 | `f_jit/doc/spec/f-jit-m2.2/specs/f-jit-base-contracts/spec.md` | .md | ✅ | — |
| 76 | `f_jit/doc/spec/f-jit-m2.2/specs/f-jit-compiler-frontend/spec.md` | .md | ✅ | — |
| 77 | `f_jit/doc/spec/f-jit-m2.2/specs/f-jit-facade-bridge/spec.md` | .md | ✅ | — |
| 78 | `f_jit/doc/spec/f-jit-m2.2/tasks.md` | .md | ✅ | — |
| 79 | `f_jit/doc/spec/f-jit-m2.3/design.md` | .md | ✅ | — |
| 80 | `f_jit/doc/spec/f-jit-m2.3/proposal.md` | .md | ✅ | — |
| 81 | `f_jit/doc/spec/f-jit-m2.3/specs/f-jit-compiler-frontend/spec.md` | .md | ✅ | — |
| 82 | `f_jit/doc/spec/f-jit-m2.3/specs/f-jit-facade-bridge/spec.md` | .md | ✅ | — |
| 83 | `f_jit/doc/spec/f-jit-m2.3/specs/f-jit-runtime/spec.md` | .md | ✅ | — |
| 84 | `f_jit/doc/spec/f-jit-m2.3/tasks.md` | .md | ✅ | — |
| 85 | `f_jit/doc/spec/f-jit-m2/baseline.md` | .md | ✅ | — |
| 86 | `f_jit/doc/spec/f-jit-m2/design.md` | .md | ✅ | — |
| 87 | `f_jit/doc/spec/f-jit-m2/proposal.md` | .md | ✅ | — |
| 88 | `f_jit/doc/spec/f-jit-m2/specs/f-jit-base-contracts/spec.md` | .md | ✅ | — |
| 89 | `f_jit/doc/spec/f-jit-m2/specs/f-jit-bytecode-format/spec.md` | .md | ✅ | — |
| 90 | `f_jit/doc/spec/f-jit-m2/specs/f-jit-compiler-frontend/spec.md` | .md | ✅ | — |
| 91 | `f_jit/doc/spec/f-jit-m2/specs/f-jit-differential-acceptance/spec.md` | .md | ✅ | — |
| 92 | `f_jit/doc/spec/f-jit-m2/specs/f-jit-facade-bridge/spec.md` | .md | ✅ | — |
| 93 | `f_jit/doc/spec/f-jit-m2/specs/f-jit-runtime/spec.md` | .md | ✅ | — |
| 94 | `f_jit/doc/spec/f-jit-m2/tasks.md` | .md | ✅ | — |
| 95 | `f_jit/doc/spec/f-jit-m2/verify.md` | .md | ✅ | — |
| 96 | `f_jit/doc/spec/f-jit-m3/design.md` | .md | ✅ | — |
| 97 | `f_jit/doc/spec/f-jit-m3/proposal.md` | .md | ✅ | — |
| 98 | `f_jit/doc/spec/f-jit-m3/specs/f-jit-base-contracts/spec.md` | .md | ✅ | — |
| 99 | `f_jit/doc/spec/f-jit-m3/specs/f-jit-bytecode-format/spec.md` | .md | ✅ | — |
| 100 | `f_jit/doc/spec/f-jit-m3/specs/f-jit-compiler-frontend/spec.md` | .md | ✅ | — |
| 101 | `f_jit/doc/spec/f-jit-m3/specs/f-jit-differential-acceptance/spec.md` | .md | ✅ | — |
| 102 | `f_jit/doc/spec/f-jit-m3/specs/f-jit-facade-bridge/spec.md` | .md | ✅ | — |
| 103 | `f_jit/doc/spec/f-jit-m3/specs/f-jit-runtime/spec.md` | .md | ✅ | — |
| 104 | `f_jit/doc/spec/f-jit-m3/tasks.md` | .md | ✅ | — |
| 105 | `f_jit/doc/spec/feat-f-jit-interface-and-inheritance/design.md` | .md | ✅ | — |
| 106 | `f_jit/doc/spec/feat-f-jit-interface-and-inheritance/proposal.md` | .md | ✅ | — |
| 107 | `f_jit/doc/spec/feat-f-jit-interface-and-inheritance/specs/f-jit-compiler-frontend/spec.md` | .md | ✅ | — |
| 108 | `f_jit/doc/spec/feat-f-jit-interface-and-inheritance/specs/f-jit-facade-bridge/spec.md` | .md | ✅ | — |
| 109 | `f_jit/doc/spec/feat-f-jit-interface-and-inheritance/tasks.md` | .md | ✅ | — |
| 110 | `f_jit/doc/spec/feat-f-jit-interface-and-inheritance/verify.md` | .md | ✅ | — |
| 111 | `f_jit/doc/spec/feat-f-jit-parallel-call/design.md` | .md | ✅ | — |
| 112 | `f_jit/doc/spec/feat-f-jit-parallel-call/proposal.md` | .md | ✅ | — |
| 113 | `f_jit/doc/spec/feat-f-jit-parallel-call/specs/f-jit-facade-bridge/spec.md` | .md | ✅ | — |
| 114 | `f_jit/doc/spec/feat-f-jit-parallel-call/specs/f-jit-runtime/spec.md` | .md | ✅ | — |
| 115 | `f_jit/doc/spec/feat-f-jit-parallel-call/tasks.md` | .md | ✅ | — |
| 116 | `f_jit/doc/spec/feat-f-jit-parallel-call/test-plan.md` | .md | ✅ | — |
| 117 | `f_jit/doc/spec/feat-f-jit-parallel-call/verify.md` | .md | ✅ | — |
| 118 | `f_jit/doc/spec/feat-f-jit-pow-and-sci-notation/design.md` | .md | ✅ | — |
| 119 | `f_jit/doc/spec/feat-f-jit-pow-and-sci-notation/proposal.md` | .md | ✅ | — |
| 120 | `f_jit/doc/spec/feat-f-jit-pow-and-sci-notation/specs/f-jit-runtime/spec.md` | .md | ✅ | — |
| 121 | `f_jit/doc/spec/feat-f-jit-pow-and-sci-notation/tasks.md` | .md | ✅ | — |
| 122 | `f_jit/doc/spec/fix-await-timeout-semantics/proposal.md` | .md | ✅ | — |
| 123 | `f_jit/doc/spec/fix-await-timeout-semantics/tasks.md` | .md | ✅ | — |
| 124 | `f_jit/doc/spec/fix-await-timeout-semantics/verify.md` | .md | ✅ | — |
| 125 | `f_jit/doc/spec/fix-compile-failure-cache-sticky/proposal.md` | .md | ✅ | — |
| 126 | `f_jit/doc/spec/fix-compile-failure-cache-sticky/tasks.md` | .md | ✅ | — |
| 127 | `f_jit/doc/spec/fix-compile-failure-cache-sticky/verify.md` | .md | ✅ | — |
| 128 | `f_jit/doc/spec/fix-compilecache-lock-order/proposal.md` | .md | ✅ | — |
| 129 | `f_jit/doc/spec/fix-compilecache-lock-order/tasks.md` | .md | ✅ | — |
| 130 | `f_jit/doc/spec/fix-compilecache-lock-order/verify.md` | .md | ✅ | — |
| 131 | `f_jit/doc/spec/fix-compiler-register-lock/proposal.md` | .md | ✅ | — |
| 132 | `f_jit/doc/spec/fix-compiler-register-lock/tasks.md` | .md | ✅ | — |
| 133 | `f_jit/doc/spec/fix-compiler-register-lock/verify.md` | .md | ✅ | — |
| 134 | `f_jit/doc/spec/fix-da-diagnostic-classification/proposal.md` | .md | ✅ | — |
| 135 | `f_jit/doc/spec/fix-da-diagnostic-classification/tasks.md` | .md | ✅ | — |
| 136 | `f_jit/doc/spec/fix-da-diagnostic-classification/verify.md` | .md | ✅ | — |
| 137 | `f_jit/doc/spec/fix-f-jit-audit-defects/design.md` | .md | ✅ | — |
| 138 | `f_jit/doc/spec/fix-f-jit-audit-defects/proposal.md` | .md | ✅ | — |
| 139 | `f_jit/doc/spec/fix-f-jit-audit-defects/specs/f-jit-backend/spec.md` | .md | ✅ | — |
| 140 | `f_jit/doc/spec/fix-f-jit-audit-defects/specs/f-jit-bytecode-format/spec.md` | .md | ✅ | — |
| 141 | `f_jit/doc/spec/fix-f-jit-audit-defects/specs/f-jit-compiler-frontend/spec.md` | .md | ✅ | — |
| 142 | `f_jit/doc/spec/fix-f-jit-audit-defects/specs/f-jit-differential-acceptance/spec.md` | .md | ✅ | — |
| 143 | `f_jit/doc/spec/fix-f-jit-audit-defects/specs/f-jit-facade-bridge/spec.md` | .md | ✅ | — |
| 144 | `f_jit/doc/spec/fix-f-jit-audit-defects/specs/f-jit-runtime/spec.md` | .md | ✅ | — |
| 145 | `f_jit/doc/spec/fix-f-jit-audit-defects/tasks.md` | .md | ✅ | — |
| 146 | `f_jit/doc/spec/fix-f-jit-audit-defects/test-plan.md` | .md | ✅ | — |
| 147 | `f_jit/doc/spec/fix-f-jit-audit-defects/verify.md` | .md | ✅ | — |
| 148 | `f_jit/doc/spec/fix-f-jit-strictfp-deadline-x86/design.md` | .md | ✅ | — |
| 149 | `f_jit/doc/spec/fix-f-jit-strictfp-deadline-x86/proposal.md` | .md | ✅ | — |
| 150 | `f_jit/doc/spec/fix-f-jit-strictfp-deadline-x86/specs/f-jit-backend/spec.md` | .md | ✅ | — |
| 151 | `f_jit/doc/spec/fix-f-jit-strictfp-deadline-x86/tasks.md` | .md | ✅ | — |
| 152 | `f_jit/doc/spec/fix-f-jit-x86-stack-align/design.md` | .md | ✅ | — |
| 153 | `f_jit/doc/spec/fix-f-jit-x86-stack-align/proposal.md` | .md | ✅ | — |
| 154 | `f_jit/doc/spec/fix-f-jit-x86-stack-align/specs/f-jit-backend/spec.md` | .md | ✅ | — |
| 155 | `f_jit/doc/spec/fix-f-jit-x86-stack-align/tasks.md` | .md | ✅ | — |
| 156 | `f_jit/doc/spec/fix-f-jit-x86-stack-align/verify.md` | .md | ✅ | — |
| 157 | `f_jit/doc/spec/fix-handle-config-race/proposal.md` | .md | ✅ | — |
| 158 | `f_jit/doc/spec/fix-handle-config-race/tasks.md` | .md | ✅ | — |
| 159 | `f_jit/doc/spec/fix-handle-config-race/verify.md` | .md | ✅ | — |
| 160 | `f_jit/doc/spec/fix-handle-gen-exhaustion/design.md` | .md | ✅ | — |
| 161 | `f_jit/doc/spec/fix-handle-gen-exhaustion/proposal.md` | .md | ✅ | — |
| 162 | `f_jit/doc/spec/fix-handle-gen-exhaustion/specs/f-jit-runtime/spec.md` | .md | ✅ | — |
| 163 | `f_jit/doc/spec/fix-handle-gen-exhaustion/tasks.md` | .md | ✅ | — |
| 164 | `f_jit/doc/spec/fix-handle-gen-exhaustion/verify.md` | .md | ✅ | — |
| 165 | `f_jit/doc/spec/fix-jit-unary-not/design.md` | .md | ✅ | — |
| 166 | `f_jit/doc/spec/fix-jit-unary-not/proposal.md` | .md | ✅ | — |
| 167 | `f_jit/doc/spec/fix-jit-unary-not/specs/f-jit-backend/spec.md` | .md | ✅ | — |
| 168 | `f_jit/doc/spec/fix-jit-unary-not/specs/f-jit-compiler-frontend/spec.md` | .md | ✅ | — |
| 169 | `f_jit/doc/spec/fix-jit-unary-not/specs/f-jit-differential-acceptance/spec.md` | .md | ✅ | — |
| 170 | `f_jit/doc/spec/fix-jit-unary-not/tasks.md` | .md | ✅ | — |
| 171 | `f_jit/doc/spec/fix-jit-unary-not/verify.md` | .md | ✅ | — |
| 172 | `f_jit/doc/spec/fix-jit-unary-not/x86-verification.md` | .md | ✅ | — |
| 173 | `f_jit/doc/spec/fix-native-assets-atomic/proposal.md` | .md | ✅ | — |
| 174 | `f_jit/doc/spec/fix-native-assets-atomic/tasks.md` | .md | ✅ | — |
| 175 | `f_jit/doc/spec/fix-native-assets-atomic/verify.md` | .md | ✅ | — |
| 176 | `f_jit/doc/spec/fix-x86-audit-isolation/proposal.md` | .md | ✅ | — |
| 177 | `f_jit/doc/spec/fix-x86-audit-isolation/tasks.md` | .md | ✅ | — |
| 178 | `f_jit/doc/spec/fix-x86-audit-isolation/verify.md` | .md | ✅ | — |
| 179 | `f_jit/doc/spec/flip-f-jit-strictfp-default/design.md` | .md | ✅ | — |
| 180 | `f_jit/doc/spec/flip-f-jit-strictfp-default/proposal.md` | .md | ✅ | — |
| 181 | `f_jit/doc/spec/flip-f-jit-strictfp-default/specs/f-jit-facade-bridge/spec.md` | .md | ✅ | — |
| 182 | `f_jit/doc/spec/flip-f-jit-strictfp-default/tasks.md` | .md | ✅ | — |
| 183 | `f_jit/doc/spec/flip-f-jit-strictfp-default/test-plan.md` | .md | ✅ | — |
| 184 | `f_jit/doc/spec/flip-f-jit-strictfp-default/verify.md` | .md | ✅ | — |
| 185 | `f_jit/doc/spec/harden-f-jit-object-lifetime/design.md` | .md | ✅ | — |
| 186 | `f_jit/doc/spec/harden-f-jit-object-lifetime/proposal.md` | .md | ✅ | — |
| 187 | `f_jit/doc/spec/harden-f-jit-object-lifetime/specs/f-jit-backend/spec.md` | .md | ✅ | — |
| 188 | `f_jit/doc/spec/harden-f-jit-object-lifetime/tasks.md` | .md | ✅ | — |
| 189 | `f_jit/doc/spec/harden-x86-audit-and-futil-tests/design.md` | .md | ✅ | — |
| 190 | `f_jit/doc/spec/harden-x86-audit-and-futil-tests/proposal.md` | .md | ✅ | — |
| 191 | `f_jit/doc/spec/harden-x86-audit-and-futil-tests/specs/f-jit-backend/spec.md` | .md | ✅ | — |
| 192 | `f_jit/doc/spec/harden-x86-audit-and-futil-tests/tasks.md` | .md | ✅ | — |
| 193 | `f_jit/doc/spec/jit-closure-unload-cascade/design.md` | .md | ✅ | — |
| 194 | `f_jit/doc/spec/jit-closure-unload-cascade/proposal.md` | .md | ✅ | — |
| 195 | `f_jit/doc/spec/jit-closure-unload-cascade/specs/f-jit-facade-bridge/spec.md` | .md | ✅ | — |
| 196 | `f_jit/doc/spec/jit-closure-unload-cascade/tasks.md` | .md | ✅ | — |
| 197 | `f_jit/doc/spec/jit-function-resource-close/design.md` | .md | ✅ | — |
| 198 | `f_jit/doc/spec/jit-function-resource-close/proposal.md` | .md | ✅ | — |
| 199 | `f_jit/doc/spec/jit-function-resource-close/specs/f-jit-facade-bridge/spec.md` | .md | ✅ | — |
| 200 | `f_jit/doc/spec/jit-function-resource-close/tasks.md` | .md | ✅ | — |
| 201 | `f_jit/doc/spec/optimize-arg-staging/design.md` | .md | ✅ | — |
| 202 | `f_jit/doc/spec/optimize-arg-staging/proposal.md` | .md | ✅ | — |
| 203 | `f_jit/doc/spec/optimize-arg-staging/tasks.md` | .md | ✅ | — |
| 204 | `f_jit/doc/spec/optimize-arg-staging/verify.md` | .md | ✅ | — |
| 205 | `f_jit/doc/spec/optimize-call-alloc/design.md` | .md | ✅ | — |
| 206 | `f_jit/doc/spec/optimize-call-alloc/proposal.md` | .md | ✅ | — |
| 207 | `f_jit/doc/spec/optimize-call-alloc/tasks.md` | .md | ✅ | — |
| 208 | `f_jit/doc/spec/optimize-call-alloc/verify.md` | .md | ✅ | — |
| 209 | `f_jit/doc/spec/optimize-call-alloc2/proposal.md` | .md | ✅ | — |
| 210 | `f_jit/doc/spec/optimize-call-alloc2/tasks.md` | .md | ✅ | — |
| 211 | `f_jit/doc/spec/optimize-call-alloc2/verify.md` | .md | ✅ | — |
| 212 | `f_jit/doc/spec/optimize-call-path-phase1/design.md` | .md | ✅ | — |
| 213 | `f_jit/doc/spec/optimize-call-path-phase1/proposal.md` | .md | ✅ | — |
| 214 | `f_jit/doc/spec/optimize-call-path-phase1/specs/f-jit-runtime/spec.md` | .md | ✅ | — |
| 215 | `f_jit/doc/spec/optimize-call-path-phase1/tasks.md` | .md | ✅ | — |
| 216 | `f_jit/doc/spec/optimize-call-path-phase1/verify.md` | .md | ✅ | — |
| 217 | `f_jit/doc/spec/optimize-call-path-phase2/design.md` | .md | ✅ | — |
| 218 | `f_jit/doc/spec/optimize-call-path-phase2/proposal.md` | .md | ✅ | — |
| 219 | `f_jit/doc/spec/optimize-call-path-phase2/tasks.md` | .md | ✅ | — |
| 220 | `f_jit/doc/spec/optimize-call-path-phase2/verify.md` | .md | ✅ | — |
| 221 | `f_jit/doc/spec/optimize-call-path-phase4/design.md` | .md | ✅ | — |
| 222 | `f_jit/doc/spec/optimize-call-path-phase4/proposal.md` | .md | ✅ | — |
| 223 | `f_jit/doc/spec/optimize-call-path-phase4/tasks.md` | .md | ✅ | — |
| 224 | `f_jit/doc/spec/optimize-call-path-phase4/verify.md` | .md | ✅ | — |
| 225 | `f_jit/doc/spec/optimize-compile-copy/design.md` | .md | ✅ | — |
| 226 | `f_jit/doc/spec/optimize-compile-copy/proposal.md` | .md | ✅ | — |
| 227 | `f_jit/doc/spec/optimize-compile-copy/tasks.md` | .md | ✅ | — |
| 228 | `f_jit/doc/spec/optimize-compile-copy/verify.md` | .md | ✅ | — |
| 229 | `f_jit/doc/spec/optimize-compile-hotpath/design.md` | .md | ✅ | — |
| 230 | `f_jit/doc/spec/optimize-compile-hotpath/proposal.md` | .md | ✅ | — |
| 231 | `f_jit/doc/spec/optimize-compile-hotpath/tasks.md` | .md | ✅ | — |
| 232 | `f_jit/doc/spec/optimize-compile-hotpath/verify.md` | .md | ✅ | — |
| 233 | `f_jit/doc/spec/optimize-compile-lookup/design.md` | .md | ✅ | — |
| 234 | `f_jit/doc/spec/optimize-compile-lookup/proposal.md` | .md | ✅ | — |
| 235 | `f_jit/doc/spec/optimize-compile-lookup/tasks.md` | .md | ✅ | — |
| 236 | `f_jit/doc/spec/optimize-compile-lookup/verify.md` | .md | ✅ | — |
| 237 | `f_jit/doc/spec/optimize-compile-path/design.md` | .md | ✅ | — |
| 238 | `f_jit/doc/spec/optimize-compile-path/proposal.md` | .md | ✅ | — |
| 239 | `f_jit/doc/spec/optimize-compile-path/tasks.md` | .md | ✅ | — |
| 240 | `f_jit/doc/spec/optimize-compile-path/verify.md` | .md | ✅ | — |
| 241 | `f_jit/doc/spec/optimize-decode-alloc/design.md` | .md | ✅ | — |
| 242 | `f_jit/doc/spec/optimize-decode-alloc/proposal.md` | .md | ✅ | — |
| 243 | `f_jit/doc/spec/optimize-decode-alloc/tasks.md` | .md | ✅ | — |
| 244 | `f_jit/doc/spec/optimize-decode-alloc/verify.md` | .md | ✅ | — |
| 245 | `f_jit/doc/spec/optimize-emit-audit/design.md` | .md | ✅ | — |
| 246 | `f_jit/doc/spec/optimize-emit-audit/proposal.md` | .md | ✅ | — |
| 247 | `f_jit/doc/spec/optimize-emit-audit/tasks.md` | .md | ✅ | — |
| 248 | `f_jit/doc/spec/optimize-emit-audit/verify.md` | .md | ✅ | — |
| 249 | `f_jit/doc/spec/optimize-emit-fixup/design.md` | .md | ✅ | — |
| 250 | `f_jit/doc/spec/optimize-emit-fixup/proposal.md` | .md | ✅ | — |
| 251 | `f_jit/doc/spec/optimize-emit-fixup/tasks.md` | .md | ✅ | — |
| 252 | `f_jit/doc/spec/optimize-emit-fixup/verify.md` | .md | ✅ | — |
| 253 | `f_jit/doc/spec/optimize-helper-table/design.md` | .md | ✅ | — |
| 254 | `f_jit/doc/spec/optimize-helper-table/proposal.md` | .md | ✅ | — |
| 255 | `f_jit/doc/spec/optimize-helper-table/tasks.md` | .md | ✅ | — |
| 256 | `f_jit/doc/spec/optimize-helper-table/verify.md` | .md | ✅ | — |
| 257 | `f_jit/doc/spec/optimize-jitcontext-pool/proposal.md` | .md | ✅ | — |
| 258 | `f_jit/doc/spec/optimize-jitcontext-pool/tasks.md` | .md | ✅ | — |
| 259 | `f_jit/doc/spec/optimize-jitcontext-pool/verify.md` | .md | ✅ | — |
| 260 | `f_jit/doc/spec/optimize-loop-safepoint/design.md` | .md | ✅ | — |
| 261 | `f_jit/doc/spec/optimize-loop-safepoint/proposal.md` | .md | ✅ | — |
| 262 | `f_jit/doc/spec/optimize-loop-safepoint/tasks.md` | .md | ✅ | — |
| 263 | `f_jit/doc/spec/optimize-loop-safepoint/verify.md` | .md | ✅ | — |
| 264 | `f_jit/doc/spec/optimize-marshal-rs/design.md` | .md | ✅ | — |
| 265 | `f_jit/doc/spec/optimize-marshal-rs/proposal.md` | .md | ✅ | — |
| 266 | `f_jit/doc/spec/optimize-marshal-rs/tasks.md` | .md | ✅ | — |
| 267 | `f_jit/doc/spec/optimize-marshal-rs/verify.md` | .md | ✅ | — |
| 268 | `f_jit/doc/spec/optimize-runtime-tls/design.md` | .md | ✅ | — |
| 269 | `f_jit/doc/spec/optimize-runtime-tls/proposal.md` | .md | ✅ | — |
| 270 | `f_jit/doc/spec/optimize-runtime-tls/tasks.md` | .md | ✅ | — |
| 271 | `f_jit/doc/spec/optimize-runtime-tls/verify.md` | .md | ✅ | — |
| 272 | `f_jit/doc/spec/optimize-signature-tables/design.md` | .md | ✅ | — |
| 273 | `f_jit/doc/spec/optimize-signature-tables/proposal.md` | .md | ✅ | — |
| 274 | `f_jit/doc/spec/optimize-signature-tables/tasks.md` | .md | ✅ | — |
| 275 | `f_jit/doc/spec/optimize-signature-tables/verify.md` | .md | ✅ | — |
| 276 | `f_jit/doc/spec/optimize-type-cache/design.md` | .md | ✅ | — |
| 277 | `f_jit/doc/spec/optimize-type-cache/proposal.md` | .md | ✅ | — |
| 278 | `f_jit/doc/spec/optimize-type-cache/tasks.md` | .md | ✅ | — |
| 279 | `f_jit/doc/spec/optimize-type-cache/verify.md` | .md | ✅ | — |
| 280 | `f_jit/doc/spec/refine-f-jit-unload-api/design.md` | .md | ✅ | — |
| 281 | `f_jit/doc/spec/refine-f-jit-unload-api/proposal.md` | .md | ✅ | — |
| 282 | `f_jit/doc/spec/refine-f-jit-unload-api/specs/f-jit-facade-bridge/spec.md` | .md | ✅ | — |
| 283 | `f_jit/doc/spec/refine-f-jit-unload-api/tasks.md` | .md | ✅ | — |
| 284 | `f_jit/doc/spec/refine-f-jit-unload-api/test-plan.md` | .md | ✅ | — |
| 285 | `f_jit/doc/spec/refine-f-jit-unload-api/verify.md` | .md | ✅ | — |
| 286 | `f_jit/doc/spec/test-f-jit-parallel-calls/design.md` | .md | ✅ | — |
| 287 | `f_jit/doc/spec/test-f-jit-parallel-calls/proposal.md` | .md | ✅ | — |
| 288 | `f_jit/doc/spec/test-f-jit-parallel-calls/tasks.md` | .md | ✅ | — |
| 289 | `f_jit/doc/spec/test-f-jit-parallel-calls/test-plan.md` | .md | ✅ | — |
| 290 | `f_jit/doc/spec/test-f-jit-parallel-calls/verify.md` | .md | ✅ | — |
| 291 | `f_jit/src/AdapterRegistry.cj` | .cj | ✅ | — |
| 292 | `f_jit/src/AdapterRegistry_test.cj` | .cj | ✅ | — |
| 293 | `f_jit/src/AnyBridgeCall_test.cj` | .cj | ✅ | — |
| 294 | `f_jit/src/AnyHostCast_test.cj` | .cj | ✅ | — |
| 295 | `f_jit/src/BaseVisibility_test.cj` | .cj | ✅ | — |
| 296 | `f_jit/src/CallForFnConcurrency_test.cj` | .cj | ✅ | — |
| 297 | `f_jit/src/CallMarshal.cj` | .cj | ✅ | — |
| 298 | `f_jit/src/CallMarshalAny_test.cj` | .cj | ✅ | — |
| 299 | `f_jit/src/CallMarshalM2_test.cj` | .cj | ✅ | — |
| 300 | `f_jit/src/CallMarshal_test.cj` | .cj | ✅ | — |
| 301 | `f_jit/src/CallPathBench_test.cj` | .cj | ✅ | — |
| 302 | `f_jit/src/CastOr_test.cj` | .cj | ✅ | — |
| 303 | `f_jit/src/ClassRegistry.cj` | .cj | ✅ | — |
| 304 | `f_jit/src/ClassRegistry_test.cj` | .cj | ✅ | — |
| 305 | `f_jit/src/CompileAwaitTimeout_test.cj` | .cj | ✅ | — |
| 306 | `f_jit/src/CompileCache.cj` | .cj | ✅ | — |
| 307 | `f_jit/src/CompileCache_test.cj` | .cj | ✅ | — |
| 308 | `f_jit/src/CompileConcurrency_test.cj` | .cj | ✅ | — |
| 309 | `f_jit/src/CompileFailureCache_test.cj` | .cj | ✅ | — |
| 310 | `f_jit/src/CompileOptions.cj` | .cj | ✅ | — |
| 311 | `f_jit/src/CompileOptions_test.cj` | .cj | ✅ | — |
| 312 | `f_jit/src/CompilePipeline.cj` | .cj | ✅ | — |
| 313 | `f_jit/src/CompilePipelineVersion_test.cj` | .cj | ✅ | — |
| 314 | `f_jit/src/CompilePipeline_test.cj` | .cj | ✅ | — |
| 315 | `f_jit/src/Compiler.cj` | .cj | ✅ | — |
| 316 | `f_jit/src/CompilerRegistrationConcurrency_test.cj` | .cj | ✅ | — |
| 317 | `f_jit/src/CompilerRegistration_test.cj` | .cj | ✅ | — |
| 318 | `f_jit/src/CompilerSnapshotCache_test.cj` | .cj | ✅ | — |
| 319 | `f_jit/src/ConcurrencyMatrix_test.cj` | .cj | ✅ | — |
| 320 | `f_jit/src/ConstantReclaimFacade_test.cj` | .cj | ✅ | — |
| 321 | `f_jit/src/DaDiagnostic_test.cj` | .cj | ✅ | — |
| 322 | `f_jit/src/EscapedClosure.cj` | .cj | ✅ | — |
| 323 | `f_jit/src/FacadeRegistry_test.cj` | .cj | ✅ | — |
| 324 | `f_jit/src/HandleTableConfigRace_test.cj` | .cj | ✅ | — |
| 325 | `f_jit/src/HelperTableScope_test.cj` | .cj | ✅ | — |
| 326 | `f_jit/src/HostClosureAdapter_test.cj` | .cj | ✅ | — |
| 327 | `f_jit/src/HostSignature_test.cj` | .cj | ✅ | — |
| 328 | `f_jit/src/Inheritance_test.cj` | .cj | ✅ | — |
| 329 | `f_jit/src/Interface_test.cj` | .cj | ✅ | — |
| 330 | `f_jit/src/IterLifecycle_test.cj` | .cj | ✅ | — |
| 331 | `f_jit/src/JitBacked_test.cj` | .cj | ✅ | — |
| 332 | `f_jit/src/JitBindIgnore_test.cj` | .cj | ✅ | — |
| 333 | `f_jit/src/JitBindSupport.cj` | .cj | ✅ | — |
| 334 | `f_jit/src/JitBindSupportSnapshot_test.cj` | .cj | ✅ | — |
| 335 | `f_jit/src/JitBind_test.cj` | .cj | ✅ | — |
| 336 | `f_jit/src/JitClosureId.cj` | .cj | ✅ | — |
| 337 | `f_jit/src/JitClosureId_test.cj` | .cj | ✅ | — |
| 338 | `f_jit/src/JitClosureLifecycle_test.cj` | .cj | ✅ | — |
| 339 | `f_jit/src/JitFunction.cj` | .cj | ✅ | — |
| 340 | `f_jit/src/JitFunctionClosure_test.cj` | .cj | ✅ | — |
| 341 | `f_jit/src/JitFunction_test.cj` | .cj | ✅ | — |
| 342 | `f_jit/src/JitHost.cj` | .cj | ✅ | — |
| 343 | `f_jit/src/JitMemberAccess_test.cj` | .cj | ✅ | — |
| 344 | `f_jit/src/JitReport.cj` | .cj | ✅ | — |
| 345 | `f_jit/src/JitReport_test.cj` | .cj | ✅ | — |
| 346 | `f_jit/src/JitSignature_test.cj` | .cj | ✅ | — |
| 347 | `f_jit/src/JsonBridge_test.cj` | .cj | ✅ | — |
| 348 | `f_jit/src/LastEscapedScope_test.cj` | .cj | ✅ | — |
| 349 | `f_jit/src/Lifetime_test.cj` | .cj | ✅ | — |
| 350 | `f_jit/src/LoopSafepoint_test.cj` | .cj | ✅ | — |
| 351 | `f_jit/src/MarshalRs_test.cj` | .cj | ✅ | — |
| 352 | `f_jit/src/OverrideBinding_test.cj` | .cj | ✅ | — |
| 353 | `f_jit/src/ParallelCall_test.cj` | .cj | ✅ | — |
| 354 | `f_jit/src/ParallelThroughput_test.cj` | .cj | ✅ | — |
| 355 | `f_jit/src/PerfAdapter_test.cj` | .cj | ✅ | — |
| 356 | `f_jit/src/PerfM2_test.cj` | .cj | ✅ | — |
| 357 | `f_jit/src/PerfOverride_test.cj` | .cj | ✅ | — |
| 358 | `f_jit/src/PowSciA64_test.cj` | .cj | ✅ | — |
| 359 | `f_jit/src/Pow_test.cj` | .cj | ✅ | — |
| 360 | `f_jit/src/Q6Acceptance_test.cj` | .cj | ✅ | — |
| 361 | `f_jit/src/Q6DiffCoverage_test.cj` | .cj | ✅ | — |
| 362 | `f_jit/src/ReflectMap_test.cj` | .cj | ✅ | — |
| 363 | `f_jit/src/ReflectRegistrar.cj` | .cj | ✅ | — |
| 364 | `f_jit/src/ReflectRegistrar_test.cj` | .cj | ✅ | — |
| 365 | `f_jit/src/Root.cj` | .cj | ✅ | — |
| 366 | `f_jit/src/RunUnit_test.cj` | .cj | ✅ | — |
| 367 | `f_jit/src/RuntimeStateIsolation_test.cj` | .cj | ✅ | — |
| 368 | `f_jit/src/SignatureTableConcurrency_test.cj` | .cj | ✅ | — |
| 369 | `f_jit/src/Skeleton_test.cj` | .cj | ✅ | — |
| 370 | `f_jit/src/Slot14_test.cj` | .cj | ✅ | — |
| 371 | `f_jit/src/StrictFp_test.cj` | .cj | ✅ | — |
| 372 | `f_jit/src/T40Deopt_test.cj` | .cj | ✅ | — |
| 373 | `f_jit/src/TwoForms_test.cj` | .cj | ✅ | — |
| 374 | `f_jit/src/TypeCodeCache_test.cj` | .cj | ✅ | — |
| 375 | `f_jit/src/UnloadConcurrency_test.cj` | .cj | ✅ | — |
| 376 | `f_jit/src/WindowPool_test.cj` | .cj | ✅ | — |
| 377 | `f_jit/src/backend/A64AuditIsolation_test.cj` | .cj | ✅ | — |
| 378 | `f_jit/src/backend/A64Compiler.cj` | .cj | ✅ | — |
| 379 | `f_jit/src/backend/A64Emitter.cj` | .cj | ✅ | — |
| 380 | `f_jit/src/backend/A64EmitterFixup_test.cj` | .cj | ✅ | — |
| 381 | `f_jit/src/backend/A64EmitterSize_test.cj` | .cj | ✅ | — |
| 382 | `f_jit/src/backend/A64Emitter_test.cj` | .cj | ✅ | — |
| 383 | `f_jit/src/backend/A64Lower.cj` | .cj | ✅ | — |
| 384 | `f_jit/src/backend/A64NotBEncoding_test.cj` | .cj | ✅ | — |
| 385 | `f_jit/src/backend/Backend.cj` | .cj | ✅ | — |
| 386 | `f_jit/src/backend/BackendSelector.cj` | .cj | ✅ | — |
| 387 | `f_jit/src/backend/BackendSelector_test.cj` | .cj | ✅ | — |
| 388 | `f_jit/src/backend/CodeBuffer.cj` | .cj | ✅ | — |
| 389 | `f_jit/src/backend/CodeBuffer_test.cj` | .cj | ✅ | — |
| 390 | `f_jit/src/backend/CompileCacheKey.cj` | .cj | ✅ | — |
| 391 | `f_jit/src/backend/CompileCacheKey_test.cj` | .cj | ✅ | — |
| 392 | `f_jit/src/backend/EmitAudit_test.cj` | .cj | ✅ | — |
| 393 | `f_jit/src/backend/JitCompiler.cj` | .cj | ✅ | — |
| 394 | `f_jit/src/backend/JitExecutor.cj` | .cj | ✅ | — |
| 395 | `f_jit/src/backend/NativeAssets.cj` | .cj | ✅ | — |
| 396 | `f_jit/src/backend/NativeAssetsConcurrency_test.cj` | .cj | ✅ | — |
| 397 | `f_jit/src/backend/NativeAssets_test.cj` | .cj | ✅ | — |
| 398 | `f_jit/src/backend/X86AuditIsolation_test.cj` | .cj | ✅ | — |
| 399 | `f_jit/src/backend/X86Compiler.cj` | .cj | ✅ | — |
| 400 | `f_jit/src/backend/X86Depth.cj` | .cj | ✅ | — |
| 401 | `f_jit/src/backend/X86Depth_test.cj` | .cj | ✅ | — |
| 402 | `f_jit/src/backend/X86Frame_test.cj` | .cj | ✅ | — |
| 403 | `f_jit/src/backend/X86Lower.cj` | .cj | ✅ | — |
| 404 | `f_jit/src/backend/X86Lower_test.cj` | .cj | ✅ | — |
| 405 | `f_jit/src/backend/X86Thunk_test.cj` | .cj | ✅ | — |
| 406 | `f_jit/src/base/Base.cj` | .cj | ✅ | — |
| 407 | `f_jit/src/base/CallContext.cj` | .cj | ✅ | — |
| 408 | `f_jit/src/base/CallContext_test.cj` | .cj | ✅ | — |
| 409 | `f_jit/src/base/ClassRegistration.cj` | .cj | ✅ | — |
| 410 | `f_jit/src/base/ClassRegistration_test.cj` | .cj | ✅ | — |
| 411 | `f_jit/src/base/DiagCode.cj` | .cj | ✅ | — |
| 412 | `f_jit/src/base/DiagnosticLevel.cj` | .cj | ✅ | — |
| 413 | `f_jit/src/base/DiagnosticsSink.cj` | .cj | ✅ | — |
| 414 | `f_jit/src/base/Diagnostics_test.cj` | .cj | ✅ | — |
| 415 | `f_jit/src/base/DummyDiagnosticsSink.cj` | .cj | ✅ | — |
| 416 | `f_jit/src/base/Engine.cj` | .cj | ✅ | — |
| 417 | `f_jit/src/base/ErrCode.cj` | .cj | ✅ | — |
| 418 | `f_jit/src/base/ErrCode_test.cj` | .cj | ✅ | — |
| 419 | `f_jit/src/base/HostSignature.cj` | .cj | ✅ | — |
| 420 | `f_jit/src/base/InterruptedException.cj` | .cj | ✅ | — |
| 421 | `f_jit/src/base/JitBindings.cj` | .cj | ✅ | — |
| 422 | `f_jit/src/base/JitException.cj` | .cj | ✅ | — |
| 423 | `f_jit/src/base/JitException_test.cj` | .cj | ✅ | — |
| 424 | `f_jit/src/base/JitMode.cj` | .cj | ✅ | — |
| 425 | `f_jit/src/base/JitValue.cj` | .cj | ✅ | — |
| 426 | `f_jit/src/base/LocalType.cj` | .cj | ✅ | — |
| 427 | `f_jit/src/base/LocalType_test.cj` | .cj | ✅ | — |
| 428 | `f_jit/src/base/PredefinedFunction.cj` | .cj | ✅ | — |
| 429 | `f_jit/src/base/RegistrationException.cj` | .cj | ✅ | — |
| 430 | `f_jit/src/base/RegistrationException_test.cj` | .cj | ✅ | — |
| 431 | `f_jit/src/base/SourceCompileException.cj` | .cj | ✅ | — |
| 432 | `f_jit/src/base/SourceCompileException_test.cj` | .cj | ✅ | — |
| 433 | `f_jit/src/base/SourcePos.cj` | .cj | ✅ | — |
| 434 | `f_jit/src/base/SourceUnit.cj` | .cj | ✅ | — |
| 435 | `f_jit/src/base/SourceUnit_test.cj` | .cj | ✅ | — |
| 436 | `f_jit/src/base/TypeNames.cj` | .cj | ✅ | — |
| 437 | `f_jit/src/base/TypeToken.cj` | .cj | ✅ | — |
| 438 | `f_jit/src/base/TypeToken_test.cj` | .cj | ✅ | — |
| 439 | `f_jit/src/base/ValueTypes_test.cj` | .cj | ✅ | — |
| 440 | `f_jit/src/base/Version.cj` | .cj | ✅ | — |
| 441 | `f_jit/src/base/Version_test.cj` | .cj | ✅ | — |
| 442 | `f_jit/src/bytecode/ByteCodec.cj` | .cj | ✅ | — |
| 443 | `f_jit/src/bytecode/ByteCodec_test.cj` | .cj | ✅ | — |
| 444 | `f_jit/src/bytecode/Bytecode.cj` | .cj | ✅ | — |
| 445 | `f_jit/src/bytecode/CanonKey.cj` | .cj | ✅ | — |
| 446 | `f_jit/src/bytecode/ConstPayload.cj` | .cj | ✅ | — |
| 447 | `f_jit/src/bytecode/ConstPayload_test.cj` | .cj | ✅ | — |
| 448 | `f_jit/src/bytecode/ConstRegistry.cj` | .cj | ✅ | — |
| 449 | `f_jit/src/bytecode/FbcHeader.cj` | .cj | ✅ | — |
| 450 | `f_jit/src/bytecode/FbcHeader_test.cj` | .cj | ✅ | — |
| 451 | `f_jit/src/bytecode/FbcReader.cj` | .cj | ✅ | — |
| 452 | `f_jit/src/bytecode/FbcReader_test.cj` | .cj | ✅ | — |
| 453 | `f_jit/src/bytecode/FbcRuleSet.cj` | .cj | ✅ | — |
| 454 | `f_jit/src/bytecode/FbcWriter.cj` | .cj | ✅ | — |
| 455 | `f_jit/src/bytecode/Fingerprint.cj` | .cj | ✅ | — |
| 456 | `f_jit/src/bytecode/Fingerprint_test.cj` | .cj | ✅ | — |
| 457 | `f_jit/src/bytecode/FuncDir.cj` | .cj | ✅ | — |
| 458 | `f_jit/src/bytecode/FuncDir_test.cj` | .cj | ✅ | — |
| 459 | `f_jit/src/bytecode/InsnDecoder.cj` | .cj | ✅ | — |
| 460 | `f_jit/src/bytecode/InsnDecoder_test.cj` | .cj | ✅ | — |
| 461 | `f_jit/src/bytecode/JsonConst_test.cj` | .cj | ✅ | — |
| 462 | `f_jit/src/bytecode/LocalTypes.cj` | .cj | ✅ | — |
| 463 | `f_jit/src/bytecode/LocalTypes_test.cj` | .cj | ✅ | — |
| 464 | `f_jit/src/bytecode/NameTable.cj` | .cj | ✅ | — |
| 465 | `f_jit/src/bytecode/OpInfo.cj` | .cj | ✅ | — |
| 466 | `f_jit/src/bytecode/OpInfo_test.cj` | .cj | ✅ | — |
| 467 | `f_jit/src/bytecode/Reject.cj` | .cj | ✅ | — |
| 468 | `f_jit/src/bytecode/SiteNameTable_test.cj` | .cj | ✅ | — |
| 469 | `f_jit/src/bytecode/SiteTable.cj` | .cj | ✅ | — |
| 470 | `f_jit/src/compiler/A4Frontend_test.cj` | .cj | ✅ | — |
| 471 | `f_jit/src/compiler/A5MapKey_test.cj` | .cj | ✅ | — |
| 472 | `f_jit/src/compiler/A64Exec_test.cj` | .cj | ✅ | — |
| 473 | `f_jit/src/compiler/A7JsonSet_test.cj` | .cj | ✅ | — |
| 474 | `f_jit/src/compiler/Acceptance_test.cj` | .cj | ✅ | — |
| 475 | `f_jit/src/compiler/AnyCastAux_test.cj` | .cj | ✅ | — |
| 476 | `f_jit/src/compiler/AnyCast_test.cj` | .cj | ✅ | — |
| 477 | `f_jit/src/compiler/AnyContainer_test.cj` | .cj | ✅ | — |
| 478 | `f_jit/src/compiler/AnyFrontend_test.cj` | .cj | ✅ | — |
| 479 | `f_jit/src/compiler/Assembler.cj` | .cj | ✅ | — |
| 480 | `f_jit/src/compiler/Assembler_test.cj` | .cj | ✅ | — |
| 481 | `f_jit/src/compiler/Ast.cj` | .cj | ✅ | — |
| 482 | `f_jit/src/compiler/AstM2_test.cj` | .cj | ✅ | — |
| 483 | `f_jit/src/compiler/AstShape.cj` | .cj | ✅ | — |
| 484 | `f_jit/src/compiler/Builder_test.cj` | .cj | ✅ | — |
| 485 | `f_jit/src/compiler/BytecodeBuilder.cj` | .cj | ✅ | — |
| 486 | `f_jit/src/compiler/Capture.cj` | .cj | ✅ | — |
| 487 | `f_jit/src/compiler/Capture_test.cj` | .cj | ✅ | — |
| 488 | `f_jit/src/compiler/CastOrParse_test.cj` | .cj | ✅ | — |
| 489 | `f_jit/src/compiler/ClassRegistryView.cj` | .cj | ✅ | — |
| 490 | `f_jit/src/compiler/ClassRegistryView_test.cj` | .cj | ✅ | — |
| 491 | `f_jit/src/compiler/CodeDump.cj` | .cj | ✅ | — |
| 492 | `f_jit/src/compiler/CompileCopy_test.cj` | .cj | ✅ | — |
| 493 | `f_jit/src/compiler/CompileSession.cj` | .cj | ✅ | — |
| 494 | `f_jit/src/compiler/Compiler.cj` | .cj | ✅ | — |
| 495 | `f_jit/src/compiler/ConstantReclaim_test.cj` | .cj | ✅ | — |
| 496 | `f_jit/src/compiler/DefiniteAssignment.cj` | .cj | ✅ | — |
| 497 | `f_jit/src/compiler/Diag.cj` | .cj | ✅ | — |
| 498 | `f_jit/src/compiler/DiffExec_test.cj` | .cj | ✅ | — |
| 499 | `f_jit/src/compiler/Golden_test.cj` | .cj | ✅ | — |
| 500 | `f_jit/src/compiler/JitWire_test.cj` | .cj | ✅ | — |
| 501 | `f_jit/src/compiler/JsonAccess_test.cj` | .cj | ✅ | — |
| 502 | `f_jit/src/compiler/JsonCode_test.cj` | .cj | ✅ | — |
| 503 | `f_jit/src/compiler/JsonLit_test.cj` | .cj | ✅ | — |
| 504 | `f_jit/src/compiler/Lexer.cj` | .cj | ✅ | — |
| 505 | `f_jit/src/compiler/Lexer_test.cj` | .cj | ✅ | — |
| 506 | `f_jit/src/compiler/Lowerer.cj` | .cj | ✅ | — |
| 507 | `f_jit/src/compiler/LowererM2_test.cj` | .cj | ✅ | — |
| 508 | `f_jit/src/compiler/Lowerer_test.cj` | .cj | ✅ | — |
| 509 | `f_jit/src/compiler/NameResolver_test.cj` | .cj | ✅ | — |
| 510 | `f_jit/src/compiler/Ops.cj` | .cj | ✅ | — |
| 511 | `f_jit/src/compiler/Parser.cj` | .cj | ✅ | — |
| 512 | `f_jit/src/compiler/Parser_test.cj` | .cj | ✅ | — |
| 513 | `f_jit/src/compiler/PerfCompare_test.cj` | .cj | ✅ | — |
| 514 | `f_jit/src/compiler/Pipeline_test.cj` | .cj | ✅ | — |
| 515 | `f_jit/src/compiler/PredefinedSnapshot.cj` | .cj | ✅ | — |
| 516 | `f_jit/src/compiler/Q6Compiler_test.cj` | .cj | ✅ | — |
| 517 | `f_jit/src/compiler/Semantics_test.cj` | .cj | ✅ | — |
| 518 | `f_jit/src/compiler/SourceCompiler.cj` | .cj | ✅ | — |
| 519 | `f_jit/src/compiler/SpecializationFmt_test.cj` | .cj | ✅ | — |
| 520 | `f_jit/src/compiler/StrictFpCodegen_test.cj` | .cj | ✅ | — |
| 521 | `f_jit/src/compiler/TemporalSurface_test.cj` | .cj | ✅ | — |
| 522 | `f_jit/src/compiler/Temporal_test.cj` | .cj | ✅ | — |
| 523 | `f_jit/src/compiler/Token.cj` | .cj | ✅ | — |
| 524 | `f_jit/src/compiler/TypeRef_test.cj` | .cj | ✅ | — |
| 525 | `f_jit/src/compiler/UnaryNotDiff_test.cj` | .cj | ✅ | — |
| 526 | `f_jit/src/compiler/UnaryNotShape_test.cj` | .cj | ✅ | — |
| 527 | `f_jit/src/compiler/X86Compile_test.cj` | .cj | ✅ | — |
| 528 | `f_jit/src/compiler/X86Exec_test.cj` | .cj | ✅ | — |
| 529 | `f_jit/src/macros/IgnoreJitBinding.cj` | .cj | ✅ | — |
| 530 | `f_jit/src/macros/JitBind.cj` | .cj | ✅ | — |
| 531 | `f_jit/src/macros/JitSignature.cj` | .cj | ✅ | — |
| 532 | `f_jit/src/refineUnload_test.cj` | .cj | ✅ | — |
| 533 | `f_jit/src/runtime/AnyHelpers.cj` | .cj | ✅ | — |
| 534 | `f_jit/src/runtime/AnyHelpers_test.cj` | .cj | ✅ | — |
| 535 | `f_jit/src/runtime/CanonKey_test.cj` | .cj | ✅ | — |
| 536 | `f_jit/src/runtime/DbgDump.cj` | .cj | ✅ | — |
| 537 | `f_jit/src/runtime/DbgDumpM2_test.cj` | .cj | ✅ | — |
| 538 | `f_jit/src/runtime/DbgDumpM3_test.cj` | .cj | ✅ | — |
| 539 | `f_jit/src/runtime/DbgDump_test.cj` | .cj | ✅ | — |
| 540 | `f_jit/src/runtime/HandleTable.cj` | .cj | ✅ | — |
| 541 | `f_jit/src/runtime/HandleTableGenExhaustion_test.cj` | .cj | ✅ | — |
| 542 | `f_jit/src/runtime/HandleTableM2_test.cj` | .cj | ✅ | — |
| 543 | `f_jit/src/runtime/HandleTableStripeConcurrency_test.cj` | .cj | ✅ | — |
| 544 | `f_jit/src/runtime/HandleTable_test.cj` | .cj | ✅ | — |
| 545 | `f_jit/src/runtime/HelperAddresses.cj` | .cj | ✅ | — |
| 546 | `f_jit/src/runtime/HelperCore.cj` | .cj | ✅ | — |
| 547 | `f_jit/src/runtime/HelperEntry.cj` | .cj | ✅ | — |
| 548 | `f_jit/src/runtime/HelperEntry_test.cj` | .cj | ✅ | — |
| 549 | `f_jit/src/runtime/HelperId.cj` | .cj | ✅ | — |
| 550 | `f_jit/src/runtime/Helpers.cj` | .cj | ✅ | — |
| 551 | `f_jit/src/runtime/Helpers_test.cj` | .cj | ✅ | — |
| 552 | `f_jit/src/runtime/HostCall.cj` | .cj | ✅ | — |
| 553 | `f_jit/src/runtime/HostCallTrampoline_test.cj` | .cj | ✅ | — |
| 554 | `f_jit/src/runtime/HostCallback_test.cj` | .cj | ✅ | — |
| 555 | `f_jit/src/runtime/HostFaultTls_test.cj` | .cj | ✅ | — |
| 556 | `f_jit/src/runtime/HostField.cj` | .cj | ✅ | — |
| 557 | `f_jit/src/runtime/HostFieldGet_test.cj` | .cj | ✅ | — |
| 558 | `f_jit/src/runtime/HostFieldSet_test.cj` | .cj | ✅ | — |
| 559 | `f_jit/src/runtime/HostFieldSnapshot_test.cj` | .cj | ✅ | — |
| 560 | `f_jit/src/runtime/Interp.cj` | .cj | ✅ | — |
| 561 | `f_jit/src/runtime/InterpHostCall_test.cj` | .cj | ✅ | — |
| 562 | `f_jit/src/runtime/Interp_test.cj` | .cj | ✅ | — |
| 563 | `f_jit/src/runtime/IterTable.cj` | .cj | ✅ | — |
| 564 | `f_jit/src/runtime/JitAnyBox.cj` | .cj | ✅ | — |
| 565 | `f_jit/src/runtime/JitContext.cj` | .cj | ✅ | — |
| 566 | `f_jit/src/runtime/JitContext_test.cj` | .cj | ✅ | — |
| 567 | `f_jit/src/runtime/JsonHelpers.cj` | .cj | ✅ | — |
| 568 | `f_jit/src/runtime/JsonHelpers_test.cj` | .cj | ✅ | — |
| 569 | `f_jit/src/runtime/PowHelper.cj` | .cj | ✅ | — |
| 570 | `f_jit/src/runtime/PromotionGroup.cj` | .cj | ✅ | — |
| 571 | `f_jit/src/runtime/PromotionGroupConcurrency_test.cj` | .cj | ✅ | — |
| 572 | `f_jit/src/runtime/PromotionGroup_test.cj` | .cj | ✅ | — |
| 573 | `f_jit/src/runtime/ReflectiveCall.cj` | .cj | ✅ | — |
| 574 | `f_jit/src/runtime/Runtime.cj` | .cj | ✅ | — |
| 575 | `f_jit/src/runtime/RuntimeEnv.cj` | .cj | ✅ | — |
| 576 | `f_jit/src/runtime/RuntimeState.cj` | .cj | ✅ | — |
| 577 | `f_jit/src/runtime/Signature.cj` | .cj | ✅ | — |
| 578 | `f_jit/src/runtime/SignatureDescriptor_test.cj` | .cj | ✅ | — |
| 579 | `f_jit/src/runtime/SignaturePlan.cj` | .cj | ✅ | — |
| 580 | `f_jit/src/runtime/SignaturePlan_test.cj` | .cj | ✅ | — |
| 581 | `f_jit/src/runtime/SignatureVerifier_test.cj` | .cj | ✅ | — |
| 582 | `f_jit/src/runtime/T40Account_test.cj` | .cj | ✅ | — |
| 583 | `f_jit/src/runtime/TextFormat.cj` | .cj | ✅ | — |
| 584 | `f_jit/src/runtime/ThreadLocalEnv_test.cj` | .cj | ✅ | — |
| 585 | `f_jit/src/runtime/UserHelper.cj` | .cj | ✅ | — |
| 586 | `f_jit/src/runtime/WindowIsolation_test.cj` | .cj | ✅ | — |
| 587 | `f_jit/src/surface/FacadeSurface_test.cj` | .cj | ✅ | — |
| 588 | `f_jit/src/test/ReflectFixtures.cj` | .cj | ✅ | — |
| 589 | `f_jit/src/test/TCase.cj` | .cj | ✅ | — |
| 590 | `f_jit/src/test/Test.cj` | .cj | ✅ | — |
| 591 | `f_jit/src/test/diff/DiffHarness.cj` | .cj | ✅ | — |
| 592 | `f_jit/src/test/diff/RealRunners.cj` | .cj | ✅ | — |
| 593 | `f_jit/src/test/diff/TCoverage.cj` | .cj | ✅ | — |
| 594 | `f_jit/src/test/diff/diff_test.cj` | .cj | ✅ | — |
| 595 | `f_jit/src/userapi/UserApi_test.cj` | .cj | ✅ | — |

合计：`.cj` 305 个 / `.md` 290 个 / 共 595 个，全部读完。

## 覆盖自检

### 第 1 部分

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

### 第 2 部分

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 12 | 文档承诺与实现不一致的契约类问题：#2 生命周期名、#3 分发入口、#4 `CallContext`、#6 桥内机制、#7 后端结构、#9 注销语义、#10 失败 kind、#11 卸载窗口、#13 编译期递归、#14 pin 身份、#15 容量配置并发、#16 卸载顺序矛盾。安全性方面核对了 §2.3.7 sink 异常、§5.3.1 非托管内存、§6.3.2 W^X/IBT 表述，未发现夸大；未发现注入/越权面 |
| §1 死代码 | 3 | 文档描述、生产中无消费者的 3 个非对外符号：`JitValue`（顶层 `protected`，只定义 + `Root.cj:21` 注释，#6）、`AdapterRegistry`（顶层 `protected`，仅测试引用，#6）、`CompiledSourceUnit.fingerprint`（`protected struct` 的 `public` 字段，全仓无读取，#20）。`SourceUnit` 虽然仓内只被测试引用，但它是**对外可达的 `public`**（`base` 包的 `public struct`），按硬原则一**不判死代码**，其问题只作为 #3 的契约缺口记录 |
| §2 重复逻辑 | 3 | ① 同一指纹口径在 §3.3.8（FNV-128 + 二次校验）与 §4.3.9（`UInt64`）两处定义且漂移（#20、#5）；② ISA 路由表在 §B.9/B.10 与 §C.4 各写一份，已出现 0xBE 归组不一致（#18）与 HW_CLOSE 注记缺失（#19）；③ helper 编号表在 §5.3.4 / B.7 / C.4 / 附录 D 四处维护，73–76 未回填（#26）。文档头部自承「同源摘录自规格」，属有意复制，但未建立同步机制 |
| §3 空实现 | 2 | 文档承诺、实现为空的机制：二次字节校验（`DedupGuard` 无调用者，#5）与诊断事件（`JitFallback`/`MmapFailed` 无发射点，#8）。`.md` 本身无空函数体 |
| §4 栈溢出 | 2 | ① `STACK_GUARD` 只护帧内操作数栈、错误码 15 无生产者，设计 A.7/C.4 的「进入/回退解释器写 15」安全论证不成立（#1/严重；递归深度本体与 part1 #5 同根因，合并时保留一条）；② 编译期递归下降没有嵌套上限（#13/一般） |
| §5 OOM | 1 | §7.3.5 的失败缓存无淘汰（#22/轻微）：按源码无界，实现以 256 条兜底但文档未记。句柄表/常量镜像/代码内存在设计里都是有界或与单元同生命周期，未发现第二处无界承诺 |
| §6.1 热点瓶颈 | 0 | 本部分无 profile / bench / 分段计时数据；3 条疑似热点已进「待验证假设」，不写成发现 |
| §6.2 大粒度锁 | 0 | 文档未把 `diag` 回调画成锁内路径；实现 `Compiler.registerType` 在 `mtx` 内调 `diag`（`Compiler.cj:138/153`），但已现场核对仓颉 `std.sync.Mutex` 为**可重入**锁（1.3.0 `sync_package_api`「提供可重入互斥锁…可再次获得该锁」），同线程回调不会自锁，缺跨线程阻塞证据，故不成立 |
| §6.3 并发串行 | 0 | 文档无 `spawn` 后立即 `get()`、批大小=1 或单消费者描述；同键等待是忙等退避而非串行提交，已进待验证假设 1 |
| §6.4 低效算法 | 0 | 附录 B/C 是 O(1) 分派表，无嵌套循环 / `contains` / `remove(at:0)` 类描述；`CompilePipeline` 的重复指纹计算已计入 #20，不重复 |
| §7 降堆内存方案 | 0 | 无堆占用数据（对象数/字节量/生命周期），按要求不提案；`DedupGuard`/`SourceUnit` 的删除属死代码清理，不是内存优化 |
| §8 降 CPU 方案 | 0 | 无改前基线；候选（失败缓存淘汰、注册锁外化）只进待验证假设 |
| §9 local mode 可行性 | 0 | design-m1 未涉及 local mode，也无峰值内存数据；不满足「改前/改后峰值对照」的前置条件 |
| §11 现有代码的 BUG（存量） | 5 | #10（同键失败丢失异常 kind）、#11（`compile` 返回 `Unloading` 单元）、#14（`pin` 身份契约与实现相反）、#15（容量配置的读写竞争）、#16（卸载顺序注释与状态机互斥）；均为读文档追到代码时确认的现有逻辑/契约问题，非纯措辞 |
| §12 并发安全与锁粒度 | 3 | #11：`CompileCache.ready` 与 `JitFunction.state` 属两个同步域，`lookup` 不检查状态即发布句柄（共享路径：cache ready 表 → 返回的 `JitFunction` → `enterUnit` 的 19）；#15：`initialCapacity`/`capacityLimit` 设计为无同步 `static var` 却允许运行中调整；#16：卸载释放的前置条件自相矛盾，照注释实现会提前释放代码内存。`CompileCache.finish` 的 H1 锁序与 `close` 的「单元锁 → 缓存锁」方向已核对，无 ABBA |
| §13 文档一致性 | 26 | 本部分主体结论：#1–#26 全部为文档与实现/文档内部的对照 |
| §14 功能完备性与 README 覆盖 | 4 | #3（分发入口未实现）、#5（二次校验未接线）、#8（诊断接线缺失）、#12（再导出清单未落地）。`SourceUnit` 同时是「public 但无消费路径」的索引缺口 |
| 文件覆盖（§13 等） | 1/1 | 本部分清单 1 个文件全部读完，无缺失 |

### 第 3 部分

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 0 | 三份均为设计文本，无可执行逻辑；「设计合理性」已按文档承诺 vs 实现（§13/§14）覆盖，命中见 #1–#13；无外部输入、无凭据与注入面 |
| §1 死代码 | 0 | 已把文档中出现的每个符号在 `src/` 全量检索：根包包装 `JitClosure`、`callWith`、`CFunc` 三条旧名在 `src/` 中已无定义（`grep "class JitClosure"` 只命中 `runtime/HandleTable.cj:1458` 的 **M1 内部闭包类**，与 §6.1.4 撤销的根包包装是同名的不同概念，属命名信息、非死代码）；`ClassRegistry.classOfField`、`SignatureTable.plan/size`、`H_ANY_BOX` 无实现但**属文档不符**，已归入 §13（#3 #9 #10），不重复计为死代码 |
| §2 重复逻辑 | 1 | 同一事实在正文/附录/决策表多处重复并已漂移：helper 编号（§5.0 叙述 / §5.4 表 / §5.1 / 附 B），单列为 #3（判据含 §2）；验签口径的重复（§5.1.2 / §9 / §10 / §11）归入 #4，不重复计数 |
| §3 空实现 | 0 | 三份文档无 `TODO`/`FIXME`/空承诺段落；唯一的「待实施」是 M3-5，经核对两项待办均已实现，按 §13 记 #11 |
| §4 栈溢出 | 0 | 文档描述的递归面（JSON 嵌套、链式成员访问、`TypeRef` 链）均为**前端编译期**且 design-m3 §4 明确括号配平为迭代取界；运行期无递归算法描述。无命中 |
| §5 OOM | 0 | 已核对文档给出的有界性主张：`SignatureTable` 实现有 `MAX_ENTRIES=128`（`SignaturePlan.cj:138`），`HandleTable` 分片空闲表定长目录 + 容量上限；文档 `design-m3.md:133`「天然有界」措辞不精确但结论成立，未达发现级 |
| §6.1 热点瓶颈 | 0 | 文档自带两组数据但均无「同环境改前/改后对照」，不构成发现，已列入「待验证假设」#1 #2 |
| §6.2 大粒度锁 | 0 | 文档结论为「调用链不再有任何每调用一次的全局锁」，代码侧 `HandleTable.cj:86` 分片锁、`RuntimeEnv` TLS 与之相符；本部分无新增锁热点证据 |
| §6.3 并发串行 | 0 | 8 线程比 4 线程低（1.91× < 2.40×）只说明存在超订/串行信号，缺独占核线程状态证据，未定为并发串行缺陷；已列入待验证假设 #1，#2 只记「门槛与结论不一致」 |
| §6.4 低效算法 | 0 | 文档描述的热路径算法（helper 直调、plan 直通、argc≤4 展开）无复杂度问题；`SignatureTable` 线性扫 + 128 上限属有界小表，无热点证据 |
| §7 降堆内存方案 | 0 | 设计文档不持有对象；`PromotionGroup`/窗口记账的生命周期主张（`design-m2.md:463`、`design-parallel-call.md:122-127`）与实现一致，未见额外副本，无方案可提 |
| §8 降 CPU 方案 | 0 | 同上；唯一候选（反射路径占比）缺数据，见待验证假设 #2 |
| §9 local mode 可行性 | 0 | 三份文档未涉及 local mode，模块内也无「函数内大对象 + 峰值内存」证据，收益无法证明 |
| §11 现有代码的 BUG（存量） | 0 | 本部分无 `.cj`，11 条缺陷全部来自文档契约（§13/§14），代码侧存量 BUG 计 0；为取证读到的实现（`Signature.cj`、`HostCall.cj`、`AnyHelpers.cj`、`JsonHelpers.cj`、`JitFunction.cj`、`HandleTable.cj`）未发现需计入本部分的存量缺陷，撞见的注释/默认值问题见「范围外提示」 |
| §12 并发安全与锁粒度 | 0 | 已核对 `design-parallel-call.md` 的 D2/D3/D3b/D3d/D6 去锁依据（所有权 + 发布后不可变、线程私有记账、提升槽只读）与实现一致（`FreeStripes`、`ThreadLocal`、`AtomicReference<PlanSnapshot>`），未发现同步缺失或锁顺序问题；`SignatureTable.enabled` 是 `public static var` 无同步读，但只作测试/宿主开关且为单值 Bool，未达发现级；文档状态与实测问题归 #1 #2（§13） |
| §14 功能完备性与 README 覆盖 | 2 | #6（M2.2/M2.3 增量未进声明总览）、#11（已完成项仍记待实施）；本部分不含 README，`README` 覆盖留给其他部分 |
| 文件覆盖（§13 等） | 3/3 | 无缺文件；`files/f_jit.part3.txt` 三行逐行对应 |

### 第 4 部分

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 18 | 正确性：#1/#4/#5/#6/#7/#8；设计/契约：#2/#3/#9/#10/#16/#18；语言特性：#15（仓颉无引用相等 ⇒ 文档 pin 契约不可实现）；可读性：#13/#17；安全性：文档不涉凭据/注入/越权，无命中 |
| §1 死代码 | 1 | 文档无代码符号，"死"按「声明的机制是否有实现/消费」判：4 个伪指令 0 命中、`CtxFlags.HAS_LOOP` 只定义不写不读、`H10/H21/H23` 全仓零调用、`RET_NULL` 与 `RET_VOID` 同效、`MAX_FIXED` 无引用且过期——合并为 #12 与 #11 |
| §2 重复逻辑 | 1 | 逐组比对 6 组副本：opcode 表（§10.3 ↔ `OpInfo.cj`，`CALL_HOST` 编码冲突 → #4）、helper 表（§6 ↔ `HelperId.cj`，值域过期 → #11）、失败码表（§5/§6 ↔ `Helpers.cj`，11/12 不可达 → #14）、规范正文 4 组多副本（→ #17）。`LocalType`/`TypeToken`/容器头/站点表/名字表逐项核对一致，未计 |
| §3 空实现 | 1 | §7 伪指令是纯文档声明（实现无汇编源层）；`HW_CLOSE`（0x7B）在 `src/backend/X86Lower.cj:1056` 为 `case 0x7Bu8 => ()` 而 0x7A 走 `bail(18)`，属静默空实现且加载期不拦——并入 #12 |
| §4 栈溢出 | 1 | 非尾递归无深度检查、互递归同（#18）；尾位置由帧复用回边覆盖（实现与 §8.0 一致） |
| §5 OOM | 1 | 句柄表 2^20 上限 +「逃逸槽不重用」的字面读法 ⇒ 单调增长至 16（#9）；无「按不可信长度预分配」（`nLocals/maxStack` 均编译期常量） |
| §6.1 热点瓶颈 | 0 | 唯一热点有数据（97.7%/44×）且已实现，不重复计为缺陷；x86 侧无数据 → 待验证假设 #1 |
| §6.2 大粒度锁 | 0 | 本部分无代码；文档唯一锁面是句柄槽追加/逃逸登记，实现已分片（`HandleTable` 64 分片 + 冷路径锁），无大锁证据 |
| §6.3 并发串行 | 0 | 无 `spawn + get` / 单消费者模型；并发调用各自独立 ctx 与窗口 |
| §6.4 低效算法 | 0 | 规范层无循环内 `contains`/`remove(at:0)`/重复解析；`PUSH_KH` 常量化与正则「加载期一次编译」已是预计算形态 |
| §7 降堆内存方案 | 0 | 无代码可改；对象生命周期已由 §8.1 矩阵限定，唯一可量化收益是槽归属收敛，已并入 #9 建议 |
| §8 降 CPU 方案 | 0 | 唯一有基线的项（回边安全点）已实现，见「优化可行性方案」说明 |
| §9 local mode 可行性 | 0 | 文档未涉及 local mode，本部分无函数级临时对象可评 |
| §11 现有代码的 BUG（存量） | 18 | 本部分 18 条全部为存量（快照模式无基线），证据均来自本轮逐条读取 + 实现比对；其中 #1/#4/#5/#6/#9/#10/#14/#15 是「契约与实现不符」，#2 是「承诺的公开入口不存在」，其余为文档过期/结构错/内部矛盾 |
| §12 并发安全与锁粒度 | 1 | 命中 #9（句柄槽跨线程归属、`gen` 复用规则）；另有一句说明：#8.7 未写「状态断言与 `activeCalls` 递增必须在同一临界区」，实现已在同一把锁内完成（`src/JitFunction.cj:198-206`），故不单列为缺陷 |
| §14 功能完备性与 README 覆盖 | 3 | #2（分发入口不存在于公开面）、#3（`unload`/`isUnloaded`/`init`/`unregisterFunction` 漂移）、#12（伪指令与加载期 token 校验未落地）。README/public 声明覆盖由第 1 部分审 |
| 文件覆盖（§13 等） | 1/1 | 无缺文件；`doc:3` 单行超限已注明 |

### 第 5 部分

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 13 | 本部分为规格文档：正确性=规格与实现/自查的一致性（#1–#13）；设计=作用域与隔离（#4）、提升组输入闭环（#13）；语言特性=「`is` 能否做 14 的类名比对」已按 v0.8.33 订正核对（#2）；可读性=编号与重复（#5、#14–#17）；安全性=12 型字段绕过逃逸禁令（#1） |
| §1 死代码 | 1 | 本部分无 `.cj`，无 `private/internal/protected/public` 符号可判；按「每个被引用的章节/ID 是否有定义」机械过了一遍：v0.8.34 的 H77/as/`@JitSignatures` 只有变更记录、正文无定义（#6），计 1 条孤儿承诺；其余 § 锚点均有正文 |
| §2 重复逻辑 | 1 | `PublicField` 在 :337/:377/:419 三处逐字重复且都缺 `sig*`，§13-8 与 §14 的备选路线整段重复（:492 与 :522），已实际漂移（#5）；§13-8 自标「正式条款见 §14」，属有意留档，不另计 |
| §3 空实现 | 0 | 全文无 `TODO`/`FIXME`/`throw Unsupported`/空函数体；唯一「跳过」是 GAP-13 的引用型方法绑定默认拒绝（#6），属实现限制而非空实现，已按功能缺口报 |
| §4 栈溢出 | 1 | H63 重入链无深度/余量检查，`STACK_GUARD` 只覆盖循环回边（#7）；崩溃阈值列入待验证假设 #1 |
| §5 OOM | 0 | 规格侧无按不可信长度预分配、无无界容器；句柄型字段读导致窗口增长属有界（`capacityLimit` 封顶），列入待验证假设 #4；12 型字段属生命周期逃逸而非 OOM（#1） |
| §6.1 热点瓶颈 | 0 | 本部分无源码 profile；§8 的 4.6–5.8× 只覆盖反射路径，已列入发现 #6 与待验证假设 #2，不作为热点结论 |
| §6.2 大粒度锁 | 0 | 本部分无锁相关代码；字段表为原子快照发布（读不取锁，`HostField.cj:121-133`），未见「锁内 I/O」类描述 |
| §6.3 并发串行 | 0 | 无 `spawn`/批处理描述 |
| §6.4 低效算法 | 0 | 字段表按 index 分桶线性查找属实现侧，且无数据，列入待验证假设 #5 |
| §7 降堆内存方案 | 0 | 无源码，无法给对象数/字节量现状；不产出无基线方案 |
| §8 降 CPU 方案 | 0 | 同上；已有基线为反射路径，已被实现超越，只能进待验证假设 #2 |
| §9 local mode 可行性 | 0 | 纯规格文档，无函数内临时大对象；逃逸分析无从谈起 |
| §11 现有代码的 BUG（存量） | 13 | 规格与实现不符的存量项：#1（12 型字段）、#2（`is`/P1）、#3（`close`/`unload`）、#4（注册表作用域）、#5（结构定义）、#6（M2.1–M2.3/版本）、#7（重入深度）、#8（错误码）、#9（继承访问器）、#10（HostObject 定义）、#11（`registerType` 签名）、#12（CALL_HOST 栈序）、#13（捕获描述符）；全部标 `[存量]` |
| §12 并发安全与锁粒度 | 1 | 字段访问器表为进程级共享静态状态，规格写「Compiler 实例内」且未定义并发注册纪律（#4） |
| §14 功能完备性与 README 覆盖 | 2 | §12.5 承诺的继承访问器能力未实现（#9）；已交付的 M2.1/M2.2/M2.3 能力（adapter/plan、GAP-13 例外、H77/`@JitSignatures`）未进规格（#6）。本部分无 README，未做 README 覆盖对照 |
| 文件覆盖（§13 等） | 1/1 | `f_jit/doc/jit-bytecode-m2.md` 全文读完；第 3 行 7120 字符版本历史亦分段读取 |

### 第 6 部分

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 5 | 正确性=容器转型与容器类型判定（#1）；设计=`SignatureTable` 作用域与开关（#2/#3/#8）；语言特性=「泛型实参参与 `is` 判定」已按 §9.1 实测结论核对，但「键型可判」不成立（#1）；可读性=索引/行号/模板残留（#13/#14）；安全性=Any 沙箱的类型边界被弱化（#1） |
| §1 死代码 | 0 | 本部分无 `.cj`，无 `private/internal/protected/public` 符号可判。文档侧逐节核对「承诺后未接线」：§12/§13 的每条裁定都能在 `src/` 找到落点（H78–H83、LocalType 16–19、`SignatureTable`、`MAX_ENTRIES`、T56/T61 用例），唯一缺口是缺失的测试护栏（记在 §14）。另记一条范围外提示：`CallMarshal.makeRetUnboxer`（`f_jit/src/CallMarshal.cj:187-189`）位于 `protected class` 内、只有测试调用，文档也自述「保留给测试」——属可见性问题，不按死代码计 |
| §2 重复逻辑 | 2 | 两份 `optimize-*.md` 重复定义同一套实验硬规则且已漂移（#15）；A64/x86 审计表两套隔离机制（#16）。文档内 `PublicField` 类重复已在上部分（part5）报过，本部分不重复计 |
| §3 空实现 | 0 | 五篇文档无 `TODO/FIXME/throw Unsupported`；§4 决策日志的空 C3 行是模板残留，计在 #14，不按「空实现」计 |
| §4 栈溢出 | 0 | 本部分无递归/自引用结构描述；m3 §13 的 H63 重入链已在 part5（m2 规格）报过，本部分不重复计 |
| §5 OOM | 1 | 无无界增长：JSON 常量有 16 MiB + 空串硬拒（`ConstRegistry.cj:258-268`），签名表有 128 上限。命中项是「上限未写进文档」（#17） |
| §6.1 热点瓶颈 | 0 | 文档内的性能结论都自带测点（`cjprof`/分段计时/同进程 A/B）。本部分未给出可复核数据的新热点只有 #7 的成本转移，已降为「待验证假设 #1」，不作发现 |
| §6.2 大粒度锁 | 0 | 台账已逐项拆锁（HostFault TLS、字段快照、句柄分片、签名两表、helper 表缓存），未见「锁内 I/O/回调」类描述；`SignatureTable.writeMtx` 内只做数组拷贝与发布 |
| §6.3 并发串行 | 0 | 已核对 `spawn` 用法（`ParallelThroughput_test` 先提交后统一 `get()`），无「spawn 后立刻 get」形态 |
| §6.4 低效算法 | 0 | 台账已覆盖线性扫标签、逐字节搬运、字符串键索引等，并给出「小表线性扫更快」的实测反证（`optimize-call-path.md:479-491`） |
| §7 降堆内存方案 | 0 | 无源码可改；plan 表 ≤128 条、helper 表按单元缓存，均已有界，无「缩短生命周期/去副本」的量化空间 |
| §8 降 CPU 方案 | 0 | 台账结论为「进入测量分辨率以下」（`optimize-call-path.md:635-639`）；本轮未取得新的同环境 A/B 数据，不产出方案 |
| §9 local mode 可行性 | 0 | 纯文档，无函数内临时大对象；台账里每次调用的 `Win`/`Array<Any>` 属桥接层，改造收益只能用峰值内存证明，缺数据 |
| §11 现有代码的 BUG（存量） | 22 | 全部为「文档承诺 vs 实现/测试」类存量问题：#1–#22，均标 `[存量]`（快照模式无 baseline） |
| §12 并发安全与锁粒度 | 1 | `SignatureTable.enabled` 是进程级非原子开关、在每次 `getOrBuild` 上读，并发切换语义未定义（#3）。其余共享点（字段表、签名表快照、句柄分片）均为原子快照/双检发布，已核 |
| §14 功能完备性与 README 覆盖 | 3 | 承诺的容器键值校验未实现（#1）；T56 的构建计数断言在超限后失效（#2）；`ParallelThroughput_test` 的 `isJitBacked` 断言未落地（#6）。本部分无模块 README，未做 README 覆盖对照 |
| 文件覆盖（§13 等） | 5/5 | 5 个 `.md` 全部逐行读完；`jit-bytecode-m3.md:3` 的 10 992 字符变更行分段读取，无遗漏 |

### 第 7 部分

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 1 | 发现 #1（契约与实现不符）。语言特性面逐项核对：`CallContext` 唯一字段 `deadline` + 构造后只读、`call` 同名双载重、`Resource` 的 `close`/`isClosed`、`protected` 枚举不外泄——均与文档一致；本部分无外部输入，无注入/凭据面 |
| §1 死代码 | 0 | 文档无代码，做等价机械检查：以反引号引用的 30+ 路径/符号逐个解析，`design-m1/m2/m3.md`、`jit-bytecode-m1/m2/m3.md`、`doc/perf-m2.md`、`doc/spec/f-jit-m2/`、`src/surface/FacadeSurface_test.cj`、`src/test/diff/TCoverage.cj`、`src/runtime/ReflectiveCall.cj`、`src/runtime/Signature.cj`、`src/Q6DiffCoverage_test.cj`、`src/PerfM2_test.cj`、`src/compiler/X86Exec_test.cj`、`scripts/check_tmap.sh`、`scripts/check_scenarios.sh` 全部存在；`.md` 中无 `](...)` 超链接，故无死链；唯一「文中出现但全仓无此符号」的 `lastClosureGroup` 落在归档 delta，见下方第 13 行说明 |
| §2 重复逻辑 | 0 | 两件机械比对：① 四份归档 delta 的 spec 文本互相比对——`align-call-entry-spec/.../spec.md:7` 与 `close-f-jit-out-of-checklist-findings/.../spec.md:53` 同文，属 OpenSpec MODIFIED 需求必须整段重述的格式要求，不是可合并重复；② 三份计划的总则——`plan-m2.md:15`、`plan-m3.md:15` 写「其余总则同 plan-m1.md §0」而非复制，无大段复制。两份「纯规格对齐」变更（align-base-contracts / align-call-entry-spec）目标不同，不构成合并候选 |
| §3 空实现 | 0 | 文档层等价检查：各 `tasks.md` 的勾选项都能在 `verify.md` 找到数值结论（5 例并发用例、1115、1127、1253），无"勾了但无验证依据"项；plan-m1 S7.8「文档同步」如实未勾 |
| §4 栈溢出 | 0 | 文档不承载递归实现；plan-m1 S3.16 的尾位置降低只描述发射规则，未承诺无界深度 |
| §5 OOM | 0 | 本部分未承诺任何容器/缓存规模；窗口与句柄表容量语义在源码部分 |
| §6.1 热点瓶颈 | 0 | 本部分无 profile/bench 数据；plan-m1 §5 的 43.8× 是单机型单次记录（含编译），不足以支撑热点结论，已入待验证假设 #2 |
| §6.2 大粒度锁 | 0 | 无「临界区内做 I/O / 解析 / 回调」的文档描述可判；发现 #1 的"每轮自旋取锁"按缺陷计（§12.1），其性能影响入待验证假设 #1 |
| §6.3 并发串行 | 0 | 文档未承诺批大小/并发度；归档 delta 里「`callForFn` 整段串行」已被后续并行化变更取代（见第 13 行） |
| §6.4 低效算法 | 0 | 本部分不描述算法实现；`timeoutMs*100000` 的自旋复杂度已在发现 #1 说明 |
| §7 降堆内存方案 | 0 | 纯文档部分，无持有对象/生命周期可评 |
| §8 降 CPU 方案 | 0 | 唯一候选（自旋排空）已作为发现 #1 的修法，避免同根因重复计数 |
| §9 local mode 可行性 | 0 | 无函数级临时大对象描述，也无峰值内存数据 |
| §11 现有代码的 BUG（存量） | 1 | 发现 #1（`timeoutMs` 语义与实现不符）；#2–#5 为文档缺陷，计入 §13/§14 |
| §12 并发安全与锁粒度 | 1 | 发现 #1（无时钟源的忙等 + 每轮取同一 `mtx`，与在飞调用退出路径争锁）。正向核对：`CompileCache.claim` 三集合去重（`src/CompileCache.cj:60-69`）、`UserHelperTable` 的 `ThreadLocal` 栈（`src/runtime/UserHelper.cj:53-63`）与文档描述一致 |
| §13 文档一致性（专项） | 4 | 发现 #1 #2 #4 #5；另核对并**排除**一条：`align-call-entry-spec/.../spec.md:7` 的「`callForFn` 整段持单元锁 + `lastClosureGroup` 不残留」已被 `feat-f-jit-parallel-call` 的 P3（删 `callMtx`，改按调用 `CallOut`）取代，但该文件是已归档变更的 delta，按 checklist §13 误报边界「按当时结论是否自洽核对」判定不构成当前缺陷，仅记一句提示 |
| §14 功能完备性与 README 覆盖 | 2 | 发现 #3（计划总览与步骤清单不符）、#4（骨架/依赖/宏入口未登记）；本部分不含 `README.md` / `README_en.md`，public API 的 README 覆盖留给对应部分 |
| 文件覆盖（§13 等） | 20/20 | 无缺文件；命中问题的文件 4 个：`plan-m1.md`、`plan-m2.md`、`plan-m3.md`、`align-jitfunction-close-naming/design.md` |

### 第 8 部分

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 5 | #1（设计前提与 ISA 不符）、#3（验收证据无效）、#4（键域不单射，正确性）、#5（登记表漂移）、#8（可见性契约与实现不符，设计/安全性）；本部分无外部输入与凭据面 |
| §1 死代码 | 1 | 文档层面的「死分支」：#2 按规格阈值推得的 deopt 分支不可达，已并入 #2；另逐个核对文档引用的符号是否仍存在（`unloadFn`/`unload` 只存于历史归档、`invoke` 已被 `call` 重载取代、`constMapFloatKeyHitWithBoxedKey` 不存在），除 #5 外无「文档引用已删除符号」 |
| §2 重复逻辑 | 1 | `tasks.md` 与 `test-plan.md` 两张用例表复制后漂移（#5）；另核对 `CanonKey.i64` 与 `cell` 函数体逐字相同、`Version.LATEST` 字面量复制 `M3_MAJOR`（#4/#7 已列） |
| §3 空实现 | 0 | 本部分无函数体；「承诺有行为但实现为空」的唯一候选是 A64 回边守卫（形式上发了指令，语义为空），已按 §13/§4 记入 #1，不重复计 §3 |
| §4 栈溢出 | 1 | #1：A64 侧余量守卫恒不触发，等于没有守卫（重入链缺深度守卫已由 part1/part5 统计，不重复） |
| §5 OOM | 0 | 本部分无容器/预分配/缓存持有描述；键域塌陷是错值不是增长，已归 #4 |
| §6.1 热点瓶颈 | 0 | 无本轮 profile/bench 数据；`doc/optimize-call-path.md:411` 的 662→15 ns/轮 是既有基线，只能支撑「待验证假设 #1」，不足以支撑热点结论 |
| §6.2 大粒度锁 | 0 | 文档未引入新的锁结构；`close` 自旋取锁已由 part7 报告 |
| §6.3 并发串行 | 0 | `callForFn` 的串行化条款属 part7；`clarify-last-escaped-scope` 反而消除了「锁外写单元字段」的竞争点（已核对代码），无新增串行段 |
| §6.4 低效算法 | 0 | 无算法描述；回边守卫是固定 4–6 条指令，未测占比，不判 |
| §7 降堆内存方案 | 0 | 文档无对象持有/生命周期可量化描述 |
| §8 降 CPU 方案 | 0 | 唯一候选（回边守卫指令）缺占比数据，列入待验证假设 #1 |
| §9 local mode 可行性 | 0 | 本部分无函数内临时对象描述；`f-jit-m1/design.md` 的 D6 已选择「非托管 malloc + 访问器」，与 local mode 方向不冲突也不收益 |
| §11 现有代码的 BUG（存量） | 2 | #1（A64 守卫空操作 + 文档错误归因，含 `0x07` 同型）、#4（键域塌陷导致错值）；均按文档承诺面报，代码侧定级留给对应部分 |
| §12 并发安全与锁粒度 | 0 | 已核对 `clarify-last-escaped-scope` 声称的三处改动全部落地（写锁内、读加锁、注释口径），未发现新的共享可变状态；`close` 自旋排空属 part7 |
| §14 功能完备性与 README 覆盖 | 2 | #5（X2-c 用例承诺但不存在）、#6（`verify.md` 承诺但不存在）；本部分不涉及 README |
| 文件覆盖（§13 等） | 20/20 | 无缺失 |

### 第 9 部分

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 0 | 本部分无 `.cj`，无运行时语义可判；文档声称的类型码表（LocalType/TypeToken）、错误码表（1–20/23/99 + M2 的 21/22）、版本常量、容器头布局、缓存键组成已逐项落地比对，差异只出现在用户面清单与缓存键口径（见 #1/#2） |
| §1 死代码 | 0 | 文档无声明可判；做了等价机械检查：文档点名的每个符号 / 路径逐个在 `src/` 解析，均有实现（`Version.MAJOR/MINOR/HDR_SIZE`、`FuncDir.SIZE=26`、`CompileCacheKey{arch,cpuFeatures,fingerprint}`、`ClassDescriptor.parents`、`JitBindings.withOverrides`、`PublicCtor`、`RegistrationRejectKind.JsonFamily`、`ReflectRegistrar.mapType`、`Interp.CALL_FUNC`）。唯一解析不到的是 `HandleTable` 的**用户面可达性**（存在但未再导出），已按 #1 记为契约问题而非死代码 |
| §2 重复逻辑 | 0 | 已比对 9 份 M1 spec 的 requirement 标题/条文与 M2.1、M2.2 镜像：重复项仅为「MODIFIED 条文沿用 M1 原文」（镜像体例要求）与 `design.md` 的 4 条不变量模板（两处逐字相同），属 §2 误报边界内的刻意展开；`proposal.md` 的 What Changes 与 `design.md` 决策摘要逐字重复，同样属模板，不判 |
| §3 空实现 | 0 | 20 份文档无 `TODO` / 占位段落 / 「暂不支持」；唯一「勾了但没做完」的形态是 tasks 的完成口径（#5），已按 §14 归类 |
| §4 栈溢出 | 0 | 文档无递归实现可判；但规格未约定字节码递归深度上限，实现侧 `Interp.CALL_FUNC`/`runClosure` 为宿主递归 —— 已记入范围外提示，交给运行期部分定级 |
| §5 OOM | 0 | 文档给出的有界性承诺（窗口触顶 16、窗口倍增、迭代器条目 ≤ 嵌套深度、容器常量去重）与 tasks S4.3/S4.6 一致，未发现「按不可信长度预分配」被写成规范的地方 |
| §6.1 热点瓶颈 | 0 | 本部分只有历史性能记录（`verify.md:158`、`:170`、`:255`），无 profile 自耗时占比；不据此下热点结论，已列入待验证假设 #2 |
| §6.2 大粒度锁 | 0 | 规格只承诺「注册与查找支持并发」（facade spec:81），临界区内容属实现；`verify.md:164` 已记录 JIT 全局串行（`envMtx`/`callMtx`）为已知工程债，本部分无法测持有时间 |
| §6.3 并发串行 | 0 | 同上；`verify.md:211` 建议改 per-call 隔离，属实现层任务，文档侧已如实登记，不重复计缺陷 |
| §6.4 低效算法 | 0 | 无代码；文档未对复杂度作可判定的承诺 |
| §7 降堆内存方案 | 0 | 文档层无可执行对象；`verify.md:152` 的「常量句柄泄漏 / 调用窗口泄漏」修复记录属实现部分 |
| §8 降 CPU 方案 | 0 | 仅 `verify.md:257`–`:259` 记录 H22 每回边分配数组（约 120 ns/迭代）待优化，位置在 `X86Lower`/helper，属实现部分，本部分不另提方案 |
| §9 local mode 可行性 | 0 | 本部分无函数体可做逃逸检查；`scope.md` 提到的 `docs/LocalMode.md` 是仓库级文档，不在本部分清单内 |
| §11 现有代码的 BUG（存量） | 10 | 本部分 10 条发现全部为存量（快照模式无基线）；其中 2 条一般（用户面契约、缓存键定义）、8 条轻微（数字/路径/步骤/验收记录/笔误/M2 镜像字段清单） |
| §12 并发安全与锁粒度 | 0 | 文档只描述并发承诺（适配器注册表并发、编译去重恰好一次、卸载排空），无法据文档判「不安全」；`verify.md:164`、`:175`、`:176` 已自陈排空与交错无用例，属已登记缺口 |
| §14 功能完备性与 README 覆盖 | 2 | #5（tasks 全勾 vs 未完成项）、#8（m2.2 缺验收记录）；本部分不含模块 README，`README` 覆盖检查留给含 README 的部分 |
| 文件覆盖（§13 等） | 8 | 20/20 全部读完；§13 命中 #1、#2、#3、#4、#6、#7、#9、#10（另 #5、#8 计入 §14） |

### 第 10 部分

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 12 | 12 条发现均为「文档契约 ↔ 实现」类（本部分无源码可判）；安全性无外部输入面 |
| §1 死代码 | 1 | 本部分无 `.cj` 符号，改为「文档声明的符号在仓内是否可达」：逐个全仓 grep `ClassDescriptor.parents`、`isSameOrSubclass`、`retName`、`JitHost.registerSignature`、`SignatureRegistry`、`$as$`、`CAST_FAIL`、`moveOutGroup`、`isLocalTypeInLegalSet`、`TCoverage`、`castor`、`callForFn` 共 12 个符号，均有实现；零命中的只有矩阵里的 `closeIsIdempotentAndReleasesGroup`（计入 #4）与 `callFor`（计入 #9，不重复计数） |
| §2 重复逻辑 | 1 | 机械比对 m2 / m2.2 / m2.3 三份镜像的 requirement 块：唯一逐行重复是 m2.2 `specs/f-jit-facade-bridge/spec.md:8-33` 对 m2 `:62-89` 的整段复制（仅 `callFor`→`callForFn`），并入 #9/#10；代码侧 `as`/`is` 的两份同源判定按「范围外提示」记，不占统计 |
| §3 空实现 | 1 | 两份 tasks 的「全量测试通过（见 `verify.md`）」无实体文件（#4）。无函数体可判 |
| §4 栈溢出 | 0 | 文档只承诺固定深度语义（`CALL_HOST` 重入 ≥3、构造嵌套一层），无「遍历用户可控结构」的递归条款；`$as$` 父链是 `while` + 64 层上限（范围外提示 4） |
| §5 OOM | 0 | 文档未承诺无界容器，窗口/提升组账目均写「每次至多 1 槽」；`SignatureRegistry` 规模由代码常量决定，未达「不可信长度」判据 |
| §6.1 热点瓶颈 | 0 | 无本部分相关的 profile；`verify.md:243` 只有闭包 vs helper 的比值，不足以定位热点，已转待验证假设 1–4 |
| §6.2 大粒度锁 | 0 | 文档只声明「句柄表操作有锁」「并发失败互不串扰」，未承诺锁内 I/O / 回调；临界区实现不在本部分 |
| §6.3 并发串行 | 0 | 文档无「并发度 = 1」类承诺；m2.2 的类型化快速路径本身是降低串行反射开销的方向 |
| §6.4 低效算法 | 0 | 文档无复杂度承诺；`$as$` 为 O(继承深度)、字段表 `accepts` 为 O(表项数)，均无规模数据（假设 3/4） |
| §7 降堆内存方案 | 0 | 本部分无分配量 / 峰值内存数据，仅有一个时间比值，按规则不出方案 |
| §8 降 CPU 方案 | 1 | adapter 覆盖热点签名（见「优化可行性方案」），证据状态 `无基线（待验证）` |
| §9 local mode 可行性 | 0 | 文档不涉及 local mode；无峰值内存前后对照，且本部分无候选函数 |
| §11 现有代码的 BUG（存量） | 0 | 本部分无源码；取证时撞见的代码侧问题按「范围外提示」记 4 条，不占统计 |
| §12 并发安全与锁粒度 | 0 | 文档层要求「新 ctx、独立事务、内层错误不覆盖外层」「句柄表有锁」，与本轮读到的实现一致，未发现相反承诺；`JitFunction` 状态机细节属模块其它部分 |
| §14 功能完备性与 README 覆盖 | 2 | #5（tasks 反写内容/溯源错误）、#12（「任一 func」承诺面）；本部分无 README，README 覆盖项不适用 |
| 文件覆盖（§13 等） | 20/20 | 无缺读文件；本部分 12 条均含 §13 要素（#4/#5 另计入 §14） |

### 第 11 部分

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 4 | 正确性 #1（F64 位模式）、#3（写入值域）、#4（取界机制）；设计 #2/#5（父成员登记口径）。语言特性（值/引用语义、`protected` module 级可见性）文档描述与实现一致；安全性面无外部输入、无凭据陈述 |
| §1 死代码 | 1 | 文档层机械核对「引用是否有下文」：`design.md` 引用的 `design-m3.md`/`jit-bytecode-m3.md`/`plan-m3.md`、interface proposal 的 6 个影响文件、`f_macros` 的 `InterfaceDecl` 扩展全部存在；唯一断链是 `tasks.md:14 → verify.md`（#10）。本部分无 `.cj`，不涉符号级死代码 |
| §2 重复逻辑 | 1 | 文档层同义枚举逐一比对：①JSON 写入值域名 4 处（两份 spec + 前端 + 运行期）已漂移（#3）；②`LocalType↔TypeToken` 映射单点（`fromToken`），`TypeToken.cj` 不反向维护，成立；③换行归一单点（`Lexer.normalizeNewlines`，5 处调用同一实现），成立；④`scenario-map.tsv` 的 scenario 名与各 spec 标题逐条一致，无第二份表 |
| §3 空实现 | 1 | 父接口 `case None => ()` 静默跳过（#2）；文档内无 TODO/FIXME 占位 |
| §4 栈溢出 | 0 | 文档未描述递归接口；`mergeAncestor*` 的 32 层封顶属代码侧，不展开 |
| §5 OOM | 0 | 唯一量化上限是 `addJson` 的 16 MiB/条 与 `SignatureTable.MAX_ENTRIES=128`，均与文档一致，无「按不可信长度预分配」 |
| §6.1 热点瓶颈 | 0 | 未构建、无 profile，热点结论不成立；只保留 1 条待验证假设（#2） |
| §6.2 大粒度锁 | 0 | 本部分无代码；文档中「单表 + 单 Mutex」属变更前语境，不判 |
| §6.3 并发串行 | 0 | 同 §6.2；并行化结论由 `ParallelThroughput_test` 承载，本轮未复核数据 |
| §6.4 低效算法 | 0 | 文档无算法描述；`hasField` 线性去重列待验证假设，不作为发现 |
| §7 降堆内存方案 | 0 | 无代码、无基线，按铁律不出方案 |
| §8 降 CPU 方案 | 0 | 同上 |
| §9 local mode 可行性 | 0 | 文档不涉及 local mode；被引用的解析/注册产物全部逃逸进常量表与描述符，`@local` 不成立 |
| §11 现有代码的 BUG（存量） | 1 | 仅 #1（为核对「装箱往返」契约而读到的实现缺陷，已标注移交）；其余代码面缺陷归各 `.cj` 分部分 |
| §12 并发安全与锁粒度 | 1 | `state/active` 的同步手段与文档「原子」口径不符（#7，当前实现安全、记录不一致）；未发现文档承诺线程安全而实现无同步的条目 |
| §14 功能完备性与 README 覆盖 | 2 | #3（规格承诺的写入值域未实现）、#10（M3 验收证据缺失）；本部分不含 README，public API 覆盖检查在 `.cj` 部分 |
| 文件覆盖（§13 等） | 20/20 | 清单 20 个文件全部读完，无缺项 |

### 第 12 部分

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 3 | 正确性 #1（优先级验收值）、#2（负指数时机）；设计 #4（失效机制缺代际）。本部分为文档，无外部输入、无凭据面，语言特性除 `**` 优先级（已用 `operator.md` 核对）外无其它断言，安全性 0 条 |
| §1 死代码 | 0 | 本部分无源码，按「文档声称新增的符号是否真有引用」机械过：`CompileCache.awaitTimeoutNs`（`CompileCache.cj:43` + `CompilePipeline.cj:135`）、`isCompiling`（`CompilePipeline.cj:133`）、`invalidateFailures`（`Compiler.cj:82/96/129/141/156`）、`missingResult`（`CompilePipeline.cj:89/117`）、`HelperCodec.IPOW`（`Lowerer.cj:1401`）、`lastEscaped`（`JitFunction.cj:669` 写、`:539-549` 与 `JitFunctionClosure_test.cj:123` 读）均有非测试引用；`failureCount` / `CompileCache.reset` 仅测试引用，属「可见性建议」不算死代码；`HelperId.IPOW` 仓内 0 引用，但 `HelperId` 是 `public class`（对外可达 public，硬原则一不判），已计入信息与 #5；`awaitReady` 末尾 `while(true)` 后的 `return None`（`CompileCache.cj:149`）是可达性兜底，不判 |
| §2 重复逻辑 | 2 | `Ops.HelperCodec` 与 `runtime.HelperId` 的 hid 双份常量（设计上刻意，守卫用例未覆盖 84，见 #5）；`CompilePipeline` 两处 `None` 分支已抽成 `missingResult`（无重复）。幂实现只有 `PowHelper.ipow` 一份，`TextFormat.pow2/pow5` 是 10 的幂换算，语义不同不判 |
| §3 空实现 | 2 | `PowHelper.cj:69` 的 `catch (_: Exception)` 把非溢出异常也归一成 3（#10）；`CompileCache.fail` 达上限整表清空后无淘汰策略说明（记入 #4 的修法）。`fix-da-diagnostic` 的 `return`（放行）有注释说明为何可以放行，不判 |
| §4 栈溢出 | 0 | 本部分文档不引入递归；`ipow` 是 `while` 循环（`:47-55`），深度由指数位数（≤63）界定 |
| §5 OOM | 1 | 失败缓存有 256 上限（`CompileCache.cj:95-104`）已挡住无界增长；剩余放大面是「每条文本内嵌全量注册名列表」，进优化方案 1（无基线，不进 tasks） |
| §6.1 热点瓶颈 | 0 | 无 profile / bench 数据；`ipow` 异常控制流、失败文本拼接都只进「待验证假设」2/3，不判缺陷 |
| §6.2 大粒度锁 | 0 | 文档所述的 `callMtx` / `envMtx` 已删；`Compiler.mtx` 在注册期包住反射（`Compiler.cj:134-146`）是冷路径且文档已明确代价（`proposal.md:37-38`），无持锁 I/O |
| §6.3 并发串行 | 0 | 本部分无 `spawn` 后立即 `get()` 的实现；`verify.md:82-92` 的 1/2/4/8 线程吞吐是已有基线（1.27×/2.40×/1.91×，共享 VM 超订），不重复计入 |
| §6.4 低效算法 | 0 | `registeredList()` 在每次失败时全量拼接（O(注册数)），但失败是冷路径且无耗时数据，归入优化方案 1 的内存面 |
| §7 降堆内存方案 | 1 | 失败文本内嵌注册名列表（优化方案 1） |
| §8 降 CPU 方案 | 1 | `ipow` 溢出检测改显式阈值（优化方案 2） |
| §9 local mode 可行性 | 0 | 本部分涉及的产物（失败文本、编译快照、`PredefinedSnapshot`）全部逃逸进 `CompileCache` / `Compiler` 成员，`@local` 不成立 |
| §11 现有代码的 BUG（存量） | 13 | #1–#13 全部按 §11 取证；其中 #1/#2/#3/#5/#10/#11/#12/#13 同时属 §13，#4 同时属 §12.1 |
| §12 并发安全与锁粒度 | 2 | #4（失效与写回的先后无序，缺代际）、#6（三态判定分两次取锁）；锁序方面核对了三条链：`Compiler.mtx → ClassRegistry.mtx / retainedMtx / CompileCache.mtx`（`Compiler.cj:113-157`）、`JitFunction.mtx → CompileCache.mtx`（`JitFunction.cj:263`）、`CompileCache` 只进不出（`finish` 的 bind 已移出锁，`CompileCache.cj:80-88`），无 ABBA；#12 只是锁序表述不准确，不改变安全结论 |
| §14 功能完备性与 README 覆盖 | 4 | #3（版本门与「记入 verify/README」未兑现）、#5（hid 名称表与值域守卫未接线）、#9（计划用例与验收门槛无对应物）、#11（承诺的词法错误面用例全缺）；本部分不含 README，README 覆盖检查在其它部分 |
| 文件覆盖（§13 等） | 20/20 | 本部分清单 20 个文件全部读完，无缺失 |

### 第 13 部分

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 3 | 正确性 #3（验收数字不自洽）、#6（完成声明与同模块回归记录相反）；设计 #1（同一事实三处维护）；语言特性 0（本部分无代码，文档所述 typecode/aux/escape 语义已逐条与 `AnyHelpers.cj`、`JitFunction.cj` 对拍一致）；可读性 0；安全性 0（无凭据、无外部输入、无注入面） |
| §1 死代码 | 0 | 本部分无 `.cj`，无 `return` 后语句 / 恒假分支 / 无调用者符号可判。文档侧「指向不存在符号」的引用共 4 类（`stackEffect`/`analyzeDepth`、`p2_5_a64Imm9SlowPath`、`p3_3_jsonSetFloat64Domain`、`a3_4_invokeMatchesCall`），按 §13 失效引用归入 #1/#4/#7，不重复计数 |
| §2 重复逻辑 | 1 | #1：缺陷→用例清单在 `test-plan.md` / `tasks.md` / `verify.md` 三处各存一份，语义相同而名字、条数已漂移（27 vs 26、6 组名字、`p1_4_` 前缀复用）；#5 同源（常量键表在 spec 与 `CanonKey` 各写一份并已分叉）。其余重复均为 OpenSpec 归档模型的镜像（同一 delta 落 `doc/spec` 与历史归档），按误报边界豁免 |
| §3 空实现 | 0 | 本部分无函数体。逐个核对「声称产出但可能为空」的产物：strictfp 的 verify 记录确在 `f-jit-m1/verify.md:238`，`DaDiagnostic_test` 四条用例有实体，`X86Lower_test` 的字节断言有实体；无占位 TODO、无「勾选但空」。`fix-da` 缺 design/specs 见文件覆盖表说明（仓内另有同类先例，不判） |
| §4 栈溢出 | 0 | 文档述及的深度风险点（深帧回边、`deepFrameExceedsImm9`、`STACK_GUARD ⇒ deopt`）与实现一致，未发现「文档承诺有保护而代码没有」或相反。本部分不含递归代码，递归专项在 `.cj` 部分 |
| §5 OOM | 0 | 无「按不可信长度预分配」「全局容器只增不减」类承诺；`IterTable` 调用级清空、逃逸槽归还两条生命周期承诺在 `JitFunction.cj:687` 与 `HandleTable.release` 侧有落点 |
| §6.1 热点瓶颈 | 0 | 本部分无 profile / bench 对照：`strictfp` 只有「约 12 条指令」的估数，`stack-align` 只有修复后的三个绝对值（无改前对照），`audit-defects` 只有用例数。两条自述已进「待验证假设」，不构成发现 |
| §6.2 大粒度锁 | 0 | 文档涉及的临界区只有 `callMtx`（`callForFn` 串行化）与 `IterTable` 静态锁，均属正确性修复而非热点；无「锁内 I/O / 解析 / 回调」的描述 |
| §6.3 并发串行 | 0 | `callForFn` 串行化是有意设计（提升组归属），文档已给理由；无 `spawn().get()`、无并发度=1 的批处理描述 |
| §6.4 低效算法 | 0 | 无嵌套循环 / `contains` 热点 / `remove(at:0)` 类描述；`X86Depth` 的工作列表数据流为 O(指令数) |
| §7 降堆内存方案 | 0 | 本部分无可改的生命周期/副本/容器上限对象（无代码）；文档所述「逃逸槽归还」「`IterTable` 清空」已是既有实现 |
| §8 降 CPU 方案 | 0 | 无基线数据，未提方案（见 §6.1 与待验证假设） |
| §9 local mode 可行性 | 0 | 文档不涉及 local mode；被描述的路径（JIT 降低、桥封送）产物均逃逸到机器码缓冲与句柄表，不满足「函数内创建、函数内用完」 |
| §11 现有代码的 BUG（存量） | 9 | 本部分 9 条全部为存量（快照模式无基线），按「存量文档/验收记录缺陷」计：#1–#9。无代码可审，故不含运行时缺陷 |
| §12 并发安全与锁粒度 | 0 | 无并发代码。文档承诺的并发契约（`callForFn` 整段入锁、`lastClosureGroup` 取完即清、`IterTable` 静态锁 + `close` 越界防御）与 `JitFunction.cj` / `IterTable.cj` 现状一致，未发现「文档声称线程安全而实现无同步」 |
| §14 功能完备性与 README 覆盖 | 3 | #2（自身 spec 的用例命名要求未落实）、#3（零回归门槛数字不可复核）、#6（spec 的回边安全点要求当时只在 tasks 勾选、实现与回归记录均未跟上）；本部分不含 README，公开 API 是否进 README 的检查在 `.cj`/README 部分 |
| 文件覆盖（§13 等） | 20/20 | 本部分清单 20 个文件全部读完，无缺失、无跳过 |

### 第 14 部分

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 1 | #1（兼容性结论与 D3 相反、规格 SHALL 全称化）。语言特性面核对了 `Int64(UInt64)` 受检转换、`AtomicInt64.load/store/fetchAdd`、`mut prop` 赋值语法、`!` 的「按位求反/逻辑非」双语义（官方 `Appendix/operator.md:14`），均与文档一致；本部分无外部输入、凭据、注入面 |
| §1 死代码 | 0 | 本部分无代码声明。改用等价机械检查：文档引用的符号/路径是否仍存在——`A64Exec_test`、`AstShape`、`CodeDump`、`A64Emitter.eorImm1`、`X86Depth.analyze`、`alignBeforeCall`、`freeOrRetireLocked`（在 `55ddaca48` 中存在，后被改名）、`HandleTableM2_test`/`T40Account_test`/`PromotionGroupConcurrency_test`/`WindowIsolation_test`/`HandleTableStripeConcurrency_test`/`NativeAssets_test`/`X86Depth_test` 均命中；README 索引遗漏见范围外提示 |
| §2 重复逻辑 | 0 | 已两两比对 5 个变更目录的 proposal/design/tasks/verify 叙述：重复仅为统一模板与必要前后引用；反复出现的测试总数 1098 → 1145 → 1201 → 1254 → 1256 单调且与各批增量自洽（+7 / +18 / +53 / +2）。真正逐字重复的 `0x50–0x6F` 指令表在 part2 的两份 design 文档中，列范围外 |
| §3 空实现 | 0 | 20 份文档均有实体内容，无 `TODO` 占位；`spec.md:19` 的空 scenario 已按 §13 计入 #2（结构错位而非占位） |
| §4 栈溢出 | 0 | 修复对象是 3~4 条定长机器码指令；`X86Depth.analyze` 是工作列表迭代；句柄 32768 轮用例是 `while` 循环，无递归 |
| §5 OOM | 0 | 唯一增长面是退休槽（永久占索引），已量化（3e-5 槽/次、默认 `capacityLimit` 1M、目录 4M），有拒绝路径（触顶 → 错误 16）；估算本身进假设 #3 |
| §6.1 热点瓶颈 | 0 | 无 `cjprof` / `cjpm bench` 数据；三处成本/容量断言进待验证假设 #1–#3，不作性能结论 |
| §6.2 大粒度锁 | 0 | 文档所述临界区只有「状态复位 + 世代号 + 归还索引」；现码 `release`/`releaseEscaped`/`resetWindow` 持分片锁、`releaseConst` 持 `mtx → 分片`，无 I/O/解析/日志。归档 design 的「持 `mtx`」是 P2.1 之前形态，不判 |
| §6.3 并发串行 | 0 | 无 `spawn` 后立即 `get` 的描述；两个并发用例都是先提交后统一 `get` |
| §6.4 低效算法 | 0 | 无复杂度描述；`resetWindow` 为 O(appendIds)，`popFreeWith` 最多扫 64 分片，与文档一致 |
| §7 降堆内存方案 | 0 | 本部分无源码；`NativeAssets` 只做计数，非 GC 内存由 `JitFunction` 持有，无优化落点 |
| §8 降 CPU 方案 | 0 | 同上；原子增量按文档「每单元各一次」，不在调用热路径，无逆向优化必要 |
| §9 local mode 可行性 | 0 | 文档未涉及 local region / `exclave` / `demode`，无改造面可评 |
| §11 现有代码的 BUG（存量） | 2 | #3（Red 形态与实测不符）、#7（并发护栏不可保证红）。另重新用 `grep CMP_I` 核实 B7 仍无 Lowerer 生产者；句柄判空 `id <= 0`、`release` 幂等、逃逸槽归宿、`FnTable.free` 幂等均已核对无缺陷 |
| §12 并发安全与锁粒度 | 0 | 逐点核对 H2/H4/H1：`NativeAssets` 计数已原子（`NativeAssets.cj:35-54`）；`HandleTable` 配置读走 `AtomicInt64`（`:149-169`）；4 处释放点都持归属分片锁，`popFreeWith` 在取 `mtx` 前已释放分片锁，无 ABBA。`liveCount` 的跨字段快照问题属范围外（见总评） |
| §14 功能完备性与 README 覆盖 | 1 | #6（spec 承诺缺 `{0,1}` 前置不变量）。README 的 API 索引与 `!` 语义覆盖属 part1，列范围外提示 |
| 文件覆盖（§13 等） | 3 | #2、#4、#5（均为 §13 文档一致性）；20/20 文件全部读完，无缺读 |

### 第 15 部分

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 3 | 发现 #1（并发正确性）、#2（契约/超时语义）、#3（返回值丢弃）。文档无外部输入、无敏感数据、无注入面；语言特性侧核对了 `Option`、`ThreadLocal`、`synchronized`、`Resource.close` 与 `Map.remove` 语义 |
| §1 死代码 | 0 | 本部分无 `.cj`。文档中 `unload()`/`unloadFn()`/`isUnloaded()` 在 `f_jit/src` 零命中，属「改名未回填」按 §13 记（发现 #10），不按死代码计；`EscapedClosure.seq` 有实际读取（`dropEscaped`），`newEscapedClosure` 有测试调用 |
| §2 重复逻辑 | 1 | 同一 G5 允许集/采集口径在 `harden-f-jit-object-lifetime` 的 design+spec 与 `harden-x86-audit-and-futil-tests` 的 spec 各写一遍，且已漂移成字面冲突（并入发现 #4）。其余重复是 SDD「提案→设计→规格→任务→验证」的固有分层，差异点是读者层次，不判 |
| §3 空实现 | 0 | 未发现空函数体 / 占位 `TODO` / 静默吞异常。G1 的 `try/catch`（`JitFunction.cj:649-654`）有实际归还动作；`case None => ()`（`:672`）是「无提升组」的正常缺失 |
| §4 栈溢出 | 0 | 本部分文档未新增递归。顺带核到 `CallMarshal.promoteClosureGraph` 对嵌套闭包递归，但有 visited 防环（范围外提示，不计入本部分） |
| §5 OOM | 0 | 登记表无界增长被 `design.md:170-173`（B4）明确写为既有契约，不判缺陷；量化面进待验证假设 #2 |
| §6.1 热点瓶颈 | 0 | 本部分无 profile / bench 数据（verify 只有用例计数），审计开销与自旋成本不成立为热点，已列入待验证假设 #1/#3 |
| §6.2 大粒度锁 | 0 | `close` 锁内的 `CompileCache.remove` 是内存操作，无 I/O/解析；自旋抢锁并入发现 #2 |
| §6.3 并发串行 | 0 | 无 `spawn` + 立即 `get()`、无单消费者队列；文档未承诺并行调用路径 |
| §6.4 低效算法 | 0 | `dropEscaped` 的 O(n)/累计 O(n²) 属实，但无 n 与耗时数据，只进优化方案 + 假设 #4 |
| §7 降堆内存方案 | 0 | 未发现可量化的多余副本；改 `HashMap` 会增加少量桶内存，收益在 CPU 侧，故不列堆方案 |
| §8 降 CPU 方案 | 1 | 登记表改 `HashMap`（`dropEscaped` O(n)→O(1)），证据状态「无基线（待验证）」 |
| §9 local mode 可行性 | 0 | 本部分无函数内临时大对象；审计表/登记表都跨调用存活，逃逸分析不成立 |
| §11 现有代码的 BUG（存量） | 3 | 逐个核对了 `close`/`unloadClosure`/`close(): Unit`/`enterClosure`/`enterUnit` 的边界与空值：#1（并发回退）、#2（自旋超时）、#3（返回值丢弃）。`entryOrFail` 的 `None` 分支、`isClosed` 三态、`close` 的 `state==2` 幂等分支无缺陷 |
| §12 并发安全与锁粒度 | 3 | #1（共享 `state` 无卸载者仲裁 ⇒ 检查后写入非原子，可释放正在执行的代码内存）、#2（自旋持锁抢锁）、#9（规格锁序不变量写错，实际为两把锁固定顺序）。已核对 `enter/exit`、`registerEscaped`、`closureReleased`、`lastEscaped` 的读写都在同一 `mtx` 内 |
| §14 功能完备性与 README 覆盖 | 2 | #4（G5「每条」只兑现抽样，且 `CALL_CLOSURE` 未登记）、#11（三条验收 Scenario 无用例）。README 本体不在本部分清单内，其与 `public` 声明的逐项覆盖由其他部分统计 |
| 文件覆盖（§13 等） | 20/20 | 20 个 `.md` 全部读完；§13 文档一致性命中 6 条（#5 #6 #7 #8 #9 #10），另 1 条属 §13/§14 交叉（#4） |

### 第 16 部分

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 0 | 本部分无源码，无逻辑/边界/注入面可判。文档侧的正确性问题按 §13 计（#1/#2/#3/#5/#7）；`Resource` 免 import、`AtomicReference` 发布、`ThreadLocal` 用法三处语言特性已对照 `f_store` 与本地 std 签名核过 |
| §1 死代码 | 1 | 本部分 0 个 `.cj`，无声明面。反向核对文档引用的符号是否已删：`freeWins`/`acquireWin`/`recycleWin`（`HandleTable.cj:225/239`、`RuntimeState.cj:47`）、`unboxRet`（`CallMarshal.cj:198`）、`FieldSnapshot`（`HostField.cj:70`）、`closeClosure`（`JitFunction.cj:294`）全部存在；命中 1 条为 `makeRetUnboxer` 仅测试引用（#8，可见性建议，不计死代码）；`unload`/`unloadFn`/`isUnloaded` 的旧名残留归 §13，已由 part15 #9 记录，不重复计 |
| §2 重复逻辑 | 0 | 逐份比对 6 个变更的 design↔proposal↔tasks↔verify 复述段：同一数据在 3–4 份文档各写一遍属 SDD 结构（提案→设计→任务→验证），差异是读者层次不是语义漂移，不判重复。复述带出的**口径不一致**已按 §13 报（#1/#4/#5），不重复计 |
| §3 空实现 | 0 | 逐份检查无空章节 / `TODO` / 「暂不处理」。`optimize-arg-staging` 与 P1.3 是「测了、判不做」的完整记录（有测量项、判定规则、重做条件），不是占位 |
| §4 栈溢出 | 0 | 6 个变更均未新增递归结构；文档唯一涉及的递归点（闭包图提升）不在本部分文件内，已在 part15 核过有 `visited` 防环 |
| §5 OOM | 0 | 本部分唯一涉及容器上限的承诺是 `freeWins ≤ 8`，实现为有界池（`HandleTable.cj:240` + `RuntimeState.cj:47`），无无界缓存/无界登记表承诺 |
| §6.1 热点瓶颈 | 0 | 本部分提供的都是历史测量记录，不是本轮 profile 结论；我对这些数据只做**自洽性**核对（#2/#3/#5），未提出任何新热点主张。缺 `cjprof` / 同环境 5 次对照的部分已转「待验证假设」#1/#2 |
| §6.2 大粒度锁 | 0 | 文档描述的锁改造均有落点且与实现一致：`HostFieldTable` 读写分离为「写锁内 COW + `AtomicReference` 发布」（`HostField.cj:86-118`）、`HostFault` 改为线程状态内表（`HostCall.cj:229-266`）。无锁内 I/O / 序列化 / 回调的承诺 |
| §6.3 并发串行 | 0 | 6 个变更均无 `spawn` + 立即 `get()` 或单消费者队列的设计；`optimize-call-path-phase1` 明确把并行度问题放在 `Q4/Q1` 指标上，未承诺串行段消除 |
| §6.4 低效算法 | 0 | 文档提到的 `Win` 池取用是 `remove(at: size-1)`（O(1) 尾删，`HandleTable.cj:227`），不是 `remove(at: 0)`；无嵌套循环/热点 `contains` 主张 |
| §7 降堆内存方案 | 0 | 本部分为测量/判定记录，无新的「还能省多少」主张；`freeWins ≤ 8` 已是既定优化，收益在 CPU 侧（GC 分配），不在堆峰值 |
| §8 降 CPU 方案 | 0 | 三项候选都已给出判定：窗口池 keep、`CallMarshal` 两表与 `cells` 明确「留待单独评估」（`optimize-call-alloc/verify.md:53-56`）、实参暂存区「不做」。三者均已有决策记录，不重复提方案 |
| §9 local mode 可行性 | 0 | 本部分无函数级临时大对象；`Win` 池、`FaultEntry`、`FieldSnapshot` 都是跨调用存活/跨线程发布的结构，逃逸检查不成立 |
| §11 现有代码的 BUG（存量） | 0 | 本部分 0 个 `.cj`，缺陷只在文档引用的实现点上取证：`close` 竞态、自旋超时、`close(): Unit` 丢结果已在 part15 #1–#3，其**文档面**（spec 无条件承诺卸载）记在 #7；`HostFault`/`HostField`/`Win` 池三处实现与规格逐条对齐，未发现新缺陷 |
| §12 并发安全与锁粒度 | 0 | 已核对的共享点：`HostFault`（改为 `RuntimeState.faults`，线程封闭，delta 规格 `spec.md:43` 的「跨线程读得到无记录」成立）、`HostFieldTable.current`（`AtomicReference` 整对象发布，读方无锁无拷贝）、`Win`/`freeWins`（`RuntimeState` 字段，线程私有）。本部分文档侧未见新增共享可变状态承诺 |
| §14 功能完备性与 README 覆盖 | 0 | README 不在本部分文件清单内。spec delta 的 4 条 Requirement（资源生命周期 / 统一调用包装 / H64-H65 / 宿主异常）与实现逐项对齐，未发现「承诺但未实现」；语义收窄项已由 part15 记录，不重复计 |
| 文件覆盖（§13 等） | 20/20 | 20 个 `.md` 全部读完；无跳过、无抽样 |

### 第 17 部分

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 1 | 本部分无 `.cj`，无代码逻辑可判；按「文档承诺即契约」把每条可言伪的声称都回到源码核对（合计为发现 #1/#3）。typecode 分支表（`LocalType` 码 0–21 / `TypeToken`）在本部分 20 个文件中没有对应表格或分支描述，未命中。语言特性一项：`AtomicInt64` / `AtomicReference` 语义已查 std 文档（`sync_package_api/sync_package_classes.md:2085-2130`，只写「默认内存排序方式」，未写 SeqCst），据此把内存序问题降级为待验证假设 #2，未当作缺陷 |
| §1 死代码 | 0 | 已机械核对本部分引用的全部符号/文件：`markConst`（0 个定义，见发现 #3）、`CompileCopy_test.cj`（实际在 `src/compiler/`）、`A64EmitterSize_test`/`HandleTableStripeConcurrency_test`/`JitBindSupportSnapshot_test`/`HostFaultTls_test`/`HandleTableGenExhaustion_test`/`ParallelThroughput_test`/`ParallelCall_test`/`UnloadConcurrency_test`/`PromotionGroupConcurrency_test`/`WindowIsolation_test`/`T40Account_test`/`AnyHostCast_test` 等引用用例均存在；`enterPauseHook`、`lateEnterAfterStateReadIsRejected` 已按 verify 所述删除（全仓 0 命中）。本部分无代码可判死代码 |
| §2 重复逻辑 | 0 | 已两两比对 20 个文件的「输入-输出-副作用」：proposal/design/tasks/verify 四件套是模板分工（为什么/怎么做/做什么/结果），不是同语义复写；phase2 与 phase4 都描述 `HandleTable` 锁改造，但前者是分片空闲表、后者是 `totalSlots` 原子化与 `JitBindSupport` 快照，改动面不重叠，合并会丢失「逐项可回滚」的决策粒度 |
| §3 空实现 | 0 | 归档件里「不做」的三项（`optimize-compile-lookup` 的 L3.1–L3.3）在 `tasks.md:3-4` 明确标注「数据不支持，不做」，并给了收益上限 0.2% 与 MOV 对比，属有意不做，不是空实现 |
| §4 栈溢出 | 0 | 本部分无代码。文档涉及的递归结构仅 `CallMarshal.promoteClosureGraph`（`optimize-call-path-phase2` 未涉及、`phase4` 只在 `PromotionGroup` 语义里提到「槽级免级联」）；已核对 `CallMarshal.cj:288-309` 用 `visited` 做环检测、深度受闭包捕获链限制，未在本部分文件内命中风险 |
| §5 OOM | 0 | 本部分无代码。文档承诺的容量面（`capacityLimit`、`FREE_STRIPES=64`、`retiredSlots` 退休上限）与 `HandleTable.cj:177-202` 一致，均为有界结构；未发现「只增不减」的承诺 |
| §6.1 热点瓶颈 | 0 | 本部分只有测量记录，没有本轮采集的 profile；文档中的热点结论（`translate` 1.41–1.65 ms、`validate` 0.21–0.23 ms、A4/S4 扩展比）属历史数据，本轮无同机复测，故不新增热点结论，只把不可复算处列入发现 #2、把机器差异列入待验证假设 #3 |
| §6.2 大粒度锁 | 0 | 文档声称的两处锁清理均已落地并与代码一致（`openWindow` 不再取 `mtx`：`HandleTable.cj:407-413`；`JitBindSupport` 读路径零锁：`JitBindSupport.cj:147-171`）。剩余 `mtx` 临界区为冷路径（`growSlot`、`pinConst` 全表扫、`moveOutGroup`、`resetForTest`），本轮无持有时间数据，不判为热点 |
| §6.3 并发串行 | 0 | 本部分无 `spawn().get()` 一类代码；`HandleTableStripeConcurrency_test.cj:59-61` 是先提交后汇合的正确形态 |
| §6.4 低效算法 | 0 | 文档点名的三处 O(n)（`PredefinedSnapshot.slotOf`、`ClassRegistryView.classOf`、`ClassRegistry.snapshot` 双拷贝）已用 0.2% 收益上限论证不做，算式自洽（50 µs / 24.9 ms）；`pinConst` 的全表线性扫在写路径、频次低，无数据前不作低效结论 |
| §7 降堆内存方案 | 0 | 归档件不产生新代码；`phase2/verify.md:71-76` 的「后续」只列了 B1 单次调用成本，无堆内存方案 |
| §8 降 CPU 方案 | 0 | 同上；文档遗留线索（审计表 TLS、`bind` 字符串键、`decode` 数组）中两项已由后续变更加工，剩 `bind` 键无实测，见「优化可行性方案」说明 |
| §9 local mode 可行性 | 0 | 本部分无函数级改造对象；`scope.md` 的 LocalMode 资料针对 `docs/` 全局方案，不属于 `f_jit` 这 20 个文件的可判范围 |
| §11 现有代码的 BUG（存量） | 4 | 发现 #1（句柄生命周期：提升与释放双锁）、#2（性能判定闸门不可复算，属记录缺陷）、#3（四处文档事实性错误）、#4（全量计数与已删探针互斥）。均已给位置 + 判据 + 证据等级；全部为存量（快照模式无 diff 基线） |
| §12 并发安全与锁粒度 | 1 | 发现 #1 即并发安全项：指出具体共享字段（`escapeFlags`）、两个并发访问者（`escape`/`moveOutGroup` vs `release`/`resetWindow`）与缺失的同步手段（两把锁不互斥）。锁粒度项：`mtx` 已按 phase2/phase4 收缩为冷路径，未发现「该分片而未分片」的新证据 |
| §14 功能完备性与 README 覆盖 | 0 | 本部分不含 README/`README_en`。文档承诺的 6 项能力已逐项在代码中确认存在：HostFault 线程私有（`HostCall.cj:229-318` + `JitContext.cj:199-203`）、HostField 快照（`HostField.cj:85-141`）、`HandleTable` 分片+原子 `totalSlots`（`HandleTable.cj:195-202`）、`JitBindSupport` 快照（`JitBindSupport.cj:39-144`）、`FbcWriter.payload` / `Assembler.clone` / 单次 `flushICache` / `A64Emitter` 按字存储 / `checkCrc32` 预分配；无「承诺但未实现」 |
| 文件覆盖（§13 等） | 20/20 | 无缺漏，全部 20 个 `.md` 逐个读完；`.cj` 只作交叉取证，不计入本部分覆盖 |

### 第 18 部分

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 2 | 本部分无 `.cj`。按「文档承诺即契约」把每条可证伪的声称回源码核对，命中：护栏清单与实际用例不符（发现 #1）、注释与实现相反（发现 #8）。语言特性只用两条：`Array` 引用语义 + `HashMap` 只读并发（后者降为发现 #10）、`internal` 只到本包（`A64Emitter` 为 `internal class`，`:39`）。typecode 分支表（`LocalType` 0–21 / `TypeToken`）在这 20 个文件中无对应描述，未涉及 |
| §1 死代码 | 0 | 本部分无代码可判，改做「文档点名的符号是否真实存在」的机械核对：声称**已删除**的 `A64Label`（全仓 `.cj` 0 命中）、`auditTls`/`auditList`（`A64Emitter.cj` 0 命中）、`CodeBuffer.statsSnapshot/resetStats`（0 命中）、`X86Lower` 的 `insns`/`offs`、`CompileStageProbe_test.cj`（文件不存在）—— 6 项全部兑现；声称**新增**的 `labels: HashMap`/`bind`/`labelOffset`/`resolve`/`finishOrNull`、`audit`/`resetAudit`/`auditSnapshot`/`auditAllows`、`buildTable`/`pushTable`/`helperTableCache`/`helperTableRef`、新 `translate(op, code, opsAt, …)` 全部存在。无「说删了还在 / 说加了没有」。`UserHelperTable.push(base, entries)` 现仅测试引用，属 design §2.1 明示保留的兼容入口，不计死代码 |
| §2 重复逻辑 | 1 | 跨文件复制段落已漂移：同一份 C1 退避计划在 `design.md:30-46` 与 `doc/optimize-compile-path.md:45-55` 各存一份，参数与实现脱节（发现 #2）。其余：proposal/design/tasks/verify 分工属模板，非重复逻辑；emit-fixup 测量表在 `verify.md` 与 doc §9.3 各一份，数字逐项一致（镜像无漂移）；`normalizeNewlines` 的复述漂移单独按 §13 记（发现 #4），不重复计数 |
| §3 空实现 | 0 | 无空函数体/占位 TODO；两处「不做」都有量化依据（compile-lookup 收益上限 0.2% < MOV 3%；C3 取消凭 M0 2.4%/5.9% < 15%）。`push` 作为兼容包装有 design 说明，不是接口默认空实现 |
| §4 栈溢出 | 0 | 本部分无递归实现或递归结构描述；唯一遍历是 `resolve` 对扁平 `relocs` 的单层循环（`A64Emitter.cj:135`），与调用深度无关 |
| §5 OOM | 0 | 唯一的全量物化面是 `Compiler.snapshot()` 的 O(F) 拷贝，已被 C2 缓存消掉（`Compiler.cj:190-219` 命中即返回）；helper 表由「每次调用建一张」改为「每单元一张」，方向是降内存。`ready` 无上限属旁证，记待验证假设 #2 |
| §6.1 热点瓶颈 | 0 | 本部分只有历史测量（`finishOrNull` 78–92%、`snapshot` 41.5%@4T、helper 表 456–925 ns/F/call），本轮未复测、无 `cjprof`/`cjpm bench` 数据 ⇒ 不新增热点结论；`verify.md:74` 明说剩余差距需专用机 + profile |
| §6.2 大粒度锁 | 1 | `awaitReady` 已从「每轮取全局锁」改为墙钟退避（`CompileCache.cj:128-150`，与 −98.4% 一致），锁粒度问题解决；剩忙等本身（无 `yield`）作 CPU 侧问题记待验证假设 #1。`Compiler.snapshot()` 的 O(F) 构造在 `mtx` 内（`Compiler.cj:191-218`），C2 后命中路径只剩两次取值，不再构成大粒度锁 |
| §6.3 并发串行 | 0 | 本部分无 `spawn(...).get()` 类描述；C0/C1/C2 三段都是「4 线程共享 Compiler」的并发测量，方向正确（先提交后汇合） |
| §6.4 低效算法 | 1 | 按文档核对三处复杂度修复真实生效：标签线性扫 → `HashMap`（`A64Emitter.cj:54/82-95`，O(R×L) → O(R)）、`finishOrNull`+`finish` 双遍 → 单遍 `resolve`、helper 表 O(F)/call → O(1)/call（`JitFunction.cj:613`）。仍存的名字线性扫（`PredefinedSnapshot.slotOf`）已由 compile-lookup 用 0.2% 上限论证不做，算式自洽，不重报 |
| §7 降堆内存方案 | 0 | 本部分无实现；文档内「下一步」只列 CPU 项，且 `compileUnitWith` 逐字节拷贝已由 `optimize-compile-copy` 处理，无可量化堆方案 |
| §8 降 CPU 方案 | 0 | 同上。两组「未测得收益」改动（emit-audit、decode-alloc）无改后基线，按铁律只保留「严格更少工作」的定性理由，不写成优化结论 |
| §9 local mode 可行性 | 0 | 本部分无函数级改造对象；`scope.md` 的 LocalMode 资料针对 `docs/LocalMode*.md` 全仓方案，不在这 20 个文件的可判范围 |
| §11 现有代码的 BUG（存量） | 10 | 本部分无 `.cj`，「存量 BUG」表现为规格事实性错误：发现 #1–#10 全部为存量，均给出位置 + 判据 + 证据等级。同时核对 6 条关键语义在实现中成立：`bind` 首次绑定优先（`A64Emitter.cj:82-88`）、`resolve` 的 `done` 幂等（`:131-165`）、失败丢弃发射器（`A64Compiler.cj:55-62`）、`snapCache` 5 个入口全失效（`Compiler.cj:80/95/127/140/155`）、30 s 墙钟预算（`CompileCache.cj:43`）、helper 表绑定期构建（`JitFunction.cj:402-406`）—— 无「规格与实现相反」 |
| §12 并发安全与锁粒度 | 1 | 发现 #10：共享 `HashMap` 只读并发的安全性是断言、缺 std 依据（待确认）。其余已核：审计表由 ThreadLocal 改实例字段后，隔离性由「每次 `compileOnce` 新建发射器」保证（`A64Compiler.cj:71`）；helper 表在 `bindUserHelpers` 发布前构建，发布经 `CompileCache` 的 `synchronized(mtx)` 就绪门，具备 happens-before |
| §14 功能完备性与 README 覆盖 | 3 | 发现 #1（两处 design 护栏未落地）、#3（目标未达成无结项）、#9（归档记录无产物）。本部分不含 README/`README_en`（在其它部分）。规格点名的 15 个测试文件与 6 个实现符号全部存在，`X86Compile_test` 实际在 `src/compiler/`、文档只写文件名，不算错误 |
| 文件覆盖（§13 等） | 20/20 | 无缺漏，20 个 `.md` 逐个读完。（**初稿更正**：初稿把「`verify.md:12` 1210 条 vs `doc/optimize-compile-path.md:88` 1206 条」判为漂移。实际是同一变更的两个时点 —— 1206 是 C1 完成时的全量，C0/C2 又新增 `A64AuditIsolation_test` 1 + `CompileConcurrency_test` 1 + `CompilerSnapshotCache_test` 2 = 4 条后成为 1210，与 emit-fixup 的 4 条护栏无关。1206→1210 属正常增量，不判缺陷） |

### 第 19 部分

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 2 | 本部分无 `.cj`，无可执行逻辑；按「文档承诺即契约」把每条可言伪的声称回到源码核对，命中发现 #1（发射序列寄存器）与 #2（门控实现）。typecode 分支表专项：20 个文件里只有 `optimize-runtime-tls` 涉及 ctx 位域，`CtxFlags` 实际 4 个常量已逐个核对（`JitContext.cj:72-86`），无 typecode/`TypeToken` 分支表描述，未命中。语言特性一项：`AtomicReference` 的 `load/store` 语义、`ThreadLocal` 成本均按项目内实测文档引用，未凭记忆断言 |
| §1 死代码 | 0 | 本部分无代码。已机械核对文档点名的全部符号：`CtxFlags.DEADLINE`（`A64Lower.cj:376`、`JitContext.cj:178` 均有读者）、`BackendX86_64.emitCtxFlagsToRax/emitDeadlineMaskToRdx/emitTestRaxRdx/emitJz`（`X86Lower.cj:1039-1042` 调用）、`HandleTable.*With` 8 个新入口与 `openWindow`/`pin` 等 5 个旧薄包装（旧入口只被测试引用——按硬原则属可见性建议，不是死代码）、`SignatureTable.buildCount/entryCount`、`UserHelperTable.pushTable/pop`、`RuntimeState.typeCodeOf` 均有引用；`realMallocCount/residentBlocks/JitContextPool_test` 确认已随回退删除（0 命中），与 tasks T1.1/T2.5 自述一致；文档点名的测试用例名 19 个全部在 `src/**` 命中（`HelperTableScope_test` 3、`LoopSafepoint_test` 3、`MarshalRs_test` 5、`RuntimeStateIsolation_test` 3、`SignatureTableConcurrency_test` 7、`X86Lower_test.loopBackPollGate`、`AnyBridgeCall_test.p0_6_deadlineInterruptsLoop`），唯一落空的是 `tasks.md:15` 的类名 `SignatureRegistryVerification`（记入发现 #6，属命名漂移不是死代码） |
| §2 重复逻辑 | 0 | 已两两比对 6 组规格的「文件角色 → 内容 → 结论」：proposal/design/tasks/verify 是模板分工（动机/方案/步骤/结果），不是同语义复写；`optimize-loop-safepoint` 与 `optimize-runtime-tls` 都改 `JitFunction.call` 的 TLS 访问，但前者是回边 poll 门控、后者是状态合并，改动面不重叠。唯一实质重复是同一组数字（665/15 ns、L1 3502–3758）在 proposal 与 verify 各写一遍，属归档惯例，不建议合并 |
| §3 空实现 | 0 | 本部分描述的改动都有实现：回边门控（`A64Lower.cj:363-381`、`X86Lower.cj:1035-1045`）、ctx flags 写入（`JitContext.cj:174-188`）、`rs` 下传（`JitContext.cj:199`、`CallMarshal.cj:43-56`）、两表快照（`HostSignature.cj:111-202`、`SignaturePlan.cj:119-199`）、helper 表预建（`JitFunction.cj:401-406`）。唯一「做了又撤」的是 ctx 池，已在 tasks/verify 明确标注 revert 且代码确无残留，不算空实现 |
| §4 栈溢出 | 0 | 本部分无代码、无递归结构描述；文档涉及的递归只有 `RuntimeState` 字段链（无自引用）与 helper 栈（`UserHelperTable` 的 `ArrayList` 入栈/出栈，深度=嵌套调用深度，与既有调用栈同阶）。未在本部分文件内命中无界递归承诺 |
| §5 OOM | 0 | 文档承诺的容量面均有界且已在代码核对：`SignatureTable.MAX_ENTRIES=128`（超限不缓存）、`SignatureRegistry` 只增但条目来自启动期注册（个位数）、`ctx` 池的「每线程 ≤4×64 B」方案已回退（不存在常驻）、helper 表按单元缓存（`JitFunction.helperTableCache`）。未命中「只增不减」的承诺 |
| §6.1 热点瓶颈 | 0 | 本部分只有历史测量记录，无本轮 profile；文档中的热点结论（回边 poll 97.7%、TLS 14 次≈4.4 µs、`HostCallback` 构造）都带基线但非本轮同机复测，故不新增热点结论，只把未测项列入待验证假设 #1/#2 |
| §6.2 大粒度锁 | 0 | 文档描述的锁收缩已落地并核对：`SignatureRegistry`/`SignatureTable` 读路径 0 锁（`HostSignature.cj:155-194`、`SignaturePlan.cj:141-152`），`writeMtx` 只在注册/未命中建计划内；`JitExecutor.invokeOff` 稳态 1 次 get 0 次 set（`JitExecutor.cj:147-179`）。剩余写锁为冷路径，无持有时间数据，不判热点 |
| §6.3 并发串行 | 0 | 本部分无 `spawn().get()` 形态；`optimize-jitcontext-pool` 讨论的正是「去掉每线程串行池化」，结论是不采纳 |
| §6.4 低效算法 | 0 | 文档点名的线性扫（`sameShape`）已用「表个位数条目」论证并保留，且有 349→233 ns 的对照；`optimize-signature-tables` 还记录了「加索引反而更慢」的反例。无「已知 n 大仍线性扫」的承诺 |
| §7 降堆内存方案 | 0 | 归档件不产生新代码；`optimize-jitcontext-pool` 的方案已被实测否决并回退，`optimize-marshal-rs` 的惰性容器已落地（值型调用 0 个 `ArrayList`）。无新的、有基线的堆方案 |
| §8 降 CPU 方案 | 0 | 同上；文档遗留线索（编译 25–48 ms、`append` 的一次 TLS）无分段数据，进待验证假设 #1，不作方案 |
| §9 local mode 可行性 | 0 | 本部分无函数级改造对象（规格里没有 local mode 相关段落）；`scope.md` 提到的 `docs/LocalMode*.md` 属全局方案，不在本部分可判范围 |
| §11 现有代码的 BUG（存量） | 0 | 本轮读到的存量缺陷均为「文档与实现不一致」，已按 §13 归类（发现 #1-#6）；未在本部分触及的代码里发现新的逻辑/BUG（交叉取证的 `X86Lower`/`A64Lower`/`JitContext`/`SignaturePlan`/`HandleTable` 关键行均与规格自洽）。故 §11 单列 0 条，不重复计数 |
| §12 并发安全与锁粒度 | 0 | 文档声明的线程模型已逐条核对：`RuntimeState` 线程私有（`RuntimeEnv.cj:33-46`，`stateTls`）、`RuntimeStateIsolation_test` 3 条存在、helper 栈 TLS（`UserHelper.cj:53`）、两表快照用 `AtomicReference` + 写锁「先填满再 store」（`HostSignature.cj:141-149`、`SignaturePlan.cj:167-175`）。未发现「文档声称线程安全而实现无线程隔离」的情形 |
| §14 功能完备性与 README 覆盖 | 1 | 发现 #2 的 `RuntimeStateFlags_test` 属「承诺了但不存在」（双证：`design.md:113` + `.cj` 0 命中）。`optimize-helper-table` 的 `design.md` 不在本部分，无法判其护栏清单完整性（`待确认`）。README 不在本部分清单内，未展开 |
| 文件覆盖（§13 等） | 20/20 | 无缺漏，全部 20 个 `.md` 逐个读完；`.cj` 只作交叉取证，不计入本部分覆盖 |

### 第 20 部分

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 3 | 命中：再导出缺项（设计/契约）、`register` 语义与注释不符、`resetWindow`/`resetForTest` 的全局状态用法；安全面无用户输入（本部分无解析/拼接外部串，无注入面） |
| §1 死代码 | 2 | 已逐个符号机械过：`AdapterRegistry` 的 `private lock/adapters/units/key` 均有内部引用；`public register/lookup/removeUnit` 仅测试引用、`size()` 零引用 ⇒ 整类判「未接线/死成员」；5 个文件的 `import` 逐个核对均被使用；无 `return`/`throw` 后同层语句；`@Test`/`@TestCase` 成员按宏生成豁免；`ProbeSink`（private class）及其 `public` 成员在文件内被使用，不判 |
| §2 重复逻辑 | 0 | 已把本部分 5 个 `.cj` 的函数体压成「输入→输出→副作用」摘要两两比对：`AnyBridgeCall_test.compiler()` 与 `AnyHostCast_test.compiler()` 差异在「是否注册 3 个类」，非同语义；`AdapterRegistry_test` 两段 `match(lookup)` 分属不同键断言。跨文件检索 `func codeOf(` / `func castCode(`：`codeOf(body: () -> Unit)` 在 `CallMarshal_test`/`JitFunction_test`/`JsonBridge_test`/`CallMarshalM2_test` 各有副本（范围外文件），属 §2 误报边界「测试里的准备代码」，不计；本部分内 `castCode` 仅 1 处 |
| §3 空实现 | 1 | `AnyBridgeCall_test.cj:147` 空 `catch`（见发现）；`AdapterRegistry` 无 TODO/占位返回；`ProbeSink.diag` 有真实副作用；`DiagnosticsSink` 的默认便捷重载由 `BaseVisibility_test:63-72` 断言转发 `Unspecified`，非空实现 |
| §4 栈溢出 | 0 | 本部分无递归：`AdapterRegistry` 全部为单层循环/哈希操作；4 个测试文件无自递归、无深遍历；`AnyBridgeCall_test` 的 1e8 是**循环**不是递归（有界、可中断） |
| §5 OOM | 1 | `AdapterRegistry.units` 重复登记线性增长 + 无容量上限（见发现 5、优化方案 2）；测试侧 `AnyHostCast_test` 的 5000 次 `openWindow/resetWindow` 成对弹出（`HandleTable.cj:1053-1096`），不累积窗口 |
| §6.1 热点瓶颈 | 0 | 本部分无 profile / bench 数据；疑似热点（`AdapterRegistry.lookup` 的锁与字符串键）已降级为「待验证假设」#1，不进发现 |
| §6.2 大粒度锁 | 0 | `AdapterRegistry` 是单锁保护两张表，但临界区内只有哈希读写（无 I/O / 解析 / 回调），且当前无调用者；按「无数据不判热点」处理 |
| §6.3 并发串行 | 0 | 无 `spawn(...).get()`、无批大小 1 的窗口；`AdapterRegistry_test:60-73` 是 4 线程先提交后统一 `get()`，形态正确 |
| §6.4 低效算法 | 0 | 无嵌套循环、无 `remove(at: 0)`、无循环内字符串 `+`；`key()` 的插值属常数开销，已归入优化方案 1 |
| §7 降堆内存方案 | 1 | `units` 去重 + 上限（见优化方案 2，无基线） |
| §8 降 CPU 方案 | 1 | 结构化键替代字符串键（见优化方案 1，无基线） |
| §9 local mode 可行性 | 0 | 不成立：`AdapterRegistry` 的键串与列表元素**逃逸到 static 容器**（`adapters`/`units`），按 §9 约束 2 不能作为 local 对象；测试侧临时对象量小且无峰值内存证据 |
| §11 现有代码的 BUG（存量） | 5 | 本轮读到的 `register/removeUnit/key/size` 与 4 个测试类的方法逐个核对边界与空值：`Option` 分支（`units.get` 的 `Some/None`）都处理了；`list.size` 返回语义与注释不符、空 `catch`、全局状态残留、文档口径冲突已单列；`key()` 用 `/` 拼接在三段均为数字/类型名时不会冲突（类型名不含 `/`），不判 |
| §12 并发安全与锁粒度 | 1 | 安全面：`AdapterRegistry` 全部状态在 `synchronized(lock)` 内读写，单锁、无嵌套、无锁内回调 ⇒ 无死锁/可见性缺陷；粒度面：单锁保护两张表但无私聊证据（无调用者），不判热点。命中项是测试对进程级 `HandleTable` / 静态注册表的共享与复位（见发现「全局状态」） |
| §14 功能完备性与 README 覆盖 | 2 | `AdapterRegistry` 未接线（设计 §7.3.5/§8.3 第 5 步）；根包再导出缺 `CallContext`/`InterruptedException`（设计 §7.3.6）。本部分不含 `README.md`，README 覆盖留待含 README 的部分 |
| 文件覆盖（§13 等） | 20/20 | 无缺文件；15 个 `.md` 全部按 §13 两两对照（文档↔代码 / 文档↔文档），命中见「统计口径」与「等待条款」两条 |

### 第 21 部分

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

### 第 22 部分

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

### 第 23 部分

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 3 | 正确性 2（`parseFnType` 解析、typecode 表漂移）、可读性 1（注释错位）；设计上 `JitReport` 的三态分派与 `JitFunction` 状态机分层清晰；语言特性无问题（`struct` 值语义、`?T` 均为惯用写法）；安全性仅日志面（`printStackTrace`，已计入轻微） |
| §1 死代码 | 2 | 已逐个 private / internal 符号全仓搜引用：`JitFnSig`、`CallOut`、`DEFAULT_CONTEXT`、`EMPTY_CELLS`、`escapedSeq`、`entryOrFail`、`classAt`/`sigAt`、`dropEscaped` 均有引用；`newEscapedClosure` / `lastPromotionGroup` / `classSnapshotOf` / `isReturnedHandle` 仅测试引用（`internal`，作可见性建议，不判死代码）；命中 2：`callLocked` 的 `options` 死参数、测试内 `box` 未读。`JitHost.private init()` 是防实例化守卫，有语义，不判 |
| §2 重复逻辑 | 2 | 已把 6 个非测试函数体压成「输入→输出→副作用」两两比对：`codeOfTypeName` 与 `computeTypeCode` 同表两写且已漂移（命中）；`closed` 状态查询重复谓词（测试，命中）；`catchCall`/`catchCallAny`、`greetOverride`/`jitOnlyOverride` 差异是业务差异（错误文案、参数个数），不算重复 |
| §3 空实现 | 0 | 无空函数体；`match` 的 `case None => ()` 均为「无可选值」的正常路径（`escaped` 无组、`entry` 无条目时另有显式 `throw`）；`JitReport` 的 `case None => ()` 是「无 cause」退化，不是吞异常 |
| §4 栈溢出 | 0 | 无递归：`parseFnType`/`typeNameOf`/`simpleTypeName` 均为循环实现；打印/比较不递归对象图；JIT 侧递归由机器码栈承担，不在本部分判 |
| §5 OOM | 1 | `escaped` 列表随「返回闭包但宿主不 close」增长，但 README:538 明确「单元存活期间不释放 = 契约」，且 `close` 会 `clear`；已作为契约记录，未升为缺陷。按不可信长度预分配点（`Array<Int64>(args.size)`、`allocateDump(diagMaxLocals)`）均由单元签名/装载期常量限定 |
| §6.1 热点瓶颈 | 0 | 本部分无 profile / bench 数据（`PerfAdapter_test` 只测反射 vs adapter 单点，不代表 `call` 热路径）；`callForFn` 重复解析、`cells` 分配已降级为「待验证假设」 |
| §6.2 大粒度锁 | 1 | `close`/`unloadClosure` 的自旋每轮取 `mtx`，与 `exitUnit` 争用（并入「自旋超时」一般项）；`CompileCache.remove` 在单元锁内调用，但锁序已在 `CompileCache.cj:71-79` 声明为「单元 → 缓存」且反向不存在，不判死锁 |
| §6.3 并发串行 | 0 | 无 `spawn` 后立即 `get()`、无单 writer 热点；`call` 路径已去进程级锁（`ParallelCall_test` 可证） |
| §6.4 低效算法 | 1 | `dropEscaped` 线性扫描（优化方案，无基线）；`escaped` 遍历仅在 `close` 出现一次 |
| §7 降堆内存方案 | 1 | 每调用 cells + `CallMarshal`（无基线，见优化方案） |
| §8 降 CPU 方案 | 2 | `callForFn` 类型名重复解析；`dropEscaped` 索引化 |
| §9 local mode 可行性 | 0 | `docs/LocalMode.md:451` 明示 f_jit「待采样」；本部分函数内临时对象均为短字符串/小数组，无峰值内存证据，收益无法证明 |
| §11 现有代码的 BUG（存量） | 6 | 并发 close 回退（严重）、自旋超时、`parseFnType`、缓存窗口、注释与声明错位、测试墙钟/门禁；本轮读到的 7 个非测试函数（`close`/`closeClosure`/`unloadClosure`/`enter*`/`exit*`/`callLocked`/`callForFn`/`parseFnType`）的边界与空值路径均已核对 |
| §12 并发安全与锁粒度 | 3 | 已列出共享点：`state`/`active`/`escaped`/`cacheKey`/`lastEscaped` 均在 `mtx` 内；装载层 `bind*` 写发生在 `CompileCache.finish` 发布之前，发布/查找同锁，happens-before 成立；唯一无锁写是 `helperTableRef` 的惰性兜底（仅测试直造实例，幂等）。命中 3：回退跨状态竞态、自旋抢锁、缓存窗口 |
| §14 功能完备性与 README 覆盖 | 0 | 本部分无 `.md`；已用 README 作契约对照（`close(timeoutMs)`、`callForFn`、并发调用三点），无「承诺未实现」；`JitHost` 的三条 public API 在 `HostSignature_test` 有端到端用例 |
| 文件覆盖（§13 等） | 20/20 | 无缺失；本部分不含 README/doc，§13 的文档一致性留给含 `.md` 的部分 |

### 第 24 部分

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 4 | 正确性 2（mapType 误映射、继承字段 21）；可读性/契约 2（注释矛盾、`onlySkipped` 名不符实）。安全检查了外部输入面：本部分无网络/文件输入，反射输入来自宿主类型声明，未发现注入或敏感数据落日志 |
| §1 死代码 | 1 | 逐 private 符号全仓搜索（`sceneOk` 仅命中定义）；逐文件核 import（`TypeInfo` 未用）；逐局部变量核「赋值后是否读取」（`kind`/`base`/`rowName`/`i`）；`ReflectRegistrar` 为 `protected class`，其 `public` 成员按「全项目使用」核过——`retainedCount`/`resetRetainedForTest`/`mapType`/`mapTypeRef`/`buildCtor`/`isInstanceOfHost` 均有用例或内部调用，只有 `sceneOk` 无引用；`public` 顶层测试类由 `@Test` 框架调用，不判 |
| §2 重复逻辑 | 3 | 已把本部分 30 个函数体压成「输入→输出→副作用」两两比对：`median3` 三份逐字相同、`code<T>`/`codeOf` 同义、`append*`/`copy*` 与 `JitBindings.replace*` 同义、`isRefCode` 与 `LocalType.isHandle` 同源不同界、父类/自有成员注册路径近似但少一条诊断；`*_test` 里 `CompileCache.reset()+Compiler().compile()` 属测试准备代码（误报边界），不判 |
| §3 空实现 | 2 | `registerInterface` 父接口缺失走 `case None => ()`；`Skeleton_test` 恒真断言。本部分无 `TODO`/`FIXME`/`UnsupportedException`（已 grep）；`ReflectRegistrar.cj:102`/`:115` 的 `catch (_: Exception)` 是文档化的降级与再抛，不判 |
| §4 栈溢出 | 0 | 本部分无递归：`ancestryOf`/`isInstanceOfClass`/`mergeAncestor*` 均为显式循环且带深度上限；`indexOfText` 为双指针迭代。已核对两处上限不同（记入 §11），但不构成无界递归 |
| §5 OOM | 1 | `retained`/访问器表只增不减、无去重（上界=宿主类数，非请求驱动，故记轻微）；其余容器均为用例内局部 `ArrayList` |
| §6.1 热点瓶颈 | 0 | 本部分未提供 profile/bench 输出（`doc/perf-m2.md` 有 36×/9797→270ns 的既测数据，但属另一部分文件）；三条疑似热点写入「待验证假设」并注明采集方式，未计入发现 |
| §6.2 大粒度锁 | 1 | `Compiler.mtx` 内做完整反射枚举 + 逐字段建表（`Compiler.cj:137-142`）。注册期一次性路径，不在请求主路径；已改写进「优化可行性方案」，不作为缺陷 |
| §6.3 并发串行 | 0 | `spawn` 后都先收齐 `Future` 再统一 `get`（`Q6Acceptance_test.cj:630-663`、`RuntimeStateIsolation_test.cj:48-59`、`SignatureTableConcurrency_test.cj:112-147`），无 `spawn().get()` 串行化 |
| §6.4 低效算法 | 2 | `HostFieldTable.register` 每次全表重建（O(N²)，写入优化方案）；`indexOfText` 为测试内的 O(n·m) 子串查找（本可用 `String.contains/indexOf`，测试代码，仅记录） |
| §7 降堆内存方案 | 1 | `retained` + 重复访问器的生命周期对齐（无基线） |
| §8 降 CPU 方案 | 2 | 批量登记字段访问器（O(N²)→O(N)）；锁外计算 + 锁内短临界区 |
| §9 local mode 可行性 | 0 | 注册期产物（`ClassDescriptor`/访问器闭包/`TypeInfo`）按设计**必须**逃逸并长期存活（`retained` 就是为防 GC 回收），local region 会在函数返回时整块释放，语义直接冲突；用例内临时 `ArrayList` 峰值极小，无可证明收益，故不提案 |
| §11 现有代码的 BUG（存量） | 7 | 已核对：`mapType` 前缀（1）、继承字段执行层（2）、深度上限不一致（3）、父类成员无诊断（4）、`registerInterface` 静默（5）、保活表/访问器累积（6）、`T40Deopt` 全局配置泄漏（7）。`Q6Acceptance_test` 的 20 余处错误码断言已逐条对照 `ErrCode`，除注释外无误 |
| §12 并发安全与锁粒度 | 0 | 已列共享点与同步手段：`retained*` 三字段全部在 `retainedMtx` 内读写（`:66-93`）；`ClassRegistry` 每方法 `synchronized(this.mtx)`；`HostFieldTable` 用 `writeMtx` + `AtomicReference` 快照发布，`accepts` 在锁外求值（注释声明支持重入注册）；`Compiler.registerType/registerInterface` 整段持 `this.mtx`，锁序 `this.mtx → ClassRegistry.mtx → HostFieldTable.writeMtx` 与 `registerClass` 一致，未发现反向获取。用例内的共享可变状态（`Q6Acceptance_test.created`、`T40Deopt_test.boxId`、`SignatureTable.enabled`）已单列为测试隔离问题 |
| §14 功能完备性与 README 覆盖 | 0 | README/`doc/**` 不在本部分清单内，§13/§14 的文档对照留给含 `.md` 的部分；本部分只核对了 `Root.cj` 再导出清单与其注释声明（`JitContext`/`Engine`/`JitValue`/`CompileCache`/`AdapterRegistry`/`CompilePipeline` 确为 `protected`，未泄漏到用户面），一致 |
| 文件覆盖（§13 等） | 18/18 | 清单 18 个文件全部读完，无 `.md` 可对照 |

### 第 25 部分

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 2 | 设计：两套并行的引擎选择/编译入口（#2）；可读性：`A64Compiler.cj:70` 语句与函数签名同行、`A64Lower.cj:232-235` 用 `;` 连接的单行 case。安全性：本部分不解析外部输入，唯一外部接口是 `mmap/mprotect/munmap`（`CodeBuffer.cj:185-194`），参数均经页对齐与 `size <= 0` 校验，未发现注入/越权面；未发现硬编码凭据 |
| §1 死代码 | 1 | 逐个 `private`/`internal` 符号全仓搜过：`A64Emitter.ret/neg`、`A64Lower.bailLabel/u32`、`A64Cond` 的 6 个条件码常量零引用（#6）。`public` 且对外可达的 `A64Compiler.compileFunction(Far)`、`CodeBuffer.flushCount/pageSize`、`CompileCacheKey` 按硬原则一不判；`BackendX86_64/AArch64` 的 `public` 成员因所属类型 `internal` 而不可达，其零引用事实并入 #2（同一根因：整层未接线），不重复计数 |
| §2 重复逻辑 | 1 | 已把本部分 40 余个函数的「输入-输出-副作用」压平两两比对，外加跨文件搜同语义序列：命中 6 组（#7）。`emitPushI8/emitPushI32`→`emitPushI64`、`emitEqH/emitNeH`→`emitCmpEq/Ne` 属有意转调（语义即同一 opcode），不计；`0x7D/0x7E` 两个 case 同体属 opcode 表驱动，不计 |
| §3 空实现 | 1 | `BackendAArch64.entryThunkBase/For` 恒返回 0（`BackendSelector.cj:1860-1866`），接口注释未定义 0 的语义（并入 #2）。`emitCheckErrNc()` 返回空数组、`emitBreakpoint()` 返回 nop 均有注释说明是发布版 no-op，不算问题 |
| §4 栈溢出 | 0 | 本部分无递归：`A64Compiler`/`A64Lower`/`A64Emitter` 全为 `while`/`for` 迭代，`translate` 是 300 分支 `match` 无自调用；`fRoundOp`/`emitDump` 等只做线性发射。递归风险在 `f_svg`/`f_xml` 一类模块 |
| §5 OOM | 0 | 输出的三个容器（`out`/`labels`/`relocs`）规模由 `fn.codeLen` 与指令数线性界定，无跨请求/全局无界容器；`CodeBuffer.alloc` 按编译产物大小分配且失败返回 `None`（`CodeBuffer.cj:53-65`）；`audit` 每次编译新建、结束即弃（其分配成本见优化方案 §堆内存） |
| §6.1 热点瓶颈 | 0 | 无可复核 profile：本部分只有代码注释里引用的历史测量（`translate` 1.4-1.65 ms、`finish` 占 78-92%、598 次审计/编译），无本轮同环境对照。相关猜测全部进「待验证假设」，不写成缺陷 |
| §6.2 大粒度锁 | 0 | 本部分无锁：`BackendSelector` 的审计表在 aarch64 侧用实例字段（`A64Emitter.cj:460`），x86 侧用 `ThreadLocal`（`BackendSelector.cj:258-268`），临界区为空 |
| §6.3 并发串行 | 0 | 本部分无 `spawn`、无线程池、无批处理；`A64AuditIsolation_test.cj:38-42` 的 `spawn` 是测试同步手段（`writer.get()` 只为观察顺序） |
| §6.4 低效算法 | 0 | 已核：`labels` 是哈希索引（避免旧线性扫的 O(重定位×标签)）、`out` 按字存（避免每字 4 次 add）、`resolve` 单遍回填；未发现嵌套循环、`contains` 热点、`remove(at:0)` 或循环内字符串拼接（`hex32/hexBytes` 是测试辅助） |
| §7 降堆内存方案 | 1 | 发射审计只记非法基址（见优化方案） |
| §8 降 CPU 方案 | 2 | 整数标签键、`helperDispatch` 常驻 x21（见优化方案） |
| §9 local mode 可行性 | 0 | 本部分的临时对象是 `ArrayList<UInt32>`/`HashMap`/短字符串，均为编译期一次性产物且会逃逸成返回值（`Array<UInt8>`）或留在发射器实例上，不满足「函数内创建、函数内销毁」；且缺改前/改后峰值数据，无法成立 |
| §11 现有代码的 BUG（存量） | 5 | #1（frame imm12 截断）、#2（诊断承诺未兑现）、#3（`fRoundOp` 取整逻辑）、#4（`flushCounter` 竞态）、#5（`emitSetSite` 截断）。其余读到的边界均已核对：`A64Emitter.addOff` 分块、`strOff/ldrOff` 的 imm9/imm12/scratch 三档、`resolve` 的 ±128MB/±1MB 校验、`intDiv` 的 `INT_MIN/-1`、`floatCmp` 的 NaN 语义、`DUP2/SWAP` 的字序与 x86 侧一致 |
| §12 并发安全与锁粒度 | 1 | 唯一共享可变状态是 `CodeBuffer.flushCounter`（#4）；`A64Emitter` 的审计表按实例隔离（注释与 `A64AuditIsolation_test` 一致），`BackendX86_64` 的审计用 `ThreadLocal`。`BackendX86_64.thunkBuf/thunkCount` 是实例字段、无并发约定，未计入 |
| §13 文档一致性（.md） | 0 | 本部分文件清单无 `.md`（README/doc 属其他部分）；文中引用 `README.md:269`、`doc/design-m1.md:203` 仅作 #2/#3 的承诺源 |
| §14 功能完备性与 README 覆盖 | 1 | `BackendSelector`/`Backend`/`CompileCacheKey` 未接线且 `JitFallback` 诊断不发出（#2）；README:241-242 仍把 `BackendX86_64/BackendAArch64` 列为后端实现 |
| 文件覆盖（§13 等） | 18/18 | 无遗漏；本部分清单不含 `.md` |

### 第 26 部分

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 4 | 正确性：NE_F NaN、invokeOff 空指针；设计：双编码器；可读性：DiagCode/注释漂移。语言特性已核对 `struct` 值语义、尾表达式返回、`AtomicInt64`、`Equatable` 语义；无外部输入、无 SQL/注入面 |
| §1 死代码 | 1 | 逐个 `private` 符号在文件内计次：`movqRaxXmm`、`leaR8Rbp` 仅定义处命中（各 1 次）⇒ 死代码。`internal`/`internal class` 成员（`NativeAssets.onAlloc/onFree`、`X86Depth.*`、`JitArtifacts.*`）均有调用者；`public` 顶层可达者（`FnTable.size`、`ConstMirror.size`、`JitArtifacts.codeOf`、`NativeAssets.liveCount/resetCounters`、`PublicField.hasSignature`）按硬原则一**不判死代码**，只记「仓内仅测试使用」并入可见性建议 |
| §2 重复逻辑 | 3 | 已把 `X86Lower` 30 个函数体压成「输入→输出→副作用」两两比对：命中 (a) `X86Lower` 内联编码 vs `BackendX86_64.emit*`（跨文件、141 vs 11 引用）；(b) `helper`/`helperReg`/`callClosure`/`callFunc` 四处重复「设 rdi/rsi/rdx/rcx/rax + 对齐 + call」模板（差异仅在 checkErr 与深度记账）；(c) `bail` 与 `BackendX86_64.emitBail` 同一收敛序列两份。测试里的 `hex`/`nib`（`X86Frame_test.cj:71-102` 与 `X86Lower_test.cj:597-624` 逐字相同）按清单「测试准备代码」误报边界**不计入** |
| §3 空实现 | 1 | 无空函数体、无 `TODO/FIXME`、无 `catch {}`；`Base.cj` 整文件只有注释、无任何声明（骨架残留）。`0x02/0x06/0x7B` 的 `()` 与解释器 `Interp.cj:211-212` 的 no-op 一致，不是空实现 |
| §4 栈溢出 | 0 | 本部分无递归函数：`X86Lower.translate` 是单层 `match`，`X86Depth.analyze` 用扁平工作数组迭代（`work` 数组模拟栈），`JitCompiler`/`JitExecutor` 全是循环。深度上界由 `codeLen` 与 CFG 边数决定，无自引用结构 |
| §5 OOM | 0 | 分配量都由单元规模界定：`Array<UInt8>(total)`（机器码总长）、`Array<Int64>(consts.size)`、`FnTable.alloc(dir.size)`。无按不可信长度预分配、无无界容器。实参缓冲虽有 malloc 未判空（见发现 3），但容量由调用实参个数决定，不构成 OOM 面 |
| §6.1 热点瓶颈 | 0 | 未提供本部分的 profile/bench 数据（`scope.md` 只给 `docs/LocalMode*.md`），编译期与调用期热点均未成立，已写入「待验证假设」1–3 |
| §6.2 大粒度锁 | 0 | 本部分无锁：`X86Lower` 每次编译新建实例（线程封闭），`NativeAssets` 用 `AtomicInt64`，审计表是线程本地（`X86AuditIsolation_test` 锁定） |
| §6.3 并发串行 | 0 | 无 `spawn`（`NativeAssetsConcurrency_test` 的 4 线程是测试自身）；无「提交后立即 get」形态 |
| §6.4 低效算法 | 0 | `JitArtifacts.entry` 线性扫描 + `create` 逐函数查找是 O(n²)，但 n = 单元函数数、仅编译期一次，无测量数据，故不列为缺陷（并入「优化方案 · 堆内存」的编译期开销讨论） |
| §7 降堆内存方案 | 1 | 编译期三份码流副本（见优化方案 3），`无基线（待验证）` |
| §8 降 CPU 方案 | 2 | 双 `CHECK_ERR`、每次 invoke 的 malloc/free（均 `无基线`） |
| §9 local mode 可行性 | 0 | 候选只有 `X86Lower.add([...])` 的数组字面量（编译期、一次性、非峰值驱动），改用 `put` 直写即可，收益无法用峰值内存证明；且引入实验特性会锁 SDK 版本，判定不适用 |
| §11 现有代码的 BUG（存量） | 14 | 本轮读到的边界/空值/资源/契约项逐条核对：`FnTable.set/entry/at` 的越界与已释放分支、`create` 五条失败路径的释放对称性、`finish()` 缺标签返回 None、`invokeFn` 的 `off<0` 判据均已核对正确；命中项见上（1 严重 + 4 一般 + 9 轻微） |
| §12 并发安全与锁粒度 | 0 | 共享点逐一列举：`NativeAssets.allocs/frees`（原子）、`MachineEnv.fnTableBase`（`RuntimeEnv.current()` 线程私有，`RuntimeEnv.cj:104-126`）、x86 审计表（线程本地）。`JitExecutor.release()` 的 `released` 是非原子布尔，但 `JitFunction.unload` 契约要求排空活跃调用后才释放，未发现第二条共享路径，故不判不安全；`invoke` 路径只读实例字段 |
| §14 功能完备性与 README 覆盖 | 1 | 本部分不含 `.md`，无 README 面；唯一「承诺 vs 实现」缺口是 GAP-05 字段签名无消费点（发现 5） |
| 文件覆盖（§13 等） | 20/20 | 无 `.md` 文件；20 个 `.cj` 全部读完，无抽样 |

### 第 27 部分

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

### 第 28 部分

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 6 | Decimal 键不一致、负 epochNanos、sign/isClosed 校验、TypeNames 分类、`* 1` 可读性、`instantiateAll` 双跳；无注入/凭据类问题（本部分无外部字符串拼接进命令或 SQL） |
| §1 死代码 | 1 | 已逐个查 private/internal 符号引用：`ensureWritable`/`append`/`makeInstance`/`tokenOf`/`checkChildren`/`checkChildIndices`/`requireRules`/`checkCrc32`/`readDir`/`checkInstructionSet`/`readTypes`/`checkSiteCoverage` 均有调用者；`internal` 的 `u32ToI32`/`i32ToU32`/`u64ToI64`/`i64ToU64`/`NANOS_PER_SECOND`/`OP_SET_SITE`/`decimalFromParts`/`parseJsonConst`/`compileRegex`/`normalizeRegexFlags`/`decimalParts`/`encodePayload`/`decodePayload`/`utf8OrReject`/`hexOf64`/`sliceOf`/`hexOf32` 均被引用；顶层 `protected class ConstMapKey` 及成员 `value`/`token` 被 `ConstRegistry` 与 `IterTable.cj:204` 使用；对外可达的 `public`（`ByteReader.seek`/`f64bits`、`TypeToken.name`、`FbcReader.supportedMajor`/`maxSupportedMinor`/`minVerMinorOf`/`LoadedUnit.entry`、`CanonKey.i64`/`f64`）按硬原则一不判死代码，只记「仓内无生产调用」信息；唯一命中是空占位文件 `Bytecode.cj` |
| §2 重复逻辑 | 5 | 已把 20 个文件里的函数体按「输入→输出→副作用」压成一览两两比对：命中 Decimal 文本解析三套、常量索引/图校验两套、hex/i64-cell/legacy 判据/regex flags 四处小复制、手工拷贝 vs `sliceOf`、三趟指令扫描（后者并入 CPU 优化方案）；测试内的字节拼装辅助按 checklist 误报边界不计 |
| §3 空实现 | 1 | 无空函数体、无 `TODO`/`catch {}`；唯一命中是 `Bytecode.cj` 的占位注释 |
| §4 栈溢出 | 1 | `makeInstance`/`tokenOf` 的 DAG 递归深度等于输入嵌套层数且无上限（已给可达深度推导：约 9 字节/层）；本部分无其他递归 |
| §5 OOM | 1 | `decodePayload` 的预分配都先过 `remaining` 粗筛（`Int64(n)*4`/`*8`），不构成「按不可信长度预分配」；命中项是递归 + 每层分配（与 §4 同源），以及 `load` 期的整段副本（写成优化方案，未算缺陷） |
| §6.1 热点瓶颈 | 0 | 本部分无 profile/bench 数据，`decFromText`/`tokenOf`/三趟扫描都只进「优化方案（无基线）」与「待验证假设」，未写成缺陷 |
| §6.2 大粒度锁 | 0 | 本部分无锁；`ConstRegistry` 的并发风险是「缺同步」而非「锁太大」 |
| §6.3 并发串行 | 0 | 本部分无 `spawn`/批处理/队列 |
| §6.4 低效算法 | 1 | `tokenOf` 的 `+` 拼接 O(n²) 与 `decFromText` 的逐字符分配已定位（复杂度可静态判定），但收益占比无数据，故只作优化方案 |
| §7 降堆内存方案 | 1 | `load` 期整段副本（crc 副本 + 四段副本） |
| §8 降 CPU 方案 | 3 | 合并三趟扫描、`decFromText` 去逐字符拼接、`tokenOf` 单缓冲 |
| §9 local mode 可行性 | 0 | 本部分无「函数内创建、函数内用完」的大对象（`ConstRegistry` 的实例是长期对象，`tokenOf`/`decFromText` 的临时串是小对象且需逃逸为键）；收益无法用峰值内存证明，不改 |
| §11 现有代码的 BUG（存量） | 4 | 命中：负 epochNanos 抛宿主异常、`PDec.sign`/`PRange.isClosed` 未限取值、`compileRegex` 计数早于编译（与注释不符）、`flags.bit0` 未按「恒 1」校验。已排除的边界：`ByteReader` 的 `need`/`bytes`/`seek` 越界均走 `rejectFormat`；`sliceOf` 的 `off+len` 不溢出（源为 u32）；`validate` 的 `raw.size - payloadOff` 在 `hdrSize` 异常时先被 hdrSize 校验拦下；`checkInstructionSet` 的 `code[p]` 上界由 `FuncDir.validate`（`FuncDir.cj:187-200`）保证 |
| §12 并发安全与锁粒度 | 2 | `regexCompileCount` 静态计数非原子、`instanceAt` 缓存检查-然后-写入（均已指出共享路径与缺失同步手段）；`LoadedUnit` 字段全 `let`，加载后发布安全；`FbcReader` 静态成员全为 `let` 常量 |
| §14 功能完备性与 README 覆盖 | 0 | README/`README_en` 不在本部分文件清单（属其他部分），未做逐符号对照；本部分只发现 `TypeNames` 分类与桥能力不一致（已按 §10 报），未见「承诺但未实现」 |
| 文件覆盖（§13 等） | 0/0 | 本部分无 `.md` 文件，§13 无对象；20 个 `.cj` 全部读完 |

### 第 29 部分

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

### 第 30 部分

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 4 | 正确性：#1（终结语栈约束）；可读性：#10/#11；设计：无分层问题（编译器内部管线职责清晰）；语言特性：`internal` 类型的 `public` 成员按硬原则二判死代码（#2/#3）；安全性：无外部输入拼接、无注入面（编译产物只写出字节） |
| §1 死代码 | 5 | 已逐个 `private`/`internal`/`protected` 符号全仓搜引用（排除 `.worktrees`）：`BytecodeBuilder` 4 个成员 + `CaptureDescriptor.describe` 零命中（#2）；`Capture_test.err` 零命中（#2）；`AstExpr.MemberName` 14 处全为 `case`、无构造（#3）；`Assembler` 2 个死 import（#4）；`place` 恒真分支（#5）。`TypeRef.hostParamNames/hostRetName` 仅 `TypeRef_test` 使用，按「仅测试引用 = 可见性建议」处理，未计入 |
| §2 重复逻辑 | 3 | 已把 `Assembler`（14 个函数体）与 `BytecodeBuilder`（30 个函数体）逐个压成「输入-输出-副作用」比对：`effectArgc`≡`argcOfInsn`（#6）、`fixupRel`≡`patchAll`（并入 #2）、hex/u16/补码三组原语（#7）。测试文件的 `errKind/errText/compile` 8 份同形辅助属「测试准备代码」误报边界，未计入 |
| §3 空实现 | 0 | 全 17 文件无 `TODO`/`FIXME`；15 处 `catch` 全部把 `kind`/`message` 取出用于断言，无静默吞异常；无空函数体 |
| §4 栈溢出 | 0 | 生产文件（`Assembler`/`BytecodeBuilder`/`Ast`/`Capture`）无递归；`AstShape.shapeE/shapeS` 按 AST 深度递归（深度由源码嵌套决定、无环），但只被测试与诊断调用，不在生产降低/汇编路径上，记入说明不计为缺陷 |
| §5 OOM | 0 | 无全局只增容器（`CompileSession` 每次 `compile()` 新建，`SourceCompiler.cj:125`）；`Assembler` 的 `bodies/entries/slots` 全部按函数数/栈深线性、随编译结束释放；`Array` 预分配均来自自产常量而非不可信报文 |
| §6.1 热点瓶颈 | 0 | 未提供本模块 profile / bench 数据，无法成立热点结论，已列「待验证假设」#1/#2 |
| §6.2 大粒度锁 | 0 | 本部分无锁：`Assembler`/`BytecodeBuilder` 是单次编译内的可变对象，无 `Mutex`/`synchronized` |
| §6.3 并发串行 | 0 | 无 `spawn`/`Future`/批处理，编译器全同步单线程执行 |
| §6.4 低效算法 | 2 | `nargsOf` 线性查表（进「优化可行性方案」[CPU]，无基线不计缺陷）；`AstShape` 循环字符串拼接 O(n²) 仅测试诊断路径，不计 |
| §7 降堆内存方案 | 1 | 见「[堆内存] assemble() 期 code 段的两份副本」（无基线） |
| §8 降 CPU 方案 | 1 | 见「[CPU] Assembler.nargsOf 的线性查表」（无基线） |
| §9 local mode 可行性 | 0 | 本部分无「函数内创建并在函数内用完的大对象」：`Assembler.assemble` 的产物必须逃逸为返回值，`BytecodeBuilder` 的 `code`/`slots` 存进成员并跨调用存活，逃逸检查不通过 |
| §11 现有代码的 BUG（存量） | 8 | 本轮读到的全部函数边界/空值路径已逐个核对：#1（终结语校验缺口）；#3（不可达 `match` 分支）；#5（恒真守卫）；#7（hex 大小写漂移 + 注释理由不成立）；#8（测试覆盖名不副实）；#9（恒真断言）；#10（失败路径资源不对称）；#12（注释与 `FbcReader` 实际校验不符） |
| §12 并发安全与锁粒度 | 0 | 已确认线程封闭：`SourceCompiler.compile` 每次新建 `CompileSession`/`Lowerer`/`Assembler`（`SourceCompiler.cj:125-129`），本部分类无静态可变状态、无共享注册表写入；`FbcRuleRegistry.get` 只读 |
| §14 功能完备性与 README 覆盖 | 1 | 本部分无 `.md`（README 覆盖留给含 README 的部分）；#8 的「承诺覆盖但未覆盖」按 §14 的「承诺源 + 缺失证据」口径记一条 |
| 文件覆盖（§13 等） | 17/17 | 与 `files/f_jit.part30.txt` 逐行一致，无未读文件；本部分无 `.md`，§13 不在本部分适用 |

### 第 31 部分

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 5 | DA 作用域不一致、DA 弃用返回值、空安全接线、`\u{}` 上界、`tokenize` 注释；分层（前端/降低/汇编）与依赖方向无违规；本部分无外部输入拼接、无凭据 |
| §1 死代码 | 4 | 已逐个 `private`/`internal`/`protected`/对外不可达 `public` 搜引用：`ClassRegistryView.registeredList/isHostObjectCode/isValueCode` 零引用（对外不可达）；`Lexer` 两处恒假分支；`Compiler.cj` 空文件；`DiffExec_test` 未用 import。另：`Lexer.position/line/column/lastRegexFlags` 仅测试引用 → 记为可见性建议不判死代码；`CodeDump`、`CompileSession` 全部成员、`Diag` 四个出口、`dedentAnchored/emitAnchoredLine/sliceStr/decodeEscapes/hex2/normalizeNewlines` 均有调用 |
| §2 重复逻辑 | 3 | ① `walkExpr`/`walkExprWithOuter`（+`walkStmt`/`walkStmtWithOuter`）两份平行遍历且已漂移；② `checkNullStore` 的 `TypeRef→码` 映射与 `TypeRef.code()` 逐分支重复；③ 同一 `normalizeNewlines` 每次编译被调 4 次（记入 CPU 方案）。测试文件的准备代码（各 `_test.cj` 的 `compileM3/errKind` 模板）属刻意独立，不判重复 |
| §3 空实现 | 2 | `Compiler.cj` 空骨架；DA 空安全规则 3 在赋值路径上等价于空实现（已并入发现）。`DummyDiagnosticsSink` 是设计内的 null object（有文档说明），不判 |
| §4 栈溢出 | 1 | `walkExpr` 无深度上限（严重）。`Lexer.findBodyEnd/skipInterp`、`dedentAnchored`、`escapeLen` 均为迭代实现，无递归；`analyzeClosureAt` 的递归深度并入同一发现 |
| §5 OOM | 0 | 无全量读入、无按不可信长度预分配；唯一无界物化是 Parser 的 `Token` 数组，规模由源码长度线性决定，记入堆内存方案而非 OOM 缺陷 |
| §6.1 热点瓶颈 | 0 | 本部分未提供 profile/bench 数据；全部性能线索（规范化重复、HashMap 克隆、token 物化）已进「待验证假设」，不作热点结论 |
| §6.2 大粒度锁 | 0 | 本部分无任何锁（`Lexer`/`DefiniteAssignment`/`CompileSession` 均为单次编译内对象） |
| §6.3 并发串行 | 0 | 无 `spawn`/`Future`；无并发窗口配置 |
| §6.4 低效算法 | 1 | `CodeDump.dump/ops` 的 `out = out + …` 循环拼接与 `DefiniteAssignment.sameKeys` 的 O(n²) 集合比较：仅在测试/极小集合上运行，未列为缺陷；`ClassRegistryView.classOf` 线性扫描在有 `requireField/requireMethod` 里被重复调用一次（同一 `classOf` 跑两遍），量级为类数×成员数，无数据支撑，不列 |
| §7 降堆内存方案 | 1 | Token 物化 + 每 token 两次分配（已给方案，无基线） |
| §8 降 CPU 方案 | 1 | 换行规范化 4 次（已给方案，无基线） |
| §9 local mode 可行性 | 1 | DA 的每分支 `HashMap` 克隆与 `snapshotKeys` 数组是典型「函数内创建、函数内销毁」，但缺峰值内存数据，只进「待验证假设 #4」；未确认 `HashMap` 的 local 构造重载 |
| §11 现有代码的 BUG（存量） | 4 | DA 作用域、DA 空安全接线、`\u{}` 上界、`CodeDump` 越界；另核对 `Diag.lineTextAt`（越界返回空串，正确）、`CompileSession.funcAt`（越界 `diagFail`，正确）、`Lexer.at()`（负/越界返回 0，正确）、`Lexer.scanNumber` 各分支（`1..2`/`1.2.3`/`3e`/`12abc` 均按预期分类） |
| §12 并发安全与锁粒度 | 0 | 线程封闭论证：`Lexer`/`DefiniteAssignment`/`CompileSession`/`ClassRegistryView` 都在 `SourceCompiler.compile` 内构造并只被该调用使用；`ClassRegistrySnapshot` 构造时 `clone()` 入参数组；本部分无 `static var`/单例可变字段。故不判共享可变状态 |
| §14 功能完备性与 README 覆盖 | 1 | 空安全规则 3 的接线缺失（并入发现）；本部分不含 `.md`，无可对照的 README 段落，专项覆盖在模块其余部分 |
| 文件覆盖（§13 等） | 17/17 | 全部读完；本部分无 `.md`，§13 文档一致性不适用 |

### 第 32 部分

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 6 | 正确性 #1–#6；设计 #3（`last*` 单槽旁路）、#4（类名口径两套）。安全性：无外部输入拼接、无凭据、无注入面（编译器只消费 DSL 源码） |
| §1 死代码 | 4 | `fnRetType` 无引用（#9）；`ALLOW_ESCAPING_HANDLES` 恒真使 #8 块不可达；`AstExpr.MemberName` 无构造点致 8 处分支不可达（#10）；`emitArith` 的 STRING 分支不可达（#11）。已逐个 private 符号全仓搜引用、逐条 `return/throw` 后语句检查；`internal`（`toStrTag`）有同文件调用者；`Lowerer`/`VarSym`/`FnCtx` 为 `internal` 类型，其 `public` 成员均有仓内使用（`captureDescriptors` 见 `SourceCompiler.cj:149`），不判 |
| §2 重复逻辑 | 1 | 合并为 #12，列出 5 组逐行/近逐行重复；函数体两两比对覆盖 `lowerExpr` 全部分支与 45 个 private 方法 |
| §3 空实现 | 1 | #1 的 `initE == None` 分支只校验不产码，等价于「声明无实现」。其余无空函数体、无 `TODO`/`FIXME`、无 `catch {}`；`ResolvedCall.HostClosureCall → notImplFail`（`:2580-2581`）是显式未实现错误而非静默空实现 |
| §4 栈溢出 | 0 | 递归仅出现在 AST 遍历（`scanExpr`/`scanStmt`/`originOfExpr`/`staticTypeFull`/`hostObjectClassOf`），深度 = 源嵌套深度，`Parser` 先递归同一结构、Lowerer 不放大；无自引用数据结构、无每帧大对象；尾递归已改回边（`:805-842`）。深嵌套上限未实测，列入待验证假设 #2 |
| §5 OOM | 0 | 所有容器按本单元声明/表达式数增长（`pendingNames`/`closureRets`/`closureParams`/`captureDescs`），无按报文长度预分配、无全局只增不减集合；`constIndexOf` 的常量登记由 `ConstRegistry` 去重。量级评估见优化方案 1（堆内存） |
| §6.1 热点瓶颈 | 0 | 本部分无 `cjprof` / `cjpm bench` 数据，未成立热点；候选写入待验证假设 #1/#3 |
| §6.2 大粒度锁 | 0 | 全文件无锁、无 `synchronized`、无 `Mutex` |
| §6.3 并发串行 | 0 | 无 `spawn`、无 `Future`、无线程池 |
| §6.4 低效算法 | 0 | 已定位两处复杂度问题（`flushNames` 插入排序、作用域线性查找），但无输入规模/耗时数据，按铁律只进优化方案 1/2 与待验证假设，不计发现 |
| §7 降堆内存方案 | 1 | 优化方案 1（`flushNames` 副本 + 排序）。`clear()`/`gc()` 假象不适用（无 `clear` 调用） |
| §8 降 CPU 方案 | 1 | 优化方案 2（作用域 `HashMap` + 复用静态类型结果） |
| §9 local mode 可行性 | 0 | Lowerer 是编译期单线程前端，收益口径是编译期峰值内存，`docs/LocalMode*.md` 的基线针对运行期；无前后峰值对照 ⇒ 按 §9 只能判「不评估」，不写成建议 |
| §11 现有代码的 BUG（存量） | 7 | 即 #1–#7；另逐条核对了 `lowerStmt`/`lowerExpr` 全部 30+ 分支的边界（空集合、`None`、越界索引、算术除零）与句柄/常量登记生命周期（`allocCtorHelper` 按 `(className, ctorIndex)` 去重，`CompileSession.cj:190-202`） |
| §12 并发安全与锁粒度 | 0 | `Lowerer` 由 `SourceCompiler.compile` 每次新建（`SourceCompiler.cj:127`），`ctx`/`last*` 是可变的实例状态但**线程封闭**；`sess.consts`/`sess.names` 亦随会话新建。无线程共享路径，无锁可谈 |
| §14 功能完备性与 README 覆盖 | 0 | 本部分只含 `.cj`，README 覆盖由其他部分负责；代码内承诺与实现的一致性已查（`ResolvedCall.HostClosureCall` 是显式 Q3.5 未接入，实现与注释一致） |
| 文件覆盖（§13 等） | 1/1 | 清单 1 个文件全部读完，无缺项 |

### 第 33 部分

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 7 | 正确性 5（#1–#5）、测试隔离 1（#6）、可读性 1（#14）；安全性 0 条：本部分无 IO / SQL / 凭据，唯一不可信输入是 lambda 源串，风险已并入 #5 |
| §1 死代码 | 4 | #7（3 个判定函数）、#10（2 个死字段）、#12（`snapshotOf`）、#13（`MemberName` 分支）；另 #9 的 `DT_NEW`/`DUR_NEW` 与 #16 的 `compileKindV2`。已逐个 private / internal 符号全仓搜引用；`protected` 顶层类型（`CompiledSourceUnit`/`SourceCompiler`/`PredefinedSnapshot`/`HostClosureSigDecl`）均有使用者，无"零引用 protected"；`Op`/`HelperCodec`/`StackEffect` 成员逐个 grep；对外可达的 public 不判 |
| §2 重复逻辑 | 2 | #11（换行规范化两份实现、链上 4 次）、#14（四段配对扫描 + 重复文档）；另 #7 的 `isUncondJump` 被内联重写。本部分函数体已两两比对「输入-输出-副作用」（`Parser.cj` 单文件 71 个函数），跨文件按字面量 / 错误文案 / 正则搜过 |
| §3 空实现 | 0 | 本部分无空函数体、无 `TODO`/`FIXME`、无 `catch {}`；`buildJsonExpr` 只做形态判定但注释明示"JSON 语法在降低阶段解析"，非空实现 |
| §4 栈溢出 | 1 | #5：`parseExpr` 递归链无深度上限（AST 递归侧 `tailValueOf` 同源）。`parseDigits`/`splitTailExpr` 均为单层循环 |
| §5 OOM | 0 | 唯一全量物化是 `Lexer.tokenize()` 的 token 数组，规模由源码长度线性决定、无按报文长度预分配、无无界容器（`PredefinedSnapshot`/`CompiledSourceUnit` 均随单次编译结束释放）；降分配建议见优化方案 |
| §6.1 热点瓶颈 | 0 | 未提供 profile / bench 数据（`PerfCompare_test` 只有单次采样），热点结论未成立，已列入待验证假设 1/5 |
| §6.2 大粒度锁 | 0 | 本部分无锁；`Ops.TABLE` 是 `private static let` 只读表，无锁内工作 |
| §6.3 并发串行 | 0 | 本部分无 `spawn`/`Future`；`SourceCompiler.compile` 每次自建 `CompileSession`/`Lowerer`，无共享串行点 |
| §6.4 低效算法 | 2 | #3（文法歧义使合法表达式不可用，归类于此）、`slotOf` 线性扫描（无数据，已降为待验证假设 5） |
| §7 降堆内存方案 | 2 | 见优化方案「去掉重复的整源规范化副本」「语句数组各留一份」 |
| §8 降 CPU 方案 | 2 | 见优化方案「预定义函数名查找」「删除死字段顺带去掉一次整源哈希」 |
| §9 local mode 可行性 | 0 | 不可行：`Parser` 的 `Array<Token>`、`Array<AstStmt>`、`AstExpr` 全部经返回值逃逸给 `Lowerer`（`SourceCompiler.cj:117-128`），`@local!` 值不得作为 `@ ~local` 返回；且 `String.fromUtf8` / `Lexer.sliceStr` 无 local 重载，逐点重建的改造成本远超收益 |
| §11 现有代码的 BUG（存量） | 17 | 全部 17 条均标 `[存量]`（快照模式无 diff）；本部分 4 个源文件的函数边界、`Option` 取值（`peekAt` 越界回退 EOF）、空集 / 除零分支均已核对 |
| §12 并发安全与锁粒度 | 1 | #6：测试翻转 `SignatureTable.enabled`（`public static var`，运行时无同步读）造成跨线程写读；本部分其余类型无线程共享路径（`Parser`/`SourceCompiler` 每次编译新建，`PredefinedSnapshot` 构造后只读） |
| §14 功能完备性与 README 覆盖 | 0 | 本部分无 `.md`；对照 `f_jit/README.md` 的公开面，`Compiler`/`SourceCompiler` 对外能力均已在 README 描述（`README.md:301/318/370` 覆盖插值、`276` 覆盖 `DT_NEW`/`DUR_NEW` 禁发）。#1 的插值内构造调用属实现缺口而非 README 缺段 |
| 文件覆盖（§13 等） | 16/16 | 本部分清单 16 个文件全部读完，无 `.md`；`f_jit/src/compiler` 目录共 59 个文件，其余 43 个不在本部分清单内 |

### 第 34 部分

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 9 | 正确性 7 条（setter 名、init 忽略、码表缺 15–19、null 转储、malloc 判空、splitTopLevel、JitSignatures 命名）+ 设计 2 条（接口静态成员未接线、码表两处复制）；安全性：本部分无外部输入解析（`Token` 由 `Lexer` 产出、`DbgDump` 只读自有缓冲），无注入面 |
| §1 死代码 | 4 | 逐个 `private`/`internal` 符号全仓搜引用：`buildMethod`/`buildCtor`/`buildStaticValue`/`capitalize`/`codeOf`/`classNameOf`/`tk`/`splitTopLevel`/`parseSignature`/`buildStmt`/`funcNameOf`/`identifierOf`/`propagateFrozen`/`anyValueOf`/`anyMatches`/`classBoundHit`/`listAuxMatches`/`mapAuxMatches`/`beginDump`/`slotText`/`joinItems` 均有调用者；命中 4 条 = `DUPLICATE_REGISTRATION`（零引用）、`fromVar`（死参数）、`anyIs` 占位变量、`anyBox` 恒假子条件。`StarStar => 90` 等 ordinal 值仅需互异（已核对 63 项无重复） |
| §2 重复逻辑 | 8 | 已两两比对 30+ 函数体的「输入-输出-副作用」：码表（缺 15–19）+ 码表两份副本、setter 名×2（宏/反射）、参数装配×3、`report` 重载×2、`hex/nib`×4、`errKind/errText`×10、`countOf`×4、`MacroExpandDecl` 下钻×2；其余（`anyValueOf`/`anyMatches`/`writeOnce` 两重载）确认差异是承载形态（CPointer vs Array、值型 vs 句柄型），属有意展开 |
| §3 空实现 | 2 | `@IgnoreJitBinding` 对 `init` 的承诺落空、接口静态成员落进 `_ => ()`；`JitSignatures()` 无属性重载的「告警 + 原样返回」是有意行为，不算空实现 |
| §4 栈溢出 | 0 | 本部分无递归函数：`MacroExpandDecl` 下钻是 `while` 迭代（`IgnoreJitBinding.cj:43`、`JitBind.cj:203`），`splitTopLevel`/`parseSignature` 为单层扫描；无自引用结构遍历 |
| §5 OOM | 0 | `allocateDump` 的大小来自字节码目录 `maxNLocals`（可信、有界），`anyBox`/`anyAs` 单槽分配且受 `HandleTable.capacityLimit`/窗口上限约束；`report` 的 `ArrayList` 长度 = `nLocals`。无「按报文字段预分配」「只增不减容器」 |
| §6.1 热点瓶颈 | 0 | 未提供 profile / bench；本部分无 `cjprof` 数据，三条疑似热点已全部降级为「待验证假设」 |
| §6.2 大粒度锁 | 0 | 本部分无锁：`AnyHelpers` 操作的是全局 `HandleTable`（其同步在 `HandleTable` 内部，不属本部分），`DbgDump` 只写 ctx 私有缓冲 |
| §6.3 并发串行 | 0 | 无 `spawn`（`CanonKey_test` 的 4 线程是测试本身，任务独立、无批内串行） |
| §6.4 低效算法 | 0 | 唯一 O(n²) 候选是 `report` 的字符串累加，`n` 为 `nLocals`（个位数到几十），且只在错误路径执行一次；无基线，已列入假设 #1 |
| §7 降堆内存方案 | 0 | 本部分无长生命周期容器：`DbgDump` 的缓冲由 `JitFunction` 每次调用分配/释放且已 `NativeMem` 计数，`AnyHelpers` 不持有跨调用状态；无「缩短生命周期/去副本」的可量化收益 |
| §8 降 CPU 方案 | 1 | 唯一候选是 `report` 的字符串累加改为一次性构建（方案见「优化可行性方案 [CPU]」）；无改前基线，只标「无基线（待验证）」，同时登记为假设 #1，不进修复清单 |
| §9 local mode 可行性 | 0 | 本部分函数内无「大临时对象」：宏在编译期执行（与运行期 local region 无关），`AnyHelpers` 每调用只产生 1–2 个句柄无大对象；`DbgDump` 的临时集合是 `nLocals` 个短串，峰值由 `nLocals` 界定，收益无法用峰值内存证明 |
| §11 现有代码的 BUG（存量） | 9 | 已核对本部分 6 个非测试 `.cj` 的边界/空值/错误路径：setter 名、init 忽略、码表缺 15–19、null 转储、malloc 判空、splitTopLevel、JitSignatures 命名、接口静态成员、码表两份副本；11 个测试文件只做逻辑核对（不把测试自身缺陷计为产品缺陷，只留 2 条轻微可读性） |
| §12 并发安全与锁粒度 | 0 | 无共享可变状态：`JitContext` 每次调用新建（`JitFunction.cj:605` 处分配 `dump`）、`DbgDump` 的静态成员全是 `const`/纯函数、宏在编译期单线程执行；`HandleTable.capacityLimit` 的改写只在 `AnyHelpers_test.p2_6` 内且 `finally` 还原（测试隔离问题，非产品并发缺陷） |
| §14 功能完备性与 README 覆盖 | 1 | 接口静态成员「承诺覆盖但未接线」（一般）；本部分无 README/`doc/**`（模块文档不在 `part34` 清单内，交由其它部分核对），故不做 README 符号对照 |
| 文件覆盖（§13 等） | 17/17 | 清单 17 个文件全部读完，无缺读；本部分无 `.md`，§13 的「文档↔实现」以代码内注释契约代替核对（命中 2 条轻微：`Token` 注释表、`HEADER_WORDS`） |

### 第 35 部分

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

### 第 36 部分

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 8 | 正确性 6 条（浮点位型、INEG、IADD_WRAP、取整族、TO_I64 边界、深度保护）、可读性 1 条、设计（类型表双份）1 条；无外部输入注入面（本部分不解析字符串），安全性未命中 |
| §1 死代码 | 3 | 逐符号机械搜索：`private` 全仓、`internal` 本包及子包；`as*`×12 / `isContainerToken` / `Interp.typesOf` / `mapHandle` / `bail` 第三参 / `0x44` 死压栈 / `&& false` 分支 / `ret=13` / `mapToken 14` 均命中；`public` 对外可达符号（`Interp`、`HostFieldTable`、`HostFault`、`JitContext`、`NativeMem`、`IterTable`）不判，仅记录仓内引用情况 |
| §2 重复逻辑 | 3 | 两两比对本部分 30+ 函数体：LocalType→TypeToken 双表、位型重解释 4 份、JSON 16–19 四连分支、marshal 分派近似重复；其余（`as*` 族、`setup/teardown` 样板）已归入 §1 或测试模板，未计 |
| §3 空实现 | 0 | `jsonSet/jsonNew` 的 `let unused = ctx` 是参数占位而非空实现；`Init`/`clear` 类方法均有实体行为；未见 `TODO`/`catch {}` 静默吞异常（`IterTable.advance` 的兜底 `catch` 会写 99，属显式失败） |
| §4 栈溢出 | 1 | 解释器无深度计数（发现 #6）；`HostFault.describe` 的 causedBy 链有 `depth < 8` 上界，不成立 |
| §5 OOM | 0 | 本部分无「按报文长度预分配 / 全量物化」；Map 迭代的窗口增长已按资源不对称报在 §11（发现 #8），不重复计 |
| §6.1 热点瓶颈 | 0 | 无 profile/bench 数据，全部转「待验证假设」#1–#4 |
| §6.2 大粒度锁 | 0 | `HostFieldTable.writeMtx` 仅护注册（临界区内只有内存拷贝，无 I/O/回调；`accepts` 明确在锁外求值）；`pinConst` 的全局锁在 `HandleTable.cj`（范围外） |
| §6.3 并发串行 | 0 | 本部分无 `spawn`+`get()`、无单消费者队列 |
| §6.4 低效算法 | 1 | Map 迭代 O(n²) 归入发现 #8 的资源面与优化方案 1；`clz64/popcnt64` 逐位循环是 ISA 语义实现，非热点证据 |
| §7 降堆内存方案 | 1 | `InterpFrame` 预分配/池化（含 local mode 不可行结论） |
| §8 降 CPU 方案 | 3 | 迭代 pin、注册整表复制、字段查找线性扫描 |
| §9 local mode 可行性 | 1 | 结论：不可行（`InterpFrame`/`locals` 逃逸、`ArrayList` 无 mode 重载），已写在 §7 附注；无峰值内存数据支撑任何改造建议 |
| §11 现有代码的 BUG（存量） | 10 | 见「发现」全部 15 条的 §11 判据条目（其中 10 条归 §11 主判据）；均为存量（快照模式） |
| §12 并发安全与锁粒度 | 2 | `HostFieldTable` 快照 + 原子发布（安全，`find` 锁外 `accepts` 可重入，已有用例）；`IterTable`/`HostFault`/`Interp` 均线程封闭（TLS 或每调用新建，`CompilePipeline.cj:247-250` 每次构造 `Interp`）⇒ 无线程共享路径；`JitContext.readAt/writeAt` 的跨线程误用风险并入发现 #10 |
| §14 功能完备性与 README 覆盖 | 2 | 0x39/0x4A–0x4D 有 ISA 与 `Ops` 登记但前端无发射点（已在 #3/#4 注明）；本部分不含 `README*.md`，README 覆盖归其他部分，未重复判 |
| 文件覆盖（§13 等） | 17/17 | 全部 17 个 `.cj` 已读；本部分无 `.md` |

### 第 37 部分

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 4 | F1（生命周期）、F7（函数类型逆变口径）、F8（`let` 数组可变）、F10（哨兵语义反向）；无外部输入解析，无注入面 |
| §1 死代码 | 3 | F2、F3、F11。已逐个 `private`/`internal` 符号全仓搜引用（`powMulChecked`/`addLocked`/`releaseLocked`/`countOf`/`dropId`/`signatureToken`/`probeType`/`componentMatches`/`arityMatches`/`paramMatches`/`returnMatches`/`pos1`/`pos2a`/`pos2b`/`ret0-2`/`shortestDigits`/`plainOf`/`plainOrSci`/`signedExp`/`bitsOf`/`intToStr`/`pow2`/`pow5`/`roundToSignificant`/`userHelperArg`/`userHelperToken`/`reflectiveInvoke*`/`convertArgs`/`cellToHostValue`/`buildTable`/`stack` 均有调用者）；`internal` 字段 `wins/freeWins/iters/faults/freeHint/typeCodes` 均有使用方；对外可达的 `public`（`PromotionGroup.contains/size/release`、`SignatureVerifier.cached/verify`、`HostCallback.init(fn)`、`UserHelperTable.push`、`TextFormat.pad2/pad4/pad9/offsetText`、`SignatureTable.buildCount/entryCount`）仓内仅测试或零引用，按硬原则一**不判死代码**，已在 F14 记为冗余入口/可见性建议 |
| §2 重复逻辑 | 3 | F14（薄包装双入口）、F15（三张码表）、F16（逐参转换两份）。已把本部分 60+ 个函数体压成「输入→输出→副作用」两两比对：`pos*/ret*` 六张表的重复是语言所限（`is` 需静态类型）不判；`add/addLocked`、`release/releaseLocked` 是锁壳惯用法不判 |
| §3 空实现 | 1 | F12（`Runtime.cj` 全文只有注释）。其余无空函数体、无 `TODO`、无 `catch {}`（`ipow` 的 `catch` 有明确转码） |
| §4 栈溢出 | 0 | 本部分无递归函数；`ipow` 是迭代快速幂（O(log exp)）。递归风险在 `CallMarshal.promoteClosureGraph`（范围外，见总评） |
| §5 OOM | 0 | `convertArgs`/`marshalArgs` 按 `sig.params.size` 分配，该值来自注册期（宿主可信），且 `SignatureTable` 有 128 条上限；`typeCodes` 上限 32；helper 栈由 `finally` 成对弹出。未发现按不可信长度预分配或无界容器 |
| §6.1 热点瓶颈 | 0 | 未提供 profile/bench 数据；F2 相关的 f64/提升组开销已列入「待验证假设」1–3 与优化方案，不作为缺陷 |
| §6.2 大粒度锁 | 0 | 提升组锁内只做清单/HashMap 操作，但会取全局 `HandleTable.mtx`；无持有时长数据，按规则记为假设 #1 而非缺陷 |
| §6.3 并发串行 | 0 | `PromotionGroupConcurrency_test` 用 4 线程真并发释放，无 `spawn` 后立即 `get()` 的形态（测试里统一汇合属正常用法） |
| §6.4 低效算法 | 0 | `pow5` 逐次乘法、`getOrBuild` 线性扫（≤128）、`dropId`/`contains` 线性（组小）均为线索；缺复杂度占比数据，只写进优化方案（TextFormat）与假设 |
| §7 降堆内存方案 | 1 | 提升组 1 元数组 + snapshot 数组（无基线） |
| §8 降 CPU 方案 | 1 | `TextFormat` BigInt 展开与常量重解析（无基线） |
| §9 local mode 可行性 | 0 | 临时对象是 std `BigInt` 与 `ArrayList<Rune>`，std 无对应 mode 重载；且收益只能靠峰值内存对照，当前无数据 |
| §11 现有代码的 BUG（存量） | 7 | F4、F5、F6、F7、F8、F9、F10（含 2 条待确认：负年份值域、`enabled` 运行期切换） |
| §12 并发安全与锁粒度 | 1 | F13（`enabled` 无同步）。`PromotionGroup` 锁序 `group.mtx → HandleTable` 单向，无反向回调；`RuntimeState` 全部字段线程私有，`ThreadLocal` 懒建在同线程内无竞态 |
| §14 功能完备性与 README 覆盖 | 0 | 本部分无 `.md` 文件，无配置项/README 契约；`Runtime.cj` 的「承诺未实现」已按 §3 记 F12 |
| 文件覆盖（§13 等） | 20/20 | 本部分清单 20 个文件全部读完（0 个 `.md`，§13 文档一致性在本部分无适用对象） |

### 第 38 部分

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 6 | 正确性 4 条（`cells` 静默 0、`text` 引用型按句柄 ID、`<2` 引擎抛异常、错误码 -1 复用）；设计 1 条（三份 `run` + 跨层复制辅助函数）；可读性 1 条（`TMapping` 类注释过期）。安全性未命中：本部分不解析外部输入、不拼 SQL/命令、无凭据；`unsafe` 只用于已分配的本地缓冲 |
| §1 死代码 | 1 | 逐符号机械搜索：`RealRunners`（`internal` 类）7 个成员有 6 个存在调用者，`nativeRunner` 全仓（排除 `.worktrees`/`target`）零引用 ⇒ 死代码；`DiffSession` 的 4 个 private 字段、`StubRunner` 的 3 个 private 字段均在类内被读；`TCase`/`DiffOutcome`/`DiffCase`/`DiffEngine`/`DiffRunner`/`DiffMismatchException`/`TMapping`/`T_MAP_*`/`allTMappings`/`okOutcome`/`diffFour`/`assertTripleEqual` 对外可达（顶层 `public`），按硬原则一不判；每个 `return` 后无同层语句；每个局部 `let/var` 均被读取（`unused0/unused1` 已单列为发现 #4，属「读了不用」的显式抑制写法的缺陷面） |
| §2 重复逻辑 | 3 | 两两比对 7 个文件的函数体：① 三个 `run` 逐字节相同（`sed` 切片 `diff` 为空）；② `maxNLocals`/`typesOf`/`reportOf` 与 `CompilePipeline.cj:331-364` 逐行相同/近同；③ F64↔I64 位型转换本文件两份、全仓五份。其余（`TCase.hit`、`StubRunner`、`okOutcome`、`allTMappings`）无同语义实现；`setup/teardown` 类模板不计 |
| §3 空实现 | 2 | `cells` 的 `case _ => out[i] = 0`（发现 #5）、`text` 的 `case _ => return ''`（`RealRunners.cj:396-397`，失败被吞成空串，已并入发现 #9）；未发现 `TODO`/`FIXME`/`catch {}`/空函数体 |
| §4 栈溢出 | 0 | 本部分无递归：`cells`/`arrayPointer`/`maxNLocals`/`typesOf`/`reportOf` 全为单层 `while`；`CFunc` 调用是尾调用式跳转，栈深度由被调机器码决定（已由 `X86Depth`/深度保护在其它部分审）；`DbgDump.report` 不在本部分 |
| §5 OOM | 0 | 分配规模都由单元规模决定且有上界：`Array<Int64>(consts.size)`、`Array<Int64>(args.size)`、`CodeBuffer.alloc(code.size + 16)`、`DbgDump.allocateDump(maxNLocals ≤ 65535)`；无按报文长度预分配、无全量物化、无全局集合只增不减（句柄表累积属「资源不对称」，已按 §11 报在发现 #2，不重复计） |
| §6.1 热点瓶颈 | 0 | 未提供 profile / bench 数据，`pinConst` 扫表与每用例编译均转「待验证假设」#1–#3，未写成缺陷 |
| §6.2 大粒度锁 | 0 | 本部分不持锁：`DiffSession` 无锁、`RealRunners` 无锁；`pinConst` 的全局 `mtx` 在 `HandleTable.cj`（范围外），其竞争面按「待验证假设」#1 记录 |
| §6.3 并发串行 | 0 | 无 `spawn`、无 `Future.get()`、无批处理窗口；`DiffSession.runAll` 是顺序 for 循环，语义上就是「逐引擎顺序跑」（同进程逐位对拍的前提），不算并发串行热点 |
| §6.4 低效算法 | 1 | 每个用例对全部常量做 `constHandle`（含全表线性去重）+ 全量重编译，归入「优化可行性方案」#1 与待验证假设 #1/#2；未发现嵌套循环 contains / `remove(at: 0)` / 循环内字符串拼接 |
| §7 降堆内存方案 | 0 | 本部分堆对象都是 O(单元规模) 的短命数组，无可量化收益；句柄表累积是「未回收」而非「表示冗余」，已按 §11 报。未提 local mode 方案（见下行） |
| §8 降 CPU 方案 | 2 | 常量句柄/编译产物缓存、跳过判定前置（两条均 `无基线`） |
| §9 local mode 可行性 | 0 | 本部分临时对象（`cells` 的 `Array<Int64>`、`typeOf` 的 `ArrayList<String>`）都小且短命、只在本函数内使用，没有可作为收益证据的峰值内存数据；local mode 需 `--experimental` + 逐模块 `compile-option`，收益不足以抵工具链风险 ⇒ 不建议改造 |
| §11 现有代码的 BUG（存量） | 6 | 发现 #2（句柄不回收）、#3（失败路径漏 `mirror.free`）、#4（`write/seal/set` 结果丢弃）、#5（`cells` 静默 0）、#6（<2 引擎抛异常）、#11（`entry` 缺失回落到 0）；均为存量（快照模式无基线） |
| §12 并发安全与锁粒度 | 1 | 线程封闭论证：`DiffSession`/`RealRunners` 均为每用例新建实例、由 `@TestCase` 串行调用（`diff_test` 与各 `*_test` 无并发入口）；`MachineEnv` 是线程私有（`RuntimeEnv.cj:111-126`），本文件 `setFnTableBase`/`reset` 不会跨线程可见。唯一并发面是「`run()` 不保存/恢复上一基址」（`RealRunners.cj:116`、`:140`），在宿主闭包重入场景下会清掉外层基址，已并入发现 #1 的「与 `JitExecutor.invokeOff` 漂移」 |
| §14 功能完备性与 README 覆盖 | 2 | ① 「非原生 ⇒ 跳过而非失败」承诺未实现（发现 #6）；② `tMappingHasNoDanglingEntries` 承诺「无悬空项」但只查非空（发现 #14）。README 覆盖：本部分 7 个文件全部在 `src/test` 与 `src/userapi/*_test.cj`，其公开符号（`TCase`、`TMapping`、`T_MAP_IN_SCOPE`/`M2`/`M3`、`allTMappings`、`DiffOutcome`、`DiffCase`、`DiffEngine`、`DiffRunner`、`DiffSession`、`InterpRunner`、`NativeRunner`、`StubRunner`、`okOutcome`、`diffFour`、`assertTripleEqual`、`DiffMismatchException`）在 `f_jit/README.md:619` 的公开清单里全部可检索到（`AArch64Runner` 逐成员说明在 `:621`、`TCase` 在 `:702`）⇒ 无遗漏 |
| 文件覆盖（§13 等） | 7/7 | 全部 7 个 `.cj` 已读完；本部分无 `.md`（README 归其它部分） |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 15 |
| 一般 | 177 |
| 轻微 | 264 |
| 其中存量 | 423 |
| 优化方案 | 见「优化可行性方案」各条 |

## 总评

**第 1 部分**：这 4 个文档的整体质量在仓内属于上游：157 条 opcode、RSVD 槽区间（0x08–0x0F / 0x1D–0x1F / 0x27–0x2F / 0x3C–0x3F / 0x4E–0x4F / 0x6F / 0x73 / 0x8A–0x8F / 0x9F / 0xC0–0xFF）、常量 kind 10/11、`verMinor=14`、`flags.bit1=NEED_JIT`、`verify.md:69` 的「157 个 opcode 0 缺失」、加速比 1.27×/2.40×/1.91× 都能与源码或证据文件对上；`concurrency-audit` 的 H1–H6 也逐条在代码里落实（锁外 `bindCacheKey`、`AtomicInt64`、`lastEscaped` 加锁、注册进 `this.mtx`、`CompileTimeout` 三态）。

问题集中在两类。第一类是**契约级事实错误**：递归深度/栈溢出完全没进「已知限制」，而文档同时承诺「JIT 只是加速层、语义不变」——非尾递归在解释器与机器码里都是真递归且没有任何闸门，溢出是进程崩溃、不产生 `JitException`（#1，本部分唯一严重项）；其次是句柄 tag 与方言类型码混用（#3）、Int64 零除错误码（#6）、英文版 `close()` 返回值（#4）、ABI 表的 `hwTop` 偏移（#5）。这几条都在宿主可见的契约面上，改动本身是纯文档，但会直接改变调用方的错误处理与安全假设。第二类是**文档随实现漂移**：11 处锚点错位（README 6 处、asm-inline 5 处）且 Q5 片段是旧签名（#8）、句柄表存储模型过期（#9）、「两遍/三遍」「H01–H83/H01–H75/`MAX_FIXED=72`」「`initialCapacity` 是 var」这类小口径错误（#10/#11/#14）、中英两版已经分叉（#4/#13）。根因是「按行号引用 + 两份手写清单」，建议一次性改成符号引用 + 从 `src/` 生成索引，否则下一轮重构还会再漂。

`asm-inline` 的可行性结论（B 先行、破 I7/禁 deopt、JIT-only）论证扎实，但 ABI 表若被后续实现直接采用，`hwTop` 偏移会成为真缺陷，应在立项前修正。`concurrency-audit` 的结论可以保留，但「25 个 static 全覆盖」与两个未加保护的诊断计数器冲突（#7），建议改成「运行期正确性无缺陷 + 诊断计数允许丢计数」，避免下一轮审计以它为豁免依据。

存量 15 条（严重 1 / 一般 6 / 轻微 8），是否纳入修复待用户决定；快照模式无基线，不区分「本次改动」。

**范围外提示**（不计入本部分统计，留待对应 `.cj` 分部分确认）：① `HelperId.MAX_FIXED = 72`（`src/runtime/HelperId.cj:125`）与已登记的 73–84 矛盾，且全仓零引用（`public`，属一致性/可见性信息，非死代码）；② `JitFunction.close(timeoutMs)` 的等待上限按自旋次数折算（`timeoutMs * 100000`，`src/JitFunction.cj:237-247`），不是真实毫秒，实际墙钟随 CPU/锁开销漂移；③ `CompileCache.reset` / `runs` 仅被 `*_test.cj` 引用且类型为 `protected`，属可见性建议。

**第 2 部分**：`design-m1.md` 是一份「规格落地稿」，前半部分（§0 分层、§1 DAG、§2 契约类型、§3 格式、§5 ctx/句柄/helper、附录 A/B 的 ISA 表）与实现贴合度很高：ctx 偏移、`Version`、`FuncEntry/SiteEntry` 尺寸、附录 B 抽查的 opcode 类别与长度、helper 编号（含 H69–H72）逐项核对均一致，说明作者当时确实对着代码写过。问题集中在**模块演进后没有回头改设计**：`unload→close`、`compile(unit)`、`CallContext.args`、`invoke/tryInvoke/JitValue/AdapterRegistry`、`JitArtifacts/JitCompiler/BackendSelector` 这五组机制在 M1/M2 实施中被内联或替换，设计却仍按原结构描述；同时 §7.3.6 的再导出清单与 `Root.cj` 的实际导出面对不上，使「哪些声明算对外契约」失去唯一判据。这类漂移不是风格问题：它会让读者按设计去找不存在的 API、按错误的产物束核对资源释放、以为 `JitFallback` 会被记录而实际上永远不会。

按影响排序，建议优先处理五条：① #2/#3/#4/#9/#12 的公开面契约（照设计写会编译失败或行为不同）；② #1 的栈防护论证（设计声称的「进入守卫 + 回退解释器写 15」不存在，非尾递归仍是进程崩溃；与 part1 #5 一并处理）；③ #8 的诊断接线（T7 的可观测承诺目前不成立）；④ #5 的去重契约（D4 的绝对表述与实现不符，且缺少它自己要求的二次校验）；⑤ #10/#11/#14/#15/#16 五条存量并发/错误通道/句柄契约问题（同键失败 kind 漂移、`compile` 可能返回卸载中的单元、`pin` 身份不跨调用、容量配置竞争、卸载顺序自相矛盾）。其余 §B/§C 表格与清单类问题（#17–#26）成本低，适合与上述修复一起做一次「设计与实现对账」。

需要说明的口径：本文档开头明确「签名以草图给出（个别类型随后续设计微调）」，因此**仅名字/参数顺序/返回类型**的差异（如 `HandleTable.get<T>` → `getAny/getAs`、`Interp.run` 多一个 `args`、`CodeBuffer.write` 返回 `Bool`、`marshalArg` 参数顺序）未计入发现；计入的是**字段被删、机制被替换、语义/边界相反、内部自相矛盾**这几类会误导实现或使用的问题。若需要把「草图免责」收窄，建议在设计里给每个声明标注「已实现 / 已改名 / 已撤销」。

本部分没有运行期代码，也没有需要立即阻塞发布的实现缺陷（文档不参与构建）；但 #1 的栈防护论证若不修，会让实现者误以为递归已被 `STACK_GUARD` 保护，这是本部分唯一的严重项。存量 26 条（严重 1 / 一般 15 / 轻微 10），是否纳入修复待用户决定。

**范围外提示**（不计入本部分统计，留待对应 `.cj` 分部分确认）：① `DedupGuard`（`bytecode/Fingerprint.cj:119`）是 `public` 但仓内无引用（对外可达，不判死代码，属可见性/接线信息）；② `BaseVisibility_test.cj:20` 用 `import fountain::f_jit.base.*` 断言「根包再导出不缺项」，测试口径与注释不符；③ `HelperId.MAX_FIXED = 72`（`runtime/HelperId.cj:125`）与已登记的 73–84 矛盾且全仓零引用（part1 已提示）。

**第 3 部分**：本部分只有三份设计文档，代码质量风险不在语法层面，而在**文档作为契约的可靠度**：`design-parallel-call.md` 的状态行与 §9 完全相反、验收门槛 5× 与实测 1.91× 并存却记「已归档」，是读者最容易被带偏的一处；`design-m2.md` 虽有一节「实施偏差回写」，但正文的验签口径、`close`/`isClosed` 语义仍停留在被废止的版本，且 M2.2 / M2.3 两个增量整段缺失、权威版本号停在 v0.8.33；`design-m3.md` 的正文/附录大体与实现同步，只有 §5.4 的 helper 编号仍是 66–75 旧表（照抄会与 `cast_fail`、`datetime_*` 撞号）与 M3-7 的立论已被 M2.3 推翻。

文档侧没有阻塞级问题（不影响已交付代码的正确性），但这 13 条里有 6 条会直接导致「按文档实现就写错」：编号表（#3）、验签选型（#4）、`Resource` 契约（#5）、增量缺失（#6）、`as` 的 helper 路径（#7）、签名合法集（#8）。建议把 #3–#8 排进下一个文档修订批次，其余随各自模块的下一轮改动顺手更新。文档中出现的两组性能数字（4.6–5.8×、1.27/2.40/1.91×）均无同环境对照，只作为待验证假设保留，未进统计。

存量 13 条（一般 8 / 轻微 5），默认只报不修；是否纳入修复由用户决定。

**第 4 部分**：这份规范的底子很好：错误码表、容器头、函数目录、站点表/名字表、ctx 布局、`LocalType`/`TypeToken`、`TO_STR` 格式、`FDIV_CHK` 谓词、`STACK_GUARD` 方向、`MAP_ITER_STEP` 相位等绝大多数数值与实现逐项对得上，实现侧文件普遍以它为「数值权威」，说明作者长期维护过一致性。

本部分的风险集中在三类，且都不是笔误级别：

1. **后端语义错误（#1，阻塞项）**：AArch64 `DUP2` 栈序颠倒，规范 §12.4 同错。当前前端不发射它，所以没炸；但分发入口装载的 `.fbc` 一旦含 `0x18`，aarch64 就与解释器不一致（I7 违反）。修 A64 lowering + 修规范 + 补三引擎差分，最小可验证闭环。
2. **分发入口不存在（#2，阻塞项）**：`Compiler.compile(unit: SourceUnit)` 不在公开面（`CompilePipeline` 为 `protected`，`SourceUnit` 无生产消费方）。这不是改名，是「分发模型对用户不可用」——补公开入口或撤回文档，不能停在「文档里有一个不存在的方法」。
3. **规范与实现的系统性漂移（#3–#17）**：门面签名（`close`/`isClosed`）、线上编码（`CALL_HOST` 2 B vs 4 B）、`LEN` 语义、转储首格协议、a64 帧/`x20`/`FPCR`、helper 值域、路由表漏项、`LOOP_BACK` 只改一处——共同特征是「文档落后实现一个版本」或「同一规则多副本只改了一份」。它们对当前 `compile(source)` 主路径多数不致命，但对「按规范实现的第三方后端/工具/新平台」是直接错误，而且 `51866c43d` 已证明这种结构必然再漏。

排期建议：**先修两条阻塞项**（#1 代码 + 规范；#2 公开入口）；**再批量同步契约面**（#3/#4/#5/#6/#9/#10，均可在同一次文档回写里完成，配 §10.3 式的装配期一致性自检）；**最后清结构性问题**（#12/#13/#17：把 opcode/helper/失败码/正文规则各收敛为单一权威表，删掉无实现的伪指令与死 helper）。优化项本部分为 0：唯一有基线的性能项已实现，剩余只是文档回写，已并入 #7。

**第 5 部分**：这份 M2 规格的机制设计是自洽且论证充分的：CALL_HOST 归一到 helper 基础设施、HostClosure/HostObject 的句柄化、逃逸闭包提升组、21/99 的错误面划分，都能给出可实施的推导。主要风险不在机制，而在**规格与落地实现已经分叉**：`design-m2.md` §11 自己记了 10 条实施偏差（`design-m2.md:472-483`），但本规格只回写了其中一部分，其余（`PublicField.sig*`、继承访问器限制、`close` 语义、M2.1–M2.3 快路径、GAP-13）仍以旧口径留在正文。其中「继承成员逐级向上」「非闭包 `close` → 19」是**与实现相反**的承诺，`close` 那条还会让使用者意外卸载单元，属阻塞项（合并前应修）。

最重的一条是字段面（§12.2）的类型范围漏洞：放行 12 会让宿主对象成为内部闭包的驻留点，直接违背本文 §1/§14.6 自己的逃逸纪律；实现侧 `isRegistrationLocalType`/`fieldToken(12)`/`fetchAny(CLOSURE)` 已完整放行，虽需手工注册才触发，但后果是窗口 ID 复用后的对象错乱，建议按严重处理并在实现侧同步收紧。

其次是 CALL_HOST 栈序（§3 与 §2/§5 相反，实现与 `design-m2` 已按 `[h_fn, a1..an]` 固化）、捕获描述符不入 `.fbc` 导致分发加载单元无法安全提升、H63 重入无深度上限——这三条都是实现者按规格会踩的坑，建议在规格与实现两侧一并补上可测口径。其余（错误码 19/20、注册表作用域、`PublicField` 结构、HostObject 定义、`registerType` 签名、版本行与 T 编号、重复定义、M1 引用缺前缀、helper 编号、Regex 边界）属可排期的一致性治理。本部分无源码，性能结论均未成立，只有五条待补数据的假设。

**第 6 部分**：本部分没有源码，风险集中在**规格与实现的最后一公里**和**性能台账的可复核性**。

最需要处理的是 m3 §5/§9.1/T39 的容器转型承诺：文档冻结了「元素/键值校验」，实现里 Map 键型**完全没有校验**（`ConstMapKey` 擦除），List 也只认 `Any` 元素，测试只锁了值码。后果不是崩溃，而是 `is`/`as` 的答案与契约相反（`Map<Int64,Any>` 被判成 `Map<String,Any>`），后续按键访问落成「缺键」或混键表——这是 Any 沙箱类型边界上唯一一条明确的缺口，建议按严重处理并二选一（收窄文档 / 加键码 tag）。

第二处会直接绊住使用者的是 m3 §11 的 `json_set` 写值域：规格仍写「值型 0–3（Unit 除外）」，把 Float64 算进可写域，而前端 `checkJsonWriteValue` 与运行期 `jsonValueOf` 都只收 Int64/Bool/String/JSON 节点，`A7JsonSet_test` 也已按「Float64 编译期拒绝」立了用例——规格是「规格 / 前端 / 运行期三处一致」里唯一没改的一方。按文档写 `o.k = 1.5` 会拿到编译错误，建议与 #1 一并修正规格文本并补 T61 负向用例。

`SignatureTable` 的三处偏差（128 上限未文档化、`enabled` 非原子、作用域写成「桥实例级」）属同一族：实现已经引入了文档没有的进程级可变状态与容量上限，而 §13 的「天然有界、无需淘汰」「读路径无锁」正好在这三点上失真；修文档即可，代价低。

性能台账方面，`perf-m1` 的 aarch64 基线已被 `optimize-loop-safepoint`（同一台机器、空循环 662→15 ns/轮）实质推翻却仍以现役基线示人；`perf-m2` 的次数/单位/换算三者互斥，按文档方法跑不出文档数字。这两处是「后来者会被带偏」的地方，优先在文档层修正；`optimize-call-path` §15.4 的 `ti` 惰性化则是一个尚未记录的成本转移（`TypeInfo.of` 从每条目一次变成每次回调一次），已放进待验证假设等数据，不写成结论。

其余是索引与治理层的瑕疵：两份台账重复定义实验规则且已漂移、行号与状态摘要过期、决策日志残留空行、`AdapterRegistry` 的 UAF 论证对象实际上没有生产调用点。这些不影响产品行为，但会让下一轮性能工作从错误的基线和错误的规则出发，建议与上述文档修正一并排期。

**第 7 部分**：本部分是 f_jit 的计划与变更归档文档，不含源码。整体质量高于一般文档：数字有出处（43.8× 的两次耗时与比值自洽）、用例名与真实方法名逐个对得上、变更 delta 与代码的命名（`close`/`isClosed`、`CallContext.deadline`、LocalType 15–19、HelperId 78–83、`ErrCode` 21/22/23/99）基本同步，`plan-m2` §4.2 的十个落点文件也都能在仓内定位——没有"编造的验收"。

风险主要在两类：

1. **一处契约与实现不符**（发现 #1）：`close(timeoutMs)` 的「超时」是没有时钟源的自旋预算，且每轮抢同一把单元锁。这既是命名/文档与实现的口径差，也让关闭路径在真并发下空转抢锁；修法是换成单调时钟 + 让出 CPU（或改参数名并在规格写清单位），属可排期的一般项，不影响数据正确性。
2. **计划文档的状态与计数漂移**（发现 #2 #3 #4 #5）：x86 后端已落地却仍记「未完成」，三处阶段总览少记一步，骨架漏了 `macros`/`surface`/`userapi` 三个包与 `f_macros` 依赖，`--parallel 1` 的理由可能已失效。这些都会误导排期与"还剩多少工作"的判断，建议一次批量回写，并加一个计数自检脚本长期钉住。

存量 5 条（1 一般 + 4 轻微）默认只报不修，是否纳入修复由用户决定；「待验证假设」4 条不进 `todo.md` / `tasks.md`，留给下一轮补数据。

> 范围外提示（不计入本部分统计，供对应部分复核）：① `f_jit/src/backend/BackendSelector.cj:77` 类注释「（P5.4–P5.8 落地；当前为契约占位）」与其 `:89-104` 的实现相反；② `f_jit/src/base/CallContext.cj:25` 的成员表仍列 `args: Array<Int64>`、`f_jit/src/base/CallContext_test.cj:27` 仍写「只钉住……`args` 与 `deadline`」，与 `align-base-contracts-callcontext` 的「`args` SHALL NOT 出现」相反；③ `f_jit/src/AnyBridgeCall_test.cj:189/200` 仍以 `invoke` 指代已并入 `call` 重载的入口（局部变量 `viaInvoke`）。

**第 8 部分**：本部分 20 个文件都是「已经实施完的变更留档」，整体质量偏上：`clarify-last-escaped-scope` 与 `align-jitfunction-close-naming` 两份的改动范围、落点、自评（「没有可测行为差异，只主张语义明确」）都与代码逐条对得上，属于可信的审计记录。

风险集中在两处。**第一处是后端守卫这条链**：x86 规格写的阈值（全帧）与实现（保留区）从落地第一天起就不一致，按规格写出来守卫恒不触发；A64 侧更严重——设计文档用一句「`x31` 的减法在该编码中不落实」解释「守卫恒不触发」，与 AArch64 编码事实相反，真实原因是 `subReg(...,31)` 读的是 XZR；两处叠加后，「回边栈余量守卫」在两个后端上一个是死分支、一个是空指令，而验收证据（`p0_6` 毫秒级、`PerfCompare` 打印）都无法证伪。这条不构成可复现崩溃（`maxStack` 静态分配仍兜住正常路径），但它是「以为有防线、其实没有」的典型，且文档给出的解释会把后来者引向改序言这种危险动作，建议优先修正文档与护栏。**第二处是键规范**：X2 把 `f:` 前缀合并掉之后，键域既不是单射（`Int64` 与同 bit 的 `Float64` 撞键）也不是满射（`Int64`/`Bool`/`List`/`Map` 的装箱键落到 `''`），`ConstMapKey` 又只按 token 比较，`Map<Any, …>` 场景会静默错值；该缺陷是本次修复「修而未净」的延续，值得单开一条变更。

其余 2 条轻微项（缺失的 `verify.md`、`LATEST` 字面量复制）成本低，可与上述文档修正一起批量处理；#5（两张用例表漂移）虽定为一般，改动也只是删一份重复表。**第三处是可见性契约**：`JitContext` 被设计写死为「已结案 `protected`」，实现却是带 `public wrap/readAt/writeAt` 的 `public class`，与仍保持 `protected` 的 `CompileCache`/`AdapterRegistry`/`CompilePipeline` 不一致；它不产生运行期错误，但把 ABI 契约的边界让掉了一截，建议与上面两处一并收口。另注一条历史口径，不计入发现：`close-f-jit-out-of-checklist-findings` 的 proposal/design/verify 三处写「默认产物逐字节不变（`strictFp=false`）」，其后 `flip-f-jit-strictfp-default` 已把缺省改为 `true`（`CompileOptions.cj:45`、`doc/design-m1.md:175`）；按归档文档「当时自洽」的判据不算缺陷，但读这三份文件的人需要知道默认值已翻转。

**第 9 部分**：这 20 份文档质量在同类 JIT 规格里属上乘：requirement / scenario 编号可机检（`check_scenarios.sh` 复核 156 条、`check_tmap.sh` 无悬空），断言口径细到字节与错误码，且 `verify.md` 主动记录了自己的 CRITICAL / 未覆盖项（7 条无断言 scenario、5 条部分覆盖、JIT 全局串行），这种自我暴露在存量文档里少见。本轮没有发现与实现相反的**行为性**承诺（类型码表、错误码、版本常量、26 B 目录项、64 B ctx、FNV 黄金值全部对得上），也没有发现空实现或重复逻辑需要合并。

风险集中在两处「契约面」而不是算法面：① 用户面清单三处口径不一（spec 说「封送 + 句柄表」一次导入可见，实现里 `CallMarshal` 是 `protected`、`HandleTable` 根本未再导出，proposal 同一行还自我矛盾）——这是会让宿主按文档写代码就编译失败的那一类问题，建议优先回写；② 「编译缓存键」在两个 requirement 里被定义成互斥的两件事，实现是第三种，而 Off/Auto 串用产物正是这个定义缺口的直接后果，规格应把 `JitMode` / `verMajor` / `strictFp` 三个维度显式写进契约。

其余 8 条轻微项（requirement 计数 40 vs 77、用例增量 +3 vs +4、tasks 自相矛盾与失效路径、六步调用把解包算两次、m2.2 缺 verify、繁体笔误、M2 镜像字段清单落后（#10））都不影响运行语义，属文档维护债，可与下一轮规格回写一并处理。三条范围外提示（`HelperId.name(84)` 落到 `unknown(84)`、解释器非尾递归无深度上限、`pow` 变更文档写 H77 而实现是 H84）建议分别转给运行期、解释器与 `pow` 变更的负责部分，它们比本部分的文档问题更接近真实故障面。

**第 10 部分**：本部分 20 份文档是 M2 系列的归档规格，**主体与实现贴合**：13/14 类型码与句柄 tag、`0x79` opcode 行、H63/H64/H65、H77 与 66–68 保留位、`$as$` 注册期合成、`@JitSignatures` 的「公开登记函数 + 包级 let」形态、`callForFn`、`ClassDescriptor.parents`、`M2.2/M2.3` 的 `as` 三态与运行期兜底，都能在代码里逐条对上；`verify.md` 的 51 requirement / 156 scenario 与 spec 实际计数一致，M1 基线 560 三处自洽。**没有严重项**：不存在会导致崩溃、数据错误或安全问题的契约矛盾。

需要处理的是三类「归档回写不彻底」，且都落在 M2 自己 verify 点名过的区域：

1. **验签方案与类型载体**（#1、#2）：design D3 与 tasks 仍写「单次 `is`」，`SignatureDescriptor`/`HostClosureT` 的 delta 仍只有类型码——正是 GAP-04/GAP-05 的文本根因，只改代码不改文档，下一轮还会被重新发现。建议无条件修（纯文字）。
2. **验收与任务链**（#4、#5）：m2.2/m2.3 没有 `verify.md`，m2.2 矩阵 21→20 且 1 条用例改名（脚本实测 `缺失 1`），两份 tasks 一份粘错清单、一份溯源到不含 M2.3 的 `plan-m2.md`。归档结论因此不可复核，建议下一轮补最小 verify 时一并处理。
3. **行为契约被后续实现推翻却无取代记录**（#8、#9、#10）：`HostCallback.sig` 可空、`callFor`→`callForFn`、`close` 协议（入口实例已改为单元卸载）。单条都只是轻微，但会让「按 spec 复核」得出错误结论。

另外 #3（m2.2 的裸 `as` 与下转型面）与 #6（CALL_HOST 语序）是**同一归档内 spec / 矩阵 / scenario / 实现互相矛盾**，建议优先修：它们直接决定读者对 `as` 语法面与 CALL_HOST 栈序的认知，而后者已被本变更 verify 判为「应在 archive 前修订」却未修订。

存量 12 条（一般 7 / 轻微 5），是否纳入修复待用户决定；本部分未发现需要阻塞合并的缺陷。

**第 11 部分**：这 20 份规格文档的整体质量高于一般归档文档：决策都写了「为什么」，不变量（包依赖 DAG、执行路径零反射、helper 边界不抛异常、窗口/句柄记账）可直接对读代码；`LocalType` 0–19 与版本分派、可转集单一来源、`TypeToken` 12 项、`kind 11` 拼装期不解析与加载期一次实例化、`frozen` 经读/拆箱传播、接口 `@JitBind` 强绑定与 14 判定=类祖先∪接口谓词、窗口切片与读路径去锁，全部核对成立；`scenario-map.tsv` 与 spec 场景逐条对齐，用例数（Interface 4 / Inheritance 2 / ParallelCall 6 / WindowIsolation 3 / ThreadLocalEnv 3）经清点属实，未发现编造或空承诺。

风险集中在「文档比实现宽」这一个方向，且都发生在 P3-3 一类**收口只改代码不回写 spec** 的场合：

- JSON 写入值域（#3）：文档放行 Float64，前后端两侧都拒绝，代码注释自己承认「规格-前端-运行期三处不一致」——本部分最值得排期的一条。
- 反引号取界（#4）：文档描述的「字符串感知 + 括号配平」不存在，字符串内反引号无法书写；列出的三个 scenario 恰好都能通过，掩盖了差异。
- 未注册父接口（#2）：三份文档三种说法，实现选了 design 明确排除的「静默降级」。
- 父类方法反射限制（#5）：spec 的「一并登记」有一个只写在代码注释里的 GAP-13 例外。

唯一按严重记的是 #1（Float64 位模式），它把「合法输入」变成引擎缺陷码 99，且同仓已有 3 处符号安全的等价实现——两条口径不可能同时正确。该缺陷落在 `.cj`，已注明与相应分部分去重，定级以代码部分为准；复核成本是一条 `call<Float64>([-1.5])` 用例。

其余 6 条是记录一致性问题（开关落点/plan 生命周期、`state/active` 与 `lastEscaped`、字段编号顺序、`JsonDecimal` 出口、`verify.md` 断链与 partial 未标 GAP、错误码映射表），单条都不阻塞，但建议与上面几条一起做一次 **spec 回写**，否则下一轮会重复命中同一批偏差。

阻塞项：本部分文件为文档，无阻塞项；#1 虽按严重记，其性质是代码缺陷，需由对应 `.cj` 分部分复核后定稿。存量合计 11 条（严重 1 / 一般 4 / 轻微 6），是否纳入修复待用户决定。

**第 12 部分**：这 20 份文档的**主体质量高于一般归档文档**：五份 `fix-*` 变更的「问题 → 改法 → 锁序论证 → 改前红/改后绿」链条完整，工程上最容易被糊弄的两处都如实写了——`fix-compiler-register-lock/verify.md:40-52` 明说「旧实现也通过，本条没有变异证据」，`fix-compilecache-lock-order/verify.md:29-33` 把「为什么把 bind 移出锁仍然安全」论证到调用图不变式层面。逐条对拍后，`missingResult` 三态、`FAILURES_MAX` 256 与五个注册入口、`finish` 的 bind/发布顺序、`DefiniteAssignment` 两处 `None` 放行、并行调用的分块存储/TLS/无锁读/PromotionGroup 加锁、10 条新用例数目，都能在代码里找到落点，没有「文档说做完了其实没做」的大面积漂移。

风险集中在两处。**第一处是 `**` 这个新特性的四份文档三套口径**：`-2 ** 2` 的验收值写反（#1）、负指数字面量的拒绝时机在 proposal/design 与 spec/实现之间相反（#2）、`verMinor` 该不该升在 design/proposal 与 tasks 之间相反且「记入 verify/README」两个落点都不存在（#3）、连带 `HelperId` 名称表与值域用例没跟上 H84（#5）。这些都不影响正常运行，但 `spec.md` 是可执行验收口径，按它写用例必红，属于必须排期修的一类。

**第二处是「注册使失败缓存失效」这个修法本身的并发边界**（#4）：时序上，注册线程清表与在飞编译写回失败之间没有先后约束，宿主「编译失败 → 补注册 → 重试」的多线程用法仍会复现原来的 sticky 行为。这条没有任何护栏覆盖（`CompileFailureCache_test` 是单线程），修法建议用代际号而非 `clear()`，成本不高。

本部分**无严重项**：没有发现栈溢出、OOM（失败表已 256 上限）、死锁（三条锁链无反向）、或对外契约承诺为空的形态。#6–#13 是归档文档的回填问题与护栏缺口，可随下一次文档整理批量处理。存量问题 13 条（一般 4 / 轻微 9），是否纳入修复待用户决定。

**范围外提示**（不计入本部分统计）：`README.md:249` 仍写 helper 白名单为「H01–H83」，而 `**` 已占用 H84（同文件 `:484` 又写 H84），属 README 部分的自相矛盾；`README_en.md` 的并发问答编为 Q7 而中文版为 Q8（`README.md:587`），中英编号不对称。

**第 13 部分**：这 20 份文档是 `f_jit` 三次 x86/AArch64/桥接缺陷收口的完整记录，质量明显高于一般归档：`fix-f-jit-audit-defects/design.md` 的 22 行缺陷目录几乎每行都给了「根因 + 修法 + 为何不选备选」，`fix-f-jit-strictfp-deadline-x86/design.md` 把 `jnp → jp` 的谓词反向错误连同汇编序列一起写清（我逐条核了 `0x8A`、`48 29 D0`、`0F 8D` 的编码，均正确），`fix-f-jit-x86-stack-align/design.md` 用「线性 depth 与 CFG depth 的奇偶差」解释 SIGSEGV 并给出四种方案对比 —— 这类根因叙述的可复核性很高。文档承诺的实现落点也经得起抽查：typecode 14 的 `aux` 类界判定与 tag 11（`AnyHelpers.cj:92-95/159-161/218`）、`appendHostObject`、`fetchAnyBox` 的 gen 校验、`IterTable.clearAll` 进 `finally`、`FDIV_CHK` 的 `0F 8A` 字节断言，全部对得上（`CanonKey` 是唯一例外：规格的前缀表与实现相反，见 #5）。

本部分的问题集中在**记账层**，而不是技术判断层：同一份「缺陷 → 用例」事实被复制到 `test-plan.md` / `tasks.md` / `verify.md` 三处，随后各自漂移 —— 条数 27 与「26」并存、6 组用例名互不相同、`p1_4_` 前缀被两组缺陷共用、P2-5 的用例名干脆不含编号（违反本变更自己写的 spec）。这类漂移不会让代码出错，但会让「26 条是否真的都有语义断言」这个问题失去可检索的答案，也与本变更自己刚立的「矩阵不许虚报」纪律相悖。第二处值得排期的是 `stack-align/design.md`：`tasks.md` 用三次「实现方式调整」如实记录了偏离，`design.md` 却仍以「手写栈效应表 + 字节级断言 + 1091/1091」叙述，且后端确实没有那张表（同名的 `StackEffect` 只在前端 `compiler/Ops.cj`），后来者按 design 找符号会先撞错地方。零回归数字（1075 vs 1076）单列一条，是因为它是本变更唯一的总验收证据，差一条就应当写清是漏跑还是假失败。

无严重项、无阻塞项。但其中两条不只是「记录不准」，而是**文档会教出错误实现**：#5 让 `Float64` 常量键回到已被判定为 P1-7 根因的 `f:` 前缀（照做即重现「常量键永不命中」）；#6 让 x86 回边守卫按 `frameSize` 比较（照做即每次正常回边 deopt），且它的 `[x]` 与本模块 `f-jit-m1/verify.md` 的「本变更未做」直接冲突。这两条建议与 #4（design 未回写的 `X86Depth`）一起作为文档收口的第一批，其余记账类（#1 #2 #3 #7 #8 #9）可以第二批。

存量 9 条（一般 6 / 轻微 3），是否纳入修复待用户决定。

**第 14 部分**：本部分没有源码，判的是「变更记录是否可信」。五条变更的实现侧都真实落了地，且质量不差：A64 的 `NOT_B` 已由 `eorImm1` 字段构造（`A64Emitter.cj:381-391`，位域注释齐全）、`gen` 退休在四处释放点统一收口（`HandleTable.cj:653/1000/1024/1077`）、句柄配置与原生资产计数都已原子化；`verify.md` 的「旧实现不会失败」这类诚实说明值得肯定。四条变更有三条带可复跑护栏，测试总数与增量逐批自洽，`git blame`/提交历史也能对上。**没有阻塞项，没有需要立即修的代码缺陷**；本部分未运行构建或测试，文档中的绿态数字只作记录核对，未独立复验。

问题集中在文档层，都是「变更做对了、文档没跟上」：#1 最值得排期（「不改 Lowerer / 字节码不变」会直接误导后续差分与缓存审计，且 `spec.md:7` 的全称 SHALL 会把正确的 `BNOT_I` 判成违规）；#2 的空 scenario 让 `!~` 的验收在契约层悬空，一次性修补即可。其余 5 条是验收记录与实测/仓库事实的偏差（Red 形态、x86 预期数、N5.3 状态、design 期望值、并发护栏强度），以及 `{0,1}` 这个隐式地基没写进 spec。

设计侧有两点已登记、应按排期跟进的残留风险，不构成本轮缺陷：① 退休槽不可回收，默认 `capacityLimit`（1M）下约 3.3e10 次分配即触顶（1M 次/秒约 9 小时返回错误 16），design §D2 与 verify「风险与后续」已明示，高 QPS 服务上线前应评估是否调高上限或另立回收变更；② B7（`CMP_I`/`CMP_F` 符号约定与解释器相反）当前无 `Lowerer` 生产者、不可达，但已登记未修，后续接入生产者前必须先定规范。

**范围外提示（不占本轮统计）**：

- `f_jit/doc/design-m1.md:1524` 与 `f_jit/doc/jit-bytecode-m1.md:2129` 的 `CMP_I` A64 列仍是 `cset x11,lt; cset x12,gt; sub x11,x12`，而实现是 `cset 11,LT; cset 10,GT; sub 9,11,10`（`A64Lower.cj:787-795`），寄存器写错；同时其符号约定与 `Interp.cj:498` 相反（B7）。`verify.md:148-149` 把这处订正挂在「与 B7 同批订正」上，但仓库里没有对应变更，两表会一直错下去。两份文档属 part2，建议按一般处理。
- `f_jit/doc/design-m1.md:1521-1543` 与 `f_jit/doc/jit-bytecode-m1.md:2126-2148` 的 `0x50–0x6F` 表逐字重复（`diff` 为空），任何订正都要改两处，本次 B7 的寄存器错就是复制体未同步的实例（§2 重复逻辑，part2）。
- `f_jit/README.md:651` / `README_en.md:691` 的公开 API 索引把 `initialCapacity` 标为 `(var)`（实现已是 `public static mut prop`，`HandleTable.cj:149`），且缺 `capacityLimit`（prop，`:159`）与 `retiredCount()`（func，`:1271`）；`releaseEscaped` 只在正文出现（`README.md:576`）、未进索引。另外 README 全文没有 `!` 的类型分派说明（`!2 == -3`、`!s` 编译期报错），而 spec 已把它定为契约。README 属 part1。
- `NativeAssets.liveCount()` 用两次独立 `AtomicInt64.load()` 求差（`f_jit/src/backend/NativeAssets.cj:47-48`），仍不是一致快照，并发读可能瞬时为负；与 `fix-native-assets-atomic/proposal.md:11-12` 描述的「并发下偏低甚至为负」只在「丢增量」维度上被修复，建议由该源码所属部分复核其公开契约。

**第 15 部分**：这 20 份文件是 5 个已归档变更的完整记录（提案 → 设计 → 规格 → 任务 → 验证），文档质量总体在平均线以上：`strictFp` 三层缺省同步（`CompileOptions.cj:45`、`SourceCompiler.cj:104`、`Lowerer.cj:166`）、`isReturnedHandle` 由 `LocalType.isHandle` 单点派生（`JitFunction.cj:722-724`）、x86 审计的 `ThreadLocal` 隔离（`BackendSelector.cj:258-303`）、`-1` 绝对地址哨兵、B1/B2/B3 三条生命周期缺陷的落点，都能与现行实现逐条对上；`verify.md` 还如实记下「G1 的 RED 构造不出来」，没有把防御性加固包装成已复现缺陷。

**阻塞项只有一处**：`jit-closure-unload-cascade` 落地后的关闭状态机。`state` 是共享标记而非卸载者令牌，任一并发 `close()` 的超时回退都能把它复位成 `0` 并重新放行调用；而「排空判定」与「置终态 + 取 `release`」分处两个临界区，中间不复检 `active`。交错成立时会在在飞调用期间 `releaseAll()` 提升组，单元路径更进一步——`JitExecutor.release()` 直接释放正在执行的机器码。触发需要「两个线程同时 `close` + 至少一次超时回退 + 新调用落进微秒级窗口」，概率低但后果不可恢复，建议优先修并补多线程压力用例。

**可排期的一般项**：`timeoutMs` 用「自旋次数 × 100000」近似毫秒且无时钟（既可能提前也可能迟到，批量等待还会被自旋拖长）；`Resource.close(): Unit` 把 `close(0)` 的 `Bool` 丢掉，`try (f) {}` 在有并发调用时静默不释放；G5 的「记录每条内存访问」只覆盖了一半，漏掉的 `CALL_CLOSURE` 恰好是唯一一处 helper 返回表基址的解引用，两份 delta 对允许集的表述还以 ADDED 方式互相否定——护栏目前只能算抽样。

**文档偏差都很轻**：proposal 把「单元不强引用包装实例」写反、G1 在同一变更内前后定性相反、A64 现状（实例字段 vs ThreadLocal）描述与实现相反且源码里留着互斥旧注释、`recursive` 的 4 个引用行号有 3 个不存在、§5 的「单锁无嵌套」与 D7 和实现矛盾、`unload` 家族改名未回填。这些是「照文档检索会落空或误判」的成本，不影响行为。

性能方面本部分没有任何可复核的测量数据（verify 只有用例计数），因此审计开销、登记表增长、自旋 CPU 占用全部只列为待验证假设与一条无基线的 CPU 方案，没有写进缺陷。

**第 16 部分**：这 20 份文件是 `f_jit` 的 SDD 过程文档（proposal / design / spec delta / tasks / verify），不是使用文档，因此风险不在「用错 API」，而在**数据与因果的可信度**：下一轮性能工作会把这里的 `verify.md` 当基线读。

- **必须订正的（一般 3 条）**：`optimize-call-alloc` 的 `pins` 因果错误（design/proposal 与 verify 结论相反，且与 `resetWindow` 只释放 `appendIds` 的实现相反）；`optimize-call-alloc2` 的快/慢模式混表——`+2.3%` 无基线、两轮相差 85% 却称「噪声内」，按项目自己的 `d ≥ 10%` 规则这组数据不足以支撑任何判定；`jit-function-resource-close` 的 delta spec 把 `close()` 写成无条件卸载，缺「在飞调用时静默不关闭」分支（代码侧已由 part15 记录）。
- **可排期的（轻微 5 条）**：收益区间写大（−300~370 vs 实际 −171~−365）且 W4.1 的 `Q4` / ≤300 ns 判据无数据、`WindowPool_test` 用例数与变异靶子对不上、394 ns 拆解不闭合、`jit-closure-unload-cascade` 归档项未勾选、`makeRetUnboxer` 仅测试引用仍为 `public`。
- **代码侧**：本部分无源码，未新增代码缺陷；文档引用的三处实现（`HostFault` 线程本地、`HostField` 不可变快照、`Win` 池有界复用）与规格一致，`HandleTable` 的 16 位 gen 阻断也已按退休处置修复（`HandleTable.cj:1148-1150`），文档中「需单独立项修复」的表述属历史记录，不算漂移。

存量 8 条，是否纳入修复待用户决定。整体质量：决策记录的可读性与「为什么不做」的留痕做得好，短板集中在**同一变更内多份文档的数字/结论没有在收口时对齐**，以及**契约文本比实现宽**（`close()` 那条会被当成测试与用法的依据）——建议归档前把 design 与 verify 的数值表逐项对账，并把 spec 的 `close()` 条件补全。另：`optimize-arg-staging` 的「不做」全部押在「TLS ≈300 ns」这一条无基线数据上（待验证假设 #3），若实测 <30 ns，该判定需按 `design.md:23-29` 的重做条件重审。

**范围外提示**：`f_jit/doc/design-m2.md:398`（M2-8 裁定行）与 `f_jit/doc/jit-bytecode-m2.md:518-521`（§14.3 括号注）仍写「非闭包包装实例：`close` → 19、`isClosed` = false；`unload` 仍为单元级」，与现行 `JitFunction.close()`（入口即卸载单元）相反，不在本部分文件清单内，留给对应部分处理。

**第 17 部分**：本部分是 `f_jit` 六个性能/编译优化变更的**归档规格**（proposal / design / tasks / verify），不含源码。就文档本身看，质量在平均线之上：每条改动都给了改前基线、护栏用例、变异验证与回滚条件，并且声称落地的代码我逐条核过，**全部真实存在**（`HandleTable` 64 分片 + `AtomicInt64 totalSlots`、`JitBindSupport`/`HostFieldTable` 写时复制快照、`FbcWriter.payload`、`A64Emitter` 按字存储、`Assembler.validateFunc` 免解码、`checkCrc32` 预分配、`JitExecutor.create` 去重复 `ICache` 刷新），未发现「文档写了、代码没做」的情况。

主要风险集中在两处，都不在代码正确性而在**承诺边界**：

1. **并发承诺边界**（发现 #1）：`escapeFlags` 由 `mtx` 与分片锁两把锁分别写、读侧还有完全无锁的 `isEscaped`，规格用「调用方非法用法」把它排除，但 public API 没有写这条约束，`moveOutGroup` 对跨线程调用又是静默 no-op。这条最值得排期——它影响的是句柄生命周期不变式，一旦命中，表现是「已提升句柄被收窗释放」，排查成本远高于修复成本。建议先按「统一锁 or 显式拒绝」二选一，再补一条跨线程逃逸的压测。
2. **判定闸门可复算性**（发现 #2）：四份 verify 里至少四处「保留」决定与本文档自己写的 `MOV = max(3%, 2×离散度)` / 「其它指标回退 ≤2%」不一致，且都以「机器噪声」解释而无线程状态或独占机复测。代码本身没问题，但归档件的价值是「为什么保留这段代码」；闸门被事后放宽后，后续同类改动的去留就没有共同基准。建议单独补一版闸门说明，而不是改动结论。

其余为事实性与计数笔误（发现 #3/#4），可在下一次触碰这些目录时顺手改掉。整体判断：**无阻塞项（本部分无代码），发现 #1 建议进修复清单、#2 建议进流程改进、#3/#4 随手修**。

**第 18 部分**：本部分是 `f_jit` 六组归档规格（编译路径并发、降低期直读操作数、发射审计、分支回填、helper 表、名字查找判定），不含源码。文档质量在平均线以上，最值得肯定的是**测量诚实**：emit-audit、decode-alloc 两组在实测没有收益时都明确写「未测得收益」，保留理由降级为「严格更少工作」，并把「跨场景外推微基准单项成本不可靠」写成教训；compile-lookup 更是在算出 0.2% 收益上限后直接判「不做」并保留测量记录。我逐条回代码核对，**声称落地的实现全部真实存在**：`labels` 改 `HashMap` 且首次绑定优先、`resolve(checkRange)` 单遍回填、`audit` 改实例字段、`translate(op, code, opsAt, …)` 去解码、`helperTableCache` 建在 `bindUserHelpers`、`snapCache` 在 5 个入口失效、`CodeBuffer` 探针已删 —— 没有「文档说改了、代码没改」。

剩余 10 条问题都不影响当前运行行为，但都是「归档件作为唯一凭据」时的可信度问题，按优先级：

1. **护栏清单有两处不实**（发现 #1，一般）：`missingLabelStillResolvesLikeBefore`、`pushTableDoesNotCopy` 只活在 design 表格里。等价性论证靠护栏，缺这两条时「改前也全绿」不再覆盖「未绑定标签」与「引用语义」，且 tasks/verify 的 4 条 vs 5 条、3 条 vs 4 条口径互相冲突。建议补用例而非改措辞。
2. **结论级漂移**（发现 #2/#3，一般）：`awaitReady` 的最坏等待粒度在 design 里是「数十 µs」、实现是 500 µs（半次编译）；compile-path 的 ≥2.0× 目标实测 1.84× 却没结项句，模块文档还标着「全部完成并归档」。这两条会直接影响下一轮调参与「要不要继续立项」的判断。
3. **同一事实多份复述且已漂移**（发现 #4/#5/#7）：`normalizeNewlines` 4 次 vs 实际 5 处（且把 `PredefinedSnapshot` 写成了 `NameResolver`）、200 vs 300 标签、tasks 只留 −85.5% 的最优配对而 verify 的保守值是 −53.9%。
4. **记录性残留**（发现 #6/#8/#9/#10）：300 ns 估算已被证伪仍被复用、`A64Emitter.cj:446-452` 的 ThreadLocal 旧论证与实例字段实现矛盾、五份 tasks 勾选的 openspec 归档在仓库里找不到产物、共享 `HashMap` 只读断言缺 std 依据。

无阻塞项。建议 #1 进修复清单（补两条护栏用例，成本很小），#2/#3 在下一次触碰这些目录时改（都是改文档，不动代码），#4/#5/#7/#8 顺手改，#9/#10 先把口径写清（「镜像即归档」/「待查 std 文档」），不必立刻补产物。

**范围外提示**（只记一句，不占统计）：`A64Lower.cj` 改用 `op = code[off]` 直读后不再做操作数长度校验，而 `FbcReader.cj:361` 的 `LoadedUnit` 有 `public init` —— 绕过 `load()` 直接构造的单元（截断/非法 opcode）会在 `A64Lower.i32/i64` 越界 panic，`decode-alloc/design.md §3` 的前提只对生产路径成立；`A64Emitter.finish()` 的 `case None => this.bytes()`（`A64Emitter.cj:167-172`）不可达且「先 `finish()` 后 `finishOrNull()`」会跳过范围校验（生产只用 `finishOrNull`，`finish` 仅测试用）；`CompileCache.cj:149` 的 `return None` 在 `while (true)` 之后不可达；`doc/optimize-compile-path.md:91` 决策日志留有一行空的 C3 模板行（C3 已在 M0 行判定「不立项」）。

**第 19 部分**：本部分是 `f_jit` 六个「调用路径 / 发射侧」优化的变更规格。就工程记录本身看，质量明显高于平均线：每组都有改前基线、护栏用例、变异验证与回滚条件，且**绝大多数声称落地的实现都能在代码里逐条对上**——`CtxFlags.DEADLINE` 与 A64 `ldr/and/cbz` 序列（`A64Lower.cj:363-381`）、`CallMarshal(rs)` 与 8 个 `With` 重载、`RuntimeState` 合并后的 2 次 TLS、两表 `AtomicReference` 快照 + 无键线性扫、helper 表预建后只入栈、`probeType` 惰性化，全部真实存在且语义与文档一致；被否决的两项（ctx 池、键索引）也留下了带数字的反例，是有价值的负结果。

问题集中在**决策变更后的文档回填**，而不是代码：

1. **x86 ctx 寄存器写错（发现 #1，一般）**：`design/proposal/tasks` 三处写 `rdi`，代码与字节断言是 `r15`。这是本部分唯一"照文档实现就会写出错误机器码"的错误，建议优先修——它是唯一可能被下游（x86 移植、审计）直接照抄的片段。
2. **`ITER/FAULT` flags 位与 `RuntimeStateFlags_test` 从未存在（发现 #2，一般）**：design 描述的是被 T2.4/T6.1 替换掉的方案。风险在于 ctx 是 64 B 冻结 ABI，照 design 补位会动布局；按 D7 找护栏会误判覆盖缺口。
3. 其余四条（`byKey` 伪代码、`MarshalRs_test` 用例数/全量数、`jitcontext-pool` proposal 缺回退标记且引用错文件、`SignatureRegistryVerification` 类名不存在）都是记录层面的陈旧，顺手改即可；其中第 3 条会实质性误导「借出口径」这一设计决策的读者，第 6 条会让「六条护栏是否落地」的复核直接扑空。
4. 附带一点：五组记录的全量用例数与仓内 `@TestCase` 计数差 13–32 条，已列入待验证假设 #3 —— 在确认 `cjpm test` 计数口径前，不宜用这些总数反推「有没有漏跑用例」。

整体判断：本部分无阻塞项（不含代码），发现 #1 建议进修复清单，#2 建议进修复清单（文档 + 一次全仓确认），四条轻微可在下次触碰这些目录时一并改掉。另有一条**范围外提示**（不占用本部分统计）：`doc/spec/optimize-loop-safepoint/tasks.md:43` 声称已更新 `doc/jit-bytecode-m1.md` 的回边描述，实际只有 §5（`:492`、`:500`）改成了「按需」，降低对照表 `jit-bytecode-m1.md:664`、`:2147` 与 §12.6 附近的 `:995` 仍写「无条件 `call H22`」，该文件的审查归其它分轮。第二、第三条范围外提示：`src/SignatureTableConcurrency_test.cj:28` 的文件头注释仍称实现改成「结构键 `HashMap` + 不可变快照」（与发现 #3 同源，源码注释不在本部分）；`doc/spec/optimize-helper-table/design.md:60-67` 列了 4 条护栏，其中 `buildTableKeepsHidOrder`、`pushTableDoesNotCopy` 在全仓 `.cj` 中 0 命中（实际 3 条，与本部分 `verify.md:26-32` 一致），该 design 不在本部分清单。

**第 20 部分**：本部分是两个"面向验收的测试文件 + 一个未被接线的注册表 + 15 份变更记录"。代码层面没有崩溃、越界、数据竞争或资源泄漏：`AdapterRegistry` 的锁使用是正确的最小形态（单锁保护两张表、锁内无回调/IO），`HandleTable` 的窗口开/关在用例里严格配对，`JitContext` 有 `finally` 释放，任何一条用例都不存在无界分配。

真正需要排期的是**契约面**而不是算法面：

1. **`AdapterRegistry` 是一份没有接线的设计**（`call` 第 5 步 / 卸载都没有调用它，`size()` 连测试都不用）。它现在唯一的产出是让 `AdapterRegistry_test` 显得有覆盖率。要么接上，要么删掉并把 `design-m1` 的调用关系改掉——这是本部分最该拍板的一条。
2. **用户面再导出漏了 `CallContext` 和 `InterruptedException`**。这两个类型出现在 `JitFunction.call` 的公开签名与异常通道里，缺了它们，「只 `import fountain::f_jit.*`」这句设计承诺就不成立；而本该抓这个的 `BaseVisibility_test` 因为自己 `import …base.*` 而永远抓不到（项目在 `FacadeSurface_test` 里已经承认过同一个坑）。
3. 规格里「卸载中到达的同键编译要等待」这条 `SHALL` 与 `design.md` D3 的"已知边界"直接矛盾，属于必须二选一的文档债：收窄措辞，或立项做缓存代次。

四条轻微项（重复登记计数、空 `catch` 的假绿、用例对全局句柄表/静态注册表的复位缺失、两份 spec 目录的统计口径互相打架）都不影响运行行为，可随下一次触碰这些文件时顺手修。两条优化方案（结构化键、`units` 去重+上限）都**没有基线**，只能留在「待验证假设」里等接线后的 profile 数据，不进本轮修复清单。

**第 21 部分**：本部分代码整体质量偏上：状态机（`CompileCache` 的 Idle→Compiling→Ready/Failed）、锁序（H1 的"锁外 bindCacheKey"、H5 的"类注册与方法并入同临界区"）、快照语义（类/函数注册只影响之后的编译）都有成文注释，并发与超时路径也有对应用例（`CallCompileConcurrency` / `CompileCache_test` / `CompileAwaitTimeout_test`），没有严重级缺陷。

风险集中在**进程级编译缓存的边界**：`ready` 无上限（#1）、命中无原字节二次校验（#2）、非 `Exception` 崩溃会把键永久卡在"编译中"（#3）——这三条都是"单次跑没事、长跑/异常输入才暴露"的类型，且下游 `f_egraph`/`f_rule` 已经在用"每次执行都编译新源码且不 close"的模式，建议一起排期。#4（可变配置双读）属确定性语义漂移，修法只是一行本地快照，性价比最高。#5 的递归深度建议随手改成迭代，与 #3 的 `StackOverflowError` 是同一根因链上的两个面。

其余 8 条轻微问题以死代码（#6、#7）、重复实现（#12）、误导性注释（#13）为主，不影响行为，可随下次重构清理。性能方面本部分没有任何测量数据，4 条优化方案全部标"无基线（待验证）"，需先在 WSL 侧用 `CallPathBench_test` + `cjprof` 补齐对照再决定是否立项。

**第 22 部分**：本部分是 `f_jit` 的「注册 / 绑定 / 重载解析」测试集群，加上两个薄产品文件。产品代码质量好：`JitBindSupport` 用「写时复制 + `AtomicReference` 原子发布」替换全局锁读路径，写者只在 `writeMtx` 内复制与发布、读者零锁且两张表同代，是我在本部分唯一需要证明的并发不变量，读完后成立；`EscapedClosure` 刻意把 `state`/`active` 交给所属单元的 `mtx` 保护并在注释里写明「不在条目上加锁」，实际读写路径与该约定一致，没有偷跑出来的裸访问。typecode 分支表这块本部分只看到常量与宏的分工（宏硬编码 14/3、常量无人引用，见 #7），真正的 typecode 分派在各 Lower/Marshal 文件里，属其它部分。

风险集中在测试层，且都是「给了安全感但没给保护」这一类：并发注册用例的成对断言发生在注册返回之后，观察不到它自己声明的窗口（#2）；性能门禁是单样本 + 固定顺序（#3）；断言失败会把恒阻塞钩子留在全局锁内，让进程挂死而不是变红（#4）。这三条不修，后续对注册路径或绑定快照的重构很可能在「全绿」的情况下把缺陷放过去。另有 2 个文件缺版权头（#1），修起来最便宜。

无阻塞项（0 严重）；4 条一般建议排进下一轮，11 条轻微里 #5 / #7（注释与常量的口径）优先，因为 `typecode` 一旦调整，宏与常量的漂移不会有任何编译期告警。

**第 23 部分**：本部分代码整体质量偏高：`JitFunction` 的状态机、句柄窗口记账与三态收尾的设计意图都用注释写清了「为什么」，测试密度也高（并发、生命周期、错误码逐码覆盖都有专门用例），死代码与重复逻辑经机械排查后只剩两处低风险项。

风险集中在**卸载路径的并发性**：

1. `close` 的超时回退是无条件写状态，与「另一个线程已成功 close」交错时可以把已释放的单元恢复成可调用态（严重，崩溃面）；
2. 同一段代码用自旋次数冒充毫秒超时，慢机/高竞争下等待时间不可控且占满一核（一般）；
3. 卸载逐出与缓存查找之间存在「拿到已终结单元」的窗口（一般）。

按「阻塞项」看待第 1 条（崩溃 + 可用性），第 2、3 条建议排期；其余为可读性与测试口径问题。`parseFnType` 的解析缺陷（一般）只影响「返回泛型/高阶闭包」的 `callForFn` 场景，但一旦命中就是必然的契约错误，建议与本轮 typecode 表合并一起修。

**第 24 部分**：本部分是「反射自动注册 + 用户面再导出」，除 `ReflectRegistrar.cj`（1003 行）与 `Root.cj`（46 行）外全是测试。产品代码的整体质量不错：注册是全量构建后再一次性登记（拒绝时不留半成品）、字段 `index` 让父类先占号、GAP-13 的引用型签名默认拒绝都有明确注释与用例锚点，`retained` 保活表也确实锁得对、`Compiler` 层用单个临界区保证了「类可见 ⇒ 函数可见」的 H5 不变量。

真正的风险集中在三处，都不阻塞发布但值得排期：
1. **typecode 判定的隐式约定**：`mapType` 用简单名前缀认容器，任何 `Range*`/`ArrayList*`/`HashMap*` 类名的宿主类会被静默判成句柄码，字段访问恒 99。这是「注册成功但永远用不了」的最难排查形态。
2. **继承字段的承诺与执行层不匹配**：`mergeAncestorFields` 让子类描述符包含父类字段，但纯反射访问器在子类实例上必抛 `IllegalTypeException` → 21；只有 `@JitBind` 才真能用。用例本身已经固化了这个限制（`reflectGetValueRejectsSubclassInstance`），说明是已知但未在注册期收口的问题。
3. **性能门禁放在单元测试里**：`PerfOverride_test` 的注释自带一次假失败记录，`rc` 被钳到 `1` 会让噪声直接变成红。对 CI 稳定性是长期消耗。

轻微项以「注册期诊断不对称」（父类成员跳过不报、父接口缺失不报、深度截断不报）和「测试自身不严谨」（死局部、恒真 `TCase.hit`、裸 helper id、全局静态配置不复原）为主——前者影响可诊断性，后者会让护栏名存实亡。`Skeleton_test.sixPackagesAreReachable` 是最典型的一个：注释说它在守包结构，实际断言的是一个本地数组长度。

`doc/perf-m2.md` 记录的端到端 1.1–1.6×（`call<T>` 固定开销 8–17 µs 吃掉 36× 差额）与本次读到的 `PerfOverride_test` 门禁口径一致，本部分不重复提性能结论；本部分给的 CPU/内存方案均标 `无基线（待验证）`，不进 `tasks.md`。

**第 25 部分**：本部分（AArch64 发射器/降低/编排 + x86 模板库 + 码内存 + 缓存键）的编码层质量整体偏高：指令编码有 `as`/`objdump` 期望字护栏，字节口径与字存储的错位有专门用例，回填从线性扫改哈希索引并保留「首个绑定优先」的旧语义，G5 内存基址审计做了按实例隔离 —— 这些都是踩过坑之后的正确修法。

真正的阻塞项只有一个但很硬：`A64Compiler` 用 `subImm` 直接写帧尺寸与 `x20` 基址，而 `subImm` 只取 imm12 低 12 位、`nLocals/maxStack` 又全链路无上限。`nLocals >= 507` 的函数会静默错位并覆盖保存寄存器，且不降级解释器 —— 这是「看得见代码就能定」的内存破坏面，建议立刻加拒绝路径或改 `movImm64+subReg`。

其次值得排期的是结构性的一件：`BackendSelector`/`Backend`/`Engine`/`CompileCacheKey` 这一层契约没有任何生产消费方，生产走的是 `JitExecutor.create → JitCompiler.compileUnitWith` 的另一条 arch 分支；后果不是抽象的「分层不清」，而是 `base/Engine.cj:26-27` 承诺的 `(Warn, JitFallback)` 诊断在生产上永远不会出现，非 Linux 用户无法感知降级。`fRoundOp` 那一族 SSE2 取整模板同样是「写了、测了、没接」的第三份实现，且其中 round-half-even 的收尾逻辑本身是错的（`round(3.0)=2`），一旦有人按注释接线就会静默算错 —— 建议要么删、要么修好再接。

其余为轻微：4 个零引用原语与 6 个未用条件码、6 组同语义重复序列（错误收敛 3 份、栈护栏 2 份、取反表 2 份、`emitDump` 2 份、x86 位运算 3 对、`bitBin` 纯别名）、ctx 偏移魔数与 `JitContext.OFF_*` 并存、`emitCallHelperNC` 的 `size-10` 耦合、`strD/ldrD` 缺校验、`finish()` 吞 `None`、`bail` 与 `bindBail` 转储不对称。均不影响当前运行结果，可随后端接线一并清理。

存量缺陷共 12 条（含 5 条 §11），是否纳入修复待用户决定；本报告不改源码、未运行构建。

**第 26 部分**：这一部分的核心风险是**x86_64 后端的正确性没有被真实执行兜住**：生产 lowering 把指令编码内联重写了一遍，而 23 个字节级用例断言的却是另一套（未参与生产的）`BackendX86_64.emit*` 模板，结果 `NE_F` 的 NaN 语义已经与解释器/A64 相反却无人发现——这是本轮唯一的严重项，且只在 x86_64 Linux 上暴露（当前 CI 为 aarch64，属"发布即带病"的风险面）。同一根因还派生出 0x9D 错误收敛路径的跨引擎报告差异。

资源与并发面整体是健康的：`JitExecutor.create` 五条失败路径都按「码内存最后释放」的顺序对称回收，`NativeAssets` 的计数改成原子，`fnTableBase` 走线程私有 TLS，审计表做了线程隔离，`X86Depth` 用迭代而非递归、单函数深度上界明确。可以排期的项是 `invokeOff` 的 malloc 未判空与两处编译期重复（双 `CHECK_ERR`、三份码流副本），都属于"改动小、可验证"。

存量 14 条（含 1 严重、4 一般、9 轻微），是否纳入修复待用户决定；性能类结论全部无基线，仅作方案与待验证假设，不进 `todo.md` / `tasks.md`。

范围外提示：`BackendSelector.cj` 里约 130 个仅测试使用的 `emit*` 是否保留属可见性/存废决策；`A64Lower.bail` 对 `BAIL k>0` 不转储而 x86 转储，与 §7 伪指令表「k>0 时单次转储」不一致（`A64Lower.cj` 不在本部分清单，留待其所属部分核实）。

**第 27 部分**：本部分是 f_jit 的类型码表与注册契约底座，主干代码质量良好：`LocalType` 的分支表（`isHandle` / `isConvertible` / `hasBoxPoint` / `isSameOrDescendant` / `fromToken` / `isLegal`）与文档表格逐位对齐，边界（0–3 值型 / 4–19 句柄型 / `NONE=0xFFFF` / 三版合法集）没有找到差错；`SignatureRegistry` 的「写时复制 + 原子发布 + id 只追加」是本模块并发处理最干净的一处，读路径无锁且语义成立；`ErrCode` / `RegistrationException` / `SourceCompileException` 的码表与消息组装同测试逐项咬合。

风险集中在**「对外 API 的入参没有被契约拦住」**这一条线上，两条一般级问题都出自这里：`JitBindings.withOverrides` 只合并四张表、静默丢弃 `parents`（F1，会让接口继承链在手工注册路径上消失，前端子类型判定给出错误结论）；`HostSignature` 对 `params` / `paramNames` 的长度与类名一致性零校验（F2，轻则注册期抛越界，重则两个不同类的签名撞成同一 id 而错派 adapter）。两者都属「合法用法不受影响、误用无提示」，不阻塞当前主路径，但会把下游的配置错误变成运行期错派或远端崩溃，建议优先补校验与合并语义，成本很低。

其余为可维护性问题：5 处枚举 `==` 与 4 处 `replace*` 的同模板复制（F5、F6）、4 份签名形状比较（F7）会让「形状」定义在多处漂移；6 处注释停在改造前（F8，其中 `LocalType` 的两条会直接误导分支表写法）；测试侧有一条与契约相反的用例（F3）和若干零判别力断言（F11），会制造「契约已覆盖」的假象。三条一般级问题都建议排期，轻微项可与下一次 `f_jit` 重构合并处理。

**第 28 部分**：本部分的骨架质量不错：显式小端编解码、`FbcHeader` 的布局兼容、`FbcReader` 的 11 类集中校验都写得克制且有针对性，`ByteReader` 的越界一律走 `rejectFormat` 也守住了「不越界访问」的承诺。风险集中在两处：

1. **常量键的规范化是 2 类严重问题的交汇点**。`CanonKey.dec` 只去尾零、三处 Decimal 文本解析各写一遍，导致 `|v|<1` 的 Decimal 常量键在运行期永不命中 —— 这是 P1-7 明确要消灭的现象的残留面，属于阻塞项，应当先修并补 `0.5`/`0.25` 用例。同一模块的 DAG 递归实例化没有深度上限，让「畸形 `.fbc` 必被 18 拒绝」的契约在深度维度上失守（崩溃而非拒绝），建议与上面同批修。
2. **次要项可排期**：负 `epochNanos` 的 `DateTime` 会在加载期抛宿主异常；`regexCompileCount` 与 `instanceAt` 的并发面（一个丢计数、一个可能重复实例化）在单线程加载路径上不显现，但公开 API 允许多线程触碰；`TypeNames.codeOf` 把 `Array<>` 归为句柄 LIST，会让验签放过不可能成立的签名。

性能维度本部分**没有任何测量数据**，因此三条 CPU、一条堆内存方案全部标为「无基线（待验证）」，只进下一轮补数据清单，不进 `todo.md` / `tasks.md`。存量缺陷共 18 条（严重 2 / 一般 5 / 轻微 11），是否纳入修复待用户决定。

**第 29 部分**：本部分是 `.fbc` 容器的核心读写面，序列化/反序列化的**边界校验总体扎实**：`count` 先按剩余字节校验、`codeOff/codeLen` 用减法防溢出、`crc32` 覆盖四段、`rel32` 以「下一条指令」为唯一基准、opcode 表有 256 项自检 + FNV 金值（本部分用脚本复算了 `10437089730419021315`，与用例一致）。没有严重缺陷，也没有栈溢出、无界增长或锁问题。

主要风险不在解析器，而在**「设计口径」与「生产路径」的接线**：#F1（D8 的命中后二次校验没有接，`DedupGuard` 只被测试引用）与 #F3（`sourceKey` 的换行规范化没被 `compile(source)` 使用）都是「能力已写好、入口没接」；这类问题不会让测试变红，但会让文档承诺与运行时行为长期分叉。其次是 #F2：`NameTable.validate` 里为取一个已经存在的 `nLocals` 做 O(n) 反查，并用 `let _ = unused` 压掉告警，顺带把「types 短于 dir 就抛非 18 异常」的边界暴露在公开方法上。

其余 12 条轻微项分两类：一类是重复实现（hex 4 份、升序检查 6 份、validate 双重载、边界常量双份、crc 双路径），另一类是测试质量问题（identity 弱断言、重复用例、两个未使用 import）。建议排期：先修 #F1 / #F2（一般），其余随重构收敛；O1–O4 需要先补基线数据再决定是否进 tasks。

本部分 14 条发现全部为存量（工作区快照无 diff），是否纳入修复待用户决定。

**第 30 部分**：本部分覆盖 JIT 前端的最后两段（AST 定义/形状化、单函数发射器与汇编器），无 `.md`。核心结论：**汇编/发射的字节级实现是可信的**——目录布局（`4 + 26n` 与 4 个 `u32` + 5 个 `u16` 字段逐项核对一致）、站点相对→绝对偏移回填、`rel32` 口径、`CHECK_ERR` 收敛块（目标 = 函数体末尾，解释器与 A64 后端都不依赖该目标作为 PC）、`CALL_HOST` 的 `[h_fn, a1..an]` 栈底句柄校验，逐条与测试断言一致，未发现数据错误、越界或崩溃路径。

唯一的「一般」项是终结语（`RET`/`RET_VOID`/`ABORT`）的簿记：字段注释承诺「终结语后为伪 dead code」但三个 emit 路径都没清 `reachable`/`slots`，同时汇编期对栈下溢只钳位不拒绝，导致 `Ops.cj:303` 声称「终结语 `pop` 供 validator 使用」的口径在唯一出口指令上实际为空——目前 Lowerer 不会在 RET 后继续发码，所以是**校验缺口而非线上故障**，可排期修。

其余 12 条均为轻微：死代码（`BytecodeBuilder` 4 个公开成员、`CaptureDescriptor.describe`、`AstExpr.MemberName` 及其 14 处死分支、2 个死 import、1 个恒真守卫）、重复原语（`argc` 取法两份、hex/u16/补码三组）、测试质量（③ 装箱插入点名不副实、7 处恒真 `TCase.hit`、失败路径泄漏）与注释漂移。其中「hex 三套实现」已经在范围外的 `Lexer.hexDigit` 上长出一个真 bug（0xE 打成 `F`），建议优先收敛。

**第 31 部分**：本部分（词法 + 明确赋值数据流 + 编译会话 + 类注册视图 + 转储工具 + 9 个测试）代码密度高、注释质量好，测试覆盖是这批文件里最强的部分：`Lexer_test` 对 60 个 `TokenKind` 做穷尽构造、词法错误族逐 kind 一条用例，`CodeDump` 把断言口径统一成字符串，`CompileCopy_test`/`Golden_test` 把产物字节固定成契约。`CompileSession`/`Diag`/`CodeDump` 三个文件基本没有可挑的问题：成员全部有调用方，防御性拷贝与错误出口的注释都能对上实现。

风险集中在 `DefiniteAssignment.cj` 一个文件：它是本轮唯一的**严重**项来源（对 AST 无深度上限递归，长运算符链/深嵌套在数万层量级即可打爆编译栈），也是四条「一般」里两条的来源——`walkExpr` 与 `walkExprWithOuter` 两份平行遍历已经漂移（闭包内 `for-in`/多重赋值/下标目标不查外层，捕获未赋值变量被静默放行），状态表又是平铺名字表，与 `Lowerer` 的块作用域不一致（同名遮蔽时两个方向都能出错：放行读到 0、或误拒合法程序）。这三条建议合并成一次改造：作用域栈 + 单一遍历 + 深度计数，改完再用 T24 的捕获用例补反向断言。

另一条「一般」是空安全规则 3 的接线空洞（`typeOf` 被常量 `NONE` 短路，`o = null` 能写进句柄槽），属于「注释承诺了、实现只在窄路径成立」，应连同 `Lowerer` 的槽类型表一起补齐或明确降级。最后一条「一般」（`\u{…}` 无上界）会产出非法 UTF-8 并绕过唯一错误出口，属易修的小口子，建议与 `escapeLen` 的其它校验一起补。

9 条「轻微」全部是可机械验证的清理项（3 个零引用成员、2 处不可达分支、空骨架文件、重复的 `TypeRef→码` 映射、恒真返回值、未用 import、`CodeDump` 越界、注释与实现不符、4 个仅测试访问器），可以一次性排进治理批次。两条优化方案（规范化重复 4 次、全量 token 物化）都缺改前基线，按规则只作「待验证假设」，不进修复清单。

**存量合计 14 条（1 严重 / 4 一般 / 9 轻微）**，均为工作区快照下的既有问题（`git diff` 为空，无本次改动引入项）；是否纳入修复待用户决定。

**第 32 部分**：`Lowerer.cj` 是整个 JIT 前端的核心（AST → 字节码，3923 行、100+ 方法），类型分派密度极高。本部分的**阻塞项只有一条**：无初始化声明（`var x: T`）直接发 `STOREL` 而没有压值，这是合法语法 + 明确的上游支持（Parser 与 DefiniteAssignment 都放行）+ 宽松的汇编期栈校验三者叠加出的崩溃路径，属于必修。

次一级是四条「静态类型跟踪不闭合」的问题（位运算缺类型门、`if` 分支只留最后一支的 `last*` 旁路、HostObject 返回值硬安接收者类、尾递归不校验元数），它们共同的特点是**编译期不报错、运行期按错的类型码解释**——对 typecode 分支表这种设计最容易积累隐性错值，建议与「把 `last*` 旁路改成结构化返回值」一并排期，否则每加一类新类型都要在 8 个位置同步补分支。

死代码与重复逻辑各有明确结论：`MemberName` 整条已死的 AST 形态是最值得清理的一项（8 处分支 + 4 组逐行重复都挂在它上面，且已出现口径漂移）；`fnRetType`、`emitArith` 的 STRING 分支、恒真的 `ALLOW_ESCAPING_HANDLES` 是可直接删除的残留。

质量好的方面：JSON 谱系（15–19）的收窄/上行/装箱/写入值域四张表逐条对齐 `LocalType` 常量与 m3 口径，`SWAP` 栈序处理、`tryLowerTailRecursive` 的「先求值到临时槽再统一写形参」等易错点都有注释与正确实现；无锁、无线程共享、无原生资源，并发面干净。

存量 14 条（严重 1 / 一般 6 / 轻微 7），是否纳入修复待用户决定。

**第 33 部分**：本部分是 f_jit 的 DSL 前端（词法 / 语法 / 名字解析 / 明确赋值 / 管线编排）加 12 个验收测试，共 4 个源文件 2290 行、12 个测试文件 1991 行。**设计意图清晰、注释密度高**（每条不变量都写了"为什么"），`SourceCompiler.compile` 的无状态编排、`PredefinedSnapshot` 的不可变快照、`FuncFlags`/栈效应表的"单一权威"思路都站得住；opcode 常量与 `OpInfo`、`HelperCodec` 与 `HelperId` 我做了逐条机械比对，当前数值完全一致。

风险集中在同一处：**Parser 的回退式文法消歧判得太宽**。`x = (…)` 被吞成多重赋值（#2）、`a / b / c` 被吞成替换段（#3）、插值走裸子解析丢了类注册表且不查尾随 token（#1），三者都不是"数据算错"，而是**合法源码写不出来 / 写出来被静默改写**，属于使用者会立刻撞上的可用性缺陷，建议作为本部分的第一批修复。其次是 `parseDigits` 无范围校验（#4，会突破"编译期错误一律 `SourceCompileException`"的对外契约）与解析器递归无上限（#5，深嵌套源可让宿主进程栈溢出终止；接外部表达式串时应升级为严重）。

死代码与重复集中在 `Ops.cj` 的工具函数（三个判定函数零引用、`CALL_HOST` 表项不可达）、`CompiledSourceUnit` 的两个死字段，以及"换行规范化 4 次 / 两份实现"——都不影响正确性，但注释里描述的两道自检防线（`Ops.agreeWithOpInfo`、`HelperId.isFixed` 守门）实际不存在，建议补一条遍历式用例，否则下一次单边改码表不会有任何提示。测试面本身覆盖了率先要守的行为（三引擎差分、未注册诊断、DA 边界），但存在恒真断言与不看错误码的弱断言（#16），以及会污染全局开关的用例（#6），使"全绿"的信号弱于表面。

阻塞项判断：无（0 条严重）。#1–#4 建议按"功能缺陷"排期修，#5 视调用方是否接外部输入决定优先级；其余轻微项与 4 条优化方案可延后，优化方案在拿到 `cjprof` / 分配量基线前不进修复清单。

**第 34 部分**：本部分（词法单元/诊断常量、三个宏、`AnyHelpers`、`DbgDump` 及其测试）整体质量良好：注释密度高且多数「为什么这么写」的解释可核（`diagReport(ERROR)` + `throw` 的双通道写法与 std 文档建议一致，不是冗余代码；`StarStar` 独立编号 90 的取舍也有说明）；`AnyHelpers` 的分支表与 `LocalType.isConvertible` 逐码对齐，A2 类界、窗口记账、`is` 不置错误的边界都写得清楚；`DbgDump` 的「首个收敛点获胜 / -1·-2 不转储 / 模板逐字节冻结」三条口径在实现与用例里一致。

风险集中在**宏与运行时的契约漂移**：同一套规则（setter 名、类型码表）在宏侧与反射侧各有一份实现，且宏侧那份在非 ASCII 名与 M3 新类型码上已经跑偏；`@IgnoreJitBinding` 对 `init`、`@JitBind` 对接口静态成员则是「文档承诺、代码静默不执行」这一类最难在测试里发现的问题。其次是 `DbgDump` 的两处健壮性缺口（null `dump` 直接解引用、`malloc` 失败不判空）：当前调用点都安全，但都偏离了同仓既有的防御约定。

无严重项与阻塞项。建议排期顺序：先修宏侧契约类（setter 名、init 忽略、接口静态成员、码表），它们都是「静默失效」，越晚发现越贵；`DbgDump` 两处健壮性各是一行守卫，可随手带上；其余重复逻辑与注释更正适合与相邻部分（`Lowerer`/`ReflectRegistrar`/其它测试文件）一并治理，避免只改一半。

**第 35 部分**：本部分覆盖句柄表（分块存储 + 分片空闲表 + 窗口记账 + 逃逸/常量）与 helper 分派表（81 个 hid、统一 `h_dispatch` 入口、cell↔宿主值转换），是 f_jit 运行时最核心、也是并发面最宽的一段。

整体质量偏上：锁序显式固定并写了注释（`mtx → 分片锁`），热路径读不加锁有明确论证，段地址稳定不搬迁、世代号退休、容量倍增与 `capacityLimit` 兜底都做了边界推导，测试里有专门的并发护栏与世代耗尽回归（这两个用例的质量高于仓库平均），81 个 hid 的分派逐值对齐、无空洞（名字表漏 H84，见发现）。

主要风险集中在三处，都不阻塞但需要排期：

1. **cell 值域混叠**（发现 #1）——`Int64 ≥ 2^48` 与 `Float64` 位型都可能落进活句柄 ID 的值域，而 `cellToAny` 靠 `isLiveHandle` 猜。注释里「天然不交」的断言是错的，会让后来者继续按错误前提加代码。这一条是唯一可能产生**静默取值错误**的缺陷，建议优先处理（改注释 + 在 §3.2 登记限制至少是必须的）。
2. **释放与读的原子性**（发现 #3）与 **`releaseConst` 缺世代校验**（发现 #2）——都属于「生命周期边界上少一道校验」，当前调用方恰好挡住了，一旦下游出现跨线程释放就会以 `Some(0)` 或 `ERR_NULL_HANDLE` 的形式冒出来。
3. **实现层面的可维护性债务**（发现 #4/#5/#7/#9/#10）——两个同义释放函数、13 处复制的槽守卫、4 个零引用符号 + 1 处不可达分支、2 处过期注释、1 条名不副实的用例。这些不产生行为缺陷，但每加一条句柄路径就要多改 n 处，是后续缺陷的温床；清理成本很低（都是 `private`/`internal`，无下游影响）。

性能方面本部分**没有可用基线**，因此 `popFreeWith` 的 64 分片探测、`pinConst` 的全表扫描、`toRuneArray` 的全串物化、每 helper 一次的 `Array<Int64>` 分配都只作为待验证假设，不作为缺陷；`replaceSpans` 的 10 倍输入放大是静态可算的，已按 OOM 风险报为一般。

本部分未覆盖：`LocalType`/typecode 分支表、`CallMarshal` 的 Marshal/逃逸收尾、`Interp` 的 helper 调用点 —— 这些分别在 f_jit 的其他部分，本报告的「桥接正确性」结论只到 helper 分派与 cell↔值转换为止。

**第 36 部分**：本部分的骨架质量不错：H63/H64/H65 的错误码分层（8/20/21/99）、`HostFault` 的线程本地旁路、`HostFieldTable` 的「不可变快照 + 原子发布」、`IterTable` 的调用级清空与 `JitFunction.call` 的 `finally` 收尾，都是能自证的设计，且用例密度高（本部分 10 个测试文件、50+ 用例）。

风险集中在**跨边界的位型/数值转换**与**解释器与机器码的语义对齐**两处：

- 必须优先修的是「浮点 cell 用检查型转换」——只要宿主闭包返回一个负 `double`，整次调用就以 99 失败，属于确定性数据错误，且解释器路径正确、JIT 路径错误，属两后端分歧；同一根因还让 H65 写负浮点失败。
- 其次是 `INEG(Int64.Min)`：`Lowerer` 会发射该指令，解释器/重放路径抛未捕获异常并跳过三态收尾，与机器码的「错误码 3」冲突。
- `IADD_WRAP`、`FFLOOR` 族、`TO_I64` 下界三处当前不可达或只在边界触发，可与上面两条一起作为「ISA 语义逐条对齐」一个批次处理，并同步修正把错误期望写进断言的 `Interp_test.cj:343-347`。
- 迭代器表 `gen` 恒 1 是「防护声明与实际能力不符」，会让 DEOPT 重放的陈旧游标读到别人的表项，建议与迭代器相关用例一起补齐。

其余（死分支、死代码、双份类型表、注释漂移、裸 hid）都是可排期的清理项，不影响正确性，但会持续拖慢本模块最需要的「typecode 分支表逐条核对」工作。

**第 37 部分**：本部分的代码质量整体良好：TLS 单载荷化（`RuntimeState`）、`SignatureTable` 的不可变快照 + 双检发布、`ipow` 的迭代快速幂与逐次溢出判定、`TextFormat` 把「最短往返」自己实现而拒绝依赖平台 `printf`，都是有明确设计取舍且注释到位的实现；测试覆盖也扎实（双路径逐位对拍、4 线程计数竞态、窗口隔离、线程私有环境）。

主要风险集中在**句柄生命周期**与**码表双口径**两处：

1. 唯一的一般项（F1）是提升组引用计数的作用域问题——计数在实例内、生产路径只有「整组释放」，注释承诺的「共享捕获保护」实际上不存在。后果是跨包装共享的闭包槽可能被先关闭的一方释放，属数据/契约级问题，但需要一条「两包装共享同一捕获槽」的用例才能从「待确认」落成「静态确定」，建议优先补这个用例而不是先改实现。
2. 码表口径分散（F2/F3/F15/F16）：`isLegalCode`、`signatureToken`、`userHelperToken`、`HostCall.mapToken` 四张表各自表述同一套 `LocalType → token` 关系，已经出现「映射支持但校验禁止」的死分支与两处不同的 14/JSON 取值校验。这类漂移不会立刻报错，但会随着后续放开 Regex/JSON 变成难查的 19/99。
3. 存量轻微项多为注释与实现脱节（F4/F5/F6/F7），其中 F5 的「各减 1 vs 减到 0」与 F1 是同一根因的两面，改注释时必须与 F1 的结论一起定。

存量缺陷共 16 条（1 一般 + 15 轻微），按规则只报不修，是否纳入修复清单待用户决定；两条优化方案均无改前基线，不进 `tasks.md`。

范围外提示（不占用本部分统计）：`f_jit/src/CallMarshal.cj:288-309` 的 `promoteClosureGraph` 递归深度由闭包嵌套层数决定，仅有 `visited` 防环、无深度上限，深层嵌套闭包存在栈溢出面；另 `HostCall.cj:251` 用 `HashMap.add` 覆盖同一 `ctx` 地址的旧异常记录，若某条失败路径没走 `takeCause` 而 `ctx` 地址恰好被复用，旧 cause 会在新调用里被读到。

**第 38 部分**：这 7 个文件的定位很清楚：一层「四元组对拍」的测试基建 + 一张 61 条的 T 编号映射表 + 一套自证用例。**数据与断言当前是干净的**——我逐条核对了 61 条映射的 `caseName`（全部能在 `src/**/*_test.cj` 中找到同名 `func`）与 61 个 `T<id>/` 标签（全部出现在可执行语句里，非注释），`diff_test` 的 11 个用例、`UserApi_test` 的 2 个用例也与实现一致，这部分不需要返工。

真正的风险在两处「看起来能跑」的地方：

- **`RealRunners.cj` 是一份已经落后于生产实现的 FFI 副本**。同一段「编译 → 映射 → 执行 → 收尾」在仓内有 4 份，测试层这三份缺少 `JitExecutor.invokeOff` 的 `try/finally`、`MachineEnv` 保存-恢复与常量句柄回收，并且 `write/seal/set` 的失败、`FnTable.alloc` 之后的 `mirror` 都未处理。现在用例只覆盖 Int64/F64/String 返回与 0~2 个实参，所以这些缺口没暴露；一旦有人用这套 harness 做「宿主对象 / 容器返回」的差分，会先遇到句柄 ID 假不一致，再遇到句柄表只增不减。
- **差分的「跳过」语义只写在注释里**。`DiffSession` 在只剩一个可用引擎时抛异常，而所有调用方（`Acceptance_test`、`DiffExec_test`、`Q6DiffCoverage_test`）都按「非原生平台应跳过」来写断言，结果是非 Linux / 非 x86_64-aarch64 平台这批用例必红。修这一条的成本很低（前置 `availableCount()` + 返回判定），收益是让「无证据」与「失败」在 CI 里不再混为一谈——这恰好是本模块最需要的信号质量。

建议排期：先修 `<2` 引擎的跳过语义与 `cells()` 的静默兜底（两者都会直接污染证据），再按 `JitExecutor.invokeOff` 收敛三份 `run`（顺带把常量句柄回收、`mirror.free`、`write/seal` 检查补齐），最后清死代码（`nativeRunner`）、过期注释（`TMapping`）与映射自证用例的名实不符。性能相关的两条（常量句柄缓存、编译产物缓存）都缺基线，先按「待验证假设」采数据，不进修复清单。

## 范围外提示（不计入统计）

- `src/compiler/Ops.cj:245` 注释写「H66 `cast_fail`」，常量值为 77（`CAST_FAIL = 77u16`），注释编号是旧的 H66。
- `src/runtime/JsonHelpers.cj` `jsonNew`：`mode` 非 0 一律构造 `JsonArray`（`mode == 0` 才建对象），非法 mode 静默落数组，与 design-m3 §5.2「mode 0/1」无拒绝路径。
- `src/JitFunction.cj:227-269` 的 `close` 排空用 `spins * 100000` 忙等而非等待/让出，`timeoutMs` 的语义是「自旋次数」而非时间，长超时会烧满一个核。
