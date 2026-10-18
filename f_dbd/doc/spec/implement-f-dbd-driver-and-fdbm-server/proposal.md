# Change: 实现 f_dbd 驱动与 fdbm 服务端

## Why

1. **两份文档现在互斥**：`fdbm/doc/详细设计.md`（§9.1 构造即预取第一行、`ExecutionOutcome.hasData`；§10.2 `CLOSE_CURSOR` → `DataNone`）与 `fdbm/doc/开发计划.md`（Step 7.1 预取与 `hasData` 跨段、Step 8.1 `CLOSE_CURSOR` 与首行预取契约）停留在旧协议；`f_dbd/doc/详细设计.md` 已于 2026-10-17 拍板改为**无预读 + `UNSUBSCRIBE`/`ACK` + 当前行缓冲**（§3.5、§3.6、§3.6.1、§3.10、§7.1–§7.3）。照任何一份旧描述写，都会产出与另一端不兼容的实现。
2. **`f_protocol` 缺一个构造器重载**：只有 `unsubscribe(id)` 与 `unsubscribe(id, data!)`，没有 `unsubscribe<T>(data!: T)`。`f_dbd` 关闭游标需要"自动生成新 `MessageID` 并携带 `QueryResultClosePayload`"的消息（`f_dbd/doc/详细设计.md` §3.6.1、§5.9）。
3. **`get<T>` 的类型分派未定**：`QueryResultImpl.get<T>` 是最热路径，候选 A（`TypeInfo` + `isSubtypeOf`）与候选 B（`None<T>` + `match case _: ?X`）性能与语义不同。设计已把它列为**开发阻塞项**（§10.1）：实验出结论前不写分派代码。
4. **两个模块目前只有 `doc/` 与 `cjpm.toml`**，没有任何源码，中间件链路（应用 → f_dbd → fdbm → 物理库）尚不存在。

## What Changes

- **文档对齐（先行，阻塞实现）**：把 `fdbm/doc/详细设计.md`、`fdbm/doc/开发计划.md` 与 `f_dbd/doc/开发计划.md` 中过时的 `hasData` / `CLOSE_CURSOR` / 首行预取描述，改写为与 `f_dbd/doc/详细设计.md` 一致的口径：查询首包只带列信息、**首次 `next()` 也发 `NEXT_ROW`**、关闭走 `UNSUBSCRIBE(qid)` → `ACK`、服务端维护**当前行缓冲**。
- **新增 `Message.unsubscribe<T>(data!: T)`**：与既有 `subscribe<T>(data!: T)` 同构，自动生成 `MessageID`；既有两个 `unsubscribe` 重载语义不变。
- **新建 `f_dbd` 源码**：`common`（payload / `SqlTypes` / `QueryResultImpl` / `DbdInputStream`）、`exception`、`driver`（URL / Datasource / Connection / Statement / Transaction / Transport）、`multid`（`MultiD` 多节点负载均衡）——完整实现 `std.database.sql` 的驱动体系，注册名 `fdbm` 与 `multidbd`。
- **新建 `fdbm` 源码**：`config` / `exception` / `resources` / `route` / `idmaker` / `custom` / `sql` / `execute` / `server` —— executable 形态的数据库中间件（监听 8112，物理驱动从 `driver/` 唯一加载）。
- **`get<T>` 性能前置实验**：在写 `QueryResultImpl.get<T>` 分派之前完成微基准，结论回写详细设计后再实现。
- **全程 TDD**：每个公共成员先写失败用例（红）→ 最小实现（绿）→ 重构；每 Step `cjpm test` 全绿才进入下一步。

## Impact

- **新增代码**：`f_dbd/src/**`、`fdbm/src/**`（两模块现状只有 `cjpm.toml` 与 `doc/`）。
- **修改代码**：`f_protocol/src/default/Message.cj` 新增一个静态构造器重载 + 单测（`register` / `subscribe` 等既有构造器不受影响）。
- **修改文档**：`fdbm/doc/详细设计.md`、`fdbm/doc/开发计划.md`、`f_dbd/doc/开发计划.md`；`f_dbd/doc/详细设计.md` 在性能实验结束后回写 §3.10 与 §10.1 的结论。
- **模块依赖**：`fdbm` → `fountain::f_dbd.common` / `fountain::f_dbd.exception` / `fountain::f_dbm`；依赖方向不变，`f_dbd` 不反向依赖 `fdbm`。
- **兼容性**：协议无独立版本号，两模块同仓库同版本发布；本次无已上线实现，不存在破坏性变更。
- **交付形态**：`fdbm` 为可执行文件（`cjpm install` 后命令行直接执行 `fdbm`，无子命令）；`f_dbd` 为动态库，由应用的动态库扫描加载。
- **发布登记**：`f_dbd` / `f_dbm` / `fdbm` 是否加入 `.modules` 的 `[include]` 待用户确认；本期不默认修改，只补齐三个模块的中英 README。

## Out of Scope

- 不改变已拍板的协议语义（命令、载荷、错误码）；实现严格按 `f_dbd/doc/详细设计.md`，协议本体不再新增/删减。
- 不实现"同连接多游标"调度（`qid` 只用于校验与日志，见 `f_dbd` §7.3）。
- 不做 SQL 方言转换、不支持聚合函数/子查询/存储过程。
- 不实现跨版本协议兼容与灰度。
