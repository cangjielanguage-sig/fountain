+ 执行pwd，本文的所有相对路径都是相对于pwd的执行结果
+ 把"---"下面的内容按顺序分解、规划任务
+ 如果需要修改.cj文件的代码确认当前上下文存在./.autocode/reference/cj_syntax.md的内容，如果不存在就加载它
+ 如果需要元编程就加载./.autocode/reference/advanced_syntax.md
+ 使用`curl -XGET <URL>`查阅仓颉文档
  - 标准库std文档： https://gitcode.com/Cangjie/cangjie_runtime/blob/main/stdlib/doc/libs/summary_cjnative.md
  - 扩展库stdx文档：https://gitcode.com/Cangjie/cangjie_stdx/blob/release/1.1/doc/summary_cjnative.md
  - 文档内部的链接也使用`curl -XGET <URL>`获取
+ 每完成一个任务就执行一次`git add . && git commit -m "<本次修改摘要>"`
+ 如果上下文快饱和了立即对上下文提取关键内容。
+ 压缩上下文后：
  - 务必保留用户最后一条消息
  - 务必查看**TODO LIST**
  - 务必保留本文件“---”之前的全部内容
---

# 任务1
cd f_concurrent

# 任务2
ConcurrentSkipListMap使用的Random不是并发安全的，用在ConcurrentSkipListMap中没有并发安全问题吗？要不要改成`ThreadLocal<Random>`？
如果有必要修改，修改后重新运行cjpm test --filter ConcurrentSkipListMap_test
如果不修改，略过这个任务继续执行下一个任务。

# 任务3
ConcurrentSkipListMap clear()函数不是原子的。如果有以下情况就出错了
1. 线程A执行clear()
2. 线程A修改head
3. 线程B执行add()，添加了数据
4. 线程B修改了size
5. 线程A修改size为0
还有一个情况是：
1. 线程A调用add函数，获得了head
2. 线程B调用clear()，修改了head
3. 线程A在已经过时的head上执行add()，添加了数据
4. 线程A修改size为0
5. 线程B将size增加1
随着运行时间越长，错误积累越大，所以clear必须是原子的。
重新检查add remove removeIf entryView clear函数及它们重载函数，为它们生成新的混合并发调用的测试用例，确认每一个函数必须是原子的，且整个ConcurrentSkipListMap必须是无锁并发安全。

# 任务4
1. **分层索引优化**：当前 MAX_LEVEL=16，对于小规模数据（< 65536）可能层数过多，可考虑动态调整 MAX_LEVEL。
2. **size_ 弱一致性**：当前使用 AtomicInt64 维护精确计数，每次 add/remove 都有 fetchAdd/fetchSub 开销。可改为惰性计算。
3. **findNode 数组分配优化**：每次 findNode 调用分配两个大小为 17 的 Array，可考虑线程局部缓存复用。

# 任务5
重新执行性能测试，
生成性能测试报告，保存到f_concurrent/doc/performance_report.md
按照潜在优化方向的重要程度做优化。
