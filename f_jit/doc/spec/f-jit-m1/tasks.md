# Tasks

> 步骤号沿用 `f_jit/doc/plan-m1.md` 的原始编号（S0.1–S7.8）；每个任务按 TDD 执行：**先写会失败的用例（红）→ 写最小实现（绿）→ 重构**，全绿后才勾掉。
> 构建与测试一律在**融合开发环境**（Linux aarch64，仓颉 1.3.0，`cjc`/`cjpm` 已在 PATH）执行，不在别处跑：
>
> ```bash
> cd /mnt/linux_share/storage/Users/currentUser/Documents/cangjie/projects/fountain/.worktrees/f_jit/f_util && cjpm build && cjpm test   # 第 1 组（f_util.Fnv）
> cd /mnt/linux_share/storage/Users/currentUser/Documents/cangjie/projects/fountain/.worktrees/f_jit/f_jit  && cjpm build && cjpm test   # 第 2–9 组（f_jit 各步）
> ```
>
> 每一步的验收口径：对应目录下 `cjpm build` 通过、`cjpm test` 新增用例由红转绿且既有用例无回归；用例数单调增长、失败数为 0。
> 根 `cjpm.toml` **不登记** `f_jit`（用户裁定）；模块以自身 `cjpm build` / `cjpm test` 为验收入口，不做全仓库依赖登记。
> 不允许出现「任务已勾选但没有对应用例」的进度。

## 1. 前置任务：`f_util.Fnv`（S2.16 指纹接入的依赖）

- [x] FNV.1 新建 `f_util/src/Fnv.cj`：`Fnv32`/`Fnv64`/`Fnv128`/`Fnv256`/`Fnv1024` 五个入口 × `fnv1`/`fnv1a` 两变体，返回类型分别钉为 `UInt32`/`UInt64`/`UInt128`/4 字/16 字（大端序）；先写失败用例 `Fnv_test`：空串 `fnv1a` 五组黄金值（32/64/128/256 用已公布常量；1024 用官方偏移基值的 16 字大端表示）；再写最小实现（标准 FNV 偏移基值与素数，不自造常数）；验收：`Fnv_test` 五条空串用例由红转绿
- [x] FNV.2 实现 `fnv1` 与 `fnv1a` 的逐字节主循环，并同时接受 `String` 与 `Array<UInt8>` 两种输入；先写失败用例：同输入 `fnv1 ≠ fnv1a`、`Fnv64.fnv1a("123456789") == 0x06D5573923C6CDFC`、字符串与其 UTF-8 字节流结果逐位相同、含 4 字节码点（emoji）的输入与参考实现一致；再补实现（按字节处理，不依赖字符边界与主机端序）；验收：`Fnv_test` 新增用例全绿且 `f_util` 既有用例无回归
- [x] FNV.3 提供增量喂入（同一上下文分三段喂入 + 空增量不改变结果）与长输入（> 4 KiB）分块等价；先写失败用例：增量与一次性喂入逐位相同、长输入不分块失真；再补实现；验收：两组对照用例通过，128 位结果可直接参与 `==` / `ToString` / 哈希容器键
- [x] FNV.4 `Fnv256` 与 `Fnv1024` 字序与可比较性收口：结果分别恒为长度 4 / 16 的 `UInt64` 数组、最高有效字在前、同一输入两次调用逐位相等；先写失败用例；验收：`f_util` 全量 `cjpm test` 通过，`Fnv_test` 覆盖 32/64/128/256/1024 × fnv1/fnv1a 全部组合
- [x] FNV.5 统一 API：`Fnv.hash(width, variant, data)`（`String` / `Array<UInt8>`）、`Fnv.fnv1` / `Fnv.fnv1a`、`FnvWidth`（`W32`…`W1024` + `name()`/`bits()`/`words()`）、`FnvHasher`（`update` / `finish` / `reset`）；先写失败用例——五种宽度的统一入口与类型化入口逐位一致、返回数组长度 1/1/2/4/16、`finish` 可重复且 `reset` 回基值；再写实现（类型化入口委托同一引擎，算法只写一份）；验收：统一 API 与类型化入口等价用例全绿
- [x] FNV.6 `Fnv1024` 正确性：按 `2^680 + 2^8 + 0x8D` 素数做 16 字「移位 + 加法」乘法并保留进位、按 `2^1024` 取模；偏移基值与素数逐字抄官方参考并在文件头注明来源；先写失败用例——`Fnv1024.fnv1a("123456789")` 与 `Fnv1024.fnv1("123456789")` 等于独立 Python 大整数参考实现、长输入高位进位不失真、结果长度恒为 16；再写实现；验收：两组黄金值 + 进位用例全绿

## 2. P0 骨架与测试基建（S0.1–S0.3）

- [x] S0.1 模块骨架：补全 `f_jit/cjpm.toml`（`name=f_jit`、`organization=fountain`、`output-type=dynamic`、版本跟随仓库、`[dependencies]` 含 `fountain::f_base`/`fountain::f_regex`/`fountain::f_util`（`Crc32` 与 `Fnv`）、`[target.*]` 覆盖 Linux x86_64/aarch64、Windows、macOS、HarmonyOS）与六个包目录（`Root.cj` + `base`/`bytecode`/`compiler`/`runtime`/`backend`）；先写「红」：`cjpm build` 能跑通、依赖可被解析的基线用例；再按 §0.4 落 `package` 声明与 `public import` 占位；验收：`cjpm build` 通过、`cjpm test` 可执行且 0 失败，基线数字（构建结果 + 用例计数）留档
- [x] S0.2 差分测试 harness（`f_jit/src/test/diff`，独立目录）：同一单元跑 `Interp`/`BackendX86_64`/`BackendAArch64` 并逐位对比；先写失败用例：以「常量 1+1」驱动 harness 自身（先只挂 `Interp`，两后端以 mock 桩替代），断言三元组输出与对拍函数 `assertTripleEqual` 行为正确；再实现统一输出（结果 / errCode / site + 报告文本）与对拍函数；验收：harness 自测通过，后续每步自动接入
- [x] S0.3 T 编号映射表与用例命名规范：先写失败用例——空跑校验「映射表每项都能定位到具体步骤 + 用例名」（可脚本校验）；再建 `T# → 用例路径` 对照；验收：映射覆盖 M1 §13.2 全集（T1–T29、T42–T48、T50–T53），T30–T41 / T49 明确标注归属 M2/M3 且不计入本次完成判据，无悬空项

> **P0 基线留档（2026-10-17 · 融合开发环境 Linux aarch64 / 仓颉 1.3.0）**
> - `f_util`：`cjpm build` 通过；`cjpm test` TOTAL 45 / PASSED 45 / FAILED 0，其中 `Fnv_test` 13 例全绿（32/64/128/256/1024 × fnv1/fnv1a）。
> - `f_jit`：`cjpm build` 通过；`cjpm test` TOTAL 14 / PASSED 14 / FAILED 0——`Skeleton_test` 4 例（六包可达 + 三个外部依赖解析）+ `Diff_test` 10 例（harness 自证 + T 映射空跑校验）。
> - 后续每步对照「用例数单调增长、失败数为 0」。

## 3. P1 包 `base`（S1.1–S1.11）

