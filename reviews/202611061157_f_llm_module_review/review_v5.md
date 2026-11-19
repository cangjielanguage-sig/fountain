# R5：测试覆盖矩阵（记忆/知识/技能/经验/人格 + 通道/Supervisor）

审查时间：2026-11-06（只读）

## 审查范围

`LoomStoreGateway_test`、`LoomPersona_test`、`LoomMemoryE2E_test`、`LoomContextMemory_test`、`SkillCatalog_test`、`StoreFunctions_test`、`Supervisor_test`、`LoomWiringSupervisor_test`、`LoomWiringChannel_test`、`LoomService_test`、`LoomBootstrap_test`、`LoomRunner_test`、`ToolFunctions_test`、`channel/{ChannelFunctions,ChannelMediator,EmailChannel,ChannelBootstrap}_test`；
对照源码 `LoomMemoryPolicy.cj`、`LoomRunner.cj`、`Supervisor.cj`、`StoreFunctions.cj`、`LoomWiring.cj`、`LoomBootstrap.cj`。

断言强度定义：**强**=正向+反向/边界；**中**=针对性断言但单路径；**弱**=仅"不报错/含某串"；**仅调用**=无有效断言。

## ① 覆盖矩阵

### A 读取

| 能力 | 用例 | 强度 |
|---|---|---|
| memory.get | LoomStoreGateway_test::testMemoryGetAndList | 强 |
| memory.list | 同上 / testListFiltersByKindBeforePaging / testMemoryListExposesSaveTime | 强 |
| memory.search | testMemorySearchFindsAddedRecord | 中（无未命中空数组断言） |
| experience.search | testExperienceAliasesMemoryWithKind；LoomMemoryE2E_test::testExperienceSearchReachesModel | 强 |
| experience.list | LoomMemoryE2E_test::testFlowRetrievalReachesModel | 中（未断言 kind 过滤） |
| knowledge.get | testKnowledgeGetReturnsContent（含未命中）+ E2E | 强 |
| knowledge.search | testKnowledgeSearchFindsUpsertedDoc；E2E::testFlowSearchReachesModel | 强 |
| knowledge.docIds | testKnowledgeDocIdsEmpty / testKnowledgeUpsertThenDocIds | 强 |
| skill.load | LoomPersona_test::testSkillLoadByTitle（含未命中） | 强 |
| skill.list/get | testSkillListAndGet、testSkillUpsertAllocatesId；E2E | 强 |
| JIT 可达性 | testJitStepCallsStoreGateway、testJitStepQueriesEvolutionReport | 强 |
| memoryCall 工具 | StoreFunctions_test::testMemoryAddThenSearch、testMemoryInvalidOpReturnsText | **弱**（add 只断言"不含 failed"；remove 未测） |
| knowledgeIngest 工具 | testKnowledgeIngestWritesDoc / testKnowledgeIngestRequiresDocId | 强 |

### B 写入

| 能力 | 用例 | 强度 |
|---|---|---|
| memory.add | testMemoryAddThenRemove；E2E::testFlowWritesMemoryAndKnowledge | 强 |
| experience 别名 | testExperienceAliasesMemoryWithKind | 中（未断言 kind 落库） |
| knowledge.upsert | testKnowledgeUpsertThenDocIds | 强 |
| prompt.put 自动版本 | testPromptPutAutoVersionAndLatest（1→2、get v1、remove、latest 缺失） | 强 |
| character.set | testCharacterSetGetReset | 强 |

### C 人格（LoomPersona_test，多数强断言）

| 能力 | 用例 | 强度 |
|---|---|---|
| 字面 | testLiteralPersonaPrefixedToSystem（精确 `严格\nBASE` + currentPersonaText 已清） | 强 |
| prompt 库 | testPersonaResolvedFromPromptStore | 强 |
| 内置正文 | testBuiltinCharacterBodyUsed（反向不出现 key） | 强 |
| 未知 key → 字面 | testUnknownKeyFallsBackToLiteral | 强 |
| custom | testCustomCharacterUsesPromptsOnly（双分支） | 强 |
| 库优先于内置 | testPersonaFallsBackToCharacterKey | 强 |
| character.prompts 追加 | testCharacterPromptsAppended | 强 |
| 空 persona 回落 character | 同上两条 | 强 |

### D 技能注入

| 能力 | 用例 | 强度 |
|---|---|---|
| SkillCatalog 自动 | LoomPersona_test::testAutoSelectsSkillByTaskText（含反向）；SkillCatalog_test 4 例 | 强 |
| run(skills:) 显式 | testSkillsInjectedIntoSystem | 强 |
| 未命中静默跳过 | **缺失**（`LoomRunner.resolveSkills:449` 的 try/catch 无用例） | — |

### E 总结（LoomContextMemory_test）

| 能力 | 用例 | 强度 |
|---|---|---|
| note | testExtractsMemoryAndExperienceAfterRun | 强 |
| experience | testSuccessWritesSuccessExperience（含不含 failed 反向） | 强 |
| experience_failed | testFailureWritesFailedExperience | 强 |
| summarize 合法 JSON | testSummarizeModeUsesModelOutput | 中 |
| summarize 非法 JSON 回落 | **缺失** | — |
| writeKnowledge | testWritesKnowledgeWhenEnabled | 强 |
| enabled=false | testDisabledPolicyWritesNothing | 强 |
| userId=0 | testSummarizeModeUsesModelOutput | 中 |
| 不演进技能 | testFlowEndDoesNotEvolveSkills | 强 |

