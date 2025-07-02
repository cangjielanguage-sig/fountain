/*
    Copyright (c) [2022] [WuJingrun（吴京润）]
    fountain is licensed under Mulan PSL v2.
    You can use this software according to the terms and conditions of the Mulan PSL v2.
    You may obtain a copy of Mulan PSL v2 at:
            http://license.coscl.org.cn/MulanPSL2
    THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
    See the Mulan PSL v2 for more details.
 */
package fountain

import std.collection.{HashMap, HashSet, Map}
import std.convert.*
import std.env.{getWorkingDirectory, getVariables, getCommand}
import std.fs.*
import std.process.{execute, findProcess, Process, ProcessException}
import std.reflect.ModuleInfo
import std.regex.Regex
import std.time.DateTime
import fountain.base.{OS, StringGenerator}
import fountain.bean.BeanFactory
import fountain.mvc.MVCStarter

public class App {
    private let args: Array<String>
    private var idx = -1
    private let path: Path
    private let ext: String
    private let libPathName: String
    private let delim: String

    public App(args: Array<String>, appHomeIsWorkingPath!: Bool = true, private let name!: String = '') {
        this.args = args
        for (i in 1..args.size where !args[i].startsWith("--dylibPattern=")) {
            idx = i
            break
        }
        path = canonicalize(
            if (idx > 1) {
                Path(args[1])
            } else if (appHomeIsWorkingPath) {
                getWorkingDirectory()
            } else {
                let p = canonicalize(Path(getCommand()))
                if (p.parent.fileName == 'bin') {
                    p.parent.parent
                } else {
                    p.parent
                }
            })
        (ext, libPathName, delim) = match (OS.current) {
            case Windows => (".dll", 'Path', ';')
            case macOS => (".dylib", 'DYLD_FALLBACK_LIBRARY_PATH', ':')
            case _ => (".so", 'LD_LIBRARY_PATH', ':')
        }
    }

    private func start(): Int64 {
        let libSet = HashSet<String>()
        let env = HashMap<String, String>(getVariables())
        let ldlibPath = StringGenerator(env.get(libPathName) ?? '')
        func genLibPath(path: Path): Unit {
            Directory.walk(path) {
                fi =>
                if (fi.isDirectory()) {
                    genLibPath(fi.path)
                } else if (fi.path.fileName.endsWith(ext) && let libpath <- fi.path.parent.toString() &&
                    !libSet.contains(libpath)) {
                    libSet.add(libpath)
                    if (ldlibPath.size > 0) {
                        ldlibPath.append(delim)
                    }
                    ldlibPath.append(libpath)
                }
                true
            }
        }
        genLibPath(path)
        env[libPathName] = ldlibPath.toString()
        run(args, env)
    }
    private func run(args: Array<String>, env: Map<String, String>) {
        args[0] = 'run'
        execute(getCommand(), args, workingDirectory: path, environment: env)
    }
    private func run(): Int64 {
        let start: DateTime = DateTime.now()
        func extractPattern() {
            if (idx > 0) {
                let p = args[idx]['--dylibPattern='.size..]
                if ((p.startsWith("'") && p.endsWith("'")) || (p.startsWith('"') && p.endsWith('"'))) {
                    return p[1..p.size - 1]
                }
                p
            } else {
                ''
            }
        }
        let pattern = Regex('^lib.*(${extractPattern()}.*)?$')
        func load(path: Path): Unit {
            Directory.walk(path) {
                fi =>
                if (fi.isDirectory()) {
                    load(fi.path)
                } else if (pattern.matches(fi.path.fileNameWithoutExtension)) {
                    ModuleInfo.load(fi.path.toString().replace(ext, ''))
                }
                true
            }
        }
        load(path)
        BeanFactory.instance.afterRegistered()
        let mvc = MVCStarter.initialize()
        //orm 需要应用开发者显式注册数据库驱动及初始化事务切面，
        //执行load函数时一定会加载初始化orm的动态链接库从而完成初始化
        //ticktock是自初始化，首次使用时完成初始化
        //其它模块是工具API没有专门的初始化API
        let app = if (name.size > 0) {
            name
        } else {
            path.fileName.toString()
        }
        let end = DateTime.now()
        println('${app} is started in ${end - start} on ${end}')
        mvc?.start()
        0
    }
    private func pid() {
        Int64.parse(args[1])
    }
    private func shutdown(): Int64 {
        //每个模块都注册了atExit，所以发送退出命令的时候都会执行atExit
        let pid = this.pid()
        shutdown(pid)
    }
    private func shutdown(pid: Int64): Int64 {
        shutdown(findProcess(pid))
    }
    private func shutdown(process: Process): Int64 {
        process.terminate()
        0
    }
    private func restart(): Int64 {
        let pid = this.pid()
        let process = findProcess(pid)
        let args = process.arguments
        let env = process.environment
        shutdown(process)
        while (true) {
            try {
                findProcess(pid)
            } catch (_: ProcessException) {
                break
            }
        }
        run(args, env)
    }
    public func boot(): Int64 {
        match (args[0]) {
            case 'start' => start()
            case 'run' => run()
            case 'shutdown' => shutdown()
            case 'restart' => restart()
            case _ => throw BootException('first command arg must be run, but current args are ${args}')
        }
    }
}
