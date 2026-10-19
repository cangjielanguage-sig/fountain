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

import std.convert.*
import std.fs.*
import std.sync.{AtomicBool, AtomicInt64}
import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_data.*
import fountain::f_io.LogPosition
import fountain::f_mq.base.MQMessageRecord
import fountain::fmq.queue.QueueLog

@Test
class BackupStoreTest {
    @TestCase
    public func concurrentAppendsReuseSingleQueueLog(): Unit {
        let root = "/tmp/fmq_test_backup_store/concurrent"
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
        let root = "/tmp/fmq_test_backup_store/close-flush"
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
        let root = "/tmp/fmq_test_backup_store/close-race"
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
}
