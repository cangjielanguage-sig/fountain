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
package fountain::fmq.cli

import std.collection.*

/**
 * MQ CLI：SubCommand 'mqcli' 入口。
 * 交互模式：直接运行 `fboot mqcli`
 * 非交互模式：`fboot mqcli <command> [args...]`
 */
public class MqCliCommand <: SubCommand {

    static init() {
        SubCommandMediator.register(MqCliCommand())
    }

    private init() {}

    public prop command: String {
        get() { "mqcli" }
    }

    public func exec(args: Array<String>): Int64 {
        if (args.size == 0) {
            runInteractive()
            0
        } else {
            if (runCommand(args)) { 0 } else { 1 }
        }
    }

    /**
     * 交互模式：读取 stdin 循环执行命令。
     * 输入空行退出。
     */
    private func runInteractive(): Unit {
        println("MQ CLI (type 'help' for commands, empty line to exit)")
        println()
        while (true) {
            let line: ?String
            try {
                line = Some(readln())
            } catch (_: Exception) {
                println()
                break
            }
            if (let Some(l) <- line) {
                if (l == "") { break }
                let trimmed = l.trimAscii()
                if (trimmed == "") { continue }
                let args = trimmed.split(' ')
                // P3-2: 跳过空参数
                var filtered = ArrayList<String>()
                for (a in args) {
                    if (!a.isEmpty()) { filtered.add(a) }
                }
                if (filtered.size == 0) { continue }
                // P3-6: single O(n) pass from ArrayList to Array
                let finalArgs = Array<String>(filtered.size, repeat: "")
                for (i in 0..filtered.size) { finalArgs[i] = filtered[i] }
                runCommand(finalArgs)
            } else { break }
        }
    }

    /**
     * 单次执行命令。返回 true 表示命令执行成功，false 表示失败。
     */
    internal static func runCommand(args: Array<String>): Bool {
        if (args.size == 0) { return false }
        let cmd = args[0]
        let cmdArgs = args[1..]
        match (cmd) {
            case "help" => printHelp(); true
            case "createTopic" => CommandRunner.createTopic(cmdArgs)
            case "deleteTopic" => CommandRunner.deleteTopic(cmdArgs)
            case "createConsumerGroup" => CommandRunner.createConsumerGroup(cmdArgs)
            case "deleteConsumerGroup" => CommandRunner.deleteConsumerGroup(cmdArgs)
            case "listTopics" => CommandRunner.listTopics(cmdArgs)
            case "listConsumerGroups" => CommandRunner.listConsumerGroups(cmdArgs)
            case "listGroups" => CommandRunner.listGroups(cmdArgs)
            case "listConsumers" => CommandRunner.listConsumers(cmdArgs)
            case "resetOffset" => CommandRunner.resetOffset(cmdArgs)
            case "showTopic" => CommandRunner.showTopic(cmdArgs)
            case "showBrokers" => CommandRunner.showBrokers(cmdArgs)
            case "listDeadLetters" => CommandRunner.listDeadLetters(cmdArgs)
            case "redeliverDeadLetter" => CommandRunner.redeliverDeadLetter(cmdArgs)
            case "redeliverAllDeadLetters" => CommandRunner.redeliverAllDeadLetters(cmdArgs)
            case _ => println("unknown command: ${cmd}. Try 'help'"); false
        }
    }

    /**
     * 打印帮助信息。
     */
    private static func printHelp(): Unit {
        println("MQ CLI commands:")
        println("  help — print this help")
        println("  createTopic --name <topic> --queues <N>")
        println("  deleteTopic --name <topic>")
        println("  createConsumerGroup --name <group> --topic <topic>")
        println("  deleteConsumerGroup --name <group> --topic <topic>")
        println("  listTopics")
        println("  listConsumerGroups")
        println("  listGroups --topic <topic>")
        println("  listConsumers --topic <topic>")
        println("  resetOffset --topic <t> --group <g> --offset <N> [--queue <N>]")
        println("  showTopic --name <topic>")
        println("  showBrokers")
        println("  listDeadLetters --topic <t> --queue <q>")
        println("  redeliverDeadLetter --topic <t> --queue <q> --messageId <id>")
        println("  redeliverAllDeadLetters --topic <t> --queue <q>")
    }
}
