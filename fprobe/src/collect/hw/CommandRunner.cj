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
package fountain::fprobe.collect.hw

import std.process.*
import fountain::f_probe.{ProbeErrorCode, ProbeException}

/**
 * 一次外部命令执行结果。
 *
 * `error` 非空表示命令无法启动等工具级失败；`timedOut` 单独标记超时，
 * 二者都不与普通非零退出码混为一谈。
 */
public struct CommandResult {
    public let exitCode: Int64
    public let stdout: String
    public let stderr: String
    public let timedOut: Bool
    public let error: String

    public init(exitCode: Int64, stdout: String, stderr: String, timedOut: Bool, error: String) {
        this.exitCode = exitCode
        this.stdout = stdout
        this.stderr = stderr
        this.timedOut = timedOut
        this.error = error
    }

    public func succeeded(): Bool {
        exitCode == 0 && !timedOut && error.isEmpty()
    }
}

/**
 * 外部命令抽象。
 *
 * 参数必须以数组给出，禁止调用方拼 shell 字符串；带空白的参数一律拒绝。
 */
public interface CommandRunner {
    func run(command: Array<String>, timeoutMs!: Int64): CommandResult
}

/** 基于 `std.process` 的生产实现：参数数组直传，不经过 shell。 */
public class FProcessRunner <: CommandRunner {
    public init() {}

    public func run(command: Array<String>, timeoutMs!: Int64 = 3000): CommandResult {
        validate(command)
        let program = command[0]
        let arguments = if (command.size > 1) {
            command[1..]
        } else {
            Array<String>()
        }

        try {
            let process = launch(program, arguments, stdIn: ProcessRedirect.Discard,
                stdOut: ProcessRedirect.Pipe, stdErr: ProcessRedirect.Pipe)
            let pending = spawn {=> process.waitOutput() }
            try {
                let (exitCode, stdout, stderr) = pending.get(timeoutMs * Duration.millisecond)
                return CommandResult(exitCode, String.fromUtf8(stdout), String.fromUtf8(stderr), false, "")
            } catch (_: TimeoutException) {
                try {
                    process.terminate(force: true)
                } catch (_: Exception) {
                    ()
                }
                return CommandResult(-1, "", "", true, "命令执行超时（${timeoutMs}ms）")
            }
        } catch (e: Exception) {
            return CommandResult(-1, "", "", false, "无法执行命令 ${program}: ${e.message}")
        }
    }
}

private func validate(command: Array<String>): Unit {
    if (command.isEmpty()) {
        throw ProbeException(ProbeErrorCode.COLLECT, "命令不能为空")
    }
    for (argument in command) {
        if (argument.isEmpty()) {
            throw ProbeException(ProbeErrorCode.COLLECT, "命令参数不能为空字符串")
        }
        if (containsWhitespace(argument)) {
            throw ProbeException(ProbeErrorCode.COLLECT, '命令参数不能包含空白: "${argument}"')
        }
    }
}

private func containsWhitespace(value: String): Bool {
    value.contains(' ') || value.contains('\t') || value.contains('\n') || value.contains('\r')
}
