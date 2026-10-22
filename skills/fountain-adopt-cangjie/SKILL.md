---
name: fountain-adopt-cangjie
description: 当用户要把非 fountain 的仓颉项目改造成 fountain 风格（拆 main、替换 HTTP / DB / 日志 / 配置 / 定时能力）时使用；全程 OpenSpec 六步 + 严格 TDD。
---

# fountain-adopt-cangjie — 非 fountain 仓颉项目 → fountain 风格（工作流 H）

## 执行步骤

输入：用户当前的仓颉项目（cjpm 项目、不依赖 fountain，可能带 `main()` / executable）。
先判断：改造目标是服务端应用才适合 fountain 风格；纯 CLI / 库项目先与用户确认必要性。

**全程走 OpenSpec 六步**（展开见 `references/openspec-workflow.md`）；**开工先加载 `test-driven-development` 技能**（**REQUIRED SUB-SKILL:**），能力替换逐类按 Red-Green-Refactor 推进。与工作流 F / G / I / K 一样，本工作流覆盖**完整交付流程**（初始化 → 配置 → 严格 TDD → 回归 + 冒烟 → 提交 → 建 tag），通用门禁见 `references/delivery-workflow.md`。

1. **步骤 1 — 环境与刷新 + 评估现状（只读）**：`openspec update` + `openspec list --json`；看 cjpm.toml（`output-type`、dependencies）、src 布局、`main()` 入口、现有能力（HTTP / DB / 日志 / 配置 / 定时）来自 stdx 还是手写。
2. **步骤 2 — 映射、缺口与 propose**：原能力 → fountain 模块（`references/module-index.md` 速查，映射参考 `references/cangjie-to-fountain.md`）；缺口按 `fountain-build-server`（工作流 F）步骤 2 的 a–d 处理（简化实现 / 第三方依赖 / 缩减范围 / 项目内实现）；映射与改造计划写进 proposal / design，执行 `opsx:propose` 生成五件套（**只写规划产物**），完成后落盘 `doc/spec/<变更名>/`，停下等评审。
3. **步骤 3 — 用户评审（门禁）**：把 `design.md` / `tasks.md` 交用户评审，重点确认**模块拆分、`main()` 拆解方案、能力替换顺序与兼容性、验收判据**；反馈用 `opsx:update` 折回。**未确认不进 apply。**
4. **步骤 4 — 骨架 + `opsx:apply` 能力替换**：`fboot workspace <新目录>` + `fboot module <模块名>` 建骨架（合规前提：workspace 与模块只能用 fboot 创建），把原源码用 `git mv`（保留历史）或拷贝进对应模块 `src/`（不删用户原文件，原目录处理与用户确认）；按工作流 D 加依赖；拆 `main()`（初始化搬进 boot 模块，业务按包分层，去掉 executable 入口）；逐类替换能力：HTTP → `f_mvc` 注解式 Controller；手写 SQL / 连接池 → `f_orm`（配置迁到 `orm_*`）；日志 → `f_log`；配置 → `f_config` / 环境变量；定时 → `f_ticktock`——每类 Red-Green-Refactor（先失败测试 → 最小实现 → 重构），跑绿才勾任务。
5. **步骤 5 — 回归 + 冒烟 + `opsx:verify`**：批次末跑**全量回归**（`cjpm test` / `fboot test`）；启动冒烟（关键路径 + 日志检查，delivery-workflow 第 5 节）；对照原项目行为逐项验证，输出改造报告（映射、缺口、未实现、启动方式）；`opsx:verify` CRITICAL 清零。
6. **步骤 6 — 交付 + `opsx:archive` + 落盘**：按 `references/delivery-workflow.md` 完成提交与建 tag（提交前单元测试 / 回归 / 冒烟全绿；tag 前提交已推送）；执行 `opsx:archive` 归档；最后覆盖更新项目根的 `doc/spec/<变更名>/`（四件套全量）。

## 前置与依赖

先完成 A→B→C→D；独立使用时确认目标项目的 workspace / 模块已就绪。

## 通用规则

执行前必须读 `references/common-rules.md` 并遵守（其中与当前工作流相关的 TDD / OpenSpec / 进度报告 / SDK BUG / fboot 规则）。本技能已随包携带该文件，不依赖 `fountain-developer` 是否安装。

## 随包资源

- `references/cangjie-to-fountain.md`
- `references/delivery-workflow.md`
- `references/environment.md`
- `references/module-index.md`
- `references/openspec-workflow.md`
- `references/opsx-waiting.md`
- `references/project-setup.md`
- `references/sdk-bug-handling.md`
- `references/skill-infra.md`
- `references/common-rules.md`（通用规则）
- `scripts/fountain_lookup.py`
- `scripts/install_fboot.sh`
- `scripts/install_skill.py`
- `scripts/migrate_fountain_imports.py`
- `scripts/opsx_fusion.py`
- `scripts/opsx_progress.py`

## 完成后的汇报

报告改造后的模块结构、能力替换、回归 / 冒烟结果；下一步通常是交付 / archive。

由 `fountain-developer` 调度时，完成后返回简明结果与下一步建议，由调度技能决定是否继续；独立使用时，按本技能流程直接交付。
