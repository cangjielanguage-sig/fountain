# f_llm


## STDX dependency

Configure the environment variable: `export CANGJIE_STDX_DYNAMIC_PATH=/path/to/dynamic_stdx`

Large model API
Developers only need to care about the organization culture, the agents, the skill descriptions and FunctionCalling, plus the event definitions and
orchestration.
Every time, the large model must return one function call, and every function call must return one piece of event data and an event name; the agent
builds a new event from the return value of the function call and sends it to the framework.
Before accessing the large model an agent may trim or compress the context according to the given context strategy.

## Constant definitions

### Large model types
`public type LLMType = String`
Values of LLMType:
text embedding tokenizer rerank code video audio image prune
These values are not the same as the types defined by large model platforms; these strings are what the framework-defined large model configuration
is used for
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
//search is a kind of tool interface; Zhipu provides it at present, and since it also depends on the Zhipu auth KEY it is treated as a large model configuration
public const LLM_TYPE_SEARCH = 'search'
```

### Roles
```cj
public type Role = String
public const ROLE_SYSTEM = "system"
public const ROLE_USER = "user"
public const ROLE_ASSISTANT = "assistant"
public const ROLE_TOOL = "tool"
```

### Skill types
Primary skills are loaded completely together with the agent, while auxiliary skills use progressive disclosure: the metadata list of the auxiliary
skills follows the agent, and the concrete skills are then loaded as needed.
system always comes first, and auxiliary skills loaded during a session are also inserted before assistant/user/tool messages and after the other system messages.
```cj
public type SkillType = String
public const SKILL_TYPE_PRIMARY = 'primary'
public const SKILL_TYPE_AUXILIARY = 'auxiliary'
```

### Thinking switch
```cj
public type ThinkingSwitch = String
public const THINGKING_ENABLED = 'enabled'
public const THINGKING_DISABLED = 'disabled'
```

### Context pruner names
```cj
public type ContextPrunerName = String
/**
 * Retain everything
 */
public const CONTEXT_PRUNER_RETAIN = "Retain"
/**
 * Keep the most recent
 */
public const CONTEXT_PRUNER_LAST_N = "LastN"
/**
 * Summary
 */
public const CONTEXT_PRUNER_SUMMARY = "Summary"
/**
 * Keyword extraction
 */
public const CONTEXT_PRUNER_KEYWORDS = "Keywords"
/**
 * system gets its own strategy and assistant+user+tool get another one
 */
public const CONTEXT_PRUNER_DRC = "DRC"
/**
 * Apply a given strategy once the context is saturated
 */
public const CONTEXT_PRUNER_SATURATION = "Saturation"
```


## Data definitions: `fountain::f_llm.model.po`

### Token usage data definition
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

### Large model definition
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

### Agent definition
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

### Skill definition
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

### Memory summary definition
```cj
@DataAssist[fields]
@QueryMappersGenerator[table: memory_summaries]
public class MemorySummary {
    @ORMField[id column: 'id']
    private var id: Int64 = 0
    @ORMField['kind']
    private var kind: String = ''
    @ORMField['content']
    private var content: String = ''
}
```


## Extracting memory

Every piece of session context is faithfully saved to disk; at midnight every day, memory is summarized with session as the context boundary,
according to the memory and the configuration items:
- Summarizing lessons and experience
  - The configuration item is export llm_summarisingActionKind=experience
  - Operations approved by the user are regarded as successful experience.
  - Operations that failed once inside a session and later succeeded with the large model are regarded as lessons from failure
- Summarizing user individuality
  - The configuration item is export llm_summarisingIndividualityKind=individuality
  - User individuality includes the user's preferences about certain things and matters, and their habits in doing things and wording
- Other cases of the configuration item export llm_summarisingActionKind
  - When it is an empty string no summarization is done
  - When it is not an empty string, the value of the configuration item is used as the name prefix of the objects managed by `fountain::f_bean`
    to fetch the implementations of the two interfaces `fountain::f_llm.memory.MemoryExtractor` and `fountain::f_llm.finder.MemorySummaryFinder`
    respectively; if nothing is found, an exception is thrown
```cj
public abstract class MemoryExtractor {
    /**
     * json is the JSON object of the JSON returned by the large model
     * The optional first-level keys of json are lesson, experience and individuality; developers may extend this class to define their own keys
     * overiwter is used to overwrite the saved historical memory extraction results; memories with high similarity are overwritten
     */
    public func extract(json: JsonObject, overwriter: (String, String) -> Unit): Unit
    /**
     * json is the second level of the json returned by the large model, and key is a key in the current json.
     * The implementation of this function builds a string from the JSON as the result of the memory summary; markdown format is recommended
     */
    public func extract(json: JsonObject, key: String): String
    protected func extract(key: String, jsonobj: JsonObject, overwriter: (String, String) -> Unit): Unit
    protected func extractString(jsonobj: JsonObject, key: String): String
    protected func extractArray(jsonobj: JsonObject, key: String): String
    /**
     * The system prompt for summarizing memory, explaining the purpose of the current memory extractor
     */
    public prop systemPrompts: String
    /**
     * The user prompt prefix for summarizing memory; the concrete content sent to the large model is as follows:
     * ${extractor.userPrompts}
     * ## Context
     * ${context}
     * 
     * context is a string built from an ArrayList<ChatMessage>
     */
    public prop userPrompts: String
}
/** 
 * Experience and lesson extractor
 */
