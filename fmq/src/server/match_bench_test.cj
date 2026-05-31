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
@Configure[warmup: Duration.millisecond * 50, batchSize: 50]
public class MatchBench {
    private let matcher = ConsumerMatcher()

    public init() {
        // 注册 50 个不同消费者，交替使用 Exact/Glob/Prefix 模式
        for (i in 0..50) {
            let modeStr = match (i % 3) {
                case 0 => "Exact:/api/v${i}"
                case 1 => "Glob:/api/*"
                case _ => "Prefix:/order/"
            }
            let reg = ConsumerRegistration(
                consumerId: "bench-${i}", groupId: "group-${i % 10}",
                matchModeStr: modeStr,
                labels: None, dataFilter: None,
                lastHeartbeat: DateTime.now())
            matcher.register(reg)
        }
    }

    @Bench
    public func benchMatch(): Unit {
        let _ = matcher.matchTopic("/api/v1")
    }
}
