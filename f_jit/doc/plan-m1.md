# f_jit TDD 开发计划 · M1

> 依据：`design-m1.md`（本目录）与 `jit-bytecode-m1.md` v0.18.35。
> 粒度：**每个公共成员一份 TDD 单元**（步骤内逐成员列出）；步骤按依赖顺序排列，每步可独立提交。
> 配套：M2/M3 增量另见 `plan-m2.md`、`plan-m3.md`。

---

## §0 计划总则

### 0.1 TDD 循环（每步一次）

1. **红**：为本步的每个目标成员写出**会失败**的用例（编译期成员可先用「能通过的最小用例」钉住行为，再补失败用例）；
2. **绿**：写最小实现使用例通过；
3. **重构**：消除重复（helper 转换器、编码原语、检查块统一），保持全绿；
4. 一步一提交（提交信息注明步骤号与目标成员）。

### 0.2 测试落点原则（语义所属层）

| 用例语义 | 落点 | 例 |
|---|---|---|
| 格式/校验（`.fbc` 合法性、常量序列化） | `bytecode` 层 | DAG 环、site 覆盖、name 坏键 |
| 编译期诊断（名字解析、明确赋值、词法） | `compiler` 层 | `SourceCompileException` 各 kind |
| 指令语义 / 错误码 / 迭代快照 / 文本化格式 | `runtime` 层 | `IMOD` 四象限、TO_STR 全表、23 转码 |
| 降低（指令序列与栈平衡） | `compiler` 层（产物断言）+ 差分层 | `if` 值/语句用法、尾递归回边 |
| 「同一字节码三引擎逐位一致」 | **差分测试层**（单独目录） | I7 全量（T2/T6/T50） |
| 桥契约（Marshal/T 校验/卸载/去重） | 根包层 | 19 全路径、T16/T29 |

### 0.3 证据与验收口径（硬约束）

- 每条完成判据必须**实测**：单测数字 / 差分逐位 / 端到端日志；不接受「应该好了」。
- **I7 对照主证据必须落在单次运行内**：三引擎跑同一份用例、同一输入，一次运行内逐位对拍（errCode/site/结果/报告文本）；跨运行比值只作旁证。
- 性能类条目：A/B 两侧**同结构、同副作用**（遍历源、类型判定、目标容器、逐元素日志一致）。
- 每个失败点用例必须断言 `JitException.code` **与** `site` 两个字段（§9 附则 8）。

### 0.4 模块骨架与构建（P0 产物）

```
f_jit/
  cjpm.toml                # name=f_jit / organization=fountain / output-type=dynamic / version 跟随仓库
  src/
    Root.cj                # package fountain::f_jit（门面/桥；public import 再导出）
    base/                  # package fountain::f_jit.base
    bytecode/              # package fountain::f_jit.bytecode
    compiler/              # package fountain::f_jit.compiler
    runtime/               # package fountain::f_jit.runtime
    backend/               # package fountain::f_jit.backend
    test/diff/             # 差分测试层（三引擎对照，禁止放单层语义断言）
  doc/                     # 本目录（规格 + 设计 + 计划）
```

- 依赖声明（`cjpm.toml [dependencies]`）：`fountain::f_base`（OS/Arch + `BaseException` 基类）、`fountain::f_regex`（`String.regex()` 扩展）、`fountain::f_util`（crc32：`Crc32.isoHdlc`）；M3 追加 `fountain::f_data`（JSON）。
- 构建/测试：`cjpm build` / `cjpm test`；差分测试用独立入口脚本（同进程内跑三引擎，见 S0.2）。

### 0.5 步骤表头约定

每步给出五列：**步骤 | 目标成员（逐成员） | 先写测试（红） | 实现要点（绿） | 验收（回归）**。步骤号稳定，便于引用与勾兑。

---

## §1 阶段总览

| 阶段 | 内容 | 步骤数 | 依赖 |
|---|---|---|---|
| P0 | 骨架与测试基建（模块、差分 harness、基线） | 3 | — |
| P1 | `base` 契约（常量命名空间、公共值/异常类型） | 11 | P0 |
| P2 | `bytecode` 模型与 `.fbc` 编解码/加载 | 15 | P1 |
| P3 | `compiler` 前端（词法→语法→降低→汇编） | 22 | P2 |
| P4 | `runtime`（ctx/句柄表/迭代器/helper/转储/解释器） | 22 | P2 |
| P5 | `backend`（代码内存/两后端/编排/合规） | 14 | P2 |
| P6 | 门面/桥（Compiler/JitFunction/Marshal/缓存/卸载） | 12 | P3、P4、P5 |
| P7 | 差分与验收（T 系列映射、容量、文档同步） | 8 | 全部 |

---

## §2 步骤清单

> 注：表中未具名的内部辅助声明（`CtxFlags`/`FuncFlags`/`Backend`/`DiagKind`/`CompileSession`/`CompiledSourceUnit`/`FuncBody`/`InterpFrame`/`RuntimeError`）随其所属步骤一并实现与验收，不单列步骤。

### P0 骨架与测试基建

| 步骤 | 目标成员 | 先写测试（红） | 实现要点（绿） | 验收（回归） |
|---|---|---|---|---|
| S0.1 | 模块骨架：`cjpm.toml`、六个包目录、空包文件 | `cjpm build` 通过；`cjpm test` 0 用例通过 | 按 §0.4 建目录与 package 声明；`public import` 占位 | 构建基线（全绿）记录进仓库 CHANGELOG/计划勾选 |
| S0.2 | 差分测试 harness（`src/test/diff`）：同一单元跑 `Interp`/`BackendX86_64`/`BackendAArch64` 并逐位对比 | 用「常量 1+1」用例验证 harness 自身（先只挂 Interp；两后端以 mock 桩） | 统一输出三元组（结果/errCode/site+报告文本）；对拍函数 `assertTripleEqual` | harness 自测通过；后续每步自动接入 |
| S0.3 | T 编号映射表（§3）与用例命名规范 | 空跑：映射表每项指到某步骤某用例名 | 建立 `T# → 用例路径` 对照（可脚本校验） | 映射覆盖 M1 §13.2 全集（T1–T29、T42–T48、T50–T53；T30–T41/T49 属 M2/M3 序列） |

