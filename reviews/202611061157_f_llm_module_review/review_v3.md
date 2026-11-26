# R3：loom 内「人格 / 提示词 / 技能注入」是否完全支持

审查时间：2026-11-06（只读）

## 审查范围

`src/loom/LoomRunner.cj`、`LoomHostApi.cj`、`LoomStoreGateway.cj`、`Planner.cj`、`Plan.cj`、`Prompts.cj`、`LoomCompiler.cj`、`LoomJitBridge.cj`、`LoomService.cj`、`LoomAgent.cj`、`LoomMemoryPolicy.cj`、`SkillCatalog.cj`、`LoomWiring.cj`；
`src/store/PredefinedCharacters.cj`、`StoreContracts.cj`、`InMemoryStores.cj`；
测试 `LoomPersona_test.cj`、`LoomMemoryE2E_test.cj`；文档 `doc/loom.md`。

## 逐项结论

1. **persona 三级解析**：顺序正确（`LoomRunner.cj:371-402`：prompt.latest 376-391 → bodyOf 396-399 → 字面 401），逐级失败下沉存在，`custom` 特例存在（171-175），空 persona 回落 character（162-168）。**但 `default` 未特例**（F1）。
2. **character.prompts 追加**：位置正确（177-183：`persona + "\n\n" + extra`，之后才 setPersona 184-186）；生效前提 `characterOf(userId)`，而 `userId<=0` 直接 None（406-408），默认 policy userId=0（`LoomMemoryPolicy.cj:52`）→ 默认配置下静默失效（F2）。
3. **prompt 库**：`get/latest/put/remove` 都在（`LoomStoreGateway.cj:242-274`），`put` 的 `version<=0` 自增语义与 persona 用 `latest` 自洽；但 `get/remove` 未延续该语义（F5）。
4. **技能注入**：自动路径（194-199 + `SkillCatalog.search`，任务文本=notes+起始输入 427-446）流程内可达；显式 `run(skills:)`（191-193 + 449-471）只在宿主直调时可达。注入位置 `LoomHostApi.callLlm:127-133`（persona → 可用技能 → 步骤 system），与文档一致。
5. **文档一致性**：`doc/loom.md:457` 称「编排时把技能列出来即可」，但 `FlowPlan`/`Planner` 无 skills 字段 → 生产链路不可达（F4）。

## 发现

### [严重] `characterKey = "default"` 被当成字面人格注入 system

- **位置**：`src/loom/LoomRunner.cj:171-175`、`:396-401`、`src/store/PredefinedCharacters.cj:81`
- **描述**：`default` 是合法可存 key（`isKnown` 通过），但 `bodyOf('default')` 走 `case _ => ''`；解析落到第 3 级字面文本，把英文单词 `default` 拼进 system。`custom` 有特例、`default` 没有，与 `PredefinedCharacters.cj:26`「default 表示不注入」矛盾。
- **建议**：特例扩为「`bodyOf` 为空且 `isKnown(key)`」即视为无内容；补 `testDefaultCharacterInjectsNothing`。

### [一般] character 人格与 prompts 依赖 `LoomMemoryPolicy.userId`（默认 0），默认配置静默失效

- **位置**：`LoomRunner.cj:159-160`、`:406-408`、`LoomMemoryPolicy.cj:52`
- **描述**：`characterOf(0)` 返回 None → 既无回落人格也无 `character.prompts`；文档未写「必须先 install 带 userId 的 policy」，失败无日志。
- **建议**：userId 提到独立人格装配项，或文档明写前置条件 + 诊断日志。

### [一般] 显式 skills 全部未命中时，自动检索被抑制

- **位置**：`LoomRunner.cj:191-203`
- **描述**：`if(selected.isEmpty() && policy.autoSkills)` 只看入参是否为空，不看是否加载到正文；标题全打错时 `skillBlock` 为空也不回落，`resolveSkills` 静默 continue。
- **建议**：以 `skillBlock.isEmpty()` 作为回落判据 + 未命中提示。

### [一般] 显式 `run(skills:)` 在编排链路内不可达，与文档不符

