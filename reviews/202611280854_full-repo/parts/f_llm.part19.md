# f_llm 模块审查报告（模块第 19/25 部分）

- **审查日期**：2026-11-28
- **模块路径**：`f_llm`（全模块 368 个 `.cj` + 112 个 `.md`；**本部分 20 个源文件**：`src/model/entity/imports.cj`、`src/model/model.cj`、`src/model/po/*`、`src/search/*`、`src/service/LLMConfService*` / `LLMConfSource*`）
- **基线**：工作区快照（master 与 sts/1.3.x 同一提交 `120fd2542`，`git diff` 为空）——本部分文件无 diff 可比，**全部问题来源为「存量」**
- **审查重点**：LLM 客户端契约与配置、流式响应与错误处理、资源与超时、死代码、重复逻辑、并发安全、存量 BUG
- **报告版本**：v1-part19（同轮重审定稿，覆盖此前同名草稿；只覆盖第 19 部分，模块报告由主 Agent 合并，不写入 `docs/review/`）

## 发现

### [严重][存量] 搜索/抓取把 TLS 校验设为 `TrustAll`，同时携带 `Bearer <API key>`——出站流量可被中间人读取与篡改

- **位置**：`f_llm/src/search/DeepSeekSearchProvider.cj:43-45`（`var tls = TlsClientConfig(); tls.verifyMode = CertificateVerifyMode.TrustAll; client.tlsConfig(tls)`）；凭据在 `:120-127`（`headers['Authorization'] = 'Bearer ${conf.auth}'`）；发送在 `:46-49`
- **来源**：存量（快照模式无 diff）
- **判据**：review-checklist §10 安全性 / §11「契约与实现不符」
- **证据**：静态确定 —— `TlsClientConfig.verifyMode` 文档默认值为 `CertificateVerifyMode.Default`（“认证系统证书”，`cangjie_runtime/stdlib/doc/libs_stdx/net/tls/tls_package_api/tls_package_classes.md:664-671`），`TrustAll` 在同文件 `:699` 明确写着“信任所有证书”；`f_httpclient` 没有在 `HttpClient.tlsConfig` 上做任何兜底（`f_httpclient/src/httpclient.cj:110-113` 只是透传 `builder.tlsConfig`）
- **描述**：能劫持 DNS/网络的中间人可用自签证书冒充 `api.deepseek.com`：(1) 直接拿到 `Authorization: Bearer sk-...`（长期计费凭据）；(2) 把 `search`/`fetch` 的返回正文替换成带指令的文本，而这段文本会被 `WebSearchFunction.call`（`f_llm/src/tool/WebSearchFunction.cj:64-69`）原样交回模型当作工具结果，构成提示注入。搜索与抓取是模型主动调用的公网能力，触发面比聊天主链路更宽
- **建议**：删除 `:43-45` 走默认 `Default` 校验；确需关闭校验的场景做成显式配置（如 `llm_tlsVerify=false`，默认 `true`），开启时 `log.warn`。同一模式在 `src/util/http.cj:26`、`src/llm/LLMTransport.cj:47`、`src/llm/LLMStreamTransport.cj:49`、`src/embedding/BgeM3Transport.cj:91`、`src/balance/BalanceQueriers.cj:42`、`src/store/hydra/HttpTransport.cj:203` 还有 6 处（属其他分轮范围），修复应统一收敛到 `f_httpclient` 一处

### [一般][存量] 搜索/抓取没有自己的超时，继承的是被 embedding 反复改写的**进程级** HTTP 默认超时

- **位置**：`f_llm/src/search/DeepSeekSearchProvider.cj:36-50`（`defaultSearchPost` 只设 `autoRedirect` / `tlsConfig`，无 `readTimeout` / `writeTimeout`）
- **来源**：存量（快照模式无 diff）
- **判据**：review-checklist §11「契约与实现不符」/ §12.1「共享可变状态」
- **证据**：静态确定 —— `HttpClient` 在构造函数里读两个**静态**变量并应用（`f_httpclient/src/httpclient.cj:29-48`：`private static var readTimeout_`/`writeTimeout_`，`globalReadTimeout`/`globalWriteTimeout` 直接赋值，无同步）；生产代码里唯一的写入点是 `BgeM3Transport.embed`（`f_llm/src/embedding/BgeM3Transport.cj:62-64`，默认 `timeoutMs = 3000`），每次向量化都改写这两个全局值
- **描述**：两条后果都成立：(1) 只要进程跑过一次向量化，搜索/抓取的 `HttpClient` 就继承 3s 读写超时，DeepSeek 搜索接口正常时延可能超过 3s，表现为“偶发搜索失败”，且失败点随 embedding 调用时机漂移；(2) 若 embedding 从未被调用，`readTimeout_` 为 `None`，请求使用 stdx 默认值（没有业务上限），一次挂起的连接会一直占住调用线程。另：`global*` 写的是无同步静态 `var`，与并发创建 client 之间存在数据竞争（该文件属其他分轮）
- **建议**：`defaultSearchPost` 里显式 `client.readTimeout(...)` / `client.writeTimeout(...)`，取值从 `LLMConfig` 读（搜索建议 10~30s，抓取单独定），不要依赖 `global*`；同时给 `f_httpclient` 的全局设置加锁或废弃

### [一般][存量] `readEntire()` 全量物化响应体、按 `Content-Length` 预分配，抓取大小上限只在读完之后才生效

- **位置**：`f_llm/src/search/DeepSeekSearchProvider.cj:48`（`response.readEntire()`）→ `f_httpclient/src/ExtendHttpResponse.cj:50-77`（`:55` `Array<Byte>(size, repeat: 0)`，或 `ArrayList<Byte>` 1KB 步进累积）→ `:93-95`（`String.unsafeUtf8` 再整份复制）
- **来源**：存量（快照模式无 diff）
- **判据**：review-checklist §5「一次性物化」「按不可信长度预分配」
- **证据**：静态确定 —— 读取阶段没有任何字节上限；`llm_fetchMaxBytes` 只在 `WebFetchFunction.renderPage`（`f_llm/src/tool/WebFetchFunction.cj:59,64-74`）里截断，此时整页正文已经在堆上；`bodySize` 直接来自响应的 `Content-Length`（`ExtendHttpResponse.cj:51-55`），是上游可控值
- **描述**：`fetch` 抓的是任意公网页面，`search(need_content=true)` 返回的 `summary` 实测也可能是整页正文（`DeepSeekSearchProvider.cj:70-71` 注释自述）。一个 500MB 的页面（或恶意站点/被劫持的上游，见 #1）会让进程在“截断到 20KB”之前先分配 500MB 的 `Array<Byte>` + 500MB 的 `String`，峰值约为响应体的 2~3 倍；`needContent=true` 时同一响应还要再建一遍 JSON 树。`count` 同样没有上限：`WebSearchParams` 的 schema 只写了“1~50”（`f_llm/src/tool/WebSearchFunction.cj:35-36`），代码不校验，`DeepSeekSearchProvider.cj:103` 原样下发
- **建议**：把字节预算下沉到读取层——`SearchPoster` 增加 `maxBytes`，`readToEnd` 改为有界循环读（超过上限即停并返回 `truncated`）；`search` 侧对 `count` 做硬校验（`1..50` 夹紧，在 provider 里做，防所有调用方漏校验）