### P1 包 `base`

| 步骤 | 目标成员 | 先写测试（红） | 实现要点（绿） | 验收（回归） |
|---|---|---|---|---|
| S1.1 | `LocalType`：`I64/F64/BOOL/UNIT/STRING/DECIMAL/DATETIME/DURATION/RANGE/REGEX/LIST/MAP/CLOSURE`、`name`、`isHandle`、`fromToken` | 13 个常量逐值断言（0–12）；`isHandle(4..12)=true`、`isHandle(0..3)=false`；`fromToken` 与 §11.7 对应表全等 | 静态常量 + 查询函数；与 TypeToken 的映射表集中一处 | 与 §11.7 表逐项一致 |
| S1.2 | `TypeToken`：`RESERVED/LIST/MAP/STRING/DECIMAL/DATETIME/DURATION/RANGE/REGEX/CLOSURE`、`name` | 常量逐值断言（0–9）；name 非空 | 常量 + 描述表 | 与 §6 类型 token 表一致 |
| S1.3 | `ErrCode`：`OK/DEOPT/INTERRUPT`、`DIV_ZERO…READONLY`（1–20）、`CONCURRENT_MOD`(23)、`HELPER_PANIC`(99)、`describe`、`isHostSide` | 全码值断言；`describe(-2..99)` 非空且含语义关键词；未知码描述兜底 | 静态表（无宏，硬编码映射） | §2 表逐项一致 |
| S1.4 | `Version`：`MAJOR/MINOR/HDR_SIZE/MAGIC` | 常量断言（1/14/36/"FBC1"） | 常量 | 与 §11.6 一致 |
| S1.5 | `SourcePos`、`JitMode`、`Engine`、`JitValue` | 构造/字段读；`match` 穷尽性（四个 JitValue 构造器）；`==` 语义 | struct/enum（`Engine`/`JitValue` 声明为 `protected`） | 10 分钟内可写完（最小成员） |
| S1.6 | `CallContext` | 默认值断言（`literalCopy=false`、`strictFp=false`、`deadline=None`）；`strictFp=true` 经 `invoke` 写 ctx.flags（后置步骤联测） | struct + 默认值 | 默认值契约正确 |
| S1.7 | `SourceUnit` | 构造与字段读；entryFn 与容器头不一致的拒绝路径（在 S2.15 联测） | struct | — |
| S1.8 | `JitException`：`init(code,site,fnId,sourcePos,message,cause)`、`code/site/fnId/sourcePos/message/cause` | 字段保真；`sourcePos=None` 分支；`cause=None`；可 `catch (e: JitException)` 并读回全部字段；**`is fountain::f_base.BaseException` 断言**（统一基类，宿主可统一 catch） | class <: `f_base.BaseException`（`super(message)` 转发报告文本） | 全部字段可用 |
| S1.9 | `SourceCompileException`：`kind/position/line/column/lineText/hint` | 字段保真；`lineText` 等于对应源码行原文；**`is fountain::f_base.BaseException` 断言** | class <: `f_base.BaseException` | T50 编译期分组前置 |
| S1.10 | `DiagnosticsSink`/`DiagnosticLevel` | 桩实现记录调用（level+message）；`JitMode` 降级路径注入（在 S5.3 联测） | interface + enum | 桩可复用 |
| S1.11 | `base` 包整体可见性检查 | 用户代码 `import fountain::f_jit.base.*` 可用；`internal` 不外泄的编译期断言（负向用例不可编译——人工核对）；**`Engine`/`JitValue`（protected）用户面不可见**（同法核对） | 可见性标注 | 与 §1.2 规则一致；D3/D6 结案 |

### P2 包 `bytecode`

