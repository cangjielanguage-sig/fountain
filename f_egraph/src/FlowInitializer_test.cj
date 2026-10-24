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

import std.collection.ArrayList
import std.sync.Mutex
import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_bean.BeanFactory
import fountain::f_util.UUID
import fountain::f_jit.base.{JitException, SourceCompileException}
import fountain::f_egraph.exception.GraphException

/**
 * 测试用 `FlowLoader`：脚本内容由 `FlowInitializer_test.install` 在用例开始时替换，
 * 避免为每个场景注册一个新 bean（`BeanFactory.getFirst` 只取第一个匹配项）。
 */
class TestFlowLoader <: FlowLoader {
    static var scripts = ArrayList<String>()

    public func load(): ArrayList<String> {
        TestFlowLoader.scripts
    }
}

/** 默认 `initialize()` 即可，测试只关心 FlowLoader 的注入。 */
class TestFlowInitializer <: FlowInitializer {}

/**
 * `FlowInitializer` 的脚本初始化路径（`specs/f-egraph-flow-script`、`design.md` §6/§7.3）。
 */
@Test
class FlowInitializer_test {
    private static let installMtx = Mutex()
    private static var installed = false

    private static func category(prefix: String): String {
        "${prefix}-${UUID.random().toHexString()}"
    }

    private static func scriptsOf(values: Array<String>): ArrayList<String> {
        let out = ArrayList<String>()
        for (v in values) {
            out.add(v)
        }
        out
    }

    private static func install(values: ArrayList<String>): Unit {
        synchronized(installMtx) {
            TestFlowLoader.scripts = values
            if (!installed) {
                BeanFactory.instance.register<TestFlowLoader>({ => TestFlowLoader() })
                installed = true
            }
        }
    }

    /**
     * 一个「开始 → 任务（返回结束事件）→ 结束」脚本。
     *
     * 任务体用 `flowEndEvent` 构造载荷，验证 `ClosureTask.compile` 与事件工厂在同一脚本里可用；
     * `exec` 源码里的引号在脚本层是 `\"`（f_jit 转义），在宿主源码里是 `\\\"`。
     */
    private static func flowScript(kind: String, c: String, tag: String, data: String): String {
        let exec = "flowEndEvent(\\\"" + c + "\\\", \\\"" + tag + "\\\", \\\"" + data + "\\\")"
        "let flow = " + kind + "(\"" + c + "\", \"" + tag + "\")\n" +
        "flow.registerStart(\"created\")\n" +
        "flow.registerEnd()\n" +
        "flow.registerError()\n" +
        "let task = compile(\"validate\", [\"created\"], [\"End\"], \"" + exec + "\")\n" +
        "flow.registerTask(task)\n" +
        "flow.removeExceptCurrentTag()\n"
    }

    /** 名称与依赖（`specs/f-egraph-test-coverage`）。 */
    @TestCase
    public func nameAndDependencies(): Unit {
        let initializer = TestFlowInitializer()
        @Assert(initializer.name, "fountain::f_egraph")
        @Assert(initializer.dependencies.size, 1)
        @Assert(initializer.dependencies[0], "fountain::f_bean")
    }

    /**
     * 同步脚本：注册后，宿主用**新实例**即可启动并拿到结束事件。
     *
     * 新实例的 `startName` 为空，`start` 走 D11 的回退读取（dispatcher 记录的开始事件名）。
     */
    @TestCase
    public func syncScriptRegistersRunnableFlow(): Unit {
        let c = FlowInitializer_test.category("sync")
        FlowInitializer_test.install(FlowInitializer_test.scriptsOf([
            FlowInitializer_test.flowScript("ImmediateFlow", c, "v1", "ok")
        ]))
        TestFlowInitializer().initialize()

        let flow = ImmediateFlow(category: c, tag: "v1")
        let end = flow.start("go").get().get()
        @Assert(end.eventType, EventType.End)
        @Assert(FlowEventFactory.flowDataOf(end), "ok")
        flow.remove()
    }

