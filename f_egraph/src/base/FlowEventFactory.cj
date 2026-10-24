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
package fountain::f_egraph.base

// 宏导入是文件级的（`design.md` §12.1）。
import fountain::f_jit.macros.*

/**
 * 脚本面的事件工厂（`design.md` D4/§7.2）。
 *
 * 事件构造器的 `data` 是 `Any`，脚本方言既不能表达 `Any` 形参也不做隐式转换，因此把
 * 「构造事件 / 读取载荷」收敛为 5 个静态函数，参数与返回只含 `String` 与宿主类型。
 */
@JitBind
public class FlowEventFactory {
    private init() {}

    public static func flowTaskEvent(category: String, tag: String, name: String,
        data: String): Event {
        TaskEvent(category: category, tag: tag, name: name, data: data)
    }

    public static func flowEndEvent(category: String, tag: String, data: String): Event {
        EndEvent(category: category, tag: tag, data: data)
    }

    public static func flowErrorEvent(category: String, tag: String, message: String): Event {
        ErrorEvent(category: category, tag: tag, message: message)
    }

    public static func flowDummyEvent(): Event {
        DummyEvent.instance
    }

    /** `data` 为 `String` 时返回其值；其它载荷与非 `DataEvent` 一律返回空串。 */
    public static func flowDataOf(event: Event): String {
        match (event) {
            case e: DataEvent =>
                match (e.data) {
                    case s: String => s
                    case _ => ""
                }
            case _ => ""
        }
    }
}
