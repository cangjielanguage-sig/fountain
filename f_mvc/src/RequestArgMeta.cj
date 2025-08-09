/*
    Copyright (c) [2022] [WuJingrun（吴京润）]
    fountain is licensed under Mulan PSL v2.
    You can use this software according to the terms and conditions of the Mulan PSL v2.
    You may obtain a copy of Mulan PSL v2 at:
            http://license.coscl.org.cn/MulanPSL2
    THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
    See the Mulan PSL v2 for more details.  
*/
package f_mvc

class RequestArgMeta {
    private let args = HashMap<String, ControllerFuncParam>()
    private func doExtract<T>(ctx: HttpContext, name: String, pattern: ?HttpRequestPathPatterns): ?T where T <: DataFields<T> {
        args[name].extract<T>(name, ctx, pattern.getOrThrow())
    }
    func extract<T>(ctx: HttpContext, name: String, pattern: ?HttpRequestPathPatterns): T where T <: DataFields<T> {
        doExtract<T>(ctx, name, pattern).getOrThrow()
    }
    func extract<T>(ctx: HttpContext, name: String, default: T, pattern: ?HttpRequestPathPatterns): T where T <: DataFields<T> {
        doExtract<T>(ctx, name, pattern) ?? default
    }
    func contains(name: String): Bool {
        args.contains(name)
    }

    operator func [](name: String): ControllerFuncParam {
        args[name]
    }
    operator func [](name: String, value!: ControllerFuncParam): Unit {
        args[name] = value
    }
    func add(all!: HashMap<String, ControllerFuncParam>): Unit {
        args.add(all: all)
    }
}