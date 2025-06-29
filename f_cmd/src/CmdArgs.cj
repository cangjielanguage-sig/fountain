/*
    Copyright (c) [2022] [WuJingrun（吴京润）]
    fountain is licensed under Mulan PSL v2.
    You can use this software according to the terms and conditions of the Mulan PSL v2.
    You may obtain a copy of Mulan PSL v2 at:
            http://license.coscl.org.cn/MulanPSL2
    THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
    See the Mulan PSL v2 for more details.  
*/
package f_cmd

import std.collection.{HashMap, ArrayList}
import std.convert.Parsable
import std.fs.Path
import std.env
import std.process.Process
import f_regex.*

import f_cmd.exception.CmdException

public class CmdArgs {
    private var args = HashMap<String, ArrayList<String>>()
    private var appName = env.getCommand()
    private var _currentWorkingDir = env.getWorkingDirectory()
    private init() {
        this(env.getCommandLine()[1 ..])
    }
    private init(args: Array<String>) {
        var prev = String.empty
        for (i in 0 .. args.size) {
            prev = String.empty
            let arg = args[i]
            if (arg.startsWith("--")) {
                let idxopt = arg.indexOf("=")
                if (let Some(idx) <- idxopt) {
                    let key = arg[2..idx].trimAscii()
                    if (idx == arg.size - 1) {
                        let val = arg[idx + 1 ..].trimAscii()
                        if(let Some(l) <- this.args.get(key)){
                            l.add(val)
                        }else{
                            let l = ArrayList<String>()
                            l.add(val)
                            this.args.add(key, l)
                        }
                    }
                    continue
                }
                throw CmdException('command arg starts with -- must match pattern as --key=value, but current is ${arg}')
            } else if (arg.startsWith("-")) {
                this.args[arg] = ArrayList<String>()
                prev = arg
            } else {
                this.args[prev].add(arg)
            }
        }
    }

    public static let instance = CmdArgs()

    public func getAllKeys(prefix: String): Array<String> {
        let list = ArrayList<String>()
        for (key in args.keys() where key.startsWith(prefix)) {
            list.add(key)
        }
        list.toArray()
    }
    public func contains(name: String): Bool {
        args.contains(name)
    }
    public func getArgs(name: String): Option<ArrayList<String>> {
        args.get(name)
    }
    public func getArg(name: String): Option<String> {
        if (let Some(list) <- getArgs(name)) {
            list.get(0)
        }
        None<String>
    }
    public func getAppName(): String {
        return appName
    }
    public prop currentWorkingDirectory: Path {
        get(){
            _currentWorkingDir
        }
    }
    public func getInt64Arg(name: String): Option<Int64> {
        if (let Some(v) <- getArg(name)) {
            Int64.parse(v)
        }
        None<Int64>
    }
}
