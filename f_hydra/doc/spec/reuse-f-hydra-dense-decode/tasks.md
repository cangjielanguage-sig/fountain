# 任务：复用 f_hydra 稠密向量解码缓冲

## 1. Red：等价与边界用例

- [x] 1.1 新增 `f_hydra/src/VectorCodecReuse_test.cj`：`decodeDenseInto` 与 `decodeDense` 对合法输入逐元素一致（验证：编译失败即 Red）
- [x] 1.2 非法输入返回 `-1`：短于 4 B、count ≤ 0、声明长度越界、`out` 小于 count（验证：断言失败）
- [x] 1.3 同一缓冲连续解 4/8/4 维，结果正确（验证：断言失败）

## 2. Green：实现 `decodeDenseInto`

- [x] 2.1 `VectorCodec` 增加 `internal func decodeDenseInto(bytes, out): Int64`（验证：1.1–1.3 全绿）
- [x] 2.2 `decodeDense` 转调 `decodeDenseInto`，保持原返回值语义（验证：既有 `VectorCodec_test` 全绿）

## 3. Red→Green：调用方复用

- [x] 3.1 新增分配基准：768 维 × 256 候选 × 200 轮，记录旧/新路径分配（验证：旧路径分配 ≈ N × 6 KB）
- [x] 3.2 `bruteForceField` 改为每次查询一块缓冲 + `decodeDenseInto`（验证：基准下降 ≥ 8×，检索结果不变）
- [x] 3.3 `scoreIds` 同上（验证：IVF 路径结果不变）

## 4. 回归与落盘

- [x] 4.1 `f_hydra` 全量测试通过（验证：0 失败）
- [x] 4.2 镜像 proposal/design/tasks 到 `f_hydra/doc/spec/reuse-f-hydra-dense-decode/`
- [x] 4.3 提交并勾选任务
