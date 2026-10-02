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
