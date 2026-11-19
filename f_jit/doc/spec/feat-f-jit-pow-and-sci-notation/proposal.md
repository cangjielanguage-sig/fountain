# Proposal：Int64 幂运算 `**` + 浮点/十进制科学计数法

## Why

方言目前没有幂运算；科学计数法只部分可用（`DecLit` 已支持 `3e2`、`1e-3`，`F64Lit` 支持
`1.5e3f64`，但**不支持仓颉允许的前导点形态** `.123e2`）。用户要求补齐两项，且**语法与限制与仓颉侧一致**。

仓颉侧事实（`docs/dev-guide/source_zh_cn/Appendix/operator.md:16`、`basic_data_type/float.md:9-41`，
并用 `cjc 1.3.0` 实测）：

| 项 | 仓颉规则 | 实测 |
|---|---|---|
| `**` 优先级/结合性 | 优先级 **4**（高于 `*`/`/` 的 5，低于一元 `-` 的 3），**右结合** | `2 ** 3 ** 2` 解析为 `2 ** (3 ** 2)` |
| `**` 类型 | **有符号基 ∧ 无符号指数**（`Int64 ** UInt64`）；`Int64 ** Int64` 与 `UInt64 ** UInt64` 均**编译错误** | 编译错误信息建议"提供 `UInt64` 右操作数" |
| 负指数 | 类型层面不可能（指数必须 `UInt64`） | 无法书写 |
| 溢出 | **静态可判时编译期报错**（`arithmetic operation '**' overflow`）；否则运行期按溢出策略抛异常 | `2 ** 63` 编译期即拒 |
| `0 ** 0` / `x ** 0` | `1` | — |
| 浮点字面量 | 十进制：整数部或小数部至少一个；**无小数部时必须有指数部**（`e`/`E`，底 10）；允许前导点 `.123e2`；后缀 `f32`/`f64` | `1.5e3f64`、`2e3f64`、`.123e2f64` 均合法 |

方言没有无符号类型 ⇒ 把"指数必须无符号"映射为"**指数必须非负**"：
字面量负指数**编译期拒绝**，运行期算出负指数**运行期拒绝**。

## What Changes

- **Int64 `**`**：
  - 词法：新增 `**` 词法单元（`StarStar`；`***` 按 `**` + `*` 切分）；
  - 语法：优先级 4、**右结合**（新增 `parsePower` 插在 `parseUnary` 与 `parseMultiplicative` 之间）；
  - 类型：仅 `(Int64, Int64) → Int64`（其他组合编译期 `TYPE_MISMATCH`，与 `%` 同风格）；
  - 语义：`x ** 0 = 1`、`0 ** 0 = 1`、负指数 → `ERR_ARG_MISMATCH(14)`、溢出 → `ERR_OVERFLOW_I64(3)`；
  - 降低：新增 helper **H77 `IPOW`**（`(Int64, Int64) → Int64`），三引擎共用同一实现（I7 天然成立）；
  - 版本：helper 表新增一项 ⇒ `verMinor` **14 → 15**。
- **科学计数法**：
  - 补 **前导点** 数字形态：`.5`、`.5e2`、`.5e2f64`（`.5` 按方言约定 = Decimal）；
  - 明确并测试既有形态：Decimal `3e2` / `1e-3` / `1.5e3`，Float64 `1.5e3f64` / `2e3f64` / `2.4e-1f64`；
  - 错误面：`1e` / `1e+` / `.` 单独 / `1.5f32` 均为词法错误（`f32` 方言不支持）。
- **README**（中英）：§6 类型表补 `**` 与科学计数法；新增 §6.x 小节给出文法与边界；FAQ 不加。

**不改**：`.fbc` 其他段布局、opcode 集合、既有 helper 语义、aarch64/x86 后端代码（幂走 helper，两后端零改动）。

## Capabilities

- **Modified Capabilities**：`f-jit-compiler-frontend`（词法/语法/类型）、`f-jit-runtime`（H77 IPOW）、
  `f-jit-backend`（helper 表版本）。

## Impact

- 代码：`compiler/Token.cj`、`compiler/Lexer.cj`、`compiler/Parser.cj`、`compiler/Lowerer.cj`、
  `runtime/HelperId.cj`、`runtime/Helpers.cj`、`bytecode/FbcHeader.cj`（verMinor）。
- 测试：新增 `Pow_test.cj`（执行/错误面/右结合）、`NumberLit_test.cj`（科学计数法与错误面）；
  既有 lexer/parser/golden 用例按需同步。
- 风险：`verMinor` 升级会让旧 Golden 断言失败（需同步期望值）；`**` 与既有 `Star` 切分需覆盖 `***`
  与 `* *`（后者仍是"两个星号"语法错误）。
