## STDX依赖
配置环境变量：`export CANGJIE_STDX_DYNAMIC_PATH=/path/to/dynamic_stdx`

大模型API
开发者只需要关注组织文化、智能体、技能描述和FunctionCalling，以及事件定义和编排。
大模型每次都要返回一个函数调用，每个函数调用都要返回一个事件数据和事件名；智能体按照函数调用的返回构造并向框架发送新事件。
智能体访问大模型前可以按照指定的上下文策略裁剪或压缩上下文。
---

## 常量定义
### 大模型类型
`public type LLMType = String`
LLMType的取值：
text embedding tokenizer rerank code video audio image prune
这些取值跟大模型平台定义的类型不一致，这些字符串是框架内部定义的大模型配置要用来做什么
```cj
public type LLMType = String 
//text embedding tokenizer rerank code video audio image prune
public const LLM_TYPE_TEXT = 'text'
public const LLM_TYPE_EMBEDDING = 'embedding'
public const LLM_TYPE_TOKENIZER = 'tokenizer'
public const LLM_TYPE_RERANK = 'rerank'
public const LLM_TYPE_CODE = 'code'
public const LLM_TYPE_VIDEO = 'video'
public const LLM_TYPE_AUDIO = 'audio'
public const LLM_TYPE_IMAGE = 'image'
//search是一类工具接口，目前智谱提供了这个接口，由于也依赖智谱的鉴权KEY，也把它当作一个大模型配置
public const LLM_TYPE_SEARCH = 'search'
```

### 角色
```cj
public type Role = String
public const ROLE_SYSTEM = "system"
public const ROLE_USER = "user"
public const ROLE_ASSISTANT = "assistant"
public const ROLE_TOOL = "tool"
```

### 技能类型
主技能随智能体一起完整加载，辅助技能采用渐进式披露，跟随智能体辅助技能的元数据列表，后按照需要加载具体的技能。
system永远排在前面，会话过程中加载的辅助技能也会插入到assistant/user/tool等消息的前面，其它system的后面。
```cj
public type SkillType = String
public const SKILL_TYPE_PRIMARY = 'primary'
public const SKILL_TYPE_AUXILIARY = 'auxiliary'
```

### 思考开关
```cj
public type ThinkingSwitch = String
public const THINGKING_ENABLED = 'enabled'
public const THINGKING_DISABLED = 'disabled'
```

### 上下文策略名
```cj
public type ContextPrunerName = String
/**
 * 保留全部
 */
public const CONTEXT_PRUNER_RETAIN = "Retain"
/**
 * 保留最新
 */
public const CONTEXT_PRUNER_LAST_N = "LastN"
/**
 * 摘要
 */
public const CONTEXT_PRUNER_SUMMARY = "Summary"
/**
 * 提取关键词
 */
public const CONTEXT_PRUNER_KEYWORDS = "Keywords"
/**
 * system单独一个策略，assistant+user+tool另外一个策略
 */
public const CONTEXT_PRUNER_DRC = "DRC"
/**
 * 上下文饱和后执行一个指定策略
 */
public const CONTEXT_PRUNER_SATURATION = "Saturation"
```

## 数据定义：`fountain::f_llm.model.po`
### token用量数据定义
```cj
@DataAssist[fields]
@QueryMappersGenerator[table: llm_token_usage]
public class TokenUsage {
    @ORMField['llm_id']
    private var llmId: Int64 = 0
    @ORMField['agent_id']
    private var agentId: Int64 = 0
    @ORMField['session']
    private var session: String = ""
    @ORMField['prompt_tokens']
    private var prompt: Int64 = 0
    @ORMField['completion_tokens']
    private var completion: Int64 = 0
    @ORMField['total_tokens']
    private var total: Int64 = 0
    @ORMField['cached_tokens']
    private var cached: Int64 = 0
    @ORMField['usage_time']
    private var usageTime: Int64 = {=>
        let now = DateTime.now()
        now.year * 100000000 + now.month.toInteger() * 1000000 + now.dayOfMonth * 10000 + now.hour * 100 + now.minute
    }()
}
```

### 大模型定义
```cj
@DataAssist[fields]
@QueryMappersGenerator[table: llm_conf]
public class LLMConf {
    @ORMField[true 'id']
    private var id: Int64 = 0
    @ORMField['llm_name']
    private var name: String = ''
    @ORMField['llm_type']
    private var llmType: String = ''
    @ORMField['llm_url']
    private var url: String = ''
    @ORMField['conf']
    private var conf: String = ''
    @ORMField['threshold']
    private var threshold: Int64 = 0
}
```

