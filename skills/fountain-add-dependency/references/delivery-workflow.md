# 交付全流程（初始化 → 配置 → TDD → 提交 → 建 tag）

工作流 F / G / H / I 共用；工作流 J（在 fountain 仓库内开发）复用其中第 3–7 节（TDD / 回归 / 冒烟 / 提交 / 建 tag），工作流 K 只走第 4–7 节（构建 / 回归 / 冒烟 / 提交 / 建 tag）。原则：能用工具就先用工具（`fboot` 建骨架、`fountain_lookup.py` 查 API、`install_fboot.sh` 查版本）。
查 API 时按**在用版本**：`fountain_lookup.py` 默认取当前项目 cjpm.toml 的 fountain 依赖版本并先把文档副本切到该版本
（输出头部标注版本；换版本 `--version X.Y.Z` / `switch X.Y.Z`，见 SKILL.md「定位 fountain 仓库与查询版本」）。

**与 OpenSpec 的分工**：工作流 F / G / H / I / J / L 全程都要走 OpenSpec 六步规格驱动流程（环境与刷新 → `opsx:propose` → 用户评审 design / tasks → `opsx:apply`
→ `opsx:verify` → `opsx:archive` + 落盘 `doc/spec/<变更名>/`，见 `references/openspec-workflow.md`）。OpenSpec 负责「做什么 / 为什么 / 怎么设计 / 进度」，
本文件负责「在 fountain 里怎么把它做对」；**OpenSpec 的产物与归档不豁免本文件的任何门禁**（TDD / 全量回归 / 冒烟 / 提交 / 建 tag）。

## 1. 初始化

- 新项目 / 新功能骨架：工作流 A（装 fboot）→ B（workspace）→ C（模块）→ D（依赖）。
- 已有项目：确认它是 fountain workspace（根 cjpm.toml 含 `[workspace]` 与 `"fountain::f_*"`），记录 fboot 版本
  （`install_fboot.sh version`）。
- 旧版本项目（SDK 1.0.x + fountain 1.0.x）：先按工作流 I 完成升级（环境 → 依赖 → 包名 → API → 脚本），再回到本流程做功能改动。

## 2. 配置（含随功能演进补充依赖）

三类配置载体（模块依赖 / 运行期环境变量 / 编译期 `--key=value`）的改法见工作流 K。其中**依赖必须随功能演进同步**：

- 每完成一批功能，核对代码里实际用到的 `fountain::f_*` 是否都已在**workspace 根 cjpm.toml** 声明：
  - 缺 → 补 `"fountain::f_xxx" = "<fboot 版本>"`（只加直接依赖，传递依赖交给 cjpm；`.modules` 的 `[detention]` 模块不能版本依赖）；
  - 不预加尚未使用的模块；功能删除后遗留的依赖清理需与用户确认；
  - 每次依赖变更后 `fboot build`（或 `cjpm update`）验证能解析。
- 运行期配置随功能同步落到**三个平台**的启动脚本（见 `references/launch-scripts.md`）。
- 版本号以现场为准：`fboot version`（fboot 版本 = 依赖版本）、`.modules`（发布状态）。

## 3. TDD（严格 Red-Green-Refactor）

**工作流 F / G / H / I / J / L 开工先加载 `test-driven-development` 技能**（**REQUIRED SUB-SKILL:**，加载失败时的处理见 `references/skill-infra.md` 第 3 节）——
Red-Green-Refactor 的循环、反合理化清单与「没看着测试失败过就不算测试」的判据以它为准，本节只补仓颉 / fountain 的落法。

F / G / H / I / J / L 的功能开发与适配一律按 TDD 循环推进，**先写测试再写实现**，不许先实现后补测试；工作流 K 只改配置、无功能代码，不走 TDD（仍要构建 + 回归 + 冒烟）：

1. **Red**：先写该功能点的仓颉单元测试（`*_test.cj`，与实现同目录结构），跑一次确认它**失败**；
   失败原因必须是「功能未实现 / 断言不满足」，不是编译错误或用例本身写错——这一步是测试有效性的证明。
2. **Green**：写**最小实现**让测试通过。
3. **Refactor**：在测试全绿的保护下重构（命名、结构、去重）；重构后再跑一次确认仍绿。
4. 每个功能点（或一小批相关点）走完一轮循环，形成一个可提交的增量。

走 OpenSpec 流程时（工作流 F / G / H / I / J / L 全程），TDD 落在 `opsx:apply` 的**每个 task** 上：
任务勾选前先跑绿，**不允许出现「任务已勾选但没有对应测试」的进度**（假进度在 `opsx:verify` 里会暴露为 completeness 缺口）。

