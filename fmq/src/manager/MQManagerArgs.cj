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
package fountain::fmq.manager

import std.collection.ArrayList
import fountain::f_config.Config

/**
 * 管理端参数：`[--server=host:port] <subcommand> [operands...]`，`--server` 可前置或后置。
 */
public struct MQManagerArgs {
    /** 目标服务地址；配置缺失时为空串（`run()` 会打印无法连接）。 */
    public let server: String
    public let command: String
    public let operands: Array<String>

    init(server: String, command: String, operands: Array<String>) {
        this.server = server
        this.command = command
        this.operands = operands
    }

    public static func parse(args: Array<String>): ?MQManagerArgs {
        var server = ""
        let tokens = ArrayList<String>()
        var i = 0i64
        while (i < args.size) {
            let arg = args[i]
            if (arg == "--help" || arg == "-h") {
                return None<MQManagerArgs>
            }
            if (arg.startsWith("--server=")) {
                server = arg["--server=".size..]
            } else if (arg == "--server") {
                i++
                if (i >= args.size) {
                    return None<MQManagerArgs>
                }
                server = args[i]
            } else {
                tokens.add(arg)
            }
            i++
        }
        if (tokens.size == 0) {
            return None<MQManagerArgs>
        }
        let command = tokens[0]
        let operands = tokens[1..].toArray()
        let valid = match (command) {
            case "registerTopic" => operands.size == 2 || operands.size == 3
            case "deleteTopic" => operands.size == 1
            case "registerSubscriber" => operands.size == 2
            case "deleteSubscribeGroup" => operands.size == 2
            case "listTopics" => operands.size == 0
            case "listSubscribeGroups" => operands.size == 1
            case "stats" => operands.size <= 1
            case _ => false
        }
        if (!valid) {
            return None<MQManagerArgs>
        }
        if (server.isEmpty()) {
            if (let Some(port) <- Config.getValue<UInt16>("mqServer_port")) {
                server = "127.0.0.1:${port}"
            }
        }
        Some(MQManagerArgs(server, command, operands))
    }

    public static func helpText(): String {
        """
Usage: fmq manager [--server=host:port] <subcommand> [args...]

子命令：
  registerTopic <topic> <queueNum> [delaying=1m1s]
                                         注册主题并分配队列；可选延迟投递（默认 0s）
  deleteTopic <topic>                    删除主题及其消息、订阅组、游标
  registerSubscriber <topic> <group>     注册订阅组
  deleteSubscribeGroup <topic> <group>   删除订阅组
  listTopics                             列出全部主题、队列分配与延迟
  listSubscribeGroups <topic>            列出主题下的订阅组
  stats [topic]                          查询节点级积压/延迟/投递/重投/死信指标

选项：
  --server=host:port   目标服务地址，可出现在子命令前后；
                       缺省读取 mqServer_port 并连接 127.0.0.1:<port>
  --help, -h           打印本帮助
"""
    }
}
