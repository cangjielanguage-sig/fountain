# fountain 模块索引与选型

索引快照时间：2026-10-23（`sts/1.3.x`，1.3.16 之后的开发分支），取自根 `README.md`「各模块详细文档」。
**可能滞后**：以 `fountain_lookup.py modules` 的现场输出与各模块 README 为准；现场查询按**在用版本**（脚本会把文档副本切到该版本，输出头部标注版本，见 SKILL.md「定位 fountain 仓库与查询版本」）。
每个模块的详细用法读 `<模块>/README.md`（英文镜像 `<模块>/README_en.md`），特性语义与限制读 `<模块>/doc/**/*.md`，细节核对 `<模块>/src/`。

## 1. 模块表

| 模块 | 描述（一句话） | 常用场景 |
| --- | --- | --- |
| `f_app` | 应用进程管理：加载应用动态库、启动/关闭/重启、子命令机制 | fboot 基础，业务一般不直接用 |
| `f_aspect` | AOP | 日志/事务/权限切面 |
| `f_base` | 基础扩展：Iterator/String/Array/Option/Range/Number 扩展、OS、HashBuilder、CpuFeatures 等 | 到处都会用到 |
| `f_bean` | IOC 容器 | `@Bean` + `lookup<T>()` 依赖注入 |
| `f_bloom` | 布隆过滤器 | 去重、存在性判断 |
| `f_cache` | 堆缓存（`HeapCache` / `WeakHeapCache`，分段互斥锁 + LRU） | 本地缓存 |
| `f_cmd` | 命令行工具 | CLI 应用 |
| `f_codec` | 编解码器 | 序列化/协议编解码 |
| `f_collection` | 标准库尚不支持的集合与集合扩展 | 并发跳表等 |
| `f_concurrent` | 负载均衡、限流算法、并发集合扩展 | 限流、负载均衡 |
| `f_config` | 配置模块（`Config.get*` / `set` / `remove`） | 读环境变量/配置项 |
| `f_crypto` | 加密模块 | 对称/非对称加密 |
| `f_data` | 数据复制、字段验证注解、反射读写、`path` 表达式（过滤器） | DTO 映射、参数校验、按路径过滤 |
| `f_dbd` | `std.database.sql` 驱动：把 SQL 与参数发给 `fdbm` 中间件，按需拉回结果集；不依赖物理库驱动 | 接 fdbm 中间件、多节点 `multidbd://` |
| `f_dbm` | 数据库中间件扩展接口：分库算法 `PartitionAlgorithm`、ID 生成器 `IdGenerator` 契约（名字必须唯一：与内置或彼此同名 ⇒ 启动失败） | 给 fdbm 写第三方扩展 |
| `f_dbpool` | 数据库连接池：`DatabasePool` / `PooledConnection`（不读配置项，池参数显式传入） | 自己管理连接池参数、不经 f_orm 直接用池 |
| `f_egraph` | 事件驱动的流程库 | 流程编排（f_llm 的基础） |
| `f_exception` | 异常模块 | 自定义异常体系 |
| `f_health` | 进程健康检查 | 健康检查接口 |
| `f_http` | HTTP 数据格式：MediaType、json、multipart/form-data | MVC 底层，业务少直接用 |
| `f_httpclient` | HTTP 客户端 | 调第三方 HTTP 接口 |
| `f_io` | IO 扩展：`SegmentedLog`（段日志：追加、按 `(编号, 偏移)` 读、按编号/时间删段、`durableBoundary`） | 追加型日志存储、消息/队列落盘 |
| `f_jit` | 仓颉方言的字节码编译器与 JIT（解释器 + x86_64 / aarch64 机器码后端，`JitFunction.call<T>`） | 运行期求值表达式、可配置规则、脚本化 |
| `f_jwt` | JWT | 令牌签发与校验 |
| `f_log` | 日志 | `LoggerFactory.getLogger<T>()` / `getLogger('name')` |
| `f_macros` | 宏工具 API | 写自定义宏时用 |
| `f_mockdb` | mock database | 测试替身 |
| `f_mq` | MQ 客户端与客户端/服务端共用 API：`MQClient` 发布/订阅/消费/ack、tag 与 `path` 过滤、错误码 | 异步消息、发布订阅 |
| `f_mvc` | MVC：HTTP 服务器、路由、参数绑定、Controller | Web 接口的主入口 |
| `f_net` | 事件驱动的网络通讯 | 长连接/自定义协议服务端 |
| `f_orm` | ORM：连接池、DAO、事务、驱动注册 | 数据库访问 |
| `f_pool` | 对象池/数组池/`KeyPool`/`ArrayListPool`（`close()` + `awaitTermination(timeout!)`） | 池化复用、优雅关停 |
| `f_process` | 进程扩展 | 子进程管理 |
| `f_protocol` | 网络通讯协议实现 | fleet / fmq 等上层协议 |
| `f_random` | 随机数扩展：ThreadLocalRandom、蓄水池、随机字符串 | 随机数/随机 ID |
| `f_regex` | 正则扩展、缓存、DSL | 文本处理 |
| `f_rpc` | RPC：服务注册发现、负载均衡、心跳 | 服务间调用 |
| `f_rx` | 反应式编程 API | 流式处理 |
| `f_security` | 配合 MVC 使用的安全模块 | 权限/认证（与 f_jwt 配套） |
| `f_store` | LSM-TREE 键值存储 | 本地 KV、前缀遍历 |
| `f_ticktock` | CRON 定时器（按时间索引筛候选，语义与全量匹配一致） | 定时任务 |
| `f_time` | 时间 API 扩展 | 时间换算/格式化 |
| `f_util` | crc16/密钥交换/命名风格转换/设计模式/geohash/snowflake/UUID/murmur/FNV/路径匹配/文本模板/树结构 | 各种工具 |
| `f_version` | 应用与 fountain 版本信息、BANNER | 版本管理 |
| `f_uring` | liburing 的 FFI 封装 | 仅 Linux，高性能 IO |
| `f_llm` | 基于 f_egraph 的大模型开发库 | **不发布中心仓**（`.modules` `[detention]`） |
| `fleet` | 基于 store/codec/net/protocol 的数据同步服务：服务注册、配置中心、元数据注册 | **不发布中心仓**（`.modules` `[detention]`） |

