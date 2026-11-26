# Spec Delta

## ADDED Requirements

### Requirement: `@DataAssist` 展开的父接口列表必须归一化

`@DataAssist` 在展开被修饰类时 MUST 归一化其父接口列表：同一父接口（含相同类型实参）MUST 只出现一次；存在 `Comparable<X>` 时 MUST NOT 再保留 `Equatable<X>`。归一化 MUST NOT 改变类最终实现的接口集合——类仍 MUST 同时是 `Comparable<X>` 与 `Equatable<X>` 的实例。

#### Scenario: 宏同时生成 equal 与 compare

- **WHEN** 类 `DataTest` 被 `@DataAssist[hash equal props fields tostring compare]` 修饰，自身未声明任何父接口
- **THEN** 展开后父接口列表含 `Comparable<DataTest>`、不含 `Equatable<DataTest>`，编译通过
- **AND** `DataTest()` 同时满足 `is Comparable<DataTest>` 与 `is Equatable<DataTest>`

#### Scenario: 用户显式声明两个接口

- **WHEN** 类写成 `class OrderedItem <: Comparable<OrderedItem> & Equatable<OrderedItem>` 且被 `@DataAssist[... equal ... compare]` 修饰
- **THEN** 展开后只保留 `Comparable<OrderedItem>`，编译通过，`compare` / `==` / `!=` 由宏生成并可正常调用

#### Scenario: 用户显式声明与宏生成重复

- **WHEN** 类显式列出 `Hashable` / `ToString` / `Comparable<X>` / `Equatable<X>`，而宏属性又要求生成同名接口
- **THEN** 重复项被丢弃，不产生 `duplicate interface` 编译错误

#### Scenario: 无冗余声明时保持原样

- **WHEN** 类只用 `@DataAssist[fields props]`（或只带 `equal`，不带 `compare`）
- **THEN** 父接口列表只做去重，`Equatable<X>` 不受影响，生成成员与修复前一致
