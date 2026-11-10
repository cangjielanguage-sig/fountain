# Tasks

> 全程 TDD：先红后绿；公开 API 变化同步 README 中英。

## 1. 依赖与开关

- [ ] 1.1 `f_llm/cjpm.toml` 增加 `fountain::f_a2a`；验证：`cjpm build` 通过。
- [ ] 1.2 `LLMConfig.a2aEnabled()`（键 `llm_a2aEnabled`，默认 false）；验证：未设 → false，设 true → true，非法值 → false。

## 2. 服务端桥

- [ ] 2.1 `SupervisorAgent <: A2aExecutor`：`dispatch` → 四态映射；验证：`dispatched`/`clarifying`/`noUsableFlow` 三条用例。
- [ ] 2.2 `LoomA2a.startIfEnabled()`：关时不注册（方法表 0 条）、开时注册（9 条）、重复调用只生效一次；验证：3 条用例。
- [ ] 2.3 卡片内容：名称/描述来自配置，`url` 指向 `/rpc/a2a`；验证：序列化断言。

## 3. 客户端

- [ ] 3.1 `LoomA2aClient.ask(url, text)`：send → 取产物正文；空产物报错；协议错误码透传；验证：3 条用例（注入调用函数）。

## 4. 工具

- [ ] 4.1 `a2aCall` 工具（`url` / `text`）：成功返回正文、`url` 缺失返回可读错误、异常转文本；验证：3 条用例。

## 5. 文档

- [ ] 5.1 `f_llm/README.md` / `README_en.md` 增加 A2A 小节（开关、端点、工具）。
- [ ] 5.2 `f_llm/doc/loom.md` 记录映射表与「默认关闭」。

## 6. 集成

- [ ] 6.1 `cd f_llm && cjpm test` 全绿（基线 656）。
- [ ] 6.2 `openspec validate add-loom-a2a --strict` 通过。

## Workflow follow-up

- 归档 `add-loom-a2a` → 覆盖 `f_llm/doc/spec/add-loom-a2a/` 四件套。