服务端与示例（不是库依赖）：

| 名称 | 描述 | 形态 |
| --- | --- | --- |
| `fboot` | 应用启动器（构建 / 运行 / 测试 / 发布） | 可执行工具 |
| `fcoder` | 命令行 AI 编程工具 | 可执行工具 |
| `fdbm` | 数据库中间件服务端：一个逻辑库对内做分库路由、读写分离、全局表广播、ID 生成 | 可执行模块（`[include]` 已登记） |
| `fmq` | MQ 服务端：`fmq server` / `fmq manager`（多节点队列、消费组游标、超时重投、死信） | 可执行模块（`[include]` 已登记） |
| `fdemo` | 全链路示例（boot + user 两模块） | workspace |
| `frpcdemo` | RPC 示例 | workspace |
| `fmqdemo` | MQ 两端示例（`fmqpub` 发布端 / `fmqsub` 消费端，均为 fboot 加载的动态库） | workspace |
| `fdbmdemo` | 数据库中间件示例（客户端 + 自定义扩展动态库） | workspace |

**发布登记以根 `.modules` 为准**：`[include]` 段里的模块才发布中心仓（含 `f_jit` / `f_mq` / `f_dbd` / `f_dbm` / `fmq` / `fdbm` / `fboot`），`[detention]` 段明确不发布（当前 `f_llm` / `fleet`）。
「已登记」= 会随发布进中心仓，但**不等于目标版本已有制品**：`f_jit` / `f_dbd` / `f_dbm` / `fdbm` 是刚登记的新模块，早于其发布版本的依赖版本里没有制品。加依赖前先看 `.modules`，解析不到时按 `references/project-setup.md` 退 path 依赖。

## 2. 选型速查（需求 → 模块）