### F 通道与 Supervisor

| 能力 | 用例 | 强度 |
|---|---|---|
| channelSend | testSendRoutesThroughMediator / testSendCarriesAttachments / testSendUnknownPlatformReturnsError | 强 |
| channelInbox | testInboxPassesDownloadDirAndReturnsJson / testInboxEmptyReturnsArray | 强 |
| 端到端收发 | testSmokeSendThenInboxWithAttachment（`exists(path)`） | 强 |
| 多账号寻址 | testRegisterTwoAccountsAndAddressThem / testBlankAccountFallsBackWhenSole / testBlankAccountWithMultipleThrows / testSendRoutesToAddressedAccount | 强 |
| 平台容错 | testUnknownChannelThrows / testCreateUnknownPlatformThrows / testRegisterProviderIsIdempotent / testReservedPlatformsAreNotImplemented | 强 |
| 附件缺失 | testSendFailsWhenAttachmentMissing（`sent.size==0`） | 强 |
| 附件落盘 | testReceiveSavesAttachments / testReceiveMapsMetadataWithoutDownload | 强 |
| 落盘冲突 | testAttachmentNameConflictIsSuffixed / testAttachmentFailsWhenDirectoryMissing | 强 |
| Bootstrap 隔离 | testInstallSkipsBadEntry / testInstallInvalidJsonDoesNotThrow / testInstallSkipsUnimplementedPlatform / testInstallFromEmptyConfigIsNoop | 强 |
| 装配 | LoomWiringChannel_test::testWireInstallsChannelsFromConfig | 中 |
| 选路提示词 | testRouterPromptCarriesRoutesAndPrompt | 强 |
| 选路容错 | testUnparsableReply / testMissingFlowField / testEmptyFlowName / testUnknownFlowName / testDispatchSkipsFlowThatIsNoLongerCompiled | 强 |
| 自动新建 | testNoUsableWhenSwitchOff / testNoUsableWhenSwitchOnCreatesAndDispatches / testTwiceAutoCreateProducesDistinctNames / testAutoCreateStopsAtClarifying / testAutoCreateNameCollisionSuffixes / testSmokeTwoFlowsThenAutoCreate | 强 |
| tap/untap | testTapIsNoopWithoutInstall；testConfirmRegistersAndDeleteRemoves | 中（untap 未装分支无用例） |
| restoreFailed | testWireSurvivesUnavailableStore | 强 |

## ② 缺失清单（按严重程度）

1. **[严重] `summarize=true` + 非法 JSON 的回落路径完全无用例**（`LoomMemoryPolicy.cj:194-210` 三条 fallback 无一条被测）。若解析失败后 memory/experience 变空 → 一条都不写，`testSummarizeModeUsesModelOutput` 会漏掉。
2. **[严重] `run(skills:)` 指定不存在技能的静默跳过无用例**（`LoomRunner.cj:449`）。`testSkillsInjectedIntoSystem`、`testAutoSelectsSkillByTaskText`、`testSkillLoadByTitle` 结构上都无法触及。
3. **[一般] `memoryCall` 的 remove 分支无用例，add 断言过弱**（`StoreFunctions_test.cj:62` 只断言"不含 failed"）。
4. **[一般] 附件写盘失败分支无覆盖**：`InboundAttachment.error` 非空路径、路径穿越/绝对路径无用例。
5. **[一般] `writeKnowledge` 写入失败的吞没分支无覆盖**（`LoomMemoryPolicy.cj:130-135`），条数统计不准不会被发现。
6. **[一般] `extract` 空输入提前返回（`turns.isEmpty() → 0`）无用例**。
7. **[一般] Supervisor 自动新建的重名/并发竞态只有单线程顺序用例**，`Mutex` 覆盖范围无并发验证。
8. **[轻微] `prompt.latest` 未在 JIT 流程内验证**（仅网关层测过）。
9. **[轻微] 工具目录可见性无断言**：`channelSend`/`channelInbox`/`memoryCall`/`knowledgeIngest` 是否真注册进 `FunctionMediator` 无用例，测试均直接 new 函数对象。
10. **[轻微] `Supervisor.untap` 未装分支、`ChannelMediator.close/注销路径` 无用例**。

## 统计

| 严重 | 一般 | 轻微 |
|---|---|---|
| 2 | 5 | 3 |

**总评**：覆盖质量高于"能跑通"级别：多数用例带反向断言（不出现某串、`inputs.size==0`、`sent.size==0`），人格三级解析、SkillCatalog 降级计数、Supervisor 四类选路容错、附件冲突顺延都有针对性设计；`LoomMemoryE2E_test` 明确区分「网关层 vs 流程内落地」。真正缺口集中在两条**静默降级**分支（summarize 非法 JSON 回落、run(skills:) 未命中跳过），二者都以 try/catch 吞异常实现，最容易被重构改坏且现有用例结构上无法触及。
