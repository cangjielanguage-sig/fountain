# 设计：两处残余锁清理

## A. `JitBindSupport` 不可变快照

### 现状

```text
private static let enrolled = HashMap<String, JitBindings>()
private static let interfaceAccepts = HashMap<String, (Object) -> Bool>()
private static let mtx = Mutex()
```

读：`acceptsInterface` / `isInterface` / `enrolledOf` 全部 `synchronized(mtx)`；
写：`enrollOf` / `enrollInterfaceOf`（宏生成的包级 `let` 在包初始化期调用）。

### 改动

```text
private class BindSnapshot {
    let enrolled: HashMap<String, JitBindings>
    let interfaceAccepts: HashMap<String, (Object) -> Bool>
}
private static let writeMtx = Mutex()
private static let current = AtomicReference<BindSnapshot>(空快照)
```

- 写：`synchronized(writeMtx)` 内复制旧快照两张表 → 覆盖/追加 → `current.store(新快照)`；
- 读：`current.load()` 后直接查表，**零锁零拷贝**；
- `parentsOf(name)` → `enrolledOf(name).parents`，随 `enrolledOf` 一起受益。

### 语义

- 注册只追加（`enrollOf` 同 key 覆盖 bindings），快照单调增长；
- 读者可能看到旧快照（缺少刚登记的项）。注册发生在包初始化 / `registerClass`，
  与后续编译/调用之间有 happens-before，不会出现「已编译却查不到」；
- 写锁与 `HandleTable.mtx` 无嵌套，无锁序问题。

## B. `HandleTable.totalSlots` 原子化

### 现状

`openWindow` 为读 `totalSlots` 取全局 `mtx`（每次 `call` 一次）；`growSlot` 在 `mtx` 内
`totalSlots = idx + 1`；`resetWindow` 的栈空分支、`liveCount`、`slotCount` 也读它。

### 改动

```text
private static let totalSlots = AtomicInt64(1)
```

- `growSlot`（仍持 `mtx`）：`let idx = totalSlots.load()` → 容量检查 → `ensureSegLocked(idx)`
  → `totalSlots.store(idx + 1)`。**段发布仍在锁内完成，返回 idx 前已可见**；
- `openWindow`：`let base = totalSlots.load()`，删掉 `synchronized`；
- `resetWindow` 栈空分支、`liveCount`、`slotCount`：`load()`；
- `resetForTest`：`store(1)`（仍持 `mtx`，与其它复位一起）。

`mtx` 保留给：段发布 / 容量检查、常量路径、`moveOutGroup`、`resetForTest`。

## TDD 策略

两项都是**行为等价重构**，没有可先红的行为差异（与 phase1 的 P1.2 同类，已声明例外）：

1. 先写**characterization + 并发护栏**（在旧实现上必须绿）；
2. 实现后同一组用例必须仍绿；
3. 用**临时微基准**判定收益，不达标则回滚：
   - A：`acceptsInterface` 的 1 vs 4 线程扩展比（基线 0.40×）；
   - B：`openWindow+resetWindow` 的 1 vs 4 线程扩展比（基线 2.28×）。

护栏用一个**故意破坏快照发布**的变异验证（把 `store` 改成先清空再填）确认能红。

## 风险

| 风险 | 处置 |
| --- | --- |
| 快照复制成本随注册类数增长 | 注册是冷路径（一次几十~几百项），复制一次成本远低于一次编译 |
| 读者看到旧快照 | 只可能缺新项；注册与使用之间有 happens-before |
| `totalSlots` 混用原子与 `mtx` | 写侧全在 `mtx` 内且用 `store`，读侧 `load`；单个 Int64 的原子读写不撕裂 |
| `liveCount` 遍历边界读到更大的 `totalSlots` | 段未发布时 `segAt` 返回 `EMPTY_SEG`（`alive=false`），不会越界 |