- 写法与运行：测试规范与 API 加载 `cangjie-coding`；`cjpm test` 在模块 / 项目里直接跑；
  fountain 应用项目可用 `fboot test [PATH] --dylibPattern='...'`（以 `PATH/test/cjpm.toml` 覆盖后 build + run，见 `f_app/README.md`）。
- 覆盖口径：需求 / 接口边界（参数校验、错误码、空值）、DAO 存取、配置开关与默认值。
- **禁止**：跳过或注释掉失败断言；用 `println` 代替断言；为了让测试通过而放宽断言；实现与测试分开在不同提交。

## 4. 回归测试

- **每个批次完成后跑全量测试**（本模块 + 受影响模块），不是只跑新写的用例：在 workspace 根或逐模块 `cjpm test`。
- 回归失败 = 门禁不通过：先定位是本次改动破坏的（优先修实现）还是用例本身过时（与用户确认后改用例）。
- **交付节点（提交前、打 tag 前）必须再跑一次全量回归**。
- 高风险改动（依赖升级、公共 API 变更、配置语义变化）做针对性回归：受影响的模块与调用方都要覆盖。
  工作流 I 的版本升级即属此类，差异逐条对照 `references/legacy-upgrade.md` 的差异表。

## 5. 冒烟测试

「应用能起来 + 关键路径能通」的最小验证，**每个交付节点做一次**：

1. `fboot build` 通过；
2. 用启动脚本拉起应用（`./boot.sh run`；长驻进程交给用户执行或后台跑）；
3. 验证关键路径：HTTP 项目至少 `curl` 一个核心接口（如 `GET /health` 或主业务接口）；RPC 项目用
   `runServer` + `runClient` 打通一次调用；
4. 检查日志（`logger_*` 输出）无异常堆栈。

冒烟失败 → **不提交、不打 tag**；把失败现象与判据整理给用户确认后再继续。

## 6. 提交（git）

- 开工前 `git status` 确认现场；只提交本次改动（`git add <具体路径...>`，不要 `git add -A`）。
- **提交前必须**：`fboot build` 通过 + 单元测试全绿 + **全量回归通过 + 冒烟通过**（先有测试，再提交）。
- 分支：遵循用户项目的既有规范（如 `feature/<功能名>` / `fix/<缺陷名>`）；仓库没有规范且用户未指示时，
  询问用户后再动分支，不擅自创建 / 切换 / 合并。
- 提交信息：`<类型>(<范围>): <要点>`（如 `feat(user): 新增注册接口`、`fix(orm): 修复连接池超时`）；一次提交做一件事。
- 提交后核对：`git show --stat HEAD` 与本轮改动一致；出现无关文件 → 停下问用户。

## 7. 建 tag（发布标记）

- 前置门禁（缺一不可）：本轮提交已 **推送**（`git push origin <分支>` 成功）；工作区干净；单元测试 / 回归 / 冒烟全部通过；在 fountain 仓库内发布（`fountain-tag` 技能）时，`CHANGELOG` 已按「上一个 tag → `origin/master`」汇总并按时间倒序更新（最新在前）且合入 master，见 `fountain-tag` 的 Step 3.5。
- 命名：**以用户项目的既有 tag 规范为准**——先 `git tag --sort=-creatordate` 看历史；无历史或规范不明时**与用户确认**，
  不要自行发明格式。
- 附注 tag（必须 `-a`，便于 `git tag -l -n` 查看消息）：

  ```bash
  git tag -a <tag 名> -F <消息文件>            # 指向当前（已推送的）提交
  git push origin refs/tags/<tag 名>            # 显式 refspec；不用 --tags、不加 -f
  ```

- tag 信息：写清本次发布包含的功能与修复（自上一个 tag 以来的要点），不要只有版本号；消息文件**写完先核对非空**
  （空文件时 `git tag -a -F` 也会 exit 0，会静默产出空消息 tag）。
- 禁止：覆盖 / 移动 / 删除已有 tag；`git push --tags`；任何 `--force` 推送。
- 复核：`git cat-file tag <tag 名>` 首行 object 指向预期提交；`git ls-remote --tags origin <tag 名>` 回显远端 sha。

## 8. 交付物清单（收尾自检）

1. 代码：按需求实现、按分层组织、无占位/假实现。
2. 配置：三类载体齐全且三平台脚本同步；依赖与代码一致。
3. 测试：新增功能有对应用例（TDD 产出）；**全量回归通过**；**冒烟通过**（含日志检查）。
4. 提交：范围干净、信息规范、已推送。
5. tag：按项目规范创建并推送（附注 tag），消息完整。
6. 文档：启动方式（各平台）、环境变量清单、验收判据写进项目 README 或交付报告。