| 需求 | 首选 | 配套 |
| --- | --- | --- |
| HTTP 接口 / REST / 路由 / 参数绑定 | `f_mvc` | `f_http`（底层格式）、`f_data`（参数校验） |
| 依赖注入 | `f_bean` | — |
| 数据库（连接池 / DAO / 事务） | `f_orm` | 驱动包（如 `postgres_driver`，第三方）；只用连接池、要自己控参数时可直接用 `f_dbpool` |
| 分库分表 / 读写分离 / 全局表广播 / 集中 ID | `fdbm`（服务端）+ `f_dbd`（应用侧驱动） | `f_dbm`（自定义分库算法 / ID 生成器）；示例 `fdbmdemo` |
| 消息队列 / 发布订阅 / 消费组 / 延迟投递 / 死信 | `f_mq`（客户端）+ `fmq`（服务端） | 示例 `fmqdemo`；运维用 `fmq manager` |
| 运行期求值仓颉表达式 / 可配置规则 | `f_jit` | 语法子集见 `f_jit/README.md` §6；机器码仅 Linux |
| 日志 | `f_log` | — |
| 配置读取 | `f_config` | — |
| 登录认证 / 权限 | `f_jwt` + `f_security` | `f_mvc` 的 `@IgnoreSecurity` 等注解 |
| 定时任务 | `f_ticktock` | 参考 `fdemo/user/src/util` 里的 cron 用法 |
| 调用外部 HTTP 服务 | `f_httpclient` | — |
| 本地缓存 | `f_cache` | — |
| 限流 / 负载均衡 | `f_concurrent` | — |
| 对象池 / 连接池复用 | `f_pool` | 关停用 `close()` + `awaitTermination(timeout!)` |
| 追加型日志 / 按位置回放 | `f_io`（`SegmentedLog`） | 段清理 `removeById` / `removeBetween` / `remove*Before` |
| JSON 序列化 | `f_codec`；或 stdx `encoding.json`（按模块 README 推荐） | — |
| AOP 切面（日志/事务/审计） | `f_aspect` | `f_mvc` 的切面配置项 |
| RPC / 服务发现 | `f_rpc` | — |
| 本地键值存储 | `f_store` | — |
| 长连接/自定义协议 | `f_net` + `f_protocol` | — |
| 健康检查 | `f_health` | — |
| 加密 / 摘要 | `f_crypto` | stdx `crypto.*` |
| 非加密哈希（缓存键 / 去重键） | `f_util`（FNV-1 / FNV-1a × 32/64/128/256） | 命中后要二次校验原字节（可构造碰撞） |
| 工具函数（UUID/snowflake/模板/路径匹配…） | `f_util` | — |

**注意**：JSON 相关的具体写法以 `f_codec` README 与 `fdemo` 实际用法为准；不要凭其它语言经验直接写。
凡是「需求有、模块没覆盖」的，按 SKILL.md 工作流 F 步骤 2 处理（停下问用户），不许造 API。

## 3. 深入阅读指引

- 想知道某关键词在哪些模块出现：`python scripts/fountain_lookup.py search "关键词"`
  （`--in readme|code|docs` 分别只查 README / 源码 / 设计文档；`--module <名>` 缩到单个模块）。
- **特性语义、限制、已知问题**多在 `<模块>/doc/**/*.md`（设计 / 规格 / 优化方案 / 评审）：`search "<关键词>" --in docs`，输出按 `<模块>/doc` 分组。模块 README 只给结论摘要，二者冲突时以源码与 `doc/` 的最新说明为准。
- 示例代码：`fdemo`（全链路）、`frpcdemo`（RPC）、`fmqdemo`（MQ 发布/消费两端）、`fdbmdemo`（中间件客户端 + 自定义扩展）。
  它们是 workspace，代码在 `<示例>/<子模块>/src/`；`search "关键词" --module fmqdemo --in code` 能直接命中，`api fmqdemo` 可列顶层声明。
- 新模块入口：`f_mq/README.md`（快速开始 + 客户端 API + 错误码）→ `fmqdemo` → `fmq/README.md`（服务端与 manager）；
  `f_dbd/README.md`（应用侧驱动 + 配置项）→ `fdbm/README.md`（SQL 能力、分库、部署）→ `f_dbm/README.md`（扩展）；
  `f_jit/README.md`（API / 语法 / 何时不 JIT）→ `f_jit/doc/`（规格与验收）。
- 想知道某模块的顶层公开声明清单：`python scripts/fountain_lookup.py api f_mvc`。
- 想查某个具体版本（而非项目在用版本）：加 `--version 1.3.16`（或 `--version release-1.3.16.alpha`）；
  脚本会先把技能目录下的文档副本切到该版本再检索，输出头部标注实际版本。
- 模块 README 的「其他公开 API」小节是自动生成的签名清单，适合快速扫 API 面；配置项（环境变量）一般在 README 的配置表中。
- 依赖关系与分层：根 `README.md` 的两张依赖图；生成脚本在 `docs/模块依赖图/`。
- 模块是否发布：根 `.modules` 的 `[include]` / `[detention]`（判定口径见上）。