public class ExperienceExtractor <: MemoryExtractor
/**
 * Individuality extractor
 */
public class IndividualityExtractor <: MemoryExecutor
```


## Data query interfaces: `fountain::f_llm.finder`

The implementation of every finder interface must be a class decorated with `fountain::f_bean.macros.Bean`
### Querying agents
```cj
public interface AgentsFinder {
    func listAgents(): ArrayList<Agent>
    func queryAgent(id: Int64): Agent
}
```

### Knowledge query interface
```cj
public interface KnowledgeFinder {
    func search(param: KnowledgeParam): ArrayList<String>
    func saveKnowledge(knowledge: Knowledge): Unit
    func findKnowledge(kind: KnowledgeKind, title: String): ?String
}
```

### Large model query interface
All large model configuration is loaded at process startup
```cj
public interface LLMFinder {
    func listConfs(llmTypes: Array<String>): ArrayList<LLMConf>
}
```

### Organization query interface
```cj
public interface OrganizationFinder {
    func queryOrgCulture(agentId: Int64): String
}
```

### Skill query interface
```cj
public interface SkillsFinder {
    func querySkills(agentId: Int64, event: String): ArrayList<Skill>
    func loadSkills(title: ArrayList<String>): ArrayList<Skill>
    func loadSkillReferences(references: ArrayList<SkillReferenceParam>): ArrayList<SkillReference>
}
```

### Token data saving interface
```cj
public interface TokenUsageSaver {
    func saveTokenUsage(usage: TokenUsage): Unit
}
```


## Embedding model interface

```cj
/**
 * Parameters
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
 * Response
 */
@DataAssist[props fields]
public class EmbeddingResp {
    private var embedding: Array<Float64> = []
    private let usage: TokenUsage = TokenUsage()
}
/**
 * The abstract class developers need to implement; the GLM embedding model is already provided
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

### Embedding model mediator
```cj
public class EmbeddingContextMediator {
    /**
     * Register an embedding model
     * @param model Model name
     * @param creator The function creating the embedding model instance
     */
    public static func register(model: String, creator: (LLMConf) -> AbstractEmbeddingContext)
    public static prop instance: EmbeddingContextMediator 

    /**
     * Access the embedding model
     * @param model Model name
     * @param param Parameters
     */
    public func access(model: String, param: EmbeddingParam): EmbeddingResp 
}
```

### Forgetting queries/summaries
```cj
public interface MemorySummaryFinder {
    func overwrite(kind: String, content: String): Unit
    func query(keywords: String): ArrayList<Experience>
}
public interface ExperienceFinder <: MemorySummaryFinder {}
public interface IndividualityFinder <: MemorySummaryFinder {}