    /** 两个脚本各自注册一个流程，互不影响（宿主新实例启动，D11）。 */
    @TestCase
    public func twoScriptsRegisterTwoFlows(): Unit {
        let c1 = FlowInitializer_test.category("multi-a")
        let c2 = FlowInitializer_test.category("multi-b")
        FlowInitializer_test.install(FlowInitializer_test.scriptsOf([
            FlowInitializer_test.flowScript("ImmediateFlow", c1, "v1", "a"),
            FlowInitializer_test.flowScript("ImmediateFlow", c2, "v1", "b")
        ]))
        TestFlowInitializer().initialize()

        let f1 = ImmediateFlow(category: c1, tag: "v1")
        let f2 = ImmediateFlow(category: c2, tag: "v1")
        @Assert(f1.start("go").get().get().category, c1)
        @Assert(f2.start("go").get().get().category, c2)
        f1.remove()
        f2.remove()
    }

    /** 空列表是合法输入。 */
    @TestCase
    public func emptyScriptListIsNoOp(): Unit {
        FlowInitializer_test.install(ArrayList<String>())
        TestFlowInitializer().initialize()
    }

    /** 空脚本 → `GraphException`，后续脚本不执行。 */
    @TestCase
    public func blankScriptFailsFast(): Unit {
        let c = FlowInitializer_test.category("blank")
        FlowInitializer_test.install(FlowInitializer_test.scriptsOf([
            "   \n  ",
            FlowInitializer_test.flowScript("ImmediateFlow", c, "v1", "never")
        ]))
        var message = ""
        try {
            TestFlowInitializer().initialize()
        } catch (e: GraphException) {
            message = e.message
        }
        @Assert(message.contains("blank"), true)

        // 第二个脚本未执行：流程只有构造期 Multi 任务，没有 StartExecutor。
        var startFailed = false
        try {
            let _ = ImmediateFlow(category: c, tag: "v1").start("go")
        } catch (e: Exception) {
            startFailed = true
        }
        @Assert(startFailed, true)
    }

    /** 非法源码 → f_jit 编译异常原样上抛。 */
    @TestCase
    public func invalidSourceThrowsCompileException(): Unit {
        // 第二个脚本在语法上合法，但一旦执行会抛 GraphException；断言只捕获到 SourceCompileException
        // 即证明初始化在第一个脚本失败后已中止。
        FlowInitializer_test.install(FlowInitializer_test.scriptsOf([
            "$$$",
            "compile(\"x\", [\"a\"], [], \"flowDummyEvent()\")"
        ]))
        var failed = false
        try {
            TestFlowInitializer().initialize()
        } catch (e: SourceCompileException) {
            failed = true
        }
        @Assert(failed, true)
    }

    /**
     * 末句不是 `Unit` → `call<Unit>([])` 的类型校验失败，初始化中止。
     *
     * 不追加 `()` 哨兵后，闭包返回类型取自块内最后一条表达式；`compile(...)` 返回
     * `ClosureTask`，与 `call<Unit>` 的 `Unit` 不符。
     */
    @TestCase
    public func nonUnitLastStatementIsRejected(): Unit {
        FlowInitializer_test.install(FlowInitializer_test.scriptsOf([
            "compile(\"t\", [\"a\"], [\"b\"], \"flowDummyEvent()\")"
        ]))
        var message = ""
        var thrown = false
        try {
            TestFlowInitializer().initialize()
        } catch (e: JitException) {
            thrown = true
            message = e.message
        }
        @Assert(thrown, true)
        @Assert(message.contains("返回类型"), true)
    }

