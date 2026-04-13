+ 执行pwd，本文的所有相对路径都是相对于pwd的执行结果
+ 把"---"下面的内容按顺序分解、规划任务
+ 如果需要修改.cj文件的代码确认当前上下文存在./.autocode/reference/cj_syntax.md的内容，如果不存在就加载它
  - 如果有语法错误务必查阅这个文档
+ 如果需要元编程就加载./.autocode/reference/advanced_syntax.md
+ 查阅仓颉文档
  - 标准库std文档： /mnt/d/docs/work/cangjie/cangjie-doc/md/std
  - 扩展库stdx文档：/mnt/d/docs/work/cangjie/cangjie-doc/md/stdx
  - 由于调用API导致的编译错误，务必查阅文档
+ 每完成一个任务就执行一次`git add . && git commit -m "<本次修改摘要>"`
+ 如果上下文快饱和了立即对上下文提取关键内容。
+ 压缩上下文后：
  - 务必保留用户最后一条消息
  - 务必查看**TODO LIST**
  - 务必保留本文件“---”之前的全部内容
---

# 前置任务
(
这一段是给人读的，接下来要对ConcurrentSkipListMap生成性能测试报告。
但是测试用例太耗时了，所以在给智能体布置任务前先运行测试用例。
curdir=$(pwd)
cd f_concurrent
cjpm test --filter ConcurrentSkipListMap_test.test_perf* > ../.autocode/skip_list_perf.txt
cjpm test --filter ConcurrentSkipListMap_test.test_concurrent* >> ../.autocode/skip_list_perf.txt
cjpm test --filter ConcurrentSkipListMap_test.test_stress* >> ../.autocode/skip_list_perf.txt
)
加载`$curdir/.autocode/skip_list_perf.txt`，根据这个文件生成性能测试报告，将性能测试报告保存在`$curdir/f_concurrent/doc/performance_report.md`中。
如果智能没有在指定路径发现这个txt文件，务必告知用户，并立即停止任务。