| 步骤 | 目标成员 | 先写测试（红） | 实现要点（绿） | 验收（回归） |
|---|---|---|---|---|
| S2.1 | `OpInfo`：5 字段 + `const init` + `static const CAT_*`（12 个）+ `static let OPCODE_TABLE`（256 项） | ① `OpInfo.OPCODE_TABLE.size == 256` 且 `table[i].code == i`；② 已分配项与 §10.3 逐条核对（名称/len/fmt/cat）：`SET_SITE=5`、`CALL_HELPER="u16 u8"=4`、`CALL_CLOSURE=u8=2`、`MAP_ITER_STEP=u8=2`…；③ 未分配 = `OP_RSVD/CAT_RSVD`；④ `0xA9/0xAA = CAT_FORBID`；⑤ `0xC0–0xFF` 全 RSVD | 按 §10.3 骨架逐项录入（可脚本生成后人工校对）；`CAT_*` 须为 `static const`（编译期常量） | 与 §10.3 全等（T1 基础） |
| S2.2 | `ByteReader`/`ByteWriter`：`u8/u16/u32/i32/i64/f64bits/bytes/remaining`、`wU8→`、`take` | LE 往返（含非对齐与跨缓冲区边界、`0x0102` 字节序断言）；越界读抛/返回错误；T3 显式解码用例 | 逐字节显式读写（禁 memcpy/指针强转） | T3 通过（主机端序无关） |
| S2.3 | `DecodedInsn`、`InsnDecoder.decode/u16/i32/i64/rel32` | 按 fmt 解码各类指令（`-`/`u8`/`u16`/`i32`/`rel32`/`i64`/`u16 u8`）；`rel32` 目标 = 下一条指令 + offset；RSVD/FORBID 解码 → 语义拒绝（`ERR_NOT_IMPL`） | 查表 + 游标推进 | 解码器是解释器取指唯一入口 |
| S2.4 | `FuncEntry`（10 字段 + `SIZE`） | 26 字节编解码往返、字段保真 | struct + SIZE 常量 | §11.7 恒 26 B |
| S2.5 | `FuncDir`：`add/get/find/size/validate` | 增查；重复 fnId 拒绝；`validate`：off/len 越界拒绝、`entryFn` 不命中拒绝 | 数组 + 索引 | 加载期校验前置 |
| S2.6 | `LocalTypes`：`init/get/set/size/validate/isHandleSlot` | 读写与越界；`validate`：长度≠nLocals 拒绝、13–255 拒绝；`isHandleSlot(4..12)=true` | 每槽 1 B | §11.7 校验 |
| S2.7 | `ConstKind`（class，常量命名空间：`static const` 线上 kind 码）、`ConstPayload`（enum：10 个构造器） | 各 kind 载荷构造/匹配；DAG 引用（PList/PMap 引用子索引） | `ConstKind` = 常量命名空间；`ConstPayload` = enum + `match` | 与 §11.5 载荷编码一一对应 |
| S2.8 | `ConstRegistry` 拼装 API：`addList/addMap/addStr/addValue/addRange/addRegex/freeze/size/get/isFrozen` | ① 各 add 返回递增 hid；② `addRegex` 去重（同 pattern+flags 同 hid）、flags 归一（`im`≡`mi`≡`ii`）；③ `freeze` 后写操作拒绝；④ `get(i)` 载荷保真 | 数组表 + 去重键表 | §3.3/§11.5 |
| S2.9 | `SiteEntry`、`SiteTable.add/freeze/lookup/validate` | `lookup`：取 `off ≤ site` 最大条目；无命中 → None；校验：严格升序、off<codeLen、line/column≥1；覆盖率=全部 SET_SITE（与 S3.19 联测） | 升序数组 + 二分 | §11.6/§9.16 |
| S2.10 | `NameEntry`、`NameTable.add/freeze/lookup/validate` | `lookup(fnId,slot)` 命中/未命中（→None=省略名字）；校验：fnId 命中目录、slot<nLocals、升序唯一、strLen≥1、strOff+strLen 在界、UTF-8 合法 | 段内相对偏移 | §11.6 |
| S2.11 | `FbcFlags`、`FbcHeader.read/write` | 新布局字段偏移断言（0/4/6/8/12/16/20/24/28/32/36）；旧布局（verMinor≤13）读入时无 nameLen、payload=36、hdrSize=32 | 结构体 + 分支 | 旧单元兼容（T9 前置） |
| S2.12 | `FbcWriter`：`setEntryFn/setCode/setConst/setSite/setName/setFlags/build` | build 产物：magic/verMajor/minor/lengths 正确；crc32 覆盖 code+const+site+name（改任一字节 crc32 变）；基准向量 `crc32(空)=0`、`crc32("123456789")=0xCBF43926` | 缓冲拼接 + `f_util.Crc32.isoHdlc`（CRC-32/ISO-HDLC） | §11.6 |
| S2.13 | `FbcReader.load`（正向） | 手工构造最小合法单元 → 全字段解出（header/code/consts/site/name/dir/types）；`entryFn` 命中目录 | 分派 + 各表解析 | T1 基础 |
| S2.14 | `FbcReader.load`（拒绝面，逐条） | ① magic 错；② verMajor 2/3 → 18 语义；③ 未知 flags 位/`bit1=1` → 拒绝；④ 段长不符；⑤ 常量 DAG 环；⑥ 坏载荷（非 canonical F64、非法 kind）；⑦ 目录越界；⑧ 类型表非法；⑨ site 未覆盖/乱序；⑩ name 坏键；⑪ crc32 不符 —— 每条独立用例断言拒绝与错误码 | 校验集中 `validate`；拒绝=抛 JitException(14/18)；crc32 用同一 `f_util.Crc32.isoHdlc` | 每拒绝面一条用例（T9/T13/T50 前置） |
| S2.15 | `ConstRegistry` 加载期实例化（kind 3–10） | kind 3/4/5/6/7/8/9 往返（对象等值、DAG 共享子结构同一对象）；kind 10：合法 pattern 构造 Regex 一次（编译次数断言）、非法/空 pattern → 14（加载期）；`PUSH_KH idx < size` | 实例化经 std（Regex/Decimal/…）；f_regex 依赖就绪 | T20 前置 |

### P3 包 `compiler`

