---
name: fountain-build-server
description: 当用户按需求文档开发 fountain 服务端应用（Controller / Service / DAO / 认证 / 定时任务）时使用；全程 OpenSpec 六步 + 严格 TDD。
---

# fountain-build-server — 按需求文档开发服务器应用（工作流 F）

## 执行步骤

**全程走 OpenSpec 六步**（步骤 1 环境与刷新 → 步骤 2 propose → 步骤 3 用户评审 → 步骤 4 apply → 步骤 5 verify → 步骤 6 archive + 落盘；展开与 CLI 对照见 `references/openspec-workflow.md`）；**开工先加载 `test-driven-development` 技能**。六步里本工作流的专属动作：

1. **步骤 1 — 环境与刷新 + 读需求**：先确保 OpenSpec 环境就绪——没装 CLI 就装、项目没初始化就 `openspec init --tools <tool>`（**`<tool>` 问用户**）、`config.yaml` 的 `context` 含「所有产出物用简体中文撰写」（细节见 openspec-workflow 第 1–2 节）→ **`openspec update`（每次开工都要先更新一次）** → `openspec list --json` 看有没有在途变更。然后拆功能点清单（接口、数据、认证、定时任务、外部调用、缓存等）；需求缺失关键信息时向用户要，不臆造。
2. **步骤 2 — 能力映射、缺口处理与 propose**：逐条把功能点映射到 fountain 模块（映射表与常见写法见 `references/server-development.md`），用 `fountain_lookup.py search` 与模块 README 核对具体 API；**特性语义与限制**（平台前提、投递语义、并发约定）用 `search "<关键词>" --in docs` 查 `<模块>/doc/`（按项目在用版本查，见 `references/common-rules.md`「定位 fountain 仓库与查询版本」）。任何功能点映射不到 fountain 能力时**停下来问用户**，给出选项：a) 用更简单的方式继续实现；b) 用户提供第三方依赖（包名或源码路径）；c) 缩减范围/不实现；d) 在项目内自行实现完整功能和要求的基础设施代码、工具代码，然后完成需求功能。不得把缺失能力硬编成假实现，不得自行引入未经验证的第三方库。结论写进 proposal / design 后执行 `opsx:propose 实现 XX 功能`（**加载 `opsx-propose` 技能**，由它生成 ssh 命令并代跑到融合开发引擎执行；本工作流后续 `opsx:*` 步骤同理，见 openspec-workflow 第 9 节）：生成 `openspec/changes/<变更名>/` 下**五件套** —— `proposal.md`、`specs/<capability>/spec.md`（规格 delta）、`design.md`、`tasks.md`、`.openspec.yaml`。**本步只产出规划产物，不改项目代码**；完成后先按约定落盘 `doc/spec/<变更名>/`，再停下等评审。
3. **步骤 3 — 用户评审（门禁）**：把 `design.md` 与 `tasks.md` 交用户逐条评审，重点确认**模块边界 / 依赖方向 / 数据模型与迁移 / 异常与错误码 / 边界场景（空值、超限、并发、重启）/ 验收判据**；按反馈用 `opsx:update`（`opsx-update` 技能）折回产物并保持一致。**用户明确确认前不进入 apply。**
4. **步骤 4 — 搭骨架 + `opsx:apply`**：先按工作流 A→B→C 安装 fboot、建 workspace、按分层建模块（业务模块 + 可选 boot 初始化模块），按工作流 D 加依赖；**生成三平台启动脚本** `boot.sh` / `boot-macos.sh` / `boot-win-gitbash.sh`（Web 型参考 `fdemo`，含 RPC 时结合 `frpcdemo`，模板选用与合并规则见 `references/launch-scripts.md`）。然后 `opsx:apply`（`opsx-apply` 技能）**逐任务 TDD 实现**：**严格跟随 `design.md` 与 `tasks.md`**，按数据模型/DAO → service → controller 推进；每个任务先写失败测试再写最小实现（Red-Green-Refactor，**REQUIRED SUB-SKILL:** `test-driven-development`），跑绿之后才勾掉任务——不允许出现「任务已勾选但没有对应测试」的进度。写法与注解见 `references/server-development.md`；实现中发现需要新的 fountain 模块，按工作流 D 随时补根 cjpm.toml 依赖。**实现与 design 冲突时不要自行改设计**——回步骤 3 问用户。
5. **步骤 5 — 构建 / 回归 / 冒烟 + `opsx:verify`**：`fboot build` 通过；跑**全量回归**（不只新用例，`cjpm test` / `fboot test`），回归失败先修再往下（delivery-workflow 第 4 节）；用启动脚本拉起应用（`./boot.sh build` → `./boot.sh run`，`--dylibPattern` 覆盖 controller、service.impl、初始化、cron 所在库）做**冒烟**（关键路径 curl / RPC 调用 + 日志无异常堆栈），按 specs / design 逐条验收接口；最后 `opsx:verify`（`opsx-verify` 技能）校验代码与规范一致（Completeness / Correctness / Coherence），**CRITICAL 未清零不往下走**；verify 不在 core 档、需先启用（启用与回退见 openspec-workflow 第 6 节）。
6. **步骤 6 — 交付 + `opsx:archive` + 落盘**：按 `references/delivery-workflow.md` 完成提交与建 tag（提交前测试全绿；tag 前提交已推送；tag 命名以用户项目规范为准）；执行 `opsx:archive`（`opsx-archive` 技能）沉淀规范、归档变更；最后用 OpenSpec 最终版**覆盖更新项目根的 `doc/spec/<变更名>/`**（四件套全量）。archive 放最后，万一还要补代码可以继续 apply。

## 前置与依赖

先完成 A→B→C→D（安装 fboot → 建 workspace → 建模块 → 加依赖）；独立使用时确认这些产物已存在，否则先加载对应技能。

## 通用规则

执行前必须读 `references/common-rules.md` 并遵守（其中与当前工作流相关的 TDD / OpenSpec / 进度报告 / SDK BUG / fboot 规则）。本技能已随包携带该文件，不依赖 `fountain-developer` 是否安装。

## 随包资源

- `references/common-rules.md`
- `references/delivery-workflow.md`
- `references/environment.md`
- `references/launch-scripts.md`
- `references/openspec-workflow.md`
- `references/opsx-waiting.md`
- `references/project-setup.md`
- `references/sdk-bug-handling.md`
- `references/server-development.md`
- `references/skill-infra.md`
- `references/common-rules.md`（通用规则）
- `scripts/fountain_lookup.py`
- `scripts/install_fboot.sh`
- `scripts/install_skill.py`
- `scripts/migrate_fountain_imports.py`
- `scripts/opsx_fusion.py`
- `scripts/opsx_progress.py`

## 完成后的汇报

报告实现摘要、测试 / 回归 / 冒烟结果、OpenSpec 变更与 `doc/spec/` 落盘；下一步通常是交付 / archive。

由 `fountain-developer` 调度时，完成后返回简明结果与下一步建议，由调度技能决定是否继续；独立使用时，按本技能流程直接交付。
