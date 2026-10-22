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
package fountain::fmq.queue

import std.fs.*
import std.sync.AtomicInt64
import std.unittest.*
import std.unittest.testmacro.*
import fountain::fmq.meta.MQFileNames
import fountain::f_mq.base.payload.MQTopicAssignment
import fountain::fmq.test.TestDirs

@Test
class QueueManagerTest {
    /** 进程不再注册 `atExit`，整个类的临时目录在收尾时统一回收。 */
    @AfterAll
    static func removeTempDirs(): Unit {
        TestDirs.cleanNamespace("queue_manager")
    }

    private static func rootOf(name: String): String {
        TestDirs.of("queue_manager", name)
    }

    private static func clean(root: String): Unit {
        if (exists(root)) {
            remove(root, recursive: true)
        }
    }

    @TestCase
    public func onlyLocalQueuesAreCreated(): Unit {
        let root = rootOf("local")
        clean(root)
        let manager = QueueManager(root, 1024 * 1024, 1)
        try {
            let assignment = MQTopicAssignment("/t", 4, 0, [0, 1, 2, 0])
            manager.openTopic(assignment, 0)
            @Assert(manager.localQueues("/t").size == 2)
            @Assert(exists(MQFileNames.queueDir(root, "/t", 0)))
            @Assert(exists(MQFileNames.queueDir(root, "/t", 3)))
            @Assert(!exists(MQFileNames.queueDir(root, "/t", 1)))
            @Assert(!exists(MQFileNames.queueDir(root, "/t", 2)))
            @Assert(manager.allLogs().size == 2)
            // 重复打开不新增队列
            manager.openTopic(assignment, 0)
            @Assert(manager.localQueues("/t").size == 2)
        } finally {
            manager.close()
            clean(root)
        }
    }

    /** 8 线程同时打开同一主题只创建一组 QueueLog（A52）。 */
    @TestCase
    public func concurrentOpenCreatesSingleSet(): Unit {
        let root = rootOf("concurrent_open")
        clean(root)
        let manager = QueueManager(root, 1024 * 1024, 1)
        try {
            let assignment = MQTopicAssignment("/t", 2, 0, [0, 0])
            let done = AtomicInt64(0)
            for (_ in 0..8) {
                spawn {
                    manager.openTopic(assignment, 0)
                    done.fetchAdd(1)
                }
            }
            var waited = 0
            while (done.load() < 8 && waited < 500) {
                sleep(Duration.millisecond * 10)
                waited++
            }
            @Assert(done.load() == 8)
            let queues = manager.localQueues("/t")
            @Assert(queues.size == 2)
            // 只有一组段文件：每个队列目录下恰好一个 log_*.log
            for ((index, _) in queues) {
                let dir = MQFileNames.queueDir(root, "/t", index)
                let files = Array<Int64>(1, repeat: 0)
                Directory.walk(dir) {info: FileInfo =>
                    if (!info.isDirectory() && info.name.endsWith(".log")) {
                        files[0] = files[0] + 1
                    }
                    true
                }
                @Assert(files[0] == 1)
            }
        } finally {
            manager.close()
            clean(root)
        }
    }

    /** 第二个队列打开失败时第一个必须被关闭，且不留下半成品主题（A52）。 */
    @TestCase
    public func failedOpenRollsBackAndLeavesNoTopic(): Unit {
        let root = rootOf("open_rollback")
        clean(root)
        let manager = QueueManager(root, 1024 * 1024, 1)
        try {
            // 把第二个队列的目录名先占成普通文件，令其构造失败
            let blocked = MQFileNames.queueDir(root, "/t", 1)
            Directory.create(Path(blocked).parent, recursive: true)
            let blocker = File(blocked, OpenMode.Write)
            blocker.write([1u8])
            blocker.close()
            var threw = false
            try {
                manager.openTopic(MQTopicAssignment("/t", 2, 0, [0, 0]), 0)
            } catch (_: Exception) {
                threw = true
            }
            @Assert(threw)
            @Assert(manager.queueOf("/t", 0).isNone())
            @Assert(manager.localQueues("/t").size == 0)
            @Assert(manager.localTopics().size == 0)
        } finally {
            manager.close()
            clean(root)
        }
    }

    @TestCase
    public func topicWithoutLocalQueueHasNoPick(): Unit {
        let root = rootOf("no_local")
        clean(root)
        let manager = QueueManager(root, 1024 * 1024, 1)
        try {
            manager.openTopic(MQTopicAssignment("/t", 2, 1, [1, 2]), 0)
            @Assert(manager.localQueues("/t").size == 0)
            @Assert(manager.pickQueue("/t").isNone())
            @Assert(manager.queueOf("/t", 1).isNone())
        } finally {
            manager.close()
            clean(root)
        }
    }

    @TestCase
    public func pickQueueRotatesEvenly(): Unit {
        let root = rootOf("rotate")
        clean(root)
        let manager = QueueManager(root, 1024 * 1024, 1)
        try {
            manager.openTopic(MQTopicAssignment("/t", 3, 0, [0, 0, 0]), 0)
            let counts = [0i64, 0i64, 0i64]
            for (_ in 0..6) {
                let (index, _) = manager.pickQueue("/t").getOrThrow()
                counts[index]++
            }
            @Assert(counts == [2, 2, 2])
        } finally {
            manager.close()
            clean(root)
        }
    }

    @TestCase
    public func closeTopicKeepsOrDeletesFiles(): Unit {
        let root = rootOf("close_topic")
        clean(root)
        let manager = QueueManager(root, 1024 * 1024, 1)
        try {
            manager.openTopic(MQTopicAssignment("/t", 1, 0, [0]), 0)
            let dir = MQFileNames.queueDir(root, "/t", 0)
            manager.pickQueue("/t").getOrThrow()[1].append([1u8, 2u8])
            manager.closeTopic("/t", deleteFiles: false)
            @Assert(exists(dir))
            @Assert(manager.pickQueue("/t").isNone())

            manager.openTopic(MQTopicAssignment("/t", 1, 0, [0]), 0)
            manager.pickQueue("/t").getOrThrow()[1].append([1u8])
            manager.closeTopic("/t", deleteFiles: true)
            @Assert(!exists(dir))
        } finally {
            manager.close()
            clean(root)
        }
    }

    @TestCase
    public func queueOfFindsLocalQueue(): Unit {
        let root = rootOf("queue_of")
        clean(root)
        let manager = QueueManager(root, 1024 * 1024, 1)
        try {
            manager.openTopic(MQTopicAssignment("/t", 2, 0, [0, 1]), 1)
            @Assert(manager.queueOf("/t", 0).isNone())
            let log = manager.queueOf("/t", 1).getOrThrow()
            @Assert(log.append([7u8]).seq >= 1)
        } finally {
            manager.close()
            clean(root)
        }
    }
}
