# Design

## Context

四项发现分两类：**已修未立规**（X1 版本、X4 `else if`）与**修而未净**（X2 键分叉、X3 无效选项）。前者不改代码，只补规格与门禁；后两者有真实代码缺口。设计只回答「怎么收口」，需求与验收见 `proposal.md` 与 `specs/`。

## 决策

### D1 版本是编译选项，不是硬编码常量

`CompileOptions.verMajor: UInt16 = Version.LATEST`（新增 `Version.LATEST = M3_MAJOR`）。`CompilePipeline.runSource` 用它替代 `Version.M3_MAJOR`，并在 `CompileCache` 键里加 `v${verMajor}`。

- **为什么不是「自动取最新」了事**：上一轮把 M2 改 M3 只是把常量换了个值，下一次扩版本还会重演。显式选项让「产物版本」成为调用方可见、可断言、可缓存区分的输入。
- **为什么不校验 `verMinor`**：`verMinor` 由编译器自身决定（`Version.MINOR`），调用方只选主版本；规则集注册表已按主版本分派。
- **拒绝方式**：`runSource` 入口检查 `Version.supportedMajors()`，不在集合内即抛 `SourceCompileException('CompileFailed', …)`，消息含请求值与支持集。**不落错误槽**——这是编译期失败，与运行期错误码无关。

### D2 `strictFp` 归位编译期（用户已裁定）

`CompileOptions.strictFp: Bool = false` → `SourceCompiler` → `Lowerer` → `emitArith` 选 `FDIV` / `FDIV_CHK`。

- **为什么不按 `ctx.flags` 运行期门控**：那样每次浮点除要多 `ldr w3,[x19,#48]` + `tbz w3,#0,skip` 两条指令，strict 关着也要付；且同一指令有两种行为，反汇编不可自证。strict 是「这一批产物要严格查除零」的调试策略，天然是产物级。
- **缓存键**：`v${verMajor}/fp${0|1}` 两段都进键。同源两种 strict 配置必须产出两份独立单元。
- **删除 `CallContext.strictFp` / `literalCopy`**：两者都无消费语义。`invoke` 不再写 `ctx.flags` bit0；`CtxFlags.STRICT_FP` 作为 ABI 位保留，注释与规格注明「运行期不读」。
- **`literalCopy` 为什么不补建**：字面量是编译期常量，`CallMarshal` 收到的是已求值的 cell/句柄；桥层不存在「深拷贝字面量」的时机。补建只能凭空造一个语义。

### D3 值型键只有一种形态：裸 cell

`CanonKey.f64(bits)` 改为返回 `CanonKey.cell(Int64(bits))` 的同一文本（`i:<64 位有符号解释>`），删掉 `f:` 前缀。

- **根因**：`Map` 的键在字节码里是裸 cell，运行期 `mapKeyOf` 对非句柄走 `CanonKey.cell`；而 `canonKeyOf(Float64)` 走 `f64`。两条路径对同一 `1.5` 给出 `i:...` 与 `f:...`，装箱承载（`Map<Any,…>` 或宿主 interning）就会查不到常量键。
- **为什么不反过来让 `cell` 去适配 `f64`**：`cell` 是值型键的通用形态（Int64 也用它），它拿不到类型码；让 `cell` 猜类型只会引入新的分叉。统一到「承载无关」的 cell 形态是唯一自洽解。
- **不变式**：对任意值型 `v`，`canonKeyOf(box(v)) == CanonKey.cell(raw(v))`。这条比「某一侧前缀写对」更强，能挡住下一次单边修改。

### D4 `else if` 只补规格，不改代码

上一轮已把 `Parser.parseIfExpr` 改成「先判 `KwIf`、再取块」，并删除了不可达的 `while`。本次只在规格里写死两条：值用法与语句用法同构；解析顺序必须是「先判关键字、后取块」，禁止「先无条件取块再回头判 `if`」的写法。**不加人为的「不可达代码检测器」**——那属于 lint 治理，不是语法契约。

### D5 兼容性口径

| 面 | 结论 |
| --- | --- |
| `.fbc` 格式 | 不变（`FDIV` / `FDIV_CHK` 都是既有 opcode） |
| 默认产物 | 逐字节不变（`strictFp=false` 仍发 `FDIV`） |
| 缓存 | 键格式变化，旧条目自然失效（仅进程内） |
| 公共 API | 删两个字段、加两个字段，属 0.x 破坏性变更 |
| 错误码 | 不新增；strict 下 ÷0 复用 1（`DIV_ZERO`） |

## 风险与缓解

| 风险 | 影响 | 缓解 |
| --- | --- | --- |
| 删除公共字段破坏下游 | 编译失败（显式，不是静默错算） | proposal 标注破坏性；仓内唯一调用方是测试，一并改写 |
| 缓存键变更导致重复编译 | 一次进程内多编一份 | 键只在同一进程内，编译成本一次性；正确性优先 |
| strict 产物与非 strict 产物并存 | 内存占用上升 | 只在显式开启时产生第二份；默认路径无额外产物 |
| `f:` 前缀消失影响既有键文本 | 旧常量表若持久化会失配 | 常量表随单元一起生成，不跨进程持久化；无兼容面 |
| 版本选项被误设为 M1/M2 编 Any | 编译期报「局部槽类型码非法」 | `supportedMajors()` 只放行 1/2/3，且错误消息给出请求值；M3 特性配 M2 仍按既有诊断拒绝 |
