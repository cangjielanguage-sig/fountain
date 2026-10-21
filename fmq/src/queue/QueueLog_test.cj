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
import fountain::f_io.LogPosition

@Test
class QueueLogTest {
    private static func dirOf(name: String): String {
        "/tmp/fmq_test_queue_log/${name}"
    }

    private static func clean(dir: String): Unit {
        if (exists(dir)) {
            remove(dir, recursive: true)
        }
    }

    private static func recordOf(value: Byte, size: Int64): Array<Byte> {
        Array<Byte>(size, repeat: value)
    }

    private static func readOne(log: QueueLog, position: LogPosition): Array<Byte> {
        log.readAt(position).getOrThrow()
    }

    @TestCase
    public func appendThenReadAtReturnsSameBytes(): Unit {
        let dir = dirOf("read_at")
        clean(dir)
        let log = QueueLog(dir, 1024 * 1024, 1)
        try {
            let a = recordOf(0xA1u8, 64)
            let b = recordOf(0xB2u8, 32)
            let pa = log.append(a)
            let pb = log.append(b)
            @Assert(readOne(log, pa) == a)
            @Assert(readOne(log, pb) == b)
            // 位置单调：同段内 offset 递增
            @Assert(pa.seq == pb.seq)
            @Assert(pb.offset > pa.offset)
        } finally {
            log.close()
            clean(dir)
        }
    }

    @TestCase
    public func rotationResetsOffsetAndIncrementsSequence(): Unit {
        let dir = dirOf("rotation")
        clean(dir)
        // 每条 entry 84 字节（4 字节头 + 80），段上限 200 ⇒ 第 3 条必轮转
        let log = QueueLog(dir, 200, 1)
        try {
            let data = recordOf(0xC3u8, 80)
            let p1 = log.append(data)
            let p2 = log.append(data)
            let p3 = log.append(data)
            @Assert(p1.seq == 1 && p1.offset == 0)
            @Assert(p2.seq == 1 && p2.offset == 84)
            @Assert(p3.seq == 2 && p3.offset == 0)
            @Assert(log.segments().size == 2)
        } finally {
            log.close()
            clean(dir)
        }
    }

    @TestCase
    public func readerSkipsPreallocationAndStopsAtEnd(): Unit {
        let dir = dirOf("reader")
        clean(dir)
        let log = QueueLog(dir, 1024 * 1024, 1)
        try {
            let records = [recordOf(1u8, 16), recordOf(2u8, 24), recordOf(3u8, 8)]
            for (record in records) {
                log.append(record)
            }
            let reader = log.openRecordsFrom(LogPosition(1, 0))
            var index = 0
            while (true) {
                let item = reader.next()
                if (item.isNone()) {
                    break
                }
                let bytes = item.getOrThrow()[0]
                @Assert(bytes == records[index])
                index++
            }
            @Assert(index == 3)
            @Assert(reader.next().isNone())
        } finally {
            log.close()
            clean(dir)
        }
    }

    @TestCase
    public func unknownSegmentThrows(): Unit {
        let dir = dirOf("unknown_segment")
        clean(dir)
        let log = QueueLog(dir, 1024, 1)
        try {
            var threw = false
            try {
                log.openRecordsFrom(LogPosition(999, 0))
            } catch (_: IllegalArgumentException) {
                threw = true
            }
            @Assert(threw)
        } finally {
            log.close()
            clean(dir)
        }
    }

    @TestCase
    public func streamIsSnapshotOfCreationTime(): Unit {
        let dir = dirOf("snapshot")
        clean(dir)
        let log = QueueLog(dir, 1024 * 1024, 1)
        try {
            let a = recordOf(1u8, 10)
            let b = recordOf(2u8, 10)
            let first = log.append(a)
            log.append(b)
            let reader = log.openRecordsFrom(first)
            // 读尽当前快照
            @Assert(reader.next().getOrThrow()[0] == a)
            @Assert(reader.next().getOrThrow()[0] == b)
            // 之后追加的数据不在旧流里
            let c = recordOf(3u8, 10)
            let pc = log.append(c)
            @Assert(reader.next().isNone())
            // 用新位置重开可读到
            let reopened = log.openRecordsFrom(pc)
            @Assert(reopened.next().getOrThrow()[0] == c)
            reopened.close()
        } finally {
            log.close()
            clean(dir)
        }
    }

