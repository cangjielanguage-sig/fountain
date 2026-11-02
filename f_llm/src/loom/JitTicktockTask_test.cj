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
import std.unittest.*
import std.unittest.testmacro.*

import fountain::f_egraph.base.*

/** 捕获任务体并允许手动触发一次的调度器 */
class ManualScheduler <: LoomScheduler {
    public var jobs: HashMap<String, () -> Unit> = HashMap<String, () -> Unit>()
    public var crons: HashMap<String, String> = HashMap<String, String>()

    public func schedule(name: String, cron: String, body: () -> Unit): Unit {
        jobs[name] = body
        crons[name] = cron
    }

    public func cancel(name: String): Unit {
        jobs.remove(name)
    }

    /** 测试用：手动跑一次 */
    public func fire(name: String): Unit {
        match(jobs.get(name)){
            case Some(body) => body()
            case None => ()
        }
    }
}

/** 记录调用的宿主 */
class CountingHost <: LoomHost {
    public var calls: Int64 = 0

    public func render(template: String, e: Event): String {
        template
    }

    public func callTool(name: String, argsJson: String): String {
        calls++
        argsJson
    }

    public func callLlm(model: String, system: String, input: String): String {
        input
    }
}

/** `JitTicktockTask`：把步骤闭包装成 () -> Unit */
@Test
class JitTicktockTask_test {
    private static func toolStep(): StepPlan {
        let step = StepPlan('sync', 'tool')
        step.tool = 'echo'
        step.args = '{"q":"hi"}'
        step
    }

    /** 触发时真的执行了步骤（宿主被调用一次），返回值被丢弃 */
    @TestCase
    func testFiresStepThroughHost(): Unit {
        let scheduler = ManualScheduler()
        let host = CountingHost()
        JitTicktockTask.create('sync-job', '0 0 9 * * * *', toolStep(), scheduler)
        @Expect(scheduler.crons.get('sync-job').getOrThrow(), '0 0 9 * * * *')

        LoomHostApi.bind(host)
        try{
            scheduler.fire('sync-job')
            @Expect(host.calls, 1)
            scheduler.fire('sync-job')
            @Expect(host.calls, 2)
        }finally{
            LoomHostApi.unbind()
        }
    }

    /** 步骤内部抛错不能穿透到调度线程 */
    @TestCase
    func testStepErrorIsSwallowed(): Unit {
        let scheduler = ManualScheduler()
        let step = StepPlan('bad', 'tool')
        step.tool = 'missing-tool'
        JitTicktockTask.create('bad-job', '0 0 9 * * * *', step, scheduler)

        LoomHostApi.bind(ThrowingHost())
        try{
            scheduler.fire('bad-job')   // 不应抛出
            @Expect(true, true)
        }finally{
            LoomHostApi.unbind()
        }
    }
}

class ThrowingHost <: LoomHost {
    public func render(template: String, e: Event): String {
        template
    }

    public func callTool(name: String, argsJson: String): String {
        throw IllegalStateException('tool failed')
    }

    public func callLlm(model: String, system: String, input: String): String {
        ''
    }
}
