✅ 1. f_net/src/test/*.cj 测试用例长时间不结束 — 已修复
   原因：Server.start() 是同步阻塞方法，直接调用会永久阻塞测试线程
   修复：将 server.start() 调用包装在 spawn {} 中
   附加修复：SocketParams.populate() 对已接受 socket 设置 bindToDevice 抛出 "already bound" 异常
   修复：仅在 bindToDevice_ 为 Some 时才设置

2. f_net WSL 有什么限制
   暂无发现 WSL 特定的限制，TCP 集成测试在 WSL 下正常运行
