✅ 1. f_net/src/test/*.cj 测试用例长时间不结束 — 已修复
   原因：Server.start() 是同步阻塞方法，直接调用会永久阻塞测试线程
   修复：将 server.start() 调用包装在 spawn {} 中
   附加修复：SocketParams.populate() 对已接受 socket 设置 bindToDevice 抛出 "already bound" 异常
   修复：仅在 bindToDevice_ 为 Some 时才设置

✅ 2. f_net WSL 限制 — 已调查
   - 无 WSL 特定限制阻碍 f_net 正常使用，TCP 集成测试在 WSL 下 2/2 通过
   - NAT 模式下绑定 0.0.0.0（已默认）或 127.0.0.1 即可；不能绑定 WSL VM IP（重启变化）
   - 所有 socket 选项（reuseAddress, noDelay, keepAlive 等）工作正常（WSL2 运行真实 Linux 内核）
   - Windows 主机通过 localhost 转发访问，NAT/Mirrored 模式均支持
   - 注意事项：Hyper-V 防火墙（Mirrored 模式）、~1024 socket 上限（仅 >1000 连接时）、端口保留冲突
