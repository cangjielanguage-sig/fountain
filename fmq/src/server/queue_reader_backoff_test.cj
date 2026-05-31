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
import fountain::f_data.base.*
import std.sync.{AtomicInt64, AtomicBool}
import std.fs.*
import std.fs.removeIfExists


@Test
public class QueueReaderBackoffTest {
    @TestCase
    public func testQueueReaderConsumesAndCloses(): Unit {
        let dataDir = "/tmp/fmq_qr_test_${DateTime.now().toUnixTimeStamp().toMilliseconds()}"
        try { Directory.create(dataDir) } catch (_: Exception) {}
        let q = MqQueue("/test", 0, dataDir, 100)
        try {
            q.append(Array<Byte>(3, repeat: 1u8))
            q.append(Array<Byte>(3, repeat: 2u8))
            q.append(Array<Byte>(3, repeat: 3u8))
            q.sync()
            let reader = QueueReader(q)
            let future = spawn { reader.run() }
            // 等待 reader 消费 3 条消息并进入退避状态
            sleep(Duration.second * 2)
            // close() 后 reader 应在 100ms 内退出（分段 sleep 每 100ms 检查 closed）
            reader.close()
            future.get()
        } finally {
            q.close()
            removeIfExists(dataDir, recursive: true)
        }
    }
}