```


## Context strategies: `fountain::f_llm.llm.ContextPrunerName`

They trim, compress and so on the context
```cj
/**
 * For all strategies it is enough to decorate the class implementing this interface with `fountain::f_bean.macros.Bean`.
 * Alternatively use `fountain::f_bean.macros.Bean` to decorate a function that initializes and returns a context strategy instance.
 */
public interface ContextPruner {
    /**
     * Strategy name
     */
    prop name: String
    /**
     * The implementation of the strategy
     * @param agentId Agent ID
     * @param session Session identifier; every execution of a session flow needs a new identifier
     */
    func prune(agentId: Int64, session: String, messages: ArrayList<ChatMessage>): ArrayList<ChatMessage>
}
```
### Retain everything
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
### Keep the most recent
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
### Strategies that depend on a large model
```cj
public abstract class ContextLLMPruner <: ContextPruner {
    /**
     * @param llmType The type of the large model executing this strategy
     * @param model The name of the large model executing this strategy
     * @param promptsGenerator The prompt generator of this strategy
     */
    public ContextLLMPruner(
        protected let llmType!: LLMType,
        protected let model!: ModelName,
        private let promptsGenerator!: (ArrayList<ChatMessage>) -> String
    ){}
    public func prune(agentId: Int64, session: String, messages: ArrayList<ChatMessage>): ArrayList<ChatMessage>
}
```
### Context summary strategy
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
### Context keyword strategy
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
system and assist/user/tool and similar messages use different strategies
```cj
public class DRCContextPruner <: ContextPruner {
    /**
     * @param systemPruner The strategy for system messages
     * @param othersPruner The strategy for the other messages
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
### Saturation strategy
```cj
public class SaturationContextPruner <: ContextPruner {
    /**
     * @param pruner The strategy executed when the tokens are saturated
    public SaturationContextPruner(
        private let pruner!: ContextPruner
    ){}
    public prop name: String{
        get(){
            '${CONTEXT_PRUNER_SATURATION}_${pruner.name}'
        }
    }
    /**
     * Use agentId to query the llmType and the large model name used by the agent, and thereby find the saturation token count of the
     * large model
     */
    public func prune(agentId: Int64, session: String, messages: ArrayList<ChatMessage>): ArrayList<ChatMessage>
}
```
### Keeping the last user message
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
     * If messages has no user message, return msgs
     * If the last user message contained in the return value of this.pruner.prune(agentId, session, messages) is the same as the last user
     * message of messages, return msgs as well
     * Otherwise append the last user message contained in messages to the end of msgs and return msgs.
     */
    public func prune(agentId: Int64, session: String, messages: ArrayList<ChatMessage>): ArrayList<ChatMessage>
}
```


## Large model access parameters and responses

