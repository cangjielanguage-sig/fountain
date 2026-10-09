# 跨语言项目 → 仓颉（fountain）：转换流程

前提：fountain 仓库**没有**现成的迁移/转换工具，转换是「逐文件人工转换 + 每批编译验证」。
本流程的产出是**独立的新 fountain 项目**，原项目仓库只读、不修改。

## 0. 总则

- 先建最小可跑切片（一个 hello 接口）把「workspace → 模块 → 依赖 → build → run」链路打通，再按批次铺开。
- 每批转换完就 `fboot build`，不要攒着最后一起编译。
- 语法、类型系统、标准库/扩展库问题一律用 `cangjie-coding` 与 `cangjie-doc-lookup` 查证后写。
- 映射不到的缺口按 SKILL.md 工作流 E 第 3 步处理（停下问用户），不许造 API。

## 1. 阶段一：侦察（只读）

输入：本地路径或 git 链接。git 链接先 clone 到新目录（如 `<目标父目录>/<原项目名>-cangjie/source-ref/` 只作参考）。

要回答的问题（逐项记录到转换报告）：

| 维度 | 要采集的信息 |
| --- | --- |
| 技术栈 | 语言、框架、版本、构建方式 |
| 入口 | 启动入口、命令行参数、环境变量 |
| HTTP | 全部路由（方法 + 路径 + 处理器文件）、中间件、错误处理、静态文件 |
| 数据 | 表结构/实体定义、字段类型、关系、迁移脚本 |
| 数据访问 | ORM/SQL/连接池、事务边界 |
| 认证 | 登录方式、令牌、权限模型 |
| 后台任务 | 定时任务、异步队列、消息订阅 |
| 外部依赖 | HTTP/RPC/缓存/MQ/对象存储等调用点 |
| 配置 | 端口、数据库、密钥、开关 |
| 日志 | 框架、格式、级别 |
| 验收 | 现有测试、可对照的行为清单 |

## 2. 阶段二：映射与缺口

产出两张表（写入转换报告，供用户确认）：

**映射表**：

| # | 原功能 | 原位置 | fountain 方案 | 状态 |
| --- | --- | --- | --- | --- |
| 1 | GET /users | app/handlers/user.py:12 | f_mvc Controller | 可映射 |
| 2 | 每日对账任务 | jobs/daily.py | f_ticktock | 可映射 |
| 3 | 消息推送 | mq/producer.py | — | 缺口 |

**映射参考**（按原技术栈初筛，落到模块前都要按 `module-index.md` 与模块 README 核对）：

| 原技术 | fountain 方案 | 备注 |
| --- | --- | --- |
| Flask / FastAPI / Express / Spring MVC / Echo / Gin | `f_mvc` | 路由、参数绑定、JSON 响应重新书写；服务端模板渲染大概率是缺口 |
| Spring Bean / DI 容器 | `f_bean`（`@Bean` + `lookup`） | 注入范围与生命周期语义不同，逐个核对 |
| SQLAlchemy / JPA / MyBatis / GORM | `f_orm` | SQL 方言与驱动不同（如 `postgres_driver`）；DDL 可复用但类型映射要逐列核对 |
| celery / APScheduler / crontab / node-cron | `f_ticktock` | CRON 表达式语义核对 |
| JWT 认证 | `f_jwt` + `f_security` | 密钥/算法/声明字段核对 |
| Redis 缓存 | `f_cache`（本地堆缓存） | **分布式缓存是缺口**：需用户提供第三方或降级为本地缓存 |
| requests / axios / okhttp | `f_httpclient` | — |
| 日志框架 | `f_log` | 输出配置走 `logger_*` 环境变量 |
| gRPC / Thrift / 自定义 RPC | `f_rpc` | 协议不兼容，接口要重新定义 |
| MQ（Kafka/RabbitMQ 等） | — | 缺口（问用户） |
| WebSocket | 核对 `f_mvc` README（仓库有 WS 相关示例） | 先核对再定状态 |
| 健康检查 | `f_health` | — |
| 自定义工具/加密/UUID 等 | `f_util` / `f_crypto` / stdx | 先查 `f_util` README 的公开 API 清单 |

**缺口表**（每个缺口一条）：缺口描述、影响的需求点、可选方案（简单替代 / 第三方依赖 / 不实现 /
在项目内自行实现完整功能和要求的基础设施代码、工具代码）、等待用户决定。用户选定前不要开工对应部分。

## 3. 阶段三：搭骨架

1. 工作流 A→B→C：装 fboot、`fboot workspace <新项目名>`、用 `fboot module` 按原项目分层建模块（不手工建目录、不直接 `cjpm init`）。
2. 工作流 D：按映射表加依赖（只加直接使用 + 确认已发布的模块）。
3. 生成三平台启动脚本（`boot.sh` / `boot-macos.sh` / `boot-win-gitbash.sh`；模板选用与合并规则见
   `references/launch-scripts.md`，含 RPC 的项目结合 frpcdemo 模板）。
4. 写一个最小 Controller（如 `GET /health` → `"ok"`），用 `./boot.sh build` + `./boot.sh run` 跑通链路，
   确认无误后再进入批量转换。

## 4. 阶段四：分批转换

推荐顺序（每批结束 `fboot build`）：

1. **数据模型**：实体/PO、枚举、常量 → `model/`（`@DataAssist`、`@ORMField` 等按需）。
2. **数据访问**：DAO/SQL/事务 → `dao/`（SQL 逐条核对方言；表结构 DDL 单独归档到文档）。
3. **业务逻辑**：service → `service/`。
4. **接口层**：路由 + 参数绑定 + 响应 → `controller/`。
5. **定时/异步任务**：`util/`（f_ticktock）。
6. **初始化与配置**：`boot` 模块（驱动注册等）+ 环境变量清单（对齐原项目配置项）。

纪律：

- 先冻结接口（包名、类名、方法签名），再并行转换多个文件；中途改签名会连累所有调用方。
- 类型映射逐个核对：可空、时间、decimal、大整数、JSON 字段、自增主键——仓颉类型系统与原语言不同，
  不要照着抄。
- 原项目的惯用法（反射、动态类型、装饰器魔法）不要直译，用仓颉的等价结构重写。

## 5. 阶段五：验收与转换报告

- 启动并逐条对照原项目行为（接口返回、错误码、边界值）。
- 原项目有测试的，按测试用例逐条复验（必要时写成仓颉单元测试）。
- 输出**转换报告**，包含：
  1. 项目画像（原技术栈、规模）；
  2. 映射表（含状态）；
  3. 缺口表（用户决定与处理结果）；
  4. 未实现项与原因；
  5. 运行说明（构建、环境变量、启动命令、`--dylibPattern`）；
  6. 后续建议（性能、测试补齐、部署差异）。

## 6. 常见陷阱

- 「自动转换」不存在：任何声称一步完成的做法都会产出编译不过的代码；以小批 + 编译验证推进。
- 语言差异：仓颉是静态类型 + 显式可见性（`public`/`protected`/`internal`）；顶层声明、可变捕获、match 等有专门规则
  （见 cangjie-coding 知识库）。
- 数据库：先用 mock 或本地实例打通最小链路，再批量迁移 SQL。
- 时区/编码/浮点精度等行为差异要专门列表核对，别默认与原来一致。
