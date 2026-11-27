# 任务：optimize-helper-table

## H1 基线（已完成）

- [x] H1.1 探针：4 vs 204 个注册函数，每次调用 11.7/11.9 µs vs 103/197 µs。
- [x] H1.2 归因：`UserHelperTable.push` 每调用新建 `HashMap` 并逐项插入 F 次。

## H2 护栏

- [x] H2.1 `src/HelperTableScope_test.cj` 3 条（嵌套遮蔽/pop 恢复、调用后无残余、hid 顺序）。
- [x] H2.2 在**未改动**实现上跑：3/3 绿。

## H3 实现

- [x] H3.1 `UserHelperTable.buildTable` 抽出；`pushTable` 只压引用；`push` 变兼容入口。
- [x] H3.2 `JitFunction.helperTableCache` 在 `bindUserHelpers` 构建；`helperTableRef()` 取缓存。
- [x] H3.3 `callLocked` 改用 `helperTable`（包装实例取 owner 的表）。

## H4 验证

- [x] H4.1 护栏 3/3 绿（改后）。
- [x] H4.2 A/B：204 vs 4 的差值从 +91/+185 µs 降到 ≈0（−96%）。
- [x] H4.3 全量 1246/1246。

## H5 收口

- [x] H5.1 `verify.md`。
- [x] H5.2 镜像 + `openspec validate --strict`。
- [x] H5.3 归档；`doc/optimize-call-path.md` 补 §17。
- [x] H5.4 删除临时探针。
