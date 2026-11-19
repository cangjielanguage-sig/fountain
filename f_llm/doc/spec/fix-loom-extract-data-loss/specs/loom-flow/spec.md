# Spec Delta

## ADDED Requirements

### Requirement: 提炼正文按字符截断

流程结束提炼记忆与经验时，摘要与正文的截断 MUST 以**字符**为单位，MUST NOT 在 UTF-8 字符内部切断；任何语言（含中文、emoji）的超长正文 MUST NOT 使提炼中断。

#### Scenario: 中文长正文

- **WHEN** 一次流程的对话摘要超过 300 字符且含中文
- **THEN** `note` 与 `experience` 都正常写入，正文是被截断到 300 字符并带省略号

#### Scenario: 未超长

- **WHEN** 正文不足上限
- **THEN** 原样写入，不追加省略号

### Requirement: 模型总结失败时按字段回落

`summarize=true` 时模型返回的内容若非法 JSON、或只包含部分字段，系统 MUST 按字段独立回落：缺失的字段使用规则提炼结果，MUST NOT 让该字段留空而丢失记录。

#### Scenario: 非 JSON

- **WHEN** 模型返回一段自然语言而不是 JSON
- **THEN** memory 与 experience 都使用规则提炼结果写入

#### Scenario: 只给 memory

- **WHEN** 模型只返回 `{"memory": "..."}`
- **THEN** memory 用模型结果，experience 用规则提炼结果，两条都写入

### Requirement: 知识切块按字符滑窗

知识文档切块 MUST 以字符为单位计算窗口与重叠，MUST NOT 在字符内部切断；中文文档切块 MUST NOT 抛异常。

#### Scenario: 中文长文档

- **WHEN** 1000 个汉字的知识文档按默认参数切块
- **THEN** 得到多块、每块不超过 400 字符、相邻块重叠 50 字符、无异常

#### Scenario: 边界正好

- **WHEN** 文档长度正好等于 `maxChars`
- **THEN** 只有一块，且内容与原文一致
