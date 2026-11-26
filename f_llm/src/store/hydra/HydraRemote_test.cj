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
package fountain::f_llm.store.hydra

import std.collection.*
import std.env.*
import std.time.DateTime
import std.unittest.*
import std.unittest.testmacro.*

import fountain::f_llm.store.*

/**
 * 远程 fhydra 与进程内 f_hydra 的行为对照。
 *
 * 需要先起 fhydra 并设置 `llm_hydraUrl` / `llm_hydraSecret`；
 * 未配置或服务不可达时打印 SKIP（不判失败），由 `fhydra/scripts/conformance.sh` 负责起服务。
 */
@Test
public class HydraRemoteConformanceTest {
    private static var dirSeq: Int64 = 0

    private func configured(): Bool {
        let url = getVariable('llm_hydraUrl') ?? ''
        let secret = getVariable('llm_hydraSecret') ?? ''
        !url.isEmpty() && !secret.isEmpty()
    }

    private func item(namespace: String, content: String): MemoryWrite {
        MemoryWrite(9, namespace, 'title-${content}', content, 'fact')
    }

    @TestCase
    func testRemoteMatchesInProcess(): Unit {
        if(!configured()){
            println('SKIP HydraRemoteConformanceTest: llm_hydraUrl/llm_hydraSecret not set')
            return
        }
        let namespace = 'conf-${DateTime.now().toUnixTimeStamp().toSeconds()}-${DateTime.now().nanosecond}'
        let remote = HydraMemoryRepository(HttpTransport())
        dirSeq++
        let local = HydraMemoryRepository(path: '/tmp/fllm-hydra-conf-${dirSeq}')

        assertSame(remote, local, namespace)
    }

    private func assertSame(remote: HydraMemoryRepository, local: HydraMemoryRepository,
                            namespace: String): Unit {
        let ops = [('alpha', [1.0f64, 0.0f64]), ('beta', [0.0f64, 1.0f64])]
        for((content, vector) in ops){
            remote.upsert(item(namespace, content), vector, vector)
            local.upsert(item(namespace, content), vector, vector)
        }

        let query = MemoryQuery(9, [namespace], [], 'q', topK: 5)
        let remoteHits = remote.searchDense(query, [0.0f64, 1.0f64], 5)
        let localHits = local.searchDense(query, [0.0f64, 1.0f64], 5)
        @Expect(remoteHits.size, localHits.size)
        @Expect(remoteHits[0].record.content, 'beta')
        @Expect(localHits[0].record.content, 'beta')

        let token = HashMap<Int64, Float64>()
        token[5] = 1.0f64
        remote.upsertSparse(remoteHits[0].record.id, 9, namespace, token)
        local.upsertSparse(localHits[0].record.id, 9, namespace, token)
        @Expect(remote.searchSparse(query, token, 5).size, 1)
        @Expect(local.searchSparse(query, token, 5).size, 1)

        @Expect(remote.list(9, namespace, 0, 10).size, 2)
        @Expect(local.list(9, namespace, 0, 10).size, 2)

        @Expect(remote.remove(9, remoteHits[0].record.id), true)
        @Expect(local.remove(9, localHits[0].record.id), true)
        @Expect(remote.get(9, remoteHits[0].record.id).isNone(), true)
        @Expect(local.get(9, localHits[0].record.id).isNone(), true)
    }
}
