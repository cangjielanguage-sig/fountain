# x86_64 端验证指引（N3.4）

> 本文件用于在原生 x86_64 Linux 上补齐 `fix-jit-unary-not` 的第三引擎证据。
> AArch64 侧已由 `verify.md` 覆盖；x86 侧需要在本机之外执行一次。

## 1. 前置

| 项 | 要求 |
|---|---|
| 平台 | Linux x86_64（`uname -m` 返回 `x86_64`） |
| SDK | 仓颉 1.3.0（与 `cjpm.toml` 的 `cjc-version` 一致） |
| 分支 | `fix/jit-unary-not`，HEAD `7f5dea83` |
| 环境 | `source cangjie.sh`（Linux 侧脚本，不是 `cangjie-hmos.sh`） |

## 2. 步骤

```bash
git fetch origin fix/jit-unary-not
git checkout fix/jit-unary-not
cd f_jit
source ../cangjie.sh          # 或你本机的仓颉环境脚本
cjpm build
cjpm test 2>&1 | tee /tmp/f_jit_x86_test.log
```

定向跑（更快，先确认这一组）：

```bash
cjpm test --filter "UnaryNotDiff" 2>&1 | tee /tmp/f_jit_unary_not_x86.log
cjpm test --filter "A64NotBEncoding" 2>&1 | tee /tmp/f_jit_a64_encoding.log
```

## 3. 预期

| 用例 | 预期 | 说明 |
|---|---|---|
| `cjpm test` 全量 | `1163 passed / 0 failed` | 与 AArch64 侧一致；若数字不同，以 x86 实际总数报告 |
| `UnaryNotDiff_test` | 全绿，且 `DiffSession.ran() == 2` | `InterpRunner` + x86 版 `NativeRunner` 都参与 |
| `UnaryNotDiff_test` 的 `!n` 矩阵 | `!2 = -3`、`!0 = -1`、`!-1 = 0`、`!Int64.max/min` 位反正确 | D3 分派在 x86 上的证据 |
| `UnaryNotDiff_test` 的 `!true` / `!(49 < 50)` | `false` / `false` | NOT_B 在 x86 上本来就正确，修复前后都应为 `false` |
| `A64NotBEncoding_test` | 全绿 | 纯编码断言，不执行 AArch64 机器码，x86 上同样可跑 |
| `skipped()` | 0 | x86 上 `NativeRunner` 可用，不应出现 `BackendX86_64` 跳过 |

**关键判据**：`UnaryNotDiff_test` 里的 `DiffSession([InterpRunner(), NativeRunner()])` 在 x86_64 上会把 `NativeRunner` 条件编译成 x86 版本（`RealRunners.cj:235`，`@When[arch == 'x86_64' && os == 'Linux']`），`engine()` 返回 `BackendX86_64`。若 `ran()` 只有 1，说明 x86 版没被选中，需要先查条件编译。

## 4. 失败时的定位顺序

1. 先看 `A64NotBEncoding_test`：它只验证 AArch64 机器字，与 x86 无关；若它红，说明编码器被误改；
2. 再看 `UnaryNotDiff_test` 的 `!n` 矩阵：若只有 x86 红，问题在 `X86Lower` 的 `0x65`（`48 F7 14 24` = `not qword [rsp]`）或 `0x5E`（`48 83 34 24 01` = `xor qword [rsp],1`）；
3. 若 `!true` 红而 `!n` 绿，问题在 `NOT_B`；
4. 若两边都绿但 `ran() == 1`，是条件编译没选中 x86 `NativeRunner`。

## 5. 回传内容

跑完把下面三项贴回来，用于回填 `verify.md` 的 N3.4：

1. `uname -a` 与 `cjc -v` 输出；
2. `cjpm test` 的汇总行（passed / failed / skipped）；
3. `cjpm test --filter "UnaryNotDiff"` 的完整输出（含 `ran` / `skipped` 相关断言）。

回填后 N3.4 可勾选，`fix-jit-unary-not` 的 24/24 任务闭合。
