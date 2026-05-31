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
import std.fs.{Directory, remove}

/**
 * MqQueue.tryReadFromLog 单元测试。
 * 使用临时目录创建 SegmentedLog，验证 append + read + skip 的正确性。
 */

@Test
public class QueueWriterNoSlaveSyncTest {
    @TestCase
    public func testSyncToSlavesWithRegisteredSlaveNoQueue(): Unit {
        // 注册 slave 但不调用 startSyncThread → slaveSyncQueues 为空
        // syncToSlaves 应 log warning 而非崩溃
        let q = MqQueue("/test-p2-3", 0, "/tmp/fmqq_p23", 4096)
        let hosts = ArrayList<String>()
        hosts.add("slave1:7201")
        let config = MqConfig.forTest(dataDir: "/tmp/fmqq_p23", mqHosts: hosts)
        let rm = ReplicationManager(config)
        rm.promoteToMaster()
        rm.onSlaveOf("slave1")
        let writer = QueueWriter(q, config, replicationManager: rm)
        // 不调用 startSyncThread → slaveSyncQueues 无 "slave1" 条目
        writer.submit([0x01u8])
        // 启动 writer 运行会在 syncToSlaves 中触发 warning 路径
        let f = spawn { writer.run() }
        sleep(Duration.millisecond * 100)
        writer.close()
        f.get()
        @Assert(writer.isClosed())
        q.close()
        try {
            for (entry in Directory.readFrom("/tmp/fmqq_p23")) {
                try { remove(entry.path.toString()) } catch (_: Exception) {}
            }
            remove("/tmp/fmqq_p23")
        } catch (_: Exception) {}
    }
}
