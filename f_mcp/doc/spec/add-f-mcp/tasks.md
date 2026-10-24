# Tasks

> 每个任务按 Red-Green-Refactor 推进：先写失败用例并确认失败原因正确，再写最小实现，跑绿后才勾选。

## 1. 骨架与协议基础

- [x] 1.1 `f_mcp/cjpm.toml` 确认路径依赖 `../f_jsonrpc` `../f_data` `../f_log`；`src/` 与 `doc/` 就绪
- [x] 1.2 失败用例：`McpException` 的 code/message/data；协议常量（版本、`_meta` 键、错误码）
- [x] 1.3 失败用例：五种内容块的 JSON 形态（text / image / audio / resource / resource_link）与 base64
- [x] 1.4 实现 `McpProtocol` / `McpException` / `ContentBlock`

## 2. 工具与资源模型

- [x] 2.1 失败用例：工具名合法性与唯一性；`$ref` 扫描与位置
- [x] 2.2 失败用例：`McpToolBuilder.of<T>()` / 显式 schema / 文件加载归一
- [x] 2.3 失败用例：资源 URI 白名单、fragment、重复注册、保留前缀
- [x] 2.4 实现 `McpTool` / `McpToolBuilder` / `McpResource` / `ResourceContent`

## 3. 服务端骨架与发现

- [x] 3.1 失败用例：`server/discover` 返回版本、能力、serverInfo，且没有 `prompts`
- [x] 3.2 失败用例：`_meta` 缺失 / 版本不支持（`-32022` + `supported`）/ 版本合法后剥离 `_meta`
- [x] 3.3 失败用例：legacy 方法 `-32601` + `legacyMethod` + 升级文案
- [x] 3.4 实现 `McpServer` / Builder / `McpRegistry` 与统一 `_meta` 校验

## 4. 工具方法

- [x] 4.1 失败用例：`tools/list` 按名排序 + 分页 + 稳定顺序
- [x] 4.2 失败用例：`tools/call` 参数校验（`-32602` + data）与单轮结果
- [x] 4.3 失败用例：`isError` 语义（业务失败不产生 JSON-RPC error）
- [x] 4.4 失败用例：`structuredContent` 双写 text 块
- [x] 4.5 实现 `tools/list` / `tools/call`

## 5. 资源方法

- [x] 5.1 失败用例：`resources/list` 按 URI 排序 + 分页
- [x] 5.2 失败用例：`resources/read` 文本 / 二进制（base64）/ 多段 `contents`
- [x] 5.3 失败用例：不存在的 URI → `-32002` + `data.uri`
- [x] 5.4 实现 `resources/list` / `resources/read`

## 6. 限流与并发

- [x] 6.1 失败用例：三层配置解析（全局 → 服务级 → 工具覆盖）
- [x] 6.2 失败用例：令牌桶补充与超限；`-32050` 的 `scope` / `limit` / `retryAfterMs`
- [x] 6.3 失败用例：并发闸门 tryAcquire/release、异常路径释放、key 回收
- [x] 6.4 实现 `RateLimitPolicy` / `ToolRateLimit` / `BucketStore` / `ConcurrencyGate` 并接入 `tools/call`

## 7. 大结果与临时存储

- [x] 7.1 失败用例：`ToolResultStore` 条数 / 字节 / TTL、CAS 预算、过期减账、惰性 sweep
- [x] 7.2 失败用例：超阈值 + `publicBaseUrl` → 单个 `resource_link`，可被 `resources/read` 读回
- [x] 7.3 失败用例：未配 `publicBaseUrl` → 截断 + `data.truncated`
- [x] 7.4 实现 `ToolResultStore` / `ByteBudget` 与大结果接线

## 8. 客户端

- [x] 8.1 失败用例（假 RPC）：`_meta` 注入、`discover`、`listTools` / `listAllTools`
- [x] 8.2 失败用例：`-32022` 只重试一次；legacy `-32601` → `McpException`
- [x] 8.3 失败用例：`callTool` 的 `resultType` / `input_required` 原样透传；`readResource`
- [x] 8.4 实现 `McpClient` / `McpClientOptions` / 页类型 / `McpRpc` 适配

## 9. HTTP 入口

- [x] 9.1 失败用例：`/mcp` 注册为 POST + `application/json`
- [x] 9.2 实现 `McpController` 与 `McpRegistry`

## 10. 文档、回归与交付

- [x] 10.1 `f_mcp/README.md` 与 `README_en.md`（中英成对）
- [x] 10.2 规格落盘 `f_mcp/doc/spec/add-f-mcp/`
- [x] 10.3 受影响模块 + `cjpm test` 回归；verify（CRITICAL 清零）
- [x] 10.4 提交、合并回 `sts/1.3.x`、推送

## 11. 追加能力（本轮要求）

- [x] 11.1 stdio 客户端传输（子进程 stdin/stdout 行分帧，stderr 独立消费）
- [x] 11.2 `input_required` 的 `Auto` 多轮（`callToolAuto`，新 id、轮次上限）
- [x] 11.3 `ToolResultStore` 运行期自适应调容（窗口统计、只调 `maxEntries`）
- [x] 11.4 `subscriptions/listen` + `/mcp/sse`（`text/event-stream`、心跳、30 分钟上限）
- [x] 11.5 `prompts/list` / `prompts/get` 与能力声明
- [x] 11.6 分布式限流 SPI（`RateLimitBackend`）+ 本地实现