### 智能体定义
```cj
@DataAssist[fields]
@QueryMappersGenerator[table: agents]
public class Agent {
    @ORMField[id column: 'id']
    private var id: Int64 = 0
    @ORMField['agent_name']
    private var name: String = ''
    @ORMField['agent']
    private var agent: String = ''
    @ORMField['acceptable']
    private var acceptable: String = ''
    @ORMField['category']
    private var category: String = ''
    @ORMField['tag']
    private var tag: String = ''
    @ORMField['llm_type']
    private var llmType: String = ''
    @ORMField['llm_name']
    private var llmName: String = ''
    @ORMField['pruner']
    private var pruner: String = ''

    public prop acceptableEvents: Array<String> {
        get(){
            acceptable.split(',')
        }
    }
}
```

### 技能定义
```cj
@DataAssist[fields]
@QueryMappersGenerator[table: skills]
public class Skill {
    @ORMField[id column: 'id']
    private var id: Int64 = 0
    @ORMField['agent_id']
    private var agentId: Int64 = 0
    @ORMField['accepted_event']
    private var acceptedEvent: String = ""
    @ORMField['returned_event']
    private var returnedEvent: String = ""
    @ORMField['title']
    private var title: String = ""
    @ORMField['metadata']
    private var metadata: String = ""
    @ORMField['details']
    private var details: String = ""
    @ORMField['functions']
    private var functions: String = ""
    @ORMField['skill_type']
    private var skillType: String = ""

    @DataExclude[field]
    public prop functionNames: Iterator<String> {
        get(){
            functions.lazySplit(',', removeEmpty: true).map{f => f.trimAscii()}
        }
    }
}
```

## 数据查询接口：`fountain::f_llm.finder`
所有finder接口的实现必须是类且被`fountain::f_bean.macros.Bean`修饰
### 查询智能体
```cj
public interface AgentsFinder {
    func listAgents(): ArrayList<Agent>
    func queryAgent(id: Int64): Agent
}
```

### 知识查询接口
```cj
public interface KnowledgeFinder {
    func search(param: KnowledgeParam): ArrayList<String>
    func saveKnowledge(knowledge: Knowledge): Unit
    func findKnowledge(kind: KnowledgeKind, title: String): ?String
}
```

### 大模型查询接口
进程启动时加载全部大模型配置
```cj
public interface LLMFinder {
    func listConfs(llmTypes: Array<String>): ArrayList<LLMConf>
}
```

### 组织查询接口
```cj
public interface OrganizationFinder {
    func queryOrgCulture(agentId: Int64): String
}
```

### 技能查询接口
```cj
public interface SkillsFinder {
    func querySkills(agentId: Int64, event: String): ArrayList<Skill>
    func loadSkills(title: ArrayList<String>): ArrayList<Skill>
    func loadSkillReferences(references: ArrayList<SkillReferenceParam>): ArrayList<SkillReference>
}
```

### token数据保存接口
```cj
public interface TokenUsageSaver {
    func saveTokenUsage(usage: TokenUsage): Unit
}
```

## 向量模型接口
```cj
/**
 * 参数
 */
public class EmbeddingParam {
    public EmbeddingParam(
        public let agentId!: Int64,
        public let session!: String,
        public let input!: String,
        public let dimension!: Int64 = 1024
    ){}
}
/**
 * 响应
 */
@DataAssist[props fields]
public class EmbeddingResp {
    private var embedding: Array<Float64> = []
    private let usage: TokenUsage = TokenUsage()
}
/**
 * 开发者需要实现的抽象类，现在已经提供了GLM向量模型
 */
public abstract class AbstractEmbeddingContext {
    public AbstractEmbeddingContext(
        protected let id: Int64,
        protected let name: String,
        protected let url: String,
        protected let conf: String
    ){}
    public init(conf: LLMConf){
        this(conf.id, conf.name, conf.url, conf.conf)
    }
    public func access(param: EmbeddingParam): EmbeddingResp
}
```

