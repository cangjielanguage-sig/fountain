# 任务：optimize-call-alloc2

- [x] K1.1 改前 `CallPathBench` 基线（L1、Q1）。
- [x] K2.1 `CallMarshal.unboxRet` 抽出；`makeRetUnboxer` 委托。
- [x] K2.2 `JitFunction` 用 `unboxRet`；零实参共享空 arrays。
- [x] K3.1 相关护栏（`CallMarshal_test`、`MarshalRs_test`、`CallPathBench`）全绿。
- [x] K3.2 A/B：L1 两臂（同进程 5 万 × 3 轮取最小）。
- [x] K3.3 全量零失败。
- [x] K4.1 `verify.md`；K4.2 镜像 + 校验；K4.3 归档 + §18；K4.4 删探针。
