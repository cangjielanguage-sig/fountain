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

import fountain::f_data.JsonString
import fountain::f_llm.store.*

/** 记录调用次数的存储函数：验证工具与装配共用同一个入口 */
class CountingStore {
    public var calls: Int64 = 0

    public func call(kind: String, op: String, payload: String): String {
        calls++
        '[]'
    }
}

@Test
class LoomWiringGateway_test {
    /**
     * 收尾时装一个空存储，而不是 `resetStore()`：
     * 测试类并行执行，移除全局存储会让别的类看到「未安装」。
     */
    private static func quiet(): Unit {
        LoomHostApi.installStore({ kind, op, payload => '[]' })
        LoomStoreGateway.resetBuildCount()
    }

    /** 注入网关后：装配不再新建，三次调用都落到同一个实例 */
    @TestCase
    func testInjectedGatewayIsReused(): Unit {
        let shared = LoomStoreGateway(InMemoryContentStore(), InMemoryMetaStore())
        LoomStoreGateway.resetBuildCount()
        try{
            let _ = LoomWiring.wire({ _, _, _ => '{"status":"planned","steps":[],"edges":[]}' },
                store: MemoryLoomStore(), gateway: shared)
            @Expect(LoomStoreGateway.buildCount, 0)

            for (i in 0..3) {
                let list = LoomHostApi.callStore('memory', 'list',
                    '{"userId":0,"namespace":"loom","offset":0,"limit":5}')
                @Expect(list, '[]')
            }
            @Expect(LoomStoreGateway.buildCount, 0)
        }finally{
            quiet()
        }
    }

    /** memoryCall 走装配安装的存储函数，而不是自己新建网关 */
    @TestCase
    func testMemoryCallUsesInstalledStore(): Unit {
        let counter = CountingStore()
        LoomHostApi.installStore({ kind, op, payload => counter.call(kind, op, payload) })
        try{
            let param = MemoryCallParam()
            param.nextEvent = 'done'
            param.op = 'search'
            param.payload = '{"userId":0,"namespace":"loom","text":"x","limit":5}'
            let _ = MemoryCallFunction().call(param)
            @Expect(counter.calls, 1)
        }finally{
            quiet()
        }
    }

    /** knowledgeIngest 同样走装配安装的存储函数 */
    @TestCase
    func testKnowledgeIngestUsesInstalledStore(): Unit {
        let counter = CountingStore()
        LoomHostApi.installStore({ kind, op, payload => counter.call(kind, op, payload) })
        try{
            let param = KnowledgeIngestParam()
            param.nextEvent = 'done'
            param.docId = 'd1'
            param.title = 't'
            param.content = 'c'
            let _ = KnowledgeIngestFunction().call(param)
            @Expect(counter.calls, 1)
        }finally{
            quiet()
        }
    }
}