    /**
     * 异步脚本：宿主要先 `initDispatcher` 才能注册；注册后宿主新实例启动（D11），
     * 用 `tryGet(timeout:)` 等结束事件，失败时不会无限阻塞。
     *
     * 「未初始化」的失败路径由 `AsyncFlow_test.uninitializedDispatcherFailsConstruction`
     * 覆盖（`fountain::f_egraph.base` 包内才能调用测试用 reset；全局 dispatcher 一旦初始化
     * 就跨用例可见，放在这里会让结果依赖测试执行顺序）。
     */
    @TestCase
    public func asyncScriptRequiresInitDispatcher(): Unit {
        let c = FlowInitializer_test.category("async")
        AsyncFlow.initDispatcher()
        FlowInitializer_test.install(FlowInitializer_test.scriptsOf([
            FlowInitializer_test.flowScript("AsyncFlow", c, "v1", "ok")
        ]))
        TestFlowInitializer().initialize()

        let end = AsyncFlow(category: c, tag: "v1").start("go").tryGet(timeout: Duration.second)
        @Assert(end.isSome(), true)
        let event = end.getOrThrow().get()
        @Assert(event.eventType, EventType.End)
        @Assert(FlowEventFactory.flowDataOf(event), "ok")
    }

    /** 脚本末行 `removeExceptCurrentTag` 删除同 category 的旧 tag（宿主新实例启动，D11）。 */
    @TestCase
    public func removeExceptCurrentTagCleansOldTag(): Unit {
        let c = FlowInitializer_test.category("cleanup")
        FlowInitializer_test.install(FlowInitializer_test.scriptsOf([
            FlowInitializer_test.flowScript("ImmediateFlow", c, "v1", "old"),
            FlowInitializer_test.flowScript("ImmediateFlow", c, "v2", "new")
        ]))
        TestFlowInitializer().initialize()

        var oldRemoved = false
        try {
            let _ = ImmediateFlow(category: c, tag: "v1").start("go")
        } catch (e: Exception) {
            oldRemoved = true
        }
        @Assert(oldRemoved, true)
        @Assert(FlowEventFactory.flowDataOf(ImmediateFlow(category: c, tag: "v2").start("go")
            .get().get()), "new")
    }

    /** 两个脚本共用注入的编译器（`design.md` §8、R7），启动走宿主新实例（D11）。 */
    @TestCase
    public func scriptsShareInjectedCompiler(): Unit {
        let c1 = FlowInitializer_test.category("share-a")
        let c2 = FlowInitializer_test.category("share-b")
        FlowInitializer_test.install(FlowInitializer_test.scriptsOf([
            FlowInitializer_test.flowScript("ImmediateFlow", c1, "v1", "a"),
            FlowInitializer_test.flowScript("ImmediateFlow", c2, "v1", "b")
        ]))
        TestFlowInitializer().initialize()
        @Assert(FlowEventFactory.flowDataOf(ImmediateFlow(category: c1, tag: "v1").start("go")
            .get().get()), "a")
        @Assert(FlowEventFactory.flowDataOf(ImmediateFlow(category: c2, tag: "v1").start("go")
            .get().get()), "b")
    }

    /**
     * README 的迁移示例可原样执行（`tasks.md` 7.5）：两段 `compile`、`flowTaskEvent` 与
     * `flowEndEvent` 串成「校验 → 支付 → 结束」。
     */
    @TestCase
    public func readmeExampleScriptRuns(): Unit {
        let c = FlowInitializer_test.category("readme")
        let validateExec = "flowTaskEvent(\\\"" + c + "\\\", \\\"v1\\\", \\\"validated\\\", flowDataOf(e))"
        let payExec = "flowEndEvent(\\\"" + c + "\\\", \\\"v1\\\", flowDataOf(e))"
        let script = "let flow = ImmediateFlow(\"" + c + "\", \"v1\")\n" +
            "flow.registerStart(\"created\")\n" +
            "flow.registerEnd()\n" +
            "flow.registerError()\n" +
            "let validate = compile(\"validate\", [\"created\"], [\"validated\"], \"" + validateExec + "\")\n" +
            "flow.registerTask(validate)\n" +
            "let pay = compile(\"pay\", [\"validated\"], [\"End\"], \"" + payExec + "\")\n" +
            "flow.registerTask(pay)\n" +
            "flow.removeExceptCurrentTag()\n"
        FlowInitializer_test.install(FlowInitializer_test.scriptsOf([script]))
        TestFlowInitializer().initialize()

        let end = ImmediateFlow(category: c, tag: "v1").start("go").get().get()
        @Assert(end.eventType, EventType.End)
        @Assert(FlowEventFactory.flowDataOf(end), "go")
    }
}
