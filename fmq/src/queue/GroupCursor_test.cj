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

import std.collection.ArrayList
import std.collection.concurrent.ConcurrentHashMap
import std.convert.*
import std.fs.*
import std.io.SeekPosition
import std.sync.AtomicInt64
import std.time.DateTime
import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_mq.base.payload.MQTopicAssignment
import fountain::f_data.*
import fountain::f_io.LogPosition
import fountain::f_mq.base.{MQFilter, MQMessageRecord}
import fountain::f_mq.base.payload.MQDeadLetterMessage
import fountain::fmq.meta.MetaStore
import fountain::f_mq.base.model.MQSubscribeGroupMeta
import fountain::fmq.metrics.MQMetrics
import fountain::fmq.test.TestDirs

class CursorClock {
    var value: DateTime = DateTime.now()

    func advance(duration: Duration): Unit {
        value = value + duration
    }
}

class CursorFixture <: Resource {
    let root: String
    let log: QueueLog
    let store: CursorStore
    let meta: MetaStore
    let catalog: CursorCatalog
    let deadLetter: DeadLetterQueue
    let clock = CursorClock()
    private let topic = "/t"

    init(name: String, maxFileSize!: Int64 = 1024 * 1024, ackTimeout!: Duration = Duration.second * 10,
        threshold!: Int64 = 3) {
        this.root = TestDirs.of("group_cursor", name)
        if (exists(root)) {
            remove(root, recursive: true)
        }
        Directory.create(root, recursive: true)
        this.log = QueueLog("${root}/logs", maxFileSize, 1)
        this.store = CursorStore(root)
        this.meta = MetaStore("${root}/metas")
        meta.load()
        meta.applyTopic(MQTopicAssignment("/t", 1, 0, [0]))
        meta.applyGroup(MQSubscribeGroupMeta("/t", "g"))
        this.catalog = CursorCatalog(store, meta)
        this.deadLetter = DeadLetterQueue("${root}/dead", maxFileSize, 1)
        this.ackTimeout_ = ackTimeout
        this.threshold_ = threshold
    }

    private let ackTimeout_: Duration
    private let threshold_: Int64

    func append(tags: Array<String>, body: String): LogPosition {
        let record = MQMessageRecord.encode(topic, tags, "mid-${body}", body.toData())
        log.append(record)
    }

    /** 用带标准 UTC 时间戳的 messageId 追加，供延迟用例使用。 */
    func appendAt(tags: Array<String>, body: String, at: DateTime): LogPosition {
        let id = "1_2_3_${at.format("yyyyMMddHHmmssSSS")}"
        let record = MQMessageRecord.encode(topic, tags, id, body.toData())
        log.append(record)
    }

    func cursorOf(group!: String = "g", delaying!: Duration = Duration.Zero,
        metrics!: ?MQMetrics = None): GroupCursor {
        GroupCursor(topic, 0, group, log, catalog, ackTimeout_, threshold_, deadLetter, delaying: delaying,
            metrics: metrics, now: {=> clock.value})
    }

    func sub(id: String, tags!: Array<String> = [], filter!: String = '', autoAck!: Bool = false): MQSubscriptionView {
        MQSubscriptionView(id, topic, tags, MQFilter.compile(filter), autoAck)
    }

    func deadLetters(): ArrayList<MQDeadLetterMessage> {
        let result = ArrayList<MQDeadLetterMessage>()
        // 从最老的现存段开始迭代
        let metas = deadLetterLogSegments()
        if (metas.size == 0) {
            return result
        }
        let itr = deadLetter.iterate(LogPosition(metas[0], 0))
        while (true) {
            let item = itr.next()
            if (item.isNone()) {
                break
            }
            result.add(item.getOrThrow())
        }
        result
    }

    private func deadLetterLogSegments(): ArrayList<Int64> {
        // 死信目录里的段号：通过重新打开一个只读视图不可行，改用文件名扫描
        let dir = "${root}/dead"
        let result = ArrayList<Int64>()
        if (!exists(dir)) {
            return result
        }
        Directory.walk(dir) {info: FileInfo =>
            if (!info.isDirectory() && info.name.startsWith("log_") && info.name.endsWith(".log")) {
                let digits = info.name[4..info.name.size - 4]
                match (Int64.tryParse(digits)) {
                    case Some(index) => result.add(index)
                    case None => ()
                }
            }
            true
        }
        result
    }

