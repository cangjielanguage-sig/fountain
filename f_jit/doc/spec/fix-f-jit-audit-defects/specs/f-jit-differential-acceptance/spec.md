# Spec Delta

## ADDED Requirements

### Requirement: 缺陷回归覆盖与零回归门槛

差分验收 SHALL 为本次 26 条缺陷各登记一条**语义断言**用例，用例名 SHALL 含缺陷编号（P0-1 … P3-5），且断言对象为「返回值 / 错误码 / 资源计数」，SHALL NOT 只断言产物里出现某指令或某 helper。

每批次实施后 SHALL 跑 M1 + M2 + M3 全量（含差分最小集 `Interp × AArch64`），用例数与失败数 SHALL 与批次基线对照留档；任何既有用例由绿转红 SHALL 按阻塞缺陷处理，SHALL NOT 通过放宽新断言来换绿。

#### Scenario: 26 条一一对应

- **WHEN** 检查回归清单
- **THEN** 26 条缺陷各有一条用例，且每条用例的断言点在「值 / 错误码 / 计数」三类之内

#### Scenario: 失败必阻塞

- **WHEN** 任一批次出现 M1/M2/M3 既有用例转红
- **THEN** 该批次不得提交，须先定位根因

#### Scenario: 三引擎一致性

- **WHEN** 同一缺陷用例分别在解释器与 AArch64 后端执行
- **THEN** 结果逐位一致；后端不可用时显式跳过并保留 `hit` 记录

### Requirement: 断言分层与文档一致性

验收矩阵 SHALL 区分「结构断言」（产物形态、指令序列、helper 编号）与「语义断言」（执行结果、错误码、资源账目），并逐条标注；标记为语义验收的条目 SHALL 有可执行断言支撑。

规格与设计文档中的每条能力声明 SHALL 能指到实现符号；本次涉及的 `jit-bytecode-m3.md`、`design-m3.md`、`plan-m3.md` SHALL 按实现订正，无法闭环的能力 SHALL 显式登记为「已知限制」而非留在能力矩阵里。

产物镜像 SHALL 四件套齐全：`f-jit-m3`、`f-jit-m2.1`、`f-jit-m2.2`、`f-jit-m2.3` 各含 `proposal.md` / `design.md` / `tasks.md` / `specs/**`。

#### Scenario: 矩阵可核查

- **WHEN** 抽查矩阵中任意一条「语义验收」
- **THEN** 能找到对应的可执行用例与断言点

#### Scenario: 文档无悬空声明

- **WHEN** 抽查文档中关于 H80 的 14 语义、句柄 tag、窗口记账、deadline 接线的声明
- **THEN** 每条都能指到实现符号；未接线的能力在文档里显式标注

#### Scenario: 镜像完备

- **WHEN** 检查 `f_jit/doc/spec/` 下 M3 与 M2.1–M2.3 目录
- **THEN** 四件套齐全，无「只有 specs」的变更