### [一般][存量] `SearchProviderRegistry.ensureLoaded` 把“扫描/构造失败”整体吞掉并永久 `loaded = true`，与自身注释相反且无日志

- **位置**：`f_llm/src/search/SearchProvider.cj:118-133`（`:124-130` 的 `try/catch(_: Exception){}`、`:131` 的 `loaded = true`）
- **来源**：存量（快照模式无 diff）
- **判据**：review-checklist §3「静默吞异常」/ §11「契约与实现不符」/ §6.2「锁内执行外部逻辑」
- **证据**：静态确定 —— 注释写“单个 provider 构造失败只跳过，不影响其他平台”，实现是把整个 `lookupList<SearchProvider>()`（`f_bean/src/lookup.cj:44-46` → `BeanFactory.getList` → `f_bean/src/BeanFactory.cj:274-283`，循环内 `m.bean` 逐个实例化）包在一个 `catch` 里：任一 provider 构造抛异常，本次扫描已构造与未构造的 provider 全部不注册，而 `loaded` 已置真，进程生命周期内不再重试
- **描述**：一次构造失败就永久关闭 `@Bean` 发现且无日志；下游 `WebSearchFunction.pickConf` 只看到 `registered: []`（`WebSearchFunction.cj:88-91` 的 `SearchUnavailableException`），真正原因被掩盖。另：扫描在 `synchronized(mutex)` 内执行（`:120-132`），期间会运行任意 provider 的构造函数。`Mutex` 是可重入的（`cangjie-doc/.../docs/dev-guide/source_zh_cn/concurrency/sync.md:350`：“在某个线程已经持有一个 `Mutex` 锁的情况下，再次尝试获取同一个 `Mutex` 锁，永远可以立即获得”），所以同线程不会自锁；但若某个 provider 的 `init` 反过来调 `get()`/`register()`，重入的 `ensureLoaded` 看到 `loaded` 仍为 `false`，会再次 `lookupList` 构造同一批 provider ⇒ 递归重入（栈溢出面，见 §4）
- **建议**：逐个 `try` 包裹（`for(p in list){ try{...}catch(e){ log.warn(...) } }`），失败时**不**置 `loaded`（或只对“容器不存在”置位）；把扫描移到锁外，先拿到列表再加锁合并；至少用 `f_log` 记一条 warn（本包已 `internal import fountain::f_llm.f_log.*`，见 #11，说明日志被删过）

### [一般][存量] `LLMConf.auth` 注释承诺支持 `secretRef:env:NAME`，全仓没有任何解析实现，auth 原样进 `Bearer`

- **位置**：`f_llm/src/model/po/LLMConf.cj:52-54`（`/** 鉴权 KEY，或 secretRef:env:NAME */`）；使用点 `f_llm/src/search/DeepSeekSearchProvider.cj:120-127`
- **来源**：存量（快照模式无 diff）
- **判据**：review-checklist §14「承诺了但没实现」（双证）
- **证据**：静态确定 —— 承诺源：上述字段注释；缺失证据：全仓 `grep -rn "secretRef"` 只命中这一行注释（另一命中是 `fprobe/README.md:350` 明确写“只认明文 KEY，不解析 `secretRef:`”），`f_llm/src` 内没有任何 `getenv`/Secret 解析器接到 `LLMConf.auth`；消费点都是字符串直用：`search/DeepSeekSearchProvider.cj:123` 与 `embedding/Embedding.cj:131-132` 拼 `Bearer`、`llm/TokenCounter.cj:72` 经 `util/http` 拼 `Bearer`、`balance/BalanceQueriers.cj:246-256` 把同一字段当 `AK:SK` 拆开
- **描述**：运维照注释把 `auth` 配成 `secretRef:env:DEEPSEEK_KEY`，请求会带 `Authorization: Bearer secretRef:env:DEEPSEEK_KEY` 发出去并得到 401，错误现象与真实原因无关；同时会误以为“库里不存明文”，实际明文仍必须写进 `llm_conf.auth`。同一字段还承担“明文 KEY / secretRef / 云厂商 AK:SK”三种语义（`balance/BalanceQueriers.cj:246-256` 把 `:` 前当 AccessKey），任何解析器落地前必须先定互斥规则
- **建议**：二选一——(a) 在配置装载期（`LLMConfSource` 四个来源的统一收口处）解析 `secretRef:env:`，只在内存里保留明文，解析失败启动即报错；(b) 删掉注释里的 `secretRef` 承诺，并在 README 的 `auth` 行写明“仅明文，原样拼 Bearer”（与 `fprobe` 写法对齐）

### [一般][存量] `parseDeepSeekSearch` 对 JSON `null` / 字段类型漂移没有兜底，单条异常让整次搜索失败

- **位置**：`f_llm/src/search/DeepSeekSearchProvider.cj:130-147`（`:133-134` 取 `results`）、`:163-172`（`searchTextOf` 的 `value.asString().value`）
- **来源**：存量（快照模式无 diff）
- **判据**：review-checklist §11「边界 / 空值 / 契约不符」
- **证据**：静态确定（语义）+ 待确认（上游是否真会这么返回）——`JsonValue.asString()` 在非 `JsonString` 时直接 `throw JsonException`（`f_data/src/json/JsonValue.cj:56-62`），`asArray()`/`asObject()` 同理（`:63-75`）
- **描述**：`searchTextOf` 只挡了 `JsonNull`（`:166`），`"results": null` 会在 `:134` 的 `asArray()` 直接抛；`title`/`url`/`date` 若变成数字或对象，会在 `:167` 抛。函数注释写的是“字段一律走 textOf，避免 JSON null 直接 asString 抛异常”，实际只覆盖 null 一种。一旦抛出，整次搜索（含已解析好的前 N 条）全丢，模型看到的是工具异常而不是“无结果/部分结果”
- **建议**：`results` 支持 `null`→空表；`searchTextOf` 按 kind 分支（`JsonNull`→`''`、`JsonString`→`value`、数字/布尔→`toString()`、对象/数组→`''`），并给单条结果加 `try/catch` 跳过坏条目（记 warn 计数）

