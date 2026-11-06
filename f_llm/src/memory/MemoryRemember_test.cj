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
package fountain::f_llm.memory

import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*

import fountain::f_config.Config
import fountain::f_llm.loom.{LoomHostApi, LoomStoreGateway}
import fountain::f_llm.store.*

/** 记录网关调用，便于断言 remember 走了哪条路 */
class RememberRecorder {
    public var payloads: ArrayList<String> = ArrayList<String>()
}

@Test
public class MemoryRememberTest {
    /** 端到端：remember → 网关 → 内容族，默认 namespace=loom、kind=session */
    @TestCase
    func testRememberWritesThroughGateway(): Unit {
        let shared = InMemoryContentStore()
        let recorder = RememberRecorder()
        let gateway = LoomStoreGateway(shared, InMemoryMetaStore())
        LoomHostApi.installStore({
            kind, op, payload =>
                recorder.payloads.add('${kind}|${op}|${payload}')
                gateway.call(kind, op, payload)
        })
        try{
            Memory.remember('session-1', '用户偏好简洁回答')

            @Expect(recorder.payloads.size, 1)
            @Expect(recorder.payloads[0].contains('"namespace":"loom"'), true)
            @Expect(recorder.payloads[0].contains('"kind":"session"'), true)

            let records = shared.memory.list(0, 'loom', 0, 10)
            @Expect(records.size, 1)
            @Expect(records[0].title, 'session-1')
            @Expect(records[0].content, '用户偏好简洁回答')
        }finally{
            LoomHostApi.installStore({ kind, op, payload => '[]' })
        }
    }

    /** 调用方可指定命名空间与 kind */
    @TestCase
    func testRememberCustomNamespaceAndKind(): Unit {
        let recorder = RememberRecorder()
        LoomHostApi.installStore({
            kind, op, payload =>
                recorder.payloads.add('${kind}|${op}|${payload}')
                'id-1'
        })
        try{
            Memory.remember('s2', '摘要', namespace: 'work', kind: 'note')
            @Expect(recorder.payloads.size, 1)
            @Expect(recorder.payloads[0].contains('"namespace":"work"'), true)
            @Expect(recorder.payloads[0].contains('"kind":"note"'), true)
        }finally{
            LoomHostApi.installStore({ kind, op, payload => '[]' })
        }
    }
}
