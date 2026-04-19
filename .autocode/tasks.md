# 前置任务
cd f_concurrent

# 任务
每完成一个任务都在相应的标题前面加上完成标记
编译时执行cd f_concurrent && cjpm build
测试时只执行cd f_concurrent && cjpm test --filter ConcurrentSkipListMap_test --no-capture-output --show-all-output确认修改的代码逻辑正确，不执行并发测试和性能测试
以下任务ConcurrentSkipListMap_test结束以后，修改过以后在任务标题前面增加完成标记，然后提交、总结经验

## O1 - randomLevel 概率表优化

### 问题
- 位置：`randomLevel()` 方法
- 每提升一层调用一次 `xorShift64()`，只用最高1位，浪费63位
- add路径中randomLevel是热路径，减少xorShift64调用次数可显著降低add延迟

### 优化方案
用一次xorShift64生成结果，通过预计算阈值表一次性确定层级：

```cj
private static let LEVEL_THRESHOLDS: Array<UInt64> = [
    0xFFFFFFFFFFFFFFFF,  // L0→L1: 100%
    0x8000000000000000,  // L1→L2: 50%
    0x4000000000000000,  // L2→L3: 25%
    0x2000000000000000,  // L3→L4: 12.5%
    ... // 每层减半
]

private func randomLevel(): Int64 {
    var level: Int64 = 0
    let effectiveMax = effectiveMaxLevel()
    let r = xorShift64().toUInt64()  // 转无符号
    while (level < effectiveMax && level < 16) {
        if (r < LEVEL_THRESHOLDS[level]) {
            level += 1
        } else {
            break
        }
    }
    return level
}
```

### 收益评估
- **预期提升**：add性能提升10-20%（减少xorShift64调用次数，减少循环次数）
- **优化难度**：低（逻辑等效替换，需确认仓颉UInt64比较语法）
- **风险**：低（分布数学等价）

### 优化之后
1. 执行命令：cjpm test --filter ConcurrentSkipListMap_test --no-capture-output --show-all-output 确认修改是否正确
2. 运行命令：cjpm test --filter ConcurrentSkipListMap_conc_test --no-capture-output --show-all-output 确认并发访问正确
3. 运行命令：cjpm test --filter ConcurrentSkipListMap_perf_test --no-capture-output --show-all-output|grep -P 'perf_.+:' 根据性能测试结果出性能测试报告跟f_concurrent/doc/performance_report.md 比较优化前后的差异，如果性能表现更优更新性能测试报告、本次修改内容，提交git；否则回退之前的版本

---

## O2 - findNode 消除数组清空开销

### 问题
- 位置：`findNode()` 方法
- 每次调用都清空两个17元素数组：`for (i in 0..cache.preds.size) { cache.preds[i] = None }`
- findNode是所有操作的核心热路径，get/add/remove/entryView都调用
- 单线程get 123K ops/s，每次get ~8.1μs，数组清空是纯浪费

### 优化方案
不预清空数组，改为在使用后标记有效范围。或者更简单：用index变量记录每层实际写入位置，返回时只信任已写入的层级。

更简单的方案：findNode只写level 0到MAX_LEVEL，且总是从高到低写满，所以清空是不必要的——下一行赋值会覆盖。唯一风险是result的消费者读取了未写入的层级。但findNode的for循环从MAX_LEVEL到0完整遍历了所有层级，所以所有preds[i]和succs[i]都会被赋值。**清空数组完全多余！**

```cj
func findNode(key: K): FindResult<K, V> {
    let cache = findNodeCache.getOrCompute { FindNodeCache<K, V>() }
    // 删除清空循环 —— findNode从MAX_LEVEL到0完整遍历，所有位置都会被赋值
    let preds = cache.preds
    let succs = cache.succs
    ...
}
```

### 收益评估
- **预期提升**：所有操作提升15-25%（消除17*2=34次None赋值，减少内存写）
- **优化难度**：极低（删除代码）
- **风险**：低（需确认findNode的所有路径都覆盖了全部17个层级）

### 优化之后
1. 执行命令：cjpm test --filter ConcurrentSkipListMap_test --no-capture-output --show-all-output 确认修改是否正确
2. 运行命令：cjpm test --filter ConcurrentSkipListMap_conc_test --no-capture-output --show-all-output 确认并发访问正确
3. 运行命令：cjpm test --filter ConcurrentSkipListMap_perf_test --no-capture-output --show-all-output|grep -P 'perf_.+:' 根据性能测试结果出性能测试报告跟f_concurrent/doc/performance_report.md 比较优化前后的差异，如果性能表现更优更新性能测试报告、本次修改内容，提交git；否则回退之前的版本

---

## O3 - add() 减少冗余的 findNode/findPredecessorAtLevel 调用

