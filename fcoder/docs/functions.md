### 函数说明
将函数描述中的`{{...}}`的部分替换为函数实参。

- **search** - 搜索引擎+本地知识库的‘全文+向量’查询
    - 函数调用
    ```json
    {
        "type": "function",
        "function": {
            "name": "search",
            "description": "搜索引擎+本地知识库的‘全文+向量’查询",
            "parameters": {
                "type": "object",
                "properties": {
                    "event": {
                        "type": "string",
                        "description": "函数在本次调用返回的事件名称，固定返回：{{event}}"
                    },
                    "keywords": {
                        "type": "string",
                        "description": "从用户需求提取的关键词列表，多个关键词用英文逗号分隔"
                    },
                    "embeddingWeight": {
                        "type": "number",
                        "description": "向量匹配的权重，默认是0.7
                                        - 文本匹配权重是`1.0 - embeddingWeight`
                                        - 如果是专业术语可以调低这个值
                                        - 如果是口语化的、模糊的内容，或者更重视语义，可以调高这个值"
                    },
                    "minConfidence": {
                        "type": "number",
                        "description": "搜索结果可接受的最低置信度，可以按照当前场景动态调整这个值，默认0.8"
                    },
                    "maxResults": {
                        "type": "number",
                        "description": "搜索结果最大返回数量，默认是10"
                    }
                },
                "requires": [
                    "keywords"
                ]
            }
        }
    }
    ```

    - 函数返回
    ```json
    {
        "role":"tool",
        "content":"查询的结果",
        "tool_call_id":"{{tool_call_id}}"
    }
    ```

- **read** - 本地知识库的确切标题搜索
    - 函数调用
    ```json
    {
        "type":"function",
        "function":{
            "name":"read",
            "description":"本地知识库的确切标题搜索",
            "parameters":{
                "type":"object",
                "properties":{
                    "title":{
                        "type":"string",
                        "description":"搜索内容"
                    },
                },
                "requires":["title"]
            }
        }
    }
    ```

    - 函数返回
    ```json
    {
        "role":"tool",
        "content":"查询的结果",
        "tool_call_id":"{{tool_call_id}}"
    }
    ```

- **select** - 本地知识库的‘全文+向量’查询
    - 函数调用
    ```json
    {
        "type":"function",
        "function":{
            "name":"select",
            "description":"本地知识库的‘全文+向量’查询",
            "parameters":{
                "type":"object",
                "properties":{
                    "keywords":{
                        "type":"string",
                        "description":"搜索内容"
                    },
                    "embeddingWeight":{
                        "type":"number",
                        "description":"向量匹配的权重，默认是0.7
                                        - 文本匹配权重是`1.0 - embeddingWeight`
                                        - 如果是专业术语可以调低这个值
                                        - 如果是口语化的、模糊的内容，或者更重视语义，可以调高这个值"
                    },
                    "minConfidence":{
                        "type":"number",
                        "description":"搜索结果可接受的最低置信度，可以按照当前场景动态调整这个值，默认0.8"
                    },
                    "maxResults":{
                        "type":"number",
                        "description":"搜索结果最大返回数量"
                    }
                },
                "requires":["keywords"]
            }
        }
    }
    ```

    - 函数返回
    ```json
    {
        "role":"tool",
        "content":"查询的结果",
        "tool_call_id":"{{tool_call_id}}"
    }
    ```