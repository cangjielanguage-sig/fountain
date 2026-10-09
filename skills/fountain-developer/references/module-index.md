# fountain 模块索引与选型

索引快照时间：2026-10，取自根 `README.md`「各模块详细文档」。
**可能滞后**：以 `fountain_lookup.py modules` 的现场输出与各模块 README 为准。
每个模块的详细用法读 `<模块>/README.md`（英文镜像 `<模块>/README_en.md`），细节核对 `<模块>/src/`。

## 1. 模块表

| 模块 | 描述（一句话） | 常用场景 |
| --- | --- | --- |
| `f_app` | 应用进程管理：加载应用动态库、启动/关闭/重启、子命令机制 | fboot 基础，业务一般不直接用 |
| `f_aspect` | AOP | 日志/事务/权限切面 |
| `f_base` | 基础扩展：Iterator/String/Array/Option/Range/Number 扩展、OS、HashBuilder 等 | 到处都会用到 |
| `f_bean` | IOC 容器 | `@Bean` + `lookup<T>()` 依赖注入 |
| `f_bloom` | 布隆过滤器 | 去重、存在性判断 |
| `f_cache` | 堆缓存 | 本地缓存 |
| `f_cmd` | 命令行工具 | CLI 应用 |
| `f_codec` | 编解码器 | 序列化/协议编解码 |
| `f_collection` | 标准库尚不支持的集合与集合扩展 | 并发跳表等 |
| `f_concurrent` | 负载均衡、限流算法、并发集合扩展 | 限流、负载均衡 |
| `f_config` | 配置模块 | 读环境变量/配置项 |
| `f_crypto` | 加密模块 | 对称/非对称加密 |
| `f_data` | 数据复制、字段验证注解、反射读写 | DTO 映射、参数校验 |
| `f_egraph` | 事件驱动的流程库 | 流程编排（f_llm 的基础） |
| `f_exception` | 异常模块 | 自定义异常体系 |
| `f_health` | 进程健康检查 | 健康检查接口 |
| `f_http` | HTTP 数据格式：MediaType、json、multipart/form-data | MVC 底层，业务少直接用 |
| `f_httpclient` | HTTP 客户端 | 调第三方 HTTP 接口 |
| `f_io` | IO 扩展（含 SegmentedLog 等） | 文件/日志存储 |
| `f_jwt` | JWT | 令牌签发与校验 |
| `f_log` | 日志 | `LoggerFactory.getLogger<T>()` / `getLogger('name')` |
| `f_macros` | 宏工具 API | 写自定义宏时用 |
| `f_mockdb` | mock database | 测试替身 |
| `f_mvc` | MVC：HTTP 服务器、路由、参数绑定、Controller | Web 接口的主入口 |
| `f_net` | 事件驱动的网络通讯 | 长连接/自定义协议服务端 |
| `f_orm` | ORM：连接池、DAO、事务、驱动注册 | 数据库访问 |
| `f_pool` | 对象池/数组池/ArrayList 池 | 池化复用 |
| `f_process` | 进程扩展 | 子进程管理 |
| `f_protocol` | 网络通讯协议实现 | fleet 等上层协议 |
| `f_random` | 随机数扩展：ThreadLocalRandom、蓄水池、随机字符串 | 随机数/随机 ID |
| `f_regex` | 正则扩展、缓存、DSL | 文本处理 |
| `f_rpc` | RPC：服务注册发现、负载均衡、心跳 | 服务间调用 |
| `f_rx` | 反应式编程 API | 流式处理 |
| `f_security` | 配合 MVC 使用的安全模块 | 权限/认证（与 f_jwt 配套） |
| `f_store` | LSM-TREE 键值存储 | 本地 KV、前缀遍历 |
| `f_ticktock` | CRON 定时器 | 定时任务 |
| `f_time` | 时间 API 扩展 | 时间换算/格式化 |
| `f_util` | crc16/密钥交换/命名风格转换/设计模式/geohash/snowflake/UUID/murmur/路径匹配/文本模板/树结构 | 各种工具 |
| `f_version` | 应用与 fountain 版本信息、BANNER | 版本管理 |
| `f_uring` | liburing 的 FFI 封装 | 仅 Linux，高性能 IO |
| `f_llm` | 基于 f_egraph 的大模型开发库 | **不发布中心仓**（`.modules` `[detention]`） |
| `fleet` | 基于 store/codec/net/protocol 的数据同步服务：服务注册、配置中心、元数据注册 | **不发布中心仓**（`.modules` `[detention]`） |

工具与示例（非库依赖）：`fboot`（启动器）、`fcoder`（命令行 AI 编程工具）、`fdemo`（全链路示例）、`frpcdemo`（RPC 示例）。

## 2. 选型速查（需求 → 模块）

| 需求 | 首选 | 配套 |
| --- | --- | --- |
| HTTP 接口 / REST / 路由 / 参数绑定 | `f_mvc` | `f_http`（底层格式）、`f_data`（参数校验） |
| 依赖注入 | `f_bean` | — |
| 数据库（连接池 / DAO / 事务） | `f_orm` | 驱动包（如 `postgres_driver`，第三方） |
| 日志 | `f_log` | — |
| 配置读取 | `f_config` | — |
| 登录认证 / 权限 | `f_jwt` + `f_security` | `f_mvc` 的 `@IgnoreSecurity` 等注解 |
| 定时任务 | `f_ticktock` | 参考 `fdemo/user/src/util` 里的 cron 用法 |
| 调用外部 HTTP 服务 | `f_httpclient` | — |
| 本地缓存 | `f_cache` | — |
| 限流 / 负载均衡 | `f_concurrent` | — |
| JSON 序列化 | `f_codec`；或 stdx `encoding.json`（按模块 README 推荐） | — |
| AOP 切面（日志/事务/审计） | `f_aspect` | `f_mvc` 的切面配置项 |
| RPC / 服务发现 | `f_rpc` | — |
| 本地键值存储 | `f_store` | — |
| 长连接/自定义协议 | `f_net` + `f_protocol` | — |
| 健康检查 | `f_health` | — |
| 加密 / 摘要 | `f_crypto` | stdx `crypto.*` |
| 工具函数（UUID/snowflake/模板/路径匹配…） | `f_util` | — |

**注意**：JSON 相关的具体写法以 `f_codec` README 与 `fdemo` 实际用法为准；不要凭其它语言经验直接写。
凡是「需求有、模块没覆盖」的，按 SKILL.md 工作流 E 第 3 步处理（停下问用户），不许造 API。

## 3. 深入阅读指引

- 想知道某关键词在哪些模块出现：`python scripts/fountain_lookup.py search "关键词"`（可加 `--in code` 只搜源码）。
- 想知道某模块的顶层公开声明清单：`python scripts/fountain_lookup.py api f_mvc`。
- 模块 README 的「其他公开 API」小节是自动生成的签名清单，适合快速扫 API 面；配置项（环境变量）一般在 README 的配置表中。
- 依赖关系与分层：根 `README.md` 的两张依赖图；生成脚本在 `docs/模块依赖图/`。
- 模块是否发布：根 `.modules` 的 `[include]` / `[detention]`。
