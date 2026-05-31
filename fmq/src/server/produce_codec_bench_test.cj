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
package fountain::fmq.server

import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_codec.default.DefaultCodec
import std.io.{ByteBuffer, SeekPosition}


@Test
@Configure[warmup: Duration.millisecond * 100, batchSize: 100]
public class ProduceCodecBench {
    private let labels = ArrayList<String>()
    private let payload: Array<Byte> = Array<Byte>(512, repeat: 0x12u8)

    public init() {
        labels.add("bench")
    }

    @Bench
    public func benchEncodeDecode(): Unit {
        let encoded = ProduceCodec.encode("/bench/topic", labels, payload)
        let _ = ProduceCodec.decode(encoded)
    }
}