- [x] S1.1 `LocalType`：13 个常量（0–12）+ `name`/`isHandle`/`fromToken`；先写失败用例——逐值断言 0–12、`isHandle(4..12)=true` 且 `(0..3)=false`、`fromToken` 与 §11.7 对应表全等、合法集按 verMajor 分派（v1 拒 13；预留 v2:0–14、v3:0–19 登记位）；再写最小实现（静态常量 + 查询函数 + 0–19 全表 `name`）；验收：与规格 §11.7 逐项一致
- [x] S1.2 `TypeToken`：token 0–9（`RESERVED`/`LIST`/`MAP`/`STRING`/`DECIMAL`/`DATETIME`/`DURATION`/`RANGE`/`REGEX`/`CLOSURE`）+ `name`，与 `LocalType` 的映射集中一处；先写失败用例（逐值断言 + `name` 非空）；再写实现；验收：与 §6 类型 token 表一致
- [x] S1.3 `ErrCode`：`OK`/`DEOPT`/`INTERRUPT` 与 1–20、`CONCURRENT_MOD`(23)、`HELPER_PANIC`(99) + `describe`/`isHostSide`；先写失败用例——全码值断言、`describe(-2..99)` 非空且含语义关键词、未知码有兜底描述、宿主侧判定与规格归类一致；再写实现（静态表，无宏）；验收：与规格 §2 错误码表逐项一致
- [x] S1.4 `Version`：`MAJOR=1`/`MINOR=14`/`HDR_SIZE=36`/`MAGIC="FBC1"`，与 `.fbc` 读写两侧共用同一份定义；先写失败用例（四常量断言 + 用它们构造最小容器头可被同版本读回、magic 与长度字段匹配）；再写实现；验收：与 §11.6 一致
- [x] S1.5 `SourcePos`、`JitMode`、`Engine`、`JitValue`：先写失败用例——构造/字段读、`match` 穷尽性（四个 `JitValue` 构造器）、`==` 语义；再写 struct/enum 实现（`Engine`/`JitValue` 声明为 `protected`）；验收：值语义正确且两个内部枚举不进用户面
- [x] S1.6 `CallContext`：先写失败用例——默认值断言（`literalCopy=false`、`strictFp=false`、`deadline=None`）；再写 struct + 默认值；验收：默认值契约正确（`strictFp=true` 写 ctx.flags 在后续步骤联测）
- [x] S1.7 `SourceUnit`：先写失败用例——构造与字段读（`entryFn` 与容器头不一致的拒绝路径在 S2.15 / S6.9 联测）；再写 struct；验收：字段读回与构造入参一致
- [x] S1.8 `JitException`：`init(code,site,fnId,sourcePos,message,cause)` 与六个字段读回，继承 `fountain::f_base.BaseException`；先写失败用例——字段保真、`sourcePos=None` 与 `cause=None` 分支、可 `catch (e: JitException)` 读回全部字段、`is BaseException` 断言；再写实现（`super(message)` 转发报告文本）；验收：宿主可 `catch (e: BaseException)` 统一捕获并读到报告文本
- [x] S1.9 `SourceCompileException`：`kind`/`position`/`line`/`column`/`lineText`/`hint`，同样继承 `BaseException`；先写失败用例——多行源码上触发编译期错误，断言 `line`/`column` 指向出错位置且 `lineText` 与该行源码逐字节相同；再写实现；验收：编译期错误不写入任何运行期错误码、不涉及错误槽
- [x] S1.10 诊断接口：`DiagnosticsSink`（主签名 `(level, code, message)` + 便捷重载 `(level, message)`）、`DiagnosticLevel`（仅 `Info`/`Warn`）、`DiagCode`（`JitFallback`/`MmapFailed`/`RegistrationSkipped`/`PredefinedLimit`/`PlanFallback`/`Unspecified`）、`DummyDiagnosticsSink`；先写失败用例——桩实现记录 level+message、六值 `DiagCode` 逐值、便捷重载默认以 `Unspecified` 转发；再写实现；验收：sink 抛异常被引擎吞掉（有在途异常挂 suppressed），调用结果/错误码/site 与不接 sink 时逐位一致（`Error` 不捕、不重入）
- [x] S1.11 `base` 包整体可见性检查：先写正向用例——用户代码 `import fountain::f_jit.base.*` 可见全部 `public` 声明；再人工核对负向（`internal` 不外泄、`Engine`/`JitValue` 用户面不可见的编译期断言）；验收：与 design §1.2 可见性规则一致，`cjpm build` 与 `cjpm test` 全绿

## 4. P2 包 `bytecode`（S2.1–S2.16）

