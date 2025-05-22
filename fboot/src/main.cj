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

import std.fs.Path
import std.reflect.ModuleInfo
import std.regex.Regex
import std.env.getWorkingDirectory

private func load(path: Path, pattern: Regex, ext: String) {
    Directory.walk(dir) {
        fi =>
        if (fi.isDirectory()) {
            load(fi.path, pattern, ext)
        } else if (pattern.matches(fi.path.fileName)) {
            ModuleInfo.load(fi.path.toString().replace(ext, ''))
        }
        true
    }
}

main(args: Array<String>): Unit {
    match (args[0]) {
        case 'run' =>
            var pattern = ''
            var idx = 1
            for (i in 1 .. args.size where !args[i].startsWith("--dylibPattern=")) {
                idx = i
                break
            }
            pattern = args[idx]['--dylibPattern='.size ..]
            let path = if (idx > 1) {
                canonicalize(args[1])
            } else {
                getWorkingDirectory()
            }
            var pathRegex = #'\.{0, 2}/(.+/)*(.+)?'#
            let ext = 
            match(OS.current){
                case Windows => 
                    pathRegex = #'([C-Z]:|\.\.?)(\\(.+))+'#
                    '.dll'
                case macOS => '.dylib'
                case _ => '.so'
            }
            if(!Regex(#'\.{0, 2}/(.+/)*(.+)?'#).matches(path)){
                throw BootException('fboot error: The path is not a directory, current arg is ${path}')
            }
            load(Path(path), Regex('^lib.*${pattern}.*\\${ext}$'), ext)
            //todo 增加项目启动初始化代码，按照Config决定需要是否需要初始化mvc，完成mvc模块后才能添加
            //应当在mvc模块提供一个函数，函数内确认是否需要初始化mvc，如果需要就完成mvc初始化
            //此处只需要调用这个函数
        case _ => throw BootException('first command arg must be run, but current args are ${args}')
    }
}
