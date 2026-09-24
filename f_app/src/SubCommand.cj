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
package fountain::f_app

public interface SubCommand{
    /**
     * 子命令名，即fboot <subcommand> 
     */
    prop command: String
    /**
     * 执行
     */
    func exec(args: Array<String>): Int64
}

public struct SubCommandMediator {
    private static let commands = ConcurrentHashMap<String, (Array<String>) -> Int64>()
    public static func register(command: SubCommand){
        commands[command.command] = command.exec
    }
    private static func exec(command: String, args: Array<String>, recursive: Bool): Int64 {
        if(let Some(cmd) <- commands.get(command)){
            cmd(args)
        }else if (recursive){
            throw BootException('sub command must be count|run|workspace|cleanUpdate|build|count|version or ${commands.iterator().map{t => t[0]}.intersperse('|').fold(StringGenerator()){g, s=>g.append(s)}}, but current sub command is ${command} and args are ${args}')
        }else{
            load(args, true)
            exec(command, args, true)
        }
    }
    public static func exec(command: String, args: Array<String>): Int64 {
        exec(command, args, false)
    }
}