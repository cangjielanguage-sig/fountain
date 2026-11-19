---
name: fountain-api-lookup
description: 当用户询问 fountain 配置项 / API 用法 / 模块能力边界（含消息队列 `f_mq`+`fmq`、数据库中间件 `fdbm`+`f_dbd`、表达式 JIT `f_jit`，以及版本间行为差异），需要按项目在用版本检索模块 README、`doc/` 设计文档与源码时使用。
---

# fountain-api-lookup — 回答 fountain 配置与 API 用法（工作流 E）

## 执行步骤

纯问答，不改代码。按下面的链路查证后再回答：

1. **定查询版本**：用户指定 `--version` > `$FOUNTAIN_VERSION` > 当前项目 cjpm.toml 的 fountain 依赖版本；脚本会先把文档副本切到该版本（见 `references/common-rules.md`「定位 fountain 仓库与查询版本」）。用户没指定、项目也没定版本时，问一句按哪个版本回答，或明确说明用的是副本现状态（输出头部有版本标注）。
2. **拆问题**：定位「模块 + 关键词」——配置项名（如 `mvc_port`、`orm_databasePoolMaxSize`、`logger_appender_*`）、API 名（如 `lookup`、`RootDAO`、`MQClient`）或特性名（如「延迟投递」「持久有效长度」）。不知道在哪个模块时先看 `references/module-index.md` 的选型速查，再用 `fountain_lookup.py search` 反查命中模块。
3. **查证（命中即停，逐步深入）**：
   - 定位：`fountain_lookup.py search "<关键词>"`；只关心源码加 `--in code`，只查特性/设计说明加 `--in docs`（覆盖根 `docs/` 与各模块 `doc/`），已知模块加 `--module <名>`。
   - 模块 README：配置表、「其他公开 API」小节、快速开始。
   - 特性语义与限制：`<模块>/doc/**/*.md`（设计 / 规格 / 优化方案；`doc/spec/<变更名>/` 是变更规格与 verify 报告，判断「这个特性承诺了什么、有哪些已知限制」看这里）；README 只有摘要，两者冲突时以源码与该模块 `doc/` 为准。
   - 签名核对：`fountain_lookup.py api <模块>` 列公开声明 → read_file 到 `<模块>/src/` 对应行。
   - 用法示例：`fdemo` / `frpcdemo` / `fmqdemo` / `fdbmdemo`（workspace，代码在 `<示例>/<子模块>/src/`，用 `search ... --module fmqdemo --in code` 定位）。
   - 语法 / std / stdx 问题按「必须遵守」加载 `cangjie-doc-lookup` 与 `cangjie-coding`。
4. **回答要求**：
   - 先说明版本：结论来自哪个 fountain 版本（输出头部的版本标注），版本不一致警告照实转达；
   - 配置类：给出配置项名、取值 / 默认值、生效方式（环境变量 / `fboot build --key=value` 编译期 / 运行期优先于编译期）以及该写在哪里（启动脚本 `exports()` 或 build 参数）；
   - API 类：给出包名 + 签名 + 最小示例，示例优先取自 `fdemo` / `frpcdemo` / `fmqdemo` / `fdbmdemo` 的真实用法，并注明出处（`<模块>/README.md`、`<模块>/src/xxx.cj:行号`）；
  - 特性类：语义 + 限制 + 前提一起答（例：`f_jit` 机器码仅 Linux x86_64/aarch64、其余平台走解释器；`f_mq` 是 at-least-once 且需要先部署 `fmq` 服务端并注册主题/订阅组；`fdbm` 需要一个已部署的中间件与物理库驱动）。出处落到 `<模块>/doc/` 的具体文件。
5. **查不到就说不确定**：仓库里没有的，明确回答「仓库中没有找到」并给出下一步（读哪个文件 / 问用户），**不许猜 API 与配置项**。用户顺势要求改动时转入工作流 K。

## 前置与依赖

无强制前置；需要本机有 fountain 源码或文档副本（`fountain_lookup.py` 会自动定位 / 克隆）。

## 通用规则

执行前必须读 `references/common-rules.md` 并遵守（其中与当前工作流相关的 TDD / OpenSpec / 进度报告 / SDK BUG / fboot 规则）。本技能已随包携带该文件，不依赖 `fountain-developer` 是否安装。

## 随包资源

- `references/common-rules.md`
- `references/module-index.md`（模块表 + 需求 → 模块选型速查）
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

报告查询版本、命中模块、签名与配置项；不修改任何文件。

由 `fountain-developer` 调度时，完成后返回简明结果与下一步建议，由调度技能决定是否继续；独立使用时，按本技能流程直接交付。
