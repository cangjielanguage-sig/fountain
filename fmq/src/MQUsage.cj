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
package fountain::fmq

import fountain::fmq.config.MQConfig

/** 用法文本拼装。 */
public class MQUsage {
    /** 顶层用法：只列 server / manager。 */
    public static func root(): String {
        """
Usage: fmq <command> [options]

Commands:
  server    启动消息队列服务（阻塞运行）
  manager   执行管理命令（注册主题/订阅组、查看列表）

Run 'fmq server --help' or 'fmq manager --help' for details.
"""
    }

    /** `fmq server --help`：配置项 + 目录说明。 */
    public static func serverHelp(): String {
        """
Usage: fmq server [--help]

启动消息队列服务（阻塞运行），配置项：

${MQConfig.helpText()}
元数据存放在可执行文件目录下的 metas/；消息段与死信分别写入
mqServer_segmentedLogDir / mqServer_deadMsgDir。
"""
    }

    /** `fmq manager --help`：六个子命令与 --server。 */
    public static func managerHelp(): String {
        """
Usage: fmq manager [--server=host:port] <subcommand> [args...]

子命令：
  registerTopic <topic> <queueNum>       注册主题并分配队列
  deleteTopic <topic>                    删除主题及其消息、订阅组、游标
  registerSubscriber <topic> <group>     注册订阅组
  deleteSubscribeGroup <topic> <group>   删除订阅组
  listTopics                             列出全部主题与队列分配
  listSubscribeGroups <topic>            列出主题下的订阅组

选项：
  --server=host:port   目标服务地址，可出现在子命令前后；
                       缺省读取 mqServer_port 并连接 127.0.0.1:<port>
  --help, -h           打印本帮助
"""
    }
}