### [一般][存量] `EnvConfSource` / `FileConfSource` / `StaticConfSource` 不保证 `id` 唯一，快照按 id 建索引后 `all()` 丢配置，连带 `webSearch`/`webFetch` 选不到平台

- **位置**：`f_llm/src/service/LLMConfSource.cj:99-114`（`parseConfJson` 不补 id）、`:67-71`（`StaticConfSource.load` 直接复制）、`:92-95`（`FileConfSource.load`）；消费侧 `f_llm/src/llm/LLMConfsHolder.cj:242`（`byId[conf.id] = conf`）、`:129-132` / `:59-67`（`all()` 只遍历 `byId`）
- **来源**：存量（快照模式无 diff）
- **判据**：review-checklist §11「契约与实现不符」；对照实现 `StoreMetaConfSource.cj:47-49` 用 `seq++` 显式赋 id，说明“id 必须唯一”是已知前提
- **证据**：静态确定 —— `LLMConf.id` 默认 `0`（`model/po/LLMConf.cj:33-34`）；JSON 来源不写 `id` 时每条都是 0（本部分测试样例 `LLMConfSource_test.cj:24-50` 就没有 `id` 字段）；`refresh` 用 `byId[conf.id] = conf` 覆盖，`all()` 只读 `byId`；工具侧的候选来自 `LLMCandidateProvider.defaultSupplier` → `holder().all()`（`f_llm/src/llm/LLMCandidateProvider.cj:37-43`）
- **描述**：`llm_confSource=env` 或 `file:` 配 3 个模型（deepseek / zhipu / ark，不写 id，符合样例格式）时 `byId` 只剩最后一条：`all()` 返回 1 条，`pickConf` 筛不到支持 `search` 的平台就报“no llm conf available for search”；`Embedding` 的兜底遍历（`src/embedding/Embedding.cj:109-113`）同样只看到一个模型。熔断器按 id 记账（`LLMConfsHolder.cj:149-159`），id 全 0 意味着所有配置共用一个熔断状态。注意 `byName` 路径（`candidates(llmName)`）保留了全部条目，所以普通对话不受影响，只有走 `all()` 的工具与兜底路径丢配置——症状更隐蔽
- **建议**：三个来源的 `load()` 统一补 id（`id <= 0` 时 `seq++`，与 `StoreMetaConfSource` 一致），或 `refresh` 改用 `(id, provider, llmName)` 复合键并显式拒绝重复 id（`log.error` 后丢后一条，不静默覆盖）；补一条“env 源 3 条配置 → `holder.all().size == 3`”的用例

### [一般][存量] `StaticConfSource.load()` 返回浅拷贝，违反接口“整体返回快照、不要返回内部可变结构”的约定

- **位置**：`f_llm/src/service/LLMConfSource.cj:67-71`（`let copy = ArrayList<LLMConf>(); copy.add(all: confs)`）；接口约定在 `:30-34`
- **来源**：存量（快照模式无 diff）
- **判据**：review-checklist §11「契约与实现不符」；`LLMConf` 是可变的（`setConf`、`weight` 等）
- **证据**：静态确定 —— `copy.add(all: confs)` 只复制引用；`LLMConf` 的 `confJson`/`weight`/`enabled` 均可写（`model/po/LLMConf.cj:80-83` 等）
- **描述**：当前 `LLMConfsHolder.refresh` 只读不写，还没有实际串数据；但接口把“快照”写成实现契约并专门强调“不要返回内部可变结构”，实现只做了列表拷贝。任何调用方（含未来的配置归一化、测试替身）一旦修改 `load()` 返回的 `LLMConf`，源对象被永久改掉，第二次 `load()` 带出的就是被污染的数据
- **建议**：要么在注释里把语义降级为“列表不可变、元素共享”，要么 `load()` 逐条复制（PO 可加 `copy()`）；更彻底的是把 `LLMConf` 拆成不可变 view（`setConf` 只在装载期用）

### [一般][存量] DB 用例直接 `service.clear()` 清空 `llm_conf`，只由 `llm_db` 布尔开关保护；`clear()` 本身还是公开 API

- **位置**：`f_llm/src/service/LLMConfService_test.cj:63`、`:103`、`:114`、`:140`（`service.clear()`）；被调 API `f_llm/src/service/LLMConfService.cj:39-40,61-63`（`deleteAll`）
- **来源**：存量（快照模式无 diff）
- **判据**：review-checklist §11「资源/数据安全」/ §10 安全性
- **证据**：静态确定 —— 门槛只有 `LLMConfig.isDatabaseEnabled()`（`src/config/LLMConfig.cj:51-54`，读 `llm_db`），没有“测试库”二次校验；用例在开头和结尾都执行 `DELETE FROM llm_conf`（`src/dao/LLMConfDAO.cj:61-63`）
- **描述**：开发者为验证 DB 功能把 `llm_db=true` 指向共享开发库后跑 `cjpm test`，第一个用例就把所有平台模型配置（含 `auth`）清空；若中途断言失败，结尾的 `clear()` 不执行，库里留着测试用的 `sk-test-1234567890`
- **建议**：用例改用独立 schema/表名或临时库，绝不碰 `llm_conf`；`clear()` 从公共接口移除（测试需要就直接调 DAO），或改 `clearForTest()` 并加运行期环境断言

### [一般][存量] `skills` 表有 `version` 列，PO `Skill` 没有该字段；同一实体两套模型字段集互补，ORM 侧永远读不到版本

