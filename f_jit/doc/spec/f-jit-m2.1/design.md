# Design

## Context

让字节码能构造与访问宿主仓颉 class：反射自动注册 + 手工覆盖，成员访问降为预定义函数调用。 本设计只回答「怎么做」，需求与验收见 `proposal.md` 与 `specs/`；
实现细节以 `design-m2.md §12（成员访问增量）` 为准，本文只登记**关键决策与不变量**。

## 决策摘要

1. `registerType<T>()` 反射自动注册（字段/方法/prop/静态/构造器）
2. `@JitBind` 手工绑定覆盖反射实现（同一槽位替换）
3. 构造器物化：`C(args…)` 走注册期合成的构造 helper
4. 成员访问语法糖 `u.f` / `u.f = v` / `u.m(a)`

## 不变量

- 包依赖 DAG：`compiler → bytecode → base`，`runtime` 不反向依赖根包；跨包可见性只用
  `protected`（module 级）与根包 `public import`。
- 执行路径零反射：所有判定在**注册期**绑定（`$as$`、方法 bind、字段访问器）。
- helper 边界不抛异常：失败一律转错误码写 `ctx` 错误槽，异常只存在于宿主边界。
- 窗口/句柄记账与 `hwTop` 一致：世界内分配必须计入窗口，桥侧 pin 不占窗口。
