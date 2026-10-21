# Design

## Context

让字节码接收并调用宿主仓颉闭包（13 型），并支持闭包捕获与提升组协作。 本设计只回答「怎么做」，需求与验收见 `proposal.md` 与 `specs/`；
实现细节以 `design-m2.md §4/§13` 为准，本文只登记**关键决策与不变量**。

## 决策摘要

1. HostClosure 形参（LocalType 13）与签名描述符
2. `CALL_HOST` 四步（验签 → 调用 → 装箱 → 转码）
3. H63 `host_call_trampoline` 与 per-signature 特化
4. 闭包捕获描述符与提升组（`moveOutGroup`）

## 不变量

- 包依赖 DAG：`compiler → bytecode → base`，`runtime` 不反向依赖根包；跨包可见性只用
  `protected`（module 级）与根包 `public import`。
- 执行路径零反射：所有判定在**注册期**绑定（`$as$`、方法 bind、字段访问器）。
- helper 边界不抛异常：失败一律转错误码写 `ctx` 错误槽，异常只存在于宿主边界。
- 窗口/句柄记账与 `hwTop` 一致：世界内分配必须计入窗口，桥侧 pin 不占窗口。
