---
name: fountain-configure-module
description: 当用户为现有 fountain 项目添加/修改模块依赖、运行期配置或编译期配置时使用。
---

# fountain-configure-module — 为现有项目添加 / 修改模块配置（工作流 K）

## 执行步骤

1. **定位项目与版本**：确认目标目录是 fountain workspace（根 cjpm.toml 有 `[workspace]` 与 `"fountain::f_*"` 依赖），记录 fboot 版本（`install_fboot.sh version`）——依赖版本必须与它一致。
2. **先判类别再动手**（三类载体，改法不同）：
   - **模块依赖（含功能演进）**：根 cjpm.toml `[dependencies]` 增删 `"fountain::f_xxx" = "<fboot 版本>"`；代码里新用到的模块要随时补齐（规则同工作流 D 与 `references/project-setup.md`，演进规则见 `references/delivery-workflow.md` 第 2 节）。
   - **运行期配置**：配置项以对应模块 README 为准；改启动脚本（`boot.sh` / `boot-macos.sh` / `boot-win-gitbash.sh` **三个同步改**，Windows 版写成 `--key=value`，见 `references/launch-scripts.md`）；临时验证可用 shell 环境变量。
   - **编译期配置**：`fboot build` 的 `--key=value`（嵌入产物）；改启动脚本的 `build()` 或直接给命令。
3. **改前先读现状**：保持原有依赖格式与注释，不覆盖用户已有配置；改动同名配置项时说明影响；不在模块自己的 cjpm.toml 里加依赖。
4. **验证（回归 + 冒烟）**：`fboot build` 通过 + **全量回归**绿（`cjpm test` / `fboot test`）；涉及运行期行为时做**冒烟**（起服务 + 关键路径 + 日志检查）；长驻进程交给用户 / 后台。改动记录进项目 README 或脚本注释。
5. **交付**：按 `references/delivery-workflow.md` 完成提交与建 tag（一次提交只做一类改动）。

## 前置与依赖

先完成 B（workspace 已存在）；独立使用时确认目标项目是 fountain workspace。

## 通用规则

执行前必须读 `references/common-rules.md` 并遵守（其中与当前工作流相关的 TDD / OpenSpec / 进度报告 / SDK BUG / fboot 规则）。本技能已随包携带该文件，不依赖 `fountain-developer` 是否安装。

## 随包资源

- `references/delivery-workflow.md`
- `references/environment.md`
- `references/launch-scripts.md`
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

报告改动类别（依赖 / 运行期 / 编译期）、文件与验证结果；下一步通常是构建 / 回归。

由 `fountain-developer` 调度时，完成后返回简明结果与下一步建议，由调度技能决定是否继续；独立使用时，按本技能流程直接交付。
