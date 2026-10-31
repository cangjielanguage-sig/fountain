# Design

## 1. 目标与不变量

| 编号 | 目标 |
|---|---|
| G1 | 单元的逃逸闭包在单元卸载时被级联释放（B1：未被 `callForFn` 承接的提升组同样覆盖） |
| G2 | 释放入口收敛为一个名字 `unload()`：入口实例 = 卸单元，包装实例 = 释放本闭包；`unloadFn` 转 private |
| G3 | 包装实例的释放与它在飞调用互斥：先排空后释放，超时回退（B2） |
| G4 | 单元不持有包装实例的强引用，包装对象随宿主引用消失可被 GC（B3） |

不变量：

- **I1 释放幂等**：`PromotionGroup.releaseAll()` 对空组是无操作（`PromotionGroup.cj:92-99`），级联与显式释放叠加不会二次归还。
- **I2 单锁**：逃逸闭包的全部生命周期状态（`state` / `active`）与单元状态机共用**单元 `mtx`**，任何路径不同时持有两把锁。
- **I3 终态不可逆**：级联只在 `state=2` 后发生；超时回退路径不释放任何闭包、不改任何组状态。

## 2. 数据结构：`EscapedClosure`（内部条目）

新增 `f_jit/src/EscapedClosure.cj`（包 `fountain::f_jit`）：

```cangjie
/** 单元发出的一个逃逸闭包：提升组 + 生命周期状态（受所属单元的 mtx 保护）。 */
class EscapedClosure {
    let group: PromotionGroup
    var state: Int64 = 0     // 0 Ready / 1 Unloading / 2 Released
    var active: Int64 = 0    // 该闭包的在飞调用数（仅本闭包，不含单元的其它调用）
    init(group: PromotionGroup) { this.group = group }
}
```

**为什么用条目而不是直接登记包装实例**（对上一版设计的修订）：

- **B1**：提升组在 `call<T>`（`retType=12`）解包时就已产生，`callForFn` 只是其中一条承接路径。条目在**组产生处**登记 ⇒ 未被承接的组也被单元卸载兜底，不再因 `lastClosureGroup` 被覆盖而丢。
- **B3**：条目只引用组与计数，不引用包装实例 ⇒ 单元不再强引用包装对象；宿主丢掉包装后对象可回收（组仍按契约驻留，直到单元卸载）。
- **G3**：`active` 天然挂在条目上，`state` 与单元状态共用同一把锁 ⇒ 检查与计数在同一临界区内完成，无 TOCTOU。

单元侧字段：

```cangjie
private let escaped = HashMap<Int64, EscapedClosure>()  // key = 条目序号
private var escapedSeq: Int64 = 0
private var lastEscaped: ?EscapedClosure = None          // 最近一次 CLOSURE 返回（承接口用）
```

（`lastClosureGroup` 由 `lastEscaped` 取代；`internal lastPromotionGroup()` 改为从条目取组，供既有用例断言。）

## 3. 登记与摘除

**D1 登记点 = 提升组产生处**：`callLocked` 解包出闭包后

```cangjie
if (unboxCode == LocalType.CLOSURE) {
    match (marshal.closureGroupOf()) {
        case Some(g) => this.lastEscaped = Some(this.registerEscaped(g))
        case None => ()
    }
}
```

`registerEscaped` 在 `synchronized(this.mtx)` 内分配序号、入表并返回条目。

**D2 承接**：`wrapClosure(owner, id, entry, nargs, retType, paramTypes)` 只把条目挂到包装实例（`entry` 字段），不重复登记。

**D3 摘除**：包装实例释放完成时 `synchronized(this.mtx) { this.escaped.remove(entry 的序号) }`。级联在锁内整表清空，不再逐个回调。

## 4. 释放实现

**D4 `unload()` 按实例种类分派**：

```cangjie
public func unload(timeoutMs: Int64): Bool {
    if (this.owner.isSome()) { return this.unloadFn(timeoutMs) }   // 逃逸闭包包装
    ... 原单元路径 ...
}

private func unloadFn(timeoutMs: Int64): Bool {   // 原 public unloadFn 降为私有
    match (this.owner) {
        case Some(o) => match (this.entry) {
            case Some(e) => o.unloadClosure(e, timeoutMs)
            case None => false
        }
        case None => false
    }
}
```

**D5 闭包释放状态机（单元侧 `unloadClosure`，全部临界区用单元 `mtx`）**：

```cangjie
private func unloadClosure(e: EscapedClosure, timeoutMs: Int64): Bool {
    synchronized(this.mtx) {
        if (e.state == 2) { return true }        // 幂等（含级联后）
        e.state = 1
    }
    // 排空：只等本闭包的 active
    while (true) {
        let drained = synchronized(this.mtx) { e.active == 0 }
        if (drained) { break }
        if (超时) {
            synchronized(this.mtx) { e.state = 0 }   // 回退可用
            return false
        }
    }
    var g: ?PromotionGroup = None
    synchronized(this.mtx) {
        e.state = 2
        g = Some(e.group)
        this.escaped.remove(e.seq)               // 出表（幂等：不在表也不报错）
    }
    match (g) { case Some(x) => x.releaseAll(); case None => () }
    true
}
```

**D6 进入/退出调用（单元侧 `enterClosure` / `exitClosure`）**：

```cangjie
private func enterClosure(e: EscapedClosure): Unit {
    synchronized(this.mtx) {
        if (this.state != 0) { throw 19('单元已卸载或正在卸载') }
        if (e.state != 0) { throw 19('闭包包装已释放') }
        this.active = this.active + 1
        e.active = e.active + 1
    }
}
```