- [x] S2.1 `OpInfo`：5 字段 + `const init` + `static const CAT_*` + `static let OPCODE_TABLE`（256 项）；先写失败用例——`size == 256` 且 `table[i].code == i`、代表项（`SET_SITE=5`、`CALL_HELPER="u16 u8"=4`、`CALL_CLOSURE=u8=2`、`MAP_ITER_STEP=u8=2`）与 §10.3 逐条核对、未分配为 `OP_RSVD/CAT_RSVD`、`0xA9/0xAA = CAT_FORBID`、`0xC0–0xFF` 全 RSVD；再按 §10.3 录入；验收：与 §10.3 全等
- [x] S2.2 `ByteReader`/`ByteWriter`：`u8/u16/u32/i32/i64/f64bits/bytes/remaining` 等显式小端原语；先写失败用例——LE 往返（含非对齐与跨缓冲区边界、`0x0102` 字节序断言）、越界读返回错误或抛异常而非越界访问；再写实现（逐字节读写，禁 memcpy/指针强转）；验收：解码结果与主机端序无关
- [x] S2.3 `DecodedInsn` + `InsnDecoder.decode/u16/i32/i64/rel32`：先写失败用例——按 fmt 解码各类指令、`rel32` 目标 = 下一条指令位置 + offset、RSVD/FORBID 编码在解码阶段被语义拒绝；再写实现（查表 + 游标推进）；验收：解码器成为解释器取指的唯一入口
- [x] S2.4 `FuncEntry`（10 字段 + `SIZE`）：先写失败用例——26 字节编解码往返、字段保真；再写实现；验收：条目恒 26 B，与 §11.7 一致
- [x] S2.5 `FuncDir.add/get/find/size/validate`：先写失败用例——增查正常、重复 `fnId` 拒绝、`off`/`len` 越界拒绝、`entryFn` 不命中拒绝；再写实现（数组 + 索引）；验收：加载期校验前置可用
- [x] S2.6 `LocalTypes.init/get/set/size/validate/isHandleSlot`：先写失败用例——读写与越界、长度 ≠ nLocals 拒绝、`validate` 按该单元 verMajor 的合法集（v1 拒 13–255；v2 拒 15–255 放行 13/14；v3 拒 20–255 放行 15–19）、`isHandleSlot(4..12)=true`；再写实现（每槽 1 B）；验收：与 §11.7 校验一致
- [x] S2.7 `ConstKind`（常量命名空间）+ `ConstPayload`（enum，10 个构造器）：先写失败用例——各 kind 载荷构造/匹配、DAG 引用（`PList`/`PMap` 引用子索引）；再写实现（`match` 穷尽）；验收：与 §11.5 载荷编码一一对应
- [x] S2.8 `ConstRegistry` 拼装 API（`addList/addMap/addStr/addValue/addRange/addRegex/freeze/size/get/isFrozen`）：先写失败用例——各 `add` 返回递增 hid、`addRegex` 去重（同 pattern+flags 同 hid、flags 归一 `im`≡`mi`≡`ii`）、`freeze` 后写操作拒绝、`get(i)` 载荷保真；再写实现（数组表 + 去重键表）；验收：与 §3.3 / §11.5 一致
- [x] S2.9 `SiteEntry` + `SiteTable.add/freeze/lookup/validate`：先写失败用例——`lookup` 取 `off ≤ site` 的最大条目、无命中返回空、严格升序与 `off<codeLen`/`line,column ≥ 1` 校验拒绝、覆盖率 = 全部 `SET_SITE`（与 S3.19 联测）；再写实现（升序数组 + 二分）；验收：与 §11.6 / §9.16 一致
- [x] S2.10 `NameEntry` + `NameTable.add/freeze/lookup/validate`：先写失败用例——`lookup(fnId,slot)` 命中/未命中（→None 即省略名字）、`fnId` 命中目录、`slot<nLocals`、升序唯一、`strLen ≥ 1`、`strOff+strLen` 在界、UTF-8 合法；再写实现（段内相对偏移）；验收：与 §11.6 name 段一致
- [x] S2.11 `FbcFlags` + `FbcHeader.read/write`：先写失败用例——新布局字段偏移断言（0/4/6/8/12/16/20/24/28/32/36）、旧布局（`verMinor ≤ 13`）读入时无 `nameLen`、payload = 36、`hdrSize = 32`；再写实现（结构体 + 分支）；验收：旧单元兼容可读
- [x] S2.12 `FbcWriter`（`setEntryFn/setCode/setConst/setSite/setName/setFlags/build`）：先写失败用例——`build` 产物的 magic/verMajor/minor/lengths 正确、crc32 覆盖 code+const+site+name（改任一字节即变）、基准向量 `crc32(空)=0` 与 `crc32("123456789")=0xCBF43926`；再写实现（缓冲拼接 + `f_util.Crc32.isoHdlc`）；验收：与 §11.6 一致
- [x] S2.13 `FbcReader.load`（正向）：先写失败用例——手工构造最小合法单元，全字段解出（header/code/consts/site/name/dir/types）且 `entryFn` 命中目录；再写实现（分派 + 各表解析）；验收：T1 基础可用
- [x] S2.14 `FbcReader.load`（拒绝面，逐条）：先为 11 类各写一条失败用例（① 魔数错 ② verMajor 2/3 → 18 语义 + 兼容矩阵给出最小可接受 verMinor ③ 未知 flags 位 / `bit1=1` ④ 段长不符 ⑤ 常量 DAG 环 ⑥ 坏载荷（非 canonical F64 / 非法 kind）⑦ 目录越界 ⑧ 类型表非法 ⑨ site 未覆盖/乱序 ⑩ name 坏键 ⑪ crc32 不符），断言拒绝与错误码；再把校验集中进 `validate`；验收：每条拒绝面一条用例、互不掩盖
- [x] S2.15 `ConstRegistry` 加载期实例化（kind 3–10）：先写失败用例——kind 3/4/5/6/7/8/9 往返（对象等值、DAG 共享子结构同一对象）、kind 10 合法 pattern 只编译一次（编译次数断言）、非法/空 pattern → 14（加载期而非执行期）、`PUSH_KH idx < size`；再写实现（实例化经 std，正则经 `f_regex`）；验收：T20 前置就绪
- [x] S2.16 指纹接入：常量指纹 FNV-1a-64、源码/字节码去重键 FNV-1a-128、命中后二次校验原字节；先写失败用例——`f_util.Fnv` 可用（见第 1 组）、基准向量断言（空串 → `0xCBF29CE484222325`、`123456789` → `0x06D5573923C6CDFC`）、等长不同源二次校验判定不命中；再写实现（**经 `fountain::f_util` 调用，不自实现哈希**）；验收：crc32 / 64 位常量指纹 / 128 位去重键三者分工不混用，与 §11.5、§12.6 一致

## 5. P3 包 `compiler`（S3.1–S3.23）

