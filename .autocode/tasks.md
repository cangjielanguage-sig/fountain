按照fsync/doc/*.md的文档开始开发fsync的功能。
开发计划每完成一步都要添加相应的测试用例、标记已完成的开发计划、提交代码、总结经验，然后继续下一步。

已完成：
- ✅ Step 1: 项目基础搭建 (cjpm.toml + imports.cj + SyncConfig)
- ✅ Step 2: 消息体 DataFields 定义 (SyncDataFormat: 6个@DataAssist类)
- ✅ Step 3: 一致性哈希环 (HashRing: TreeMap<UInt128, Int64>)
- ✅ Step 4: 节点管理 (NodeManager: 仲裁/路由/健康检查)
- ✅ Step 5: Watch管理 (WatchManager: 注册/通知/过期清理)
- ✅ Step 6: 服务端处理逻辑 (SyncHandler: Store操作/版本/适配器)
- ✅ Step 7: 服务端网络层 (SyncServer: f_net.Server封装)
- ✅ Step 10: 测试用例 (34个测试全部通过)

待开发：
- ⬜ Step 8: 客户端实现 (SyncClient: API + 故障转移)
- ⬜ Step 9: SyncCommand (SubCommand注册)