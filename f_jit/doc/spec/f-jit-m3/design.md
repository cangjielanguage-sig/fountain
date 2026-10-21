# Design

## Context

补齐异构搬运（Any 15）与 JSON 内建句柄码 16–19：装箱/问答/强制转型 + 世界内可变 JSON API。 本设计只回答「怎么做」，需求与验收见 `proposal.md` 与 `specs/`；
实现细节以 `design-m3.md（§5 helper 表 / §11 JSON）` 为准，本文只登记**关键决策与不变量**。

## 决策摘要

1. H78 `any_box` / H79 `any_is` / H80 `any_as`（typecode + aux 描述符）
2. JSON 内建码 16–19 与反引号字面量（kind 11 常量）
3. H81 `json_get` / H82 `json_set` / H83 `json_new`
4. frozen 标记与经读/拆箱的传播

## 不变量

- 包依赖 DAG：`compiler → bytecode → base`，`runtime` 不反向依赖根包；跨包可见性只用
  `protected`（module 级）与根包 `public import`。
- 执行路径零反射：所有判定在**注册期**绑定（`$as$`、方法 bind、字段访问器）。
- helper 边界不抛异常：失败一律转错误码写 `ctx` 错误槽，异常只存在于宿主边界。
- 窗口/句柄记账与 `hwTop` 一致：世界内分配必须计入窗口，桥侧 pin 不占窗口。
