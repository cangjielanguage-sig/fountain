# Tasks

> 说明：本批次实现先行（改写点分散在四个文件），产物是补齐的；用例在实现后追加，未做到先红后绿，已在交付说明中标注。

## 1. 知识归属

- [x] 1.1 `docId` 加 `userId:namespace` 与时间戳；验证：两次执行产生两个 docId，均以 `loom:7:kb:` 开头。
- [x] 1.2 更新既有断言（原 `loom:memory-flow:1` → 动态取第一个 id）。

## 2. 策略加锁

- [x] 2.1 `install/reset/effective` 加 `Mutex` + `PolicyBox`；验证：全量回归不退化（无专测，代码审查）。

## 3. 演进归属

- [x] 3.1 `LoomWiring.evolutionOwner` + `evolutionNamespace` 默认空串；验证：policy(7,work) 未显式给 → (7,work)；显式给 → 以显式为准。

## 4. 知识租户过滤

- [x] 4.1 `SkillEvolutionJob.ownedBy` + `knowledgeOf` 过滤；验证：4 条真值（同租户/他人/他命名空间/旧格式）。
- [x] 4.2 更新既有演进用例的知识 docId 为新格式。

## 5. 提炼观测

- [x] 5.1 `extract` 异常与零写入各打 warn；验证：全量回归不退化（无日志断言，代码审查）。

## 6. 集成

- [x] 6.1 全量回归 `cd f_llm && cjpm test` 全绿（634）。
- [x] 6.2 `doc/f_llm-memory-design.md` 补 docId 格式；`doc/loom.md` 补演进归属派生。

## 未覆盖

- 演进素材 `limit=500` 与水位线推进语义（见 design 末尾）。
