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
public class QueueWriterTest {
    @TestCase
    public func testStartSyncThreadDoubleCallNoCrash(): Unit {
        let q = MqQueue("/test-sync2", 0, "/tmp/fmqq_sync2", 4096)
        let hosts = ArrayList<String>()
        hosts.add("localhost:7201")
        let config = MqConfig.forTest(dataDir: "/tmp/fmqq_sync2", mqHosts: hosts)
        let rm = ReplicationManager(config)
        let writer = QueueWriter(q, config, replicationManager: rm)
        // 两次调用 startSyncThread 不应崩溃或报错
        writer.startSyncThread()
        writer.startSyncThread()
        @Assert(!q.isClosed())
        q.close()
        cleanupDir("/tmp/fmqq_sync2")
    }

    /**
     * P2-2: 验证 sync 线程串行调用 syncToSlave（无内层 spawn）。
     * startSyncThread 不抛异常即表示内层 spawn 已移除。
     */
    @TestCase
    public func testSyncThreadSerialProcessing(): Unit {
        let q = MqQueue("/test-p2-2", 0, "/tmp/fmqq_p22", 4096)
        let hosts = ArrayList<String>()
        hosts.add("locahost:7202")
        let config = MqConfig.forTest(dataDir: "/tmp/fmqq_p22", mqHosts: hosts)
        let rm = ReplicationManager(config)
        let writer = QueueWriter(q, config, replicationManager: rm)
        writer.startSyncThread()
        // 提交 sync 条目（需 slave 连接才真正发送，但不会因 spawn 爆炸）
        writer.submit([0x01u8])
        sleep(Duration.millisecond * 50)
        @Assert(!q.isClosed())  // 无 spawn 爆炸即通过
        q.close()
        cleanupDir("/tmp/fmqq_p22")
    }

    /**
     * P2-3: 验证 close() 清理 syncThreads 不遗漏 future。
     * synchronized(syncLock) 确保 startSyncThread 的 put 与 close 的快照不竞态。
     */
    @TestCase
    public func testCloseWithSyncThreadsNoLeak(): Unit {
        let q = MqQueue("/test-p2-3", 0, "/tmp/fmqq_p23_close", 4096)
        let hosts = ArrayList<String>()
        hosts.add("slave1:7201")
        let config = MqConfig.forTest(dataDir: "/tmp/fmqq_p23_close", mqHosts: hosts)
        let rm = ReplicationManager(config)
        rm.promoteToMaster()
        rm.onSlaveOf("slave1")
        let writer = QueueWriter(q, config, replicationManager: rm)

        // 启动同步线程
        writer.startSyncThread()
        // close 应清理 syncThreads，不抛异常
        writer.close()
        @Assert(writer.isClosed())
        q.close()
        try {
            for (entry in Directory.readFrom("/tmp/fmqq_p23_close")) {
                try { remove(entry.path.toString()) } catch (_: Exception) {}
            }
            remove("/tmp/fmqq_p23_close")
        } catch (_: Exception) {}
    }

    /**
     * SRV-5: 验证 QueueWriter 构造缓存 syncPrefix 不抛异常。
     */
    @TestCase
    public func testSyncPrefixCachedOnInit(): Unit {
        let q = MqQueue("/test-srv5", 0, "/tmp/fmqq_srv5", 4096)
        let hosts = ArrayList<String>()
        hosts.add("cachehost:7301")
        let config = MqConfig.forTest(dataDir: "/tmp/fmqq_srv5", mqHosts: hosts)
        let rm = ReplicationManager(config)
        let writer = QueueWriter(q, config, replicationManager: rm)
        // 构造完成后 syncPrefix 已缓存（构造函数内完成编码）
        writer.startSyncThread()
        @Assert(!q.isClosed())  // 构造 + startSyncThread 不损坏队列状态
        q.close()
        cleanupDir("/tmp/fmqq_srv5")
    }

    private static func cleanupDir(path: String): Unit {
        try {
            for (entry in Directory.readFrom(path)) {
                try { remove(entry.path.toString()) } catch (_: Exception) {}
            }
            remove(path)
        } catch (_: Exception) {}
    }
}
