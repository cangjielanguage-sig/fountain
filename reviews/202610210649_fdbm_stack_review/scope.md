# 审查范围：f_dbd / f_dbm / fdbm 全量文档与代码

- **基线提交**：`7ca82fcc`（`sts/1.3.x` = `feature/dbware`）
- **审查方式**：全量源码/文档审查（非 diff；该提交已是 sts 合并结果）
- **审查工作树**：`.worktrees/review_fdbm_stack_202610210649`（detached HEAD，只读）
- **审查目标**：
  1. 对照各自 README / 详细设计 / 开发计划 / 主规范，确认功能是否完备；
  2. 确认测试用例是否覆盖全部公开行为、错误路径与文档承诺；
  3. 找出空函数、空实现、占位实现、空测试、无断言测试、被跳过/禁用的测试。
- **跨模块参照**：`openspec/specs/fdbm/spec.md`、`openspec/specs/f-dbd/spec.md`（若存在）

## 审查维度

| 维度 | 检查点 |
| --- | --- |
| 功能完备性 | 公开 API/配置/错误码/协议行为是否都有实现；文档承诺与代码是否一致；未实现分支是否有明确错误码 |
| 空实现 | 函数/方法/属性 getter 空体、`()`、仅 `return`/`return 0`/`return null`、`throw Unimplemented`、TODO/FIXME、空 `catch`、空接口实现 |
| 测试充分性 | 每个模块是否有测试；每个公开函数/错误分支是否有对应用例；是否存在无 `@Assert` 的 `@TestCase`、空测试类、仅编译测试、禁用/跳过测试 |
| 正确性 | 边界、异常路径、资源释放、并发/事务、错误码映射 |
| 文档一致性 | README/设计/开发计划的签名、默认值、错误码、示例与代码一致 |
| 可维护性 | 命名、重复、死代码、注释与实现不符 |

## 文件清单（tracked）

### f_dbd（52 个文件）

- `f_dbd/README.md`
- `f_dbd/README_en.md`
- `f_dbd/cjpm.toml`
- `f_dbd/doc/spec/implement-f-dbd-driver-and-fdbm-server/design.md`
- `f_dbd/doc/spec/implement-f-dbd-driver-and-fdbm-server/proposal.md`
- `f_dbd/doc/spec/implement-f-dbd-driver-and-fdbm-server/specs/f-dbd/spec.md`
- `f_dbd/doc/spec/implement-f-dbd-driver-and-fdbm-server/specs/f-protocol/spec.md`
- `f_dbd/doc/spec/implement-f-dbd-driver-and-fdbm-server/tasks.md`
- `f_dbd/src/common/DbdException.cj`
- `f_dbd/src/common/DbdException_test.cj`
- `f_dbd/src/common/column.cj`
- `f_dbd/src/common/column_test.cj`
- `f_dbd/src/common/dispatch_perf_test.cj`
- `f_dbd/src/common/error.cj`
- `f_dbd/src/common/error_test.cj`
- `f_dbd/src/common/payload.cj`
- `f_dbd/src/common/payload_test.cj`
- `f_dbd/src/common/placeholder.cj`
- `f_dbd/src/common/result.cj`
- `f_dbd/src/common/result_test.cj`
- `f_dbd/src/common/sqltypes_test.cj`
- `f_dbd/src/common/types.cj`
- `f_dbd/src/common/types_test.cj`
- `f_dbd/src/dbd.cj`
- `f_dbd/src/dbd_test.cj`
- `f_dbd/src/driver/DbdConnection.cj`
- `f_dbd/src/driver/DbdConnection_test.cj`
- `f_dbd/src/driver/DbdDatasource.cj`
- `f_dbd/src/driver/DbdDriver.cj`
- `f_dbd/src/driver/DbdDriver_test.cj`
- `f_dbd/src/driver/DbdOptions.cj`
- `f_dbd/src/driver/DbdStatement.cj`
- `f_dbd/src/driver/DbdStatement_test.cj`
- `f_dbd/src/driver/DbdTransaction.cj`
- `f_dbd/src/driver/DbdTransaction_test.cj`
- `f_dbd/src/driver/DbdTransport.cj`
- `f_dbd/src/driver/DbdTransport_test.cj`
- `f_dbd/src/driver/DbdUrl.cj`
- `f_dbd/src/driver/DbdUrl_test.cj`
- `f_dbd/src/driver/placeholder.cj`
- `f_dbd/src/driver/stub_fdbm_test.cj`
- `f_dbd/src/driver/testkit_test.cj`
- `f_dbd/src/exception/DbdException.cj`
- `f_dbd/src/exception/Reexport_test.cj`
- `f_dbd/src/multid/Config.cj`
- `f_dbd/src/multid/Datasource.cj`
- `f_dbd/src/multid/MultiD.cj`
- `f_dbd/src/multid/MultiD_test.cj`
- `f_dbd/src/multid/MultiDatasource_test.cj`
- `f_dbd/src/multid/Url.cj`
- `f_dbd/src/multid/placeholder.cj`
- `f_dbd/src/multid/stub_test.cj`