### 向量模型中介者
```cj
public class EmbeddingContextMediator {
    /**
     * 注册向量模型
     * @param model 模型名称
     * @param creator 创建向量模型实例的函数
     */
    public static func register(model: String, creator: (LLMConf) -> AbstractEmbeddingContext)
    public static prop instance: EmbeddingContextMediator 

    /**
     * 访问向量模型
     * @param model 模型名称
     * @param param 参数
     */
    public func access(model: String, param: EmbeddingParam): EmbeddingResp 
}
```

## 上下文策略：`fountain::f_llm.llm.ConsextPrunerName`
对上下文执行裁剪、压缩等
```cj
/**
 * 所有策略只需要使用`fountain::f_bean.macros.Bean`修饰实现本接口的类即可。
 * 或者用`fountain::f_bean.macros.Bean`修饰初始化并返回上下文策略实例函数。
 */
public interface ContextPruner {
    /**
     * 策略名称
     */
    prop name: String
    /**
     * 策略的实现
     * @param agentId 智能体ID
     * @param session 会话标识，每次执行一个会话流程都要有一个新的标识
     */
    func prune(agentId: Int64, session: String, messages: ArrayList<ChatMessage>): ArrayList<ChatMessage>
}
```
### 保留全部
```cj
@Bean
public class RetainContext <: ContextPruner {
    public prop name: String{
        get(){
            CONTEXT_PRUNER_RETAIN
        }
    }
    public func prune(_: Int64, _: String, messages: ArrayList<ChatMessage>): ArrayList<ChatMessage>
}
```
### 保留最新
```cj
public class LastNContext <: ContextPruner {
    public LastNContext(
        private let n!: Int64 = 1
    ){}
    public prop name: String{
        get(){
            '${CONTEXT_PRUNER_LAST_N}_${n}'
        }
    }
    public func prune(_: Int64, _: String, messages: ArrayList<ChatMessage>): ArrayList<ChatMessage>
}
```
### 依赖大模型的策略
```cj
public abstract class ContextLLMPruner <: ContextPruner {
    /**
     * @param llmType 执行本策略的大模型类型
     * @param model 执行本策略的大模型名称
     * @param promptsGenerator 本策略的提示生成器
     */
    public ContextLLMPruner(
        protected let llmType!: LLMType,
        protected let model!: ModelName,
        private let promptsGenerator!: (ArrayList<ChatMessage>) -> String
    ){}
    public func prune(agentId: Int64, session: String, messages: ArrayList<ChatMessage>): ArrayList<ChatMessage>
}
```
### 上下文摘要策略
```cj
public class ContextSummaryPruner <: ContextLLMPruner {
    public init(
        llmType!: LLMType = LLM_TYPE_TEXT,
        model!: ModelName = MODEL_NAME_GLM4_7_FLASH,
        promptsGenerator!: (ArrayList<ChatMessage>) -> String = {messages => '''
- 总结下面的JSON所描述的内容，从中提取内容**要点**、**关键**内容，并以MARKDOWN格式返回。
```json
${JsonValue.tryFromData(messages.toData())}
```'''}
    ){
        super(llmType: llmType, model: model, promptsGenerator: promptsGenerator)
    }
    public prop name: String{
        get(){
            '${CONTEXT_PRUNER_SUMMARY}_BY_${llmType}_${model}'
        }
    }
}
```
### 上下文关键词策略
```cj
public class ContextKeywordsPruner <: ContextLLMPruner {
    public init(
        llmType!: LLMType = LLM_TYPE_TEXT,
        model!: ModelName = MODEL_NAME_GLM4_7_FLASH,
        promptsGenerator!: (ArrayList<ChatMessage>) -> String = {messages => '''
- 从下面的JSON所描述的内容中提取**关键词**，关键词之间以逗号分隔。
```json
${JsonValue.tryFromData(messages.toData())}
```'''}
    ){
        super(llmType: llmType, model: model, promptsGenerator: promptsGenerator)
    }
    public prop name: String{
        get(){
            '${CONTEXT_PRUNER_KEYWORDS}_BY_${llmType}_${model}'
        }
    }
}
```
### DRC
system和assist/user/tool等消息执行不同的策略
```cj
public class DRCContextPruner <: ContextPruner {
    /**
     * @param systemPruner system消息的策略
     * @param othersPruner 其他消息的策略
    public DRCContextPruner(
        private let systemPruner!: ContextPruner,
        private let othersPruner!: ContextPruner
    ){}
    public prop name: String{
        get(){
            '${CONTEXT_PRUNER_DRC}_${systemPruner.name}_${othersPruner.name}'
        }
    }
    public func prune(agentId: Int64, session: String, messages: ArrayList<ChatMessage>): ArrayList<ChatMessage>
}
```
### 饱和策略
```cj
public class SaturationContextPruner <: ContextPruner {
    /**
     * @param pruner token饱和时执行的策略
    public SaturationContextPruner(
        private let pruner!: ContextPruner
    ){}
    public prop name: String{
        get(){
            '${CONTEXT_PRUNER_SATURATION}_${pruner.name}'
        }
    }
    /**
     * 使用agentId查询智能体使用的大模型llmType和大模型名，进而找到大模型的饱和token数
     */
    public func prune(agentId: Int64, session: String, messages: ArrayList<ChatMessage>): ArrayList<ChatMessage>
}
```
### 保留最后的用户消息
```cj
public class RetainLastUserPruner <: ContextPruner {
    public RetainLastUserPruner(
        private let pruner!: ContextPruner
    ){}
    public prop name: String {
        get(){
            '${CONTEXT_PRUNER_RETAIN_LAST_USER}_${pruner.name}'
        }
    }
    /**
     * let msgs = this.pruner.prune(agentId, session, messages)
     * 如果messages没有用户消息，则返回msgs
     * 如果this.pruner.prune(agentId, session, messages)的返回包含的最后用户消息跟messages最后的用户消息一样也是返回msgs
     * 否则把messages包含的最后用户消息添加到msgs尾再返回msgs。
     */
    public func prune(agentId: Int64, session: String, messages: ArrayList<ChatMessage>): ArrayList<ChatMessage>
}
```

