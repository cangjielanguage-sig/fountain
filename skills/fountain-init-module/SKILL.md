---
name: fountain-init-module
description: 当用户要求新建 fountain 模块、把模块加入 workspace members，或 `fboot module` 失败时使用。
---

# fountain-init-module — 在 workspace 下初始化模块（工作流 C）

## 执行步骤

**只能用 `fboot module` 创建**。不得用 `cjpm init --type=dynamic` 或手工建目录代替：fboot 在初始化模块的同时会把
`./<module_name>` 追加进上层 cjpm.toml 的 `members`；手工建目录不做这一步，模块不会被编译，也不会被 `fboot run` 加载。

```bash
cd <workspace>
fboot module <module_name>    # 创建 <module_name>/（cjpm init --type=dynamic）并加进 workspace 的 members
```

fboot 自动完成：生成模块 `cjpm.toml`（`output-type = "dynamic"`）、把 `./<module_name>` 追加进上层 `cjpm.toml` 的 `members`、写入占位 `src/<module_name>.cj`（内容 `package <module_name>`）。约定：

- 每个模块都必须是**动态链接库**，不需要 main 函数。
- `src/` 下按包分层（如 `controller/`、`service/impl/`、`dao/`、`model/`），包名与目录一致；包名由源码的 `package` 声明决定（fboot 生成的占位是 `package <module_name>`），模块之间与引用 fountain 库时都用**包名** import。
- 模块自己的 cjpm.toml 保持 cjpm 生成内容，不要手写；依赖统一声明在 workspace 根 cjpm.toml。

## 前置与依赖

先完成工作流 B（`fountain-init-workspace`）；独立使用时确认目标 workspace 已存在。

## 通用规则

执行前必须读 `references/common-rules.md` 并遵守（其中与当前工作流相关的 TDD / OpenSpec / 进度报告 / SDK BUG / fboot 规则）。本技能已随包携带该文件，不依赖 `fountain-developer` 是否安装。

## 随包资源

- `references/delivery-workflow.md`
- `references/environment.md`
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

报告模块目录、`members` 变更与占位源码；下一步通常是 D（`fountain-add-dependency`）或 F（`fountain-build-server`）。

由 `fountain-developer` 调度时，完成后返回简明结果与下一步建议，由调度技能决定是否继续；独立使用时，按本技能流程直接交付。
