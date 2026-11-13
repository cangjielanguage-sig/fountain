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

class FakeTransport <: EmbeddingTransport {
    public var response: EmbeddingResponse
    public var calls: Int64 = 0

    public init(response: EmbeddingResponse) {
        this.response = response
    }

    public func embed(text: String): EmbeddingResponse {
        calls++
        response
    }
}

func denseOf(dim: Int64, value: Float64): Array<Float64> {
    let values = Array<Float64>(dim, repeat: value)
    values
}

@Test
public class HttpEmbedderTest {

    @TestCase
    func testDenseDimensionMatches(): Unit {
        let transport = FakeTransport(EmbeddingResponse(denseOf(1024, 0.1f64)))
        let embedder = HttpEmbedder(transport)
        @Expect(embedder.embed('hi').size, 1024)
    }

    @TestCase
    func testDimensionMismatchRejected(): Unit {
        let transport = FakeTransport(EmbeddingResponse(denseOf(768, 0.1f64)))
        let embedder = HttpEmbedder(transport)
        var message = ''
        try{
            embedder.embed('hi')
        }catch(e: Exception){
            message = e.message
        }
        @Expect(message.contains('dimension mismatch'), true)
    }

    @TestCase
    func testSparseAndColbertPassThrough(): Unit {
        let sparse = HashMap<Int64, Float64>()
        sparse[42] = 0.7f64
        let colbert = [[0.1f64, 0.2f64]]
        let transport = FakeTransport(EmbeddingResponse(denseOf(1024, 0.0f64),
                                                        sparse: sparse, colbert: colbert))
        let embedder = HttpEmbedder(transport)

        @Expect(embedder.tokenize('hi').get(42).getOrThrow(), 0.7f64)
        @Expect(embedder.embedColbert('hi').size, 1)
    }
}
