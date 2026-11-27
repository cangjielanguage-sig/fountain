# 任务：optimize-decode-alloc

- [x] J1.1 改前跑 `A64Emitter_test` / `X86Compile_test` / `X86Lower_test` / `Golden_test`（基线绿）。
- [x] J2.1 `A64Lower.translate` 签名改 `(op, code, opsAt, at, next)`，37 处下标改写；`lower` 去 `decode`。
- [x] J2.2 `X86Lower` 同构（36 处）；删除 `insns`/`offs` 缓存与 `DecodedInsn` 依赖。
- [x] J3.1 四个字节级护栏全绿；`CompileCopy_test` 绿。
- [x] J3.2 A/B：`codegen` 同进程中位数两臂（如实记录，无论有无收益）。
- [x] J3.3 全量零失败。
- [x] J4.1 `verify.md`；J4.2 镜像 + 校验；J4.3 归档 + §13；J4.4 删探针。