## 大模型访问参数与响应
```cj
@DataAssist[props fields]
public open class LLMParams {
    public LLMParams(
        private let model!: String = '',
        private var messages!: ArrayList<ChatMessage> = ArrayList<ChatMessage>()
    ){}
    private let thinking: Thinking = Thinking()
    //不能用驼峰命名法再用@FieldAlias['do_sample']修饰，因为要用这个类的实例转换为JSON，这样命名会产生JSON字段冗余
    private var temperature: Float64 = 1.0
    private var max_tokens: Int64 = 65536
}

@DataAssist[props fields]
public open class LLMToolParams <: LLMParams {
    public init(
        model!: String = '',
        messages!: ArrayList<ChatMessage> = ArrayList<ChatMessage>()
    ){
        super(model: model, messages: messages)
    }
    protected let functions: ArrayList<FunctionCall> = ArrayList<FunctionCall>()
    
    @DataExclude[prop field]
    private let fnNames = HashSet<String>()
    public func addFunctions<I>(functions: I): Unit where I <: Iterable<FunctionCall> {
        for (function in functions where !fnNames.contains(function.function.name)) {
            this.functions.add(function)
            fnNames.add(function.function.name)
        }
    }
}

@DataAssist[props fields]
public class Thinking {
    public Thinking(
        private var `type`!: ThinkingSwitch = THINGKING_ENABLED,
        private var clear_thinking!: Bool = false
    ){}
}

@DataAssist[props fields]
public class FunctionCall {
    public let `type`: String = 'function'
    public let function: Function = Function()
}

@DataAssist[props fields]
public class Function {
    public Function(
        private var name!: String = '',
        private var description!: String = '',
        private var parameters!: Parameters = Parameters(),
    ){}
}

@DataAssist[props fields]
public class Parameters { 
    public Parameters(
        private var `type`!: String = 'object'
    ){}
    private var properties: HashMap<String, Property> = HashMap<String, Property>()
    private var required: ArrayList<String> = ArrayList<String>()

    public func addRequired(name: String) {
        this.required.add(name)
    }
    public func addProperty(name!: String, `type`!: String, description!: String) {
        this.properties.add(name, Property(`type`: `type`, description: description))
    }
    public func addProperty(name: String, property: Property){
        this.properties.add(name, property)
    }
}

@DataAssist[props fields]
public class Property {
    public Property(
        private var `type`!: String = '',
        private var description!: String = ''
    ){}
}
```
```cj
@DataAssist[props fields]
public class LLMResp {
    private let usage: TokenUsage = TokenUsage()
    private let messages: ArrayList<ChatMessage> = ArrayList<ChatMessage>()
}
```
```cj
@DataAssist[fields]
public class TokenizerParams{
    public TokenizerParams(
        public let model!: String = '',
        public let messages!: ArrayList<ChatMessage> = ArrayList<ChatMessage>()
    ){}
}
```
```cj
@DataAssist[props fields]
public open class ChatMessage {
    public ChatMessage(
        private var role: Role,
        private var content: String) {}
    public init(){
        this('', '')
    }
}

@DataAssist[props fields]
public class SystemMessage <: ChatMessage {
    public init(){
        super(ROLE_SYSTEM, '')
    }
    public init(content: String){
        super(ROLE_SYSTEM, content)
    }
}

@DataAssist[props fields]
public open class AssistantMessage <: ChatMessage {
    @FieldAlias['reasoning_content']
    private var reasoningContent: String = ""
    public init(){
        super(ROLE_ASSISTANT, '')
    }
    public init(content: String){
        super(ROLE_ASSISTANT, content)
    }
}

@DataAssist[props fields]
public class UserMessage <: ChatMessage {
    public init(){
        super(ROLE_USER, '')
    }
    public init(content: String){
        super(ROLE_USER, content)
    }
}

@DataAssist[props fields]
public class ToolCallFunction {
    public ToolCallFunction(
        private var name: String,
        private var arguments: String
    ){}
    public init(){
        this("", "")
    }
}

@DataAssist[props fields]
public class ToolCallMessage <: AssistantMessage {
    @FieldAlias['tool_calls']
    private let toolCalls: ArrayList<ToolCall> = ArrayList<ToolCall>()

    public func addToolCall(call: ToolCall){
        toolCalls.add(call)
    }
    public func addFunctionCall(id!: String, toolType!: ToolType, name!: String, arguments!: String){
        addToolCall(ToolCall(id, toolType, ToolCallFunction(name, arguments)))
    }
}

@DataAssist[props fields]
public class ToolCall {
    public ToolCall(
        private var id: String,
        @FieldAlias['type']
        private var toolType: ToolType,
        private var function: ToolCallFunction
    ){}

    public init(){
        this('', '', ToolCallFunction())
    }
}

@DataAssist[props fields]
public class ToolMessage <: ChatMessage {
    private var tool_call_id: String = ""
    public init(){
        super(ROLE_TOOL, '')
    }
}
```

