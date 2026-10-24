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

/** 手工注册的端到端用例：每个登记成员都要被真实脚本调用一次（`design.md` §9.3-3）。 */
class BindingTestTask <: Task {
    private let acceptable_: Array<String>
    private let body_: (Event) -> Event

    init(acceptableEvents: Array<String>, body: (Event) -> Event) {
        acceptable_ = acceptableEvents
        body_ = body
    }

    public prop name: String {
        get() {
            "binding-test"
        }
    }

    public prop acceptableEvents: Array<String> {
        get() {
            acceptable_
        }
    }

    public prop producingEvents: Array<String> {
        get() {
            [EventType.End.toString()]
        }
    }

    public func exec(e: Event): Event {
        body_(e)
    }
}

@Test
class JitManualBinding_test {
    private static func configuredCompiler(): Compiler {
        HostFieldTable.resetForTest()
        let compiler = Compiler(CompileOptions(DummyDiagnosticsSink()))
        JitHostRegistry.configure(compiler)
        compiler
    }

    private static func category(prefix: String): String {
        "${prefix}-${UUID.random().toHexString()}"
    }

    /** 编译失败时返回异常文本（含分类与提示），编译成功返回空串。 */
    static func compileError(compiler: Compiler, source: String): String {
        try {
            compiler.compile(source)
            ''
        } catch (e: SourceCompileException) {
            e.message
        }
    }

    /** 事件字段：`name`/`category`/`tag` 都能从脚本读到。 */
    @TestCase
    public func scriptReadsEventFields(): Unit {
        let compiler = JitManualBinding_test.configuredCompiler()
        let event: Event = EndEvent(category: "cat", tag: "v1", data: "ok")
        @Assert(compiler.compile("{ e: Event => e.name }").call<String>([event]),
            EventType.End.toString())
        @Assert(compiler.compile("{ e: Event => e.category }").call<String>([event]), "cat")
        @Assert(compiler.compile("{ e: Event => e.tag }").call<String>([event]), "v1")
    }

    /** `toString` 是 `Event` 唯一登记的方法。 */
    @TestCase
    public func scriptCallsEventToString(): Unit {
        let compiler = JitManualBinding_test.configuredCompiler()
        let event: Event = TaskEvent(category: "cat", tag: "v1", name: "n", data: "ok")
        let text = compiler.compile("{ e: Event => e.toString() }").call<String>([event])
        @Assert(text, event.toString())
    }

    /** 脚本实例化 `ImmediateFlow`，宿主侧拿到同一实例。 */
    @TestCase
    public func scriptConstructsImmediateFlow(): Unit {
        let compiler = JitManualBinding_test.configuredCompiler()
        let c = JitManualBinding_test.category("manual-ctor")
        let flow = compiler.compile('{ c: String => ImmediateFlow(c, "v1") }')
            .call<ImmediateFlow>([c])
        @Assert(flow.category, c)
        @Assert(flow.tag, "v1")
        flow.remove()
    }

    /** `registerStart` + `registerEnd` + `registerTask(Task)` 串起来能跑完一个流程。 */
    @TestCase
    public func scriptRegistersStartEndAndTask(): Unit {
        let compiler = JitManualBinding_test.configuredCompiler()
        let c = JitManualBinding_test.category("manual-task")
        let task = BindingTestTask(["created"], { _ => EndEvent(category: c, tag: "v1", data: "done") })
        let flow = compiler.compile("""
            { c: String, t: Task =>
                let flow = ImmediateFlow(c, "v1")
                flow.registerStart("created")
                flow.registerEnd()
                flow.registerTask(t)
                flow
            }
            """).call<ImmediateFlow>([c, task])
        let end = flow.start("go").get().get()
        @Assert(end.name, EventType.End.toString())
        flow.remove()
    }

    /** `registerError` 真实生效：任务返回 `ErrorEvent` 时抛出携带载荷的 `GraphException`。 */
    @TestCase
    public func scriptRegistersError(): Unit {
        let compiler = JitManualBinding_test.configuredCompiler()
        let c = JitManualBinding_test.category("manual-error")
        let task = BindingTestTask(["created"], { _ =>
            ErrorEvent(category: c, tag: "v1", message: "boom")
        })
        let flow = compiler.compile("""
            { c: String, t: Task =>
                let flow = ImmediateFlow(c, "v1")
                flow.registerStart("created")
                flow.registerError()
                flow.registerTask(t)
                flow
            }
            """).call<ImmediateFlow>([c, task])
        var message = ""
        try {
            flow.start("go")
        } catch (e: GraphException) {
            message = e.message
        }
        @Assert(message.contains("boom"), true)
        flow.remove()
    }

