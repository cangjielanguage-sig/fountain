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
package fountain::f_egraph

import fountain::f_jit.Compiler
import fountain::f_egraph.exception.GraphException

/**
 * 执行一段 `FlowLoader` 脚本（`design.md` §6、§7.3）。
 *
 * 每个元素是一个**无参脚本**：包裹为 `{ => <script> }` 后执行一次，执行过程完成一个流程的
 * 注册。f_jit 不支持空括号 `()`，因此**不追加哨兵表达式**：闭包返回类型取自块内最后一条
 * 表达式，脚本末条语句必须是 `Unit` 值（约定为 `flow.removeExceptCurrentTag()`）；
 * 末条不是 `Unit` 时 `call<Unit>([])` 的类型校验失败，初始化随之中止。
 *
 * 去空白后为空视为配置错误，抛 [GraphException]，不静默跳过。
 */
internal class FlowScriptRunner {
    static func run(compiler: Compiler, script: String): Unit {
        if (script.trimAscii().isEmpty()) {
            throw GraphException("flow script must not be blank")
        }
        let source = "{ =>\n" + script + "\n}"
        compiler.compile(source).call<Unit>([])
    }
}
