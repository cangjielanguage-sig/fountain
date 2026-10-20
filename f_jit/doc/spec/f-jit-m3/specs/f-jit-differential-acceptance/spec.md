# Spec Delta

## ADDED Requirements

### Requirement: M3 差分矩阵与零回归门槛

M3 SHALL 建立并维护下列验收项，每项 SHALL 有可执行用例与映射条目：**T37** 装箱/拆箱往返（全可转集、值型逐位、引用型同对象、null → 19、typecode 防御 8/99、容器元素自动装箱）、**T38** is/as 语义（命中/未命中/集合外、22 与 7 边界对拍、静态路径免 helper、禁止面编译错误、hwCap 对账）、**T39** 异构容器端到端（`List<Any>` / `Map<String,Any>` / `Map<Int64,Any>`、容器转型校验、宿主往返、无泄漏）、**T40** 对账（deopt 重放、装箱 churn、GC 并发、跨线程只读盒）、**T41** JSON 字面量（黄金值、一次解析、双层拒绝、跨桥）、**T56** 特化（双路径逐位对拍、构建计数、失效面、argc 边界）、**T61** JSON 世界内可变 API 与内建码（读写、frozen 传播、点号/下标糖、零注册）。

每项 SHALL 在三引擎（解释器 / x86_64 / AArch64）上给出结果、错误码与 site 三者全等的证据。M1 与 M2 的全部既有验收项与产物 SHALL 保持零回归；任何逐位差异按阻塞缺陷处理，不得以「M3 新语义」为由豁免。验收矩阵 SHALL 以 `doc/spec/f-jit-m3/` 的增量镜像 + `scenario-map.tsv` 登记，未覆盖的 scenario SHALL 显式标 GAP，不得静默。

#### Scenario: 七项验收齐备

- **WHEN** 检查 M3 的验收清单
- **THEN** T37–T41、T56、T61 各有对应用例与矩阵条目，无缺项

#### Scenario: 三引擎全等

- **WHEN** 以同一批确定性数据（值型、基础引用型、异构容器、JSON 常量）跑三引擎
- **THEN** 结果、错误码、site 逐位一致（22 含调用点）

#### Scenario: M1/M2 零回归

- **WHEN** 在 M3 全部改动落地后重跑 M1 与 M2 的验收项与差分
- **THEN** 全部通过，且同类源单元的产物与 M3 之前逐位相同

#### Scenario: 缺口如实登记

- **WHEN** 某 scenario 尚无对应用例（如 Layer C 未引入）
- **THEN** 矩阵中标为 GAP 并在 `verify.md` 说明，不得记为 full
