# svg-security

## ADDED Requirements

### Requirement: M5 上限与降级

系统 SHALL 在解析或布局前检查下列上限，并按指定方式降级，SHALL NOT 因这些上限抛异常或中断整篇文档：

- CSS 变量嵌套：8 层，超限使该声明无效并记 warning；
- `calc()` 嵌套：16 层，超限使该声明无效并记 warning；
- 单条选择器的简单选择器数量：256，超限跳过该规则并记 warning；
- `kern` 表条目：65536，超限忽略整表并记 warning；
- `GPOS` pair 集条目：65536，超限忽略该子表并记 warning；
- `GSUB` lookup 深度：8，超限停止替换并记 warning；
- 单次连字输入字形数：4，超限不替换。

所有上限检查 SHALL 发生在分配大缓冲或进入递归循环之前；warning SHALL 包含可定位的属性名、选择器或表名。

#### Scenario: 变量嵌套超限

- **WHEN** `--v1` 至 `--v10` 形成 10 层 `var()` 引用
- **THEN** 引用声明无效，`warnings` 含 `var`，文档其余样式正常

#### Scenario: calc 嵌套超限

- **WHEN** `calc()` 括号嵌套 17 层
- **THEN** 该属性回退初始值并记 warning，渲染继续

#### Scenario: 选择器过长

- **WHEN** 单条规则包含 257 个简单选择器
- **THEN** 该规则被跳过并记 warning，后续规则仍生效

#### Scenario: kern 表超限

- **WHEN** 字体的 `kern` 表声明 65537 个条目
- **THEN** 整表被忽略并记 warning，文本仍按无字距布局

#### Scenario: GPOS 子表超限

- **WHEN** 一个 Pair Adjustment 子表声明 65537 个 pair
- **THEN** 该子表被忽略并记 warning，其余字距子表不受影响

#### Scenario: GSUB 深度超限

- **WHEN** lookup 链深度为 9
- **THEN** 第 9 层停止替换并记 warning，已完成的替换保留
