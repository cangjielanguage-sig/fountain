# 复用 f_hydra 稠密向量解码缓冲

## 为什么

`FStoreVectorStore` 的暴力检索与 IVF 打分对每个候选调用一次 `VectorCodec.decodeDense(bytes)`：

- 每次新建 `Array<Float64>(count)`，768 维即 6,144 B；
- 一次查询扫描 N 个候选就是 N 次分配、N × dim × 8 字节；
- 微基准（同一进程、`-O0`/`-O2`、全量填充 + 读取）显示：复用一块比每次新建快 1.3～2.4 倍，且分配从 N 次降到 1 次。

`decodeDense` 的返回值只在 `cosine` 中读取一次随即丢弃，是典型的「循环内临时区」——按实测结论应复用，不应 local（local 会在函数返回前累积，N × 6 KB 可撑爆 256 MB 上限）。

## 变更什么

- 在 `VectorCodec` 增加包内 `decodeDenseInto(bytes, out): Int64`：把解码结果写入调用方提供的缓冲，返回解码维数；输入非法或缓冲不足返回 `-1`。
- `bruteForceField` 与 `scoreIds` 每次查询分配**一块** `Array<Float64>(query.dense.size)`，候选循环内复用。
- 公开 `VectorCodec.decodeDense`、`FStoreVectorStore` 全部公开方法保持不变。

## 影响

- 生产代码：`f_hydra/src/VectorCodec.cj`、`f_hydra/src/FStoreVectorStore.cj`。
- 行为：向量维度不匹配、坏数据、空结果的判定与现状一致；检索结果、排序、过滤不变。
- 契约：无 `public` 签名变化；`decodeDenseInto` 为包内可见。

## 验收

- 等价用例：合法输入、短字节、count 与缓冲不匹配、缓冲过大/过小、连续不同长度复用。
- 分配基准：N 次解码的总堆分配，从 `N × dim × 8` 降到 `dim × 8` 量级（env gated）。
- `f_hydra` 全量测试通过。

## 明确不做

- 不改 IVF 构建、不改 `f_store` 的读取路径。
- 不改 `decodeColbert`（调用频次与形态不同，另议）。
- 不引入 local mode。
