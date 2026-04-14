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
