# 性能门禁报告（M7）

> 对应 `doc/09-testing.md` §5 的 B-01~B-07。阈值是验收合同，本文只记录实测值与采样方法，
> 不放宽任何阈值。

## 1. 环境

| 项 | 值 |
|---|---|
| 日期 | 2026-11-01 |
| 机器 | Linux 6.6.0 aarch64（7 vCPU，Cortex-A53，16 GiB） |
| 编译器 | `cjc 1.3.0-alpha.20261023001052`（cjnative） |
| 构建工具 | `cjpm 1.3.0-alpha.08` |
| 构建模式 | `cjpm test` 默认（release，未开 `-g`） |
| 运行方式 | 单进程、串行执行；`cjpm test --include-tags=perf --no-capture-output` |
| 计时 | `std.time.MonoTime` 纳秒差，单次样本包含一次完整被测操作 |

B-05（RSS）单独起进程测量（`--include-tags=b05`），避免前面用例的堆残留干扰基线。

## 2. 测量纪律

1. **先 warmup 再采样**：warmup 次数的调用结果不计入样本，覆盖首调用/懒建索引/缓存预热。
2. **分位数用最近秩**：`rank = ceil(p × n)`，`P95` 是排序后第 `ceil(0.95n)` 个样本，
   不是 `max`，也不是平均值。实现见 `src/test/PerfSupport.cj` 的 `PerfStats.percentile`。
3. **样本与 warmup 逐项记录**（下表），失败时抛出实测值 + 上限，便于复核。
4. 阈值集中在 `PerfGate`，测试代码不内联魔数；任何调优不得修改该类的取值。

复现：

```bash
cd f_rule
cjpm test --include-tags=perf --no-capture-output   # 只跑门禁
cjpm test --exclude-tags=perf                      # 日常回归，跳过门禁与规模用例
```

门禁用例带 `@Tag[perf]`，默认随 `cjpm test` 一起执行（任务清单把它们定义为单元用例）；
只想跑功能回归时用 `--exclude-tags=perf`。

## 3. 结果

| 编号 | 场景 | 门禁 | 判定指标 | 实测 | 采样 | 结论 |
|---|---|---|---|---|---|---|
| B-01 | 1000 规则（每规则 2 模式）构建网络 | < 500 ms，节点 < 3000 | 5 次冷构建的**最大值** | 58.12 ms；节点 1200 | warmup 1 / samples 5 | 达标 |
| B-02 | 10000 事实插入 | < 2 s，激活数与朴素一致 | 5 次插入的 **P95** | 1161.71 ms（重复整轮运行的区间 1096–1162 ms）；激活 1000 = 朴素 1000 | warmup 1 / samples 5 | 达标 |
| B-03 | 网络已建后单条插入 | P95 < 1 ms | 500 次单条插入的 **P95** | 0.116 ms（P50 0.0856 ms，max 4.80 ms） | warmup 100 / samples 500 | 达标 |
| B-04 | 撤销 30% 事实 | < 500 ms | 3 次撤销的**最大值** | 176.41 ms（P50 130.18 ms） | warmup 1 / samples 3 | 达标 |
| B-05 | 1000 规则 / 10000 事实 RSS | < 512 MB | 单次 `VmRSS` 快照 | 188,850,176 B（基线 48,349,184 B，增量 140,304,384 B） | 1 次（独立进程） | 达标 |
| B-06 | 重复构建同一规则集 | < 50 ms | 100 次缓存命中的 **P95** | 0.000157 ms（引擎构造 P95 0.00125 ms） | warmup 10 / samples 100（引擎 2 / 20） | 达标 |
| B-07 | 1000 行决策表解析 + 编译 | < 300 ms | 5 次的 **P95** | 16.35 ms（P50 14.56 ms） | warmup 1 / samples 5 | 达标 |

补充观测：

- B-02 的激活集合与 `NaiveMatcher` 逐条相等（排序键集合完全一致），并额外与解析解
  `expectedActivations(1000, 10000) = 1000` 对账；比对不计时。
- B-03 的 `max`（4.8–13.1 ms 视运行而定）是 GC 停顿造成的离群值，故门禁取 P95；
  P50 与 P95 同数量级，单次插入路径本身没有随规模退化。
- B-01 节点数 1200 = 200 个 alpha（100 个 `code` 等值链头 + 100 个 `group` 等值链头）
  + 1000 个 beta join，远低于 3000，说明 alpha/beta 共享按签名生效。
- 重复整轮运行的观测区间（同一台机器，4 次）：B-01 41–58 ms、B-02 P95 1096–1162 ms、
  B-03 P95 0.116–0.306 ms、B-04 169–176 ms、B-05 188.9 MB（独立进程）– 204 MB（同进程）、
  B-06 P95 < 0.0002 ms、B-07 16–20 ms。表中取一轮完整测量记录，门禁判定值均按该轮样本计算。

## 4. 夹具（`src/test/PerfSupport.cj`）