- **位置**：`LoomService.cj:133`、`LoomAgent.cj:129-132`、`Plan.cj:67-74`、`Prompts.cj:50-63`、`Planner.cj:27-48`
- **描述**：`FlowPlan` 无 skills 字段，Planner schema 只教 persona，`LoomRequest` 无 skills；`executeNow`/`LoomAgent.run` 都不传 `skills:`。模型规划 → `loomExecute` → `executeNow` 链路拿不到显式技能。
- **建议**：`FlowPlan`/`PlanDto`/`LoomRequest` 增 skills 并透传；否则改文档措辞。

### [一般] `prompt.get` / `prompt.remove` 未定义 `version<=0` 语义，与 `put` 不一致

- **位置**：`LoomStoreGateway.cj:243-247`、`:271-273`、`:341-356`
- **描述**：`intOf` 缺字段返回 0；`get(name,0)`/`remove(name,0)` 直接落到底层 → 永远 `''`/`false`，与 `put` 的自增语义不对称。
- **建议**：`get` 在 `version<=0` 走 `latest`；`remove` 补 latest/all 语义或文档写明必须给 version。

### [一般] 提示词条目 `content` 为空时会屏蔽内置人格

- **位置**：`LoomRunner.cj:378-386`
- **描述**：命中 `content:""` 直接 `return ''`，既不下沉第 2 级也不回落字面，人格被静默关掉。
- **建议**：空 content 视为本级无内容，继续下沉。

### [一般] persona/skills 用静态全局 + 无条件 clear，嵌套流程会清掉外层人格

- **位置**：`LoomHostApi.cj:145-188`、`LoomRunner.cj:219-225`
- **描述**：`personaText`/`skillText` 进程级静态；`finally` 无条件 clear。嵌套流程（jit 里 `loomExecute(execute=true)`）或并发分支会互相清空/覆盖。
- **建议**：栈式 push/pop 或 runCompiled 局部持有 + 还原旧值。

### [一般] 记忆提炼把「人格 + 技能块」当事实写进记忆

- **位置**：`LoomHostApi.cj:138`、`LoomMemoryPolicy.cj:183-185`
- **描述**：`LlmTurn` 记的是 `fullSystem`（含 persona 与技能块），摘要写进 `note`/`knowledge` → 污染检索并自反馈。
- **建议**：`LlmTurn` 分字段存「步骤 system」与「注入前缀」，摘要只取前者。

### [一般] 测试缺口

- **位置**：`LoomPersona_test.cj:45-266`
- **描述**：缺 ① `default` 不注入；② `prompt.get/remove` 的 version 语义；③ 显式 skills 全未命中是否回落；④ `userId<=0` + 有 character；⑤ 空 content 屏蔽；⑥ 嵌套流程不破坏外层 persona。
- **建议**：各补一条最小用例，断言 `host.lastSystem` 与 `currentPersonaText()/currentSkillsText()`。

### [轻微] 注入块拼接符与文档不一致

- **位置**：`LoomHostApi.cj:132-133`
- **描述**：代码用单个 `\n` 拼前缀与步骤 system，文档画的是空行；人格与 prompts 用 `\n\n`。
- **建议**：统一 `\n\n` 或改文档。

### [轻微] `resolvePersona` 用未 trim 原值查库/查内置

- **位置**：`LoomRunner.cj:372-401`
- **描述**：`custom` 判断用 trim 后的值，`prompt.latest`/`bodyOf` 用原值；`persona=" rigorous "` 两级都查不中，最后按字面注入带空白的 key。
- **建议**：入口统一 `value.trimAscii()`。

### [轻微] 自动选技能只认 String 型起始输入

- **位置**：`LoomRunner.cj:427-446`
- **描述**：只对 `data as String` 取值；结构化事件/payload 启动时 `taskText` 只剩 notes，常为空 → `search('')` 返回空，自动注入静默不发生。
- **建议**：结构化 data 做 `toString()` 兜底或写诊断。

## 统计

| 严重 | 一般 | 轻微 |
|---|---|---|
| 1 | 8 | 4 |

**总评**：主干干净（顺序、逐级回退、custom 特例、prompts 追加位置、finally 复位、单出口注入），缺口集中在边界值与显式路径；`default` 反向污染 system 是唯一严重项。
