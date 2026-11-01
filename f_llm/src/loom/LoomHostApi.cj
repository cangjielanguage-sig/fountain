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

import fountain::f_egraph.base.*

/**
 * 生成源码调用的静态宿主入口。
 *
 * 为什么不用 `host` 参数：JIT 编译的步骤闭包形参越少越好，`host` 作为接口参数
 * 需要额外注册；这里的静态入口在编译前绑定一次，生成的代码只依赖类名。
 *
 * 约束：**单线程使用**。执行前 `bind`，执行完 `unbind`；并发流程需各自持有独立进程
 * 或改为显式传参（当前 loom 的执行模型是单流程串行）。
 */
public class LoomHostApi {
    private static var current: ?LoomHost = None

    private init() {
    }

    public static func bind(host: LoomHost): Unit {
        current = Some(host)
    }

    public static func unbind(): Unit {
        current = None
    }

    public static func render(template: String, e: Event): String {
        match(current){
            case Some(host) => host.render(template, e)
            case None => template
        }
    }

    public static func callTool(name: String, argsJson: String): String {
        match(current){
            case Some(host) => host.callTool(name, argsJson)
            case None => throw LoomException('loom host is not bound, cannot call tool: ${name}')
        }
    }

    /**
     * 生成事件：f_jit 不支持命名实参，所以由宿主代建 `TaskEvent`。
     *
     * 生成的步骤体只需要一次位置参数调用，编译期不依赖构造器的具名参数。
     */
    public static func taskEvent(e: Event, name: String, data: Any): Event {
        TaskEvent(category: e.category, tag: e.tag, name: name, data: data)
    }

    public static func callLlm(model: String, system: String, input: String): String {
        match(current){
            case Some(host) => host.callLlm(model, system, input)
            case None => throw LoomException('loom host is not bound, cannot call llm: ${model}')
        }
    }
}
