# 设计：签名两表的快照化

## 决策总览

| 编号 | 决策 | 理由 |
| --- | --- | --- |
| D1 | **不做结构键索引**，保留线性 `sameShape` 扫描，只去掉锁 | 实测反例：表只有个位数条目时，拼字符串键（`StringBuilder` + 插值）比线性扫更贵（`adapterOf` 349 → 790 ns）；去锁后线性扫降到 233 ns |
| D2 | 快照不可变（`Array` 只读 + `HashMap` 只读），写时复制 | 与 P1.2（`HostFieldTable`）、P4-A（`JitBindSupport`）同一模式，已验证两次 |
| D3 | 发布用 `AtomicReference<Snapshot>` | std 已确认支持 `init/load/store/CAS` |
| D4 | `SignatureTable.builds` 计数放进快照 | 避免额外的全局原子；`builds` 只在写锁内 +1，随快照一起发布 |
| D5 | `SignatureTable.enabled` 保持 `public static var` | 原状就未同步（锁外读）；本次不改其语义，只改表结构 |
| D6 | `register` 仍返回 `Int32` 下标 | id 语义不变，`get(id)` 仍 O(1) 数组索引 |

## D1：为什么最终没有用键索引（实测否决）

原设计打算用「结构键字符串 + `HashMap`」，理由是「查找频繁」。实现后实测（同一探针、同机）：

| 版本 | `adapterOf` | `getOrBuild` | `HostCallback` 全构造 | 4 线程全构造 |
| --- | --- | --- | --- | --- |
| 改造前（锁 + 线性扫） | 349 ns | 216 ns | 521 ns | 1008 ns（0.52×） |
| 字符串键版 | **790 ns** | **554 ns** | **1306 ns** | 未测（已否决） |
| **快照 + 线性扫（采纳）** | **233 ns** | **134 ns** | **244 ns** | **484 ns（0.94×）** |

根因：`SignatureRegistry` 的条目数是个位数（JitHost 登记的几个签名），线性扫 `sameShape`
（逐位比 `UInt16` 与短字符串）本身只要几十 ns；而拼键要在每次查找时用 `StringBuilder`
做 5–10 次插值拼接 + 分配。**表小的时候，索引的构造成本高于它省下的扫描成本。**

因此最终实现只做一件事：**把锁去掉**（快照 + `AtomicReference`），扫描逻辑原样保留。

### 附：如果将来表规模变大

超过约 50 条时应重新评估键索引；届时要**把键缓存在调用方**（例如 `HostCallback`
按 `sig` 复用），而不是每次查找现拼。

## 原 D1 草案：键的构造（**已不采用，保留为分析**）

`SignatureRegistry.sameShape` 比较四个维度：

1. `params.size`
2. 逐位 `params[i]`（`LocalType` 码）
3. 逐位 `paramNames[i]`（具体类名，非 14 位置为 `''`）
4. `ret` + `retName`

键必须全部覆盖，否则不同签名会撞 id：

```
k = params 逐位十进制用 ',' 连接
    + '|' + paramNames 用 ',' 连接
    + '|' + ret
    + '|' + retName
```

安全性：类名/参数名进入键的是**类型名**（不含用户可控的任意字符串分隔符冲突问题——`LocalType` 码是数字，
类名是合法标识符与 `.`；即便如此仍用长度前缀兜底，避免 `a,b` 与 `a`+`b` 歧义）。

采用**长度前缀**编码：`'${s.size}:${s}'`，拼接顺序固定，避免分隔符歧义。

`SignatureTable` 的键只看 `params` 与 `ret`（与它现有 `sameShape(sig.params, sig.ret)` 一致），
**不含** `paramNames`——不要把 `SignatureRegistry` 的键规则照搬过来，否则会导致
「同码不同类名」的计划被错误分开（行为变化）。

## D2/D3：快照与发布

```cj
private class SigSnapshot {
    let entries: Array<HostSignature>     // 下标即 id
    let byKey: HashMap<String, Int32>
}

private static let writeMtx = Mutex()
private static let current = AtomicReference<SigSnapshot>(empty())
```

- 读（`find`/`adapterOf`/`get`/`count`）：`current.load()` 后直接查，**零锁零分配**；
- 写（`register`）：`synchronized(writeMtx)` 内 `load` → 查键 → 命中即返回 → 未命中则复制数组追加、
  复制 map 加一项、`store` 新快照；
- `resetForTest`：`store(empty())`。

快照里的 `Array` / `HashMap` **发布后不再修改**（复制后填充再发布，参照 P4-A 踩过的坑：
必须**先填满再 store**，否则读者会看到半成品）。

## D4：`SignatureTable` 的双检

```cj
public static func getOrBuild(sig: SignatureDescriptor): ?SignaturePlan {
    if (!enabled) { return None }
    let k = keyOf(sig.params, sig.ret)
    let snap = current.load()
    match (snap.byKey.get(k)) {
        case Some(i) => return Some(snap.plans[Int64(i)])
        case None => ()
    }
    synchronized(writeMtx) {
        let s2 = current.load()               // 双检：别的线程可能已建好
        match (s2.byKey.get(k)) {
            case Some(i) => return Some(s2.plans[Int64(i)])
            case None => ()
        }
        let p = SignaturePlan(sig)
        let builds = s2.builds + 1
        if (s2.plans.size < MAX_ENTRIES) {
            // 追加并发布
            let plans = append(s2.plans, p)
            let byKey = copy(s2.byKey); byKey[k] = Int32(plans.size - 1)
            current.store(PlanSnapshot(plans, byKey, builds))
        } else {
            // 超上限：不缓存，但计数仍 +1（与现状一致）
            current.store(PlanSnapshot(s2.plans, s2.byKey, builds))
        }
        Some(p)
    }
}
```

## 风险与回退

| 风险 | 处置 |
| --- | --- |
| （已消除）键与 `sameShape` 不等价 ⇒ 签名串号 | 最终实现不含键，直接复用 `sameShape`；护栏仍保留该类名区分用例 |
| 先 `store` 后填充 ⇒ 读者见半成品 | 用 P4-A 的 `publishHook` 同法验证（store 前必须已填满）；本次直接按「填满再 store」写，并加并发读写用例 |
| `register` 与 `get(id)` 并发 | 旧快照仍完整可读；id 只追加 ⇒ `get` 对旧 id 恒有效 |
| 超上限后每次调用都新建 plan | 与现状一致（原本也不缓存），`builds` 会持续增长——保留原语义 |

## TDD 策略

- **行为 Red**：本次是等价重构，没有行为 Red（与 P1.2 同类的 TDD 例外）；
  护栏用「幂等 / id 稳定 / 类名区分 / 上限 / 开关 / 并发注册+读」六条 characterization 用例，
  **实现前后都必须绿**；keep/revert 只由基准数据决定。
- **判定基准**：`HostCallback(fn, sig)` 构造成本（1 线程 ns、4 线程扩展比）。
  实测：单线程 521 → **456 / 252**（−11%），4 线程 1008 → **484**（**−52%**），
  扩展比 0.52× → **0.94× / 0.70×**。
  **未达**原定「≤200 ns 且 ≥1.5×」，但 4 线程每 op −52% 远超 MOV；
  剩余争用已定位到 `TypeInfo.of` 反射（4 线程 **0.31–0.35×**，占单次构造 22–38%），
  属 std 反射元数据缓存，不在本次范围（建议另案）。判定：**keep**。
