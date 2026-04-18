# 前置任务
cd f_concurrent

# 任务
每完成一个任务都在相应的标题前面加上完成标记
编译时执行cd f_concurrent && cjpm build
测试时执行cd f_concurrent && cjpm test --filter ConcurrentSkipListMap_test --no-capture-output --show-all-output，性能测试并发测试也仿照此命令

## P0 - 活锁BUG
cd f_concurrent && timeout 120 cjpm test --filter ConcurrentSkipListMap_conc_test --no-capture-output --show-all-output
这个测试类的每个用例都有概率会长时间不结束，每个用例单独执行，多执行几次就会发生，一起执行一定会发生。应该是并发调用发生了死循环。
考虑到编译时间，命令超时时间不能太短，否则可能还没编译完就结束了。
检查ConcurrentSkipListMap.cj，找到问题原因。尤其是add remove get 等函数的混合并发操作。
在代码测试代码和被测代码添加sleep控制执行节奏，添加println输出运行过程中的变量，方便观察。

### 优化之后
1. 执行命令：cjpm test --filter ConcurrentSkipListMap_test --no-captcture-output --show-all-output 确认修改是否正确
2. 运行命令：cjpm test --filter ConcurrentSkipListMap_conc_test --no-captcture-output --show-all-output 确认并发访问正确
3. 运行命令：cjpm test --filter ConcurrentSkipListMap_perf_test --no-captcture-output --show-all-output|grep -P 'perf_.+:' 根据性能测试结果出性能测试报告跟f_concurrent/doc/performance_report.md 比较优化前后的差异，如果性能表现更优更新性能测试报告、本次修改内容，提交git；否则回退之前的版本

## P1 - randomLevel 随机数生成优化

### 问题定位
- 位置：第 131-155 行
- 当前使用 64 位 XorShift，但每次只检查最高位（bit 63）
- 浪费 63 位的计算结果
- 每次生成 64 位随机数，只用 1 位

### 优化方案

#### 方案：预计算概率表
  原理

  跳表层级服从几何分布：层级 L 概率 P(L) = (1/2)^(L+1)

  即：
  - L=0: 50%
  - L=1: 25%
  - L=2: 12.5%
  - ...

  传统方案问题

  当前代码：
  while (level < effectiveMax) {
      let r = xorShift64()
      if ((r & (1 << 63)) == 0) {  // 检查最高位
          level += 1
      } else {
          break
      }
  }

  每次生成 64 位，只用 1 位，浪费 63 位。

  概率表方案

  // 预计算阈值：满足条件则 level++
  // 阈值含义：r < threshold 则提升到下一层
  private static let LEVEL_THRESHOLDS: Array<UInt64> = [
      0xFFFFFFFFFFFFFFFFu64,  // L=0→1: 必然提升（100%）
      0x8000000000000000u64,  // L=1→2: r < 2^63 (50%)
      0x4000000000000000u64,  // L=2→3: r < 2^62 (25%)
      0x2000000000000000u64,  // L=3→4: r < 2^61 (12.5%)
      0x1000000000000000u64,  // L=4→5: 6.25%
      0x0800000000000000u64,  // L=5→6: 3.125%
      0x0400000000000000u64,  // L=6→7: 1.5625%
      0x0200000000000000u64,  // L=7→8: 0.78%
      // ... 继续衰减
  ]

  private func randomLevel(): Int64 {
      var level: Int64 = 0
      let effectiveMax = effectiveMaxLevel()
      let r = xorShift64().toUInt()  // 转无符号比较

      while (level < effectiveMax && level < 16) {
          if (r < LEVEL_THRESHOLDS[level]) {
              level += 1
          } else {
              break
          }
      }
      return level
  }

  对比

  ┌────────────┬────────────────┬────────────────────┐
  │    维度    │    传统方案    │     概率表方案     │
  ├────────────┼────────────────┼────────────────────┤
  │ 随机数使用 │ 1 位/循环      │ 1 次生成，全用     │
  ├────────────┼────────────────┼────────────────────┤
  │ 分支预测   │ 难（0/1 随机） │ 易（阈值固定）     │
  ├────────────┼────────────────┼────────────────────┤
  │ 代码复杂度 │ 简单           │ 中等               │
  ├────────────┼────────────────┼────────────────────┤
  │ 性能       │ 一般           │ 优（减少分支失败） │
  └────────────┴────────────────┴────────────────────┘

  关键优势

  1. 一次随机数生成：64 位全用，不逐层生成
  2. 分支预测友好：阈值固定，CPU 易预测
  3. 分布精确：严格遵循几何分布

  风险

  - 需验证 UInt64 比较正确性
  - 阈值数组需与 MAX_LEVEL 匹配
  - 仓颉 UInt64 字面量语法需确认

### 预期收益
- 减少 CPU 指令（32 位 vs 64 位操作）
- 或通过概率表消除分支预测失败

### 风险
- 低：逻辑等效
- 概率表需测试验证分布一致性

### 优化之后
1. 执行命令：cjpm test --filter ConcurrentSkipListMap_test --no-captcture-output --show-all-output 确认修改是否正确
2. 运行命令：cjpm test --filter ConcurrentSkipListMap_conc_test --no-captcture-output --show-all-output 确认并发访问正确
3. 运行命令：cjpm test --filter ConcurrentSkipListMap_perf_test --no-captcture-output --show-all-output|grep -P 'perf_.+:' 根据性能测试结果出性能测试报告跟f_concurrent/doc/performance_report.md 比较优化前后的差异，如果性能表现更优更新性能测试报告、本次修改内容，提交git；否则回退之前的版本

