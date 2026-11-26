# Tasks

## 1. 构造计数

- [x] 1.1 `LoomStoreGateway` 增加包内 `buildCount` 与 `resetBuildCount()`，两个构造各 +1；验证：新建两个实例后计数为 2（先失败）。

## 2. 装配期单实例

- [x] 2.1 `LoomWiring.wire` 增加 `gateway!: ?LoomStoreGateway = None`，装配期建一次并复用；验证：`resetBuildCount()` → `wire()` → `callStore` 三次 → 计数仍为 1。
- [x] 2.2 `SkillEvolutionJob.load` 的装配路径传同一个网关；验证：装配（含 evolutionCron）后计数不因演进注册而增加。

## 3. 工具与网关同源

- [x] 3.1 `memoryCall` 未注入网关时走 `LoomHostApi.callStore`；验证：装一个计数函数后调用，计数 +1（而非新建网关）。
- [x] 3.2 `knowledgeIngest` 同上；验证：同一计数函数被调用。
- [x] 3.3 未装配时回落自建；验证：`LoomHostApi.resetStore()` 后调用仍返回结果、不抛「未安装」。

## 4. 集成验证

- [x] 4.1 全量回归 `cd f_llm && cjpm test` 全绿（基线 600）。
- [x] 4.2 `doc/loom.md` 的「装配」小节补一句「网关在装配期创建一次，三类入口共用」。

## Workflow follow-up

- `openspec validate --strict` → 归档 → 覆盖 `f_llm/doc/spec/fix-loom-store-gateway-reuse/`。
