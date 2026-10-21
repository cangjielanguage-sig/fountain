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

import std.fs.*
import std.sync.{AtomicBool, AtomicInt64}
import std.time.DateTime
import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_data.*
import fountain::f_io.LogPosition
import fountain::f_mq.base.MQMessageRecord
import fountain::fmq.cluster.LogCleaner
import fountain::fmq.meta.MetaStore
import fountain::fmq.queue.{CursorCatalog, CursorStore, DeadLetterQueue, QueueLog, QueueManager}
import fountain::fmq.test.TestDirs

@Test
class BackupStoreTest {
    /** 关闭后写入被丢弃但必须留痕（含 topic/队列），且同秒内限流（R4-G3）。 */
    @TestCase
    public func appendsAfterCloseAreLoggedAndRateLimited(): Unit {
        CapturingAppender.install()
        let root = TestDirs.of("backup_store", "closed_log")
        if (exists(root)) {
            remove(root, recursive: true)
        }
        Directory.create(root, recursive: true)
        let store = BackupStore(root, 1024 * 1024, 1)
        store.append(0, "/closed-log", 0, [1u8])
        store.close()
        for (_ in 0..3) {
            store.append(0, "/closed-log", 0, [2u8])
        }
        @Assert(CapturingAppender.waitFor(["/closed-log", "dropped backup append", "closed"]))
        // 1 秒限流：连续 3 次只留 1 条
        @Assert(CapturingAppender.find(["/closed-log", "dropped backup append"]).size == 1)
        remove(root, recursive: true)
    }

    /** 底层 QueueLog 被并发关闭时，`LogClosedException` 不得静默（R4-G3）。 */
    @TestCase
    public func closedQueueLogIsLoggedInsteadOfSilentDrop(): Unit {
        CapturingAppender.install()
        let root = TestDirs.of("backup_store", "closed_queue_log")
        if (exists(root)) {
            remove(root, recursive: true)
        }
        Directory.create(root, recursive: true)
        let store = BackupStore(root, 1024 * 1024, 1)
        store.append(0, "/closed-ql", 0, [1u8])
        // 直接关掉底层日志，模拟「关闭与写入并发」
        for ((_, _, _, log) in store.allLogs()) {
            log.close()
        }
        store.append(0, "/closed-ql", 0, [2u8])
        @Assert(CapturingAppender.waitFor(["/closed-ql", "dropped backup append", "closed concurrently"]))
        store.close()
        remove(root, recursive: true)
    }

    @TestCase
    public func concurrentAppendsReuseSingleQueueLog(): Unit {
        let root = TestDirs.of("backup_store", "concurrent")
        if (exists(root)) {
            remove(root, recursive: true)
        }
        Directory.create(root, recursive: true)
        let store = BackupStore(root, 1024 * 1024, 1)
        let done = AtomicInt64(0)
        let failures = AtomicInt64(0)
        let threads = 4
        let perThread = 25
        for (t in 0..threads) {
            spawn {
                try {
                    for (i in 0..perThread) {
                        let record = MQMessageRecord.encode("/t", [], "mid", "${t}-${i}".toData())
                        store.append(0, "/t", 0, record)
                    }
                } catch (_: Exception) {
                    failures.fetchAdd(1)
                }
                done.fetchAdd(1)
            }
        }
        var waited = 0
        while (done.load() < threads && waited < 500) {
            sleep(Duration.millisecond * 20)
            waited++
        }
        @Assert(done.load() == threads)
        @Assert(failures.load() == 0)
        // 同一 (owner, topic, queue) 只允许一个 QueueLog
        @Assert(store.instanceCount == 1)
        store.close()

        // 关闭后从最老段顺序读回：记录不交错、不丢失
        let readerLog = QueueLog("${root}/backup/0/%2Ft/0", 1024 * 1024, 1)
        let reader = readerLog.openRecordsFrom(LogPosition(1, 0))
        var count = 0
        while (true) {
            let item = reader.next()
            if (item.isNone()) {
                break
            }
            let content = MQMessageRecord.decode(item.getOrThrow()[0]).getOrThrow()
            @Assert(content.topic == "/t")
            @Assert(convert<String>(content.body.data).isSome())
            count++
        }
        reader.close()
        readerLog.close()
        @Assert(count == threads * perThread)
        if (exists(root)) {
            remove(root, recursive: true)
        }
    }

