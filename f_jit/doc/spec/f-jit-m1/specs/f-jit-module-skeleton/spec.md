# Spec Delta

## Purpose

定义 `f_jit` 模块的物理骨架：包划分与依赖方向、构建配置，以及「构建通过、测试可跑」的可回归基线（模块独立构建，不登记根 `cjpm.toml`）。

## ADDED Requirements

### Requirement: 六包结构与单向依赖

模块 SHALL 由根包 `fountain::f_jit` 与 `base`、`bytecode`、`compiler`、`runtime`、`backend` 五个子包组成，依赖 SHALL 只能向下（`base` 不依赖模块内任何包，`bytecode` 只依赖 `base`，三个生产/消费包互不依赖，根包可依赖全部），禁止任何包间环。

#### Scenario: 包目录齐备

- **WHEN** 检视 `f_jit/src`
- **THEN** 存在 `Root.cj`（根包）与 `base/`、`bytecode/`、`compiler/`、`runtime/`、`backend/` 五个包目录，每包有包声明文件

#### Scenario: 无环约束

- **WHEN** 检视各包的 import 清单
- **THEN** `base` 不 import 模块内任何包；`bytecode` 只 import `base`；`compiler`/`runtime`/`backend` 彼此不 import；跨包共享声明一律经 `base`/`bytecode` 以 `protected` 暴露

### Requirement: 差分测试层为独立目录

模块 SHALL 提供 `src/test/diff` 作为三引擎逐位对拍的独立测试层，且该层 SHALL 只承载跨引擎一致性断言，不承载单层语义断言。

#### Scenario: 差分层就位

- **WHEN** 检视 `f_jit/src/test/diff`
- **THEN** 该目录存在且为独立包，用例只引用 `protected`/`public` 可见面，不依赖各包 `internal` 声明

### Requirement: 构建配置与依赖声明

`f_jit/cjpm.toml` SHALL 声明 `name=f_jit`、`organization=fountain`、`output-type=dynamic`、版本跟随仓库，并在 `[dependencies]` 中声明 `fountain::f_base`、`fountain::f_regex`、`fountain::f_util`（`Crc32` 与 `Fnv`）；M3 才追加 `fountain::f_data`。

#### Scenario: 依赖可被解析

- **WHEN** 在融合开发环境执行 `cjpm build`
- **THEN** 三个依赖均被解析并成功构建，无缺失依赖报错

#### Scenario: 多目标编译选项齐备

- **WHEN** 检视 `cjpm.toml` 的 `[target.*]` 段
- **THEN** 覆盖 Linux（x86_64/aarch64）、Windows、macOS、HarmonyOS 目标的编译与链接选项，与仓库其它模块保持同一写法

### Requirement: 构建与测试基线可回归

骨架 SHALL 满足「`cjpm build` 通过、`cjpm test` 可执行且 0 用例失败」的基线，作为后续每步 TDD 的起点；根 `cjpm.toml` **不登记** `f_jit`（用户裁定），验收以模块自身目录为准。

#### Scenario: 空基线通过

- **WHEN** 在骨架完成后于 `f_jit` 模块目录执行 `cjpm build` 与 `cjpm test`
- **THEN** 构建成功、测试进程正常退出且无失败用例

#### Scenario: 基线数字留档

- **WHEN** 记录骨架基线
- **THEN** 构建结果与用例计数被写进变更记录（供后续步骤对照「用例数单调增长、失败数为 0」）
