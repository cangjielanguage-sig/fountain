/*
    Copyright (c) [2022] [WuJingrun（吴京润）]
    fountain is licensed under Mulan PSL v2.
    You can use this software according to the terms and conditions of the Mulan PSL v2.
    You may obtain a copy of Mulan PSL v2 at:
            http://license.coscl.org.cn/MulanPSL2
    THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
    See the Mulan PSL v2 for more details.
 */
package fboot

import std.env.getWorkingDirectory
import std.fs.*
import std.reflect.ModuleInfo
import std.regex.Regex
import std.time.DateTime
import fountain.base.OS
import fountain.bean.BeanFactory

main(args: Array<String>): Unit {
    match (args[0]) {
        case 'run' =>
            let start = DateTime.now()
            var idx = -1
            for (i in 1..args.size where !args[i].startsWith("--dylibPattern=")) {
                idx = i
                break
            }
            func extractPattern(){
                if (idx > 0) {
                    args[idx]['--dylibPattern='.size..]
                } else {
                    ''
                }
            }
            let pattern = Regex('^lib.*(${extractPattern()}.*)?$')
            let ext = match (OS.current) {
                case Windows => ".dll"
                case macOS => ".dylib"
                case _ => ".so"
            }
            let path = canonicalize(if (idx > 1) {
                Path(args[1])
            } else {
                getWorkingDirectory()
            })
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
            //todo 增加项目启动初始化代码，按照Config决定需要是否需要初始化mvc，完成mvc模块后才能添加mvc初始化代码
            //应当在mvc模块提供一个函数，函数内确认是否需要初始化mvc，如果需要就完成mvc初始化
            //此处只需要调用这个函数

            //orm 需要应用开发者显式注册数据库驱动及初始化事务切面，执行load函数时一定会加载初始化orm的动态链接库从而完成初始化
            //ticktock是自初始化，首次使用时完成初始化
            //其它模块是工具API没有专门的初始化API
            let end = DateTime.now()
            println('${path.fileName} is started in ${end - start}, now is ${end}')
        case _ => throw BootException('first command arg must be run, but current args are ${args}')
    }
}