## 访问大模型
```cj
/**
 * 抽象大模型访问上下文，已提供智谱的实现。
 * 开发者只需要提供AbstractLLMContext的实现，并使用`fountain::f_bean.macros.Bean`修饰这个实现。
 */
public sealed abstract class AbstractLLMContext {
    private AbstractLLMContext(
        protected let id: Int64,
        protected let name: String,
        protected let llmType: String,
        protected let url: String,
        protected let conf: String,
        protected let threshold: Int64
    ) {}
    public init(conf: LLMConf){
        this(conf.id, conf.name, conf.llmType, conf.url, conf.conf, conf.threshold)
    }
    /**
     * 访问大模型
     * @param agentId 智能体ID
     * @param session 会话标识，每次执行一个会话流程都要有一个新的标识
     * @param params 访问大模型的参数
     */
    public func access(agentId: Int64, session: String, params: LLMParams): LLMResp
    /**
     * 获取大模型对接收到的messages产生的token数
     */
    public func tokenize(model: String, messages: ArrayList<ChatMessage>): Int64
}
```

### 大模型中介者
```cj
public class LLMContextMediator {
    /**
     * 注册大模型
     * @param llmType 大模型类型
     * @param model 大模型名称
     * @param creator 大模型创建者
    public static func register(llmType: LLMType, model: String, creator: (LLMConf) -> AbstractLLMContext)
    
    public static prop instance: LLMContextMediator 
    /**
     * 访问指定大模型
     * @param agentId 智能体ID
     * @param session 会话标识，每次执行一个会话流程都要有一个新的标识
     * @param llmType 大模型类型
     * @param params 访问大模型的参数
    public func access(agentId: Int64, session: String, llmType: LLMType, params: LLMParams): LLMResp 
    /**
     * 获取指定大模型的饱和token数
     */
    public func getTokenThreshold(llmType: LLMType, model: String): Int64 
    /**
     * 获取指定大模型对于指定消息的token数
     */
    public func tokenize(llmType: LLMType, model: String, messages: ArrayList<ChatMessage>): Int64 
    /**
     * 判断指定上下文对于指定的大模型是否饱和
     */
    public func saturated(llmType: LLMType, model: String, messages: ArrayList<ChatMessage>): Bool 
}
```

