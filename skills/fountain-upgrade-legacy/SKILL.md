---
name: fountain-upgrade-legacy
description: 当用户要把 SDK 1.0.x + fountain 1.0.x 的既有项目升级到与当前 fboot 同版 fountain 时使用；全程 OpenSpec 六步 + 严格 TDD。
---

# fountain-upgrade-legacy — 旧版本项目升级（工作流 I）

## 执行步骤

输入是已跑起来的**老项目**（SDK 1.0.x + fountain 1.0.x：模块 `cjc-version = "1.0.4"`，源码里是聚合根
`import fountain.mvc.*` 或扁平 `import f_mvc.*`）。产出默认是**同一项目就地升级**（保留 git 历史）到
「fountain 依赖版本 = 当前 fboot 版本」；不改技术栈、不重写业务。完整展开见 `references/legacy-upgrade.md`。

**全程走 OpenSpec 六步**（展开见 `references/openspec-workflow.md`）；**开工先加载 `test-driven-development` 技能**（**REQUIRED SUB-SKILL:**）；升级属高风险改动，API 适配与行为修复都先落失败用例再改代码。

1. **步骤 1 — 环境对齐与刷新（先做）**：工作流 A 安装 / 配置当前 fboot——`fboot version` 定目标版本号（它就是待写入的依赖版本）；把 SDK / stdx 换到与 fboot 匹配的版本（老项目 `cjc-version = "1.0.4"` 对不上当前 fountain 的 `"1.2.0"`），不换的话后面全是假错误；`openspec update` + `openspec list --json`；**现状评估（只读）**：依赖形态（聚合根 path / git）、各模块 `cjc-version`、`import fountain.*` / `import f_*` 去重出的模块清单（= 升级后要声明的 `fountain::f_*`）、`boot.sh` 的配置项清单、第三方依赖写法（legacy-upgrade 第 2 节表）。
2. **步骤 2 — 缺口处理与 propose**：升级范围、硬差异清单（见 legacy-upgrade 第 4.3 节）与适配 / 测试计划写进 proposal / design；执行 `opsx:propose 升级 XX 项目到 fountain <版本>` 生成五件套（**只写规划产物**），完成后落盘 `doc/spec/<变更名>/`，停下等评审。
3. **步骤 3 — 用户评审（门禁）**：把 `design.md` / `tasks.md` 交用户评审，重点确认**升级范围、兼容性影响（公开 API / 行为变化）、分批适配顺序、验收判据（对照老行为）**；反馈用 `opsx:update` 折回。**未确认不进 apply。**
4. **步骤 4 — `opsx:apply`：依赖与代码适配**：默认**就地升级**——把聚合根依赖换成按模块版本依赖 `"fountain::f_xxx" = "<fboot 版本>"`，`[target]` 段补齐 `${CANGJIE_STDX_PATH}`，模块 `cjc-version` 同步；用 `fboot workspace` 在临时目录生成一份新产物逐段对照（产物样例见 `references/project-setup.md`）。先 `python <skill-root>/scripts/migrate_fountain_imports.py <项目根>`（预演确认后 `--apply`）把包名 import 机械改掉（**单独一个提交**）；再 `fboot build` 逐条修 API，每个点用 `fountain_lookup.py --version <老项目在用版本>` 与目标版本**两版对照**查证（老版本号读老项目依赖的 fountain 源码 `f_version/src/FountainVersion.cj`；1.0.x 的 tag 名与版本标记不总相等，见 legacy-upgrade 第 4.2 节）。已知硬差异见 legacy-upgrade 第 4.3 节：AOP `InvocationFuncInfo` class→struct、连接池迁到 `fountain::f_dbpool.DatabasePool`（`init(driver, ds)` 已删）、第三方依赖新写法、新增模块可换用、fboot 子命令变化。每类适配先写失败用例再改代码。
5. **步骤 5 — 配置 / 启动脚本 + 回归 + 冒烟 + `opsx:verify`**：按 `references/launch-scripts.md` 补齐 / 对齐三平台脚本——老脚本是**库路径后插**（`undefined symbol` 的根因）、通常只有 Linux 版、编译期配置靠环境变量；老 `export` 清单里的配置项逐个用**目标版本**的模块 README 核对。版本升级属**高风险改动**（`references/delivery-workflow.md` 第 4 节）——针对性回归 + 全量回归 + 冒烟（起服务 + 关键路径 + 日志）；最后 `opsx:verify`，**CRITICAL 未清零不往下走**。
6. **步骤 6 — 交付 + `opsx:archive` + 落盘**：提交按「依赖 / 机械 import / API 适配」分粒度；按 delivery-workflow 第 6 / 7 节提交与建 tag；交付升级报告（旧 → 新对照表 + 行为变化 + 未适配项）；执行 `opsx:archive` 归档；最后覆盖更新项目根的 `doc/spec/<变更名>/`（四件套全量）。

## 前置与依赖

先完成 A（`fountain-install-fboot`）并把 SDK / stdx 对齐；独立使用时先确认目标版本。

## 通用规则

执行前必须读 `references/common-rules.md` 并遵守（其中与当前工作流相关的 TDD / OpenSpec / 进度报告 / SDK BUG / fboot 规则）。本技能已随包携带该文件，不依赖 `fountain-developer` 是否安装。

## 随包资源

- `references/delivery-workflow.md`
- `references/environment.md`
- `references/launch-scripts.md`
- `references/legacy-upgrade.md`
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

报告升级前后版本、适配点、回归 / 冒烟结果与未适配项；下一步通常是交付 / archive。

由 `fountain-developer` 调度时，完成后返回简明结果与下一步建议，由调度技能决定是否继续；独立使用时，按本技能流程直接交付。