- **位置**：`f_llm/src/model/po/Skill.cj:25-50`；DDL `f_llm/tables-pg.sql:52-62`（`version INT NOT NULL DEFAULT 1, -- 技能自演进版本（§10.4）`）；对照模型 `f_llm/src/store/StoreModels.cj:109-122`
- **来源**：存量（快照模式无 diff）
- **判据**：review-checklist §2「只改类型名 / 字段漂移」/ §11「契约与实现不符」
- **证据**：静态确定 —— PO 字段是 `id/agentId/acceptedEvent/returnedEvent/title/metadata/details/functions/skillType`（`:26-43`）；store 侧 `Skill` 是 `id/title/details/functions/version`；DDL 两边的列都在
- **描述**：`@QueryMappersGenerator[table: skills]` 生成的映射以 PO 字段为准，`SELECT *` 读出的 `version` 无处可放，PO 侧也永远写不进 `version`；`MetaDAO.upsertSkill(... version ...)`（`src/dao/postgres/MetaDAO.cj:97-103`）走的是 store 模型。结果是“技能演进版本”只对 store 路径可见，任何走 PO 的工具（`SkillsFinder.querySkills` → `AgentTask` 的技能注入）拿不到版本号，无法判断技能是否更新。两套模型各缺对方 4~5 个字段，新增列只会落在一侧
- **建议**：给 PO 补 `@ORMField['version'] private var version: Int64 = 1`（读路径即可用），并在 store→PO 的适配处显式透传；或在 `doc/f_llm.md` 的模型表里写清两套模型的字段映射与“新增列必须同时加”的约定

### [轻微][存量] 包级 `imports.cj` 里残留 9 条包内零引用导入（旧 Searcher 链路的痕迹）

- **位置**：`f_llm/src/search/imports.cj:19-29`（`std.collection.concurrent.ConcurrentHashMap`、`std.time.MonoTime`、`fountain::f_log.*`、`fountain::f_util.*`、`fountain::f_llm.constant.*`、`fountain::f_llm.finder.*`、`fountain::f_llm.model.*`）；`f_llm/src/model/entity/imports.cj:23-24`（`f_base.*`、`f_data.*`）
- **来源**：存量（快照模式无 diff）
- **判据**：review-checklist §1「未使用的 import」
- **证据**：静态确定 —— `internal import` 的作用域是“当前包及其子包”（`docs/dev-guide/source_zh_cn/package/import.md:291-296`：“`internal import` 表示导入的内容在当前包及其子包（包括子包的子包）均可访问”），所以判定范围是整个 `src/search` 包：包内 4 个 `.cj` 全文检索 `MonoTime`/`ConcurrentHashMap`/`LoggerFactory`/`Logger`/`TextClip`/`Knowledge`/`Specification`/`LLM_TYPE_*`/`MODEL_NAME_*`/`*Finder` 全部零命中（`SearchResult.cj:21-25` 只在注释里提到 `KnowledgeEntity`）；`entity` 包唯一实现 `KnowledgeEntity.cj` 不引用 `f_base`/`f_data`。包内仍需保留的只有 `std.collection.*`（`ArrayList`/`HashMap`）、`f_base.*`（`resource`，`f_base/src/resource.cj:18`，`DeepSeekSearchProvider.cj:46` 在用）、`f_data.*`、`f_httpclient.*`、`model.po.*`
- **描述**：这些导入是搜索旧链路（`SearchMediartor`/`GLMSearcher`）删除后的残留；`f_log` 的残留尤其说明“注册表失败要记日志”那段被删掉了（见 #4）。不影响运行，但会误导读者以为包内还有日志/并发容器依赖
- **建议**：删除零引用导入，并顺带补回 #4 需要的日志

### [轻微][存量] `LLMConf.conf` 注释写“用 conf 属性读写 Map”，实际只有 getter，写入会被静默丢弃

- **位置**：`f_llm/src/model/po/LLMConf.cj:64-69`（注释“对外用下面的 conf 属性读写 Map”）、`:73-78`（只有 `get()`，写入口是 `setConf` `:80-83`）
- **来源**：存量（快照模式无 diff）
- **判据**：review-checklist §11「语义与注释不符」
- **证据**：静态确定 —— `public prop conf: HashMap<String, String>` 无 `mut`/`set`；`HashMap` 是引用类型，`conf.conf['k'] = 'v'` 能编译通过，但改的是 getter 每次新建的临时表，`confJson` 不变
- **描述**：读路径没问题（每次 `fromColumn(confJson)` 新建表，调用方改不到内部状态，这一点是对的）；问题在文档：注释与 README 的“`prop conf` + `setConf`”并列，容易被读成“prop 可写”。真按注释写 `conf.conf['thinking']='none'` 会静默失效且无任何报错
- **建议**：注释改成“conf 只读视图，写请用 `setConf`”，或在 `doc/f_llm.md` 的 option 表里加同样的约束

### [轻微][存量] 两个“逗号分隔列”的解析方式不一致：`Agent` 不 trim/不去空，`Skill` 去空且 trim

- **位置**：`f_llm/src/model/po/Agent.cj:47-56`（`acceptable.split(',')` / `producings.split(',')`）vs `f_llm/src/model/po/Skill.cj:45-50`（`functions.lazySplit(',', removeEmpty: true).map{f => f.trimAscii()}`）
- **来源**：存量（快照模式无 diff）
- **判据**：review-checklist §2「实现漂移」/ §11「边界」
- **证据**：静态确定（差异）+ 待确认（线上数据格式）——`String.split` 默认 `removeEmpty: false`，原串为空时返回长度 0，但 `"a,"` / `"a,,b"` 会保留空元素，`"a, b"` 会保留前导空格（`cangjie_runtime/stdlib/doc/libs/std/core/core_package_api/core_package_structs.md:8027-8042`）
- **描述**：`agents.acceptable/producings` 与 `skills.functions` 是同一种列格式（`tables-pg.sql:36-40`、`:55`），却只有后者做了归一化。手工维护的数据出现 `"created, planned"` 时 `Agent.acceptableEvents` 会产出 `" planned"`，与事件名 `"planned"` 永不相等；尾逗号会产出空事件名，被当成“接受空事件”的任务注册。当前数据严格无空格则无影响
- **建议**：抽一个 `splitCsv(text): Array<String>`（`split(',', removeEmpty: true)` + `trimAscii`）放 `model/po` 公共处，两个 PO 共用

### [轻微][存量] `defaultSearchPost` 与 `f_llm.util.http` 是同一套 HTTP 客户端构造的两次实现（含同一处 `TrustAll`）