```cj
@DataAssist[props fields]
public open class LLMParams {
    public LLMParams(
        private let model!: String = '',
        private var messages!: ArrayList<ChatMessage> = ArrayList<ChatMessage>()
    ){}
    private let thinking: Thinking = Thinking()
    //Camel case cannot be used together with the @FieldAlias['response_format'] annotation, because instances of this class are converted into
    //JSON and that naming would produce redundant JSON fields
    private var response_format: ResponseFormat = ResponseFormat.json
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
public class ResponseFormat {
    public static let json: ResponseFormat = ResponseFormat('json_object')
    public static let text: ResponseFormat = ResponseFormat('text')
    public init(){}
    public init(t: String){
        this.`type` = t
    }
    private var `type`: String = 'json_object'
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


## Accessing large models

```cj
/**
 * Abstract large model access context; a Zhipu implementation is already provided.
 * Developers only need to provide an implementation of AbstractLLMContext and decorate it with `fountain::f_bean.macros.Bean`.
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
     * Access the large model
     * @param agentId Agent ID
     * @param session Session identifier; every execution of a session flow needs a new identifier
     * @param params The parameters for accessing the large model
     */
    public func access(agentId: Int64, session: String, params: LLMParams): LLMResp
    /**
     * Get the number of tokens the large model produces for the received messages
     */
    public func tokenize(model: String, messages: ArrayList<ChatMessage>): Int64
}
```

### Large model mediator
```cj
public class LLMContextMediator {
    /**
     * Register a large model
     * @param llmType Large model type
     * @param model Large model name
     * @param creator The large model creator
    public static func register(llmType: LLMType, model: String, creator: (LLMConf) -> AbstractLLMContext)
    
    public static prop instance: LLMContextMediator 
    /**
     * Access the given large model
     * @param agentId Agent ID
     * @param session Session identifier; every execution of a session flow needs a new identifier
     * @param llmType Large model type
     * @param params The parameters for accessing the large model
    public func access(agentId: Int64, session: String, llmType: LLMType, params: LLMParams): LLMResp 
    /**
     * Get the saturation token count of the given large model
     */
    public func getTokenThreshold(llmType: LLMType, model: String): Int64 
    /**
     * Get the number of tokens of the given large model for the given messages
     */
    public func tokenize(llmType: LLMType, model: String, messages: ArrayList<ChatMessage>): Int64 
    /**
     * Determine whether the given context is saturated for the given large model
     */
    public func saturated(llmType: LLMType, model: String, messages: ArrayList<ChatMessage>): Bool 
}
```


## Search

- Search (the former `doc/搜索.md` has been deleted; see the interfaces in `src/**`)

## Function calling

### `fountain::f_llm.FunctionCalling`
```cj
/**
 * The result of a function call; this module is an auxiliary module of fcoder, and fcoder depends on the events and flows defined by f_egraph
 */
public struct FunctionResult {
    /**
     * The result of the function call
     * @param event The name of the event into which the result of this function is wrapped
     * @param result The result of the function call, either a simple string or markdown text
     */
    public FunctionResult(
        public prop event!: String,
        public prop result!: String
    ){}
}
public interface CommonFunctionCalling {
    /**
     * The large model function definition described in JSON SCHEMA form
     */
    prop definition: JsonObject
    /**
     * Function name
     */
    prop name: String
    /**
     * Function description
     */
    prop description: String 
    /**
     * Function call; this function is called by the agent, and the developer only needs to implement `func call(params: T): FunctionResult`
     * @param params Function parameters
     * @return The result of the function call
     */
    func call(json: JsonObject): FunctionResult
}
/**
 * An implementation of this interface must be a class decorated with fountain::f_bean.macros.Bean; decorating the implementation of this
 * interface with `@Bean` is enough to complete the registration of the function
 */
public interface FunctionCalling<T> <: CommonFunctionCalling where T <: DataFields<T> {
    /**
     * The large model function definition described in JSON SCHEMA form
     * The default implementation calls the JsonObject.toJsonSchema<T>() extension of fountain::f_data.json to obtain the parameter definition,
     * and combines the name and description properties of this interface with the Json converted from the generic argument into the large model
     * function definition
     */
    prop definition: JsonObject 
    /**
     * Function name
     */
    prop name: String
    /**
     * Function description
     */
    prop description: String
    /**
     * Function call. The default implementation only throws FunctionCallingException
     * @param params Function parameters
     * @return The result of the function call
     */
    func call(params: T): FunctionResult
    /**
     * Function call; this function is called by the agent, and the developer only needs to implement `func call(params: T): FunctionResult`
     * @param params Function parameters
     * @return The result of the function call
     */
    func call(json: JsonValue): FunctionResult {
        DataObject<T>.populate(json.toData()).getOrThrow() |> call
    }
}
```
### The parser function for large model replies
This function does nothing; it merely parses the JSON returned by the large model into an Answer object
```cj
@DataAssist[props fields]
public class Answer {
    @JsonStringSchema[description:'The event name of the next step of the flow']
    private var event: String = ''
    @JsonStringSchema[description:'Your reply, which will be used as the argument of the next event of the flow']
    private var answer: String = ''
}

