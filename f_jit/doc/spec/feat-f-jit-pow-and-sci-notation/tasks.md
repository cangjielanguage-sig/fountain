# Tasks

## 1. 词法与语法

- [x] 1.1 `TokenKind.StarStar`（ordinal 独立取值，不移动既有 ordinal）；`Lexer.scanOp` 识别 `**`
      （`***` → `**`+`*`；`* *` 仍是两个 `Star`）
      验证：`Pow_test.powPrecedence` / 全量 Lexer 用例
- [x] 1.2 `Parser.parsePower`：插在 `parseUnary` 与 `parseMultiplicative` 之间，优先级 4、**右结合**
      验证：`powIsRightAssociative`（`2 ** 3 ** 2` = 512）

## 2. 语义与 helper

- [x] 2.1 `Lowerer` 的 `case StarStar`：非 `(I64, I64)` → 编译期 `TYPE_MISMATCH`；`setSite` 后
      `callHelper(H84, 2)`
      验证：`powRejectsNonInt64`（`1.5 ** 2` 编译期拒绝）
- [x] 2.2 `HelperId.IPOW = 84` + `HelperCodec.IPOW` + `Helpers` 分派 + `runtime/PowHelper.cj`
      （快速幂；负指数 → 14、溢出 → 3、`x**0`/`0**0` = 1）
      验证：`powBasics` / `powOverflowFails3` / `powNegativeExponentFails14`

## 3. 科学计数法

- [x] 3.1 前导点数字（`.5`、`.5e2`、`.5e2f64`）：`Lexer.scanOne` 走 `scanNumber`；
      `Lowerer` 的 `F64Lit` 解析前补 `0`
      验证：`NumberLitSci_test.leadingDotLiteral` / `floatSciNotation`
- [x] 3.2 既有形态回归：Decimal `1.5e3`/`3e2`/`1e-3`/`2.4E-1`，Float64 `1.5e3f64`/`2e3f64`
      验证：`NumberLitSci_test.decimalSciNotation` / `floatSciNotation`

## 4. 回归与版本

- [x] 4.1 全量 `cjpm test`：**1123/1123（0 FAILED / 0 ERROR）**
      验证：Summary 数字
- [x] 4.2 `verMinor` 决定：**不升级**（升 15 导致 6 个 Golden 指纹 + 2 个常量表断言失败；
      H84 只被新单元引用）——取舍记入 `verify.md` 与 README「已知限制」
      验证：撤回后全量恢复绿

## 5. 文档

- [x] 5.1 README（中英）：§6 类型表补 `**` 与科学计数法字面值；新增 **§6.6 幂运算与科学计数法**
      （规则表 + 示例 + 非法形态）
      验证：两文件结构一致、`grep '\*\*'` 命中

## Workflow follow-up

- 用户要求（2026-10-22）：两项新特性走 OpenSpec 全流程并加入 README。
- 完成后 `opsx:verify` + `opsx:archive`。