- 事实：`PerfOrder`（动态类型），字段 `orderId / amount / level / code / group`；
  10000 条事实把 `(code, group)` 的 100×100 网格铺满，每条 `orderId` 唯一。
- 规则：1000 条，每条两个模式——`code == Ci` 与 `group == Gj`，并用
  `a.orderId == b.orderId` 连接。1000 个规则对互不相同，因此恰好命中 1000 条事实，
  激活数有解析解，便于与朴素匹配对账。
- 规模不变式由 `PerfFixture_test` 锁定：小规模（20 规则 / 100 事实）与全量（1000/10000）
  都断言 `激活数 == 解析解`。

## 5. 调优记录（按收益排序）

门禁首次实测：B-01 41 ms（已达标）、B-02 **2288 ms（不达标）**、B-03 **8.70 ms（不达标）**、
B-04 **1197 ms（不达标）**、B-05 195 MB（已达标）、B-07 19 ms（已达标）；
B-06 的缓存是第一版实现就带上的（没有缓存时门禁无从谈起），首测 0.000312 ms。
以下改动都是真实实现优化，夹具与阈值未动。

| # | 问题 | 改动 | 影响 |
|---|---|---|---|
| 1 | 首模式的 beta 节点在右侧事实到达时**全扫左侧 alpha memory** 并为每条左事实构造令牌，单次插入 O(n) | `BetaNode.probeLeftAlpha`：用 join 值走 alpha 索引探测，无索引才回退全扫 | B-02 2288 → 1032 ms，B-03 8.70 → 0.23 ms |
| 2 | 根节点对同类型的每个 alpha 链头逐条跑测试闭包，200 个链头 × 每条事实 | `RootDispatch`：等值首约束按 `(字段, 值)` 建桶，事实只算一次字段值即定位链头 | B-03 0.19 → 0.116 ms；B-02 的变化在噪声内（该场景由 beta 侧主导），但它是 #3 命中记录的前提 |
| 3 | 撤销时按 200 个链头逐个查 memory（200 次哈希 + 调用），网络侧实测 643 ms | 插入时记录命中的链头（`ReteSession.recordAlphaHits`），撤销按记录回收 | B-04 665 → 176 ms |
| 4 | `BetaNode.produced_`/`producedByParent_` 是**会话态**却挂在共享节点上：第二个会话插入同一批事实会命中上个会话的索引，表现为"新会话零激活" | 下沉为 `BetaProductions`，由 `(space, session)` 的 `SessionNetwork` 持有 | 修复会话隔离缺陷（`laterSessionsStillProduceAllActivations` 覆盖） |
| 5 | `FactBase` 撤销按类型桶线性扫描（`scan` 顺序契约不能破） | 桶内槽位索引 + 墓碑，过半整理；`scan` 仍按插入顺序 | 3000 次撤销的存储侧成本 ~650 → 16.7 ms；B-04 1197 → 665 ms |
| 6 | 撤销路径之外的小项：`TrackingSink`/`RecordingSink` 的 O(n) 去重与删除、`AlphaMemory`/`BetaMemory` 的线性删除、`Token`/`Activation` 的全局互斥锁取号、`RootNode` 每条事实复制链头数组、`Bindings` 双次复制、`ValueKey` 每次归一分配 | 键索引 + 槽位交换删除、`AtomicInt64`、内部列表直读、`Bindings.adopt`、同类型基本值走直比 | 累计若干十毫秒；B-05 维持 189 MB |
| 7 | B-06 无网络结构缓存 | `ShardedNetwork.shared` 单条缓存（按 `RuleSet` 实例身份），`RuleEngine` 复用之 | 未缓存的重复构建等同一次冷构建（B-01 实测 41–58 ms）→ 0.00016 ms |
| 8 | `ExpressionMode.Interpreted` 是死配置：脚本始终走 f_jit | `JitExpression.interpretedOf` + `Validator`/`ReteNetwork` 按模式编译 | 让 I-03 可在引擎层逐条对比两种模式 |

未采用的方案（记录原因）：

- 为 `BetaNode` 增加 `(parent, handle)` 二级哈希替代"先查产出索引再构造令牌"：需要额外
  索引与内存，当前 `produced_` 已是 O(k)，收益不足。
- 把 alpha 测试编译成特化闭包：收益有限，且 `#2` 已从源头消除绝大多数测试调用。

## 6. 已知边界

- Cortex-A53 单核性能较弱，绝对耗时比 x86 开发机高一个量级；阈值是跨机器合同，
  本表只记录该机器实测。
- B-02 的 P95 距上限余量约 42%（1162 ms / 2000 ms），后续改动涉及插入路径时需重跑；
  同一台机器上重复整轮运行的波动约 2%，门禁判定用 P95 而非单次最小值。
- B-03 的 max 离群由 GC 引起；若后续把插入路径改为零分配，P95 与 max 的差距会缩小。
