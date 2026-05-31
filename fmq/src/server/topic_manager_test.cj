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
public class TopicManagerTest {
    @TestCase
    public func testCreateAndDelete(): Unit {
        let config = configWithHosts()
        let tm = TopicManager(config)
        @Assert(tm.createTopic("/test", queueCount: 2) == MqErrorCode.SUCCESS)
        @Assert(tm.createTopic("/test") == MqErrorCode.TOPIC_EXISTS)
        @Assert(tm.deleteTopic("/test") == MqErrorCode.SUCCESS)
        @Assert(tm.deleteTopic("/test") == MqErrorCode.TOPIC_NOT_FOUND)
    }

    @TestCase
    public func testListTopics(): Unit {
        let tm = TopicManager(configWithHosts())
        tm.createTopic("/a")
        tm.createTopic("/b")
        let list = tm.listTopics()
        @Assert(list.size == 2)
    }

    @TestCase
    public func testAddAndRemoveConsumerGroup(): Unit {
        let tm = TopicManager(configWithHosts())
        tm.createTopic("/test")
        @Assert(tm.addConsumerGroup("/test", "group1") == MqErrorCode.SUCCESS)
        let meta = tm.getTopicMeta("/test")
        if (let Some(m) <- meta) {
            @Assert(m.getConsumerGroups().size == 1)
        }
        @Assert(tm.removeConsumerGroup("/test", "group1") == MqErrorCode.SUCCESS)
    }

    @TestCase
    public func testListAllConsumerGroupsEmpty(): Unit {
        let tm = TopicManager(configWithHosts())
        let all = tm.listAllConsumerGroups()
        @Assert(all.size == 0)
    }

    @TestCase
    public func testListAllConsumerGroupsWithTopics(): Unit {
        let tm = TopicManager(configWithHosts())
        tm.createTopic("/a")
        tm.createTopic("/b")
        tm.addConsumerGroup("/a", "g1")
        tm.addConsumerGroup("/a", "g2")
        tm.addConsumerGroup("/b", "g3")
        let all = tm.listAllConsumerGroups()
        @Assert(all.size == 2)
        if (let Some(groups) <- all.get("/a")) {
            @Assert(groups.size == 2)
        }
        if (let Some(groups) <- all.get("/b")) {
            @Assert(groups.size == 1)
        }
    }

    @TestCase
    public func testListAllConsumerGroupsSkipEmpty(): Unit {
        let tm = TopicManager(configWithHosts())
        tm.createTopic("/x")
        tm.createTopic("/y")
        tm.addConsumerGroup("/y", "g")
        let all = tm.listAllConsumerGroups()
        // /x 无 consumerGroup 不应出现
        @Assert(all.size == 1)
        @Assert(all.get("/x").isNone())
        @Assert(all.get("/y").isSome())
    }

    @TestCase
    public func testConcurrentReadWrite(): Unit {
        let tm = TopicManager(configWithHosts())
        tm.createTopic("/base")
        // 并发读写：写入线程创建 topic，读取线程同时 list/get
        let done = AtomicBool(false)
        let writeCount = AtomicInt64(0)
        let readCount = AtomicInt64(0)
        var writers = ArrayList<Future<Unit>>()
        var readers = ArrayList<Future<Unit>>()
        // 5 个写入线程
        for (i in 0..5) {
            writers.add(spawn {
                let idx = i
                while (!done.load()) {
                    let name = "/topic_${idx}_${writeCount.fetchAdd(1)}"
                    try { tm.createTopic(name) } catch (_: Exception) {}
                }
            })
        }
        // 5 个读取线程
        for (_ in 0..5) {
            readers.add(spawn {
                while (!done.load()) {
                    let _ = tm.listTopics()
                    let _ = tm.getTopicMeta("/base")
                    let _ = tm.listAllConsumerGroups()
                    let _ = tm.getConsumerGroups("/base")
                    readCount.fetchAdd(1)
                }
            })
        }
        sleep(Duration.millisecond * 300)
        done.store(true)
        for (w in writers) { w.get() }
        for (r in readers) { r.get() }
        let reads = readCount.load()
        @Assert(reads > 0)
        // 验证基础操作仍正常
        let topics = tm.listTopics()
        @Assert(topics.size > 0)
    }

    private static func configWithHosts(): MqConfig {
        let hosts = ArrayList<String>()
        hosts.add("node1:7201")
        MqConfig(
            mqHosts: hosts, syncHosts: ArrayList(),
            dataDir: "/tmp/fmq_tm_test", segmentMaxSize: 1024,
            heartbeatIntervalSec: 5, healthcheckMaxRetry: 3,
            idleTimeoutMinutes: 30, ackTimeoutMs: 30000,
            maxRetryCount: 3, retryIntervalMs: 1000,
            dlqRetentionHours: 168, maxMessageSize: 4096,
            maxLabelsPerMessage: 64, retentionHours: 72,
            syncQuorum: 1
        )
    }
}
