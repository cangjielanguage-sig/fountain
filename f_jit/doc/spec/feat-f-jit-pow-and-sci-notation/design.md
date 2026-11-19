# Design：`**` 与科学计数法

## 1. `**` 的语义对齐（依据仓颉实测）

| 项 | 仓颉 | 方言（本变更） |
|---|---|---|
| 类型 | `Int64 ** UInt64`；`Int64 ** Int64` 编译错误 | `**` 仅 `(Int64, Int64)`；方言无无符号 ⇒ 把"指数无符号"映射为"**指数必须非负**" |
| 优先级/结合 | 4（> `*`，< 一元 `-`）、右结合 | 同 |
| 负指数 | 类型不可表达 | 字面量负值 → **编译期拒绝**；运行期负值 → `14` |
| 溢出 | 静态可判 → 编译期报错；否则运行期抛 | 运行期 → `ERR_OVERFLOW_I64(3)`；字面量可判的 `2 ** 63` 由常量折叠/运行期一致地报 `3`（本实现取运行期路径，编译期不特判，保持简单） |
| `0 ** 0` | 1 | 1 |

**为什么走 helper 而不是新 opcode**：`CALL_HELPER` 通道三引擎共用同一份仓颉实现 ⇒ I7 天然成立，
x86/a64 后端**零改动**；新增 opcode 则要改两后端 + 解释器 + 版本（风险大、收益为零）。

## 2. 落点

| 环节 | 文件 | 改动 |
|---|---|---|
| 词法 | `compiler/Token.cj` | 新增 `TokenKind.StarStar`（ordinal 取未用值，不移动既有 ordinal） |
| 词法 | `compiler/Lexer.cj` | `scanOp`：`0x2A 0x2A` → `StarStar`（`***` 切成 `**` + `*`）；`scanOne`：`.` 后接数字 → 走 `scanNumber`（前导点） |
| 语法 | `compiler/Parser.cj` | 新增 `parsePower()`：`parseUnary` 之上、`parseMultiplicative` 之下，右结合（右操作数递归 `parsePower`） |
| 类型/降低 | `compiler/Lowerer.cj` | `case StarStar`：非 `(I64, I64)` → `TYPE_MISMATCH`；字面量负指数 → 编译期拒绝；`setSite(pos)` 后 `callHelper(H77, 2)`，返回 `I64` |
| helper | `compiler/HelperCodec.cj`（镜像） | `IPOW = 77` |
| helper | `runtime/HelperId.cj` | `IPOW = 77` + 名称表 |
| helper | `runtime/Helpers.cj` | `ipow`：指数 <0 → `14`；快速幂 + 乘法溢出检查 → `3` |
| 版本 | `bytecode/FbcHeader.cj` 及写入方 | `verMinor` **14 → 15**（helper 表新增项；旧加载器不该接受含 H77 的单元） |

## 3. 快速幂 + 溢出检查（核心算法）

```
ipow(base, exp):
  if exp < 0        → fail 14
  if exp == 0       → 1
  result = 1; b = base; e = exp
  while e > 0:
     if e & 1 == 1: result = mulChecked(result, b)   // 溢出 → fail 3
     e >>= 1
     if e > 0: b = mulChecked(b, b)
  result
```

`mulChecked(a, b)`：显式边界判断（`MinInt64 * -1`、符号组合的 `MIN/…`、`MAX/…` 阈值）；
任一分支越界 → `3`。**O(log exp)**，避免 `2 ** 1e9` 的线性死循环。

## 4. 科学计数法（现状 + 增量）

现状（`Lexer.scanNumber`，:337-379）已支持：`frac || exp → DecLit`、`f64` 后缀 → `F64Lit`；
`3e2`、`1e-3`、`1.5e3f64`、`2e3f64` 已可用。**缺口**只有仓颉允许的**前导点**：
`.5`、`.5e2`、`.5e2f64`。

增量：`scanOne` 的 `.` 分支先看下一个字符是否数字 → 走 `scanNumber`（`cur` 指向 `.`，
`scanNumber` 需接受"首字符为点"）；其余（`.` 单独 / `..` / `...`）保持原判定顺序。

## 5. 测试

| 层 | 用例 |
|---|---|
| 词法 | `**` 成对、`***` = `**`+`*`、`* *` 仍是两个 `Star`（语法错误）；`.5`/`.5e2`/`.5e2f64`；`1e`/`1e+`/`1.5f32` 报错 |
| 语法 | `2 ** 3 ** 2` 右结合；`-2 ** 2` = -4；`2 * 3 ** 2` = 18 |
| 执行 | `2**10`=1024、`0**0`=1、`0**5`=0、`(-2)**3`=-8、`x**0`=1 |
| 错误面 | `2**63` → 3；`{x:Int64 => 2 ** x}` 传 -1 → 14；`1.5 ** 2` / `2 ** 1.5` / `"a" ** 2` → 编译期 |
| 科学计数法 | `1.5e3`=1500、`3e2`=300、`1e-3`=0.001（Decimal）；`1.5e3f64`/`.123e2f64`=123.0（Float64） |
| 三引擎 | `test.diff` 增 1 例幂；`X86Exec_test` 风格加 1 例 |

## 6. 风险

| 项 | 说明 |
|---|---|
| `verMinor` 升级 | 旧 Golden 用例的期望头字节需同步（14→15） |
| `**` 词法切分 | `***`、`**=`（方言无复合赋值）需覆盖；`* *` 仍应报语法错误 |
| 前导点 | 不能影响 `.` 成员访问、`..`/`..=` 区间与浮点 `.5` 的判定顺序 |