    @TestCase
    public func sizeUsesSegmentMetadata(): Unit {
        let dir = dirOf("size")
        clean(dir)
        let log = QueueLog(dir, 1024 * 1024, 1)
        try {
            @Assert(log.size == 0)
            log.append(recordOf(1u8, 10))
            log.append(recordOf(2u8, 20))
            var expected = 0i64
            for (meta in log.segments()) {
                expected += meta.size
            }
            @Assert(log.size == expected)
            @Assert(log.size == 2 * 4 + 30)
        } finally {
            log.close()
            clean(dir)
        }
    }

    @TestCase
    public func restartOpensNewSegmentAndKeepsOldBytes(): Unit {
        let dir = dirOf("restart")
        clean(dir)
        let a = recordOf(0x11u8, 40)
        let b = recordOf(0x22u8, 50)
        var before = 0i64
        var posA = LogPosition(0, 0)
        let first = QueueLog(dir, 1024 * 1024, 1)
        try {
            posA = first.append(a)
            first.append(b)
            before = first.size
        } finally {
            first.close()
        }
        // 重启：新实例开新段，旧段仍可读，有效长度不变
        let second = QueueLog(dir, 1024 * 1024, 1)
        try {
            @Assert(second.size == before)
            @Assert(second.segments().size == 2)
            @Assert(readOne(second, posA) == a)
            let c = recordOf(0x33u8, 10)
            let posC = second.append(c)
            @Assert(posC.seq == 2)
            @Assert(posC.offset == 0)
            @Assert(readOne(second, posC) == c)
            @Assert(second.size == before + 4 + c.size)
        } finally {
            second.close()
            clean(dir)
        }
    }

    @TestCase
    public func emptyLogHasNoRecord(): Unit {
        let dir = dirOf("empty")
        clean(dir)
        let log = QueueLog(dir, 1024, 1)
        try {
            @Assert(log.size == 0)
            let reader = log.openRecordsFrom(LogPosition(1, 0))
            @Assert(reader.next().isNone())
            reader.close()
        } finally {
            log.close()
            clean(dir)
        }
    }

    @TestCase
    public func everyAppendIsImmediatelyReadable(): Unit {
        let dir = dirOf("fsync")
        clean(dir)
        let log = QueueLog(dir, 1024 * 1024, 1)
        try {
            for (i in 0..50) {
                let record = recordOf(UInt8(i % 251), 64)
                let position = log.append(record)
                @Assert(readOne(log, position) == record)
            }
        } finally {
            log.close()
            clean(dir)
        }
    }

    @TestCase
    public func truncatedEntryIsRejected(): Unit {
        let dir = dirOf("truncated")
        clean(dir)
        let log = QueueLog(dir, 1024 * 1024, 1)
        try {
            log.append(recordOf(1u8, 64))
            // 位置越过记录体：读到的是长度头的后半程，必然无法组成完整记录
            let reader = log.openRecordsFrom(LogPosition(1, 2))
            var rejected = false
            try {
                rejected = reader.next().isNone()
            } catch (_: Exception) {
                rejected = true
            }
            @Assert(rejected)
            reader.close()
        } finally {
            log.close()
            clean(dir)
        }
    }

    // ===== 长度头上界（A45） =====

    /** 直接在段文件里写原始字节，模拟损坏段。 */
    private static func rawLog(name: String, segments: Array<Array<Byte>>, maxFileSize!: Int64 = 1024 * 1024):
        QueueLog {
        let dir = dirOf(name)
        clean(dir)
        Directory.create(dir, recursive: true)
        for (i in 0..segments.size) {
            let file = File.create("${dir}/log_${i + 1}.log")
            file.write(segments[i])
            file.close()
        }
        QueueLog(dir, maxFileSize, 1)
    }

