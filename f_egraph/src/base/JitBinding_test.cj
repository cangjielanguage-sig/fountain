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

import std.collection.HashSet
import std.reflect.TypeInfo
import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_jit.base.SourceCompileException

/**
 * `@JitBind` 的登记面（`design.md` §7.4、§9.3）。
 *
 * 1.6 先钉住「该手工注册的类型不能有注解」；2.5 再补 `Task`/`ClosureTask`/`FlowEventFactory`
 * 的正向断言。
 */
@Test
class JitBinding_test {
    /** 手工注册的类型不得出现在宏登记表里（防止有人回头加注解）。 */
    @TestCase
    public func manualTypesAreNotEnrolledByMacro(): Unit {
        for (name in ["Event", "DataEvent", "StartEvent", "EndEvent", "TaskEvent",
            "ErrorEvent", "MultiEvent", "DummyEvent", "Emitter", "BaseFlow", "Flow",
            "ImmediateFlow", "AsyncFlow"]) {
            @Assert(JitBindSupport.enrolledOf(name).isEmpty(), true)
        }
    }

    private static func methodNames(b: JitBindings): HashSet<String> {
        let names = HashSet<String>()
        for (m in b.methods) {
            names.add(m.name)
        }
        names
    }

    private static func staticNames(b: JitBindings): HashSet<String> {
        let names = HashSet<String>()
        for (f in b.statics) {
            names.add(f.name)
        }
        names
    }

    private static func newCompiler(): Compiler {
        HostFieldTable.resetForTest()
        let c = Compiler(CompileOptions(DummyDiagnosticsSink()))
        JitHostRegistry.configure(c)
        c
    }

    /** 编译期望失败的脚本，返回错误消息（成功则返回空串）。 */
    private static func compileError(c: Compiler, source: String): String {
        try {
            let _ = c.compile(source)
            ''
        } catch (e: SourceCompileException) {
            e.message
        }
    }

    /** `Task` 接口的四条契约方法全部进宏登记表。 */
    @TestCase
    public func taskInterfaceEnrollsContractMethods(): Unit {
        let b = JitBindSupport.enrolledOf(TypeInfo.of<Task>().name)
        let ms = JitBinding_test.methodNames(b)
        @Assert(ms.size, 4)
        @Assert(ms.contains('name'), true)
        @Assert(ms.contains('acceptableEvents'), true)
        @Assert(ms.contains('producingEvents'), true)
        @Assert(ms.contains('exec'), true)
    }

    /**
     * `ClosureTask`：`compile` 进 `statics`，宿主专用 `initCompiler` 因 `@IgnoreJitBinding`
     * 不在其中（D10）。
     */
    @TestCase
    public func closureTaskStaticsExcludeInitCompiler(): Unit {
        let b = JitBindSupport.enrolledOf(TypeInfo.of<ClosureTask>().name)
        let statics = JitBinding_test.staticNames(b)
        @Assert(statics.size, 1)
        @Assert(statics.contains('compile'), true)
        @Assert(statics.contains('initCompiler'), false)
        @Assert(b.ignored.size, 1)
        @Assert(b.ignored[0], 'initCompiler')
    }

    /** `FlowEventFactory`：5 个 `flow*` 静态函数全部进宏登记表。 */
    @TestCase
    public func flowEventFactoryEnrollsFiveStatics(): Unit {
        let b = JitBindSupport.enrolledOf(TypeInfo.of<FlowEventFactory>().name)
        let statics = JitBinding_test.staticNames(b)
        @Assert(statics.size, 5)
        for (name in ["flowTaskEvent", "flowEndEvent", "flowErrorEvent", "flowDummyEvent",
            "flowDataOf"]) {
            @Assert(statics.contains(name), true)
        }
    }

    /** 端到端：脚本能调 `compile(...)`（静态名空间里只有一个 `compile`）。 */
    @TestCase
    public func scriptCallsCompile(): Unit {
        let c = JitBinding_test.newCompiler()
        let fn = c.compile('{ => compile("scripted", ["created"], ["End"], "e") }')
        let task = fn.call<ClosureTask>([])
        @Assert(task.name, 'scripted')
        @Assert(task.acceptableEvents[0], 'created')
    }

    /** 端到端：脚本能调 5 个 `flow*`。 */
    @TestCase
    public func scriptCallsFlowEventFactory(): Unit {
        let c = JitBinding_test.newCompiler()

        let taskEvent = c.compile('{ => flowTaskEvent("c", "v1", "validated", "payload") }')
            .call<Event>([])
        @Assert(taskEvent.eventType, EventType.Task)
        @Assert(taskEvent.category, 'c')
        @Assert(taskEvent.name, 'validated')

        let endEvent = c.compile('{ => flowEndEvent("c", "v1", "ok") }').call<Event>([])
        @Assert(endEvent.eventType, EventType.End)

        let errorEvent = c.compile('{ => flowErrorEvent("c", "v1", "boom") }').call<Event>([])
        @Assert(errorEvent.eventType, EventType.Error)

        let dummy = c.compile('{ => flowDummyEvent() }').call<Event>([])
        @Assert(dummy.eventType, EventType.Dummy)

        let data = c.compile('{ => flowDataOf(flowEndEvent("c", "v1", "ok")) }')
            .call<String>([])
        @Assert(data, 'ok')
    }

    /** 反向门禁：宿主专用静态入口不在脚本静态名空间里。 */
    @TestCase
    public func hostOnlyStaticsAreInvisibleToScripts(): Unit {
        let c = JitBinding_test.newCompiler()

        let initCompilerErr = JitBinding_test.compileError(c, '{ => initCompiler(1) }')
        @Assert(initCompilerErr.contains('initCompiler'), true)

        let initDispatcherErr = JitBinding_test.compileError(c, '{ => initDispatcher(1) }')
        @Assert(initDispatcherErr.contains('initDispatcher'), true)

        let instanceErr = JitBinding_test.compileError(c, '{ d: DummyEvent => d.instance }')
        @Assert(instanceErr.size > 0, true)
    }
}
