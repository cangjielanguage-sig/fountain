# f_jit 模块审查报告（模块第 36/38 部分）

- **审查日期**：2026-11-28
- **模块路径**：`f_jit/src/runtime/`（本部分 17 个源文件，全部 `.cj`）
- **基线**：工作区快照（master 与 sts/1.3.x 同一提交 `120fd2542`，`git diff` 为空）⇒ 所有问题来源记「存量」
- **审查重点**：动态调用/桥接正确性（typecode 分支表）、句柄与资源生命周期、并发安全、递归与栈溢出、死代码、重复逻辑
- **报告版本**：v1（分部分报告，只统计本部分；由主 Agent 合并进 `docs/review/2026-11-28/f_jit_v2.md`）

> 本部分审查单元：H63 宿主调用转发器与异常旁路（`HostCall.cj`）、H64/H65 字段访问（`HostField.cj`）、解释器（`Interp.cj`）、迭代器表（`IterTable.cj`）、`JitContext`/`NativeMem`/`CtxFlags`（`JitContext.cj`）、`JitAnyBox.cj`、JSON 世界内 API（`JsonHelpers.cj`），以及对应 10 个测试文件。

## 发现

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

## 优化可行性方案

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

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 字段访问 `HostFieldTable.find` 的闭包调用是热点 | `f_jit/src/runtime/HostField.cj:121-133` | `find` 自耗时占比、桶长分布 | `cjprof record` 跑字段读写密集负载（每类 ≥3 字段、1000 万次访问），看 self time 与调用次数 |
| 2 | 注释器每帧分配是 GC 主要来源 | `f_jit/src/runtime/Interp.cj:37-45`、`:667-675` | 每万次调用的分配字节数、GC 次数 | `cjprof heap` + `getAllocatedHeapSize()` 前后差，跑 10 万次解释执行 |
| 3 | Map 迭代窗口槽峰值按 2n 线性增长并在大 Map 触发 16 | `f_jit/src/runtime/IterTable.cj:202-211` | `capacityLimit` 下的实际 n 阈值 | 构造 `Map<String,String>`，n 从 1k 到 100k 迭代，记录 `windowUsed()` 与是否出现 16 |
| 4 | 解释器深递归的可达深度显著低于机器码 | `f_jit/src/runtime/Interp.cj:201-263` | 崩溃深度、每层栈字节 | 递归函数逐级增大深度（1k→100k），对比 JIT / Off 两种模式的崩溃点与栈占用 |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_jit/src/runtime/HostCall.cj` | .cj | ✅ | H63 转发 + `HostFault`；发现 #1、死分支、死代码、重复表 |
| 2 | `f_jit/src/runtime/HostCallTrampoline_test.cj` | .cj | ✅ | 14 个用例；未覆盖负浮点/`ret=13`/深递归 |
| 3 | `f_jit/src/runtime/HostCallback_test.cj` | .cj | ✅ | 条目/验签缓存用例，与实现一致 |
| 4 | `f_jit/src/runtime/HostFaultTls_test.cj` | .cj | ✅ | TLS 隔离用例，与 `RuntimeState.faults` 实现一致 |
| 5 | `f_jit/src/runtime/HostField.cj` | .cj | ✅ | H64/H65 与快照表；发现 #1、#9，重复 `fieldToken` |
| 6 | `f_jit/src/runtime/HostFieldGet_test.cj` | .cj | ✅ | 7 用例；未覆盖 F64 负值 |
| 7 | `f_jit/src/runtime/HostFieldSet_test.cj` | .cj | ✅ | 6 用例；注释 19/20 漂移（发现 #14） |
| 8 | `f_jit/src/runtime/HostFieldSnapshot_test.cj` | .cj | ✅ | 快照/并发/重入注册 4 用例，与原子发布实现一致 |
| 9 | `f_jit/src/runtime/Interp.cj` | .cj | ✅ | 语义基准；发现 #2–#6、死分支/死代码/重复逻辑集中地 |
| 10 | `f_jit/src/runtime/InterpHostCall_test.cj` | .cj | ✅ | 0x79 三用例，与 H63 逐位一致口径成立 |
| 11 | `f_jit/src/runtime/Interp_test.cj` | .cj | ✅ | 18 用例；`0x4A–0x4D` 期望值编码了分歧（发现 #4） |
| 12 | `f_jit/src/runtime/IterTable.cj` | .cj | ✅ | 发现 #7、#8；`isContainerToken` 死代码 |
| 13 | `f_jit/src/runtime/JitAnyBox.cj` | .cj | ✅ | 不可变盒，成员均被使用，无问题 |
| 14 | `f_jit/src/runtime/JitContext.cj` | .cj | ✅ | 发现 #10、注释漂移（发现 #14）；`NativeMem` 计数原子化正确 |
| 15 | `f_jit/src/runtime/JitContext_test.cj` | .cj | ✅ | 7 用例；顺序耦合与位表注释（发现 #14、#15） |
| 16 | `f_jit/src/runtime/JsonHelpers.cj` | .cj | ✅ | H81–H83；16–19 四连分支（发现 #13），`unused` 局部（#15） |
| 17 | `f_jit/src/runtime/JsonHelpers_test.cj` | .cj | ✅ | 6 用例；frozen 传播与出口解包均有覆盖 |

合计：`.cj` 17 个 / `.md` 0 个 / 共 17 个，全部读完。

## 覆盖自检

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

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 2 |
| 一般 | 8 |
| 轻微 | 5 |
| 优化方案（堆内存 / CPU） | 1 / 3 |

存量缺陷 15 条（全部为存量，快照模式无基线），是否纳入修复待用户决定。

## 总评

本部分的骨架质量不错：H63/H64/H65 的错误码分层（8/20/21/99）、`HostFault` 的线程本地旁路、`HostFieldTable` 的「不可变快照 + 原子发布」、`IterTable` 的调用级清空与 `JitFunction.call` 的 `finally` 收尾，都是能自证的设计，且用例密度高（本部分 10 个测试文件、50+ 用例）。

风险集中在**跨边界的位型/数值转换**与**解释器与机器码的语义对齐**两处：

- 必须优先修的是「浮点 cell 用检查型转换」——只要宿主闭包返回一个负 `double`，整次调用就以 99 失败，属于确定性数据错误，且解释器路径正确、JIT 路径错误，属两后端分歧；同一根因还让 H65 写负浮点失败。
- 其次是 `INEG(Int64.Min)`：`Lowerer` 会发射该指令，解释器/重放路径抛未捕获异常并跳过三态收尾，与机器码的「错误码 3」冲突。
- `IADD_WRAP`、`FFLOOR` 族、`TO_I64` 下界三处当前不可达或只在边界触发，可与上面两条一起作为「ISA 语义逐条对齐」一个批次处理，并同步修正把错误期望写进断言的 `Interp_test.cj:343-347`。
- 迭代器表 `gen` 恒 1 是「防护声明与实际能力不符」，会让 DEOPT 重放的陈旧游标读到别人的表项，建议与迭代器相关用例一起补齐。

其余（死分支、死代码、双份类型表、注释漂移、裸 hid）都是可排期的清理项，不影响正确性，但会持续拖慢本模块最需要的「typecode 分支表逐条核对」工作。
