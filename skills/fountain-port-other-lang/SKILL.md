---
name: fountain-port-other-lang
description: 当用户要把 Python / Java / Go / Node / TS 等项目转换或迁移为仓颉 fountain 项目时使用；全程 OpenSpec 六步 + 严格 TDD。
---

# fountain-port-other-lang — 其他语言项目 → 仓颉项目（工作流 G）

## 执行步骤

输入为本地路径或 git 链接；产出为**独立的新 fountain 项目**，不改原仓库。

**全程走 OpenSpec 六步**（在**产出项目根**初始化 OpenSpec 并执行；展开见 `references/openspec-workflow.md`）；**开工先加载 `test-driven-development` 技能**（**REQUIRED SUB-SKILL:**），全程按 Red-Green-Refactor 推进。

1. **步骤 1 — 环境与刷新 + 取源码与侦察**：`openspec update` + `openspec list --json`；git 链接 clone 到新目录（本地路径只读分析）；读原项目结构与关键文件，产出「原功能 → fountain 模块」映射表与缺口清单（侦察清单与映射表见 `references/porting-guide.md`）。
2. **步骤 2 — 缺口处理与 propose**：缺口按 `fountain-build-server`（工作流 F）步骤 2 的 a–d 选项处理（简化实现 / 第三方依赖 / 缩减范围 / 项目内实现）；映射、缺口与分期转换计划写进 proposal / design，执行 `opsx:propose 把 XX 项目转换为仓颉 fountain 项目` 生成五件套（**只写规划产物**），完成后落盘 `doc/spec/<变更名>/`，停下等评审。
3. **步骤 3 — 用户评审（门禁）**：把 `design.md` / `tasks.md` 交用户评审，重点确认**模块划分与原项目分层的对应、缺口方案（a–d）、分期计划、验收判据（对照原项目行为）**；反馈用 `opsx:update` 折回。**未确认不进 apply。**
4. **步骤 4 — 搭骨架 + `opsx:apply` 分批转换**：工作流 A→B→C→D 建新项目，模块划分对齐原项目分层；生成三平台启动脚本（同 `fountain-build-server`（工作流 F）步骤 4，见 `references/launch-scripts.md`）；按「数据模型 → 数据访问 → 业务逻辑 → 接口层 → 定时/异步任务」顺序逐批转换——每批按 Red-Green-Refactor 补测试（先失败测试再实现），批次末跑**全量回归** + `fboot build`，跑绿才勾任务；发现需要新模块时按工作流 D 补依赖。
5. **步骤 5 — 冒烟 + 回归 + `opsx:verify`**：启动做**冒烟**（关键路径）后，对照原项目行为逐项验证；`opsx:verify` 校验代码与规范一致，**CRITICAL 未清零不往下走**；输出转换报告（对应关系、缺口、未实现项），见 `references/porting-guide.md`。
6. **步骤 6 — 交付 + `opsx:archive` + 落盘**：按 `references/delivery-workflow.md` 完成提交与建 tag；执行 `opsx:archive` 归档；最后覆盖更新**产出项目根**的 `doc/spec/<变更名>/`（四件套全量）。

## 前置与依赖

先完成 A→B→C→D；独立使用时确认产出项目的骨架与依赖已就绪。

## 通用规则

执行前必须读 `references/common-rules.md` 并遵守（其中与当前工作流相关的 TDD / OpenSpec / 进度报告 / SDK BUG / fboot 规则）。本技能已随包携带该文件，不依赖 `fountain-developer` 是否安装。

## 随包资源

- `references/delivery-workflow.md`
- `references/environment.md`
- `references/launch-scripts.md`
- `references/openspec-workflow.md`
- `references/opsx-waiting.md`
- `references/porting-guide.md`
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

报告转换后的项目路径、模块映射、缺口与验证结果；下一步通常是交付 / archive。

由 `fountain-developer` 调度时，完成后返回简明结果与下一步建议，由调度技能决定是否继续；独立使用时，按本技能流程直接交付。
