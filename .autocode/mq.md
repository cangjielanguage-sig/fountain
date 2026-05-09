已知问题（v2待实现）
  1. MqServer.start() 中 Server 是 struct，被 closure 按值捕获后调用 start() 在 "Socket is not bound" 的竞争条件（仅在首轮偶现）
  2. 完整 PING/PONG 双向通信需更深的 f_net 集成（响应编解码匹配）