@Bean
public class AnswerFunction <: FunctionCalling<Answer> {
    /**
     * Function name
     */
    public prop name: String {
        get(){
            'answer'
        }
    }
    /**
     * Function description
     */
    public prop description: String {
        get(){
            '如果需要直接输出回复，而不依赖其它函数的结果，务必使用此函数传递回复'
        }
    }
    /**
     * Used to parse the reply of the large model
     * @param params Function parameters
     * @return The result of the function call
     */
    public func call(params: Answer): FunctionResult {
        FunctionResult(event: params.event, result: params.answer)
    }
}
```

### Skill loading function
```cj
@DataAssist[props fields]
public class SkillLoading {
    @JsonStringSchema[description:'The event name of the current step of the flow']
    private var event: String = ''
    @JsonStringSchema[description:'Skill title, which is unique']
    private var title: String = ''
}

@Bean
public class SkillLoadingFunction <: FunctionCalling<SkillLoading> {
    private let skillsFinder = lookup<SkillsFinder>()
    /**
     * Function name
     */
    public prop name: String {
        get(){
            'loadSkill'
        }
    }
    /**
     * Function description
     */
    public prop description: String {
        get(){
            '加载技能详细描述'
        }
    }
    /**
     * Used to load the detailed description of a skill
     * @param params Function parameters
     * @return The result of the function call
     */
    public func call(params: SkillLoading): FunctionResult {
        FunctionResult(event: params.event, result: skillsFinder.loadSkill(params.title), resultType: ResultType.Skill)
    }
}
```

### Skill reference loading function
```cj

@DataAssist[props fields]
public class SkillReferenceLoading {
    @JsonStringSchema[description:'The event name of the current step of the flow']
    private var event: String = ''
    @JsonStringSchema[description:'The list of skill titles to load; titles are unique']
    private var references: ArrayList<SkillReferenceParam> = ArrayList<SkillReferenceParam>()
}


@Bean
public class SkillReferenceLoadingFunction <: FunctionCalling<SkillReferenceLoading> {
    private let skillsFinder = lookup<SkillsFinder>()
    /**
     * Function name
     */
    public prop name: String {
        get(){
            'loadSkillReferences'
        }
    }
    /**
     * Function description
     */
    public prop description: String {
        get(){
            '加载技能详细描述'
        }
    }
    /**
     * Used to load the detailed description of a skill
     * @param params Function parameters
     * @return The result of the function call
     */
    public func call(params: SkillReferenceLoading): FunctionResult 
}
```

### Memory loading function for experience, lessons, user individuality, etc.
```cj
@DataAssist[props fields]
public class MemoryLoading {
    @JsonStringSchema[description:'The event name of the current step of the flow']
    private var event: String = ''
    @JsonStringSchema[description:'Query the experience most relevant to this argument']
    private var query: String = ''
}

@Bean
public class MemoriesLoadingFunction <: FunctionCalling<MemoryLoading> {
    private let finder = lookup<MemorySummaryFinder>()
    /**
     * Function name
     */
    public prop name: String {
        get(){
            'loadMemories'
        }
    }
    /**
     * Function description
     */
    public prop description: String {
        get(){
            '加载经验、教训、用户个性等的详细内容，这些内容来自过往会话的记忆总结'
        }
    }
    /**
     * Used to load the detailed description of an experience
     * @param params Function parameters
     * @return The result of the function call
     */
    public func call(params: MemoryLoading): FunctionResult
}
```

### Command line execution function
```cj

@DataAssist[props fields]
public class Command {
    @JsonStringSchema[description:'The event name of the next step of the flow']
    private var nextEvent: String = ''
    @JsonStringSchema[description:'A complete operating system console command']
    private var command: String = ''
}

@Bean
public class CommandFunction <: FunctionCalling<Command> {
    /**
     * Function name
     */
    public prop name: String {
        get(){
            'command'
        }
    }
    /**
     * Function description
     */
    public prop description: String {
        get(){
            '执行操作系统控制台命令'
        }
    }
    /**
     * @param params Command parameters
     * @return The result of the function call
     */
    public func call(params: Command): FunctionResult 
}
```

### Console read/write function
When the user presses CTRL+D on Linux or CTRL+Z on Windows, the input ends.
```cj
@DataAssist[props fields]
public class ConsoleOutput {
    @JsonStringSchema[description:'The event name of the next step of the flow']
    private var nextEvent: String = ''
    @JsonStringSchema[description:'The content the large model outputs to the console']
    private var content: String = ''
}

