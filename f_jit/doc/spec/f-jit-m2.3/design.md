# Design

## Context

补齐 `as T` / `as T ?? V`、`$as$<C>` 运行期判定与闭包签名适配，使 M2 的宿主互操作闭合。 本设计只回答「怎么做」，需求与验收见 `proposal.md` 与 `specs/`；
实现细节以 `design-m2.md §12.4/§16` 为准，本文只登记**关键决策与不变量**。

## 决策摘要

1. `as T` / `as T ?? V` 的静态与运行期两层语义
2. 注册期合成 `$as$<C>`（`(14) -> Bool`）
3. H77 `cast_fail`（失败 = 7，与 22 严格区分）
4. `@JitSignatures` 生成的闭包 adapter

## 不变量

- 包依赖 DAG：`compiler → bytecode → base`，`runtime` 不反向依赖根包；跨包可见性只用
  `protected`（module 级）与根包 `public import`。
- 执行路径零反射：所有判定在**注册期**绑定（`$as$`、方法 bind、字段访问器）。
- helper 边界不抛异常：失败一律转错误码写 `ctx` 错误槽，异常只存在于宿主边界。
- 窗口/句柄记账与 `hwTop` 一致：世界内分配必须计入窗口，桥侧 pin 不占窗口。
