### 函数说明
将函数描述中的`{{...}}`的部分替换为函数实参。

- **search** - 搜索引擎+本地知识库的‘全文+向量’查询
    - 函数调用
    ```json
    {
        "function":"search",
        "params":["{{keywords}}"],
        "embeddingWeight": 0.7,
        "minConfidence": 0.75
    }
    ```

    - 参数说明
        |参数            |描述|
        |:--------------|:--|
        |function       |函数名|
        |params         |函数参数，参数为字符串数组|
        |embeddingWeight|向量匹配的权重，范围0-1，默认为0.7|
        |minConfidence  |搜索结果的最低置信度，范围0-1，默认为0.75|

    - 函数返回
    ```json
    {
        "status":"success",
        "content":"查询的结果"
    }
    ```
- **read** - 本地知识库的确切标题搜索
    - 函数调用
    ```json
    {
        "function":"read",
        "params":["{{title}}"]
    }
    ```

    - 函数返回
    ```json
    {
        "status":"success",
        "content":"查询的结果"
    }
    ```
- **select** - 本地知识库的‘全文+向量’查询
    - 函数调用
    ```json
    {
        "function":"select",
        "params":["{{keywords}}"],
        "embeddingWeight": 0.7,
        "minConfidence": 0.75
    }
    ```

    - 参数说明
        |参数            |描述|
        |:--------------|:--|
        |function       |函数名|
        |params         |函数参数，参数为字符串数组|
        |embeddingWeight|向量匹配的权重，范围0-1，默认为0.7|
        |minConfidence  |搜索结果的最低置信度，范围0-1，默认为0.75|

    - 函数返回
    ```json
    {
        "status":"success",
        "content":"查询的结果"
    }
    ```
- **remember** - 记忆新的经验和知识
    - 函数调用
    ```json
    {
        "function":"remember",
        "params":["{{kind}}", "{{content}}"]
    }
    ```
        - kind: 记忆的类型
            - EXPERIENCE - 经验
            - ARTICLE - 文章
        - content: 记忆的内容
    - 函数返回
    ```json
    {
        "status":"success"
    }
    ```