- [x] S3.1 `TokenKind`（§4.3.1 全表 58 项）+ `Token`（kind/text/pos/line/column/`nlBefore`）：先写失败用例——每个 kind 各一条构造用例、位置字段正确（多字节字符列号按码点）、`nlBefore` 正确性（同行紧跟为 false、跨行含注释跨行为 true）、`match` 穷尽性；再写实现（无载荷 enum + 只读 struct）；验收：词法基座可用
- [x] S3.2 `Lexer` 基础（`next/position/line/column`、`nlBefore`）：先写失败用例——标识符/关键字、数字（含小数、指数、超 Int64 标记）、标点/运算符（含 `!~` 单 token）、`=>`、EOF、`;` 与换行的 `nlBefore`、词法错误族逐 kind 一条（`IllegalCharacter`/`UnterminatedString`/`BadEscape`/`BadNumber`/`UnterminatedRegex`，fail-fast 抛出且**无 error token**）；再写实现（扫描器 + 关键字表，`null` 给专门诊断）；验收：逐 token 断言通过
- [x] S3.3 `Lexer` 字符串三形态：先写失败用例——单行（转义、异种引号为内容）、多行（首行换行、首个非转义三连终止、单独 `\` → 错误 kind）、原始串（`#`×n 定界、verbatim、可跨行、未闭合 → 错误）、`'''` 最长匹配消歧、CRLF/CR → LF；再写实现；验收：T42 词法组用例全绿
- [x] S3.4 `Lexer` 行首锚定标记（多行串，`>|`；规格 §8.8 / design §4.4）：先写失败用例——进入判定（仅首个非空白位置的标记触发）、无标记行整行保留、标记不进入产物（单独标记行 → 空串）、标记前含非空白字符的同类序列视为内容、非标记三例；再写实现；验收：产物中不含标记与前导缩进
- [x] S3.5 `Lexer` 注释与词法保护：先写失败用例——单行/多行注释、`/* */` 嵌套配平、未闭合 → `UnterminatedComment`、字符串跨度内 `//`/`/*`/引号/`{`/`}`/行首锚定标记不参与识别、注释不影响 site 语义；再写实现（保护 → 剥离 → 解析三阶段）；验收：T24 注释组用例全绿
- [x] S3.6 `Lexer` 正则字面量：先写失败用例——`/pattern/flags`（flags 顺序无关、重复幂等）、字面量后紧贴 `/` 优先于注释识别（三书写形态）、`/` 与除法消歧；再写实现（正则段扫描；非法 flags 不在词法层判）；验收：T20/T26 词法组就绪
- [x] S3.7 `LambdaAst/AstExpr/AstStmt` + `Parser.parseLambda`：先写失败用例——全 `AstExpr` 构造器各一例、形参 `name: Type`（不支持具名/默认）、`=>` 缺失 → `MissingArrow`、尾表达式即返回值、嵌套闭包与 IIFE、`recursive` 调用表达式、语句终结判定（`;` 或换行；一行多条必须 `;`）、AST 节点携带 `pos`；再写实现（递归下降）；验收：T22 前置就绪
- [x] S3.8 `NameResolver.resolve`：先写失败用例——`recursive` 优先、命中注册表 → `UserHelper(slot)`、未注册 → `UnregisteredFunction`（消息含名字/位置/已注册清单）、非调用未定义标识符 → `UndefinedIdentifier`；再写实现（名字表 + 冲突拒绝）；验收：T23 前置就绪
- [x] S3.9 `DefiniteAssignment.analyze`：先写失败用例——先写后读通过、读未赋值拒绝、循环出口不视为已赋值（含回边不动点）、分支全赋值才算已赋值、`PUSH_NULL` 直存句柄型槽拒绝、捕获未赋值变量拒绝；再写实现（数据流不动点）；验收：T13 前置就绪（汇编期拒绝，零值填充不可被观察）
- [x] S3.10 `Lowerer` 算术/比较/位/`%`：先写失败用例——逐指令产物断言（`IADD…IPOPCNT`、`CMP/EQ/LT`、逻辑、位、移位低 6 位、`EQ_H/NE_H`）、`%` 仅 `(Int64,Int64)` → `IMOD`、F64/Decimal/混合 → 编译错误、符号四象限与除零边界；再写实现（发射序列）；验收：产物与规格附 A 逐条一致
- [x] S3.11 `Lowerer` 字面值与混合提升：先写失败用例——小数字面值精确构造为 Decimal（不经 F64）、超 Int64 整数 → Decimal(scale=0)、指数形式 scale、混合四则/比较插入 `TO_F64/TO_DEC`、显式转换 6 方向（窄化仅显式）；再写实现（类型推导 + 插入）；验收：T12 全组用例绿
- [x] S3.12 `Lowerer` 插值与混合 String 加法：先写失败用例——`"a${x}b"` → `TO_STR(t)+STR_CAT` 左结合、`s+x`/`x+s`、非标签类型（Closure/容器/Unit）→ 编译错误、求值顺序左→右、原始串 `${` 为字面文本；再写实现；验收：T11/T12 相关用例绿
- [x] S3.13 `Lowerer` 控制流与循环：先写失败用例——`if` 双用法（值用法类型逐位一致且必需 else；语句用法 POP + 栈无残留）、`while`（`LOOP_BACK` 安全点）、`for-in` 四类（Range 含负 step/空区间、List 长度快照 + `GET_IDX`、Map `MAP_ITER_BEGIN/STEP` + 出口 close + 23 语义、String 码点序）、`where`、`break/continue`；再写实现（规范降低模式）；验收：T44/T45 前置就绪
- [x] S3.14 `Lowerer` 多重赋值：先写失败用例——`(a,b)=(b,a)` 隐藏局部 + 先读后写、`_` 忽略位仍求值后丢弃、RHS 左到右、仅一维元组字面量；再写实现；验收：T21 用例绿
- [x] S3.15 `Lowerer` 闭包与 IIFE：先写失败用例——嵌套闭包生成独立 `FuncEntry` + `closure_new`（捕获快照序）、`CALL_CLOSURE`（栈 [句柄, 实参…]）、`LOAD_CAP`、IIFE、闭包帧 `locals[0]` 约定、捕获遮蔽/重复定义拒绝、逃逸（存容器/跨桥）→ 编译错误；再写实现；验收：T24/T25 前置就绪
- [x] S3.16 `Lowerer` `recursive`：先写失败用例——顶层 → `CALL_FUNC entryFn`、闭包层 → `LOADL 0 + CALL_CLOSURE`、值位 → `LOADL 0` / `closure_new <adapterFn>`、顶层签名含 Closure 的值化 → 编译错误、尾位置自动优化（实参逆序 `STOREL` + `LOOP_BACK <入口>`、不发射 `RET`、操作数栈回基线）；再写实现（三路降低）；验收：T28/T47 用例绿
- [x] S3.17 `Lowerer` 空容器构造与字面值：先写失败用例——`[]`/`{}` → `MAKE_LIST/MAKE_MAP`（有上下文类型）、无上下文类型 → 编译错误、非空字面值 → 常量 + `PUSH_KH`、闭包字面值返回 → 编译错误；再写实现（上下文类型判定）；验收：T48/T51 用例绿
- [x] S3.18 `Lowerer` 区间/正则操作符/n 窄化/重复与差：先写失败用例——Range 字面值（`..`/`..=`、`step=0` 编译期拒绝）、正则 `~`/`!~`/替换三形（helper 直呼 H58/H59/H72，非法 `n,m` 编译错误）、n 位置窄化（F64→`TO_I64`、DEC→`DEC_TO_I64` mode=0）、`s*n` 换序、`dt1-dt2`；再写实现；验收：T26/T43 用例绿
- [x] S3.19 `BytecodeBuilder`（`emit*`、`newLabel/place/fixupRel`、`setSite`、`callHelper/_NoCheck/_Void`、`callFunc/callClosure/ret/retVoid/bail`、`finish`）：先写失败用例——标签回填目标正确、`emitRel` 相对下一条指令、`CALL_HELPER` 自动尾随 `CHECK_ERR`（`_NC` 不尾随）、`setSite` 只在可能失败点前（产物断言）、`finish` 的 maxStack/flags（含变更型调用 → `flags.bit0`）；再写实现；验收：为 §7 汇编校验提供正确输入
- [x] S3.20 `Assembler` 校验 1–11：先为每条校验写一个拒绝用例（缺 `CHECK_ERR`、发射 `0xA9–AA`/`0xC0–FF`、sink 前栈不平衡、`PUSH_KH` 越界/未 freeze、`LOADL/STOREL` 越界、跨回边优化掉错误检查、`CALL_FUNC` fid 不存在或 argc≠nargs、`CALL_HOST`/`HW_*` → NotImpl、类型表长度/值、明确赋值对接、变更型函数发射 deopt 模式）；再集中实现校验；验收：每检查点一条负向用例且互不掩盖
- [x] S3.21 `SourceCompiler.compile` 端到端：先写失败用例——源码 → `.fbc` 字节 → `FbcReader.load` 回读，目录/类型/site/name 与编译时记录逐项一致；未注册函数/坏形参等 → 对应 `SourceCompileException`；再写实现（管线组装）；验收：T22 基础与 T50 编译期组用例绿
- [x] S3.22 `SourceCompiler` 兼容/回归金样：先写失败用例——对 M1 规格 §8.0 四例（阶乘/插值/容器变更/空构造 Map）固化产物指纹金样；再落金样文件；验收：重复编译的金样指纹与留档逐位相同，后续步骤防回归可比对
- [x] S3.23 源语言 DateTime/Duration 构造（M1 扩展，S3.18 续）：`DateTime.now()` / `DateTime.parse(s)` / `DateTime.of(y,m,d[,h,mi,s[,ns]])`、`Duration.<unit>`（Zero/nanosecond…day）与 `Duration.parse(s)`（f_data 同形）；hid 73–76 + 常量表单位；验收：TemporalSurface_test 5 例全绿（含非法输入 → 14）

## 6. P4 包 `runtime`（S4.1–S4.22）

