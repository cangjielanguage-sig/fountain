# 验证：optimize-jitcontext-pool（实验后 **revert**）

## 1. 结论

**不 adopt。** 三个版本测下来，ctx 的 `malloc/free` 并不慢，池化带来的 C1 下降无法传导到
端到端；两个池化版本都让 L1 变慢。代码已全部回退，仓库无改动。

## 2. 三组数据（同一构建机，单轮 B1/B4）

| 版本 | C1（create+free） | L1（短调用） | Q1 | Q4 |
| --- | --- | --- | --- | --- |
| A 无池（基线，`2952` 那一轮） | 405 ns | 2952 ns | 338.7k/s | 776.9k/s |
| B `ThreadLocal` 池 | **855 ns**（+111%） | 3407 ns（+15%） | 293.5k/s | 713.0k/s |
| C `RuntimeState` 池（第 1 次） | 376 ns | 3128 ns（+6%） | 319.6k/s | 833.8k/s |
| C `RuntimeState` 池（第 2 次） | 348 ns | 3248 ns（+10%） | 307.9k/s | 519.2k/s |

## 3. 为什么 C1 降了、L1 反而升

- **B 的教训（最重要）**：`std.ThreadLocal` 单次访问约 **300 ns**，比一次 malloc/free
  （glibc tcache 快路径）还贵。`create`/`free` 各取一次 TLS ⇒ C1 从 405 直接涨到 855。
  这与 `optimize-runtime-tls` 的经验一致：TLS 只能在「每次调用一次」的量级上用，
  不能放进 create/free 这种成对调用里。
- **C 的形态**：池挂到 `RuntimeState`（调用路径已持有 `rs`），TLS 成本消失，C1 降到
  348–376（−14%）。但 `JitFunction.callLocked` 需要把 `rs` 以 `rs!: ?RuntimeState` 的
  **命名可选参数**传给 `create`，热路径多了一次 `Some(rs)` 构造与 `match`；
  同时池操作（`size`/`remove`/`add`）本身也有成本。
  两者相加 ≈ 把 C1 省下的 30–60 ns 又吃回去，端到端落在噪声里。
- **测量面**：本轮 Q4 从 833k 掉到 519k（同一份代码、相隔一次编译），说明构建机负载
  波动很大；L1 的 +6% 与 +10% 两次方向一致，但幅度本身也不足以支撑「显著变慢」的结论。
  无论哪个方向，**都没有可采纳的收益**。

## 4. 回退内容

```
git checkout -- src/runtime/JitContext.cj src/runtime/RuntimeState.cj \
                src/JitFunction.cj src/CallPathBench_test.cj
rm src/JitContextPool_test.cj
```

`JitContext` / `RuntimeState` 恢复为「每次 `LibC.malloc` 64 B / `LibC.free`」；
`NativeMem` 计数口径不变（未引入 `realMallocCount`）。

## 5. 后续建议

- 若要再碰这条路径，应该先做**同进程 A/B**（同一份代码里两个池化开关各跑 21 次取中位数），
  而不是两次独立构建对比——本轮 Q4 的 833k→519k 就是独立构建对比不可靠的直接证据。
- 编译侧（front-end 扫描、AST 分配）仍是唯一有量级的剩余成本（~5 ms/次），
  但它属于大改，不建议在「调用路径」上继续挖 1% 级别的项。
- 结论写入 `doc/concurrency-audit.md` 的性能段落（作为「已尝试、无收益」的记录）。
