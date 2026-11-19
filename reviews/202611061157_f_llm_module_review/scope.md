# 审查范围

## 调用参数

| 项 | 值 |
|---|---|
| workdir | `D:\docs\work\cangjie\projects\fountain\.worktrees\f_llm\reviews\202611061157_f_llm_module_review\` |
| project_root | `D:\docs\work\cangjie\projects\fountain\.worktrees\f_llm\f_llm` |
| source_branch | `feature/f_llm` |
| target_branch | `master` |
| 被审查模块 | `f_llm/src/**`（含测试文件 `*_test.cj`） |
| 文档参照 | `f_llm/README.md`、`f_llm/doc/loom.md`、`f_llm/doc/f_llm.md`、`f_llm/doc/f_llm-memory-design.md` |

## 锚定方式（与原流程的偏差）

原流程要求 `checkout master → squash merge source → 审暂存区`。本 worktree 的 `master` 未被任何 worktree 占用，但 squash merge 会把 cross-module 变更一并带入，且会切换用户当前分支。**本次改为只读锚定**：

```bash
git -C <project_root>/.. diff --stat master...feature/f_llm -- f_llm
```

审查以**当前工作树上的 f_llm 模块代码**为准（分支 `feature/f_llm`，HEAD `d5385cec`），不做分支切换、不做 merge。

## 三个审查目标（用户原话拆解）

### 目标 1：没有死代码、没有功能重复

- 无人引用的公开类型 / 函数 / 常量 / 配置文件（`pub` 但全仓零引用）。
- 同一能力的两套实现（例如记忆写入的多个入口、检索的多条路径、工具与网关重叠的 op）。
- 重复的常量、重复的字符串协议、复制粘贴的大段逻辑。
- 已废弃但未删除的入口（文档里说"已删除"但代码仍在，或反之）。

### 目标 2：记忆 / 知识 / 技能 / 经验 / 提示词·人格 在 loom 内得到完全支持

必须能在 loom 编排的流程内：

| 能力 | 期望入口 |
|---|---|
| 读取记忆 | `loomStore("memory", "get"/"list"/"search")`、`memoryCall` 工具 |
| 读取知识 | `loomStore("knowledge", "get"/"search"/"docIds")`、`knowledgeIngest` 写入 |
| 读取经验 | `loomStore("experience", "search"/"list")` |
| 加载技能 | `loomStore("skill", "load"/"list")`、`SkillCatalog` 自动注入、`run(skills:)` 显式注入 |
| 指定人格 | `FlowPlan.persona` 三级解析（prompt 库 → `PredefinedCharacters` → 字面） |
| 指定提示词 | `loomStore("prompt", "latest"/"get"/"put")` + persona 走 prompt 库 |
| 总结新经验 / 新记忆 | 流程结束 `LoomMemoryExtractor`（`note` / `experience` / `experience_failed`，可选 `writeKnowledge`、`summarize`） |

同时核对：上述每条是否都有**测试用例**覆盖（类名 + 用例名 + 断言点），缺口要列出。

### 目标 3：性能与内存

- 热路径：记忆检索的向量融合、`SkillCatalog` 检索与缓存、loom 执行的事件表与模板替换、`loomStore` 的 JSON 序列化。
- 不必要的拷贝 / 重复编码（同一文本多次 embed、同一技能多次加载）。
- 无界增长的容器（缓存、日志、事件表、`LoomContextLog`）。
- 明显的 O(n²)、每步重复全量扫描、在循环里建大对象。

### 目标 4（追加专项）：通道 / Supervisor

- `src/channel/**`：契约与中介者（平台/账号寻址、provider 静态注册、实例登记）、`EmailChannel` + `FEmailTransport`（附件收发、路径校验、落盘命名冲突）、`ChannelBootstrap` 配置装配、`channelSend` / `channelInbox` 两个工具。
- `src/loom/Supervisor.cj` 及其钩子（`LoomService` 的 tap/untap、`LoomWiring.installSupervisor`）：选路提示词、JSON 容错、`auto-*` 命名与冲突顺延、澄清态不登记、`restoreFailed` 观测。
- 重点看：状态一致性（路由表 vs 流程库）、异常吞没、并发（`Mutex` 覆盖范围）、配置单条失败隔离、事件名/账号键的归一化。

## 不在范围

- `f_email`、`f_store`、`f_egraph` 等外部模块的内部实现（只核对其被调用的方式是否正确）。
- 纯文档措辞问题（除非与代码矛盾）。
- 新增功能建议（只记录，不改代码）。

## 报告约定

- 严重程度：**严重**（正确性/内存泄漏/安全）、**一般**（可维护性/明显低效/测试缺口）、**建议**（风格/命名）。
- 每条给：题目、位置（`file:line`）、描述、证据（grep 结果或调用链）、建议。
- **只读审查**：不得修改任何源码。
