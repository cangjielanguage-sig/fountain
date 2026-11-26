# Tasks

## 1. 经验列表的 kind 强制

- [x] 1.1 `LoomStoreGateway` 的 `list` 改用 `kindOf(args, defaultKind)`；验证：同一用户下写一条 `note` + 一条 `experience`，`loomStore("experience","list")` 只返回经验（先失败）。
- [x] 1.2 显式 `kind` 优先：`loomStore("experience","list",{kind:"note"})` 返回 note（保持 `search` 的既有语义）。

## 2. 人格的无正文判定

- [x] 2.1 `default` 视为无正文（与 `custom` 同处理）；验证：`persona='default'` 时 system 等于步骤自身 system，不含 `default` 字样。
- [x] 2.2 提示词 `content` 为空时下沉；验证：库里有空条目 + 内置 key → 注入内置正文。
- [x] 2.3 空条目 + 未知 key → 回落字面文本（第三级语义不变）。
- [x] 2.4 `custom` 行为回归：仍只取 `character.prompts`。

## 3. 集成验证

- [x] 3.1 全量回归 `cd f_llm && cjpm test` 全绿（基线 595）。
- [x] 3.2 `doc/loom.md` 的人格解析小节补一句「`default` 与空 content 都表示本级无正文」。

## Workflow follow-up

- `openspec validate --strict` → 归档 → 覆盖 `f_llm/doc/spec/fix-loom-experience-persona/`。
