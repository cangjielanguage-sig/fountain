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

### 记忆总结定义
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