@Bean
public class ConsoleFunction <: FunctionCalling<ConsoleOutput> {
    private let writer = ConsoleWriter()
    private let reader = ConsoleReader()
    /**
     * Function name
     */
    public prop name: String {
        get(){
            'console'
        }
    }
    /**
     * Function description
     */
    public prop description: String {
        get(){
            '控制台读写，大模型向控制台输出一段内容，用户通过控制台向大模型指示下一步行动'
        }
    }
    /**
     * Console read/write: outputs to the console the content the large model wants the user to see, and waits for the user to reply or confirm
     * the next action.
     */
    public func call(params: ConsoleOutput): FunctionResult 
}
```

### File reading function
```cj
@DataAssist[props fields]
public class FileReadingParams {
    @JsonStringSchema[description:'The event name of the next step of the flow']
    private var event: String = ''
    @JsonStringSchema[description:'''
A UNIX-style file path.
This function is part of an application; this path is resolved relative to the configured available path, so even if the argument returned by
the large model is an absolute path it will not access the file system of the whole operating system.''']
    private var path: String = ''
    @JsonStringSchema[description:'Used together with mode; only text lines satisfying the condition are returned']
    private var condition: String = ''
    @JsonStringSchema[description: '''
The mode for reading the file, used together with condition.
### Possible values
- entire: the default; returns the whole file, and condition has no effect in this case
- regex: only text lines matching the regular expression represented by condition are returned
- tail: condition must then be an integer; returns the given number of lines at the end of the file, the number being the integer represented by condition
- head: condition must then be an integer; returns the given number of lines at the beginning of the file, the number being the integer represented by condition
- random: condition must then be an integer; uses the reservoir algorithm to choose the given number of lines at random from the file, the number
  being the integer represented by condition
''']
    private var mode: String = 'entire'
}

@Bean
public class FileReadingFunction <: AbstractFileFunction<FileReadingParams> {
    /**
     * Function name
     */
    public prop name: String {
        get(){
            'readFile'
        }
    }
    /**
     * Function description
     */
    public prop description: String {
        get(){
            '读文件'
        }
    }
    /**
     * The operation of reading a file
     * @param params Function parameters
     * @return The result of the function call
     */
    public func call(params: FileReadingParams): FunctionResult
}
```

### File content replacement function
```cj

@DataAssist[props fields]
public class FileReplacingParams {
    @JsonStringSchema[description:'The event name of the next step of the flow']
    private var event: String = ''
    @JsonStringSchema[description:'''
A UNIX-style file path.
This function is part of an application; this path is resolved relative to the configured available path, so even if the argument returned by
the large model is an absolute path it will not access the file system of the whole operating system.''']
    private var path: String = ''
    @JsonStringSchema[description:'The content to replace with']
    private var replacement: String = ''
    @JsonStringSchema[description: 'Only text lines matching this regular expression are replaced; an empty string returns an error']
    private var regex: String = ''
}

@Bean
public class FileReplacngFunction <: AbstractFileFunction<FileReplacingParams> {
    /**
     * Function name
     */
    public prop name: String {
        get(){
            'replaceFile'
        }
    }
    /**
     * Function description
     */
    public prop description: String {
        get(){
            '逐行替换文件内容，替换成功返回OK，否则返回错误原因，如果文件不存在会立即返回"文件不存在"'
        }
    }
    /**
     * The operation of reading a file
     * @param params Function parameters
     * @return The result of the function call
     */
    public func call(params: FileReplacingParams): FunctionResult 
}
```

### File writing function
```cj

@DataAssist[props fields]
public class FileWritingParams {
    @JsonStringSchema[description:'The event name of the next step of the flow']
    private var event: String = ''
    @JsonStringSchema[description:'''
A UNIX-style file path.
This function is part of an application; this path is resolved relative to the configured available path, so even if the argument returned by
the large model is an absolute path it will not access the file system of the whole operating system.''']
    private var path: String = ''
    @JsonStringSchema[description:'The file content to write']
    private var content: String = ''
    @JsonStringSchema[description: '''
File writing mode; the default is append and the possible values are append and truncate.
If content is an empty string and truncate is given, the file is emptied.
If the file does not exist a new file is created automatically.''']
    private var mode: String = 'append'
}