## 搜索
### 搜索API定义
```cj
@DataAssist[props fields]
public class SearchResult {
    private var title: String = ''
    private var content: String = ''
    private var link: String = ''
    private var media: String = ''
    private var icon: String = ''
    private var refer: String = ''
    private var publish_date: String = ''
}

@DataAssist[props fields]
public class SearchParams {
    @FieldAlias['search_query']
    private var searchQuery: String = ''
    @FieldAlias['search_engine']
    private var searchEngine: String = 'search_pro'
    private var count: Int64 = 50
    @FieldAlias['content_size']
    private let contentSize: String = CONTENT_SIZE_HIGH
    @FieldAlias['request_id']
    private let requestId: String = UUID.random().toString()
    @FieldAlias['user_id']
    private let userId: String = FOUNTAIN_LLM_AGENT
}

public abstract class AbstractSearcher {
    public AbstractSearcher(
        protected let id!: Int64,
        protected let url!: String, 
        protected let name!: String,
        protected let conf!: String
    ){}
    public init(conf: LLMConf){
        this(id: conf.id, url: conf.url, name: conf.name, conf: conf.conf)
    }
    public func search(keywords: String, count: Int64): ArrayList<SearchResult>
}
```


### 搜索中介者
```cj
public class SearchMediator {
    /**
     * 注册搜索引擎
     * @param engine 搜索引擎名称
     * @param creator 搜索引擎创建者
     */
    public static func register(engine: String, creator: (LLMConf) -> AbstractSearcher)
    public static prop instance: SearchMediator 

    /**
     * 搜索
     * @param engine 搜索引擎名称
     * @param keywords 关键词
     * @param count 搜索结果数量
     * @return 搜索结果
     */
    public func search(engine: String, keywords: String, count: Int64): ArrayList<SearchResult> 
}
```

## 函数调用
### `fountain::f_llm.FunctionCalling`
```cj
/**
 * 函数调用结果，本模块是fcoder的辅助模块，而fcoder依赖f_egraph定义的事件和流程
 */
public struct FunctionResult {
    /**
     * 函数调用结果
     * @param event 本函数的结果要包装的事件名称
     * @param result 函数调用结果，要么是简单字符串，要么是MARKDOWN格式的文本
     */
    public FunctionResult(
        public prop event!: String,
        public prop result!: String
    ){}
}
public interface CommonFunctionCalling {
    /**
     * JSON SCHEMA形式描述的大模型函数定义
     */
    prop definition: JsonObject
    /**
     * 函数名称
     */
    prop name: String
    /**
     * 函数描述
     */
    prop description: String 
    /**
     * 函数调用，这个函数供agent调用，开发者实现`func call(params: T): FunctionResult`即可
     * @param params 函数参数
     * @return 函数调用结果
     */
    func call(json: JsonObject): FunctionResult
}
/**
 * 此接口的实现必须是类且被fountain::f_bean.macros.Bean修饰，只要被`@Bean`修饰本接口的实现即可完成函数的注册
 */
public interface FunctionCalling<T> <: CommonFunctionCalling where T <: DataFields<T> {
    /**
     * JSON SCHEMA形式描述的大模型函数定义
     * 默认实现调用fountain::f_data.json的JsonObject.toJsonSchema<T>()扩展函数获得参数定义，并把本接口的name和description属性与从泛型实参转换来的Json作为大模型函数定义
     */
    prop definition: JsonObject 
    /**
     * 函数名称
     */
    prop name: String
    /**
     * 函数描述
     */
    prop description: String
    /**
     * 函数调用。默认实现只抛出FunctionCallingException
     * @param params 函数参数
     * @return 函数调用结果
     */
    func call(params: T): FunctionResult
    /**
     * 函数调用，这个函数供agent调用，开发者实现`func call(params: T): FunctionResult`即可
     * @param params 函数参数
     * @return 函数调用结果
     */
    func call(json: JsonValue): FunctionResult {
        DataObject<T>.populate(json.toData()).getOrThrow() |> call
    }
}
```
### 大模型回复的解析函数
本函数不做任何事，仅仅是把大模型返回的JSON解析为Answer对象
```cj
@DataAssist[props fields]
public class Answer {
    @JsonStringSchema[description:'流程下一步的事件名称']
    private var event: String = ''
    @JsonStringSchema[description:'你的回复，将作为流程下一步事件的参数']
    private var answer: String = ''
}

@Bean
public class AnswerFunction <: FunctionCalling<Answer> {
    /**
     * 函数名称
     */
    public prop name: String {
        get(){
            'answer'
        }
    }
    /**
     * 函数描述
     */
    public prop description: String {
        get(){
            '如果需要直接输出回复，而不依赖其它函数的结果，务必使用此函数传递回复'
        }
    }
    /**
     * 用来解析大模型的返回
     * @param params 函数参数
     * @return 函数调用结果
     */
    public func call(params: Answer): FunctionResult {
        FunctionResult(event: params.event, result: params.answer)
    }
}
```

