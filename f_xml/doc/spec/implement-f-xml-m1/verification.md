# implement-f-xml-m1 验收记录

> 记录时间：2026-10-29。对应 `tasks.md` 全部勾选、`baseline.md` 的 Gate A 结果。
> 本文件随 `doc/spec/` 入库，作为可追溯的验收证据；`openspec/` 本地目录不入库。

## 1. 结果总览

| 项 | 结果 |
|---|---|
| `cjpm build` | 成功；`f_xml` 自身 20 条 WARNING，逐条记录在 `f_xml/doc/build-warnings.md` |
| `cjpm test` | **303 passed / 0 failed / 0 skipped**（`cjpm clean` 后复跑仍全绿） |
| xmlconf Gate A | `pass=2038`（含 known=0）、`fail=0`、`unsupported=524`、`observed=24` |
| 可跑集 | 2062 条，断言 2038 条；五条排除规则 313 / 95 / 59 / 47 / 10 |
| 两份 spec 副本 | `diff -ru f_xml/doc/spec/implement-f-xml-m1 openspec/changes/implement-f-xml-m1` 无输出 |
| 入库边界 | 套件与派生 JSON 在 `f_xml/.cache/xmlconf/`（`.gitignore` 命中）；仓库只有生成脚本、`known-issues.json` 与 `xmlconf-unsupported.md` |

## 2. verify 轮次

| 轮次 | 结论 | 处置 |
|---|---|---|
| 第一轮 | 2 CRITICAL（1.8 未勾、12.8 未合并）、3 WARNING、3 SUGGESTION | 1.8 改为「已移交 optimize-f-xml-char-layer」并勾选；12.8 经用户确认合并后勾选；WARNING/SUGGESTION 全部修正 |
| 第二轮 | 无 CRITICAL；P1（SpillDir 用例、Gate A 数字断言）、P2（文案口径）、P3（少量 scenario 无用例） | P1 已补 `SpillDir_test.cj` 与 harness 断言；P2 已修；P3 见 §3 |

## 3. 已知遗留（P3，不阻塞归档）

以下 scenario 的实现存在、行为已人工核对，但没有独立的自动化用例；归入后续
`optimize-f-xml-char-layer` 或按需补测：

- 四级临时目录全部失败的报错路径（`SpillDir.createFile` 的最终 throw）：需要注入文件系统
  故障才能稳定触发，当前只覆盖显式目录 / TMPDIR / 回落目录的成功路径。
- 两个解析器实例的实体计数互不影响：当前由实例字段（非全局）保证，缺并发用例。
- `xmlconf_gen.py` 的 SHA-256 不匹配分支：脚本实现存在，缺自动化（需要伪造套件）。

> **后续**：以上三项已由 `complete-f-xml-m1-followups` 全部承接并补齐用例
> （`SpillDirFallback_test.cj` / `EntityCounterIsolation_test.cj` /
> `tools/test_xmlconf_gen.py`），本节的历史结论保留不改。

## 4. 性能（已移出本变更）

事件模式实测：1 MB ≈ 1.5 s、10 MB ≈ 15.8 s；根因是字符层逐字符 `Option` 分配与三层缓冲。
按用户决策，本变更只记录现状，性能目标与 `bufSize`（R5）移交
`optimize-f-xml-char-layer` 变更。
