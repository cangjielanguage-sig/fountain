/*
Copyright (c) 2026 WuJingrun（吴京润）

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/
package fountain::fsync.server

import std.collection.ArrayList
import std.convert.*
import fountain::f_app.{SubCommand, SubCommandMediator}
import fountain::f_store.Store
import fountain::fsync.base.HostAndPort
import fountain::fsync.config.SyncConfig

public class SyncCommand <: SubCommand {
    static init() {
        SubCommandMediator.register(SyncCommand())
    }
    private init() {}

    public prop command: String {
        get() { 'sync' }
    }

    public func exec(args: Array<String>): Int64 {
        // 1. 读取节点列表
        let hostsArr = SyncConfig.getHosts()
        if (hostsArr.size == 0) {
            eprintln('sync_hosts is required')
            return 1
        }
        let hosts = ArrayList<HostAndPort>(hostsArr.size) { i => hostsArr[i] }

        // 2. 解析本地节点索引（默认 0）
        let localIndex = parseLocalIndex(args, hosts.size)

        // 3. 初始化数据目录
        let dataPath = SyncConfig.getDataPath()

        // 4. 初始化组件
        let store = Store(dataPath)
        let nodeManager = NodeManager(hosts, localIndex)
        let watchManager = WatchManager()
        let handler = SyncHandler(store, nodeManager, watchManager)
        let server = SyncServer(hosts[localIndex].port, queueSize: 1024)

        // 5. 启动服务
        server.start(handler)

        // 6. 阻塞主线程
        while (true) {
            sleep(Duration.second * 60)
        }

        return 0
    }

    /** 从命令行参数解析本地节点索引 */
    private static func parseLocalIndex(args: Array<String>, hostCount: Int64): Int64 {
        for (arg in args) {
            if (arg.startsWith('--sync_localIndex=')) {
                let val = arg['--sync_localIndex='.size..]
                return Int64.parse(val)
            }
        }
        0
    }
}
