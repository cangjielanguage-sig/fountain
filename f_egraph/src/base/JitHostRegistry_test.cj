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
import std.unittest.*
import std.unittest.testmacro.*

/**
 * `JitHostRegistry` 手工注册面（`design.md` §5.2 金线、§9.3 登记面门禁）。
 *
 * 0.3 阶段先覆盖两条可行性断言：脚本读事件字段、脚本构造流程并调用 `registerStart`。
 */
@Test
class JitHostRegistry_test {
    private static func newCompiler(): Compiler {
        HostFieldTable.resetForTest()
        Compiler(CompileOptions(DummyDiagnosticsSink()))
    }

    /** 0.3：手工描述符 + `HostFieldTable` 能让脚本读到 `e.name`。 */
    @TestCase
    public func scriptReadsEventName(): Unit {
        let compiler = JitHostRegistry_test.newCompiler()
        JitHostRegistry.configure(compiler)
        let fn = compiler.compile("{ e: Event => e.name }")
        let event: Event = EndEvent(category: "spike", tag: "v1", data: "ok")
        @Assert(fn.call<String>([event]), EventType.End.toString())
    }

    /** 0.3：脚本能构造 `ImmediateFlow` 并调用 `registerStart`，宿主随后可正常启动流程。 */
    @TestCase
    public func scriptConstructsImmediateFlowAndRegistersStart(): Unit {
        let compiler = JitHostRegistry_test.newCompiler()
        JitHostRegistry.configure(compiler)
        let fn = compiler.compile("""
            { =>
                let flow = ImmediateFlow("spike-flow", "v1")
                flow.registerStart("created")
                flow
            }
            """)
        let flow = fn.call<ImmediateFlow>([])
        @Assert(flow.category, "spike-flow")
        flow.registerEnd()
        flow.registerTask("created") { _ => EndEvent(category: "spike-flow", tag: "v1", data: "done") }
        let end = flow.start("go").get().get()
        @Assert(end.name, EventType.End.toString())
        flow.remove()
    }

    /** 0.5：两个流程类只登记一条 `registerTask`（`Task` 重载），不按名字折叠重载。 */
    @TestCase
    public func flowDescriptorsRegisterSingleRegisterTask(): Unit {
        let descs: Array<ClassDescriptor> = [
            JitHostRegistry.immediateFlowDescriptor(),
            JitHostRegistry.asyncFlowDescriptor()
        ]
        for (desc in descs) {
            let matched = ArrayList<PublicMethod>()
            for (m in desc.methods) {
                if (m.name == "registerTask") {
                    matched.add(m)
                }
            }
            @Assert(matched.size, 1)
            @Assert(matched[0].bind.name, "${desc.name}.registerTask")
            @Assert(matched[0].bind.paramTypes.size, 2)
            @Assert(matched[0].bind.paramTypes[0], LocalType.HOST_OBJECT)
            @Assert(matched[0].bind.paramTypes[1], LocalType.HOST_OBJECT)
        }
    }

    // ===== 1.1 登记面金线（`design.md` §5.2/§9.3）=====

    private static let EVENT_NAMES: Array<String> = [
        "Event", "DataEvent", "StartEvent", "EndEvent",
        "TaskEvent", "ErrorEvent", "MultiEvent", "DummyEvent"
    ]

    private static let EVENT_PARENTS: Array<String> = [
        "", "Event", "DataEvent,Event", "DataEvent,Event",
        "DataEvent,Event", "DataEvent,Event", "DataEvent,Event", "Event"
    ]

    private static let FLOW_METHOD_NAMES: Array<String> = [
        "canBeRemoved", "remove", "removeExceptCurrentTag", "registerStart",
        "registerEnd", "registerError", "registerTask"
    ]

    private static func configuredCompiler(): Compiler {
        let compiler = JitHostRegistry_test.newCompiler()
        JitHostRegistry.configure(compiler)
        compiler
    }

    private static func descriptorNamed(descs: Array<ClassDescriptor>, name: String): ClassDescriptor {
        for (desc in descs) {
            if (desc.name == name) {
                return desc
            }
        }
        throw GraphException("no descriptor named ${name}")
    }

    private static func methodNames(desc: ClassDescriptor): ArrayList<String> {
        let names = ArrayList<String>()
        for (m in desc.methods) {
            names.add(m.name)
        }
        names
    }

