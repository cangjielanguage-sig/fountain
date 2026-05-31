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
package fountain::fmq.client

import std.unittest.*
import std.unittest.testmacro.*
import std.random.*
import fountain::f_codec.default.DefaultCodec
import std.io.{ByteBuffer, SeekPosition}
import fountain::f_protocol.default.{Message as ProtocolMessage, EncodedMessage, MessageID}


@Test
public class SyncRegistryJitterTest {
    @TestCase
    public func testRandomJitterInRange(): Unit {
        for (_ in 0..100) {
            let jitter = Random().nextInt64(100)
            @Assert(jitter >= 0)
            @Assert(jitter < 100)
        }
    }

    @TestCase
    public func testRandomJitterProducesVaryingValues(): Unit {
        // 多次调用应有不同值（概率验证，失败概率极低）
        let first = Random().nextInt64(100)
        var allSame = true
        for (_ in 0..20) {
            if (Random().nextInt64(100) != first) {
                allSame = false
                break
            }
        }
        @Assert(!allSame)
    }
}
