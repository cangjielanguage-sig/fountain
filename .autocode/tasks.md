
# 前置任务
cd f_concurrent

# 任务
为ConcurrentSkipListMap 实现一个tailer迭代器，要以O(log(n))的时间复杂度找到第一个符合条件的key。
函数声明如下：
```cj
/**
 * @param min: 迭代器的第一个key不小于min
 * @param including: 迭代器的第一个key是否包含min，true为包含，false为不包含
 */
public func tailer(min: K, including!: Bool = true): Iterator<(K, V)>
```