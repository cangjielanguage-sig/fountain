# Verify

## 全量回归

| 项 | 数值 |
| --- | --- |
| 基线 | 1115 用例 / 1115 通过 / 0 失败 |
| 终态 | **1115 用例 / 1114 通过 / 0 error**（唯一失败为 `PerfM2_test.userHelperVsHostClosure`，性能比值在负载下越界；单独复跑 1/1 通过） |
| 定向用例 | `AnyBridgeCall_test` 7/7、`JitBacked_test` 4/4 |
| 回归 | 0 |

## 变更内容（纯规格对齐）

| 项 | 变化 |
| --- | --- |
| 规格 `调用入口与选项` | `invoke<T>(args, options)` → `call<T>(args, options)` 同名重载；保留「SHALL NOT 引入 `tryInvoke`」 |
| `AnyBridgeCall_test` | 用例改名 `a3_4_invokeMatchesCall` → `a3_4_callOverloadsAgree`；注释与局部变量去 `invoke`；断言不变 |
| `JitValue` / `ValueTypes_test` / `JitFunction` 注释 | 把「`invoke` / `tryInvoke` 为生产点」的历史表述改为「桥内 `call` 路径」 |
| 代码 | 零行为改动 |

## 口径

- 规格不再出现「`invoke` 为唯一带选项入口」；改为「`call` 双载重等价」。
- `invoke` 的移除发生在 2026-10-22 的合入（提交 `be0d708e` 之前的上游提交），属 0.x 破坏性变更；本次只把它写进规格，消除漂移。

## 归档（全流程收尾）

| 项 | 结果 |
| --- | --- |
| 命令 | `openspec archive align-call-entry-spec --yes` |
| 增量应用 | **+0 added / ~1 modified**（`调用入口与选项` 入口名改为 `call` 双载重） |
| 归档路径 | `openspec/changes/archive/2026-10-22-align-call-entry-spec/` |
| 活动变更 | `openspec list` → `No active changes found` |
