# Design

## 1. 现象与调用链

`fountain::fdbm.server` 的 8 条 IntegrationTest 用例共用同一夹具入口
（`fdbm/src/server/Integration_test.cj:344`）：

```
IntegrationTest.xxx
  → IntegrationFixture.connect(database)        // Integration_test.cj:344-348
    → dbdDriver()                               // f_dbd/src/driver/DbdDriver.cj:137
      → configuredName()                        // DbdDriver.cj:122
        → Config.getString('dbd_driverName')    // 返回 None（测试进程未配置）
        → throw DbdException(CONFIG, 'dbd_driverName is not configured ...')
```

8 条用例在 `fixture.connect(...)` 这一行就抛出，尚未与 fdbm 服务发生任何交互，因此失败与 fdbm 服务端逻辑无关。

对照：

- `f_dbd` 自己的用例在调用前显式注入配置（`f_dbd/src/driver/DbdDriver_test.cj:35`：
  `Config.set([('dbd_driverName', 'postgres')])`），所以那边能过。
- fdbm 测试进程的进程级前置配置只有 `protocol_hostId`（`fdbm/src/server/FdbmTestSetup_test.cj:22`），
  没有任何地方写入 `dbd_driverName`（全模块 `grep dbd_driverName` 只命中 e2e 脚本与注释）。

结论：这是**测试夹具缺失前置配置**，不是 `fdbm` 服务端缺陷，也不是 `f_dbd` 缺陷。

## 2. 约束

用户明确要求：不改现有 API 语义、不新增 API、保持向后兼容。因此可选方案被限制在测试侧。

`dbdDriver()` / `DbdDriver` 现有语义是**规格的一部分**（`f_dbd/README.md`、`references/server-development.md`：
「应用侧必配 `dbd_driverName`；未配置时 `static init` 只记日志，`dbdDriver()` 取用时抛 `DbdException(CONFIG)`」）。
把它改成「未配置也能用」或加默认值、加新参数，都属于语义变更 / 新增 API，直接排除。

## 3. 方案对比

| 方案 | 做法 | 评价 |
| --- | --- | --- |
| A（选定） | 在 `FdbmTestSetup_test.cj` 包级初始化补 `dbd_driverName` | 与既有 `protocol_hostId` 同构，进程级前置条件集中一处；测试代码内聚，生产代码零改动 |
| B | 在 `IntegrationFixture.connect()` 内每次 `Config.set` | 影响面更小，但把进程级前置条件藏在每次建连里，重复写全局状态，语义不清晰 |
| C | 夹具改用 `DbdDriver('testdialect')` 直接构造 | 绕开公开入口 `dbdDriver()`；虽能过，但用例不再覆盖文档推荐的接入路径，属降级验证 |
| D | 放宽 `dbdDriver()`（默认名 / 空名兜底） | 变更既有语义与公开行为，违反本次约束，否决 |

方案 A 只影响 `fountain::fdbm.server` 这一个测试二进制（同一包内 HandlerTest / Server_test / ServerLifecycleTest /
GracefulShutdownTest 也在这个进程里，均不读取该配置，见第 5 节影响分析）。

## 4. 驱动名取值

`dbd_driverName` 的语义是**后端方言名**，即 f_orm 选方言用的标签。本集成夹具的后端是 `f_mockdb`，看似应取 `mockdb`，
但**不能**：

- `f_mockdb` 在包初始化时已把 `MockDriver` 注册为 `mockdb`（`f_mockdb/src/Driver.cj:20-23`）；
- fdbm 服务端构造时按节点配置 `fdbm_db_driver_name0 = mockdb` 去 `DriverManager.getDriver('mockdb')` 取物理驱动
  （`fdbm/src/server/DatabaseResources.cj:69-73`、`Integration_test.cj:295`）；
- 客户端若以 `mockdb` 注册 `DbdDriver`，要么 `DriverManager` 里同名条目被覆盖、服务端拿到 `DbdDriver` 导致链路错乱，
  要么 `dbdDriver()` 命中 `MockDriver` 并抛「the driver registered as mockdb is not a DbdDriver」
  （`DbdDriver.cj:142-146`）。

取 `postgres` / `mysql` 也不合适：这类真实方言名在测试进程里被注册后，会与「某方言驱动缺失应报 `NO_DRIVER`」
一类负向用例的隐含前提纠缠（例如 `Server_test.cj:371-378` 用 `driverName: 'postgres'` 构造不匹配场景）。

因此取一个测试专用、不会与任何物理驱动重名的标签 `testdialect`（早期审查建议里也用这个名字）。它只作
`DriverManager` 的键与 `Driver.name`，本链路不使用 f_orm，不参与方言分派。

## 5. 实施落点

在 `fdbm/src/server/FdbmTestSetup_test.cj` 增加一条包级初始化，与 `protocol_hostId` 并列：

```cangjie
/** 集成夹具以 f_dbd 客户端身份连 fdbm：dbdDriver() 需要驱动注册名。
    不能取 mockdb（同进程里 f_mockdb 已注册该名字）。 */
let testDbdDriverNameSetup: Unit = Config.set([('dbd_driverName', 'testdialect')])
```

初始化顺序无风险：`DbdDriver.static init` 若早于该赋值执行，本次不注册驱动，之后 `dbdDriver()` 会走
「配置晚于包初始化写入」的按需注册分支（`DbdDriver.cj:146-151`）；若晚于赋值执行，则注册名就是 `testdialect`。
两条路径结果一致。

## 6. 影响面

- **生产代码**：无改动。
- **公开 API / 配置语义**：无改动；`dbd_driverName` 的必配语义、未配置抛 `CONFIG` 的行为原样保留。
- **同进程其他测试**：
  - `HandlerTest` / `GracefulShutdownTest`：不读该配置、不查 `DriverManager` 的同名条目，不受影响；
  - `Server_test.constructorRejectsDriverNameMismatch`：走 `FdbmServer` 的「传入驱动名 ≠ 节点配置名」分支
    （`FdbmServer.cj:90-96`），与 `DriverManager` 里是否有 `testdialect` 无关；
  - `ServerLifecycleTest`：驱动加载用例针对自建的驱动目录，不枚举全局注册表。
- **构建产物**：`_test.cj` 只进测试二进制，模块既有 `cjpm build` 产物不变。

## 7. 验收

1. RED（已取证）：`cjpm test --filter 'IntegrationTest.*' --no-color` → `ERROR: 8`，报错文本为 `dbd_driverName is not configured`。
2. 修复后同一命令：8 条全部 PASSED。
3. fdbm 全量 `cjpm test`：`TOTAL 254 / PASSED 254 / ERROR 0 / FAILED 0`。
4. 相邻模块回归：`f_dbd` 全量 `cjpm test` 仍全绿（本次未改其代码，用于确认语义未被触碰）。
5. `cjpm build`（fdbm）通过。