    private static func concat(left: Array<Byte>, right: Array<Byte>): Array<Byte> {
        let out = Array<Byte>(left.size + right.size, repeat: 0u8)
        left.copyTo(out, 0, 0, left.size)
        right.copyTo(out, 0, left.size, right.size)
        out
    }

    private static func header(value: Int64): Array<Byte> {
        [
            UInt8((value >> 24) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8(value & 0xff)
        ]
    }

    @TestCase
    public func hugeDeclaredLengthIsRejectedWithoutAllocation(): Unit {
        // 长度头 0xFFFFFFFF：绝不能据此申请 4 GiB
        let log = rawLog("corrupt_huge", [header(0xFFFFFFFF)])
        let dir = dirOf("corrupt_huge")
        try {
            @Assert(log.readAt(LogPosition(1, 0)).isNone())
            var thrown = false
            try {
                log.scanAfter(LogPosition(1, 0))
            } catch (_: QueueCorruptionException) {
                thrown = true
            }
            @Assert(thrown)
        } finally {
            log.close()
            clean(dir)
        }
    }

    @TestCase
    public func declaredLengthBeyondRemainingIsRejected(): Unit {
        let segment = concat(header(100), [1u8, 2u8, 3u8])
        let log = rawLog("corrupt_remaining", [segment])
        let dir = dirOf("corrupt_remaining")
        try {
            @Assert(log.readAt(LogPosition(1, 0)).isNone())
            var thrown = false
            try {
                log.scanAfter(LogPosition(1, 0))
            } catch (_: QueueCorruptionException) {
                thrown = true
            }
            @Assert(thrown)
        } finally {
            log.close()
            clean(dir)
        }
    }

    @TestCase
    public func lengthEqualToRemainingIsValid(): Unit {
        let log = rawLog("exact_remaining", [concat(header(3), [1u8, 2u8, 3u8])])
        let dir = dirOf("exact_remaining")
        try {
            @Assert(log.readAt(LogPosition(1, 0)).getOrThrow() == [1u8, 2u8, 3u8])
            let scanned = log.scanAfter(LogPosition(1, 0))
            @Assert(scanned[0] == 1)
        } finally {
            log.close()
            clean(dir)
        }
    }

    @TestCase
    public func incompleteHeaderIsCorruption(): Unit {
        let log = rawLog("corrupt_header", [[1u8, 2u8]])
        let dir = dirOf("corrupt_header")
        try {
            @Assert(log.readAt(LogPosition(1, 0)).isNone())
            var thrown = false
            try {
                log.scanAfter(LogPosition(1, 0))
            } catch (_: QueueCorruptionException) {
                thrown = true
            }
            @Assert(thrown)
        } finally {
            log.close()
            clean(dir)
        }
    }

    @TestCase
    public func zeroLengthHeaderEndsTheStream(): Unit {
        let log = rawLog("zero_length", [header(0)])
        let dir = dirOf("zero_length")
        try {
            @Assert(log.readAt(LogPosition(1, 0)).isNone())
            let scanned = log.scanAfter(LogPosition(1, 0))
            @Assert(scanned[0] == 0)
        } finally {
            log.close()
            clean(dir)
        }
    }

    @TestCase
    public func corruptionDoesNotReadIntoNextSegment(): Unit {
        // 段 1 声明 1000 字节但只剩 3 字节；段 2 有合法记录，不得被读进来充数
        let log = rawLog("corrupt_cross", [concat(header(1000), [1u8, 2u8, 3u8]), concat(header(2), [9u8, 9u8])],
            maxFileSize: 16)
        let dir = dirOf("corrupt_cross")
        try {
            @Assert(log.readAt(LogPosition(1, 0)).isNone())
            var thrown = false
            try {
                log.scanAfter(LogPosition(1, 0))
            } catch (_: QueueCorruptionException) {
                thrown = true
            }
            @Assert(thrown)
        } finally {
            log.close()
            clean(dir)
        }
    }
}