## P3 - removeIf 遍历中缺时代际检查

### 问题定位
- 位置：第 597-625 行
- `removeIf` 开始时捕获 `epoch`，但长遍历过程中不检查 `clear()` 干扰
- 如果 `clear()` 在遍历期间执行，遍历可能访问已断开连接的节点
- 当前实现无防护

### 优化方案

```cj
public func removeIf(predicate: (K, V) -> Bool): Unit {
    let startEpoch = epoch.load()
    var currOpt = head.next[0].load()
    var checkCounter: Int64 = 0

    while (true) {
        // 每 64 个节点检查一次 epoch 变化
        checkCounter += 1
        if (checkCounter % 64 == 0) {
            if (epoch.load() != startEpoch) {
                // clear() 已执行，终止遍历
                return
            }
        }

        match (currOpt) {
            case Some(curr) =>
                if (isHead(curr)) {
                    currOpt = curr.next[0].load()
                    continue
                }
                let valOpt = curr.value.load()
                match (valOpt) {
                    case Some(box) =>
                        match (curr.key) {
                            case Some(k) =>
                                if (predicate(k, box.value)) {
                                    tryRemoveNode(curr, startEpoch)
                                }
                            case None =>
                                tryRemoveNode(curr, startEpoch)
                        }
                    case None =>
                        helpPhysicallyRemove(curr)
                }
                currOpt = curr.next[0].load()
            case None => break
        }
    }
}
```

### 预期收益
- 防止访问已断开的链表
- 减少无效遍历

### 风险
- 低：增加检查开销极小
- 需验证 epoch 比较逻辑正确性

### 优化之后
1. 针对本次修改分别在ConcurrentSkipListMap_test.cj 和ConcurrentSkipListMap_conc_test.cj 添加新的测试用例
2. 执行命令：cjpm test --filter ConcurrentSkipListMap_test --no-captcture-output --show-all-output 确认修改是否正确
3. 运行命令：cjpm test --filter ConcurrentSkipListMap_conc_test --no-captcture-output --show-all-output 确认并发访问正确
4. 运行命令：cjpm test --filter ConcurrentSkipListMap_perf_test --no-captcture-output --show-all-output|grep -P 'perf_.+:' 根据性能测试结果出性能测试报告跟f_concurrent/doc/performance_report.md 比较优化前后的差异，如果性能表现更优更新性能测试报告、本次修改内容，提交git；否则回退之前的版本

## P4 - tryInsertAtLevel 重试策略优化

### 问题定位
- 位置：第 391-429 行
- 当前固定重试 3 次，无区分策略
- CAS 失败可能是多种原因，但处理方式相同

---

### 方案：智能冲突检测

#### 核心思路
- 区分冲突类型（删除/复活/真正冲突）
- 放宽重试上限（8次）
- 主动清理被删除节点

#### 代码

```cj
private func tryInsertAtLevel(newNode: Node<K, V>, lvl: Int64, pred: Node<K, V>): Bool {
    var currentPred = pred
    var retries = 0

    while (retries < 8) {
        let succ = currentPred.next[lvl].load()

        match (succ) {
            case Some(n) if !isHead(n) =>
                let cmp = compare(n.key, newNode.key)
                if (cmp == LT) {
                    currentPred = n
                    retries += 1
                    continue
                } else if (cmp == EQ) {
                    if (refEq(n, newNode)) {
                        return true
                    }
                    // 检测是否是"复活"场景
                    if (n.value.load().isNone()) {
                        // 后继被逻辑删除，帮助清理后重试
                        let nodeNext = n.next[lvl].load()
                        currentPred.next[lvl].compareAndSwap(succ, nodeNext)
                        retries += 1
                        continue
                    }
                    return false  // 真实冲突
                }
                // cmp == GT，前驱位置正确
            case _ => ()
        }

        // 检测前驱是否被删除
        if (!isHead(currentPred) && currentPred.value.load().isNone()) {
            currentPred = findPredecessorAtLevel(newNode.key, lvl)
            retries += 1
            continue
        }

        // 执行 CAS
        newNode.next[lvl].store(succ)
        if (currentPred.next[lvl].compareAndSwap(succ, Some(newNode))) {
            return true
        }

        // CAS 失败，区分原因
        let newSucc = currentPred.next[lvl].load()
        match (newSucc) {
            case Some(ns) =>
                if (refEq(ns, newNode)) {
                    return true  // CAS 失败但节点已在链中
                }
            case None => ()
        }
        retries += 1
    }
    return false
}
```

#### 特点
- 代码改动：大
- 引入 bug 风险：高
- 长期收益：有（自愈清理）

---

### 建议

- **追求极致性能**：需充分测试

### 优化之后
1. 如有必要，针对本次修改分别在ConcurrentSkipListMap_test.cj 和ConcurrentSkipListMap_conc_test.cj 添加新的测试用例
2. 执行命令：cjpm test --filter ConcurrentSkipListMap_test --no-captcture-output --show-all-output 确认修改是否正确
3. 逐个执行ConcurrentSkipListMap_conc_test的测试函数，运行命令：`cjpm test --filter ConcurrentSkipListMap_conc_test.<test_func_name> --no-captcture-output --show-all-output` 确认并发访问正确
4. 运行命令：cjpm test --filter ConcurrentSkipListMap_perf_test --no-captcture-output --show-all-output|grep -P 'perf_.+:' 根据性能测试结果出性能测试报告跟f_concurrent/doc/performance_report.md 比较优化前后的差异，如果性能表现更优更新性能测试报告、本次修改内容，提交git；否则回退之前的版本
