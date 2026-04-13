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

# 前置任务
cd f_concurrent

# 任务1
ConcurrentSkipListMap 是否还有明显的性能优化空间？