    public func isClosed(): Bool {
        false
    }

    public func close(): Unit {
        log.close()
        deadLetter.close()
        if (exists(root)) {
            remove(root, recursive: true)
        }
    }
}

@Test
class GroupCursorTest {
    private static func posEq(left: LogPosition, right: LogPosition): Bool {
        left.seq == right.seq && left.offset == right.offset
    }

    private static func recordSize(body: String, tags: Array<String>): Int64 {
        MQMessageRecord.encode("/t", tags, "mid-${body}", body.toData()).size
    }


    /** 记录损坏（段仍在）：游标不标记已决、不推进，也不跳过后续记录（R3-M2）。 */
    @TestCase
    public func corruptedRecordDoesNotAdvanceCursor(): Unit {
        let fixture = CursorFixture("corrupt_record", ackTimeout: Duration.Zero)
        try {
            let first = fixture.append([], "first")
            fixture.append([], "second")
            let cursor = fixture.cursorOf()
            let sub = fixture.sub("s1")
            let delivered = cursor.next(sub, [sub], MQMatcher()).getOrThrow()
            @Assert(delivered[1].seq == first.seq && delivered[1].offset == first.offset)

            // 把第一条记录的长度头改成非法值（段文件仍在）
            let file = File("${fixture.root}/logs/log_1.log", OpenMode.ReadWrite)
            try {
                file.seek(SeekPosition.Begin(0))
                file.write([0xFFu8, 0xFFu8, 0xFFu8, 0xFFu8])
            } finally {
                file.close()
            }

            @Assert(cursor.next(sub, [sub], MQMatcher()).isNone())
            @Assert(cursor.committed.seq == first.seq && cursor.committed.offset == first.offset)
            @Assert(cursor.unreadableSkipped == 0)
            cursor.close()
        } finally {
            fixture.close()
        }
    }

    @TestCase
    public func sequentialDeliveryAdvancesCommitted(): Unit {
        let fixture = CursorFixture("sequential")
        try {
            fixture.append([], "one")
            fixture.append([], "two")
            fixture.append([], "three")
            let cursor = fixture.cursorOf()
            let sub = fixture.sub("s1")
            let members = [sub]

            let first = cursor.next(sub, members, MQMatcher()).getOrThrow()
            @Assert(cursor.ack("s1", first[1]))
            let second = cursor.next(sub, members, MQMatcher()).getOrThrow()
            @Assert(cursor.ack("s1", second[1]))
            let third = cursor.next(sub, members, MQMatcher()).getOrThrow()
            @Assert(cursor.ack("s1", third[1]))

            @Assert(first[0] != second[0])
            @Assert(cursor.pendingCount == 0)
            @Assert(cursor.next(sub, members, MQMatcher()).isNone())
            cursor.close()
        } finally {
            fixture.close()
        }
    }

    @TestCase
    public func outOfOrderAckKeepsHole(): Unit {
        let fixture = CursorFixture("out_of_order")
        try {
            fixture.append([], "one")
            fixture.append([], "two")
            fixture.append([], "three")
            let cursor = fixture.cursorOf()
            let sub = fixture.sub("s1")
            let members = [sub]
            let p1 = cursor.next(sub, members, MQMatcher()).getOrThrow()[1]
            let p2 = cursor.next(sub, members, MQMatcher()).getOrThrow()[1]
            let p3 = cursor.next(sub, members, MQMatcher()).getOrThrow()[1]

            @Assert(cursor.ack("s1", p2))
            @Assert(cursor.ack("s1", p3))
            @Assert(cursor.pendingCount == 1)
            @Assert(cursor.ack("s1", p1))
            @Assert(cursor.pendingCount == 0)
            // 重复确认 → ACK_UNKNOWN
            @Assert(!cursor.ack("s1", p1))
            cursor.close()
        } finally {
            fixture.close()
        }
    }