- **位置**：`f_llm/src/search/DeepSeekSearchProvider.cj:36-50` vs `f_llm/src/util/http.cj:18-29`
- **来源**：存量（快照模式无 diff）
- **判据**：review-checklist §2「换控制流 / 跨文件复制」；`f_llm.util.http` 是现成 `public` 能力
- **证据**：静态确定 —— 步骤逐条对齐：`HttpClient(url)` → 设 header → `Accept-Encoding: identity` → `TlsClientConfig().verifyMode = TrustAll` → `client.tlsConfig(tls)` → `resource(client){...}`；差异只有 `util.http` 额外固定 `Authorization: Bearer <auth>` 与 `Accept`，`defaultSearchPost` 收任意 header 表
- **描述**：同一段“关证书校验 + 关 gzip + 用完即关”的逻辑存两份，导致 #1 的修法必须改两处，也让“为什么搜索要 TrustAll”这类决策没有唯一落点（`util.http` 的注释解释了 gzip，搜索侧解释了重定向，TLS 谁都没解释）
- **建议**：`defaultSearchPost` 改成基于 `util.http` 的变体（补一个收 header 表的重载），或把 TLS/解压/超时策略统一收进 `f_httpclient` 的一个 `newJsonClient(url, headers)` 工厂

### [轻微][存量] 三处“把坏数据/异常变成默认值”且不打日志：`searchScoreOf`、`LLMConfCodec.fromColumn`、`optionBool`

- **位置**：`f_llm/src/search/DeepSeekSearchProvider.cj:174-184`（`catch(_: Exception){ 0.0f64 }`）；`f_llm/src/model/po/LLMConfCodec.cj:35-45`（非法/空内容返回空表）；`f_llm/src/model/po/LLMConf.cj:109-115`（`v == 'true' || v == '1'`，其余一律 false，不回退 `defaultValue`）
- **来源**：存量（快照模式无 diff）
- **判据**：review-checklist §3「静默吞异常 / `case None => ()` 兜底」
- **证据**：静态确定 —— 三处都没有日志，返回值直接参与打分/配置判断
- **描述**：后果同源：坏数据被当成“合法默认”。(1) `rerank_score` 若是字符串或缺失，得分静默变 0，排序看起来正常但顺序已错；(2) `llm_conf.conf` 列被手工写成非 JSON 时整份配置静默退化成默认值（`tokenThreshold=0` 即不限长、`stream=true`），排障看不到痕迹；`parseConfJson`（`LLMConfSource.cj:106-110`）把 `conf` 当对象解析失败时同样静默丢全部选项（例如值写成数字）。(3) `stream: "TRUE"` / `"yes"` 被判成 false，与配置意图相反
- **建议**：(1)(3) 加 warn（按 key 限频），解析失败回退 `defaultValue` 而不是恒 false；(2) 保留降级行为但在 `LLMConfCodec`/`parseConfJson` 带 conf id/provider 记 warn，便于发现“库里/文件里存了坏 JSON”

### [轻微][存量] `LLMConf` 是可变的 PO，却被当作“不可变配置快照”跨线程共享（当前无写者，属设计隐患）

- **位置**：`f_llm/src/model/po/LLMConf.cj:80-83`（`setConf` 写 `confJson`）、`:56-62`（`temperature`/`alwaysThinking` 可变）；快照声明 `f_llm/src/llm/LLMConfsHolder.cj:29`（“一份不可变配置快照：刷新时整体替换，读路径无锁”）
- **来源**：存量（快照模式无 diff）
- **判据**：review-checklist §12.1「发布逸出 / 可见性」
- **证据**：待确认 —— 共享路径确定（`snapshot.byName`/`byId` 的 `LLMConf` 被多个请求线程读取，`LLMConfsHolder.cj:124-132`），缺的是“写者”：`refresh` 只读（`:233-255`），仓内也没有对快照里的 `LLMConf` 调 `setConf` 的代码
- **描述**：`LLMConfsSnapshot` 靠约定而不是类型系统保证不可变：字段全 `mut`，`setConf` 是 `public`。未来任何“运行期改一个 conf 的 stream/权重”的需求，写者会直接改到在途请求正在读的对象，既无锁也无 `volatile` 语义，编译器不会提醒
- **建议**：短期在 `LLMConfsSnapshot` 注释写明“元素只读、禁止修改”；中期给 `LLMConf` 提供只读 view（`LLMConfView` 已有先例），把 `setConf`/`weight` 的写入口收到装载器

### [轻微][存量] 测试有效性：`testStaticSourceReturnsCopy` 只断言 size，DB 用例不满足条件时静默 `return` 而不是正式 skip

- **位置**：`f_llm/src/service/LLMConfSource_test.cj:71-82`（两次 `source.load().size`）；`f_llm/src/service/LLMConfService_test.cj:57-59`、`:108-110`
- **来源**：存量（快照模式无 diff）
- **判据**：review-checklist §11（测试无法证明其声称的契约）
- **证据**：静态确定 —— 用例名声称 “ReturnsCopy”，实际只调两次 `load()` 比长度，任何实现（包括直接返回 `confs` 本体）都能通过；DB 用例在不满足条件时 `return`，框架只记为通过
- **描述**：前者让 #8 的浅拷贝问题在测试里“看起来被覆盖了”；后者让 service 层在 CI 中永远绿——`LLMConfService` 的 5 个方法（含 `clear`）没有任何自动化验证，而它正是“唯一读取入口”（`LLMConfService.cj:25-28`）
- **建议**：copy 用例改成“`load()` 后修改返回列表/元素，再 `load()` 断言源未变”；DB 用例用 `@Configure[skip: ...]`（unittest 的 `KeySkip`）显式跳过，并在 CI 另配测试库把 `llm_db=true` 跑起来

### [轻微][存量] 注册表两条注册路径对“同名”策略不一致：`@Bean` 扫描静默覆盖，`register` 抛异常，且都没有日志

- **位置**：`f_llm/src/search/SearchProvider.cj:126`（`providers[provider.provider] = provider`，扫描路径无条件覆盖）vs `:90-98`（`register` 内 `if(providers.contains(...)) throw IllegalArgumentException`）
- **来源**：存量（快照模式无 diff）
- **判据**：`skills/fountain-review/references/fountain-baseline.md` §4「同名注册（扩展 / 路由 / 插件）：**启动直接失败**，不做隐式优先级」；review-checklist §14「版本与依赖漂移 / 接线」
- **证据**：静态确定 —— 扫描路径对同名 key 直接赋值，后写覆盖先写；显式路径对同名直接抛。两条路径同时生效时（先 `register` 后首次 `get` 触发扫描）表现为“显式注册的 provider 被 bean 版覆盖”，反向顺序则表现为启动抛异常，行为取决于首次调用顺序
- **描述**：当前仓内只有一个 `@Bean` provider（`DeepSeekSearchProvider`），所以还不会触发；但下游项目按 README 增加第二个 provider 时，若同名（例如两个平台都叫 `deepseek`），实际生效的是哪一个取决于 bean 扫描顺序，且没有日志。同一能力的两条注册路径语义不一致本身也会误导扩展者
- **建议**：扫描路径复用 `register` 的重名检查（或先收集再判断，重名时 `log.error` 并按基线“启动即失败”抛 `IllegalArgumentException`），让两条路径对同名给出同一结论

