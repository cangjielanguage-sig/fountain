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
package fountain::f_llm.store

import std.collection.ArrayList
import std.unittest.*
import std.unittest.testmacro.*

@Test
public class ColbertCodecTest {

    @TestCase
    func testRoundTripSingleVector(): Unit {
        let source = [[0.1f64, -0.25f64, 1.5f64]]
        let decoded = ColbertCodec.decode(ColbertCodec.encode(source))
        @Expect(decoded.size, 1)
        @Expect(decoded[0].size, 3)
        @Expect(decoded[0][0] > 0.099f64 && decoded[0][0] < 0.101f64, true)
        @Expect(decoded[0][1] < -0.249f64 && decoded[0][1] > -0.251f64, true)
        @Expect(decoded[0][2] > 1.499f64 && decoded[0][2] < 1.501f64, true)
    }

    @TestCase
    func testRoundTripMultipleVectors(): Unit {
        let source = ArrayList<Array<Float64>>()
        source.add([0.5f64, 0.5f64])
        source.add([-1.0f64, 2.0f64])
        let decoded = ColbertCodec.decode(ColbertCodec.encode(source.toArray()))
        @Expect(decoded.size, 2)
        @Expect(decoded[0].size, 2)
        @Expect(decoded[1][0] < -0.999f64 && decoded[1][0] > -1.001f64, true)
    }

    @TestCase
    func testEmptyVectors(): Unit {
        let decoded = ColbertCodec.decode(ColbertCodec.encode([]))
        @Expect(decoded.size, 0)
    }
}