### 技能加载函数
```cj
@DataAssist[props fields]
public class SkillLoading {
    @JsonStringSchema[description:'流程当前步骤的事件名称']
    private var event: String = ''
    @JsonStringSchema[description:'技能标题，具备唯一性']
    private var title: String = ''
}

@Bean
public class SkillLoadingFunction <: FunctionCalling<SkillLoading> {
    private let skillsFinder = lookup<SkillsFinder>()
    /**
     * 函数名称
     */
    public prop name: String {
        get(){
            'loadSkill'
        }
    }
    /**
     * 函数描述
     */
    public prop description: String {
        get(){
            '加载技能详细描述'
        }
    }
    /**
     * 用来加载技能详细描述
     * @param params 函数参数
     * @return 函数调用结果
     */
    public func call(params: SkillLoading): FunctionResult {
        FunctionResult(event: params.event, result: skillsFinder.loadSkill(params.title), resultType: ResultType.Skill)
    }
}
```

## 搜索

## 智能体的定义
1. 使用事件名+agent.id查询skill
   - 一个智能体可以有若干主要技能和若干辅助技能，也可以没有
2. 把agent.agent+skill.details组成完整的提示词模板
   技能包含主技能和辅助技能，组织文化、智能体描述、主技能描述、辅助技能元数据拼在一起作为一个system消息
   ```md
   组织文化
   ===
   ${culture}

   > **重要提示**：标注 ⚠️ 的内容为特别提醒，需要重点关注，请勿忽略。

   智能体描述
   ===
   ${agent.agent}
   ___

   技能列表
   ===
   # 主技能
   ## 技能标题：${skill.title}
   ${skill.details}
   ___

   # 辅助技能元数据
   ## 技能标题：${skill.title}
   ${skill.metadata}
   ___
   ```
3. 把exec(e: Event)的e.data做以下转换((e.data as ToData)?.toData()).getOrThrow() as SimpleDataObject，
   将转换后的实例作为模板参数替换提示词模板中的{{...}}占位符
4. 用agent.llmType agent.llmName查询大模型
5. 用替换后的提示词+函数列表访问大模型
6. 用大模型返回的结果访问函数
7. 用函数返回的结果构造事件作为智能体的返回
8. 控制上下文长度的策略接口和若干实现
     #### 上下文策略（fountain::f_llm.llm.ContextPruner的子类型）：
     - A：Retain（RetainContext）：保留全部上下文
     - B：LastN（LastNContext）：用初始化参数指定N的具体数
       - 这个策略的名称是'LastN_${n}'，n是初始化指定的具体数
     - B：Summary（ContextSummaryPruner）：对全部上下文总结概要
       - 这个策略的名称是'Summary_BY_${llmType}_${model}'，llmType和model都是初始化参数
       - llmType是大模型可以做的事情，可取的值: text code image video audio embedding rerank tokenizer。
       - model是大模型的名称
     - D: Keywords（ContextKeywordsPruner）：对全部上下文提取关键词
       - 这个策略的名称是'Keywords_BY_${llmType}_${model}'，llmType是大模型可以做的事情，可取的值: text code image video audio embedding rerank tokenizer。
       - model是大模型的名称
     - E：DRC（DRCContextPruner）：对system和其他消息执行不同的上下文策略
       - 这个策略的名称是'DRC_BY_${systemPruner.name}_${otherPruner.name}'。
     - F：饱和上下文（SaturationContextPruner）：
       - 这个策略的名称是'Saturation_${pruner.name}'
       - 上下文饱和时执行指定策略，
       - 饱和token数在大模型配置中指定，
       - 可以用agentId查询到智能体使用使用的大模型，进而确定大模型配置的饱和token数
         - 不同的大模型饱和token数可能不同，
           - 通常支持1M上下文的大模型在上下文达到10%~15%会产生严重幻觉，
           - 支持200K上下文的大模型在上下文达到80K时会产生严重幻觉。
           - Keywords和Summary两个策略依赖大模型，要注意给执行策略的大模型发送的上下文不要超过它的饱和token数

