---
name: fountain-init-workspace
description: 当用户要求新建 fountain workspace、初始化项目骨架，或 `fboot workspace` 失败时使用。
---

# fountain-init-workspace — 初始化 fountain workspace（工作流 B）

## 执行步骤

**只能用 `fboot workspace` 创建**（先完成工作流 A）。不得用 `cjpm init --workspace` 或手工写 cjpm.toml 代替：
`cjpm init` 的产物缺 fboot 注入的 `[dependencies]`（f_base / f_version）、编译选项与各平台 `[target]` 段，手工补极易漏项。

```bash
fboot workspace <name>    # 在当前目录创建 <name>/ 并初始化为 workspace
fboot workspace           # 把当前目录初始化为 workspace（该目录必须为空）
cd <name>
```

fboot 在 `cjpm init --workspace` 之后自动改写 `cjpm.toml`：

- `[workspace] version = "1.0.0"`、`compile-option = "--dy-std -Woff all"`
- `[dependencies]` 注入 `"fountain::f_base"` 与 `"fountain::f_version"`，**版本 = 当前 fboot 的版本**
- 补齐各平台 `[target.*]` 与 `${CANGJIE_STDX_DYNAMIC_PATH}` / `${CANGJIE_STDX_PATH}` path-option

验收：`cjpm.toml` 中含上述 `[dependencies]` 与 `[target]` 段（完整产物样例见 `references/project-setup.md`）。Windows 下不要传 `D:\...` 绝对路径（只识别 `/` 开头的绝对路径）：先 `cd` 到目标父目录再 `fboot workspace <name>`。

## 前置与依赖

先完成工作流 A（`fountain-install-fboot`）；独立使用时确认 `fboot` 已可用。

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

报告 workspace 路径、注入的依赖与 `[target]` 段；下一步通常是 C（`fountain-init-module`）。

由 `fountain-developer` 调度时，完成后返回简明结果与下一步建议，由调度技能决定是否继续；独立使用时，按本技能流程直接交付。