> 范围外提示（不计入本部分统计）：`f_llm/src/service/StoreMetaConfSource.cj:42-63` 由 `LLMConfView` 构造 `LLMConf` 时从不调用 `setConf`，而 `LLMConfView`（`src/store/StoreModels.cj:170-195`）也没有 `conf` 字段——一旦启用 store 源，`tokenThreshold`/`stream`/`chatPath`/`searchUrl` 全部丢失（`tokenThreshold=0` 即不限长）。该文件属其他分轮，请对应分报告复核。

## 优化可行性方案

> 不是缺陷，是“还能更好”。三条均无性能基线，只作为下一轮取数候选，**不进 `tasks.md`**。

### [堆内存] 搜索/抓取响应改为有界读取（与 #3 同源，这里量化“能省多少”）

- **现状**：`readEntire()` 一次物化整个响应体：命中 `Content-Length` 时 `Array<Byte>(size)` + `String.unsafeUtf8` 各一份；未命中时 `ArrayList<Byte>` 以 1KB 步进扩容（`f_httpclient/src/ExtendHttpResponse.cj:50-77`）。抓取单页时峰值 ≈ 2 × 响应体 + 解析后的 `content`；`needContent=true` 的搜索再多一份 JSON 树。生命周期：单次工具调用（秒级），但并发 8 个抓取即 8 份峰值叠加
- **方案**：`SearchPoster` 增加 `maxBytes` 参数，`readToEnd` 改为“读满上限即停并返回 `truncated`”；上限取 `LLMConfig.getFetchMaxBytes()`（已有配置项，`WebFetchFunction.cj:59`）+ 少量 JSON 余量
- **预期**：单次抓取峰值从 O(响应体) 降到 O(上限)（默认上限 20KB 量级）；具体降幅需实测
- **代价**：`SearchPoster` 是 `public type`（`:34`），签名属对外契约，需同步测试与调用方；截断后 JSON 可能不完整，解析前须判 `truncated`
- **验证**：同一组页面（1MB / 50MB / 500MB）改前改后对比 `getUsedHeapSize()` 峰值、RSS、单次耗时，各 30 轮取中位数
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] 复用 `HttpClient` / 连接，避免每次搜索都重新 TCP+TLS 握手

- **现状**：`defaultSearchPost` 每次调用 `HttpClient(url)` + `resource` 立即 `close()`（`DeepSeekSearchProvider.cj:37-49`），没有连接复用；一次 `webSearch` = 一次完整 TLS 握手（1~2 RTT）
- **方案**：provider 持有长生命周期 client（按 endpoint 缓存），或由 `f_httpclient` 提供按 baseUrl 的池；header 每次请求覆盖
- **预期**：省掉每次握手的 RTT 与 CPU（ECDHE/RSA 运算），P50 下降量待测
- **代价**：连接/池的生命周期与关闭责任转移；`HttpClient` 是否可被多线程并发复用需先查 stdx 文档（它持可变 `request` 字段，`f_httpclient/src/httpclient.cj:38`，直接共享可能不安全）——未确认前不要落地
- **验证**：同机同 endpoint 连续 200 次 search，改前/改后 P50/P95 与 `cjprof` 中 TLS 相关占比
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] `LLMConf.conf` 解析结果缓存（减少每请求的重复 JSON 解析与 HashMap 分配）

