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
package fountain::f_llm.embedding

import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*

/** 录制自本机服务（2026-10-31）的形状，维度缩小到 4 便于断言。 */
let BGE_FIXTURE = '''
{"object":"list","model":"bge-m3","data":[{"object":"embedding","index":0,
"embedding":[0.1,0.2,0.3,0.4],
"colbert_vecs":[[1.0,0.0,0.0,0.0],[0.0,1.0,0.0,0.0]],
"lexical_weights":{"101":0.5,"202":0.25}}],
"usage":{"prompt_tokens":6,"total_tokens":6}}
'''

@Test
public class BgeM3CodecTest {

    @TestCase
    func testParseThreeRoutes(): Unit {
        let response = BgeM3Codec.parse(BGE_FIXTURE)
        @Expect(response.dense.size, 4)
        @Expect(response.dense[2], 0.3f64)
        @Expect(response.sparse.size, 2)
        @Expect(response.sparse.get(101).getOrThrow(), 0.5f64)
        @Expect(response.colbert.size, 2)
        @Expect(response.colbert[0].size, 4)
    }

    @TestCase
    func testMissingOptionalFieldsAreEmpty(): Unit {
        let body = '{"data":[{"embedding":[1.0,2.0]}]}'
        let response = BgeM3Codec.parse(body)
        @Expect(response.dense.size, 2)
        @Expect(response.sparse.isEmpty(), true)
        @Expect(response.colbert.size, 0)
    }

    @TestCase
    func testThreeCallsReuseSingleTransportRequest(): Unit {
        let transport = FakeTransport(EmbeddingResponse(
            [0.1f64, 0.2f64, 0.3f64, 0.4f64],
            sparse: HashMap<Int64, Float64>([(7, 1.0f64)]),
            colbert: [[0.0f64, 1.0f64, 0.0f64, 0.0f64]]))
        let embedder = HttpEmbedder(transport, dim: 4)

        embedder.embed('same text')
        embedder.embedColbert('same text')
        embedder.tokenize('same text')
        @Expect(transport.calls, 1)
    }
}