    /** 集合相等（元素个数 + 双向包含），避免依赖顺序。 */
    private static func sameSet(actual: ArrayList<String>, expected: ArrayList<String>): Bool {
        if (actual.size != expected.size) {
            return false
        }
        for (e in expected) {
            if (!actual.contains(e)) {
                return false
            }
        }
        true
    }

    private static func toList(values: Array<String>): ArrayList<String> {
        let list = ArrayList<String>()
        for (v in values) {
            list.add(v)
        }
        list
    }

    /** 8 个事件类、`Emitter`/`BaseFlow`/两个流程类/`Task` 都可解析。 */
    @TestCase
    public func allHostTypesAreRegistered(): Unit {
        let compiler = JitHostRegistry_test.configuredCompiler()
        for (name in JitHostRegistry_test.EVENT_NAMES) {
            @Assert(compiler.hasClass(name))
        }
        for (name in ["Emitter", "BaseFlow", "ImmediateFlow", "AsyncFlow", "Task"]) {
            @Assert(compiler.hasClass(name))
        }
    }

    /** 事件描述符的字段集合 = `{category, tag, name, session}`，索引 0–3、类型 4、不可变。 */
    @TestCase
    public func eventDescriptorsMatchGoldLineFields(): Unit {
        let descs = JitHostRegistry.eventDescriptors()
        @Assert(descs.size, JitHostRegistry_test.EVENT_NAMES.size)
        let expected = ["category", "tag", "name", "session"]
        for (desc in descs) {
            @Assert(desc.fields.size, expected.size)
            var i = 0
            while (i < expected.size) {
                @Assert(desc.fields[i].name, expected[i])
                @Assert(desc.fields[i].index, UInt16(i))
                @Assert(desc.fields[i].`type`, LocalType.STRING)
                @Assert(desc.fields[i].mutable, false)
                i++
            }
        }
    }

    /** 事件类的父链与 `Event.toString` 与 §5.2 完全相等。 */
    @TestCase
    public func eventDescriptorsMatchGoldLineParentsAndMethods(): Unit {
        let descs = JitHostRegistry.eventDescriptors()
        var index = 0
        while (index < JitHostRegistry_test.EVENT_NAMES.size) {
            let name = JitHostRegistry_test.EVENT_NAMES[index]
            let desc = JitHostRegistry_test.descriptorNamed(descs, name)
            let expectedParents = JitHostRegistry_test.EVENT_PARENTS[index]
            if (expectedParents.size == 0) {
                @Assert(desc.parents.size, 0)
            } else {
                let parts = expectedParents.split(",")
                @Assert(desc.parents.size, parts.size)
                var i = 0
                while (i < parts.size) {
                    @Assert(desc.parents[i], parts[i])
                    i++
                }
            }
            if (name == "Event") {
                @Assert(JitHostRegistry_test.methodNames(desc).size, 1)
                @Assert(desc.methods[0].name, "toString")
                @Assert(desc.methods[0].bind.name, "Event.toString")
                @Assert(desc.methods[0].bind.paramTypes.size, 1)
                @Assert(desc.methods[0].bind.paramTypes[0], LocalType.HOST_OBJECT)
                @Assert(desc.methods[0].bind.retType, LocalType.STRING)
            } else {
                @Assert(desc.methods.size, 0)
            }
            @Assert(desc.ctors.size, 0)
            index++
        }
    }