包装实例的 `enter/exit` 改为委托这两个方法（原先委托 `enter/exit`）；单元 `active` 仍计入包装调用 ⇒ 单元卸载的排空覆盖它们。

**D7 单元终态级联**：锁内只做「置终态 + 逐出缓存 + 标记全部条目 + 拷组 + 清表」，锁外**先**释放组、**再** `release()` 单元资产：

```cangjie
var groups = ArrayList<PromotionGroup>()
var rel: ?(() -> Unit) = None
synchronized(this.mtx) {
    this.state = 2
    ... 逐出缓存 ...
    for ((_, e) in this.escaped) {
        if (e.state != 2) { e.state = 2; groups.add(e.group) }
    }
    this.escaped.clear()
    this.lastEscaped = None
    rel = this.release; this.release = None
}
for (g in groups) { g.releaseAll() }
match (rel) { case Some(f) => f(); case None => () }
```

**D8 状态谓词**：包装实例 `isClosed` = 条目 `state == 2`；`isUnloaded()` = `isClosed || owner.isUnloaded()`。二者都经单元 `mtx` 读。

## 5. 并发与锁序

| 场景 | 处理 |
|---|---|
| 同一闭包：调用 vs 释放 | 同一把单元 `mtx` 内「检查 state + `active+1`」与「state=1」互斥 ⇒ 释放开始后新调用 19，旧调用计数结束后才真正释放 |
| 同一闭包：级联 vs 显式释放 | 都以 `state` 单点判定；置 2 的一方拷贝组，另一方直接 `true`；`releaseAll` 幂等兜底 |
| 单元卸载 vs 包装调用 | 包装调用计入单元 `active`，单元终态要求 `active==0`；`state=1` 后 `enterClosure` 拒绝 |
| 锁序 | 全流程只有单元 `mtx` 一把锁，无嵌套 |

## 6. 与上一版设计的差异（因 B1/B2/B3）

| 项 | 上一版 | 本版 |
|---|---|---|
| 登记对象 | 包装实例（`JitFunction`） | 条目 `EscapedClosure`（组 + state + active） |
| 登记时机 | `wrapClosure` | 提升组产生处（`callLocked` 解包 CLOSURE）——覆盖未承接的组（B1） |
| 包装释放排空 | 不排空 | 按条目 `active` 排空，超时可回退（B2） |
| 单元 → 包装强引用 | 有 | 无（B3） |

## 7. 已知边界（本次仍不修）

- **B4** 条目在「宿主既不释放、单元也不卸载」期间常驻，组按契约 pin 住 —— 这是既有契约（README 已写明），非缺陷。
- **B5** 从**闭包内部**释放自己（重入：JIT 调用的宿主回调里 `w.unload(0)`）会因自身 `active≥1` 立即返回 `false`；如需支持需引入「重入豁免」，本次不做，记为边界并补用例固定该行为。

## 8. API 影响

| 变更 | 形式 | 仓内影响 |
|---|---|---|
| `unloadFn()` | `public` → `private`，签名 `(timeoutMs): Bool` | 20 处测试调用改 `unload()`；`unloadFnOnEntryInstanceIsRejected` 删除 |
| `unload()`（包装实例） | 委托单元卸载 → 释放本闭包（排空 + 超时回退） | 仓内无用例依赖旧行为 |
| `isUnloaded()`（包装实例） | 单元状态 → `isClosed \|\| 单元状态` | 仅新增为真场景 |
| `wrapClosure` | 内部签名加 `entry` 参数 | 仅 `callForFn` 与 2 处测试调用 |

## 9. 测试计划

| 用例 | 断言焦点 | 覆盖 |
|---|---|---|
| `unitUnloadReleasesEscapedClosures` | `liveCount` 回基线；两个包装 `isClosed` 真；调用 → 19 | G1 级联 |
| `unwrappedClosureGroupIsSweptOnUnitUnload` | `call<JitClosureId>` 两次（不承接）→ `unload(0)` → `liveCount` 回基线 | B1 |
| `wrapperUnloadOnlyReleasesOwnGroup` | 单元仍可调用、`runs()` 不变、`liveCount` 回基线 | G2 |
| `wrapperUnloadWaitsForInFlightCall` | 宿主回调内 `w.unload(0)` → `false` 且 `isClosed` 假；回调返回后 `w.unload(0)` → `true` | G3/B2/B5 |
| `cascadeThenWrapperUnloadIsIdempotent` | 级联后 `w.unload()` → `true`，不重复释放 | I1 |
| `unitUnloadCascadeKeepsOtherUnitsIntact` | A 卸载不影响 B | 隔离 |
| `unloadTimeoutRollbackKeepsClosures` | 单元 `unload(0)` 在飞 → `false`，闭包未释放 | 回退不级联 |
| `wrapperStatePredicatesAgree` | `isClosed` / `isUnloaded` 与释放来源一致 | D8 |

回归面：`refineUnload_test`、`JitFunctionClosure_test`、`CallForFnConcurrency_test`、`Q6Acceptance_test` T49/T32。

## 10. 文档落点

- `f_jit/README.md` / `README_en.md`：释放协议、API 表、Q4/Q6/Q7、已知限制（去 B1/B2/B3，补 B4/B5）。
- `doc/design-m2.md` §6.1.4 / §14.2 / §14.3。
- `doc/jit-bytecode-m2.md` §14.2 / §14.4。
