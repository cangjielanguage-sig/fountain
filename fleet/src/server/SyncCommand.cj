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
package fountain::fleet.server

import std.collection.ArrayList
import std.env.*
import std.posix.gethostname
import fountain::f_base.StringGenerator
import fountain::f_app.{SubCommand, SubCommandMediator}
import fountain::f_store.Store
import fountain::fleet.base.HostAndPort
import fountain::fleet.client.SyncClient
import fountain::fleet.config.SyncConfig

public class SyncCommand <: SubCommand {
    static init() {
        SubCommandMediator.register(SyncCommand())
    }
    internal init() {}

    public prop command: String {
        get() { 'fleet' }
    }

    public func exec(_: Array<String>): Int64 {
        // 1. 读取节点列表
        let hostsArr = SyncConfig.getHosts()
        if (hostsArr.size == 0) {
            eprintln('fleet_hosts is required')
            return 1
        }
        let hosts = ArrayList<HostAndPort>(hostsArr.size) { i => hostsArr[i] }
        let hostsStr = configString(hosts)

        // 2. 确定本地节点索引
        let localIndex = resolveLocalIndex(hosts)

        // 3. 初始化数据目录
        let dataPath = SyncConfig.getDataPath()

        // 4. 初始化组件
        let store = Store(dataPath)
        let nodeManager = NodeManager(hosts, localIndex)
        let watchManager = WatchManager()
        let handler = SyncHandler(store, nodeManager, watchManager, configHosts: hostsStr)
        let server = SyncServer(hosts[localIndex].port, queueSize: 1024)

        // 5. 启动服务
        server.start(handler)

        // 6. 在后台校验集群配置一致性
        let cfgHosts = hostsStr
        spawn {
            validateClusterConfig(cfgHosts, store, server, watchManager)
        }

        // 7. 阻塞主线程
        while (true) {
            sleep(Duration.second * 60)
        }

        return 0
    }

    /** 校验集群各节点的 fleet_hosts 配置是否一致 */
    private static func validateClusterConfig(localConfig: String, store: Store, server: SyncServer, watchManager: WatchManager): Unit {
        sleep(Duration.second)  // 等待其他节点启动
        try {
            let client = SyncClient.getInstance()
            // 获取所有节点列表
            for (i in 1..10) {  // 最多尝试 10 次
                if (let Some(configBytes) <- client.getBytes('__config__')) {
                    let peerConfig = String.fromUtf8(configBytes)
                    if (peerConfig != localConfig) {
                        eprintln('')
                        eprintln('====================================================')
                        eprintln('ERROR: Cluster configuration mismatch detected!')
                        eprintln('Local hosts:  ${localConfig}')
                        eprintln('Peer hosts:   ${peerConfig}')
                        eprintln('All server nodes must have the same fleet_hosts')
                        eprintln('order. The current process will now exit.')
                        eprintln('====================================================')
                        eprintln('')
                        try { store.close() } catch (_: Exception) {}
                        try { server.close() } catch (_: Exception) {}
                        try { watchManager.close() } catch (_: Exception) {}
                        exit(1)
                    }
                    return  // 验证通过
                }
                sleep(Duration.second * 3)
            }
        } catch (_: Exception) {
            // 节点不可达，跳过验证
        }
    }

    /** 将节点列表编码为配置比较字符串 */
    private static func configString(hosts: ArrayList<HostAndPort>): String {
        let sb = StringGenerator()
        for (i in 0..hosts.size) {
            if (i > 0) { sb.append(',') }
            sb.append(hosts[i].host).append(':').append(hosts[i].port)
        }
        sb.toString()
    }

    /** 通过本地主机名匹配节点列表中的索引 */
    internal static func resolveLocalIndex(hosts: ArrayList<HostAndPort>): Int64 {
        let localName = try {
            gethostname()
        } catch (_: Exception) {
            return 0
        }
        for (i in 0..hosts.size) {
            if (hosts[i].host == localName || hosts[i].host == '127.0.0.1' || hosts[i].host == 'localhost') {
                return i
            }
        }
        0
    }
}