### 问题
- 位置：`add()` 方法
- 插入新节点时先调用 `findNode(key)` 找level 0前驱，然后对level 1到newNode.level逐层调用 `findPredecessorAtLevel(key, lvl)`
- `findPredecessorAtLevel` 每次从MAX_LEVEL遍历到目标层，level 1到level N共调用N次，每次都是O(MAX_LEVEL)起
- 例如level=5的节点，高层插入需要5次findPredecessorAtLevel，每次从16层扫到目标层
- 总共约 5*16=80层遍历，而实际上一次从高到低的遍历就能找到所有层的前驱

### 优化方案
复用 `findNode` 已计算出的 preds 数组。findNode 已经从MAX_LEVEL到0遍历完成，preds[level]就是每层的前驱。新节点插入高层时，直接用findNode结果中的preds[lvl]作为前驱，只有在CAS失败重试时才重新查找：

```cj
case None =>
    let level = randomLevel()
    let newNode = Node(key, genbox(), level)
    // 优先使用findNode已找到的前驱
    let pred0 = result.preds[0].getOrThrow()
    if (!tryInsertAtLevel(newNode, 0, pred0)) {
        continue
    }
    // ... size/epoch逻辑不变 ...
    // 高层插入：优先用findNode结果，失败才重新查找
    for (lvl in 1..=level) {
        if (newNode.value.load().isNone()) { break }
        var inserted = false
        // 先尝试findNode缓存的前驱
        if (let Some(pred) <- result.preds[lvl]) {
            if (isHead(pred) || pred.value.load().isSome()) {
                inserted = tryInsertAtLevel(newNode, lvl, pred)
            }
        }
        // 缓存前驱失败，重新查找
        if (!inserted) {
            var retries = 0
            while (!inserted && retries < 3) {
                let pred = findPredecessorAtLevel(key, lvl)
                if (!isHead(pred) && pred.value.load().isNone()) {
                    retries += 1; continue
                }
                let succ = pred.next[lvl].load()
                if (let Some(n) <- succ && !isHead(n) && compare(n.key, newNode.key) == EQ && !refEq(n, newNode)) {
                    break
                } else if (tryInsertAtLevel(newNode, lvl, pred)) {
                    inserted = true
                } else {
                    retries += 1
                }
            }
        }
        if (!inserted) { break }
    }
```

### 收益评估
- **预期提升**：add性能提升20-40%（高层插入从N次全量查找降为0-1次，大多数情况复用findNode结果）
- **优化难度**：中（需仔细处理CAS竞争下preds过期的情况）
- **风险**：中（findNode的preds在并发下可能过期，需要验证tryInsertAtLevel能正确处理过期前驱）

---

## O4 - Node 减少内存分配开销

### 问题
- 位置：Node 构造函数
- 每个新Node分配：1个Array(17个AtomicOptionReference) + 1个AtomicOptionReference(值) + 1个Box<V>
- 实际上大部分节点level很低（50%是level 0，25%是level 1），却总是分配17层的next数组
- 17个AtomicOptionReference = 17 * (对象头+内部指针) ≈ 大量小对象分配
- 单线程add 63K ops/s 意味着每次add ~15.8μs，其中很大比例是GC和内存分配

### 优化方案
Node的next数组大小改为level+1而非MAX_LEVEL+1：

```cj
init(key: K, valbox: ?Box<V>, level: Int64) {
    ...
    this.next = Array<AtomicOptionReference<Node<K, V>>>(level + 1) {  // 只分配所需层数
        _ => AtomicOptionReference<Node<K, V>>()
    }
}
```

同时删除Box<V>包装，value直接用AtomicOptionReference<V>（需确认仓颉泛型原子引用支持）。

### 收益评估
- **预期提升**：add性能提升15-30%（减少内存分配量，level 0节点从17个AtomicOptionReference降为1个）
- **优化难度**：中（需修改Node构造函数和所有访问next数组的代码，确保不越界）
- **风险**：中（next数组大小不统一，遍历时需检查level边界）

---

## O5 - removeIf epoch 检查

### 问题
- 位置：`removeIf()` 方法
- removeIf 开始时捕获 epoch，但长遍历过程中不检查 clear() 干扰
- 如果 clear() 在遍历期间执行，遍历可能访问已断开连接的节点

### 优化方案
每64个节点检查一次epoch变化：

```cj
public func removeIf(predicate: (K, V) -> Bool): Unit {
    let startEpoch = epoch.load()
    var currOpt = head.next[0].load()
    var checkCounter: Int64 = 0
    while (true) {
        checkCounter += 1
        if (checkCounter % 64 == 0 && epoch.load() != startEpoch) {
            return  // clear()已执行，终止遍历
        }
        match (currOpt) {
            case Some(curr) =>
                ... // 原有逻辑不变
                currOpt = curr.next[0].load()
            case None => break
        }
    }
}
```

### 收益评估
- **预期提升**：无直接性能提升，属于正确性修复
- **优化难度**：极低
- **风险**：极低
