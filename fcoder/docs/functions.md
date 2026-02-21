### 函数说明
将函数描述中的`{{...}}`的部分替换为函数实参。

- **search** - 搜索引擎+本地知识库的‘全文+向量’查询
    - 调用方式：search('{{keywords}}')
- **read** - 本地知识库的确切标题搜索
    - 调用方式：read('{{title}}')
- **select** - 本地知识库的‘全文+向量’查询
    - 调用方式：select('{{keywords}}')
- **remember** - 记忆新的经验和知识
    - 调用方式：remember('{{kind}}', '{{content}}')
        - kind: 记忆的类型
            - EXPERIENCE - 经验
            - ARTICLE - 文章
        - content: 记忆的内容