@Bean
public class FileWritingFunction <: AbstractFileFunction<FileWritingParams> {
    /**
     * Function name
     */
    public prop name: String {
        get(){
            'writeFile'
        }
    }
    /**
     * Function description
     */
    public prop description: String {
        get(){
            '写文件，写成功返回OK，否则返回错误原因'
        }
    }
    /**
     * The operation of reading a file
     * @param params Function parameters
     * @return The result of the function call
     */
    public func call(params: FileWritingParams): FunctionResult 
}
```


## Definition of an agent

1. Query the skills with the event name + agent.id
   - An agent may have several primary skills and several auxiliary skills, or none at all
2. Combine agent.agent + skill.details into the complete prompt template
   The skills include primary and auxiliary skills; the organization culture, the agent description, the primary skill descriptions and the
   auxiliary skill metadata are concatenated as one system message
   ```md
   Organization culture
   ===
   ${culture}

   > **Important note**: content marked with ⚠️ is a special reminder that needs particular attention; do not ignore it.

   Agent description
   ===
   ${agent.agent}
   ___

   Skill list
   ===
   # Primary skills
   ## Skill title: ${skill.title}
   ${skill.details}
   ___

   # Auxiliary skill metadata
   ## Skill title: ${skill.title}
   ${skill.metadata}
   ___
   ```
3. Convert the e.data of exec(e: Event) as follows: ((e.data as ToData)?.toData()).getOrThrow() as SimpleDataObject,
   and use the converted instance as the template arguments replacing the {{...}} placeholders in the prompt template
4. Query the large model with agent.llmType and agent.llmName
5. Access the large model with the replaced prompt + the function list
6. Access functions with the result returned by the large model
7. Build an event from the result returned by the function as the return value of the agent
8. The interface of the context length control strategies and several implementations
     #### Context strategies (subtypes of fountain::f_llm.llm.ContextPruner):
     - A: Retain (RetainContext): retain the whole context
     - B: LastN (LastNContext): the concrete number N is given by an initialization argument
       - The name of this strategy is 'LastN_${n}', where n is the concrete number given at initialization
     - B: Summary (ContextSummaryPruner): summarize the whole context
       - The name of this strategy is 'Summary_BY_${llmType}_${model}', where llmType and model are initialization arguments
       - llmType is what the large model can do; the possible values are text code image video audio embedding rerank tokenizer.
       - model is the name of the large model
     - D: Keywords (ContextKeywordsPruner): extract keywords from the whole context
       - The name of this strategy is 'Keywords_BY_${llmType}_${model}'; llmType is what the large model can do and the possible values are text code image video audio embedding rerank tokenizer.
       - model is the name of the large model
     - E: DRC (DRCContextPruner): apply different context strategies to system and to the other messages
       - The name of this strategy is 'DRC_BY_${systemPruner.name}_${otherPruner.name}'.
     - F: Saturated context (SaturationContextPruner):
       - The name of this strategy is 'Saturation_${pruner.name}'
       - It applies the given strategy when the context is saturated,
       - The saturation token count is specified in the large model configuration,
       - agentId can be used to find the large model used by the agent and thereby determine the saturation token count in the large model configuration
         - Different large models may have different saturation token counts,
           - A large model that supports a 1M context usually produces severe hallucinations once the context reaches 10%~15%,
           - A large model that supports a 200K context produces severe hallucinations at 80K.
           - The Keywords and Summary strategies depend on a large model; be careful that the context sent to the large model executing the
             strategy does not exceed its saturation token count


## todo

```cj
package fountain::f_llm.finder
public interface TodoFinder {
    /**
     * Save todos
     * @param task The name of the todo task
     * @param todos The todo list of the current task
     */
    func save(task: String, todos: ArrayList<Todo>): Unit
    /**
     * List todos
     * @param task The name of the todo task
     * @return The todo list
     */
    func list(task: String): ArrayList<Todo>
    /**
     * Update the status of a todo
     * @param task The name of the todo task
     * @param id The todo ID
     * @param status The todo status
     * @return The number of updated todos; a value other than 1 means the arguments were wrong or the todo does not exist
     */
    func updateStatus(task: String, id: Int64, status: String): Int64
}
```

```cj
package fountain::f_llm.tool
@DataAssist[props fields]
public class TodoSavingParam {
    @JsonStringSchema[description:'The event name of the next step of the flow']
    private var nextEvent: String = ''
    @JsonStringSchema[description:'Task name']
    private var task: String = ''
    @JsonArraySchema[description:'Todo list']
    private var todos: ArrayList<TodoSaving> = ArrayList<TodoSaving>()
}
@DataAssist[props fields]
public class TodoSaving {
    @JsonStringSchema[description:'Todo title']
    private var title: String = ''
    @JsonStringSchema[description:'Todo details']
    private var content: String = ''
    @JsonStringSchema[description:'Todo status']
    private var status: String = TODO_STATUS_PENDING
    @JsonArraySchema[description:'List of predecessor todo IDs']
    private var predecessor: ArrayList<Int64> = ArrayList<Int64>()
}
@DataAssist[props fields]
public class TodoListParam{
    @JsonStringSchema[description:'The event name of the next step of the flow']
    private var nextEvent: String = ''
    @JsonStringSchema[description:'Task name']
    private var task: String = ''
}
@DataAssist[props fields]
public class TodoStatusParam{
    @JsonStringSchema[description:'The event name of the next step of the flow']
    private var nextEvent: String = ''
    @JsonStringSchema[description:'Task name']
    private var task: String = ''
    @JsonStringSchema[description:'Todo ID']
    private var id: Int64 = 0
    @JsonStringSchema[description:'The new todo status']
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


## tool call function definition

Several tool call functions may be defined in one class
```cj
/**
 * Used to decorate public instance functions of a class; that class must be decorated with the @ToolCall macro
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
 * The macro used to define tool call functions; it decorates a class, the decorated class is registered with fountain::f_bean,
 * and the public instance functions of the decorated class are registered as tool call functions.
 * Only functions decorated with @FunctionDefinition are registered as tool call functions; otherwise an exception is thrown.
 */
public macro ToolCall(input: Tokens): Tokens 
/**
 * Used to decorate a class; the decorated class is registered with fountain::f_bean, and the public instance functions of the decorated class
 * are registered as tool call functions.
 * Only functions decorated with @FunctionDefinition are registered as tool call functions; otherwise an exception is thrown.
 * The difference is that the public instance functions of the class decorated with this macro also have matching aspects weaved into them.
 */
public macro WeavedToolCall(input: Tokens): Tokens 
```


## Configuration items

All configuration items are environment variables
```cj
public static const LLM = 'llm'
/**
 * String
 * The path the large model may operate on; the large model can only manipulate files under this path
 */
public static const FILE_SANDBOX_PATH = LLM + '_fileSandboxPath'
/**
 * Positive integer
 * Number of retries when accessing the large model fails; Int64.Max by default
 */
public static const LLM_ACCESS_TRYING_COUNT = LLM + '_accessTryingCount'
/**
 * Positive integer
 * The retry time for accessing the large model: from the start of each attempt to interact with the large model, retrying is allowed for this
 * long, until the access succeeds or the time is up
 * The unit is seconds; Int64.Max by default
 */
public static const LLM_ACCESS_TRYING_ELAPSED = LLM + '_accessTryingElapsed'
/**
 * String
 * Faithful memory storage path
 */
public static const LLM_FAITHFUL_MEMORY_PATH = LLM + '_faithfulMemoryPath'
/**
 * Bool
 * Whether to save memory; only when memory is saved can experience be produced
 */
public static const LLM_MAKING_MEMORY = LLM + '_makingMemory'
/**
 * String
 * The model used to summarize experience; glm-4.7-flash by default
 */
public static const SUMMARISING_MODEL = LLM + '_summarisingModel'
```
