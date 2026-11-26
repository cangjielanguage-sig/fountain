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
package fountain::fprobe

import fountain::fprobe.config.{AgentSettings, SupervisorSettings}
import fountain::fprobe.runtime.{AgentRuntime, SupervisorBootstrap}

/**
 * fprobe 可执行文件入口。
 *
 * `agent` / `supervisor` / `supervisor resident` / `--help` 分发在这里完成；
 * 采集、拉取与 TUI 由后续任务接入对应子命令。
 */
main(args: Array<String>): Int64 {
    dispatch(args)
}

/** 生产分发：把真实启动路径交给可测的 `dispatchWith`。 */
func dispatch(args: Array<String>): Int64 {
    dispatchWith({=> runAgent()}, {resident => runSupervisor(resident)}, args)
}

/**
 * 可注入的分发实现。
 *
 * `agentFactory` 与 `supervisorFactory` 让用例断言「分支是否命中、返回码是否透传」，
 * 不需要真的启动采集或 TUI。
 */
func dispatchWith(agentFactory: () -> Int64, supervisorFactory: (Bool) -> Int64,
    args: Array<String>): Int64 {
    if (args.size == 0) {
        println(Usage.root())
        return 2
    }

    // 允许配置参数前置：`fprobe --probe_port=12325 agent`
    var commandIndex = -1
    for (i in 0..args.size) {
        if (!args[i].startsWith("-")) {
            commandIndex = i
            break
        }
    }
    if (commandIndex < 0) {
        if (wantsHelp(args)) {
            println(Usage.root())
            return 0
        }
        println(Usage.root())
        return 2
    }

    let command = args[commandIndex]
    match (command) {
        case "agent" =>
            if (wantsHelp(args)) {
                println(Usage.agent())
                return 0
            }
            agentFactory()
        case "supervisor" =>
            if (wantsHelp(args)) {
                println(Usage.supervisor())
                return 0
            }
            supervisorFactory(isResident(args, commandIndex))
        case _ =>
            println(Usage.root())
            2
    }
}

private func wantsHelp(args: Array<String>): Bool {
    for (arg in args) {
        if (arg == "--help" || arg == "-h") {
            return true
        }
    }
    false
}

private func isResident(args: Array<String>, commandIndex: Int64): Bool {
    if (commandIndex + 1 < args.size && args[commandIndex + 1] == "resident") {
        return true
    }
    false
}

/** agent 启动：先解析并校验配置，通过后才把端口映射给 RPC。 */
private func runAgent(): Int64 {
    let settings = AgentSettings.load()
    let errors = settings.validate()
    if (!errors.isEmpty()) {
        for (message in errors) {
            eprintln("fprobe agent: ${message}")
        }
        return 2
    }
    settings.apply()
    try {
        return AgentRuntime.prepare(settings).serve()
    } catch (e: Exception) {
        eprintln("fprobe agent: 启动失败: ${e.message}")
        1
    } catch (e: Error) {
        eprintln("fprobe agent: 启动失败: ${e.message}")
        1
    }
}

/** supervisor 启动：TTY 与 resident 模式共用同一份配置校验。 */
private func runSupervisor(resident: Bool): Int64 {
    let settings = SupervisorSettings.load()
    let errors = settings.validate()
    if (!errors.isEmpty()) {
        for (message in errors) {
            eprintln("fprobe supervisor: ${message}")
        }
        return 2
    }
    try {
        return SupervisorBootstrap.run(settings, resident)
    } catch (e: Exception) {
        eprintln("fprobe supervisor: 启动失败: ${e.message}")
        1
    } catch (e: Error) {
        eprintln("fprobe supervisor: 启动失败: ${e.message}")
        1
    }
}