    @TestCase
    public func closeKeepsAcknowledgedWrites(): Unit {
        let root = TestDirs.of("backup_store", "close_flush")
        if (exists(root)) {
            remove(root, recursive: true)
        }
        Directory.create(root, recursive: true)
        let store = BackupStore(root, 1024 * 1024, 1)
        for (i in 0..10) {
            let record = MQMessageRecord.encode("/t", [], "mid", "v${i}".toData())
            store.append(0, "/t", 0, record)
        }
        store.close()

        let readerLog = QueueLog("${root}/backup/0/%2Ft/0", 1024 * 1024, 1)
        let reader = readerLog.openRecordsFrom(LogPosition(1, 0))
        var count = 0
        while (true) {
            match (reader.next()) {
                case Some(_) => count++
                case None => break
            }
        }
        reader.close()
        readerLog.close()
        @Assert(count == 10)
        if (exists(root)) {
            remove(root, recursive: true)
        }
    }

    @TestCase
    public func closeRacesWithConcurrentAppends(): Unit {
        let root = TestDirs.of("backup_store", "close_race")
        if (exists(root)) {
            remove(root, recursive: true)
        }
        Directory.create(root, recursive: true)
        let store = BackupStore(root, 1024 * 1024, 1)
        let stop = AtomicBool(false)
        let done = AtomicInt64(0)
        let failures = AtomicInt64(0)
        let threads = 4
        for (t in 0..threads) {
            spawn {
                var i = 0i64
                while (!stop.load()) {
                    try {
                        let record = MQMessageRecord.encode("/t", [], "mid", "${t}-${i}".toData())
                        store.append(0, "/t", 0, record)
                    } catch (_: Exception) {
                        failures.fetchAdd(1)
                    }
                    i++
                }
                done.fetchAdd(1)
            }
        }
        sleep(Duration.millisecond * 100)
        store.close()
        stop.store(true)
        var waited = 0
        while (done.load() < threads && waited < 500) {
            sleep(Duration.millisecond * 20)
            waited++
        }
        @Assert(done.load() == threads)
        @Assert(failures.load() == 0)
        @Assert(store.instanceCount == 0)
        @Assert(store.isClosed())

        // 关闭后的写入被静默丢弃，不重建 QueueLog
        let record = MQMessageRecord.encode("/t", [], "mid", "after-close".toData())
        store.append(0, "/t", 0, record)
        @Assert(store.instanceCount == 0)
        if (exists(root)) {
            remove(root, recursive: true)
        }
    }

    private static func samePosition(left: LogPosition, right: LogPosition): Bool {
        left.seq == right.seq && left.offset == right.offset
    }

    /** 备份队列参与 TTL 清理：有备份位点才回收，无位点全部保留（A66）。 */
    @TestCase
    public func cleanerReclaimsBackupSegmentsByCursor(): Unit {
        let root = TestDirs.of("backup_store", "cleanup_ttl")
        let queues = QueueManager("${root}/logs", 40, 1)
        let dead = DeadLetterQueue("${root}/dead", 40, 1)
        let store = BackupStore(root, 40, 1)
        try {
            for (i in 0..6) {
                store.append(0, "/t", 0, Array<Byte>(20, repeat: UInt8(i)))
            }
            let logs = store.allLogs()
            @Assert(logs.size == 1)
            let log = logs[0][3]
            let before = log.segments().size
            @Assert(before >= 3)

            let noCursor = LogCleaner(queues, dead, {_, _ => Int64.Max}, Duration.second * -1,
                Duration.hour * 72, backupLogs: {=> store.allLogs()},
                backupFloor: {owner, topic, queueIndex => store.cursorFloor(owner, topic, queueIndex)})
            try {
                @Assert(noCursor.cleanOnce(DateTime.now()) == 0)
            } finally {
                noCursor.close()
            }
            @Assert(log.segments().size == before)

            store.saveCursor(0, "/t", 0, "g", LogPosition(2, 0))
            let withCursor = LogCleaner(queues, dead, {_, _ => Int64.Max}, Duration.second * -1,
                Duration.hour * 72, backupLogs: {=> store.allLogs()},
                backupFloor: {owner, topic, queueIndex => store.cursorFloor(owner, topic, queueIndex)})
            try {
                @Assert(withCursor.cleanOnce(DateTime.now()) >= 1)
            } finally {
                withCursor.close()
            }
            @Assert(log.segments()[0].index == 2)
        } finally {
            store.close()
            queues.close()
            dead.close()
            remove(root, recursive: true)
        }
    }

