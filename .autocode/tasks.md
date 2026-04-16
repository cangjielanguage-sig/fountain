# 前置任务
cd f_concurrent

# 任务
cjpm test --filter ConcurrentSkipListMap_conc_test.test_size_consistency_under_concurrent_modifications*
多执行几次这个测试，有时候很快就结束了，有时候很长时间不结束，一定是有概率问题触发死循环。
继续检查ConcurrentSkipListMap.cj的代码