| 步骤 | 目标成员 | 先写测试（红） | 实现要点（绿） | 验收（回归） |
|---|---|---|---|---|
| S3.1 | `TokenKind`（§4.3.1 全表：58 = 5 字面量 + 16 标识符/关键字 + 12 标点 + 24 运算符 + `EOF`）、`Token`（kind/text/pos/line/column/`nlBefore`） | 每个 kind 各一条构造用例；位置字段正确（含多字节字符列号按码点）；**`nlBefore` 正确性**（跨行 token 之后同行紧跟者 → false；空白/注释跨行 → true）；`match` 穷尽性 | `TokenKind` = 无载荷 enum；`Token` = 只读 struct（6 字段） | 词法基座 |
| S3.2 | `Lexer` 基础：`next/position/line/column`、`nlBefore` | 标识符/关键字（`recursive/let/var/if/else/while/for/in/where/break/continue/return/true/false/null`）/数字（含小数、指数、超 Int64 → 标记为 Decimal 候选）/标点/运算符（含 `!~` 单 token）；`=>`；EOF；**换行与 `;` 的 `nlBefore` 标记**；**词法错误族逐 kind 一条用例**（`IllegalCharacter`/`UnterminatedString`/`BadEscape`/`BadNumber`/`UnterminatedRegex`——fail-fast 抛出、**无 error token**） | 扫描器 + 关键字表；`null` 报「保留关键字、M1 无 null 字面值」专门诊断 | 逐 token 断言 |
| S3.3 | `Lexer` 字符串三形态 | 单行（`'…'`/`"…"`、转义、异种引号=内容）；多行（首行换行/首个非转义三连终止/单独 `\` → 错误 kind）；原始串（`#`×n 定界、verbatim、可跨行、未闭合 → 错误）；`'''` 最长匹配消歧；CRLF/CR→LF | 三形态合并扫描 + kind 错误 | T42 词法组 |
| S3.4 | `Lexer` `>\|` 锚定 | 进入判定（仅首个非空白位置标记触发）；无标记行整行保留；标记不进入产物（单独 `>\|` → 空串）；`>>\|`/`a>\|b`/`\|>\|` 为内容；处理顺序（标记消耗→转义→插值） | 多行串后处理 | T42 锚定组 |
| S3.5 | `Lexer` 注释与词法保护 | 单行/多行注释；`/* */` 嵌套配平；未闭合 → `UnterminatedComment`；字符串跨度内 `//`/`/*`/引号/`{`/`}`/`>\|` 不参与；注释不影响 site 语义 | 保护 → 剥离 → 解析三阶段 | T24 注释组 |
| S3.6 | `Lexer` 正则字面量 | `/pattern/flags`（flags 顺序无关、重复幂等、非法 flags → 14 语义的编译错误？否——非法 flags 加载期 14，前端词法仅切分）；字面量后紧贴 `/` 优先于注释识别（三书写形态）；`/` 除法消歧 | 正则段扫描 | T20/T26 词法组 |
| S3.7 | `LambdaAst/AstExpr/AstStmt/Parser.parseLambda` | 全 AstExpr 构造器各一用例；形参（`name: Type`，不支持具名/默认；`=>` 必需，缺失 → `MissingArrow`）；尾表达式；嵌套闭包与 IIFE；`recursive` 调用表达式；**语句终结判定（`;` 或换行；一行多条必须 `;`）**；**AST 节点携带 `pos`**（供 `setSite`/诊断） | 递归下降；`pos` 取自首 Token | T22 前置 |
| S3.8 | `NameResolver`：`resolve` | `recursive` 优先；命中注册表 → `UserHelper(slot)`；未注册 → `UnregisteredFunction`（消息含名字/位置/已注册清单）；非调用未定义标识符 → `UndefinedIdentifier` | 名字表 + 冲突拒绝 | T23 前置 |
| S3.9 | `DefiniteAssignment.analyze` | 先写后读通过；读未赋值 → 编译错误；循环出口不视为已赋值（含回边不动点）；分支全赋值 → 已赋值；`PUSH_NULL` 直存句柄型槽拒绝；捕获未赋值变量 → 错误 | 数据流不动点 | T13 前置 |
| S3.10 | `Lowerer` 算术/比较/位/`%` | 逐指令产物断言（IADD…IPOPCNT、CMP/EQ/LT、逻辑、位、移位低 6 位、EQ_H/NE_H）；`%` 仅 `(Int64,Int64)` → `IMOD`，F64/DEC/混合 → 编译错误 | 发射序列 | T12 子集 |
| S3.11 | `Lowerer` 字面值与混合提升 | 小数字面值 → Decimal（精确构造，不经 F64）；超 Int64 整数 → Decimal(scale=0)；指数形式 scale；混合四则/比较 → 提升插入（`TO_F64/TO_DEC src=0/1`）；`Float64` 仅显式标注；显式转换 6 方向（窄化仅显式） | 类型推导 + 插入 | T12 全组 |
| S3.12 | `Lowerer` 插值与混合 String 加法 | `"a${x}b"` → `TO_STR(t)+STR_CAT` 左结合；`s+x`/`x+s`；非标签类型（Closure/容器/Unit）→ 编译错误；求值顺序左→右；原始串 `${` 为字面文本 | 前端糖 | T11/T12 |
| S3.13 | `Lowerer` 控制流与循环 | `if` 双用法（值用法类型逐位一致+必需 else；语句用法 POP+栈平衡）；`while`（`LOOP_BACK` 安全点）；`for-in`：Range（含负 step/空区间）、List（长度快照+GET_IDX）、Map（`MAP_ITER_BEGIN/STEP` 模式序列+出口 close+23 语义）、String（码点序）；`where`；`break/continue` | 规范降低模式（§5） | T44/T45 前置 |
| S3.14 | `Lowerer` 多重赋值 | `(a,b)=(b,a)` 隐藏局部 + 先读后写；`_` 忽略位仍求值（POP）；RHS 左到右；仅一维元组字面量 | 前端糖 | T21 |
| S3.15 | `Lowerer` 闭包与 IIFE | 嵌套闭包 → 独立 FuncEntry + `closure_new`（捕获快照序）；`CALL_CLOSURE`（栈 [句柄, 实参…]）；`LOAD_CAP`；IIFE；闭包帧 `locals[0]` 约定；捕获遮蔽/重复定义拒绝；逃逸（存容器/跨桥）→ 编译错误 | 帧约定 + helper 调用 | T24/T25 前置 |
| S3.16 | `Lowerer` `recursive` | 顶层 → `CALL_FUNC entryFn`；闭包层 → `LOADL 0 + CALL_CLOSURE`；值位 → `LOADL 0` / `closure_new <adapterFn>`（适配器 FuncEntry 生成）；顶层签名含 Closure 的值化 → 编译错误；**尾位置自动优化**：实参逆序 STOREL + `LOOP_BACK <入口>`、不发射 RET、操作数栈回基线 | 三路降低 | T28/T47 |
| S3.17 | `Lowerer` 空容器构造与字面值 | `[]`/`{}` → `MAKE_LIST/MAKE_MAP`（上下文类型必需，无 → 编译错误）；非空字面值 → 常量 + `PUSH_KH`；字面值变量返回（含非空容器常量）；闭包字面值返回 → 编译错误 | 上下文类型判定 | T48/T51 |
| S3.18 | `Lowerer` 区间/正则操作符/n 窄化/重复与差 | Range 字面值（`..`/`..=`/step=0 编译期拒绝）；正则 `~`/`!~`/替换三形（helper 直呼 H58/H59/H72；非法 `n,m` 编译错误）；n 位置窄化（F64→`TO_I64`、DEC→`DEC_TO_I64` mode=0）；`s*n`（前端换序）、`dt1-dt2` | 前端糖 + 静态检查 | T26/T43 |
| S3.19 | `BytecodeBuilder`：`emit*`、`newLabel/place/fixupRel`、`setSite`、`callHelper/_NoCheck/_Void`、`callFunc/callClosure/ret/retVoid/bail`、`finish` | ① 标签回填目标正确；② `emitRel` 相对下一条指令；③ `CALL_HELPER` 自动尾随 CHECK_ERR（`_NC` 不尾随）；④ `setSite` 只在可能失败点前（产物断言）；⑤ `finish` 的 maxStack/flags（含变更型调用 → `flags.bit0`） | 构建器 | §7 校验输入 |
| S3.20 | `Assembler` 校验 1–11 | 每条校验一个**拒绝用例**：① 缺 CHECK_ERR（人为构造）→ 拒绝；② 0xA9–AA/0xC0–FF 发射 → `NotImpl`；③ sink 前栈不平衡；④ PUSH_KH 越界/未 freeze；⑤ LOADL/STOREL 越界；⑥ 跨回边优化掉错误检查；⑦ CALL_FUNC fid 不存在/argc≠nargs（closure_new fnId 同）；⑧ CALL_HOST/HW_* → NotImpl；⑨ 类型表长度/值；⑩ 明确赋值（与 S3.9 对接）；⑪ 变更型函数发射 deopt 模式 → 拒绝 | 校验集中实现；kind=NotImpl 等 | 每检查点一条负向用例 |
| S3.21 | `SourceCompiler.compile` 端到端 | 源码 → `.fbc` 字节 → `FbcReader.load` 回读 → 目录/类型/site/name 一致；未注册函数/坏形参等 → 对应 SourceCompileException（T50 编译期组） | 管线组装 | T22 基础 |
| S3.22 | `SourceCompiler` 兼容/回归 | 与 M1 规格示例（§8.0 四例：阶乘/插值/容器变更/空构造 Map）产物指纹固化（金样） | 金样文件 | 后续步骤防回归 |

