/*
    Copyright (c) [2022] [WuJingrun（吴京润）]
    fountain is licensed under Mulan PSL v2.
    You can use this software according to the terms and conditions of the Mulan PSL v2.
    You may obtain a copy of Mulan PSL v2 at:
            http://license.coscl.org.cn/MulanPSL2
    THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
    See the Mulan PSL v2 for more details.
 */
package f_process

import std.collection.{Map, HashMap}
import std.env.*
import std.fs.Path
import std.io.{InputStream, OutputStream}
import std.process.{Process, SubProcess, ProcessRedirect, launch}
import f_io.{asyncPipe, pipe}
import f_regex.*

public interface ExtendProcess {
    func piped(workingDirectory!: ?Path, environment!: ?Map<String, String>, stdIn!: InputStream, stdOut!: OutputStream,
        bufSize!: Int64, stdErr!: ProcessRedirect): Unit
    func piped(workingDirectory!: ?Path, environment!: ?Map<String, String>, stdIn!: InputStream, bufSize!: Int64,
        stdOut!: ProcessRedirect, stdErr!: ProcessRedirect): SubProcess
    func piped(workingDirectory!: ?Path, environment!: ?Map<String, String>, stdIn!: ProcessRedirect,
        stdOut!: ProcessRedirect, stdErr!: ProcessRedirect): (?SubProcess, ?SubProcess)
    func exec(workingDirectory!: ?Path, environment!: ?Map<String, String>, stdIn!: ProcessRedirect,
        stdOut!: ProcessRedirect, stdErr!: ProcessRedirect): SubProcess
    operator func |(next: SubProcess): SubProcess
    operator func |(next: String): SubProcess
}

extend String <: ExtendProcess {
    private func link(input: InputStream, output: OutputStream, bufsize: Int64) {
        asyncPipe(input: input, output: output, bufferSize: bufsize)
    }
    private prop enviromentVariables: Map<String, String> {
        get() {
            let vars = HashMap<String, String>()
            for ((k, v) in getVariables()) {
                vars[k] = v
            }
            vars
        }
    }
    public func piped(workingDirectory!: ?Path = getWorkingDirectory(),
        environment!: ?Map<String, String> = enviromentVariables, stdIn!: InputStream, stdOut!: OutputStream,
        bufSize!: Int64 = 4096, stdErr!: ProcessRedirect = Inherit): Unit {
        let tuple = piped(workingDirectory: workingDirectory, environment: environment, stdIn: Pipe, stdOut: Pipe,
            stdErr: stdErr)
        link(tuple[1].getOrThrow().stdOutPipe, stdOut, bufSize)
        link(stdIn, tuple[0].getOrThrow().stdInPipe, bufSize)
    }
    public func piped(workingDirectory!: ?Path = getWorkingDirectory(),
        environment!: ?Map<String, String> = enviromentVariables, stdOut!: OutputStream, bufSize!: Int64 = 4096,
        stdIn!: ProcessRedirect = Pipe, stdErr!: ProcessRedirect = Inherit): SubProcess {
        let tuple = piped(workingDirectory: workingDirectory, environment: environment, stdIn: stdIn, stdOut: Pipe,
            stdErr: stdErr)
        link(tuple[1].getOrThrow().stdOutPipe, stdOut, bufSize)
        tuple[0].getOrThrow()
    }
    public func piped(workingDirectory!: ?Path = getWorkingDirectory(),
        environment!: ?Map<String, String> = enviromentVariables, stdIn!: InputStream, bufSize!: Int64 = 4096,
        stdOut!: ProcessRedirect = Pipe, stdErr!: ProcessRedirect = Inherit): SubProcess {
        let tuple = piped(workingDirectory: workingDirectory, environment: environment, stdIn: Pipe, stdOut: stdOut,
            stdErr: stdErr)
        link(stdIn, tuple[0].getOrThrow().stdInPipe, bufSize)
        tuple[1].getOrThrow()
    }
    public func piped(workingDirectory!: ?Path = getWorkingDirectory(),
        environment!: ?Map<String, String> = enviromentVariables, stdIn!: ProcessRedirect = Pipe,
        stdOut!: ProcessRedirect = Pipe, stdErr!: ProcessRedirect = Inherit): (?SubProcess, ?SubProcess) {
        let cmd = this.trimAscii()
        var cur = 0
        let s = cmd.size
        var last = None<SubProcess>
        var first = None<SubProcess>
        while (cur < s) {
            let idx = cmd.indexOf("|", cur) ?? s
            func startup() {
                cmd[cur..idx]
                    .trimAscii()
                    .exec(
                        workingDirectory: workingDirectory,
                        environment: environment,
                        stdIn: if (cur == 0) {
                            stdIn
                        } else {
                            Pipe
                        },
                        stdOut: if (idx == s) {
                            stdOut
                        } else {
                            Pipe
                        },
                        stdErr: stdErr
                    )
            }
            last = if (let Some(p) <- last) {
                p | startup()
            } else {
                startup()
            }
            if (first.isNone()) {
                first = last
            }
            cur = idx + 1
        }
        (first, last)
    }
    public func exec(workingDirectory!: ?Path = getWorkingDirectory(),
        environment!: ?Map<String, String> = enviromentVariables, stdIn!: ProcessRedirect = Pipe,
        stdOut!: ProcessRedirect = Pipe, stdErr!: ProcessRedirect = Inherit): SubProcess {
        let command = this.trimAscii().split(' ', removeEmpty: true)
        launch(command[0], if (command.size > 1) {
            command[1..]
        } else {
            []
        }, workingDirectory: workingDirectory, environment: environment, stdIn: stdIn, stdOut: stdOut, stdErr: stdErr)
    }
    public operator func |(next: SubProcess): SubProcess {
        exec() | next
    }
    public operator func |(next: String): SubProcess {
        exec() | next.exec()
    }
}

public interface ExtendSubProcess {
    operator func |(next: SubProcess): SubProcess
    operator func |(next: String): SubProcess
}

extend SubProcess <: ExtendSubProcess {
    public operator func |(next: SubProcess): SubProcess {
        pipe(input: this.stdOutPipe, output: next.stdInPipe)
        next
    }
    public operator func |(next: String): SubProcess {
        this | next.exec()
    }
}
