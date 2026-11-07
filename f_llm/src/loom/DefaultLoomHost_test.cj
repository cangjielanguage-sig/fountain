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

@Test
class DefaultLoomHost_test {
    private func start(): Event {
        StartEvent(category: 'loom', tag: 'p', name: 'start', data: 'go')
    }

    @TestCase
    func testLlmGoesThroughInjectedChat(): Unit {
        let host = DefaultLoomHost({ model, system, input => '${model}|${system}|${input}' })
        @Expect(host.callLlm('chat-pro', 'sys', 'in'), 'chat-pro|sys|in')
    }

    @TestCase
    func testTemplateRendersPreviousStepOutput(): Unit {
        LoomHostApi.bind(DefaultLoomHost({ _, _, input => input }))
        try{
            let first = LoomHostApi.taskEvent(start(), 'fetch', 'A')
            let text = LoomHostApi.render('sum: {fetch.output}', first)
            @Expect(text, 'sum: A')
            @Expect(LoomHostApi.valueOf('fetch'), 'A')
        }finally{
            LoomHostApi.unbind()
        }
    }

    @TestCase
    func testTemplateKeepsUnknownPlaceholder(): Unit {
        LoomHostApi.bind(DefaultLoomHost({ _, _, input => input }))
        try{
            @Expect(LoomHostApi.render('{missing.output}', start()), '{missing.output}')
        }finally{
            LoomHostApi.unbind()
        }
    }

    @TestCase
    func testValuesClearedBetweenRuns(): Unit {
        LoomHostApi.bind(DefaultLoomHost({ _, _, input => input }))
        LoomHostApi.taskEvent(start(), 'fetch', 'A')
        LoomHostApi.unbind()
        LoomHostApi.bind(DefaultLoomHost({ _, _, input => input }))
        @Expect(LoomHostApi.valueOf('fetch'), '')
        LoomHostApi.unbind()
    }
}
