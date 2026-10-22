---
name: fountain-develop-framework
description: 当开发对象就是 fountain 仓库自身（修改 `f_*` 模块、加功能、修缺陷、新建模块）时使用；全程 OpenSpec 六步 + 严格 TDD。
---

# fountain-develop-framework — 在 fountain 仓库内开发（工作流 J）

## 执行步骤

**适用**：当前正在开发的项目就是 fountain 仓库——根 cjpm.toml 的包名是 `fountain`、`fountain::f_*` 依赖全是 `{path = "./f_xxx"}` 形态，仓库里有 `.modules` 与各 `f_*` 模块目录；此时被开发的对象就是框架自身（加功能 / 修缺陷 / 新建模块），产出是框架源码的改动。**仓库内查询不加 `--version` 即读工作区源码**（path 依赖没有版本号、脚本不需要切文档副本；输出头部标注源码版本与分支 / tag）。

**全程走 OpenSpec 六步**（新建模块、加功能、修缺陷一律；纯内部修复可在 `.openspec.yaml` 里用 `skip_specs: true` 跳过规格文件，但六步流程照走；展开见 `references/openspec-workflow.md`）；**开工先加载 `test-driven-development` 技能**（**REQUIRED SUB-SKILL:**）。

1. **步骤 1 — 环境与刷新 + 先复用再实现**：`openspec update` + `openspec list --json`。动手写代码前，把要用到的能力逐条在仓库里查证有没有现成实现，命中即用：
   - 查证链路：`fountain_lookup.py modules` → `search "<能力关键词>"` → 模块 README → `api <模块>` → 读 `src/` 核对签名；
   - 现有模块能满足的**不重复造轮子**（异常体系、日志、工具函数、集合扩展、时间换算、编解码等，先按 `references/module-index.md` 对号入座再现场核对，不按记忆猜）；
   - 新增代码遵守仓库既有约定：包与目录结构、可见性、测试布局都参照同层既有代码；README 中英成对同步。
2. **步骤 2 — 缺口处理与 propose**：fountain 现有 API 不能满足需求时**停下来问用户**，给出几个建议并询问接下来如何做，等用户拍板再动手——**不擅自新造公开 API、不硬编假实现、不悄悄引入第三方依赖**：
   - 每条建议写清代价与影响面（是否动公开 API、是否破坏兼容、影响哪些调用方、测试与文档成本）；公开 API 变更宁保守（能加参数 / 重载就不改既有签名）；
   - 典型候选：a) 扩展现有模块（哪个模块、加什么 API 的签名草案）；b) 新建模块（职责边界与发布登记；聚合根包与 `src/<模块>` shim 已冻结，新模块不登记进去）；c) 改用仓颉标准库 / stdx 的现成能力（不新增 fountain API）；d) 在目标模块内部实现（不公开，仅本次需求用）；e) 缩减范围或调整需求；
   - 未拍板前不写实现代码。
   - 拍板后执行 `opsx:propose`（新建模块：职责 + 对外 API 草案；加功能 / 修缺陷：行为变化与规格 delta），生成五件套（**只写规划产物**），完成后**落盘到相应模块的 `doc/spec/<变更名>/`**（跨多个模块时各模块放其 `spec.md`，`proposal.md` / `design.md` / `tasks.md` 放主模块），停下等评审。
3. **步骤 3 — 用户评审（门禁）**：把 `design.md` / `tasks.md` 交用户逐条评审——**新建模块**重点：模块职责边界、公开 API 签名、与既有模块的依赖方向、`.modules` 发布登记、README 中英同步、边界场景与兼容性；**既有模块改动**重点：兼容性（是否动公开 API、破坏调用方）、测试与文档影响。反馈用 `opsx:update` 折回产物并保持一致。**用户明确确认前不进入 apply。**
4. **步骤 4 — `opsx:apply`（逐任务 TDD）**：严格跟随 design / tasks（新建模块的目录 / 包结构 / 测试布局以 design 为准，既有约束 `[detention]`、聚合根 shim 冻结不破）；先写失败用例（Red）→ 最小实现（Green）→ 重构（Refactor）；用例放语义所属的层 / 包；**跑绿才勾任务**——不许出现「任务已勾选但没有对应测试」的假进度；公开 API 变化同步该模块 README（中英成对）；实现与 design 冲突时回步骤 3 问用户，不自行改设计。
5. **步骤 5 — 回归 + `opsx:verify`**：受影响模块 + 全量 `cjpm test` 全绿再提交；涉及 fboot / 应用启动链的改动按 `references/delivery-workflow.md` 第 5 节做冒烟；最后 `opsx:verify`，**CRITICAL 未清零不往下走**（启用与回退见 openspec-workflow 第 6 节）。
6. **步骤 6 — 交付 + `opsx:archive` + 落盘**：提交与建 tag 按 delivery-workflow 第 6 / 7 节；fountain 自身的升版（各 `cjpm.toml` + `f_version/src/FountainVersion.cj`）与发布文档同步按仓库既有发布流程；执行 `opsx:archive` 归档；最后用最终版**覆盖更新相应模块的 `doc/spec/<变更名>/`**（四件套全量）。仓库里可能有其他会话的并行工作线（`.worktrees/` 工作树与分支）——只操作自己的，不 prune、不删除任何工作树与分支。

## 前置与依赖

无强制前置；当前目录必须是 fountain 仓库自身（根 cjpm.toml 包名 `fountain`、依赖为 path 形态）。

## 通用规则

执行前必须读 `references/common-rules.md` 并遵守（其中与当前工作流相关的 TDD / OpenSpec / 进度报告 / SDK BUG / fboot 规则）。本技能已随包携带该文件，不依赖 `fountain-developer` 是否安装。

## 随包资源

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

报告框架改动、测试 / 回归结果、OpenSpec 变更与发布注意项；下一步通常是交付 / archive。

由 `fountain-developer` 调度时，完成后返回简明结果与下一步建议，由调度技能决定是否继续；独立使用时，按本技能流程直接交付。
