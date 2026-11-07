# Tasks

## 1. 经验 kind 常量

- [x] 1.1 `MemoryKinds` 增加 `EXPERIENCE` / `EXPERIENCE_FAILED`，纳入 `predefined()`，`weightOf` 显式返回 0.8；验证：`predefined()` 含两者、权重 0.8（先失败）。
- [x] 1.2 `LoomMemoryPolicy` / `LoomStoreGateway` / `SkillEvolutionJob` 的 kind 字面量改用常量；验证：全量回归不退化。

## 2. remember 走网关

- [x] 2.1 `Memory.remember` 增加 `namespace!` / `kind!`（默认 loom / session），优先 `LoomHostApi.callStore`；验证：装计数网关后调用，payload 含 `"namespace":"loom"`、`"kind":"session"`（先失败）。
- [x] 2.2 自定义 namespace/kind 透传；验证：`namespace:'work', kind:'note'` 出现在 payload。
- [x] 2.3 未装配时回落适配器；验证：不抛异常且返回正常。

## 3. 集成验证

- [x] 3.1 全量回归 `cd f_llm && cjpm test` 全绿（基线 604）。
- [x] 3.2 `doc/f_llm-memory-design.md` 的「三条写入路径」补一句：`Memory.remember` 默认命名空间为 `loom`。

## Workflow follow-up

- `openspec validate --strict` → 归档 → 覆盖 `f_llm/doc/spec/fix-memory-write-consistency/`。
