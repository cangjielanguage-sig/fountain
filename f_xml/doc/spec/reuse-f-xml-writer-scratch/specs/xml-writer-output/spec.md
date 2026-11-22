# xml-writer-output

## Purpose

定义 `f_xml.XmlWriter` 的输出不变性与低分配约束：复用字节暂存不改变任何编码下的输出字节、转义结果与异常行为，并消除非 ASCII 字符逐字符新建暂存数组的开销。

## ADDED Requirements

### Requirement: 非 ASCII 追加复用暂存

`XmlWriter` 在转义文本、属性值与 CDATA 时，非 ASCII 码点 MUST 写入复用的 4 B 暂存区再搬入输出缓冲；MUST NOT 为每个码点新建编码数组。暂存区 MUST 在写入器实例内复用。

#### Scenario: 汉字文本

- **WHEN** 写入包含 20000 个汉字的元素文本
- **THEN** 输出与逐字符编码结果逐字节相同，码点追加的堆分配不超过 8 B/rune

#### Scenario: 混合 ASCII 与非 ASCII

- **WHEN** 同一段文本混有 ASCII、汉字与 4 字节 emoji
- **THEN** 所有字符按 UTF-8 正确编码，转义字符仍按既有规则替换

#### Scenario: 属性值与 CDATA

- **WHEN** 非 ASCII 内容出现在属性值或 CDATA 中
- **THEN** 属性转义与 `]]>` 拆分行为与改动前一致

### Requirement: 输出字节不变

在任何支持的编码下，复用暂存与缓冲 MUST NOT 改变输出字节。

1. UTF-8 路径 MUST 直接写出 `[0, size)` 区间的字节视图；
2. 非 UTF 路径 MUST 保持既有往返校验与不可映射字符的 `?` 兜底；
3. 多段刷写与一次性写出的结果 MUST 逐字节相同；
4. 元素、属性、命名空间、缩进、声明的输出顺序 MUST 不变。

#### Scenario: UTF-8 多段刷写

- **WHEN** 文档超过 16 KB 刷写门限，内容含汉字与 emoji
- **THEN** 完整输出与期望字符串逐字节相同

#### Scenario: UTF-16LE 多段刷写

- **WHEN** 以 UTF-16LE 写入超过刷写门限的文档
- **THEN** 输出等于同一文档一次性写出的字节序列

#### Scenario: 不可映射字符

- **WHEN** 以单字节编码写入该编码不支持的字符
- **THEN** 仍按既有规则替换为 `?`，不抛新异常

### Requirement: 追加路径的分配基准

本变更 MUST 提供可重复执行的分配基准：

1. 基准 MUST 由环境变量开启，未开启时只打印跳过原因；
2. 汉字追加 MUST 断言 `<= 8 B/rune`；
3. 基准 MUST 同时测量 `StringGenerator.append(rune)` 作为对照，并断言复用路径比其低一个数量级以上；
4. 断言 MUST 使用多次采样取最小值，避免 GC 噪声导致偶发失败。

#### Scenario: 基准开启

- **WHEN** 设置基准环境变量并运行 `f_xml` 测试
- **THEN** 打印两条路径的 `allocPerRune`，断言复用路径 `<= 8 B/rune` 且总量低于基线 1/8

#### Scenario: 基准未开启

- **WHEN** 未设置环境变量
- **THEN** 用例打印跳过原因并通过，不影响常规测试
