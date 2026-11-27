# 任务：optimize-compile-hotpath

## G1 基线（已完成）

- [x] G1.1 `A64Lower`：`translate` 1.41–1.65 ms、`bind+decode` 0.67–0.72 ms（n=250）。
- [x] G1.2 `validateFunc`：`decode` 0.21–0.23 ms。
- [x] G1.3 `FbcReader.load`：crc 0.15–0.53、dir+types 0.24、site+name 0.30、slices 0.17 ms。

## G2 护栏

- [x] G2.1 新增 `src/backend/A64EmitterSize_test.cj`：`size()` 为字节、`finish()` 字节与小端逐位正确。
- [x] G2.2 在**未改动**实现上跑一遍：必须全绿。

## G3 实现

- [x] G3.1 `A64Emitter.out` 改 `ArrayList<UInt32>`；`word/readWord/patchWord/size/bytes` 同步。
- [x] G3.2 `Assembler.validateFunc` 免 `decode`；`effectArgc`/`loadedSlotOf` 改签名。
- [x] G3.3 `FbcReader.checkCrc32` 预分配数组。

## G4 验证

- [x] G4.1 护栏 + `A64Emitter_test` + `A64EmitterFixup_test` + `Golden_test` 全绿。
- [x] G4.2 A/B：端到端同探针两臂（`git stash` 切换）。
- [x] G4.3 全量 `cjpm test --parallel 1` 零失败。
- [x] G4.4 变异：`size()` 返回 `words`（少乘 4）⇒ 护栏必须红；恢复。

## G5 收口

- [x] G5.1 `verify.md` 记录数据。
- [x] G5.2 镜像 `f_jit/doc/spec/optimize-compile-hotpath/` 并 `openspec validate --strict`。
- [x] G5.3 归档；`doc/optimize-compile-path.md` 补 §11。
- [x] G5.4 删除临时探针。