### P4 包 `runtime`

| 步骤 | 目标成员 | 先写测试（红） | 实现要点（绿） | 验收（回归） |
|---|---|---|---|---|
| S4.1 | `JitContext`：`create/free/errCode/site/hwBase/hwCap/hwTop/fnId/flags/dbgBase/resetForCall/cp` | 偏移断言（0/8/16/24/32/40/48/56）；`resetForCall` 归零（errCode=0/site=-1/hwTop=hwBase）；`create/free` 配对（`LibC.malloc/free` 计数断言，T27 基础）；跨线程独立 | 非托管分配：`std.core.LibC.malloc<Int64>(count: 8)` / `LibC.free<Int64>`（选型理由见 design-m1 §5.3.1；**不用 acquireArrayRawData 钉住**）；转储缓冲同选型 `(count: 2 + maxNLocals)` | T27 基础 |
| S4.2 | `HandleTable.pin/get/release` | 同对象复用同 ID；不同类型对象不同 ID；`get` 类型不符 → None；`release` 后 `get` → None 且表项不重用（gen 校验）；null 拒绝 | 托管容器 + 槽三元组 | T14 基础 |
| S4.3 | `HandleTable` 窗口：`append`、`hwTop==hwCap` 扩容、`capacityLimit` 封顶 | 扩容倍增（`hwCap ≤ 2*hwTop`）；容量上限触顶 → 16；`initialCapacity` 可调（调用前生效，进行中不追溯）；T10 前置 | 追加 + 倍增 | T10 |
| S4.4 | `HandleTable.fetch`、`idxOf/tagOf/genOf` | null → 6；tag 不符 → 8；坏 idx → 6/99 防御 | 槽解析 | helper 公共前置 |
| S4.5 | `HandleTable.escape/resetWindow/promote` + `EscapeArea` | 逃逸槽 ID 不变、重置不回收；非逃逸槽随重置失效；规则 6① 自动回收（窗口区间判定）；`gen+1` 可复用 | 逃逸区登记 | T14 |
| S4.6 | `IterTable`：`open/next/key/value/close/clearAll` | 游标 `(gen<<32)\|idx`；`next` 0/1 唯一终止来源；未推进取件 → 99；close 幂等；`clearAll` 后旧游标 → 99（gen 失效）；条目 ≤ 嵌套深度；不登记窗口槽 | 宿主侧调用级表 | T45 |
| S4.7 | `HelperId`（常量+name） | 1–62、69–72 逐值；63–68 保留；name 非空 | 常量 | §8.4 hid 编码 |
| S4.8 | H01–H08（容器/字符串读） | 逐 helper 正常值 + 失败码（越界 4、缺键 5、null 6、tag 8）；不登记槽（`hwTop` 不变断言） | 模板 helper | T18 前置 |
| S4.9 | H09–H20（比较/判定） | 逐 helper：字符串/Decimal/DateTime/Duration 比较（禁止浮点中间值）；`h_ref_eq` 恒不失败；`h_guard` 6/8；`h_is_type` null→false | std 调用 + 转码 | — |
| S4.10 | H21–H23（错误/安全点/窗口） | `err_raise` 写槽+site 后返回；`interrupt_poll` deadline 到期 → -2；`hw_check` 触顶 → 16 | — | -2/16 语义 |
| S4.11 | H24–H31（Decimal） | 四则；`dec_div` ÷0 → 10；`dec_from_i64` scale=0；`dec_from_f64` 最短往返（`0.1f64 == Decimal("0.1")`）；`dec_to_i64` 越界 → 9；`dec_to_f64` 溢出 → ±Inf 不报错；分配型登记 1 槽 | std Decimal（默认上下文） | T12 |
| S4.12 | H32/H33/H50/H51/H60（字符串族） | `str_cat`；`to_str` 全标签（0–8）逐字节格式（§11.9：Bool/I64/F64(整数值附 .0/NaN/Infinity)/Decimal(plain)/DateTime(本地时区, 固定 TZ 采金样)/Duration(仓颉同形)/Range/Regex(规范序)/String 原样）；`str_sub` 码点索引与边界；`str_replace` 空模式 → 14；`str_repeat` n≤0 → 空串、溢出 → 3 | 格式算法内嵌（禁依赖平台 locale/printf） | T11 |
| S4.13 | H34–H40/H61（时间族） | DT±DUR 越界 → 11；DUR 四则溢出 → 12；`dur_div` ÷0 → 1；`dt_diff` 正/负/零、越界 → 12；DateTime 值恒 UTC | std time | T43 |
| S4.14 | H41/H42（区间） | `range_new` step=0 → 14、isClosed∉{0,1} → 14；空区间规则四式；`range_contains` 含端点/空区间 false | std Range | T12 子集 |
| S4.15 | H43–H48（变更型） | 逐 helper 与 std 语义对齐（`add/insert/set/remove/put/remove`；LIST_REMOVE 返回被删元素、MAP_REMOVE 归一 0/1）；常量目标 → 20；null 6/tag 8；**不登记槽**（hwTop 不变） | std collection | T18/T53 |
| S4.16 | H52/H53/H58/H59/H69/H72（正则族） | `is_match/find`（无匹配 → 0）；替换 g/n/n,m（越位 → 原串、剩余不足 → 到末尾、n=0,m=1 ≡ /0）；`str_to_regex` 非法/空 → 14（运行期、每次新对象不去重）；替换结果为新串（分配型） | std regex | T20/T26/T46 |
| S4.17 | H54–H57（闭包族） | `closure_new`（fnId+捕获快照，登记 1 槽）；`closure_fnid/closure_cap`（越界 6/8）；`fn_table` 基址（非 GC 内存） | 闭包对象 | T25 |
| S4.18 | `ctxWriteCode` 多级写码 | 内层已写码时外层仅在新异常覆盖；catch-all 末尾兜 99；任何 helper 异常不逃逸 | 写码规则 | §9.5 |
| S4.19 | `DbgDump.writeOnce/report/allocateDump/freeDump` | 首格哨兵（首个收敛点获胜）；DEOPT 不转储；`dbgBase=0` 跳过；报告模板逐字节（`（code=N，site=OFF）`/`源码行 L:C · fnId=F`/`变量: [0] a: Int64 = 42; [1] s: String#7;`）；无名槽省略名字；句柄型 `#idx` 不取对象；值型按 §11.9 文本化 | 报告组装 | T50 |
| S4.20 | `Interp` 框架：帧/local 载入/操作数栈/指令循环/返回 | 帧尺寸公式（16 对齐）；`LOADL/STOREL`；`RET/RET_VOID` 唯一出口；结束即销毁 | 解释循环 | — |
| S4.21 | `Interp` 全指令语义（分组） | 逐组：控制/常量栈/局部/整型（检查溢出、IDIV 边界、IMOD 四象限）/浮点（NaN 规范化 canonical）/比较逻辑位/控制流（JMP/JZ/JNZ/LOOP_BACK）/调用（CALL_FUNC 共窗口、CALL_CLOSURE、user helper 路由、fnId 重写）/类型（CAST/TO_I64/TO_F64/IS_TYPE/GUARD/THROW/ASSERT/ABORT/GUARD_NNZ）/容器与值提取（LEN/GET_IDX/……/TO_DEC/DEC_TO_I64/DEC_TO_F64）；fail-fast（错误后不再执行）；`CALL_HELPER` 自动 CHECK_ERR 语义 | 逐指令 | T2/T6 |
| S4.22 | `Interp` §11.9 语义组 | List/Map/Range/String 迭代（含 23）；`s[a..=b]` 折算；插值；范围/正则操作；TO_STR 契约与 JIT 一致（先自证） | 语义实现 | T19/T45 |

