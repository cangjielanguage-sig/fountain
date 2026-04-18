# 前置任务
cd f_concurrent

# 任务
按照以下方案优化ConcurrentSkipListMap.cj
---

# P5: tryInsertAtLevel 重试策略优化

## 问题定位
- 位置：第 391-429 行
- 当前固定重试 3 次，无区分策略
- CAS 失败可能是多种原因，但处理方式相同

---

## 方案：智能冲突检测

### 核心思路
- 区分冲突类型（删除/复活/真正冲突）
- 放宽重试上限（8次）
- 主动清理被删除节点

### 代码

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

### 特点
- 代码改动：大
- 引入 bug 风险：高
- 长期收益：有（自愈清理）

---

## 建议

- **追求极致性能**：需充分测试


# 优化之后
1. 如有必要，针对本次修改分别在ConcurrentSkipListMap_test.cj 和ConcurrentSkipListMap_conc_test.cj 添加新的测试用例
2. 执行命令：cjpm test --filter ConcurrentSkipListMap_test --no-captcture-output --show-all-output 确认修改是否正确
3. 逐个执行ConcurrentSkipListMap_conc_test的测试函数，运行命令：`cjpm test --filter ConcurrentSkipListMap_conc_test.<test_func_name> --no-captcture-output --show-all-output` 确认并发访问正确
4. 运行命令：cjpm test --filter ConcurrentSkipListMap_perf_test --no-captcture-output --show-all-output|grep -P 'perf_.+:' 根据性能测试结果出性能测试报告跟f_concurrent/doc/performance_report.md 比较优化前后的差异，如果性能表现更优更新性能测试报告、本次修改内容，提交git；否则回退之前的版本
