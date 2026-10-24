# Tasks

> 每个任务按 Red-Green-Refactor 推进：先写失败用例并确认失败原因正确，再写最小实现，跑绿后才勾选。

## 1. 骨架与登记

- [x] 1.1 新建 `f_jsonrpc` 模块骨架：`cjpm.toml`（`output-type = "dynamic"`、`--dy-std`、路径依赖 `../f_mvc` `../f_data` `../f_log`）与 `src/`、`doc/` 目录
- [x] 1.2 新建 `f_mcp` 模块骨架：`cjpm.toml`（路径依赖 `../f_jsonrpc` `../f_data` `../f_log`）与 `src/`、`doc/` 目录（本变更不实现其逻辑）
- [x] 1.3 设计文档迁入 `f_jsonrpc/doc/` 与 `f_mcp/doc/`；`.modules` 的 `[include]` 登记两个模块；不改根 `src/` 聚合 shim 与根 `cjpm.toml`

## 2. f_data：JsonSchema.validate（P-1.5）

- [x] 2.1 失败用例：实例版 `type` / `minLength` / `maxLength` / `enum` / `nullable` / `items` 递归
- [x] 2.2 失败用例：文档版 `properties` / `required` / `additionalProperties` / 嵌套对象 / 数组元素
- [x] 2.3 失败用例：fail-closed（`$ref`、组合关键字、坏 schema）与 `UnknownKeyword.Skip` 的 `skipped`
- [x] 2.4 失败用例：`maxErrors` 提前返回、`maxDepth`、`ValidationResult.toJson()` 结构
- [x] 2.5 实现 `ValidationError` / `ValidationResult` / `ValidationOptions` / `UnknownKeyword` + 实例版校验
- [x] 2.6 实现文档版校验（含 `pattern` / `format` 正则走 `f_regex`、`uniqueItems` 大数组跳过）

## 3. f_jsonrpc：消息模型与错误

- [x] 3.1 失败用例：`JsonRpcError` 序列化（含/不含 `data`）、协议常量
- [x] 3.2 失败用例：`id` 保真（字符串 / 大整数 / `null`）
- [x] 3.3 实现 `JsonRpcProtocol` 常量、`JsonRpcException`、`JsonRpcError`

## 4. f_jsonrpc：方法表

- [x] 4.1 失败用例：注册、重复注册抛错、`methods()` 按名稳定排序、元数据字段可读
- [x] 4.2 实现 `JsonRpcHandler` / `JsonRpcMethodMeta` / `JsonRpcServer.addMethod` / `methods`

## 5. f_jsonrpc：单请求处理

- [x] 5.1 失败用例：成功响应、`-32601`、`-32600`（缺 `jsonrpc` / `method` 非字符串）、`-32700`（非法 JSON / 非法 UTF-8）
- [x] 5.2 失败用例：请求体超限（`maxBodyBytes`）
- [x] 5.3 实现 `JsonRpcServer.handle` 单请求流水线（大小检查 → 解析 → 形态校验 → 方法表 → 调用 → 错误映射）
- [x] 5.4 失败用例 + 实现：`-32603` 固定文案、异常细节只进日志

## 6. f_jsonrpc：批量与通知

- [x] 6.1 失败用例：批量混合通知、全通知无响应、空数组单错误、超 `maxBatchSize` 整批 `-32003`
- [x] 6.2 失败用例：单条通知返回 `None`、通知内异常不产生响应但记录日志
- [x] 6.3 实现批量与通知（只回有 `id` 的条目，顺序稳定）

## 7. f_jsonrpc：topic 命名空间

- [x] 7.1 失败用例：`/rpc/kb` 命中 `kb.search`、跨命名空间 `-32601`、未知 topic `-32004`、无点方法只能从 `/rpc` 调用
- [x] 7.2 实现 topic 过滤与命名空间集合维护

## 8. f_jsonrpc：参数校验接线

- [x] 8.1 失败用例：声明 `paramsSchema` 且参数不合法 → `-32602`、`error.data` 为 `ValidationResult.toJson()`、handler 未调用
- [x] 8.2 失败用例：未声明 schema 时跳过校验
- [x] 8.3 实现 `paramsSchema` 的注册期编译与调用期校验

## 9. f_jsonrpc：超时与上下文

- [x] 9.1 失败用例：带 `timeout` 的方法超时返回 `-32002`；无 `timeout` 时不产生 `-32002`；`ctx.deadline` 可读
- [x] 9.2 失败用例：`setResponseHeader` 在 `http = None` 时静默忽略
- [x] 9.3 实现 `spawn` + 超时等待、`deadline`、响应头写入接缝

## 10. f_jsonrpc：注解、controller 与注册表

- [x] 10.1 失败用例：`@Controller` + `@JsonRpcMapping` 生成 `RequestMeta`，`method = POST`、`consumes` / `produces` 含 `application/json`
- [x] 10.2 实现 `JsonRpcMapping`、`JsonRpcController`（`/rpc`、`/rpc/{topic}`）、`JsonRpcRegistry`
- [x] 10.3 失败用例 + 实现：`invoke` 本地直调不依赖 HTTP

## 11. f_jsonrpc：客户端

- [x] 11.1 失败用例（假传输）：`call` 请求形态（POST / Content-Type / 紧凑 body）与结果解析
- [x] 11.2 失败用例：服务端 `error` → 抛 `JsonRpcException`；`notify` 不解析响应；`batch` 同序
- [x] 11.3 实现 `JsonRpcClient` / `ClientOptions` / 传输接缝（默认 `stdx.net.http.Client`，连接复用、默认不重试）
- [x] 11.4 HTTP 传输实现完成；端到端 loopback / fboot 冒烟因本机无 fboot 记为遗留项（见 design 风险表）

## 12. 文档、回归与交付

- [x] 12.1 `f_jsonrpc/README.md` 与 `README_en.md`（中英成对，公开 API 与用法）
- [x] 12.2 五件套落盘 `f_jsonrpc/doc/spec/add-f-jsonrpc/` 与 `f_data/doc/spec/add-f-jsonrpc/spec.md`
- [x] 12.3 受影响模块 + 仓库全量 `cjpm test` 回归；`opsx:verify` CRITICAL 清零
- [x] 12.4 提交、合并回 `sts/1.3.x`、推送