### P5 包 `backend`

| 步骤 | 目标成员 | 先写测试（红） | 实现要点（绿） | 验收（回归） |
|---|---|---|---|---|
| S5.1 | `CodeBuffer.alloc/write/patch/seal/flushICache/free/base/size` | 分配/写入/读回；seal 后写入失败（W^X）；I-cache 接口调用；free 幂等；页大小 4K/16K/64K 环境运行（T4 条件用例） | mmap/mprotect + cache 序列 | T4 |
| S5.2 | `FnTable.alloc/set/entry/free`、`ConstMirror.build/base/free` | 表项读写；镜像连续 8 B 且基址可烘焙；释放配对 | 非 GC 内存 | — |
| S5.3 | `BackendSelector.select` | 矩阵：`{Off,Auto,Force} × {Linux x86_64, Linux aarch64, Linux 其他, Windows, macOS, HarmonyOS}` → (Engine, Backend)；非 Linux 恒 Interp 且无异常；diagnostics 有记录（T7/T9） | OS/Arch 判定（f_base） | T7/T9 |
| S5.4 | `BackendX86_64` 框架 + `BackendX86_64.compile/entryThunk/abiSummary/name` | prologue/epilogue 序列（含 r15 保存/恢复、hwBase 镜像、fnId 写 ctx、args 拷入 locals、卫生填充）；帧 16 对齐算术 | 发射器 | §12.3 |
| S5.5 | x86 lowering 0x00–0x3F | 逐指令机器码断言（可用反汇编或行为对拍）：`SET_SITE`、`BAIL` 块（含单次转储）、`CHECK_ERR`、`STACK_GUARD`、PUSH_*、DUP/PICK、LOADL/STOREL/LOAD_CAP、整型组（jo/bail、IDIV 前置判定、IMOD INT_MIN/-1、ICLZ=bsr 序列、IPOPCNT=SWAR 序列）；NaN/失败收敛块规则 | 逐条 lowering 表 | §12.4 |
| S5.6 | x86 lowering 0x40–0x8F | 浮点（含 NaN 尾 `CANON`）、比较（EQ_F 谓词/GT 交换）、逻辑位、跳转（rel32）、调用模板 A/B/C、CAST/TO_I64（哨兵区分）/GUARD/ASSERT/ABORT | 同上 | §12.4 |
| S5.7 | x86 模板 A/B/C 与镜像 | `CALL_HELPER`（lea rsi/argc 收参/自动 CHECK_ERR）、`CALL_FUNC`（fnTable 间接 + fnId 重写）、`CALL_CLOSURE`（H55/H57/间接调用 + IBT endbr64）、`PUSH_KH`（镜像立即数） | 模板 | §12.4 |
| S5.8 | `JitCompiler.compileUnit`（x86 路径）+ `JitArtifacts` | 最小单元（`{=>1}`）编译→执行→结果 1；两遍布局（x86 通常一遍）；重定位补丁正确 | 编排 | T2 前置 |
| S5.9 | `BackendAArch64` 框架 + lowering 全量 | 同 S5.4–S5.7 全部项（x29/x30 保存、CTX x19、`b.vs` 溢出、`sdiv` 预判、`frint*`、`cset` 谓词、`csel`、`clz`、FPCR.DN、跳板）；aarch64 条件分支 ±1 MB 边界用例 | 逐条 lowering 表 | §12.4 |
| S5.10 | `JitCompiler` 两遍布局与跳板 | 超界条件分支 → 「取反条件 + 无条件 b」跳板；布局阶段两后端共享；跨函数重定位 | 布局阶段 | §12.4 |
| S5.11 | 后端合规判据（§12.7） | 最小集 `interp == jit_x86_64 == jit_aarch64`（结果/NaN 位模式/errCode/site） | 差分 | T2 |
| S5.12 | 引擎降级一致性 | `jit=Force` 在非 Linux 静默降级：不报错、结果与 Linux 解释器一致、diagnostics 记录 | 桥依赖 | T7 |
| S5.13 | 代码内存生命周期 | 卸载 → `munmap`；编译缓存键 `(arch, cpuFeatures, bytecodeFingerprint)` 仅驻内存；mmap/mprotect 失败 → 降级解释器（不写错误槽） | — | T29 前置 |
| S5.14 | IBT/CET | `endbr64`/`bti c` 全程发射；IBT 开启内核运行无控制保护异常 | — | T5 |