    @TestCase
    public func ackChecksOwnership(): Unit {
        let fixture = CursorFixture("ack_owner")
        try {
            fixture.append([], "one")
            let cursor = fixture.cursorOf()
            let sub = fixture.sub("s1")
            let position = cursor.next(sub, [sub], MQMatcher()).getOrThrow()[1]
            // 别的订阅不能确认
            @Assert(!cursor.ack("s2", position))
            @Assert(cursor.ack("s1", position))
            cursor.close()
        } finally {
            fixture.close()
        }
    }

    @TestCase
    public func timeoutAllowsRedelivery(): Unit {
        let fixture = CursorFixture("timeout", ackTimeout: Duration.second * 10)
        try {
            fixture.append([], "one")
            fixture.append([], "two")
            let cursor = fixture.cursorOf()
            let sub = fixture.sub("s1")
            let members = [sub]
            let p1 = cursor.next(sub, members, MQMatcher()).getOrThrow()[1]

            // 未超时：只投递新消息
            let p2 = cursor.next(sub, members, MQMatcher()).getOrThrow()[1]
            @Assert(!posEq(p2, p1))

            // 超时后 p1 可再次投递（此时 p2 也已投递，未超时）
            fixture.clock.advance(Duration.second * 11)
            let again = cursor.next(sub, members, MQMatcher()).getOrThrow()[1]
            @Assert(posEq(again, p1))
            cursor.close()
        } finally {
            fixture.close()
        }
    }

    @TestCase
    public func deliveryOverThresholdGoesToDeadLetter(): Unit {
        let fixture = CursorFixture("dead_letter", threshold: 1)
        try {
            fixture.append([], "one")
            let cursor = fixture.cursorOf()
            let sub = fixture.sub("s1")
            let members = [sub]
            cursor.next(sub, members, MQMatcher()).getOrThrow()
            // 第一次投递 count = 1；超时后再次可投递时 count = 2 > 1 ⇒ 进死信
            fixture.clock.advance(Duration.second * 11)
            @Assert(cursor.next(sub, members, MQMatcher()).isNone())
            let letters = fixture.deadLetters()
            @Assert(letters.size == 1)
            @Assert(letters[0].segmentedIndex >= 1)
            @Assert(letters[0].subscribeGroup == "g")
            @Assert(letters[0].deliverCount == 2)
            cursor.close()
        } finally {
            fixture.close()
        }
    }

    @TestCase
    public func autoAckAdvancesWithoutExplicitAck(): Unit {
        let fixture = CursorFixture("auto_ack")
        try {
            fixture.append([], "one")
            fixture.append([], "two")
            let cursor = fixture.cursorOf()
            let sub = fixture.sub("s1", autoAck: true)
            let members = [sub]
            @Assert(cursor.next(sub, members, MQMatcher()).isSome())
            @Assert(cursor.pendingCount == 0)
            @Assert(cursor.next(sub, members, MQMatcher()).isSome())
            @Assert(cursor.pendingCount == 0)
            @Assert(cursor.next(sub, members, MQMatcher()).isNone())
            cursor.close()
        } finally {
            fixture.close()
        }
    }

    @TestCase
    public func unmatchedRecordIsSkippedAndCommitted(): Unit {
        let fixture = CursorFixture("unmatched")
        try {
            let tags: Array<String> = []
            fixture.append(tags, "one")
            let cursor = fixture.cursorOf()
            let sub = fixture.sub("s1", tags: ["x"])
            @Assert(cursor.next(sub, [sub], MQMatcher()).isNone())
            // 唯一的记录不匹配 ⇒ 记为不适用并越过
            let expected = 4 + recordSize("one", tags)
            @Assert(posEq(cursor.committed, LogPosition(1, expected)))
            // 越过必须留痕（DEBUG 日志 + 跳过计数）
            @Assert(cursor.noMatchSkipped == 1)
            cursor.close()
        } finally {
            fixture.close()
        }
    }

