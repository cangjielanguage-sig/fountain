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

internal struct DataSyncer {
    internal static func start(): Unit {
         spawn{
            //todo 启动节点间数据同步，使用订阅命令同步数据
            let hosts = FleetServerConfig.hosts // 主机IP:PORT Array<String>
            //数据同步初始化时，服务端节点可能尚未完成初始化，注意同步客户端连接失败、同步失败等情况
         }
    }
}