### P6 门面 / 桥（包 `fountain::f_jit`）

| 步骤 | 目标成员 | 先写测试（红） | 实现要点（绿） | 验收（回归） |
|---|---|---|---|---|
| S6.1 | `CompileOptions`、`PredefinedFunction` | 默认值；构造校验（paramTypes 合法集 0–8/10–11）；impl 返回值与 retType 匹配（契约） | class | — |
| S6.2 | `Compiler`：`init/registerFunction/unregisterFunction/hasFunction/registeredNames` | 注册/查询/注销；重名 → DuplicateRegistration；超 `maxPredefined` → 编译期错误；快照语义（注册变更不影响已编译产物——S6.8 联测） | 注册表 + 锁 | T23 需求 2 |
| S6.3 | `CallMarshal`：`makeArgMarshalers/marshalArg/makeRetUnboxer/escapeAndGet/cleanup` | §8.2.1 表全行（Int64/F64/Bool/句柄型；不符 → 19）；不接受 Option/null、不做宽化；解包表全行；`escapeAndGet` 自动回收（T14/T15）；try/finally 全路径清理（含异常路径） | Marshal/解包生成 | T15 |
| S6.4 | 三态收尾 + `Report.throwJit` | 0→unbox；-1→`Interp.run` 重跑（对调用方透明）；-2→InterruptedException；>0→JitException（原码原 site+报告）；19 契约错误 site=-1；非两类异常不逃逸（兜 99） | 收敛逻辑 | T6/T15 |
| S6.5 | `JitFunction.call<T>` 六步 | 长度不符 → 19；Marshal 失败 → 19；T 与 retType 一致性（编译期校验 + 运行期注册表 → 19）；`site=-1/sourcePos=None` 契约错误；返回正确 T | 单态化适配器 | T15/T52 |
| S6.6 | `AdapterRegistry`：`register/lookup/removeUnit` | 键 `(单元指纹, fnId, T)`；查无 → 19；卸载按维度移除；并发注册 | 宿主侧锁 | T15/T29 |
| S6.7 | `CompileCache`：`lookupOrClaim/awaitReady/finish/remove` | 同键并发：恰好执行一次管线（计数断言）、全线程同一 `JitFunction`；失败共享等价异常；不同键互不阻塞；Miss→CAS 占位 | 状态机 Idle→Compiling→Ready/Failed | T16 |
| S6.8 | `CompilePipeline.runSource` + `Compiler.compile(source)` | 端到端：示例源码编译/调用；失败在 compile 时刻抛出（不涉及运行期槽）；同源码复用；user helper 全链路（注册→调用→返回 marshal→异常 21） | 四步管线 | T22/T23 |
| S6.9 | `CompilePipeline.runUnit` + `Compiler.compile(unit)` | 装载 `.fbc` 全路径；含 user hid 的单元 → 加载期拒绝（18 语义）；字节码指纹去重；`SourceUnit.entryFn` 校验 | — | T1 |
| S6.10 | `JitFunction.unload/isUnloaded` | 未卸载 → Ready 可调用；卸载后调用 → 19（site=-1）；活跃调用排空（timeout 恢复 Ready）；双 unload 幂等；Unloading 期间 compile 阻塞后按 Miss 重编（并发=序贯）；资产释放顺序与计数（code buffer 最后） | 状态机 + 资产清点 | T29 |
| S6.11 | 再导出与用户面冒烟 | `import fountain::f_jit.*` 后可见全部用户面声明（编译期）；最小宿主示例（编译+调用+卸载） | `public import` 清单 | 用户面 API 冻结 |
| S6.12 | 端到端金样回归 | S3.22 金样单元 + 差分三引擎 + 错误报告逐位 | — | P7 前置 |

