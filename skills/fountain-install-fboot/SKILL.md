---
name: fountain-install-fboot
description: 当用户要求安装/检查 fboot，或出现 `fboot: command not found`、需要配置 CANGJIE/STDX 环境时使用。
---

# fountain-install-fboot — 安装 fboot（工作流 A）

## 执行步骤

1. 检测：`fboot version` 能跑就跳过（记录版本号，后续依赖版本要与之相同；查不到就用 `references/common-rules.md`「查看 fboot 版本」里的 `install_fboot.sh version`）。
2. 检查环境：`bash <skill-root>/scripts/install_fboot.sh check`（探测 cjc / cjpm / stdx / fountain 源码）。
3. 安装（二选一）：
   - **有 fountain 源码（推荐）**：`bash <skill-root>/scripts/install_fboot.sh install [--root DIR]`；等价于 `cd <fountain>/fboot && cjpm install --root DIR`。
   - **只有中心仓**：`cjpm install fountain::fboot-<版本> --root DIR`（如 `cjpm install fountain::fboot-1.3.16 --root ~/.cjpm`；省略 `--root` 时装到 `~/.cjpm`）。
4. 配置环境变量（每个新 shell 都要）：

   ```bash
   export PATH=$PATH:<DIR>/bin
   export LD_LIBRARY_PATH=$LD_LIBRARY_PATH:<DIR>/libs/fboot
   export CANGJIE_STDX_DYNAMIC_PATH=<stdx 动态库所在目录>
   ```

5. 验收：`fboot version` 与 `fboot help` 均正常输出。

平台细节与已知坑（WSL 下 source cangjie 环境、库搜索顺序、Windows 变量错位）见 `references/environment.md`。

## 前置与依赖

无（本技能是其余工作流的起点）。

## 通用规则

执行前必须读 `references/common-rules.md` 并遵守（其中与当前工作流相关的 TDD / OpenSpec / 进度报告 / SDK BUG / fboot 规则）。本技能已随包携带该文件，不依赖 `fountain-developer` 是否安装。

## 随包资源

- `references/common-rules.md`
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

报告 fboot 版本与安装路径；下一步通常是 B（`fountain-init-workspace`）。

由 `fountain-developer` 调度时，完成后返回简明结果与下一步建议，由调度技能决定是否继续；独立使用时，按本技能流程直接交付。