    @TestCase
    public func recordAssignedToOtherSubscriber(): Unit {
        let fixture = CursorFixture("assign_other")
        try {
            fixture.append(["b"], "one")
            let cursor = fixture.cursorOf()
            let s1 = fixture.sub("s1", tags: ["a"])
            let s2 = fixture.sub("s2", tags: ["b"])
            let members = [s1, s2]
            // s1 取不到，但记录被分配给 s2
            @Assert(cursor.next(s1, members, MQMatcher()).isNone())
            let taken = cursor.next(s2, members, MQMatcher()).getOrThrow()
            @Assert(!cursor.ack("s1", taken[1]))
            @Assert(cursor.ack("s2", taken[1]))
            cursor.close()
        } finally {
            fixture.close()
        }
    }

    @TestCase
    public func releaseReturnsRecordToGroup(): Unit {
        let fixture = CursorFixture("release")
        try {
            fixture.append([], "one")
            let cursor = fixture.cursorOf()
            let sub = fixture.sub("s1")
            let first = cursor.next(sub, [sub], MQMatcher()).getOrThrow()[1]
            cursor.release("s1")
            @Assert(cursor.pendingCount == 1)
            let again = cursor.next(sub, [sub], MQMatcher()).getOrThrow()[1]
            @Assert(posEq(again, first))
            cursor.close()
        } finally {
            fixture.close()
        }
    }

    @TestCase
    public func sweepReleasesInactiveOwner(): Unit {
        let fixture = CursorFixture("sweep")
        try {
            fixture.append(["b"], "one")
            let cursor = fixture.cursorOf()
            let s1 = fixture.sub("s1", tags: ["a"])
            let s2 = fixture.sub("s2", tags: ["b"])
            @Assert(cursor.next(s1, [s1, s2], MQMatcher()).isNone())
            // s2 不在活跃集合里 ⇒ 分配被退回；s1 不匹配 ⇒ 仍取不到
            cursor.sweep(["s1"])
            @Assert(cursor.next(s1, [s1], MQMatcher()).isNone())
            // s2 回来后可以取到
            let taken = cursor.next(s2, [s1, s2], MQMatcher()).getOrThrow()
            @Assert(taken[0].size > 0)
            cursor.close()
        } finally {
            fixture.close()
        }
    }

    @TestCase
    public func restartRedeliversOnlyUnacked(): Unit {
        let fixture = CursorFixture("restart")
        try {
            let p1 = fixture.append([], "one")
            let p2 = fixture.append([], "two")
            let p3 = fixture.append([], "three")
            let sub = fixture.sub("s1")
            let first = fixture.cursorOf()
            @Assert(posEq(first.next(sub, [sub], MQMatcher()).getOrThrow()[1], p1))
            @Assert(first.ack("s1", p1))
            @Assert(posEq(first.next(sub, [sub], MQMatcher()).getOrThrow()[1], p2))
            @Assert(first.ack("s1", p2))
            @Assert(posEq(first.next(sub, [sub], MQMatcher()).getOrThrow()[1], p3))
            first.close()

            let second = fixture.cursorOf()
            let redelivered = second.next(sub, [sub], MQMatcher()).getOrThrow()
            @Assert(posEq(redelivered[1], p3))
            second.close()
        } finally {
            fixture.close()
        }
    }

    @TestCase
    public func catalogFloorTracksCommittedSegments(): Unit {
        // 段上限 32：两条记录必然跨段
        let fixture = CursorFixture("floor_committed", maxFileSize: 32)
        try {
            let p1 = fixture.append([], "one")
            let p2 = fixture.append([], "two")
            @Assert(p2.seq > p1.seq)
            let cursor = fixture.cursorOf()
            let sub = fixture.sub("s1")
            // 组从未消费：边界钉在最老段
            @Assert(fixture.catalog.floorOf("/t", 0) == 1)
            let first = cursor.next(sub, [sub], MQMatcher()).getOrThrow()
            @Assert(cursor.ack("s1", first[1]))
            let second = cursor.next(sub, [sub], MQMatcher()).getOrThrow()
            @Assert(cursor.ack("s1", second[1]))
            // committed 已越过段 1：边界抬到 committed 的段号
            @Assert(fixture.catalog.floorOf("/t", 0) == cursor.committed.seq)
            @Assert(cursor.committed.seq > 1)
            cursor.close()
        } finally {
            fixture.close()
        }
    }

