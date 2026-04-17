# 前置任务
cd f_concurrent

# 任务
按照以下方案优化ConcurrentSkipListMap
---

# P4: removeIf 遍历中缺时代际检查

## 问题定位
- 位置：第 597-625 行
- `removeIf` 开始时捕获 `epoch`，但长遍历过程中不检查 `clear()` 干扰
- 如果 `clear()` 在遍历期间执行，遍历可能访问已断开连接的节点
- 当前实现无防护

## 优化方案

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

## 预期收益
- 防止访问已断开的链表
- 减少无效遍历

## 风险
- 低：增加检查开销极小
- 需验证 epoch 比较逻辑正确性


# 优化之后
1. 针对本次修改分别在ConcurrentSkipListMap_test.cj 和ConcurrentSkipListMap_conc_test.cj 添加新的测试用例
2. 执行命令：cjpm test --filter ConcurrentSkipListMap_test --no-captcture-output --show-all-output 确认修改是否正确
3. 运行命令：cjpm test --filter ConcurrentSkipListMap_conc_test --no-captcture-output --show-all-output 确认并发访问正确
4. 运行命令：cjpm test --filter ConcurrentSkipListMap_perf_test --no-captcture-output --show-all-output|grep -P 'perf_.+:' 根据性能测试结果出性能测试报告跟f_concurrent/doc/performance_report.md 比较优化前后的差异，如果性能表现更优更新性能测试报告、本次修改内容，提交git；否则回退之前的版本
