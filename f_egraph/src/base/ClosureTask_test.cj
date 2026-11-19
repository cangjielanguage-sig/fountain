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

import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_jit.base.SourceCompileException

/** `ClosureTask`：宿主注入闭包与 `compile` 两条构造路径（`design.md` §7.1）。 */
@Test
class ClosureTask_test {
    private static func category(prefix: String): String {
        "${prefix}-${UUID.random().toHexString()}"
    }

    /**
     * f_jit 的 LIST 运行时形态恒为 `ArrayList<Any>`，且仓颉泛型不协变：
     * 脚本传入的列表只能按 `ArrayList<Any>` 解包（`design.md` §7.1）。
     */
    private static func list(values: Array<String>): ArrayList<Any> {
        let out = ArrayList<Any>()
        for (v in values) {
            out.add(v)
        }
        out
    }

    /** 构造器与四个属性。 */
    @TestCase
    public func constructorAndProperties(): Unit {
        let task = ClosureTask("compile-me", ["created"], ["validated"], { e => e })
        @Assert(task.name, "compile-me")
        @Assert(task.acceptableEvents.size, 1)
        @Assert(task.acceptableEvents[0], "created")
        @Assert(task.producingEvents.size, 1)
        @Assert(task.producingEvents[0], "validated")
    }

    /** `exec` 返回注入执行体的结果。 */
    @TestCase
    public func execReturnsBodyResult(): Unit {
        let task = ClosureTask("t", ["created"], ["End"], { e =>
            EndEvent(category: e.category, tag: e.tag, data: e.name)
        })
        let out = task.exec(TaskEvent(category: "c", tag: "v1", name: "payload", data: "d"))
        @Assert(out.eventType, EventType.End)
        @Assert(out.name, EventType.End.toString())
    }

    /** `compile` 成功：任务体被执行器真实调用，返回事件原样透出。 */
    @TestCase
    public func compiledTaskExecutesBody(): Unit {
        ClosureTask.resetCompilerForTest()
        let task = ClosureTask.compile("identity", ClosureTask_test.list(["created"]),
            ClosureTask_test.list([EventType.End.toString()]), "e")
        @Assert(task.name, "identity")
        @Assert(task.acceptableEvents[0], "created")
        let input = TaskEvent(category: "c", tag: "v1", name: "created", data: "go")
        let out = task.exec(input)
        @Assert(out.eventType, EventType.Task)
        @Assert(out.name, "created")
    }

    /** `compile` 成功：任务体经 `FlowEventFactory` 返回结束事件。 */
    @TestCase
    public func compiledTaskBuildsEndEvent(): Unit {
        ClosureTask.resetCompilerForTest()
        let task = ClosureTask.compile("end", ClosureTask_test.list(["created"]),
            ClosureTask_test.list([EventType.End.toString()]),
            'flowEndEvent("c", "v1", flowDataOf(e))')
        let out = task.exec(TaskEvent(category: "c", tag: "v1", name: "created", data: "ok"))
        @Assert(out.eventType, EventType.End)
        @Assert(FlowEventFactory.flowDataOf(out), "ok")
    }

    /** 空白 `name` → `GraphException`。 */
    @TestCase
    public func blankNameIsRejected(): Unit {
        var message = ""
        try {
            ClosureTask.compile("  ", ClosureTask_test.list(["a"]), ClosureTask_test.list(["b"]), "e")
        } catch (e: GraphException) {
            message = e.message
        }
        @Assert(message.contains("name"), true)
    }

    /** 空事件列表 → `GraphException`。 */
    @TestCase
    public func emptyEventListsAreRejected(): Unit {
        var acceptableMessage = ""
        try {
            ClosureTask.compile("t", ArrayList<Any>(), ClosureTask_test.list(["b"]), "e")
        } catch (e: GraphException) {
            acceptableMessage = e.message
        }
        @Assert(acceptableMessage.contains("acceptableEvents"), true)

        var producingMessage = ""
        try {
            ClosureTask.compile("t", ClosureTask_test.list(["a"]), ArrayList<Any>(), "e")
        } catch (e: GraphException) {
            producingMessage = e.message
        }
        @Assert(producingMessage.contains("producingEvents"), true)
    }

    /** 列表元素必须都是 `String`，否则 `GraphException`（`design.md` §7.1）。 */
    @TestCase
    public func nonStringEventElementsAreRejected(): Unit {
        let acceptable = ArrayList<Any>()
        acceptable.add(42)
        var message = ""
        try {
            ClosureTask.compile("t", acceptable, ClosureTask_test.list(["b"]), "e")
        } catch (e: GraphException) {
            message = e.message
        }
        @Assert(message.contains("String"), true)

        let producing = ArrayList<Any>()
        producing.add(true)
        var message2 = ""
        try {
            ClosureTask.compile("t", ClosureTask_test.list(["a"]), producing, "e")
        } catch (e: GraphException) {
            message2 = e.message
        }
        @Assert(message2.contains("String"), true)
    }

    /** 空白 `exec` → `GraphException`。 */
    @TestCase
    public func blankExecIsRejected(): Unit {
        var message = ""
        try {
            ClosureTask.compile("t", ClosureTask_test.list(["a"]), ClosureTask_test.list(["b"]), "  ")
        } catch (e: GraphException) {
            message = e.message
        }
        @Assert(message.contains("exec"), true)
    }

    /** 非法源码 → f_jit 编译异常，站点信息保留。 */
    @TestCase
    public func invalidSourceKeepsCompileSite(): Unit {
        ClosureTask.resetCompilerForTest()
        var line = 0
        try {
            ClosureTask.compile("t", ClosureTask_test.list(["a"]), ClosureTask_test.list(["b"]), "$$$")
        } catch (e: SourceCompileException) {
            line = e.line
        }
        @Assert(line > 0, true)
    }

    /** 未注入编译器时惰性创建（并完成宿主类型注册）。 */
    @TestCase
    public func lazyCompilerIsCreatedWhenNotInjected(): Unit {
        ClosureTask.resetCompilerForTest()
        let task = ClosureTask.compile("lazy", ClosureTask_test.list(["created"]),
            ClosureTask_test.list([EventType.End.toString()]), "e")
        let out = task.exec(TaskEvent(category: "c", tag: "v1", name: "created", data: "go"))
        @Assert(out.name, "created")
    }
}