## todo
```cj
package fountain::f_llm.finder
public interface TodoFinder {
    /**
     * 保存待办
     * @param task 待办任务名称
     * @param todos 当前task的待办列表
     */
    func save(task: String, todos: ArrayList<Todo>): Unit
    /**
     * 列出待办
     * @param task 待办任务名称
     * @return 待办列表
     */
    func list(task: String): ArrayList<Todo>
    /**
     * 更新待办状态
     * @param task 待办任务名称
     * @param id 待办ID
     * @param status 待办状态
     * @return 更新的待办数量，如果返回的值不是1表示参数错了，或者待办不存在
     */
    func updateStatus(task: String, id: Int64, status: String): Int64
}
```

```cj
package fountain::f_llm.tool
@DataAssist[props fields]
public class TodoSavingParam {
    @JsonStringSchema[description:'流程下一步骤的事件名称']
    private var nextEvent: String = ''
    @JsonStringSchema[description:'任务名称']
    private var task: String = ''
    @JsonArraySchema[description:'待办列表']
    private var todos: ArrayList<TodoSaving> = ArrayList<TodoSaving>()
}
@DataAssist[props fields]
public class TodoSaving {
    @JsonStringSchema[description:'待办标题']
    private var title: String = ''
    @JsonStringSchema[description:'待办详述']
    private var content: String = ''
    @JsonStringSchema[description:'待办状态']
    private var status: String = TODO_STATUS_PENDING
    @JsonArraySchema[description:'前置待办ID列表']
    private var predecessor: ArrayList<Int64> = ArrayList<Int64>()
}
@DataAssist[props fields]
public class TodoListParam{
    @JsonStringSchema[description:'流程下一步骤的事件名称']
    private var nextEvent: String = ''
    @JsonStringSchema[description:'任务名称']
    private var task: String = ''
}
@DataAssist[props fields]
public class TodoStatusParam{
    @JsonStringSchema[description:'流程下一步骤的事件名称']
    private var nextEvent: String = ''
    @JsonStringSchema[description:'任务名称']
    private var task: String = ''
    @JsonStringSchema[description:'待办ID']
    private var id: Int64 = 0
    @JsonStringSchema[description:'新的待办状态']
    private var status: String = ''
}
```

```cj
package fountain::f_llm.tool
@ToolCall
public class TodoFunction {
    @FunctionDefinition[
        name: 'addTodo',
        description: '添加待办'
    ]
    public func addTodo(param: TodoSavingParam): FunctionResult 

    @FunctionDefinition[
        name: 'todoList',
        description: '查询全部待办'
    ]
    public func todoList(param: TodoListParam): FunctionResult 
    @FunctionDefinition[
        name: 'updateTodoStatus',
        description: '更新待办状态'
    ]
    public func updateStatus(param: TodoStatusParam): FunctionResult 
}
```

## tool call 函数定义
可以在一个类定义多个tool call函数
```cj
/**
 * 用来修饰类的公共实例函数，这个类必须被@ToolCall宏修饰
 */
@Annotation[target: [MemberFunction]]
public class FunctionDefinition {
    public const FunctionDefinition(
        public let name!: String,
        public let description!: String
    ){}
}
```

```cj
macro package fountain::f_llm.macros
/**
 * 用来定义tool call函数的宏，这个宏用来修饰类，被它修饰的类将被注册到fountain::f_bean，
 * 并且被它修饰的类的公共实例函数将被注册为tool call函数。
 * 只有被@FunctionDefinition修饰的函数才会被注册为tool call函数，否则将抛出异常。
 */
public macro ToolCall(input: Tokens): Tokens 
/**
 * 用来修饰类，这个类将被注册到fountain::f_bean，并且被它修饰的类的公共实例函数将被注册为tool call函数。
 * 只有被@FunctionDefinition修饰的函数才会被注册为tool call函数，否则将抛出异常。
 * 所不同的是这个宏的公共实例函数交被织入符合条件的切面。
 */
public macro WeavedToolCall(input: Tokens): Tokens 
```