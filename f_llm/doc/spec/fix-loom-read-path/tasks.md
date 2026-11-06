# Tasks

## 1. 经验检索覆盖失败经验

- [x] 1.1 `search` / `list` 未给 kind 时，experience 展开为 `experience` + `experience_failed`；验证：两类各写一条，检索不指定 kind 时两条都在（先失败）。
- [x] 1.2 显式 kind 优先；验证：传 `kind:"experience"` 只返回成功经验。

## 2. 分页缺省

- [x] 2.1 `memory.list` 缺 `limit` 时返回数据而非空数组；验证：写 3 条、不传 limit，断言 3 条（先失败）。
- [x] 2.2 `knowledge.docIds` 同样；验证：写 2 个文档、不传 limit，断言 2 个 id。
- [x] 2.3 `limit:0` 按缺省 50 处理；验证：同上用例传 `limit:0` 仍返回数据。

## 3. jit 占位符

- [x] 3.1 `LoomCompiler` 对 jit 源码里的 `{…}` 抛 `LoomException`；验证：`{start.output}` 的 jit 计划编译失败且错误含 `jit` 与 `template`（先失败）。
- [x] 3.2 回归：不含占位符的 jit 步骤照常编译执行。

## 4. 集成验证

- [x] 4.1 全量回归 `cd f_llm && cjpm test` 全绿（基线以当前为准），无新增失败。
- [x] 4.2 `doc/loom.md` 网关 op 表与 jit 小节同步这三条行为。

## Workflow follow-up

- `openspec validate --strict` → 归档 → 覆盖 `f_llm/doc/spec/fix-loom-read-path/`。
