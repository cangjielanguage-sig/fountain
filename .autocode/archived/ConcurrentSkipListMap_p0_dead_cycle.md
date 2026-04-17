# 前置任务
cd f_concurrent

# 任务
timeout 120 cjpm test --filter ConcurrentSkipListMap_conc_test 这个测试类的每个用例都有概率会长时间不结束，每个用例单独执行，多执行几次就会发生，一起执行一定会发生。应该是并发调用发生了死循环。

检查ConcurrentSkipListMap.cj，找到问题原因。尤其是add remove get 等函数的混合并发操作。

考虑到编译时间，命令超时时间不能太短，否则可能还没编译完就结束了。