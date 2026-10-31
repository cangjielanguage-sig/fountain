# 设计：JsonRpc 宏收敛与端到端 demo

## D1. 单一宏名

类宏只保留 `JsonRpc`。Cangjie 宏名区分大小写，`@JsonRpc` 与注解 `@JsonRpcMeta` 形成一致的命名。删除 `jsonrpcmeta`：它只是把参数转给 `JsonRpcMeta`，没有额外语义，保留会让注解出现两条读取路径。

## D2. 运行期读取注解

`JsonRpcRegistry.getMeta<T>(funcName, argTypes)` 直接调用 `TypeInfo.of<T>().getInstanceFunction(fnName, argTypes)` 定位重载，再返回 `findAnnotation<JsonRpcMeta>()`；未找到时捕获 `InfoNotFoundException` 返回默认值。宏不再扫描 `ClassDecl.toTokens()`，也不再生成 description / timeout 字面量。

- 生成代码：`let __jsonrpc_meta = JsonRpcRegistry.getMeta<T>('fn', [TypeInfo.of<...>()])`
- handler 内：`lookup<T>().fn(...)`
- `timeout`：`if (meta.timeout.isEmpty()) { None } else { Some(meta.timeoutDuration) }`

没有注解时 `getMeta` 返回 `JsonRpcMeta('', '500ms')`：无描述，超时默认 500ms。

## D3. 删除的 API

- `JsonRpcRegister` 类整体删除：`getMeta` 迁入 `JsonRpcRegistry`；`instance` 仅测试使用，一并删除。解析职责下沉到 `JsonRpcMeta.timeoutDuration`
- `JsonRpcRegisteredMeta`：`getMeta` 直接返回注解对象
- `paramCount!` 由 `argTypes` 取代：同名重载按参数类型匹配
- 宏文件里的 `func str` 与 `metaMap` / `isStringToken`

## D4. HTTP 客户端 keep-alive

stdx `HttpResponse.close()` 的语义是“放弃未读完的 body、关闭连接”。`JsonRpcClient` 之前无论是否读完都调用 `close()`，导致连接池里的连接被关掉，第二次请求报 `Socket is already closed`。改为：

- 正常读完 body：不 close，由连接池复用
- 读取 / 大小校验异常：close 后原样抛出

## D5. SSE 流式响应

stdx http server 对 `InputStream` body 且没有长度信息的响应要求显式 `Transfer-Encoding: chunked`，否则抛 `Unknown body size for Content-Length header` 并回 500。`McpController.sse()` 在返回 `McpSseStream` 前写该响应头。

## D6. demo 模块布局

两个 demo 都是独立 workspace，子模块 `output-type = "dynamic"`，由 `fboot run` 加载：

- `fjsonrpcdemo/{server,client}`，`boot.sh` 支持 `build/runServer/runClient/e2e`
- `fmcpdemo/{server,client}`，同样四种子命令

服务端与客户端用不同 `mvc_port`，避免同机端口冲突。客户端用 `Initializer.start()` 执行验证后 `exit`，不在动态库静态初始化阶段做网络调用（静态初始化阶段 `exit` 会卡住 dlopen）。

## D7. 分布式限流验证

`fmcpdemo` 的 `SharedWindowBackend` 实现 `RateLimitBackend`，用进程内共享计数器模拟外部存储。服务端启动时构建两个 `McpServer` 共用同一个 backend，对 `limited` 工具连续调用 4 次，断言第 4 次为 `-32050`。真实部署把 backend 换成 Redis / f_store 即可。

## 风险

- `getMeta` 依赖运行期反射；类首次使用前注解元数据可能未就绪。demo 与单测均在 `@Bean` 注册完成后调用，已验证可用。
- 无同名方法重载消歧：`getMeta` 只按方法名取第一个。当前不支持 JSON-RPC 方法重载。
