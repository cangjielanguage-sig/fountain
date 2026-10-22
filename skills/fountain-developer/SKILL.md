---
name: fountain-developer
description: 当用户要求用 fountain 框架（仓颉）开发服务器应用、安装/初始化 fountain 环境、添加模块依赖、按需求开发或迁移/升级项目、在 fountain 仓库内开发、修改模块配置，或做代码审查并按报告修复时使用；本技能是 12 个 fountain 工作流技能的统一调度入口，按任务加载对应技能（技能没装先运行 `scripts/install_skill.py workflows`）。
---

# fountain-developer — fountain 工作流调度

fountain 是仓颉语言的服务器应用框架：应用**没有 main 函数**，每个模块编译为动态链接库，由 `fboot` 加载启动。本技能只负责**识别任务 → 加载对应的独立工作流技能 → 汇总结果**；工作流细节不再内联，避免 12 份文案漂移。

## 工作流索引

| 任务 | 独立技能 | 工作流 |
| --- | --- | --- |
| 安装 fboot | `fountain-install-fboot` | A |
| 初始化 fountain workspace | `fountain-init-workspace` | B |
| 在 workspace 下初始化模块 | `fountain-init-module` | C |
| 添加 fountain 模块的中心仓依赖 | `fountain-add-dependency` | D |
| 回答 fountain 配置与 API 用法 | `fountain-api-lookup` | E |
| 按需求文档开发服务器应用 | `fountain-build-server` | F |
| 其他语言项目 → 仓颉项目 | `fountain-port-other-lang` | G |
| 非 fountain 仓颉项目 → fountain 风格 | `fountain-adopt-cangjie` | H |
| 旧版本项目升级 | `fountain-upgrade-legacy` | I |
| 在 fountain 仓库内开发 | `fountain-develop-framework` | J |
| 为现有项目添加 / 修改模块配置 | `fountain-configure-module` | K |
| 代码审查 → OpenSpec 修复 | `fountain-code-review-fix` | L |

## 调度协议

1. **识别工作流**：按上表匹配用户任务；一个任务跨多个工作流时（如从零开发新服务 = A→B→C→D→F），按顺序加载。
2. **加载技能**：用当前 Agent 的技能机制加载对应技能；没有技能机制时直接读该技能目录的 `SKILL.md`。**不要在本技能里重写工作流步骤，也不要跳过技能直接执行。**
3. **缺失先安装**：`python <skill-root>/scripts/install_skill.py workflows` 一次装齐 12 个工作流技能；`install_skill.py list` 复验。
4. **传递用户需求**：把用户原话、目标目录、项目类型、已有产物一并交给工作流技能；工作流技能会自行加载它需要的联动技能（cangjie-coding / cangjie-doc-lookup / opsx-* / harness / test-driven-development）。
5. **收尾与下一棒**：收集工作流技能的完成摘要；按下表给出下一步建议，不替用户拍板。

## 通用规则

执行任何工作流前读 `references/common-rules.md`；其中包含联动技能自动安装、TDD / OpenSpec 六步、进度报告、SDK/STDX BUG 处理、fboot 创建约束、fountain 查询版本与常见坑。**工作流 F / G / H / I / J / L 必须走 OpenSpec 六步 + 严格 TDD；A / B / C / D / E / K 不走六步。**

## Red flags（调度层）

| 你正想做 | 现实 |
| --- | --- |
| 在调度技能里直接展开 12 个工作流的步骤 | 步骤在独立技能里；这里只做识别、加载、汇总 |
| 用户说要开发新服务，直接从 F 开始 | 先确认 A→B→C→D 的产物；缺什么先加载对应技能 |
| 工作流技能没装，自己手写流程 | 先 `install_skill.py workflows`，装完再加载 |
| 用户没说清楚是哪个工作流 | 问清楚再加载；不要替用户猜 |
| 工作流技能返回后不汇总、不报下一棒 | 调度器要给出目标 / 产物 / 验收 / 下一步建议 |

## 随包资源

- `references/common-rules.md` — 12 个工作流共享的通用规则（各独立技能也各带一份）
- `references/` — 工作流细节参考（`environment` / `project-setup` / `module-index` / `server-development` / `launch-scripts` / `delivery-workflow` / `porting-guide` / `openspec-workflow` / `cangjie-to-fountain` / `legacy-upgrade` / `skill-infra` / `code-review-workflow` / `opsx-waiting` / `sdk-bug-handling`）
- `scripts/` — `install_fboot.sh` / `fountain_lookup.py` / `install_skill.py` / `migrate_fountain_imports.py` / `opsx_fusion.py` / `opsx_progress.py`
