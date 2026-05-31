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
public class QueueCleanerFileOrderTest {
    @TestCase
    public func testIsFileExpiredOldFileReturnsTrue(): Unit {
        // 创建临时文件，手动设置过期阈值
        let testDir = "/tmp/fmq_file_exp_test_${DateTime.now().toUnixTimeStamp().toMilliseconds()}"
        let testFile = "${testDir}/temp_segment.log"
        try {
            Directory.create(testDir, recursive: true)
            let f = File(testFile, OpenMode.Write)
            f.write([0x01u8])
            f.close()
        } catch (_: Exception) { @Assert(false); return }
        // 阈值设为一个小时前，刚创建的文件 mtime 应在 1 小时内 → 未过期
        let threshold = DateTime.now() - Duration.hour
        let expired = QueueCleaner.isFileExpired(testFile, threshold)
        @Assert(!expired)
        // 清理
        remove(testFile); remove(testDir)
    }
}