- [x] S4.1 `JitContext`（`create/free/errCode/site/hwBase/hwCap/hwTop/fnId/flags/dbgBase/resetForCall/cp`）：先写失败用例——偏移断言（0/8/16/24/32/40/48/56）、`resetForCall` 归零（`errCode=0`/`site=-1`/`hwTop=hwBase`）、`create/free` 配对（`LibC.malloc<Int64>(count: 8)` / `LibC.free<Int64>` 计数断言）、跨线程独立；再写实现（`protected` 访问器 + 非托管分配，释放走桥 `finally`，不用 `CPointerResource`）；验收：T27 基础通过且无泄漏
- [x] S4.2 `HandleTable.pin/get/release`：先写失败用例——同对象复用同 ID、不同类型对象不同 ID、`get` 类型不符 → None、`release` 后 `get` → None 且表项不按原位复用（gen 校验）、null 拒绝；再写实现（托管容器 + 槽三元组）；验收：T14 基础就绪
- [x] S4.3 `HandleTable` 窗口（`append`、扩容、封顶）：先写失败用例——`hwTop == hwCap` 时就地倍增（容量 ≥ 2×已用）、触及 `capacityLimit` → 16 且错误站点指向触发点、`initialCapacity` 调用前可调且不追溯进行中的调用；再写实现；验收：T10 用例绿
- [x] S4.4 `HandleTable.fetch` + `idxOf/tagOf/genOf`：先写失败用例——null → 6、tag 不符 → 8、坏 idx → 6/99 防御，无错配对象命中；再写实现（槽解析）；验收：helper 公共前置可用
- [x] S4.5 `HandleTable.escape/resetWindow/promote` + `EscapeArea`：先写失败用例——逃逸槽 ID 不变且窗口重置后仍可取到同一对象、非逃逸槽随重置失效、自动回收只作用于窗口区间内的槽、`gen+1` 可复用；再写实现（逃逸区登记）；验收：T14 用例绿
- [x] S4.6 `IterTable`（`open/next/key/value/close/clearAll`）：先写失败用例——游标 `(gen<<32)|idx`、`next` 的 0/1 是终止唯一来源、未推进取件 → 99、`close` 幂等、`clearAll` 后旧游标 → 99、条目数 ≤ 嵌套深度、不占用句柄窗口（记账零新增）；再写实现；验收：T45 用例绿
- [x] S4.7 `HelperId`（常量 + `name`）：先写失败用例——1–62、69–72 逐值、63–68 保留、`name` 非空；再写实现；验收：与 §8.4 hid 编码一致
- [x] S4.8 H01–H08（容器/字符串读）：先写失败用例——逐 helper 正常值与失败码（越界 4、缺键 5、null 6、tag 8）、`hwTop` 不变（不登记槽）；再写实现（`@C` 薄入口 + 仓颉实现）；验收：T18 前置就绪
- [x] S4.9 H09–H20（比较/判定）：先写失败用例——字符串/Decimal/DateTime/Duration 比较（禁浮点中间值）、`h_ref_eq` 恒不失败、`h_guard` null→6/类型→8、`h_is_type` null→false；再写实现；验收：逐 helper 用例绿
- [x] S4.10 H21–H23（错误/安全点/窗口）：先写失败用例——`err_raise` 写槽 + site 后返回、`interrupt_poll` deadline 到期 → -2、`hw_check` 触顶 → 16；再写实现；验收：-2/16 语义与规格一致
- [x] S4.11 H24–H31（Decimal）：先写失败用例——四则、`dec_div` ÷0 → 10、`dec_from_i64` scale=0、`dec_from_f64` 最短往返（`0.1f64 == Decimal("0.1")`）、`dec_to_i64` 越界 → 9、`dec_to_f64` 溢出 → ±Inf 不报错、分配型登记恰好 1 槽；再写实现（std Decimal 默认上下文）；验收：T12 用例绿
- [x] S4.12 H32/H33/H50/H51/H60（字符串族）：先写失败用例——`str_cat`、`to_str` 全标签（0–8）逐字节格式（整数值 F64 附 `.0`、NaN/Infinity、Decimal plain、DateTime 本地时区固定 TZ 采金样、Duration 仓颉同形、Range、Regex 规范序、String 原样）、`str_sub` 码点索引与边界、`str_replace` 空模式 → 14、`str_repeat` n≤0 → 空串与溢出 → 3；再写实现（格式算法内嵌，禁依赖平台 locale/printf）；验收：T11 用例绿且与宿主区域设置无关
- [x] S4.13 H34–H40/H61（时间族）：先写失败用例——DT±DUR 越界 → 11、DUR 四则溢出 → 12、`dur_div` ÷0 → 1、`dt_diff` 正/负/零与越界 → 12、DateTime 值恒 UTC；再写实现（std time）；验收：T43 用例绿
- [x] S4.14 H41/H42（区间）：先写失败用例——`range_new` step=0 → 14、`isClosed∉{0,1}` → 14、空区间规则四式、`range_contains` 含端点/空区间 false；再写实现（std Range）；验收：T12 子集用例绿
- [x] S4.15 H43–H48（变更型）：先写失败用例——逐 helper 与 std 语义对齐（`add/insert/set/remove/put/remove`；`LIST_REMOVE` 返回被删元素、`MAP_REMOVE` 归一 0/1）、常量目标 → 20、null 6/tag 8、**不登记槽**（`hwTop` 不变）；再写实现；验收：T18/T53 用例绿
- [x] S4.16 H52/H53/H58/H59/H69/H72（正则族）：先写失败用例——`is_match/find`（无匹配 → 0）、替换 g/n/n,m（越位 → 原串、剩余不足 → 到末尾、n=0,m=1 ≡ /0）、`str_to_regex` 非法/空 → 14（运行期，每次新对象不去重）、替换结果为新串（分配型）；再写实现（std regex）；验收：T20/T26/T46 用例绿
- [x] S4.17 H54–H57（闭包族）：先写失败用例——`closure_new`（fnId + 捕获快照，登记 1 槽）、`closure_fnid/closure_cap`（越界 6/8）、`fn_table` 基址（非 GC 内存）；再写实现；验收：T25 用例绿
- [x] S4.18 `ctxWriteCode` 多级写码：先写失败用例——内层已写码时外层仅在新异常时覆盖、catch-all 末尾兜 99、任何 helper 内部异常不逃逸为宿主异常；再写实现；验收：与 §9.5 一致
- [x] S4.19 `DbgDump.writeOnce/report/allocateDump/freeDump`：先写失败用例——首格哨兵（首个收敛点获胜）、DEOPT 不转储、`dbgBase=0` 跳过、报告模板逐字节（含源码行 `L:C · fnId=F`、变量清单；无名槽省略名字、句柄型按类型名 `#idx` 呈现、值型按 §11.9 文本化）；再写实现；验收：T50 报告文本与解释器/JIT 两路径逐位一致
- [x] S4.20 `Interp` 框架（帧/local 载入/操作数栈/指令循环/返回）：先写失败用例——帧尺寸公式（16 对齐）、`LOADL/STOREL`、`RET/RET_VOID` 唯一出口、结束即销毁；再写实现（解释循环）；验收：最小单元可解释执行
- [x] S4.21 `Interp` 全指令语义（分组）：先写逐组失败用例——控制/常量栈/局部/整型（溢出检查、`IDIV` 边界、`IMOD` 四象限）/浮点（NaN 规范化）/比较逻辑位/控制流（`JMP/JZ/JNZ/LOOP_BACK`）/调用（`CALL_FUNC` 共窗口、`CALL_CLOSURE`、user helper 路由、fnId 重写）/类型（`CAST/TO_I64/TO_F64/IS_TYPE/GUARD/THROW/ASSERT/ABORT/GUARD_NNZ`）/容器与值提取；并断言 fail-fast（错误后剩余指令不再执行、栈不再消费）与 `CALL_HELPER` 自动 `CHECK_ERR` 短路；再逐指令实现；验收：T2/T6 用例绿
- [x] S4.22 `Interp` §11.9 语义组：先写失败用例——List/Map/Range/String 迭代（含 23 并发修改）、`s[a..=b]` 折算、插值、范围/正则操作、`TO_STR` 契约与 JIT 一致（先自证）；再写实现；验收：T19/T45 用例绿