    /** 位点正好落在段末尾（`offset == size`）：继续读后继段，并把 committed 前移落盘（R3-C1）。 */
    @TestCase
    public func committedAtSegmentEndContinuesOnNextSegment(): Unit {
        let sz1 = 4 + recordSize("one", [])
        let sz2 = 4 + recordSize("two", [])
        let fixture = CursorFixture("segment_end_cursor", maxFileSize: sz1 + sz2)
        try {
            fixture.append([], "one")
            fixture.append([], "two")
            fixture.append([], "three")
            // 段 1 已读满：committed = (1, sz1 + sz2)
            fixture.store.save("/t", 0, "g", LogPosition(1, sz1 + sz2))
            let cursor = fixture.cursorOf()
            let sub = fixture.sub("s1")
            let next = cursor.next(sub, [sub], MQMatcher()).getOrThrow()
            @Assert(next[1].seq == 2 && next[1].offset == 0)
            @Assert(cursor.committed.seq == 2 && cursor.committed.offset == 0)
            @Assert(fixture.store.load("/t", 0, "g").getOrThrow().seq == 2)
            cursor.close()
        } finally {
            fixture.close()
        }
    }

    @TestCase
    public func removedCommittedSegmentRecoversToOldestSurvivor(): Unit {
        let sz1 = 4 + recordSize("one", [])
        let sz2 = 4 + recordSize("two", [])
        let fixture = CursorFixture("segment_gone", maxFileSize: sz1 + sz2)
        try {
            fixture.append([], "one")
            fixture.append([], "two")
            fixture.append([], "three") // 段 1 封口，段 2 成为当前段
            // 模拟重启前落盘的位点：committed 仍指向段 1
            fixture.store.save("/t", 0, "g", LogPosition(1, 0))
            fixture.log.removeById(1)

            let cursor = fixture.cursorOf()
            let sub = fixture.sub("s1")
            // 打开段 1 失败 → 跳到现存最老段 2 继续，不永久报错
            let recovered = cursor.next(sub, [sub], MQMatcher()).getOrThrow()
            @Assert(recovered[1].seq == 2)
            @Assert(cursor.committed.seq == 2)
            @Assert(convert<String>(MQMessageRecord.decode(recovered[0]).getOrThrow().body.data).getOrThrow() ==
                "three")
            // 恢复后的位置已落盘
            @Assert(fixture.store.load("/t", 0, "g").getOrThrow().seq == 2)
            cursor.close()
        } finally {
            fixture.close()
        }
    }

    @TestCase
    public func allSegmentsMissingReturnsNone(): Unit {
        let fixture = CursorFixture("all_gone")
        try {
            fixture.append([], "one")
            let cursor = fixture.cursorOf()
            let sub = fixture.sub("s1")
            // 整目录被删除：没有任何可读段，返回空而不是抛出
            remove("${fixture.root}/logs", recursive: true)
            @Assert(cursor.next(sub, [sub], MQMatcher()).isNone())
            cursor.close()
        } finally {
            fixture.close()
        }
    }

    /** 读流已打开后整目录被删除：与开流路径一致返回空，不把空队列变成异常（W1）。 */
    @TestCase
    public func allSegmentsMissingMidStreamReturnsNone(): Unit {
        let fixture = CursorFixture("all_gone_mid", maxFileSize: 4 + recordSize("m0", []))
        try {
            fixture.append([], "m0")
            fixture.append([], "m1")
            let cursor = fixture.cursorOf()
            let sub = fixture.sub("s1")
            // 第一次投递后读流仍开着（跨段），此时运维删掉整个队列目录
            let first = cursor.next(sub, [sub], MQMatcher()).getOrThrow()
            @Assert(first[1].seq == 1)
            remove("${fixture.root}/logs", recursive: true)
            var thrown = false
            var item: ?(Array<Byte>, LogPosition) = None
            try {
                item = cursor.next(sub, [sub], MQMatcher())
            } catch (_: Exception) {
                thrown = true
            }
            @Assert(!thrown)
            @Assert(item.isNone())
            cursor.close()
        } finally {
            fixture.close()
        }
    }

