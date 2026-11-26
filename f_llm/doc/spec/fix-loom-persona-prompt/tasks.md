# Tasks

## 1. 人格归属

- [x] 1.1 新增 `LoomCharacterScope`（install/current/reset）；`LoomRunner` 优先取它；验证：policy.userId=0 + scope=9 + character(9, rigorous) → system 含内置正文（先失败）。
- [x] 1.2 `LoomWiring.wire(characterUserId!)` 安装 scope；验证：wire 后 `LoomCharacterScope.current()==Some(9)`。

## 2. 技能回落

- [x] 2.1 判据改为「解析结果为空」；验证：`run(skills:['不存在的技能'])` 仍注入自动检索到的技能（先失败）。

## 3. 提示词版本

- [x] 3.1 `prompt.get(version<=0)` 走 latest；验证：v1/v2 存在时返回 v2（先失败）。
- [x] 3.2 `prompt.remove(version<=0)` 抛错；验证：抛 `LoomException` 且信息含 `version`。

## 4. 提炼记录

- [x] 4.1 `LoomHostApi` 记录步骤 system；验证：persona=「严格」时落库记忆不含「严格」（先失败）。

## 5. 集成

- [x] 5.1 全量回归 `cd f_llm && cjpm test` 全绿（基线 625）。
- [x] 5.2 `doc/loom.md` 人格小节补「character 归属用 `characterUserId`」；网关表补 `prompt.get/remove` 的版本语义。

## Workflow follow-up

- `openspec validate --strict` → 归档 → 覆盖 `f_llm/doc/spec/fix-loom-persona-prompt/`。