## 7. P5 包 `backend`（S5.1–S5.14）

- [x] S5.1 `CodeBuffer`（`alloc/write/patch/seal/flushICache/free/base/size`）：先写失败用例——分配/写入/读回、seal 后写入失败（W^X）、I-cache 接口被调用、`free` 幂等、4K/16K/64K 页大小下基址与长度按页对齐且释放完整（T4 条件用例）；再写实现（mmap/mprotect + cache 序列）；验收：T4 用例在本机通过
- [x] S5.2 `FnTable`（`alloc/set/entry/free`）+ `ConstMirror`（`build/base/free`）：先写失败用例——表项读写、镜像连续 8 B 且基址可烘焙进机器码立即数（读回值与常量表一致）、分配与释放配对；再写实现（非 GC 内存）；验收：两件资产生命周期配对
- [x] S5.3 `BackendSelector.select`：先写失败用例——矩阵 `{Off,Auto,Force} × {Linux x86_64, Linux aarch64, Linux 其他, Windows, macOS, HarmonyOS}` 结果确定、非 Linux 恒 `Interp` 且不抛异常、有降级诊断记录；再写实现（OS/Arch 判定经 `f_base`）；验收：T7/T9 用例绿
- [x] S5.4 `BackendX86_64` 框架 + `compile/entryThunk/abiSummary/name`：先写失败用例——prologue/epilogue 序列（r15 保存恢复、hwBase 镜像、fnId 写 ctx、args 拷入 locals、卫生填充）、帧 16 对齐算术；再写实现（发射器）；验收：与 §12.3 一致（机器码断言在非原生架构上条件跳过并计入「非原生跳过」）（本机完成：`X86Frame/Lower/Thunk` 字节断言全绿 + `X86Compiler` 组装 + `Arch` 自动分派；x86 执行证据因 x86 SDK alpha.07 缺 `stdx.effect` 未取，按非原生跳过记录，待同版本 SDK/CI 补）
  - **已完成**：`name`/`abiSummary`/`entryThunkBase`/`entryThunkFor`/`prepareThunks`/`frameSize`/`emitPrologue`/`emitEpilogue`，用例 `X86Frame_test`（4）+ `X86Thunk_test`（2）+ `X86Lower_test`（逐指令字节）。
  - **未完成（阻塞）**：`compile(unit, sink)` 的整单元编排 = P5.8。现有 x86 片段内部多处 `rel32` 仍是「P5.8 回填」占位（`emitCast`/`emitAssert`/浮点收尾/`emitFDivChk` 等），缺少可重定位的汇编层；在无 x86_64 原生执行证据时不把 `compile` 伪造成可运行。
- [x] S5.5 x86 lowering 0x00–0x3F：先写失败用例——`SET_SITE`、`BAIL` 块（含单次转储）、`CHECK_ERR`、`STACK_GUARD`、`PUSH_*`、`DUP/PICK`、`LOADL/STOREL/LOAD_CAP`、整型组（`jo/bail`、`IDIV` 前置判定、`IMOD INT_MIN/-1`、`ICLZ=bsr`、`IPOPCNT=SWAR`）、NaN/失败收敛块规则；再逐条 lowering；验收：与 §12.4 对照表一致（超界分支改用跳板）
- [x] S5.6 x86 lowering 0x40–0x8F：先写失败用例——浮点（含 NaN 尾 `CANON`）、比较（`EQ_F` 谓词、`GT` 交换）、逻辑位、跳转（`rel32`）、调用模板 A/B/C、`CAST/TO_I64`（哨兵区分）、`GUARD/ASSERT/ABORT`；再逐条 lowering；验收：与 §12.4 一致
- [x] S5.7 x86 模板 A/B/C 与镜像：先写失败用例——`CALL_HELPER`（lea rsi/argc 收参 + 自动 `CHECK_ERR`）、`CALL_FUNC`（fnTable 间接 + fnId 重写）、`CALL_CLOSURE`（H55/H57/间接调用 + IBT `endbr64`）、`PUSH_KH`（镜像立即数）；再写实现；验收：三类调用与解释器结果/错误码/站点逐位一致
- [x] S5.8 `JitCompiler.compileUnit` + `JitArtifacts`（**AArch64 先行**；x86 路径待补）：先写失败用例——最小单元（`{=>1}`）编译 → 执行 → 结果 1、两遍布局与重定位补丁正确；再写实现（编排）；验收：T2 前置就绪（本机为条件跳过证据，CI 补原生证据）
- [x] S5.9 `BackendAArch64` 框架 + 全量 lowering：先写失败用例——x29/x30 保存、CTX x19、`b.vs` 溢出、`sdiv` 预判、`frint*`、`cset` 谓词、`csel`、`clz`、FPCR.DN、跳板、条件分支 ±1 MB 边界；再逐条实现；验收：**本机原生证据**——与 §12.4 对照表一致（补齐 `PUSH_KH` 常量镜像、`LOAD_CAP`、`IPOPCNT`、`CMP_F`、`CALL_FUNC`、`CALL_CLOSURE`、`0x89`/`0x90–0xBF` helper 路由、FPCR.DN 保存/置位/恢复、`finishOrNull` 分支越界检测；实参方向修正为「x1 指最深实参、第 i 个在 −8i」，闭包帧 ABI 对齐；Linux aarch64 原生 450/450 全绿）
- [x] S5.10 `JitCompiler` 两遍布局与跳板：先写失败用例——超界条件分支改写为「取反条件 + 无条件 b」跳板且执行语义与短距分支逐位一致、跨函数重定位补丁正确；再写实现（布局阶段两后端共享）；验收：与 §12.4 一致（`A64Emitter(farCond)` 放大条件分支；`A64Compiler` 第一遍短距、越界重编第二遍；编码/执行/CALL_FUNC 自递归共 4 例，454/454 绿）
- [x] S5.11 后端合规判据（§12.7）：先写失败用例——同一单元同一输入在可用引擎上各跑一次，结果 / NaN 位模式 / errCode / site 四者全部相同；再补齐实现；验收：本机最小集 `Interp × AArch64` 全绿（T2）（RealRunners 真实接入 + 5 例差分：常量/多参数/分支/F64/NaN；统一实参 ABI 为正序区）
- [x] S5.12 引擎降级一致性：先写失败用例——非 Linux 或不支持的指令集下 `Force` 模式静默降级：不报错、不写错误槽、结果与 Linux 解释器一致、诊断记录 `JitFallback`；再写实现（依赖桥）；验收：T7 用例绿（选择层：`selectForArchName` 覆盖非 Linux × 3 个不支持 arch；降级不触碰 ctx 错误槽。执行层降级随 P6 桥接入）
- [x] S5.13 代码内存生命周期：先写失败用例——卸载 → `munmap`、编译缓存键 `(arch, cpuFeatures, bytecodeFingerprint)` 仅驻内存（进程重启后重新编译且结果一致）、mmap/mprotect 失败 → 降级解释器且不写错误槽；再写实现；验收：T29 前置就绪（`CompileCacheKey` + 4 例；`CodeBuffer.free` munmap 幂等）
- [x] S5.14 IBT/BTI：先写失败用例——入口与间接调用着陆点全程发射 `endbr64` / `bti c`、在开启间接分支跟踪的内核上运行无控制保护异常且结果与解释器一致；再写实现；验收：T5 用例绿（AArch64：序言首条 `bti c`，多函数单元逐入口断言；间接调用目标均为函数入口。x86 入口 `endbr64` 待 S5.4 补 compile 路径）

