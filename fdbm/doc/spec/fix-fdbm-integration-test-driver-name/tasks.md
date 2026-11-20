# Tasks

## 1. RED：确认失败由夹具缺配置引起

- [x] 1.1 在 WSL 以 `cjpm test --filter 'IntegrationTest.*' --no-color` 复现，确认 8 条用例均为
      `dbd_driverName is not configured`（errorCode 11），并把输出落到 `/tmp/fdbm_red.log` 留证。
      → 实测 `EXIT=1`、`PASSED: 0, SKIPPED: 246, ERROR: 8`，8 条堆栈均止于
      `IntegrationFixture.connect` → `dbdDriver()` → `configuredName()`。
- [x] 1.2 核对同一进程内 `DriverManager` 的既有注册名（`f_mockdb` 占 `mockdb`）与
      `Server_test.constructorRejectsDriverNameMismatch` 的隐含前提，确认测试专用名不与任何既有注册名冲突。
      → 进程内既有注册名只有 `mockdb`（`f_mockdb/src/Driver.cj:20-23`）与可选 `multidbd`；
      `constructorRejectsDriverNameMismatch` 走 `FdbmServer.cj:90-96` 的「传入驱动名 ≠ 节点配置名」分支，
      不依赖全局注册表，故 `testdialect` 无冲突。

## 2. GREEN：补测试进程的驱动注册名

- [x] 2.1 在 `fdbm/src/server/FdbmTestSetup_test.cj` 增加包级初始化
      `Config.set([('dbd_driverName', 'testdialect')])`，与既有 `protocol_hostId` 并列，注释写明原因与「不能取 `mockdb`」。
- [x] 2.2 重新执行 `cjpm test --filter 'IntegrationTest.*' --no-color`，8 条全部 PASSED（对比 1.1 的 RED）。
      → `EXIT=0`、`PASSED: 8, SKIPPED: 246, ERROR: 0`（`/tmp/fdbm_green.log`）。
- [x] 2.3 确认工作区 diff 只含该测试文件（无生产代码、无 API、无 cjpm.toml 变化）。
      → `git diff --stat`：`fdbm/src/server/FdbmTestSetup_test.cj | 9 +++++++++`，仅此一处。

## 3. 回归

- [x] 3.1 fdbm 全量 `cjpm test`：`TOTAL 254 / PASSED 254 / ERROR 0 / FAILED 0`。
      → `EXIT=0`（`/tmp/fdbm_full.log`）。
- [x] 3.2 `cjpm build`（fdbm）通过。
      → `EXIT=0`、`cjpm build success`（`/tmp/fdbm_build.log`；仅遗留既有的 `--lto` 重复与 unused 警告）。
- [x] 3.3 相邻模块 `f_dbd` 全量 `cjpm test` 仍全绿（确认 `dbd_driverName` 语义未被触碰）。
      → `EXIT=0`、`TOTAL 208 / PASSED 208 / ERROR 0`（`/tmp/fdbd_full.log`）。

## 4. 收口

- [x] 4.1 `openspec validate fix-fdbm-integration-test-driver-name --strict` 通过。
      → `Change ... is valid`（`skip_specs` 生效，零 delta 被接受）。
- [x] 4.2 四件套落盘 `fdbm/doc/spec/fix-fdbm-integration-test-driver-name/`（proposal / design / tasks；
      `skip_specs: true`，无 spec delta）。
- [x] 4.3 `opsx:verify` 三对齐（design 决定有落点、tasks 全勾选且逐条有验证证据、无 CRITICAL）。
