# Verify

## 范围

纯规格/文档变更，**无代码改动**（`git diff -- f_jit/src` 为空），因此不跑测试套件；
验证以规格一致性与校验器为准。

## 一致性检查

| 检查 | 结果 |
| --- | --- |
| 主规格 `f-jit-facade-bridge` 的 `unloadFn` / `unload(` | 0 处 |
| 主规格「统一调用包装」与代码 `close(timeoutMs)` / `close()` / `isClosed()` | 逐条对应 |
| `design-m2.md` 的 `unloadFn` / `prop isClosed` | 0 处 |
| `design-parallel-call.md` 的 `unloadFn` / `unload(` | 0 处 |
| README / README_en | 本就使用 `close`，0 处旧名 |
| 历史归档 `refine-f-jit-unload-api` / `jit-closure-unload-cascade` | 保留旧名（按归档惯例，不回改） |

## 校验器

```text
openspec validate align-jitfunction-close-naming --strict
openspec validate --all
```

| 项 | 结果 |
| --- | --- |
| 变更严格校验 | 通过 |
| 全量规格校验 | **9 passed / 0 failed**（4 条 >500 字符警告为历史遗留，非本变更引入） |
| 归档 | `2026-11-26-align-jitfunction-close-naming`（主规格在归档前已同步，故增量 0/0） |

## 未做

- 不引入 `unloadFn`/`unload` 别名（方案 A 的明确取舍）；
- 不改 M1 历史设计文档（`design-m1.md`、`jit-bytecode-m1.md`）中的 `unload(timeout)`。
