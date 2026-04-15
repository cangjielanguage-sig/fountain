# 前置任务
cd f_concurrent

# 任务
严格审查ConcurrentSkipListMap.cj，确认这个无锁并发跳表实现还有没有性能优化方向，指出性能优化方向
把优化方向追加到.autocode/tasks.md，如果没有就返回"**完美**"，不修改文件

---

# 性能优化方向

## 1. randomLevel 随机数生成优化
- 问题：使用完整 64 位 XorShift，每次只检查最高位（bit 63），浪费 63 位
- 优化：使用 32 位 XorShift 或预计算概率表，每次只需 1-2 位即可生成 0-16 层级
- 位置：第 141-155 行

## 2. effectiveMaxLevel 缓存优化
- 问题：每次 randomLevel 都调用 effectiveMaxLevel，涉及 size_.load() 和多次比较
- 优化：使用 AtomicInt64缓存结果，每 1000 次调用或 clear() 时更新
- 位置：第 98-103 行，第 141 行

## 3. findNode 缓存清理优化
- 问题：使用 for 循环逐个清空数组，17 次迭代
- 优化：直接创建新数组（17 个 Option 对象分配开销 vs 17 次写入），或使用 fill(None)
- 位置：第 167-170 行

## 4. Node.value 类型优化
- 问题：使用 AtomicOptionReference<Box<V>> 包装，逻辑删除需要额外封装
- 优化：考虑使用 AtomicReference<Box<V>> + 单独 AtomicBool 标记删除状态，避免 Option 包装开销
- 位置：第 28 行

## 5. compare 函数内联
- 问题：match (a, b) 模式匹配有开销，且频繁调用
- 优化：对于 Comparable<K>，直接使用 key.compareTo 或内联比较逻辑
- 位置：第 110-117 行

## 6. TryInsertAtLevel 重试策略
- 问题：固定 3 次重试，无指数退避
- 优化：根据重试次数动态调整或使用更智能的冲突检测
- 位置：第 391-429 行

## 7. removeIf 缺时代际检查
- 问题：removeIf 开始时捕获 epoch，但遍历过程中不检查 clear() 干扰
- 优化：在长遍历中周期性检查 epoch 变化，提前终止
- 位置：第 597-625 行

## 8. TailEntryIterator 代码复用
- 问题：与 EntryIterator 逻辑重复
- 优化：抽取公共基类或使用组合模式
- 位置：第 852-892 行

## 9. 批量插入优化
- 问题：add(all!: Collection<(K, V)>) 逐个插入，无批量优化
- 优化：使用分段锁或多线程并行插入大集合
- 位置：第 773-777 行

## 10. contains(all!) 提前退出优化
- 问题：已有 early return，但可考虑并行检查
- 位置：第 752-757 行