- **现状**：`conf` getter 每次 `LLMConfCodec.fromColumn(confJson)`：`trimAscii` + `JsonValue` 解析 + 新建 `HashMap`（`LLMConf.cj:73-78`、`LLMConfCodec.cj:35-45`）；`option/optionInt/optionBool/tokenThreshold/streamable` 每次调用各触发一次（`:93-130`）。一次请求链路上 `tokenThreshold`（`LLMConfsHolder.cj:135-146`）、`stream`（`LLMConf.cj:125-130`）、`chatPath` 等会被多处读取
- **方案**：装载完成后预解析一次并缓存（`private var cached: ?HashMap`，`setConf` 时置 `None`）；或直接把 `confJson` 换成 `HashMap` 字段、只在写库时序列化
- **预期**：每请求省 N 次小 JSON 解析（N = option 读取次数，静态可见 ≥3），分配量同降；绝对耗时待测
- **代价**：引入可变缓存字段，与 #16 的“快照只读”假设冲突，需保证只在装载期写；缓存后 `conf` 仍须返回副本或只读视图
- **验证**：`cjpm bench -O2` 跑“1 万次 candidates()+option 读取”改前改后中位数；`cjprof` 看 `fromColumn/JsonValue.fromStr` 自耗时占比
- **证据状态**：`无基线（待验证，不进 tasks）`

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 搜索/抓取端到端延迟中 TLS 握手占比可观（每请求新建 client） | `f_llm/src/search/DeepSeekSearchProvider.cj:36-50` | 握手耗时占比、P50/P95 | 同机连续 200 次 search，分段计时（建连/握手/首字节/读完）+ `cjprof record` |
| 2 | 每请求 3~5 次 `LLMConf.conf` 解析的自耗时进入前 10 | `f_llm/src/model/po/LLMConf.cj:73-78`、`:93-130` | `fromColumn` 自耗时占比 | `cjprof` 跑 10 分钟稳态对话负载（≥1k 请求），按函数聚合 |
| 3 | `need_content=true` + count=50 时单次搜索的峰值堆由响应体主导 | `f_llm/src/search/DeepSeekSearchProvider.cj:105-107` | 峰值堆、单条 summary 字节分布 | 构造 50 条全正文响应，记录 `getUsedHeapSize()` 峰值与 `cjprof heap` |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_llm/src/model/entity/imports.cj` | .cj | ✅ | 包级 `internal import`；`f_base`/`f_data` 在 entity 包零引用 → #11 |
| 2 | `f_llm/src/model/model.cj` | .cj | ✅ | 包级导入；`ArrayList` 被 `SkillReferenceParam.cj:26` 使用、`f_llm.constant` 被 `Specification.cj`/`KnowledgeParam.cj` 使用；`f_data` 保留（宏展开可能引用），不判 |
| 3 | `f_llm/src/model/po/Agent.cj` | .cj | ✅ | 两个事件列 getter 均为 `split(',')` → #13；DDL `agents` 列齐全 |
| 4 | `f_llm/src/model/po/LLMConf.cj` | .cj | ✅ | 配置契约核心；#5 #12 #15 #16、优化方案 3 |
| 5 | `f_llm/src/model/po/LLMConfCodec.cj` | .cj | ✅ | JSON↔Map 唯一入口；非法内容静默空表 → #15 |
| 6 | `f_llm/src/model/po/LLMConf_test.cj` | .cj | ✅ | 4 个用例覆盖字段/option/codec/placeholder，断言与实现一致 |
| 7 | `f_llm/src/model/po/MemorySummary.cj` | .cj | ✅ | 纯 PO，与 `memory_summaries` DDL 列一致，无逻辑 |
| 8 | `f_llm/src/model/po/Skill.cj` | .cj | ✅ | `functionNames` 归一化正确（#13 对照）；缺 `version` 映射 → #10 |
| 9 | `f_llm/src/model/po/SkillReference.cj` | .cj | ✅ | 纯 PO；DDL 该表无 id，PO 无 id，映射一致 |
| 10 | `f_llm/src/model/po/Todo.cj` | .cj | ✅ | `predecessor` 双向 JSON；空串经 `fromStr` 得 `JsonNull`（`f_data/src/json/JsonValue.cj:207-211`）再 `convert` 失败回落空表，未构成缺陷；两个 `public` 方法仓内无调用（对外可达，仅记录） |
| 11 | `f_llm/src/model/po/TokenUsage.cj` | .cj | ✅ | `usageTime` 构造时求值（12 位定长、分钟粒度），与 `idx_usage_agent` 用途一致；DDL 有 id 而 PO 无 id（identity 自增，插入不受影响），不判 |
| 12 | `f_llm/src/search/DeepSeekSearchProvider.cj` | .cj | ✅ | #1 #2 #3 #6 #14 #15；优化方案 1、2 |
| 13 | `f_llm/src/search/DeepSeekSearchProvider_test.cj` | .cj | ✅ | 8 个用例（归一化/need_content/fetch/URL 覆盖/3xx/5xx）；未覆盖 `defaultSearchPost`（TLS/超时）与非字符串字段 |
| 14 | `f_llm/src/search/SearchProvider.cj` | .cj | ✅ | 接口契约 + 注册表；#4 #18；`register/get/names` 均有调用方（`register` 仅测试调用，属对外 API） |
| 15 | `f_llm/src/search/SearchResult.cj` | .cj | ✅ | 兼容类，被 `KnowledgeEntity.cj:37,45` 使用；注释与实现一致，非死代码 |
| 16 | `f_llm/src/search/imports.cj` | .cj | ✅ | 7 条零引用导入 → #11 |
| 17 | `f_llm/src/service/LLMConfService.cj` | .cj | ✅ | 纯委托 DAO（符合分层基线）；`clear()` 对外暴露 → #9 |
| 18 | `f_llm/src/service/LLMConfService_test.cj` | .cj | ✅ | 真库用例；`clear()` 破坏性 → #9；静默 return → #17 |
| 19 | `f_llm/src/service/LLMConfSource.cj` | .cj | ✅ | 四个来源；id 不唯一 → #7；浅拷贝 → #8；`File.readFrom` 整文件读入（配置文件，量小，不计缺陷） |
| 20 | `f_llm/src/service/LLMConfSource_test.cj` | .cj | ✅ | 6 个用例；`testStaticSourceReturnsCopy` 断言无效 → #17；样例 JSON 无 id，正是 #7 的触发形态 |

合计：`.cj` 20 个 / `.md` 0 个 / 共 20 个，全部读完。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 18 | 安全性：#1（TrustAll）、#5（凭据假承诺）、#9（测试清库）；正确性/契约：#2 #3 #4 #6 #7 #8 #10 #12 #13 #15 #18；设计：#10（双模型）、#14（重复客户端）、#16（可变快照）；语言特性：#12（prop 只读与 `mut` 语义）、#5（字符串拼 header）、#7（HashMap 覆盖语义）；可读性：#11；测试有效性归 #17。逐文件核对未命中项：`Todo.predecessor` 空串路径、`TokenUsage.usageTime` 定长编码、`SkillReference` 无 id 映射、`LLMConfService` 每语句重新取 `executor()`（符合基线 §2）均成立 |
| §1 死代码 | 2 | 两个 `imports.cj` 的零引用导入（#11）。其余机械检查：7 个 `private` 成员（`mutex`/`providers`/`loaded`/`poster`/`confs`/`path`/`text`）全仓搜均有使用；`internal`（缺省）顶层函数 `defaultSearchPost`/`ensureOk`/`headersOf`/`searchSummaryOf`/`searchTextOf`/`searchScoreOf` 全部被本包调用；`protected` 0 个；`public` 所属顶层类型均为 `public`（对外可达），按硬原则一不判，`Todo.predecessor` 两个重载与 `LLMConfService.save/update/findById/clear` 仓内仅测试调用，记为对外 API 信息；`return`/`throw` 之后同层语句、恒真恒假分支：无；局部变量与形参：`defaultSearchPost` 的 `tls`、`parseDeepSeekSearch` 的 `summary/obj`、`parseConfJson` 的 `obj/conf` 均被读取 |
| §2 重复逻辑 | 3 | #10（同表两套模型字段漂移）、#13（逗号列解析漂移）、#14（`defaultSearchPost` vs `util.http`）。另做的两两比对：`search()`/`fetch()` 结构同形但 body 字段、错误动作名、解析器都不同，合并只加参数层，按误报边界不单列；`LLMConfService` 5 个方法是一层委托（基线要求）；四个 `LLMConfSource.load()` 数据源各自独立；`Agent` 两个事件 prop 同形但对应不同列，属可读性展开，不单列 |
| §3 空实现 | 2 | #4（`ensureLoaded` 的 `catch(_: Exception){ }` + 永久置位）、#15（三处异常→默认值）。无 `TODO`/`FIXME`、无空函数体；`LLMConfCodec.fromColumn` 的空表降级有注释说明是有意设计，只按可观测性并入 #15 |
| §4 栈溢出 | 1 | 并入 #4（待确认）：`ensureLoaded` 持锁调用 `lookupList`，若 provider 构造函数回调 `get()`/`register()`，重入的 `ensureLoaded` 因 `loaded` 仍为 `false` 会再次构造同一批 provider ⇒ 递归重入。本部分文件自身无递归函数（`parseConfJson`/`parseDeepSeekSearch` 均为迭代），无自引用结构、无递归 `clone`；`JsonValue.fromJson` 的递归在 `f_data`，深度由配置/响应 JSON 嵌套层数决定 |
| §5 OOM | 1 | #3（`readEntire` 全量物化 + `Content-Length` 预分配 + `count` 无上限）。其余：`parseConfJson` 读整个配置文件（运维可控、量小）；注册表 `providers` 只随显式注册增长（有界） |
| §6.1 热点瓶颈 | 0 | 未提供 `cjprof`/`cjpm bench` 数据，热点结论不成立；可疑点全部降为「待验证假设」1-3，不参与严重度统计 |
| §6.2 大粒度锁 | 1 | 并入 #4：`ensureLoaded` 在 `synchronized(mutex)` 内执行 `lookupList`（会跑任意 provider 构造函数），锁持有时长取决于 bean 构造；只在首次扫描发生一次，未构成热点，按“锁内执行外部逻辑”记为设计风险。`names()`/`get()` 锁内只做一次 HashMap 遍历/查找，可接受 |
| §6.3 并发串行 | 0 | 本部分无 `spawn`/`Future`/线程池；`search`/`fetch` 各是一次同步 HTTP 调用，不存在“并发度配成 1” |
| §6.4 低效算法 | 0 | 未见随输入规模增长的复杂度问题：`parseDeepSeekSearch` 单趟 O(结果数)、`parseConfJson` 单趟；`conf` 每次重解析是常数级开销，已列入优化方案 3 与待验证 2 |
| §7 降堆内存方案 | 1 | 优化方案 1（有界读取），`无基线（待验证）`；`conf` 缓存同时降分配，但主要收益在 CPU，归入方案 3 |
| §8 降 CPU 方案 | 2 | 优化方案 2（client/连接复用）、方案 3（conf 解析缓存），均 `无基线（待验证）` |
| §9 local mode 可行性 | 0 | 本部分没有“函数内创建、函数内销毁且不逃逸”的大对象：`parseDeepSeekSearch` 的 `ArrayList<SearchResultItem>` 作为返回值逃逸，`readEntire` 的字节数组转成 `String` 后进入 JSON 树；且收益只能靠峰值内存证明，当前无数据 |
| §11 现有代码的 BUG（存量） | 18 | 本部分 18 条全部为存量（快照模式无 diff）。已核对但未成立的边界：`Todo.predecessor` 空串（`fromStr("")` → `JsonNull`，`convert` 失败回落空表）、`TokenUsage.usageTime` 12 位定长拼接、`ensureOk` 的 3xx/4xx 分支、`createConfSource('file:')` 空路径、`parseDeepSeekSearch` 缺 `results` 键返回空表、`DataObject.populate` 返回值被忽略（`f_data/src/base/DataObject.cj:194-206`，Iterable 分支不会返回 `None`）、DDL 允许 NULL 而 PO 非 `Option`（`f_orm` 对非 `Option` 字段走 `FieldQueryMapper.populate` 的 `if(let Some(id) <- ...)` 跳过分支，NULL 落到字段默认值，不抛） |
| §12 并发安全与锁粒度 | 2 | #4（锁内 bean 扫描 + 重入递归，待确认）、#16（可变 PO 作为“不可变快照”共享，待确认）。已证明安全的部分：注册表三个静态字段（`mutex`/`providers`/`loaded`）读写全部在 `synchronized(mutex)` 内，`loaded` 的双重检查在锁内完成，无检查-然后-写入竞态；`DeepSeekSearchProvider` 只持有不可变 `poster`，可并发调用（`defaultSearchPost` 每次新建 client） |
| §14 功能完备性与 README 覆盖 | 2 | #5（`secretRef` 注释承诺、无实现）、#18（同名注册策略与基线 §4 不符）。另核对：`SearchProvider.search/fetch` 的“失败必须抛异常”契约，实现确实抛 `SearchHttpException`（`ensureOk`）与 `JsonException`（解析），未用空列表冒充失败；`searchEndpoint/fetchEndpoint` 的 conf 覆盖均已接线（`searchUrl`/`fetchUrl`）；本部分无 `.md`，README 覆盖面留待含 README 的分轮 |
| 文件覆盖（§13 等） | 20/20 | `files/f_llm.part19.txt` 共 20 行，20 个 `.cj` 全部读完，无 `.md`；§13 文档一致性本部分无对象 |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 1 |
| 一般 | 9 |
| 轻微 | 8 |
| 优化方案（堆内存 / CPU） | 1 / 2 |

存量 18 条（严重 1、一般 9、轻微 8），是否纳入修复待用户决定；本部分不含「本次改动」引入的问题。

## 总评

这一部分的代码形态是“PO + 薄 Service + 搜索适配器”，分层和命名干净：`LLMConf` 把 `conf` 列收敛到唯一 codec，`LLMConfSource` 把四种配置来源抽象掉，`DeepSeekSearchProvider` 把 3xx 拒绝与字段归一化写清楚，可读性在模块内属于较好的一档。

阻塞项集中在出站 HTTP 这一层：`TrustAll`（#1）让携带 API key 的搜索/抓取可被中间人劫持并注入模型上下文，上线前必须处理；#2（无自身超时、继承被 embedding 改写的全局值）与 #3（响应无上限物化）是同一个“HTTP 客户端没有业务边界”的两面，表现为偶发失败或一次大页面把进程顶到 OOM。三者修法互相独立、都不大，建议一起排。

其次是配置正确性：#7 让 `env`/`file` 这两种文档化来源在多模型场景下经 `all()` 丢配置（直接影响 `webSearch`/`webFetch` 选平台），#4 让一次 provider 构造失败永久静默关闭搜索能力，#5 让运维按注释写 `secretRef` 必然 401 —— 都不会崩，但都属于“功能在特定配置下静默不可用”，排期紧跟安全项。#8/#9/#10/#17/#18 属于契约与测试的欠账，可合并成一次“配置装载与测试夹具”清理。轻微项（死导入、注释与实现不符、逗号列归一化、重复的 client 构造）建议随手带上，不必单独排期。