### f_dbm（5 个文件）

- `f_dbm/README.md`
- `f_dbm/README_en.md`
- `f_dbm/cjpm.toml`
- `f_dbm/src/IdGenerator.cj`
- `f_dbm/src/PartitionAlgorithm.cj`

### fdbm（73 个文件）

- `fdbm/README.md`
- `fdbm/README_en.md`
- `fdbm/boot.sh`
- `fdbm/cjpm.toml`
- `fdbm/doc/spec/implement-f-dbd-driver-and-fdbm-server/specs/fdbm/spec.md`
- `fdbm/src/config/BootScriptWriter.cj`
- `fdbm/src/config/BootScriptWriter_test.cj`
- `fdbm/src/config/FdbmConfig.cj`
- `fdbm/src/config/FdbmConfig_test.cj`
- `fdbm/src/config/models.cj`
- `fdbm/src/config/settings.cj`
- `fdbm/src/config/source.cj`
- `fdbm/src/exception/FdbmException.cj`
- `fdbm/src/exception/FdbmException_test.cj`
- `fdbm/src/execute/Dispatcher_test.cj`
- `fdbm/src/execute/ExecutorFeature_test.cj`
- `fdbm/src/execute/cursor.cj`
- `fdbm/src/execute/dispatcher.cj`
- `fdbm/src/execute/executors.cj`
- `fdbm/src/execute/placeholder.cj`
- `fdbm/src/execute/session.cj`
- `fdbm/src/idmaker/IdMakers.cj`
- `fdbm/src/idmaker/IdMakers_test.cj`
- `fdbm/src/idmaker/placeholder.cj`
- `fdbm/src/main.cj`
- `fdbm/src/main_test.cj`
- `fdbm/src/resources/DatabaseResources.cj`
- `fdbm/src/resources/DatabaseResources_test.cj`
- `fdbm/src/resources/placeholder.cj`
- `fdbm/src/route/Route_test.cj`
- `fdbm/src/route/algorithms.cj`
- `fdbm/src/route/cache.cj`
- `fdbm/src/route/global.cj`
- `fdbm/src/route/placeholder.cj`
- `fdbm/src/route/router.cj`
- `fdbm/src/server/CustomLoader.cj`
- `fdbm/src/server/DriverLoader.cj`
- `fdbm/src/server/FdbmServer.cj`
- `fdbm/src/server/Handler_test.cj`
- `fdbm/src/server/InFlight.cj`
- `fdbm/src/server/Integration_test.cj`
- `fdbm/src/server/Server_test.cj`
- `fdbm/src/server/SessionRegistry.cj`
- `fdbm/src/server/context.cj`
- `fdbm/src/server/handler.cj`
- `fdbm/src/sql/Dialect.cj`
- `fdbm/src/sql/ParameterBinder.cj`
- `fdbm/src/sql/PartitionKeyExtractor.cj`
- `fdbm/src/sql/SqlFeature_test.cj`
- `fdbm/src/sql/SqlParser.cj`
- `fdbm/src/sql/SqlParser_test.cj`
- `fdbm/src/sql/SqlRenderer.cj`
- `fdbm/src/sql/SqlSupport_test.cj`
- `fdbm/src/sql/ast.cj`
- `fdbm/src/sql/placeholder.cj`
- `fdbm/src/sql/token.cj`
- `fdbm/test/e2e/README.md`
- `fdbm/test/e2e/backends/mysql.sh`
- `fdbm/test/e2e/backends/postgres.sh`
- `fdbm/test/e2e/client/cjpm.toml`
- `fdbm/test/e2e/client/src/main.cj`
- `fdbm/test/e2e/driver_bundle_mysql/cjpm.toml`
- `fdbm/test/e2e/driver_bundle_mysql/src/main.cj`
- `fdbm/test/e2e/driver_bundle_postgres/cjpm.toml`
- `fdbm/test/e2e/driver_bundle_postgres/src/main.cj`
- `fdbm/test/e2e/lib.sh`
- `fdbm/test/e2e/orm_client/cjpm.toml`
- `fdbm/test/e2e/orm_client/src/main.cj`
- `fdbm/test/e2e/run.sh`
- `fdbm/test/lifecycle_test.sh`
- `fdbm/test/mysql_e2e/run.sh`
- `fdbm/test/postgres_e2e/README.md`
- `fdbm/test/postgres_e2e/run.sh`

## 报告要求

- 按 `reviewer.md` 的格式输出到指定的 `review_v{N}.md`；
- 问题必须给出文件与行号；空函数/空测试要给出判定依据（代码片段或结构）；
- 「功能完备性」与「测试覆盖」需给出覆盖矩阵或缺口列表，不能只给结论；
- 不修改源码，不引入与范围无关的风格偏好。