    /** 起点段落在空洞时从最接近的更大段继续，不得回退到更老段重投（W2）。 */
    @TestCase
    public func startingSegmentHoleResumesAtNextSegment(): Unit {
        let fixture = CursorFixture("segment_hole", maxFileSize: 4 + recordSize("m0", []))
        try {
            for (i in 0..8) {
                fixture.append([], "m${i}")
            }
            // 运维手删中间段：只剩 1、7、8
            for (i in 2..=6) {
                fixture.log.removeById(i)
            }
            @Assert(fixture.log.segments().size == 3)
            fixture.store.save("/t", 0, "g", LogPosition(5, 0))

            let cursor = fixture.cursorOf()
            let sub = fixture.sub("s1")
            let item = cursor.next(sub, [sub], MQMatcher()).getOrThrow()
            // 从段 7 起点继续（第 7 条记录 m6），而不是回退到段 1 重投 m0
            @Assert(item[1].seq == 7 && item[1].offset == 0)
            @Assert(convert<String>(MQMessageRecord.decode(item[0]).getOrThrow().body.data).getOrThrow() == "m6")
            @Assert(cursor.committed.seq == 7 && cursor.committed.offset == 0)
            @Assert(fixture.store.load("/t", 0, "g").getOrThrow().seq == 7)
            cursor.close()
        } finally {
            fixture.close()
        }
    }

    /** 「不可评估 BODY 跳过」必须计数（W3）。 */
    @TestCase
    public func unsupportedBodySkipIsCounted(): Unit {
        let fixture = CursorFixture("unsupported_skip")
        try {
            // 截断记录：topic/tags 可解，BODY 不可解 ⇒ 带 filter 的订阅无法判定
            let full = MQMessageRecord.encode("/t", [], "mid-truncated", "{\"level\":1}".toData())
            fixture.log.append(full[0..full.size - 3])
            let cursor = fixture.cursorOf()
            let sub = fixture.sub("s1", filter: "$.level")
            @Assert(cursor.next(sub, [sub], MQMatcher()).isNone())
            @Assert(cursor.unsupportedSkipped == 1)
            @Assert(cursor.takeUnsupported().isSome())
            cursor.close()
        } finally {
            fixture.close()
        }
    }

    @TestCase
    public func concurrentNextAndAckProduceUniquePositions(): Unit {
        let fixture = CursorFixture("concurrent", ackTimeout: Duration.hour, threshold: 1000)
        try {
            for (i in 0..200) {
                fixture.append([], "m${i}")
            }
            let cursor = fixture.cursorOf()
            let sub = fixture.sub("s1")
            let members = [sub]
            let seen = ConcurrentHashMap<String, Bool>()
            let done = AtomicInt64(0)
            for (_ in 0..4) {
                spawn {
                    for (_ in 0..50) {
                        let item = cursor.next(sub, members, MQMatcher())
                        if (let Some(pair) <- item) {
                            seen.addIfAbsent("${pair[1].seq}:${pair[1].offset}", true)
                            cursor.ack("s1", pair[1])
                        }
                    }
                    done.fetchAdd(1)
                }
            }
            var waited = 0
            while (done.load() < 4 && waited < 500) {
                sleep(Duration.millisecond * 20)
                waited++
            }
            @Assert(done.load() == 4)
            @Assert(seen.size == 200)
            // 并发确认后 committed 已推进（单调，不回退到起点）
            @Assert(cursor.committed.seq > 1 || cursor.committed.offset > 0)
            cursor.close()
        } finally {
            fixture.close()
        }
    }
    @TestCase
    public func delayedRecordWaitsUntilDue(): Unit {
        let fixture = CursorFixture("delay")
        try {
            let published = DateTime.nowUTC()
            fixture.appendAt([], "one", published)
            let cursor = fixture.cursorOf(delaying: Duration.second * 61)
            let sub = fixture.sub("s1")
            @Assert(cursor.next(sub, [sub], MQMatcher()).isNone())
            @Assert(cursor.committed.seq == 1 && cursor.committed.offset == 0)

            fixture.clock.advance(Duration.second * 62)
            let item = cursor.next(sub, [sub], MQMatcher()).getOrThrow()
            @Assert(convert<String>(MQMessageRecord.decode(item[0]).getOrThrow().body.data) == Some("one"))
            cursor.close()
        } finally {
            fixture.close()
        }
    }

