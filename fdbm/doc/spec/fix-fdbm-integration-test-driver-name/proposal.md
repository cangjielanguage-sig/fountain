# Proposal

## Why

fdbm 模块在干净环境执行 `cjpm test` 时，`fountain::fdbm.server` 包的 8 条 IntegrationTest 用例全部 ERROR，统一抛出：

```
SqlException: dbd_driverName is not configured. f_dbd is a proxy driver and cannot know the
physical database dialect; set dbd_driverName=<backend dialect> ... , errorCode: 11
```

这 8 条是 fdbm 服务端唯一的端到端回归覆盖（建表 / 插入 / 查询 / 更新 / 删除 / 事务 / 游标关闭 / show / export），
现状等于这条链路没有回归保护，任何一次改动都只能在人工 e2e 里发现问题。

根因不在 fdbm 服务端：集成夹具以 f_dbd 客户端身份连自己启动的 fdbm 服务，走的是公开入口 `dbdDriver()`；
该入口按既有契约要求全局配置 `dbd_driverName`（后端方言名），未配置时抛 `DbdException(CONFIG)`，这是**正确的既有语义**。
`f_dbd` 自己的用例在调用前显式 `Config.set([('dbd_driverName', ...)])`，而 fdbm 的测试进程只配置了
`protocol_hostId`（`FdbmTestSetup_test.cj`），漏掉了客户端驱动的注册名。

## What Changes

- 在 fdbm 测试进程的包级初始化里补一条 `dbd_driverName` 配置（测试专用方言名 `testdialect`），与既有
  `protocol_hostId` 并列，注释说明「集成夹具以 f_dbd 客户端身份连 fdbm，需要驱动注册名」与「不能取 `mockdb`」的原因。
- 不改任何生产代码；`dbdDriver()` / `DbdDriver` 的语义（未配置即抛 `CONFIG`）、配置项含义、公开 API 一律不动。
- 不改 8 条用例的断言与夹具行为，它们恢复为直接验证原有链路。

## Capabilities

### New Capabilities

无。本变更只补测试夹具的进程级前置配置，系统行为与规格语义不变，变更元数据置 `skip_specs: true`。

### Modified Capabilities

无。

## Impact

- 代码：`fdbm/src/server/FdbmTestSetup_test.cj`（测试代码，编译进 `fountain::fdbm.server` 测试二进制）。
- API / 依赖 / 运行时行为：无变化。`f_dbd` 与 `fdbm` 的公开契约、配置项语义、既有调用方均不受影响。
- 测试：fdbm `cjpm test` 从 `TOTAL 254 / PASSED 246 / ERROR 8` 恢复为 `254 / 254 / 0`；`f_dbd` 作为共享
  `dbd_driverName` 语义的相邻模块做一次回归确认。