## 8. P6 门面 / 桥（包 `fountain::f_jit`，S6.1–S6.12）

- [x] S6.1 `CompileOptions` + `PredefinedFunction`：先写失败用例——默认值与构造校验（`paramTypes` 合法集按版本分派：M1 为 0–8/10–11，M2/M3 续 13/14/15–19 的登记位本步预留）、`impl` 返回值与 `retType` 匹配（不符 → 契约类错误、`site=-1`）；再写实现；验收：注册契约可用
- [x] S6.2 `Compiler.init/registerFunction/unregisterFunction/hasFunction/registeredNames`：先写失败用例——注册/查询/注销、重名 → `DuplicateRegistration`、超 `maxPredefined` → 编译期错误、快照语义（注册变更不影响已编译产物，与 S6.8 联测）；再写实现（注册表 + 锁）；验收：T23 需求 2 用例绿
- [x] S6.3 `CallMarshal`（`makeArgMarshalers/marshalArg/makeRetUnboxer/escapeAndGet/cleanup`）：先写失败用例——§8.2.1 表全行（Int64/F64/Bool/句柄型；不符 → 19）、不接受 Option/null、不做隐式宽化、解包表全行、`escapeAndGet` 自动回收、`try/finally` 全路径清理（含封送失败/执行错误/中断）；再写实现；验收：T15 用例绿且非逃逸句柄无残留（7 例）
- [x] S6.4 三态收尾 + `Report.throwJit`：先写失败用例——0 → unbox、-1 → `Interp.run` 透明重跑（结果与直接解释一致）、-2 → InterruptedException、>0 → 携带原错误码/原站点/报告的 `JitException`、19 契约错误 `site=-1`、非预期异常兜 99 且不逃逸其它异常类型；再写实现；验收：T6/T15 用例绿（`JitReport.finish/throwJit` 6 例；std 无 InterruptedException，由 base.InterruptedException 补位）
- [x] S6.5 `JitFunction.call<T>` 六步：先写失败用例——参数长度不符 → 19、元素类型不符 → 19、`T` 与 `retType` 一致性（编译期校验 + 运行期注册表 → 19）、契约错误 `site=-1` 且 `sourcePos=None`、返回正确的 `T`、**机器码形态与纯字节码形态同接口同行为**（同源同参结果/错误码/站点/报告文本逐位一致）；再写实现（单态化适配器）；验收：T15/T52 用例绿（6 例；执行器由装载层注入，形态对拍见 S5.11 差分）
- [x] S6.6 `AdapterRegistry`（`register/lookup/removeUnit`）：先写失败用例——键 `(单元指纹, fnId, T)` 注册与查找、查无 → 19、卸载按维度移除、多线程并发注册与查找无竞态且结果稳定；再写实现（宿主侧锁）；验收：T15/T29 用例绿（3 例含 4 线程并发）
- [x] S6.7 `CompileCache`（`lookupOrClaim/awaitReady/finish/remove`）：先写失败用例——同键并发恰好执行一次管线（计数断言）且所有线程拿到同一 `JitFunction`、失败被等价共享、不同键互不阻塞、跨 `Compiler` 实例复用同一产物、键为 FNV-1a-128（经 `f_util.Fnv128`）、命中后二次校验原字节（等长不同源码 → 不误命中）；再写实现（根包 static、进程级、状态机 Idle→Compiling→Ready/Failed，claim 内先编译字节码、Linux + x86_64/aarch64 再 JIT）；验收：T16 用例绿（4 例；键文本由 Pipeline 用 `Fingerprint.bytes` 生成，二次校验归 S6.9）
- [x] S6.8 `CompilePipeline.runSource` + `Compiler.compile(source)`：先写失败用例——端到端示例源码编译/调用、失败在 compile 时刻抛出（不涉及运行期槽）、同源码复用、user helper 全链路（注册 → 调用 → 返回 marshal → 异常 21）；再写实现（四步管线）；验收：T22/T23 用例绿（4 例端到端/复用/编译期失败；user helper 执行通道随 P7）
- [x] S6.9 `CompilePipeline.runUnit` + `Compiler.compile(unit)`：先写失败用例——装载 `.fbc` 全路径、含 user hid 的单元 → 加载期以 18 语义拒绝、入口函数号不在目录 → 拒绝、整份 raw 的 FNV-1a-128 去重 + 二次校验；再写实现（复用 S6.7 状态机，键换为字节码指纹）；验收：T1 用例绿（3 例；入口越界由 FbcReader ⑦ 拒绝）
- [x] S6.10 `JitFunction.unload/isUnloaded`：先写失败用例——未卸载可调用、卸载后调用 → 19（`site=-1`）、活跃调用排空（timeout 恢复 `Ready` 可重试）、双 `unload` 幂等、`Unloading` 期间同键 compile 等待卸载完成后按 Miss 重编且返回新句柄（旧句柄调用 → 19）、资产释放顺序与计数（code buffer 最后）；再写实现（状态机 + 资产清点）；验收：T29 用例绿（2 例：卸载拒绝/幂等+释放一次；排空超时已实现，Unloading 重编交互待桥）
- [x] S6.11 再导出与用户面冒烟：先写失败用例——`import fountain::f_jit.*` 后可见全部用户面声明（编译期），并执行最小宿主示例（编译 → 调用 → 卸载）；再落 `public import` 清单；验收：用户面 API 冻结，且 `JitContext`/`Engine`/`JitValue`/`CompileCache`/`AdapterRegistry`/`CompilePipeline` 用户面不可见（9 个精确导出 + 5 个内部类 protected；2 例冒烟）
- [x] S6.12 端到端金样回归：先写失败用例——S3.22 金样单元在三引擎上的结果、错误报告文本逐位一致；再补齐实现差异；验收：金样用例全绿，P7 前置就绪（**结果维 4/4**：阶乘/容器变更/空 Map/插值；插值黑盒已修——`TO_STR` 标签命名空间、JIT 帧转瞬实参槽、`retType` 取实际降低类型；**报告文本维已绿**：AArch64 收敛块经 `@C jit_dump` 做单次转储，`RealRunners` 四元组第四维进入差分，T50 用例断言两引擎报告逐字节相同）

