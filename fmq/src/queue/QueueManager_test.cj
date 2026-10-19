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
import std.unittest.*
import std.unittest.testmacro.*
import fountain::fmq.meta.MQFileNames
import fountain::f_mq.base.payload.MQTopicAssignment

@Test
class QueueManagerTest {
    private static func rootOf(name: String): String {
        "/tmp/fmq_test_queue_manager/${name}"
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