    /** `removeExceptCurrentTag` 清掉同 `category` 的其它 tag。 */
    @TestCase
    public func scriptRemovesOtherTags(): Unit {
        let compiler = JitManualBinding_test.configuredCompiler()
        let c = JitManualBinding_test.category("manual-clean")
        let older = ImmediateFlow(category: c, tag: "v0")
        let flow = compiler.compile("""
            { c: String =>
                let flow = ImmediateFlow(c, "v1")
                flow.removeExceptCurrentTag()
                flow
            }
            """).call<ImmediateFlow>([c])
        // 旧 tag 的 dispatcher 已被移除：`start` 取不到 dispatcher。
        var removed = false
        try {
            older.start("go")
        } catch (e: Exception) {
            removed = true
        }
        @Assert(removed, true)
        flow.remove()
    }

    /** `canBeRemoved` + `remove` 真实生效：移除后 `start` 取不到 dispatcher。 */
    @TestCase
    public func scriptCallsCanBeRemovedAndRemove(): Unit {
        let compiler = JitManualBinding_test.configuredCompiler()
        let c = JitManualBinding_test.category("manual-remove")
        let flow = compiler.compile("""
            { c: String =>
                let flow = ImmediateFlow(c, "v1")
                flow.canBeRemoved()
                flow.remove()
                flow
            }
            """).call<ImmediateFlow>([c])
        var removed = false
        try {
            flow.start("go")
        } catch (e: Exception) {
            removed = true
        }
        @Assert(removed, true)
    }

    /** 负向：`emit` 不在脚本面（`Any` 形参不登记）。 */
    @TestCase
    public func emitIsNotCallableFromScript(): Unit {
        let compiler = JitManualBinding_test.configuredCompiler()
        let message = JitManualBinding_test.compileError(compiler, """
            { c: String =>
                let flow = ImmediateFlow(c, "v1")
                flow.emit()
                flow
            }
            """)
        @Assert(message.contains("未注册方法「emit」"), true)
    }

    /** 负向：闭包重载 `registerTask(eventName, closure)` 不在脚本面。 */
    @TestCase
    public func closureOverloadIsNotCallableFromScript(): Unit {
        let compiler = JitManualBinding_test.configuredCompiler()
        let message = JitManualBinding_test.compileError(compiler, """
            { c: String, t: Task =>
                let flow = ImmediateFlow(c, "v1")
                flow.registerTask("created", t)
                flow
            }
            """)
        @Assert(message.contains("实参个数不符"), true)
        @Assert(message.contains("registerTask(HostObject)"), true)
    }

    /** 负向：`Event.data` 是 `Any`，不登记字段，脚本不可读。 */
    @TestCase
    public func eventDataIsNotReadableFromScript(): Unit {
        let compiler = JitManualBinding_test.configuredCompiler()
        let message = JitManualBinding_test.compileError(compiler, "{ e: Event => e.data }")
        @Assert(message.contains("未注册字段「data」"), true)
    }

    /** 负向：手工注册不合成 `$as$`，脚本不能对事件类型写 `as`。 */
    @TestCase
    public func castToEventSubtypeIsNotAllowed(): Unit {
        let compiler = JitManualBinding_test.configuredCompiler()
        let message = JitManualBinding_test.compileError(compiler, "{ e: Event => e as TaskEvent }")
        @Assert(message.contains("缺少转型判定函数"), true)
    }

    /** 负向：手工注册不合成 `$is$`，脚本不能对事件类型写 `is`。 */
    @TestCase
    public func typeTestOnEventSubtypeIsNotAllowed(): Unit {
        let compiler = JitManualBinding_test.configuredCompiler()
        let message = JitManualBinding_test.compileError(compiler, "{ e: Event => e is TaskEvent }")
        @Assert(message.size > 0, true)
    }
}

