# f_mq 协议层（delta）

## ADDED Requirements

### Requirement: BODY 容器类型的编解码与过滤

记录 BODY 为 `TreeSet`、`HashMap`、`Array` 时，`MQMessageRecord.encode/decode` SHALL 保持元素类型
与内容不变；`filter` SHALL 能按 `f_data` 路径语义读取容器内的值。容器为空时 SHALL 正确往返，
不得退化为 `DataNone` 或抛异常。

#### Scenario: TreeSet 往返

- **WHEN** BODY 为 `TreeSet<Int64>{1, 2, 3}`
- **THEN** 解码后仍为 `TreeSet`，元素集合与顺序一致

#### Scenario: HashMap 往返与过滤

- **WHEN** BODY 为 `HashMap<String, Int64>{"age": 40}`，filter 为 `$.age`
- **THEN** 解码后键值一致，过滤结果为真（非零值取真）

#### Scenario: Array 往返

- **WHEN** BODY 为 `Array<Int64>{10, 20, 30}`
- **THEN** 解码后长度与元素一致，元素类型仍为 `Int64`

#### Scenario: 空容器

- **WHEN** BODY 为空的 `TreeSet` / `HashMap` / `Array`
- **THEN** 往返后仍为空容器，过滤空串返回匹配
