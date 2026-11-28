# f_jit 模块审查报告（第 28/38 部分）

- **审查日期**：2026-11-28
- **模块路径**：`f_jit/`（本部分 20 个源文件：`src/base` 10 个、`src/bytecode` 10 个）
- **基线**：工作区快照（master 与 sts/1.3.x 同一提交 `120fd2542`，`git diff` 为空）⇒ 本报告所有问题来源均为「存量」
- **审查重点**：动态调用/桥接正确性（typecode 分支表）、句柄与资源生命周期、并发安全、递归与栈溢出、死代码、重复逻辑
- **报告版本**：分部分报告（由主 Agent 合并进 `docs/review/2026-11-28/f_jit_v2.md`），只统计本部分

## 发现

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

## 优化可行性方案

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

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `CanonKey.decFromText` 是 `Map<Decimal,_>` 读写路径的主要自耗时来源 | `f_jit/src/bytecode/CanonKey.cj:107` | 自耗时占比、每次分配量 | `cjprof record` 跑 10 万次 Decimal 键查找，看该函数 self time 与分配 |
| 2 | `tokenOf` 的 O(n²) 拼接在大 List 键常量上是真实瓶颈 | `f_jit/src/bytecode/ConstRegistry.cj:185` | 单次实例化耗时随 n 的曲线 | 构造 n=10/100/1000 的 List 键常量，分段计时取中位数 |
| 3 | `checkCrc32` 的整段复制显著抬高 `load` 峰值 RSS | `f_jit/src/bytecode/FbcReader.cj:232` | 峰值 RSS 对照（有/无该副本） | 10 MB `.fbc` × 100 次 load，`getAllocatedHeapSize()` + RSS 采样 |
| 4 | 三趟指令扫描占 `load` 端到端时间的可观比例 | `f_jit/src/bytecode/FbcReader.cj:270/320/395` | 三趟各自占比 | `cjprof record` 跑 1 MB code 段 load × 1000 |
| 5 | 超长 `PDec` 系数（如 1 MB 数字串）经 `BigInt.parse` 会产生超线性耗时/内存 | `f_jit/src/bytecode/ConstRegistry.cj:419` | parse 耗时与峰值内存 | 构造 1 KB/100 KB/1 MB 系数载荷，计时 + 内存采样 |
| 6 | 常量 DAG 深链在多深时触发栈溢出（决定 §4 的阈值取值） | `f_jit/src/bytecode/ConstRegistry.cj:146/178` | 每帧大小与实际崩溃深度 | 构造 1k/10k/100k 层嵌套常量段，跑 `load` 观察崩溃点 |

## 文件覆盖

> 与 `files/f_jit.part28.txt` 一一对应。

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `src/base/SourceCompileException_test.cj` | .cj | ✅ | 断言过弱，见「测试命名/注释/导入漂移」 |
| 2 | `src/base/SourcePos.cj` | .cj | ✅ | 纯值类型，`==` 与文档一致，无问题 |
| 3 | `src/base/SourceUnit.cj` | .cj | ✅ | 值类型 + 共享字节，与测试一致，无问题 |
| 4 | `src/base/SourceUnit_test.cj` | .cj | ✅ | 三条用例与实现一致 |
| 5 | `src/base/TypeNames.cj` | .cj | ✅ | 容器/泛型分类不一致，见一般级发现 |
| 6 | `src/base/TypeToken.cj` | .cj | ✅ | token 表缺 12=Any 的类注释，见轻微发现 |
| 7 | `src/base/TypeToken_test.cj` | .cj | ✅ | 函数名 Nine vs 11 项，见轻微发现 |
| 8 | `src/base/ValueTypes_test.cj` | .cj | ✅ | 只测值类型语义（`JitMode`/`Engine`/`JitValue` 定义在本部分之外），无问题 |
| 9 | `src/base/Version.cj` | .cj | ✅ | 常量与 §11.6 一致，无问题 |
| 10 | `src/base/Version_test.cj` | .cj | ✅ | 自带 LE 读写辅助（测试准备代码，不计重复） |
| 11 | `src/bytecode/ByteCodec.cj` | .cj | ✅ | 显式 LE 原语；`seek`/`f64bits` 仓内无生产调用（对外 API，不计死代码） |
| 12 | `src/bytecode/ByteCodec_test.cj` | .cj | ✅ | 与实现一致 |
| 13 | `src/bytecode/Bytecode.cj` | .cj | ✅ | 空占位文件，见轻微发现 |
| 14 | `src/bytecode/CanonKey.cj` | .cj | ✅ | 严重问题 1 与重复逻辑的落点 |
| 15 | `src/bytecode/ConstPayload.cj` | .cj | ✅ | kind 表与 §11.5 一致 |
| 16 | `src/bytecode/ConstPayload_test.cj` | .cj | ✅ | kind 11 注释漂移，见轻微发现 |
| 17 | `src/bytecode/ConstRegistry.cj` | .cj | ✅ | 严重 2 条、一般 3 条、轻微 6 条的集中地 |
| 18 | `src/bytecode/FbcHeader.cj` | .cj | ✅ | legacy 判据内联复制，见重复逻辑 |
| 19 | `src/bytecode/FbcHeader_test.cj` | .cj | ✅ | 未使用 import，见轻微发现 |
| 20 | `src/bytecode/FbcReader.cj` | .cj | ✅ | 校验/分段/扫描逻辑，见一般与优化方案 |

合计：`.cj` 20 个 / `.md` 0 个 / 共 20 个，全部读完。

## 覆盖自检

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

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 2 |
| 一般 | 5 |
| 轻微 | 11 |
| 优化方案（堆内存 / CPU） | 1 / 3 |

## 总评

本部分的骨架质量不错：显式小端编解码、`FbcHeader` 的布局兼容、`FbcReader` 的 11 类集中校验都写得克制且有针对性，`ByteReader` 的越界一律走 `rejectFormat` 也守住了「不越界访问」的承诺。风险集中在两处：

1. **常量键的规范化是 2 类严重问题的交汇点**。`CanonKey.dec` 只去尾零、三处 Decimal 文本解析各写一遍，导致 `|v|<1` 的 Decimal 常量键在运行期永不命中 —— 这是 P1-7 明确要消灭的现象的残留面，属于阻塞项，应当先修并补 `0.5`/`0.25` 用例。同一模块的 DAG 递归实例化没有深度上限，让「畸形 `.fbc` 必被 18 拒绝」的契约在深度维度上失守（崩溃而非拒绝），建议与上面同批修。
2. **次要项可排期**：负 `epochNanos` 的 `DateTime` 会在加载期抛宿主异常；`regexCompileCount` 与 `instanceAt` 的并发面（一个丢计数、一个可能重复实例化）在单线程加载路径上不显现，但公开 API 允许多线程触碰；`TypeNames.codeOf` 把 `Array<>` 归为句柄 LIST，会让验签放过不可能成立的签名。

性能维度本部分**没有任何测量数据**，因此三条 CPU、一条堆内存方案全部标为「无基线（待验证）」，只进下一轮补数据清单，不进 `todo.md` / `tasks.md`。存量缺陷共 18 条（严重 2 / 一般 5 / 轻微 11），是否纳入修复待用户决定。