    @TestCase
    public func delayedTopicBlocksHeadOfLine(): Unit {
        let fixture = CursorFixture("delay_hol")
        try {
            let now = DateTime.nowUTC()
            // 第一条未到期；第二条虽然已到期，也不能越过第一条
            fixture.appendAt([], "late", now)
            fixture.appendAt([], "already-due", now - Duration.second * 120)
            let cursor = fixture.cursorOf(delaying: Duration.second * 61)
            let sub = fixture.sub("s1")
            @Assert(cursor.next(sub, [sub], MQMatcher()).isNone())
            @Assert(cursor.committed.seq == 1 && cursor.committed.offset == 0)

            fixture.clock.advance(Duration.second * 62)
            let first = cursor.next(sub, [sub], MQMatcher()).getOrThrow()
            @Assert(convert<String>(MQMessageRecord.decode(first[0]).getOrThrow().body.data) == Some("late"))
            cursor.close()
        } finally {
            fixture.close()
        }
    }

    @TestCase
    public func delayedRecordSurvivesCursorReopen(): Unit {
        let fixture = CursorFixture("delay_restart")
        try {
            fixture.appendAt([], "one", DateTime.nowUTC())
            let first = fixture.cursorOf(delaying: Duration.second * 61)
            let sub = fixture.sub("s1")
            @Assert(first.next(sub, [sub], MQMatcher()).isNone())
            first.close()

            let reopened = fixture.cursorOf(delaying: Duration.second * 61)
            @Assert(reopened.next(sub, [sub], MQMatcher()).isNone())
            reopened.close()
        } finally {
            fixture.close()
        }
    }

    /** 比当前时刻晚 8 小时的时间戳（旧版按本地时区写入）必须视为已到期，不能把组卡住（A02）。 */
    @TestCase
    public func futurePublishTimeIsDeliveredImmediately(): Unit {
        let fixture = CursorFixture("delay_future")
        try {
            fixture.appendAt([], "skewed", DateTime.nowUTC() + Duration.hour * 8)
            let cursor = fixture.cursorOf(delaying: Duration.second * 61)
            let sub = fixture.sub("s1")
            let item = cursor.next(sub, [sub], MQMatcher()).getOrThrow()
            @Assert(convert<String>(MQMessageRecord.decode(item[0]).getOrThrow().body.data) == Some("skewed"))
            cursor.close()
        } finally {
            fixture.close()
        }
    }

    @TestCase
    public func nonStandardMessageIdDeliversImmediately(): Unit {
        let fixture = CursorFixture("delay_bad_id")
        try {
            fixture.append([], "one")
            let cursor = fixture.cursorOf(delaying: Duration.second * 61)
            let sub = fixture.sub("s1")
            @Assert(cursor.next(sub, [sub], MQMatcher()).isSome())
            cursor.close()
        } finally {
            fixture.close()
        }
    }

    @TestCase
    public func metricsCountDeliveryAckAndRedelivery(): Unit {
        let fixture = CursorFixture("metrics", ackTimeout: Duration.second * 10, threshold: 10)
        try {
            fixture.append([], "one")
            let metrics = MQMetrics()
            let cursor = fixture.cursorOf(metrics: metrics)
            let sub = fixture.sub("s1")
            let first = cursor.next(sub, [sub], MQMatcher()).getOrThrow()
            fixture.clock.advance(Duration.second * 11)
            let again = cursor.next(sub, [sub], MQMatcher()).getOrThrow()
            @Assert(again[1].seq == first[1].seq && again[1].offset == first[1].offset)
            @Assert(cursor.ack("s1", again[1]))
            @Assert(metrics.deliveredOf("/t", "g") == 2)
            @Assert(metrics.redeliveredOf("/t", "g") == 1)
            @Assert(metrics.ackedOf("/t", "g") == 1)
            @Assert(metrics.deadLetteredOf("/t", "g") == 0)
            cursor.close()
        } finally {
            fixture.close()
        }
    }

