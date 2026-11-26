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
package fountain::f_llm.loom

import fountain::f_jit.*

/**
 * 把 loom 的宿主能力注册进 f_jit。
 *
 * 注册后，**JIT 编译出的步骤源码可以按名字直接调用**：
 *
 * ```cangjie
 * let x = loomCallLlm("deepseek-flash", "system", "input")
 * let y = loomCallTool("webSearch", "{\"query\":\"…\"}")
 * let z = loomStore("knowledge", "search", "{\"q\":\"…\"}")
 * ```
 *
 * 实现方式：`PredefinedFunction` 用闭包包住 `LoomHostApi` 的转发，参数与返回值都是字符串，
 * 因此不需要把 `LLM` / `FunctionMediator` / `Stores` 这些宿主类暴露给 JIT 的类型系统。
 */
public class LoomJitBridge {
    private init() {
    }

    /** 幂等：重复安装会覆盖同名函数 */
    public static func install(compiler: Compiler): Unit {
        compiler.registerFunction(PredefinedFunction(
            'loomCallLlm',
            [LocalType.STRING, LocalType.STRING, LocalType.STRING],
            LocalType.STRING,
            { args => LoomHostApi.callLlm(textOf(args, 0), textOf(args, 1), textOf(args, 2)) }))
        compiler.registerFunction(PredefinedFunction(
            'loomCallTool',
            [LocalType.STRING, LocalType.STRING],
            LocalType.STRING,
            { args => LoomHostApi.callTool(textOf(args, 0), textOf(args, 1)) }))
        compiler.registerFunction(PredefinedFunction(
            'loomStore',
            [LocalType.STRING, LocalType.STRING, LocalType.STRING],
            LocalType.STRING,
            { args => LoomHostApi.callStore(textOf(args, 0), textOf(args, 1), textOf(args, 2)) }))
    }

    private static func textOf(args: Array<Any>, index: Int64): String {
        if(index >= Int64(args.size)){
            return ''
        }
        match(args[index] as String){
            case Some(value) => value
            case None => ''
        }
    }
}
