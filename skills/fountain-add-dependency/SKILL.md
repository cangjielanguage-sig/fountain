---
name: fountain-add-dependency
description: 当用户要求为 fountain 项目添加/修改中心仓模块依赖、对齐 `fountain::f_*` 版本时使用。
---

# fountain-add-dependency — 添加 fountain 模块的中心仓依赖（工作流 D）

## 执行步骤

1. 定清单：按需求选**直接使用**的模块（索引与选型见 `references/module-index.md`；不确定用 `fountain_lookup.py search <能力关键词>` 核对）。传递依赖由 cjpm 自动解析，不手动加。
2. 取版本号：`fboot version` 返回的 fboot 版本号（fboot 不在 PATH 时用 `install_fboot.sh version`；源码读法见 `references/common-rules.md`「查看 fboot 版本」）。写进 `[dependencies]` 后，这个号也成了后续 `fountain_lookup.py` 查询时自动采用的版本（按项目依赖识别）。
3. 编辑 **workspace 根** cjpm.toml 的 `[dependencies]`：

   ```toml
   [dependencies]
     "fountain::f_base" = "1.3.16"
     "fountain::f_mvc" = "1.3.16"
   ```

4. 核对是否发布：`.modules` 的 `[detention]` 段列出的模块（当前为 `f_llm`、`fleet`）不发布中心仓，不能用版本依赖——需要时改 path/git 依赖，或与用户确认替代方案。
5. 验证：`fboot build`（或 `cjpm update`）能解析依赖。失败先查网络/镜像与版本号，再考虑换 path 依赖。

三种依赖形态（版本 / path / git）的写法与限制见 `references/project-setup.md`。

## 前置与依赖

先完成工作流 A→B（`fountain-install-fboot` → `fountain-init-workspace`）；独立使用时确认项目根 cjpm.toml 已有 workspace 与 `fountain::f_*` 依赖。

## 通用规则

执行前必须读 `references/common-rules.md` 并遵守（其中与当前工作流相关的 TDD / OpenSpec / 进度报告 / SDK BUG / fboot 规则）。本技能已随包携带该文件，不依赖 `fountain-developer` 是否安装。

## 随包资源

- `references/common-rules.md`
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

报告新增/变更的依赖与版本；下一步通常是 F（`fountain-build-server`）或继续当前开发。

由 `fountain-developer` 调度时，完成后返回简明结果与下一步建议，由调度技能决定是否继续；独立使用时，按本技能流程直接交付。
