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

import fountain::f_base.ExitCallbacks
import fountain::fmq.config.MQConfigException
import fountain::fmq.manager.{MQManager, MQManagerArgs}
import fountain::fmq.server.{MQServer, installExitHooks}

/**
 * fmq 可执行文件入口：`server` / `manager` / `--help` 分发。
 */
main(args: Array<String>): Int64 {
    dispatch(args)
}

/**
 * 可测的分发逻辑：
 * - `--help` / `-h`：打印用法，返回 0；
 * - 无参数 / 未知子命令：打印顶层用法，返回 2；
 * - `server`：阻塞运行服务；
 * - `manager`：解析参数并执行一次管理命令。
 */
func dispatch(args: Array<String>): Int64 {
    dispatchWith({=> runServer()}, {rest => runManager(rest)}, args)
}

/**
 * 可注入的分发实现：`serverFactory` / `managerFactory` 让启动路径可测（A68）。
 *
 * 生产入口 `dispatch` 只是把两个真实工厂传进来。
 */
func dispatchWith(serverFactory: () -> Int64, managerFactory: (Array<String>) -> Int64,
    args: Array<String>): Int64 {
    if (args.size == 0) {
        println(MQUsage.root())
        return 2
    }
    let command = args[0]
    if (command == "--help" || command == "-h") {
        println(MQUsage.root())
        return 0
    }
    if (command == "server") {
        if (wantsHelp(args)) {
            println(MQUsage.serverHelp())
            return 0
        }
        return serverFactory()
    }
    if (command == "manager") {
        if (wantsHelp(args)) {
            println(MQUsage.managerHelp())
            return 0
        }
        return managerFactory(args[1..])
    }
    println(MQUsage.root())
    2
}

/** 管理端子命令：解析参数并执行一次。 */
private func runManager(args: Array<String>): Int64 {
    match (MQManagerArgs.parse(args)) {
        case None =>
            println(MQManagerArgs.helpText())
            2
        case Some(value) => MQManager(value).run()
    }
}

private func runServer(): Int64 {
    var server: ?MQServer = None
    try {
        server = Some(MQServer())
    } catch (e: MQConfigException) {
        eprintln("fmq server: ${e.message}")
        return 2
    } catch (e: Exception) {
        eprintln("fmq server: ${e.message}")
        return 2
    }
    let instance = server.getOrThrow()
    // 只在 server 分支安装：manager / --help 不需要
    ExitCallbacks.toExitGracefully()
    installExitHooks(instance, {close => ExitCallbacks.atExit(0, close)})
    instance.run()
}

private func wantsHelp(args: Array<String>): Bool {
    for (arg in args) {
        if (arg == "--help" || arg == "-h") {
            return true
        }
    }
    false
}
