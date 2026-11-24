# 设计：复用 f_hydra 稠密向量解码缓冲

## D1 `decodeDenseInto` 契约

```cangjie
internal func decodeDenseInto(bytes: Array<Byte>, out: Array<Float64>): Int64
```

- 布局与 `decodeDense` 完全一致：`count(Int32 LE) + count × Float32 LE`；
- 成功：写 `out[0..count]`，返回 `count`；
- 失败（返回 `-1`）：`bytes.size < 4`、`count <= 0`、`bytes.size < 4 + count * 4`、`out.size < count`；
- 不修改 `out[count..]`，调用方只按返回值读取有效前缀。

`decodeDense` 保留原实现（其他调用方与测试仍在用），内部改为调用 `decodeDenseInto` 以避免两套解析逻辑漂移。

## D2 调用方复用

```cangjie
let denseBuf = Array<Float64>(query.dense.size, repeat: 0.0)
...
let count = VectorCodec.decodeDenseInto(bytes, denseBuf)
if (count != query.dense.size) {
    continue
}
hits.add(VectorHit(id, payload, VectorMath.cosine(query.dense, denseBuf)))
```

- `bruteForceField` 与 `scoreIds` 各自在进入候选循环前分配一次；
- 语义等价：旧代码 `decodeDense` 返回空数组或长度不符都走 `continue`，新代码 `-1` 或 `count` 不等同样 `continue`；
- 缓冲大小固定为查询向量维度，不存在跨维度污染。

## D3 测试

1. **等价**：同一字节分别经 `decodeDense` 与 `decodeDenseInto` 解码，逐元素相等；
2. **非法输入**：短于 4 B、count ≤ 0、声明长度超出实际、`out` 小于 count，均返回 `-1` 且不越界写；
3. **复用**：同一缓冲先解 4 维再解 8 维再解 4 维，结果只受当前 `count` 影响；
4. **检索回归**：既有 `FStoreVectorStore_test` 全量覆盖暴力检索与 IVF 打分路径。

## D4 分配基准

- `F_HYDRA_BENCH=1` 时对 768 维、固定 256 个候选重复解码 200 次；
- 记录旧路径（每次 `decodeDense`）与新路径（一次分配 + `decodeDenseInto`）的 `allocPerQuery`；
- 断言新路径 ≤ 旧路径的 1/8；GC 噪声大时改为只记录（与既有基准口径一致）。

## 风险

| 风险 | 处理 |
| --- | --- |
| 缓冲复用导致跨候选数据残留 | 只读 `[0, count)`；count 必须等于查询维度 |
| 两套解析逻辑漂移 | `decodeDense` 转调 `decodeDenseInto` |
| 并发查询共享缓冲 | 缓冲是每次查询的局部变量，不共享 |

## 实测记录（2026-11-22，`-O0`）

- 768 维 × 2000 次解码：旧路径 135,931,680 B，复用路径 123,008,576 B；
- 差值 12,923,104 B ≈ 2000 × 6,461 B，正好是每次省掉的那块 768 × 8 数组；
- 其余分配来自 `-O0` 下逐元素读写，与本次改动无关。
