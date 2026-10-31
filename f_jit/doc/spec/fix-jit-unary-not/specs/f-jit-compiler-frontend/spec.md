# Spec Delta

## ADDED Requirements

### Requirement: 一元逻辑非的产物形状可断言

前端对 `!operand` SHALL 产出「操作数求值指令序列 + 单条 `NOT_B`」，SHALL NOT 追加二次取反、真值归一或分支；AST SHALL 为 `Unary(Bang, operand)`，操作数 SHALL NOT 被重排或与比较交换。该形状 SHALL 有可直接断言的用例，使一次失败即可分离「前端形态错」与「后端语义错」。

#### Scenario: AST 形状

- **WHEN** 解析 `!(n < 50)`
- **THEN** 顶层为一元 `Bang`，其唯一子节点是 `n < 50`；不出现在比较左侧的一元节点

#### Scenario: 字节码形状

- **WHEN** 编译 `{ n: Int64 => !(n < 50) }`
- **THEN** 函数体为 `LOADL n; PUSH_I64 50; LT_I; NOT_B; RET`，`NOT_B` 恰好一条且紧跟比较

#### Scenario: 正则取反同样单条

- **WHEN** 编译 `re !~ s`
- **THEN** 产物为 `REGEX_IS_MATCH` 后追加**恰好一条** `NOT_B`