    /** 位点缺失时保留全部段：`cursorFloor` 返回 1，清理器据此不删任何历史段（T25 的前置契约）。 */
    @TestCase
    public func cursorFloorIsOneWhenNoCursorExists(): Unit {
        let root = TestDirs.of("backup_store", "no_cursor")
        let store = BackupStore(root, 1024 * 1024, 1)
        try {
            store.append(0, "/t", 0, [1u8])
            @Assert(store.cursorFloor(0, "/t", 0) == 1)
            // 位点写入后才按真实段号回收
            store.saveCursor(0, "/t", 0, "g", LogPosition(2, 0))
            @Assert(store.cursorFloor(0, "/t", 0) == 2)
        } finally {
            store.close()
            remove(root, recursive: true)
        }
    }

    /** 重复批次幂等：同一批再送一次，位点不回退、日志实例不重复创建。 */
    @TestCase
    public func duplicateBatchKeepsCursorAndLogsStable(): Unit {
        let root = TestDirs.of("backup_store", "duplicate_batch")
        let store = BackupStore(root, 1024 * 1024, 1)
        try {
            let record = MQMessageRecord.encode("/t", [], "mid", "dup".toData())
            for (_ in 0..2) {
                store.append(0, "/t", 0, record)
                store.saveCursor(0, "/t", 0, "g", LogPosition(2, 8))
            }
            @Assert(samePosition(store.loadCursor(0, "/t", 0, "g").getOrThrow(), LogPosition(2, 8)))
            @Assert(store.cursorFloor(0, "/t", 0) == 2)
            @Assert(store.instanceCount == 1)
            @Assert(store.allLogs().size == 1)
        } finally {
            store.close()
            remove(root, recursive: true)
        }
    }

    @TestCase
    public func cursorsOnlyMoveForward(): Unit {
        let root = TestDirs.of("backup_store", "cursors")
        if (exists(root)) {
            remove(root, recursive: true)
        }
        Directory.create(root, recursive: true)
        let store = BackupStore(root, 1024 * 1024, 1)
        try {
            store.append(0, "/t", 0, [1u8])
            store.saveCursor(0, "/t", 0, "g", LogPosition(2, 8))
            @Assert(samePosition(store.loadCursor(0, "/t", 0, "g").getOrThrow(), LogPosition(2, 8)))
            // 回退请求被忽略
            store.saveCursor(0, "/t", 0, "g", LogPosition(1, 0))
            @Assert(samePosition(store.loadCursor(0, "/t", 0, "g").getOrThrow(), LogPosition(2, 8)))
            // 前进生效
            store.saveCursor(0, "/t", 0, "g", LogPosition(3, 0))
            @Assert(samePosition(store.loadCursor(0, "/t", 0, "g").getOrThrow(), LogPosition(3, 0)))
            @Assert(store.cursorFloor(0, "/t", 0) == 3)

            store.saveCursor(0, "/t", 0, "slow", LogPosition(1, 0))
            @Assert(store.cursorFloor(0, "/t", 0) == 1)

            let logs = store.allLogs()
            @Assert(logs.size == 1)
            @Assert(logs[0][0] == 0)
            @Assert(logs[0][1] == "/t")
            @Assert(logs[0][2] == 0)
        } finally {
            store.close()
            remove(root, recursive: true)
        }
    }

    /** 备份位点可读回，并作为重建消费游标的唯一来源（恢复场景的数据基础）。 */
    @TestCase
    public func backupCursorRebuildsConsumerCursor(): Unit {
        let root = TestDirs.of("backup_store", "cursor_rebuild")
        if (exists(root)) {
            remove(root, recursive: true)
        }
        Directory.create(root, recursive: true)
        let store = BackupStore(root, 1024 * 1024, 1)
        try {
            store.append(0, "/t", 0, [1u8])
            store.saveCursor(0, "/t", 0, "g", LogPosition(3, 40))
            let saved = store.loadCursor(0, "/t", 0, "g").getOrThrow()
            @Assert(samePosition(saved, LogPosition(3, 40)))

            // 恢复：备份位点写回游标目录后，目录（而非内存）就能给出 committed
            let cursorStore = CursorStore("${root}/metas")
            cursorStore.save("/t", 0, "g", saved)
            let meta = MetaStore("${root}/metas")
            meta.load()
            let catalog = CursorCatalog(cursorStore, meta)
            @Assert(samePosition(catalog.positionOf("/t", 0, "g").getOrThrow(), LogPosition(3, 40)))
        } finally {
            store.close()
            remove(root, recursive: true)
        }
    }
}
