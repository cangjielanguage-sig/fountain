# fountain 项目基线

审查 fountain 仓库（`f_*` 模块、`fboot`、`fdemo`、`fdbm`、`fmq` 等）时，除通用维度外按本文件核对。每条都是**可判定的约定**，不是风格偏好。

## 1. 工程形态

- 应用**没有 `main`**：每个模块编译成动态库，由 `fboot` 加载启动。审查"入口"时看 `@Controller` 路由、`@Bean` 初始化、定时任务注册，不要找 `main`。
- 每个模块有独立 `cjpm.toml`；`f_*` 模块的 `version` 与当前 fountain 版本对齐，模块间依赖写成同版（版本漂移会拉错制品）。
- 编译 / 测试在 WSL Ubuntu 里跑（先 `source cangjie.sh`），Windows 侧只读代码。报告里的"已验证"必须写清在哪个环境跑的。

## 2. 分层与数据访问

| 规则 | 判据 |
| --- | --- |
| 读库必须经 Service 层 | 业务类里出现 `ORM.executor()` 或直接依赖 DAO 接口 = 违规 |
| DAO 独立成包 | `@DAO public interface XxxDAO <: RootDAO`，方法体只用 `RootDAO` 的 `executor` 属性 |
| Service 声明在接口里 | `public interface XxxService <: RootService` 声明读写方法，`@Bean` 类实现，调用方 `lookup<XxxService>()` 取实例 |
| 不跨语句复用 `SqlExecutor` | 单条语句执行后线程内 current executor 会被清空，每次操作重新 `executor()` |
| 参数化，不拼串 | SQL 用 `arg(...)` / `IN` 参数，不把外部输入插值进 SQL |
| 类型名 | 用 `f_orm` 的 `Sql*` 抽象名或仓颉类型名，代码里不出现数据库方言名（`bytea` / `int4` / `numeric` / `bool` 之类）；驱动上报的就是仓颉类型名 |

## 3. 文件头

每个 `.cj` 文件必须有 Apache 2.0 版权注释，**位于 `package` 之前**：

```cangjie
/*
Copyright (c) 2025 WuJingrun（吴京润）
... Apache License, Version 2.0 全文 ...
*/
package fountain::f_util
```

缺头、头在 `package` 之后、年份与新建年不符，都按"一般"报。

## 4. 多实现与注册冲突

| 场景 | 约定 | 违规形态 |
| --- | --- | --- |
| 启动时选一个实现 | 条件化 `@Bean` + `lookupOption`，配置先于 bean 初始化 | 在调用点写 `if (配置 == "A") {...} else {...}` |
| 运行时按参数选 | 中介者：标识 → 实现映射，调用方只依赖中介者 | 业务代码里散落 `match (kind)` 分支 |
| 同名注册（扩展 / 路由 / 插件） | **启动直接失败**，不做隐式优先级 | 后者静默覆盖前者，或"先注册先赢" |

## 5. 配置与生命周期

- 配置走 `f_config` 读取；不要散落的 `std.env` / 手写文件解析。
- 启动后不假设配置可热更新：配置只在启动读一次，换实现或端点要重启。审查时看到"监听配置变化 / 运行期重载"的代码，先确认这是需求还是误解。
- 定时任务用 `f_ticktock`。`Timer.after(delay, task)` 的 `task` 返回值就是**下次调度延迟**：返回 `Some(v)` 会自动重排，返回 `None` 才失效。**不要**把"回调里只返回一个 `Duration`"误报成"一次性定时器"。
- 审查中发现"疑似只触发一次 / 只执行一轮"时，先查对应 API 的返回值语义，再下结论。

## 6. 日志与可观测

- 日志走 `f_log`，热点路径不 `println`；循环里逐条打印按 `perf §9.1` 处理。
- 日志中不得出现凭据、令牌、完整报文等敏感字段。
- 不要只看日志判断执行顺序：`println` 重定向到文件时带缓冲，事件文件逐行 append + flush 更可靠。

## 7. 不要凭记忆断言能力

审查"项目没有 X"或"应该这样调 Y"之前，先查：

- 模块选型与较新能力（MQ、数据库中间件、表达式 JIT 等）：`fountain-api-lookup` 技能 / `scripts/fountain_lookup.py search|api`。
- 语言与标准库语义：`cangjie-doc-lookup`（本地官方文档），不凭记忆写签名、默认值、返回值语义。

## 8. 性能结论的取证要求

- 基准必须 `-O2`；`cjpm test` 默认 `-O0`，同代码可能差一个数量级。
- 报告"变快 / 变慢"要附绝对值、单位、中位数、离散程度与构建配置；一次最快值不算。
- 无法在目标平台复测时，把结论限定为"当前已测平台"，并把需要实测的项降级为轻微。