    @TestCase
    public func metricsCountDeadLetter(): Unit {
        let fixture = CursorFixture("metrics_dl", ackTimeout: Duration.second * 10, threshold: 1)
        try {
            fixture.append([], "one")
            let metrics = MQMetrics()
            let cursor = fixture.cursorOf(metrics: metrics)
            let sub = fixture.sub("s1")
            @Assert(cursor.next(sub, [sub], MQMatcher()).isSome())
            fixture.clock.advance(Duration.second * 11)
            // 第二次尝试超过阈值：直接进死信，不再返回给订阅者
            @Assert(cursor.next(sub, [sub], MQMatcher()).isNone())
            @Assert(metrics.deliveredOf("/t", "g") == 1)
            @Assert(metrics.deadLetteredOf("/t", "g") == 1)
            cursor.close()
        } finally {
            fixture.close()
        }
    }
    @TestCase
    public func delayedRecordNotAssignedToOtherSubscriberEarly(): Unit {
        let fixture = CursorFixture("delay_group")
        try {
            fixture.appendAt(["b"], "one", DateTime.nowUTC())
            let cursor = fixture.cursorOf(delaying: Duration.second * 61)
            let s1 = fixture.sub("s1", tags: ["a"])
            let s2 = fixture.sub("s2", tags: ["b"])
            let members = [s1, s2]
            // s1 不匹配，但也不能在到期前把记录分配给 s2
            @Assert(cursor.next(s1, members, MQMatcher()).isNone())
            @Assert(cursor.next(s2, members, MQMatcher()).isNone())

            fixture.clock.advance(Duration.second * 62)
            @Assert(cursor.next(s1, members, MQMatcher()).isNone())
            @Assert(cursor.next(s2, members, MQMatcher()).isSome())
            cursor.close()
        } finally {
            fixture.close()
        }
    }

    /** 记录不可读时标记已决但必须留痕，不能静默吞掉（A48）。 */
    @TestCase
    public func unreadableRecordIsCounted(): Unit {
        let fixture = CursorFixture("unreadable")
        try {
            let position = fixture.append(["b"], "one")
            let cursor = fixture.cursorOf()
            let s1 = fixture.sub("s1", tags: ["a"])
            let s2 = fixture.sub("s2", tags: ["b"])
            let members = [s1, s2]
            // s1 扫描：记录分配给 s2（entry.position = 记录位置）
            @Assert(cursor.next(s1, members, MQMatcher()).isNone())
            // 真实删段（模拟 TTL 清理）：readAt 按「段缺失」处理，而不是「记录损坏」
            let dir = "${fixture.root}/logs"
            let segments = ArrayList<String>()
            Directory.walk(dir) {info: FileInfo =>
                if (!info.isDirectory() && info.name.startsWith("log_")) {
                    segments.add(info.path.toString())
                }
                true
            }
            @Assert(segments.size > 0)
            for (path in segments) {
                remove(path)
            }
            @Assert(cursor.next(s2, members, MQMatcher()).isNone())
            @Assert(cursor.unreadableSkipped == 1)
            @Assert(cursor.committed.seq > position.seq ||
                (cursor.committed.seq == position.seq && cursor.committed.offset > position.offset))
            cursor.close()
        } finally {
            fixture.close()
        }
    }

    /** 未真正投递过的位置不接受 ACK，游标也不得推进（A50）。 */
    @TestCase
    public func ackRequiresDeliveredPosition(): Unit {
        let fixture = CursorFixture("ack_not_delivered")
        try {
            let position = fixture.append(["b"], "one")
            let cursor = fixture.cursorOf()
            let s1 = fixture.sub("s1", tags: ["a"])
            let s2 = fixture.sub("s2", tags: ["b"])
            let members = [s1, s2]
            // s1 扫描时把记录分配给 s2（delivered = false），s1 拿不到
            @Assert(cursor.next(s1, members, MQMatcher()).isNone())
            // s2 还没取走就 ACK：必须被拒绝
            @Assert(!cursor.ack("s2", position))
            @Assert(cursor.committed.seq == 1 && cursor.committed.offset == 0)
            // s2 真正取走后 ACK 生效
            @Assert(cursor.next(s2, members, MQMatcher()).isSome())
            @Assert(cursor.ack("s2", position))
            cursor.close()
        } finally {
            fixture.close()
        }
    }
}