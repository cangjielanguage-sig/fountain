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

import std.collection.*

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
    /** 已执行步骤的输出：`{id.output}` 模板从这里取值 */
    private static var values = HashMap<String, String>()

    private init() {
    }

    public static func bind(host: LoomHost): Unit {
        current = Some(host)
        values = HashMap<String, String>()
    }

    public static func unbind(): Unit {
        current = None
        values = HashMap<String, String>()
    }

    /**
     * 模板替换：把 `{stepId.output}` 换成该步骤已产出的数据。
     *
     * 未命中的占位符原样保留——让模型/开发者看到「这里没取到值」，比静默替换成空串好排错。
     */
    public static func render(template: String, e: Event): String {
        var text = template
        for((name, value) in values){
            text = text.replace('{${name}.output}', value)
        }
        text
    }

    public static func callTool(name: String, argsJson: String): String {
        match(current){
            case Some(host) => host.callTool(name, argsJson)
            case None => throw LoomException('loom host is not bound, cannot call tool: ${name}')
        }
    }

    public static func callLlm(model: String, system: String, input: String): String {
        match(current){
            case Some(host) => host.callLlm(model, system, input)
            case None => throw LoomException('loom host is not bound, cannot call llm: ${model}')
        }
    }

    /**
     * 生成事件：f_jit 不支持命名实参，所以由宿主代建 `TaskEvent`。
     *
     * 同时把输出记进 `values`，供后续步骤的 `{id.output}` 模板取值。
     */
    public static func taskEvent(e: Event, name: String, data: Any): Event {
        values[name] = textOf(data)
        TaskEvent(category: e.category, tag: e.tag, name: name, data: data)
    }

    /** 供测试/诊断：某步骤当前记录的输出 */
    public static func valueOf(name: String): String {
        values.get(name) ?? ''
    }

    private static func textOf(data: Any): String {
        match(data as String){
            case Some(text) => text
            case None =>
                match(data as Int64){
                    case Some(number) => number.toString()
                    case None => ''
                }
        }
    }
}