### P7 差分与验收

| 步骤 | 目标成员 | 先写测试（红） | 实现要点（绿） | 验收（回归） |
|---|---|---|---|---|
| S7.1 | T1/T2/T3/T4/T5 | 黄金字节码跨平台加载；三引擎差分核心；端序；页大小；CET/BTI | 差分 harness 全量接入 | T1–T5 通过 |
| S7.2 | T6/T7/T8/T9 | 错误一致性 1–20/99；降级一致性；NaN 与文本；冻结决策回归（bit1=1/32 位/Force） | — | T6–T9 通过 |
| S7.3 | T10–T15 | 分配与重放；TO_STR 黄金值（固定 TZ）；混合类型；类型化局部与明确赋值；句柄 Marshal 与逃逸；call\<T\> 全组合 | — | T10–T15 通过 |
| S7.4 | T16–T21 | 只编译一次；并发重复调用；容器变更差分；迭代与快照；字符串/正则；多重赋值 | — | T16–T21 通过 |
| S7.5 | T22–T29 | 源入口格式与递归；Compiler 门面与预定义；闭包族；跨指令/机制交互（闭包/值化/卸载/内存安全） | — | T22–T29 通过 |
| S7.6 | T42–T48、T50–T53 | 字符串形态；重复与日期差；if 双用法；Map 惰性迭代；Regex 互操作；尾递归；容器自建；源位置与诊断；容器/类型矩阵 | — | 对应项全绿 |
| S7.7 | 容量与性能基线 | 窗口扩容深度用例（显式调小 initialCapacity 复现）、大循环分配 16 边界；JIT 相对解释器吞吐基线（同结构同副作用对照） | 记录实测数字 | 性能证据留档 |
| S7.8 | 文档同步 | 设计/计划与实现偏差回写（design-m1.md/plan-m1.md 修订记录） | — | 文档与产物一致 |

---

## §3 T 系列 → 步骤映射

| T | 落点步骤 | T | 落点步骤 |
|---|---|---|---|
| T1 | S2.13/S6.9/S7.1 | T21 | S3.14/S7.4 |
| T2 | S0.2/S5.11/S7.1 | T22 | S3.7/S6.8/S7.5 |
| T3 | S2.2/S7.1 | T23 | S6.2/S6.8/S7.5 |
| T4 | S5.1/S7.1 | T24 | S3.5/S3.15/S7.5 |
| T5 | S5.14/S7.1 | T25 | S3.15/S4.17/S7.5 |
| T6 | S4.21/S6.4/S7.2 | T26 | S3.6/S3.18/S4.16/S7.5 |
| T7 | S5.3/S5.12/S7.2 | T27 | S4.1/S6.3/S7.5 |
| T8 | S4.12/S7.2 | T28 | S3.16/S7.5 |
| T9 | S2.11/S2.14/S5.12/S7.2 | T29 | S6.10/S7.5 |
| T10 | S4.3/S4.5/S7.3 | T42 | S3.3/S3.4/S7.6 |
| T11 | S4.12/S7.3 | T43 | S3.18/S4.13/S7.6 |
| T12 | S3.10/S3.11/S4.11/S7.3 | T44 | S3.13/S7.6 |
| T13 | S3.9/S4.1/S7.3 | T45 | S3.13/S4.6/S7.6 |
| T14 | S4.2/S4.5/S6.3/S7.3 | T46 | S4.16/S7.6 |
| T15 | S6.3/S6.5/S6.6/S7.3 | T47 | S3.16/S7.6 |
| T16 | S6.7/S7.4 | T48 | S3.17/S7.6 |
| T17 | S6.7/S7.4 | T50 | S1.9/S4.19/S7.6 |
| T18 | S4.15/S7.4 | T51 | S3.17/S7.6 |
| T19 | S4.22/S7.4 | T52 | S6.5/S7.6 |
| T20 | S2.8/S2.15/S4.16/S7.4 | T53 | S4.15/S7.6 |

> 说明：上表为**主要落点**；次要落点（如 T8 的 NaN 规范化实现 S4.21、T46 的桥 Marshal S6.3、T50 的 site/name 加载校验 S2.9/S2.10、T52/T53 的读类 helper S4.8/S4.21）不逐一列出，统一由 S7.x 差分阶段兜底验收。

---

## §4 顺序约束与风险

1. **硬顺序**：`base` → `bytecode` →（`compiler` ∥ `runtime` ∥ `backend`）→ 门面。`Interp`（S4.20–S4.22）必须先于差分 harness 的两后端对拍启用（解释器是基准）。
2. **用户面 API 冻结点**：S6.11 之后再改公共签名需走「文档 + 用例」双更新（契约变更偏好：宁写文档也不做破坏性改动）。
3. **平台条件**：S5.x 的机器码用例仅在 Linux x86_64/aarch64 上可执行（CI 矩阵需两架构）；其余平台跑「降级一致性」子集。
4. **T11 的 TZ 依赖**：DateTime 文本化用例固定 TZ 采金样（基准 UTC + 非 UTC 附加用例）。
5. **风险**：helper 集（H01–H72）体量大且零散——按族推进（S4.8–S4.17），每族完成即接差分，避免最后积压。
6. **与 M2/M3 的衔接**：M2（步骤前缀 `Q`）追加 LocalType 13/14 与 H63–H65、verMajor 2；M3（步骤前缀 `R`）追加 LocalType/token 15 与错误码 22、H66–H68、kind 11——M3 的 JSON helper 已裁定顺延为 **H73–H75**（避让 M1 已占用的 H72 `regex_replace_range`；2026-10-11 裁定，见 design-m3.md §10 的 M3-6）。
