# Verify：签名两表快照化（`optimize-signature-tables`）

## 变更范围

| 文件 | 改动 |
| --- | --- |
| `src/base/HostSignature.cj` | `SignatureRegistry`：`ArrayList + Mutex` → `AtomicReference<SigSnapshot>`；`register` 写时复制，`find/adapterOf/get/count` 零锁 |
| `src/runtime/SignaturePlan.cj` | `SignatureTable`：`ArrayList + Mutex + builds` → `AtomicReference<PlanSnapshot>`（含 `builds`）；`getOrBuild` 读命中零锁、未命中原写锁内双检 |
| `src/SignatureTableConcurrency_test.cj` | 新增 7 条语义护栏（无副作用：不调 `resetForTest`，全用唯一类名/签名） |

## 数据（A/B 同轮对比，旧/新各两轮）

| 指标 | 旧实现 | 新实现 | 变化 |
| --- | --- | --- | --- |
| `HostCallback` 单线程 | 524 / 280 ns | **456 / 252 ns** | −11% |
| **`HostCallback` 4 线程每 op** | 1008 / 752 ns | **484 / 360 ns** | **−52%** |
| 4 线程扩展比 | 0.52× / 0.37× | **0.94× / 0.70×** | +0.42 / +0.33 |
| `adapterOf`（单线程） | 357 / 212 ns | 316 / 209 ns | −11% / −1% |
| `getOrBuild`（单线程） | 216 / 124 ns | 200 / 108 ns | −7% / −13% |

> 共享 7 核 VM 上两轮绝对值差异大（负载），故采用**同轮 A/B**（`git stash` 回退旧实现再测）。

## 被实测否决的方案（重要）

原设计是「结构键字符串 + `HashMap` 索引」。实现后**性能反而变差**：

| 版本 | `adapterOf` | `getOrBuild` | 全构造 |
| --- | --- | --- | --- |
| 旧（锁 + 线性扫） | 349 ns | 216 ns | 521 ns |
| **字符串键版** | **790 ns** | **554 ns** | **1306 ns** |
| 快照 + 线性扫（最终） | **233 ns** | **134 ns** | **244 ns** |

根因：表只有个位数条目，线性扫 `sameShape` 本身几十 ns，而拼键要 5–10 次
`StringBuilder` 插值 + 分配 —— **表小时索引的构造成本高于它省下的扫描成本**。
已据此改回「只去锁、保留线性扫」，并在 design D1 记录该反例与「表 >50 条时再评估」的边界。

## 语义验证

| 用例 | 结果 |
| --- | --- |
| `registerIsIdempotent`（同结构同 id） | 绿 |
| `idsAreDistinctAndOrdered`（id 递增） | 绿 |
| `classNameDistinguishes`（`(User)` vs `(Order)` 不撞 id） | 绿 |
| `lookupsAgree`（find/get/adapterOf 一致；未登记/越界 → None） | 绿 |
| `concurrentRegisterAndFind`（4 写 + 4 读，200 个唯一签名，计数恰增 200） | 绿 |
| `planIsBuiltOnce`（同签名只建一次） | 绿 |
| `planRespectsSwitch`（`enabled=false` → None，finally 恢复） | 绿 |

护栏在**改造前后均绿**（等价重构，无行为 Red —— design 已声明的 TDD 例外）。

## 全量

**1221 / 1221 / 0 失败 / 0 error / 0 skipped**（1214 基线 + 7 条新护栏）。

## 未达成的目标与原因

| 目标 | 结果 |
| --- | --- |
| 单线程 ≤200 ns | 456 / 252（低负载轮接近，未稳达） |
| 4 线程 ≥1.5× | 0.94× / 0.70×（未达） |

**剩余争用已定位**：`TypeInfo.of(host)`（即 `HostCallback.probeType`）4 线程扩展比
**0.31–0.35×**，单线程占全构造 22–38%。这是 std 反射元数据缓存内部的争用，
不在本次范围。若要继续，方向是「按 `fn` 身份缓存 `FunctionTypeInfo`」或
「把 `probeType` 结果随 `HostSignature` 一起登记」，需另案评估（缓存生命周期与弱引用语义）。

## 风险

- 旧快照对新 id 的读者完整可用（id 只追加）；`get(id)` 对历史 id 恒有效；
- `register` 写时复制是 O(n) 复制，n 为个位数 —— 注册发生在初始化/注册期，可接受；
- `SignatureTable` 超 `MAX_ENTRIES` 后仍不缓存、`builds` 仍 +1（与改造前一致）。

## 归档

`openspec archive optimize-signature-tables --yes`。
