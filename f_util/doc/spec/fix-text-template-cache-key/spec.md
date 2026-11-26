# Spec Delta

## Purpose

定义文本模板从模板字符串编译、缓存到格式化的行为契约：分隔符参数必须参与缓存键，同一模板串在不同分隔符下互不串味。

## ADDED Requirements

### Requirement: 缓存键必须包含分隔符

模板编译结果的缓存键必须同时包含模板字符串、前缀和后缀。任意一个不同，都必须得到独立的编译结果。

#### Scenario: 同一模板串先后用花括号与默认分隔符编译

- **WHEN** 先用 `prefix: "{", suffix: "}"` 编译模板串 `"hello ${name}"`，再用默认 `prefix: "${", suffix: "}"` 编译同一个模板串
- **THEN** 第一次把 `{name}` 当作占位符（`$` 是字面量），第二次把 `${name}` 当作占位符；两次格式化结果分别符合各自的分隔符语义

#### Scenario: 反向顺序

- **WHEN** 先用默认分隔符编译 `"hello {name}"`，再用 `prefix: "{", suffix: "}"` 编译同一个模板串
- **THEN** 第一次原样输出 `"hello {name}"`，第二次把 `name` 替换为实参；两次互不串味

### Requirement: 相同分隔符的重复编译输出一致

同一模板串、同一分隔符组合重复编译并格式化，输出必须逐字符一致。

#### Scenario: 重复编译同一模板

- **WHEN** 用相同模板串和相同分隔符连续编译两次，分别用相同实参格式化
- **THEN** 两次输出完全一致

### Requirement: 默认分隔符语义不变

不显式传入分隔符时，占位符仍是 `${...}`；`placeholder!` 重载仍把同一个字符串同时作为前缀和后缀。

#### Scenario: 默认编译替换 ${name}

- **WHEN** 用默认参数编译 `"hello ${name}"` 并传入 `name = "world"`
- **THEN** 输出 `"hello world"`

#### Scenario: placeholder 重载同时用作前后缀

- **WHEN** 用 `placeholder: "#"` 编译 `"hello #name#"` 并传入 `name = "world"`
- **THEN** 输出 `"hello world"`
