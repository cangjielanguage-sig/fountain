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

/** 模板替换与执行期快照的边界：单遍扫描、快照有上限 */
@Test
class LoomRenderPerf_test {
    private static func start(data: String): Event {
        StartEvent(category: 'loom', tag: 'render', name: 'start', data: data)
    }

    /** 多步输出一次性替换，且未命中的占位符原样保留 */
    @TestCase
    func testRenderReplacesAllKnownAndKeepsUnknown(): Unit {
        LoomHostApi.bind(RenderTestHost())
        try {
            let _ = LoomHostApi.taskEvent(start(''), 'a', 'AAA')
            let _ = LoomHostApi.taskEvent(start(''), 'b', 'BBB')
            let out = LoomHostApi.render('{a.output}|{b.output}|{start.output}|{c.output}', start('S'))
            @Expect(out, 'AAA|BBB|S|{c.output}')
        } finally {
            LoomHostApi.unbind()
        }
    }

    /** 事件没有数据时 `{start.output}` 保持原样（与旧 replace 语义一致） */
    @TestCase
    func testStartPlaceholderKeptWithoutData(): Unit {
        LoomHostApi.bind(RenderTestHost())
        try {
            let out = LoomHostApi.render('x{start.output}y', start(''))
            @Expect(out, 'x{start.output}y')
        } finally {
            LoomHostApi.unbind()
        }
    }

    /** 文本里的普通大括号（JSON 片段）不被动到 */
    @TestCase
    func testRenderLeavesJsonBracesAlone(): Unit {
        LoomHostApi.bind(RenderTestHost())
        try {
            let _ = LoomHostApi.taskEvent(start(''), 'a', 'AAA')
            let out = LoomHostApi.render('{"k":"{a.output}"}', start(''))
            @Expect(out, '{"k":"AAA"}')
        } finally {
            LoomHostApi.unbind()
        }
    }

    /** 快照有上限：超过 200 轮只留最近的 */
    @TestCase
    func testContextLogKeepsAtMostMaxTurns(): Unit {
        LoomContextLog.begin()
        try {
            for (index in 0..(LoomContextLog.MAX_TURNS + 30)) {
                LoomContextLog.record(LlmTurn('m', 'sys', 'in-${index}', 'out-${index}'))
            }
            let snapshot = LoomContextLog.snapshot()
            @Expect(Int64(snapshot.size), LoomContextLog.MAX_TURNS)
            @Expect(snapshot[snapshot.size - 1].input, 'in-${LoomContextLog.MAX_TURNS + 29}')
        } finally {
            LoomContextLog.clear()
        }
    }
}

/** 只为 bind 一个宿主：render 不依赖它的具体行为 */
class RenderTestHost <: LoomHost {
    public func render(template: String, e: Event): String {
        template
    }

    public func callTool(name: String, argsJson: String): String {
        argsJson
    }

    public func callLlm(model: String, system: String, input: String): String {
        input
    }
}