    /** `Emitter` 方法面为空；`BaseFlow` 与两个流程类的方法名集合恰好是 7 个。 */
    @TestCase
    public func flowDescriptorsMatchGoldLineMethods(): Unit {
        let emitter = JitHostRegistry.emitterDescriptor()
        @Assert(emitter.name, "Emitter")
        @Assert(emitter.isInterface, true)
        @Assert(emitter.fields.size, 0)
        @Assert(emitter.ctors.size, 0)
        @Assert(emitter.methods.size, 0)

        let baseFlow = JitHostRegistry.baseFlowDescriptor()
        @Assert(baseFlow.name, "BaseFlow")
        @Assert(baseFlow.isInterface, true)
        @Assert(JitHostRegistry_test.sameSet(JitHostRegistry_test.methodNames(baseFlow),
                JitHostRegistry_test.toList(JitHostRegistry_test.FLOW_METHOD_NAMES)), true)

        for (desc in [JitHostRegistry.immediateFlowDescriptor(), JitHostRegistry.asyncFlowDescriptor()]) {
            @Assert(desc.isInterface, false)
            @Assert(desc.parents.size, 1)
            @Assert(desc.parents[0], "BaseFlow")
            @Assert(JitHostRegistry_test.sameSet(JitHostRegistry_test.methodNames(desc),
                    JitHostRegistry_test.toList(JitHostRegistry_test.FLOW_METHOD_NAMES)), true)
            @Assert(desc.ctors.size, 1)
            @Assert(desc.ctors[0].params.size, 2)
            @Assert(desc.ctors[0].params[0], LocalType.STRING)
            @Assert(desc.ctors[0].params[1], LocalType.STRING)
            for (m in desc.methods) {
                @Assert(m.bind.name, "${desc.name}.${m.name}")
            }
        }

        // `registerStart` 的签名必须带事件名（`[14, 4]`），其余无参方法为 `[14]`。
        for (m in baseFlow.methods) {
            if (m.name == "registerStart") {
                @Assert(m.bind.paramTypes.size, 2)
                @Assert(m.bind.paramTypes[1], LocalType.STRING)
            } else if (m.name != "registerTask") {
                @Assert(m.bind.paramTypes.size, 1)
            }
        }
    }

    /** 全表绑定名唯一（`PublicMethod.bind.name` 是预定义函数表的键）。 */
    @TestCase
    public func methodBindNamesAreGloballyUnique(): Unit {
        let seen = HashSet<String>()
        for (desc in JitHostRegistry.eventDescriptors()) {
            for (m in desc.methods) {
                @Assert(seen.contains(m.bind.name), false)
                seen.add(m.bind.name)
            }
        }
        for (desc in [JitHostRegistry.emitterDescriptor(), JitHostRegistry.baseFlowDescriptor(),
            JitHostRegistry.immediateFlowDescriptor(), JitHostRegistry.asyncFlowDescriptor()]) {
            for (m in desc.methods) {
                @Assert(seen.contains(m.bind.name), false)
                seen.add(m.bind.name)
            }
        }
    }

    /**
     * 字段访问器只登记索引 0–3（`category`/`tag`/`name`/`session`），`data` 不在表中
     * （`design.md` §5.2、R3）。
     */
    @TestCase
    public func hostFieldTableExposesOnlyFourIndexes(): Unit {
        HostFieldTable.resetForTest()
        JitHostRegistry.registerEventFields()
        let e = TaskEvent(category: "c", tag: "t", name: "n", data: "d")
        let expected = ["c", "t", "n", e.session]
        for (i in 0 .. 4) {
            let found = HostFieldTable.find(e, UInt16(i))
            @Expect(found.isSome(), true)
            let accessor = found.getOrThrow()
            @Assert(accessor.`type`, LocalType.STRING)
            @Assert(accessor.mutable, false)
            @Assert(accessor.getter(e) as String, Some(expected[i]))
        }
        // `data` 是 `Any`，不进描述符，也没有字段访问器。
        @Expect(HostFieldTable.find(e, UInt16(4)).isNone(), true)
    }

    /** 1.7：`registeredNames()` 只含手工绑定名，不含宏静态名（`initDispatcher`/`instance`）。 */
    @TestCase
    public func registeredNamesCoverManualBindingsOnly(): Unit {
        let compiler = JitHostRegistry_test.configuredCompiler()
        let names = compiler.registeredNames()
        let expected = ArrayList<String>()
        expected.add("Event.toString")
        for (prefix in ["BaseFlow", "ImmediateFlow", "AsyncFlow"]) {
            for (method in JitHostRegistry_test.FLOW_METHOD_NAMES) {
                expected.add("${prefix}.${method}")
            }
        }
        @Assert(names.size, expected.size)
        for (name in expected) {
            var found = false
            for (actual in names) {
                if (actual == name) {
                    found = true
                }
            }
            @Assert(found, true)
        }
        for (forbidden in ["initDispatcher", "instance", "compile"]) {
            var found = false
            for (actual in names) {
                if (actual == forbidden) {
                    found = true
                }
            }
            @Assert(found, false)
        }
    }
}
