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
package fountain::fprobe.config

import std.collection.{ArrayList, HashSet}
import fountain::f_config.Config
import fountain::fprobe.rpc.NodeEndpoint

/**
 * supervisor 子命令的运行期配置。
 *
 * `probe_nodes` 在加载期即解析为 `NodeEndpoint`；任何非法项都会进入错误列表，
 * 不会被静默跳过。
 */
public class SupervisorSettings {
    public var nodes: Array<NodeEndpoint> = []
    public var pollIntervalMs: Int64 = 5000
    public var nodeTimeoutMs: Int64 = 3000
    public var missingThreshold: Int64 = 2
    public var historyPoints: Int64 = 60

    private var errors = ArrayList<String>()

    private init() {}

    public static func load(): SupervisorSettings {
        let settings = SupervisorSettings()

        let specs = Config.getStringArray("probe_nodes")
        if (specs.isEmpty()) {
            settings.nodes = [defaultNode()]
        } else {
            let parsed = ArrayList<NodeEndpoint>()
            let names = HashSet<String>()
            for (spec in specs) {
                match (NodeEndpoint.parse(spec)) {
                    case Some(endpoint) =>
                        if (names.contains(endpoint.name)) {
                            settings.errors.add('probe_nodes 存在重复节点名 "${endpoint.name}"（${spec}）')
                        } else {
                            names.add(endpoint.name)
                            parsed.add(endpoint)
                        }
                    case None => settings.errors.add('probe_nodes 存在非法节点项 "${spec}"，格式应为 name@host:port')
                }
            }
            settings.nodes = parsed.toArray()
        }

        settings.pollIntervalMs = readInt("probe_pollIntervalMs", settings.pollIntervalMs, 1, settings.errors)
        settings.nodeTimeoutMs = readInt("probe_nodeTimeoutMs", settings.nodeTimeoutMs, 1, settings.errors)
        settings.missingThreshold = readInt("probe_missingThreshold", settings.missingThreshold, 1, settings.errors)
        settings.historyPoints = readInt("probe_historyPoints", settings.historyPoints, 1, settings.errors)

        settings
    }

    public func validate(): Array<String> {
        errors.toArray()
    }

    private static func defaultNode(): NodeEndpoint {
        NodeEndpoint("localhost", "127.0.0.1", 12323)
    }
}
