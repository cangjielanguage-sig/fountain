# data-json-serialization

## Purpose

定义 `f_data` 的 `Data → JSON 文本` 路径的转义契约与分配约束：转义结果不变，无需转义的字符串不构造额外缓冲。

## ADDED Requirements

### Requirement: 无转义字符串走快路径

`escapeJsonString` SHALL 在字符串不包含 `"`、`\` 或码点小于 `0x20` 的字符时原样返回输入字符串，MUST NOT 构造转义缓冲或新字符串。

#### Scenario: 普通 ASCII

- **WHEN** 输入为 `plain text 123`
- **THEN** 返回内容与输入完全相同

#### Scenario: 中文与 emoji

- **WHEN** 输入为 `汉字😀`（无非转义字符）
- **THEN** 返回内容与输入完全相同

#### Scenario: 空字符串

- **WHEN** 输入为空字符串
- **THEN** 返回空字符串

### Requirement: 转义结果不变

需要转义的字符串 SHALL 按既有规则输出：`"` → `\"`、`\` → `\\`、换行/回车/制表 → `\n`/`\r`/`\t`、其余码点 `< 0x20` → `\u00XX`。转义 MUST NOT 受快路径影响。

#### Scenario: 双引号与反斜杠

- **WHEN** 输入为 `a"b\c`
- **THEN** 输出为 `a\"b\\c`

#### Scenario: 控制字符

- **WHEN** 输入包含 `\n`、`\r`、`\t` 与 `U+0001`
- **THEN** 输出分别为 `\n`、`\r`、`\t`、`\u0001`，其余字符原样

#### Scenario: 转义与非 ASCII 混合

- **WHEN** 输入为 `中"文😀\n`
- **THEN** 中文与 emoji 原样，引号与换行按规则转义

#### Scenario: `toJsonString` 集成

- **WHEN** 对 `DataString` 调用 `toJsonString()`
- **THEN** 结果与改动前逐字节相同（含引号包裹）

### Requirement: 转义分配基准

本变更 MUST 提供可重复执行的分配基准：

1. 基准由环境变量开启，未开启时打印跳过原因；
2. 普通字符串（无转义字符）转义 MUST 断言 `<= 128 B/次`；
3. 基准 MUST 同时测量旧式「逐 rune 构造缓冲」实现作为对照，并断言快路径低 8 倍以上；
4. 使用多次采样取最小值。

#### Scenario: 基准开启

- **WHEN** 设置 `F_DATA_JSON_BENCH=1` 并运行 `f_data` 测试
- **THEN** 打印快路径与旧路径的 `allocPerCall`，断言快路径 `<= 128 B/次` 且旧路径总量高于快路径 8 倍

#### Scenario: 基准未开启

- **WHEN** 未设置环境变量
- **THEN** 用例打印跳过原因并通过