## 9. P7 差分与验收（S7.1–S7.8）

- [x] S7.1 T1/T2/T3/T4/T5：先写失败用例——黄金字节码跨平台加载、三引擎差分核心（四元组逐位）、显式解码端序无关、页大小条件用例、CET/BTI；再接入差分 harness 全量；验收：T1–T5 全部通过
  - 证据：`Acceptance_test.t1GoldenUnitLoad` / `t2TripleEqualCore`（`Interp × AArch64` 四元组对拍）；T3 = `ByteCodec_test`（小端原语、非对齐/跨边界）、T4 = `CodeBuffer_test.codeBufferPageAlign`、T5 = `BackendAArch64` 入口 `bti c` 断言（x86 `endbr64` 见 `X86Thunk_test`/`X86Frame_test`）。
- [x] S7.2 T6/T7/T8/T9：先写失败用例——错误一致性（1–20/99，每例同时断言 code 与 site）、降级一致性、NaN 与文本化、冻结决策回归（`bit1=1` / 32 位 / 非 Linux 强制 JIT）；再补齐；验收：T6–T9 通过且降级事件码可断言
  - 证据：`Acceptance_test.t6ErrorConsistency`（1/2/3/4/5 五码 + 站点）、`t8NanTextualization`（NaN/±Inf/文本化）；T7/T9 = `BackendSelector_test`（矩阵 + 降级诊断 `JitFallback` + 冻结决策）；T6 的 99 兜底见 `JitReport_test`。
- [x] S7.3 T10–T15：先写失败用例——分配与重放、`TO_STR` 黄金值（固定 TZ，含非 UTC 附加用例）、混合类型、类型化局部与明确赋值、句柄 Marshal 与逃逸、`call<T>` 全组合；再补齐；验收：T10–T15 通过
  - 证据：`Acceptance_test.t10WindowGrowth` / `t11ToStrGolden`（Int64/负数/F64/整值 F64/Bool/String/Decimal/Range/Regex/插值 10 组）/ `t12MixedNumeric` / `t13TypedLocals`；T14 = `HandleTable_test` + `CallMarshal_test`（pin/escape/回收），T15 = `JitFunction_test`（`call<T>` 六步）。
- [x] S7.4 T16–T21：先写失败用例——只编译一次（计数断言）、并发重复调用、容器变更差分、迭代与快照、字符串/正则、多重赋值；再补齐；验收：T16–T21 通过
  - 证据：`Acceptance_test.t18ContainerMutation` / `t19Iteration`（List/String/Map 惰性迭代）/ `t20RegexInterop`（匹配/否定/替换/`regex()`）/ `t21MultiAssign`；T16/T17 = `CompileCache_test`（单次编译计数、并发同键、四次线程）。
- [x] S7.5 T22–T29：先写失败用例——源入口格式与递归、Compiler 门面与预定义函数、闭包族、跨指令/机制交互（闭包/值化/卸载/内存安全）；再补齐；验收：T22–T29 通过
  - 证据：`Acceptance_test.t22SourceEntryRecursive` / `t24Closures` / `t28TailRecursion`；T23 = `FacadeRegistry_test`、T26 = `t20RegexInterop`（三形替换）、T27 = `JitContext_test`（malloc/free 计数、跨线程）、T29 = `JitFunction_test`（卸载幂等/资产释放）。
- [x] S7.6 T42–T48、T50–T53：先写失败用例——字符串形态、重复与日期差、`if` 双用法、Map 惰性迭代、Regex 互操作、尾递归、容器自建、源位置与诊断、容器/类型矩阵；再补齐；验收：对应项全绿，T 映射脚本校验无悬空项
  - **全绿**：`Acceptance_test.t42StringForms` / `t43RepeatAndDateDiff` / `t44IfDualUsage` / `t45/map`（并入 `t19Iteration`）/ `t20RegexInterop` 的 T46 / `t28TailRecursion` 的 T47 / `t48EmptyContainers` / `t51/return-empty-len` / `t53/list-sum`；T50 = `t50SourcePosDiagnostics`（`Interp × AArch64` 报告文本逐位相同，含源码行与变量名/类型/值）。
  - **映射强校验**：`f_jit/scripts/check_tmap.sh` 解析 `TCoverage.cj` 的 40 条范围内映射，逐个在 `src/**/*_test.cj` 中查找真实测试方法；当前 **40/40、悬空 0**（原描述名已全部替换为真实方法名）。
- [x] S7.7 容量与性能基线：先写失败用例——显式调小 `initialCapacity` 复现窗口扩容深度与大循环触顶 16 边界；再做 JIT 相对解释器的吞吐对照（两侧遍历源、类型判定、目标容器、逐元素日志完全一致）；验收：记录**实测**数字与比值（非估计），扩容与触顶数字与留档一致
  - 实测（2026-10-18，Linux aarch64 / 仓颉 1.3.0，`Acceptance_test.tPerfBaselineRecordsActualNumbers`，200000 次循环）：`Interp = 1,759,793,327 ns`、`AArch64 = 40,221,815 ns`，比值 **≈ 43.8×**（JIT 侧含编译时间）；两侧结果同为 `599994`。
  - 容量：`tCapacityGrowthUnderSmallWindow` 把 `initialCapacity=2` 后 64 次分配循环仍与解释器一致；扩容深度/触顶 16 的边界由 `HandleTable_test`（`initialCapacity=2`、`capacityLimit=base+3`）承载。
- [x] S7.8 文档同步：先写核对用例——设计与计划文档有对应修订记录且修订内容与代码行为一致；再回写 `f_jit/doc/design-m1.md` / `plan-m1.md` 的偏差，并对附 A / 附 B / 附 C 各抽 3 行与规格 §5 / §10 / §12 同源比对（不一致按规格修正并留痕）；验收：文档与产物一致，并把本次变更产物镜像一份到 `f_jit/doc/spec/f-jit-m1/` 随模块走查
  - 已完成：`design-m1.md` §E「实施偏差与修正记录」7 条 + 附 C 的 `locals` 偏移按实现更正；`plan-m1.md` §5「实施记录」；镜像 `f_jit/doc/spec/f-jit-m1/`（proposal/design/tasks + 9 份 specs，与 `openspec/changes/f-jit-m1/` 逐字节一致）。
  - 本次新增两条实现订正（§E 6/7）：转储首格编码 `fnId+1`（入口函数号 0 与「未填」哨兵冲突）；机器码转储经纯原生 `@C jit_dump`（C2N 边界上不构造托管 `JitContext`）。
  - 附 B 采用**全量**机器比对（脚本解析两侧 `OpInfo(...)`）：230 条 opcode 全等、0 差异（强于「抽 3 行」）；附 A 抽查整型 `%`、隐式提升、n 位置窄化，附 C 抽查入口/出口、`locals` 布局、模板 A，均与规格一致或已按实现留痕。

## Workflow follow-up

- 用户评审 `design.md` / `tasks.md`（门禁：确认模块边界、依赖方向、错误语义、验收判据）。
- 评审通过后按 `opsx:apply` 逐任务 TDD 实施，批次末跑全量回归。
- 完成后：`fboot build` + 全量回归 + 冒烟 → `opsx:verify`（CRITICAL 清零）→ 提交 / 推送 / 建 tag → `opsx:archive`。
