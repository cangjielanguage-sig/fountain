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
package fountain::f_io

import std.unittest.*
import std.unittest.testmacro.*
import std.fs.*
import std.sync.*
import std.env.atExit
import std.io.InputStream
import std.time.*
import std.collection.ArrayList

@Test
class SegmentedLogTest {
    private static func testDir(): String {
        "/tmp/f_io_test/segmented_log"
    }
    private static func cleanDir(): Unit {
        let dir = testDir()
        if (exists(dir)) {
            Directory.walk(dir) { fi: FileInfo =>
                if (!fi.isDirectory()) {
                    remove(fi.path.toString())
                }
                true
            }
        }
    }

    @TestCase
    public func basicAppendAndRotate(): Unit {
        cleanDir()
        atExit { cleanDir() }

        let config = LogConfig(
            testDir(),
            "test",
            1024,        // maxFileSize: 1KB
            100,         // syncInterval
            fileExt: ".log"
        )
        let log = SegmentedLog(config)
        // append 时 SegmentedLog.startSeq=1 → 初始文件 test_1.log

        // 写入小数据（不触发轮转）
        let data1 = Array<Byte>(128, repeat: 0x41u8)
        let pos1 = log.append(data1)
        @Assert(pos1.seq == 1)
        @Assert(pos1.offset == 0)

        // 写入更多数据（仍不触发轮转：累计 256 < 1024）
        let data2 = Array<Byte>(128, repeat: 0x42u8)
        let pos2 = log.append(data2)
        @Assert(pos2.seq == 1)
        @Assert(pos2.offset == 128)

        // 验证文件存在
        let filePath = "${testDir()}/test_1.log"
        @Assert(exists(filePath))
        let info = File(filePath, OpenMode.Read).info
        @Assert(info.size >= 256)

        // 验证数据可读回
        let f = File(filePath, OpenMode.Read)
        let buf = Array<Byte>(256, repeat: 0u8)
        let n = f.read(buf)
        f.close()
        @Assert(n == 256)
        @Assert(buf[0..128] == data1)
        @Assert(buf[128..256] == data2)

        log.close()
    }

    @TestCase
    public func rotationAtFileSizeThreshold(): Unit {
        cleanDir()
        atExit { cleanDir() }

        let config = LogConfig(
            testDir(),
            "rot",
            512,         // maxFileSize: 512B
            100,
            fileExt: ".wal"
        )
        let log = SegmentedLog(config)

        // 写入 3 条 200B 数据 → 累计 600 > 512，应触发轮转
        let data = Array<Byte>(200, repeat: 0xABu8)
        log.append(data)  // seq=1, offset=0
        log.append(data)  // seq=1, offset=200
        let pos3 = log.append(data)  // 触发 rotate → seq=2, offset=0
        @Assert(pos3.seq == 2)
        @Assert(pos3.offset == 0)

        let firstFile = "${testDir()}/rot_1.wal"
        let secondFile = "${testDir()}/rot_2.wal"
        @Assert(exists(firstFile))
        @Assert(exists(secondFile))

        // 验证第二个文件有写入数据（读取回检查）
        let f2 = File(secondFile, OpenMode.Read)
        let buf = Array<Byte>(200, repeat: 0u8)
        let n = f2.read(buf)
        f2.close()
        @Assert(n == 200)
        @Assert(buf == data)

        log.close()
    }

    @TestCase
    public func takeOldFilesReturnsRotatedPaths(): Unit {
        cleanDir()
        atExit { cleanDir() }

        let config = LogConfig(
            testDir(),
            "old",
            200,
            100,
            fileExt: ".wal"
        )
        let log = SegmentedLog(config)

        // 写入数据触发轮转
        let data = Array<Byte>(150, repeat: 0x01u8)
        log.append(data)  // seq=1, offset=0
        log.append(data)  // 触发 rotate → seq=2, offset=0
        log.append(data)  // 触发 rotate → seq=3, offset=0

        // takeOldFiles 应返回旧文件路径
        let oldFiles = log.takeOldFiles()
        @Assert(oldFiles.size == 2)
        @Assert(oldFiles[0].contains("old_1.wal"))
        @Assert(oldFiles[1].contains("old_2.wal"))

        // 再次调用应返回空列表（已清空）
        let emptyFiles = log.takeOldFiles()
        @Assert(emptyFiles.size == 0)

        log.close()
    }

    @TestCase
    public func initPathPreservesCustomPath(): Unit {
        cleanDir()
        atExit { cleanDir() }

        let customPath = "${testDir()}/my_custom.wal"
        let config = LogConfig(
            testDir(),
            "default",
            512,
            100,
            fileExt: ".wal"
        )
        // 使用 initPath 构造器
        let log = SegmentedLog(config, customPath)

        let data = Array<Byte>(64, repeat: 0xDDu8)
        log.append(data)

        // 初始文件应为自定义路径
        @Assert(exists(customPath))

        // 轮转：maxFileSize=512，每条 320B，2 条(640>512)即触发 rotate
        let bigData = Array<Byte>(320, repeat: 0xEEu8)
        log.append(bigData)  // 累计 64+320=384 < 512，不触发
        log.append(bigData)  // 累计 384+320=704 > 512，触发 rotate
        let defaultFile = "${testDir()}/default_2.wal"
        @Assert(exists(defaultFile))

        log.close()
    }

    @TestCase
    public func closeMakesAppendThrow(): Unit {
        cleanDir()
        atExit { cleanDir() }

        let config = LogConfig(
            testDir(),
            "close",
            1024,
            100,
            fileExt: ".log"
        )
        let log = SegmentedLog(config)
        log.close()

        var threw = false
        try {
            log.append([0x01u8])
        } catch (_: LogClosedException) {
            threw = true
        }
        @Assert(threw)
    }

    @TestCase
    public func closeIsIdempotent(): Unit {
        cleanDir()
        atExit { cleanDir() }

        let config = LogConfig(
            testDir(),
            "idem",
            1024,
            100,
            fileExt: ".log"
        )
        let log = SegmentedLog(config)
        log.close()
        // 第二次 close 不抛异常
        log.close()
        @Assert(log.isClosed())
    }

    @TestCase
    public func rotateAfterCloseNoOp(): Unit {
        cleanDir()
        atExit { cleanDir() }

        let config = LogConfig(
            testDir(),
            "rotclose",
            200,
            100,
            fileExt: ".log"
        )
        let log = SegmentedLog(config)
        log.close()
        // close 后 rotate 不应抛异常
        log.rotate()
    }

    @TestCase
    public func concurrentAppendNoDataLoss(): Unit {
        cleanDir()
        atExit { cleanDir() }

        let config = LogConfig(
            testDir(),
            "conc",
            65536,       // 64KB 足够容纳所有并发写入，不触发轮转
            100,
            fileExt: ".log"
        )
        let log = SegmentedLog(config)
        let threadCount = 4
        let opsPerThread = 100
        let data = Array<Byte>(16, repeat: 0x42u8)  // 16B each

        let futures = Array<Future<Int64>>(threadCount) { _ =>
            spawn {
                var count: Int64 = 0
                for (_ in 0..opsPerThread) {
                    log.append(data)
                    count += 1
                }
                count
            }
        }

        var totalOps: Int64 = 0
        for (f in futures) {
            totalOps += f.get()
        }
        @Assert(totalOps == threadCount * opsPerThread)

        // 验证数据完整（通过读取文件验证总写入量）
        let filePath = "${testDir()}/conc_1.log"
        let f = File(filePath, OpenMode.Read)
        let buf = Array<Byte>(totalOps * data.size, repeat: 0u8)
        let n = f.read(buf)
        f.close()
        @Assert(n == totalOps * data.size)

        log.close()
    }

    @TestCase
    public func syncDoesNotPanic(): Unit {
        cleanDir()
        atExit { cleanDir() }

        let config = LogConfig(
            testDir(),
            "sync",
            1024,
            100,
            fileExt: ".log"
        )
        let log = SegmentedLog(config)
        log.append([0x01u8])
        log.sync()  // 不应抛异常
        log.close()
    }

    @TestCase
    public func rotationConcurrentNoLeak(): Unit {
        cleanDir()
        atExit { cleanDir() }

        // 极小 maxFileSize（128B）确保频繁轮转
        let config = LogConfig(
            testDir(),
            "concurrent_rot",
            128,
            100,
            fileExt: ".wal"
        )
        let log = SegmentedLog(config)
        let writerCount = 2
        let data = Array<Byte>(32, repeat: 0x88u8)
        let running = AtomicBool(true)

        let writers = Array<Future<Int64>>(writerCount) { _ =>
            spawn {
                var count: Int64 = 0
                while (running.load()) {
                    try {
                        log.append(data)
                        count += 1
                    } catch (_: LogClosedException) {
                        break
                    }
                }
                count
            }
        }

        // 写 100ms 后停止
        sleep(Duration.millisecond * 100)
        running.store(false)

        var totalOps: Int64 = 0
        for (w in writers) {
            totalOps += w.get()
        }
        @Assert(totalOps > 0)

        // 轮转后的旧文件应由 takeOldFiles 管理
        let oldFiles = log.takeOldFiles()
        for (path in oldFiles) {
            @Assert(exists(path))
        }

        log.close()
    }

    // ===== 段元数据 / 按序号或时间删除 / 编号单调 / 定位读取 =====

    /** 把流读干，返回全部字节 */
    private static func readAll(stream: InputStream): Array<Byte> {
        let buf = Array<Byte>(16, repeat: 0u8)
        let out = ArrayList<Byte>()
        while (true) {
            let n = stream.read(buf)
            if (n <= 0) { break }
            for (i in 0..n) {
                out.add(buf[i])
            }
        }
        // openEntryStream 的声明类型是 InputStream，关流要转成 Resource
        if (let Some(res) <- (stream as Resource)) {
            res.close()
        }
        Array<Byte>(out.size) { i => out[i] }
    }

    /** 按顺序拼接多段字节 */
    private static func join(parts: Array<Array<Byte>>): Array<Byte> {
        let out = ArrayList<Byte>()
        for (p in parts) {
            for (b in p) {
                out.add(b)
            }
        }
        Array<Byte>(out.size) { i => out[i] }
    }

    /** FileInfo 的时间戳只精确到秒，跨秒才能把两批文件的时间分开 */
    private static func crossSecond(): Unit {
        sleep(Duration.second + Duration.millisecond * 300)
    }

    @TestCase
    public func logMetasListsSegmentsWithSizeAndTimes(): Unit {
        cleanDir()
        atExit { cleanDir() }
        let log = SegmentedLog(LogConfig(testDir(), "meta", 100, 100, fileExt: ".seg"))
        let data = Array<Byte>(60, repeat: 0x11u8)
        log.append(data)
        log.append(data)
        log.append(data) // 段 1、2 封口，段 3 为当前

        let metas = log.logMetas()
        @Assert(metas.size == 3)
        @Assert(metas[0].index == 1)
        @Assert(metas[1].index == 2)
        @Assert(metas[2].index == 3)
        @Assert(!metas[0].last)
        @Assert(!metas[1].last)
        @Assert(metas[2].last)
        // 封口段截断到实际写入长度，当前段取已写入字节数（都不是预分配的 maxFileSize）
        @Assert(metas[0].size == 60)
        @Assert(metas[1].size == 60)
        @Assert(metas[2].size == 60)
        @Assert(FileInfo("${testDir()}/meta_2.seg").size == 60)
        @Assert(metas[0].creationTime <= metas[2].creationTime)
        @Assert(metas[0].updateTime <= metas[2].updateTime)

        log.close()
        // 关闭后当前段同样被截断
        @Assert(FileInfo("${testDir()}/meta_3.seg").size == 60)
        let afterClose = log.logMetas()
        @Assert(afterClose.size == 3)
        @Assert(afterClose[2].size == 60)
        @Assert(afterClose[2].last)
    }

    @TestCase
    public func segmentNumberNeverReusedAfterDeleteOrReopen(): Unit {
        cleanDir()
        atExit { cleanDir() }
        let config = LogConfig(testDir(), "mono", 100, 100, fileExt: ".seg")
        let log = SegmentedLog(config)
        let data = Array<Byte>(60, repeat: 0x22u8)
        log.append(data)
        log.append(data)
        log.append(data) // 段 1、2 封口，段 3 为当前
        log.removeById(1)
        log.removeById(2)
        log.rotate() // 新段编号 = 最新编号 + 1 → 4，不复用 1/2
        var metas = log.logMetas()
        @Assert(metas.size == 2)
        @Assert(metas[0].index == 3)
        @Assert(metas[1].index == 4)
        @Assert(metas[1].last)
        @Assert(!exists("${testDir()}/mono_1.seg"))
        @Assert(!exists("${testDir()}/mono_2.seg"))
        log.close()

        // 重新打开同一目录：基于目录里最新编号 + 1 = 5
        let reopened = SegmentedLog(config)
        metas = reopened.logMetas()
        @Assert(metas.size == 3)
        @Assert(metas[2].index == 5)
        @Assert(metas[2].last)
        @Assert(reopened.append(data).seq == 5)
        reopened.close()
    }

    @TestCase
    public func removeByIdRemovesSealedSegmentOnly(): Unit {
        cleanDir()
        atExit { cleanDir() }
        let log = SegmentedLog(LogConfig(testDir(), "rid", 100, 100, fileExt: ".seg"))
        let data = Array<Byte>(60, repeat: 0x33u8)
        log.append(data)
        log.append(data)
        log.append(data) // 段 3 为当前

        // 当前段不能被删除：显式指名时报错，而不是静默丢数据
        var threw = false
        try {
            log.removeById(3)
        } catch (_: IllegalArgumentException) {
            threw = true
        }
        @Assert(threw)
        @Assert(exists("${testDir()}/rid_3.seg"))

        // 不存在的编号：幂等空操作
        log.removeById(99)

        log.removeById(1)
        @Assert(!exists("${testDir()}/rid_1.seg"))
        let metas = log.logMetas()
        @Assert(metas.size == 2)
        @Assert(metas[0].index == 2)
        // 已删除的段不再出现在 takeOldFiles 里，外部清理不会重复处理
        let oldFiles = log.takeOldFiles()
        @Assert(oldFiles.size == 1)
        @Assert(oldFiles[0].contains("rid_2.seg"))
        log.close()
    }

    @TestCase
    public func removeBetweenIndexRangeRespectsInterval(): Unit {
        cleanDir()
        atExit { cleanDir() }
        let log = SegmentedLog(LogConfig(testDir(), "rng", 100, 100, fileExt: ".seg"))
        let data = Array<Byte>(60, repeat: 0x44u8)
        log.append(data)
        log.append(data)
        log.append(data)
        log.append(data) // 段 1、2、3 封口，段 4 为当前

        log.removeBetween(1..3) // [1, 3) → 删 1、2
        var metas = log.logMetas()
        @Assert(metas.size == 2)
        @Assert(metas[0].index == 3)
        @Assert(metas[1].index == 4)

        log.removeBetween(3..=3) // 闭区间 → 删 3
        metas = log.logMetas()
        @Assert(metas.size == 1)
        @Assert(metas[0].index == 4)
        @Assert(metas[0].last)
        log.close()
    }

    @TestCase
    public func removeCreatedBeforeAndAfter(): Unit {
        cleanDir()
        atExit { cleanDir() }
        let log = SegmentedLog(LogConfig(testDir(), "ctime", 100, 100, fileExt: ".seg"))
        let data = Array<Byte>(60, repeat: 0x55u8)
        log.append(data)
        log.append(data)
        log.append(data) // 段 1、2 封口，段 3 为当前
        crossSecond()
        let boundary = DateTime.now() // 边界：早于它的段（1、2）与晚于它的段（3）
        crossSecond()
        log.append(data) // 段 3 封口（时间晚于 boundary），段 4 为当前

        log.removeCreatedAfter(boundary) // 删 3；1、2 与当前段 4 保留
        var metas = log.logMetas()
        @Assert(metas.size == 3)
        @Assert(metas[0].index == 1)
        @Assert(metas[1].index == 2)
        @Assert(metas[2].index == 4)

        log.removeCreatedBefore(boundary) // 删 1、2；当前段 4 保留
        metas = log.logMetas()
        @Assert(metas.size == 1)
        @Assert(metas[0].index == 4)
        @Assert(metas[0].last)
        log.close()
    }

    @TestCase
    public func removeUpdatedBeforeAndAfter(): Unit {
        cleanDir()
        atExit { cleanDir() }
        let log = SegmentedLog(LogConfig(testDir(), "utime", 100, 100, fileExt: ".seg"))
        let data = Array<Byte>(60, repeat: 0x66u8)
        log.append(data)
        log.append(data)
        log.append(data) // 段 1、2 封口，段 3 为当前；三者的最后写入都在同一秒
        let boundary = DateTime.now()
        crossSecond()
        log.append(data) // 段 3 封口（封口不写数据，updateTime 仍是旧秒），段 4 为当前
        crossSecond()
        log.append(data) // 段 4 封口，段 5 为当前

        // 封口时的截断会把封口段的 updateTime 刷新为封口时刻，因此这里按「片段封口时刻」划分：
        // 1、2 封口于第一秒（早于 boundary）；3 封口于第二秒、4 封口于第三秒（晚于 boundary）
        log.removeUpdatedBefore(boundary)
        var metas = log.logMetas()
        @Assert(metas.size == 3)
        @Assert(metas[0].index == 3)
        @Assert(metas[1].index == 4)
        @Assert(metas[2].index == 5)

        // 最后写入晚于 boundary 的封口段：4 → 删除
        log.removeUpdatedAfter(boundary)
        metas = log.logMetas()
        @Assert(metas.size == 1)
        @Assert(metas[0].index == 5)
        @Assert(metas[0].last)
        log.close()
    }

    @TestCase
    public func removeBetweenCreatedTimeHalfOpen(): Unit {
        cleanDir()
        atExit { cleanDir() }
        let log = SegmentedLog(LogConfig(testDir(), "btw", 100, 100, fileExt: ".seg"))
        let data = Array<Byte>(60, repeat: 0x77u8)
        log.append(data)
        log.append(data)
        log.append(data) // 段 1、2 封口，段 3 为当前
        let start = DateTime.now()
        crossSecond()
        log.append(data) // 段 3 封口（时间晚于 start），段 4 为当前
        let end = DateTime.now()

        log.removeBetween(start, end) // [start, end) → 只删 3
        let metas = log.logMetas()
        @Assert(metas.size == 3)
        @Assert(metas[0].index == 1)
        @Assert(metas[1].index == 2)
        @Assert(metas[2].index == 4)
        log.close()
    }

    @TestCase
    public func openEntryStreamFromIndexAndOffset(): Unit {
        cleanDir()
        atExit { cleanDir() }
        let log = SegmentedLog(LogConfig(testDir(), "read", 100, 100, fileExt: ".seg"))
        let a = Array<Byte>(60, repeat: 0xAAu8)
        let b = Array<Byte>(60, repeat: 0xBBu8)
        let c = Array<Byte>(60, repeat: 0xCCu8)
        log.append(a)
        log.append(b)
        log.append(c) // 段 1、2 封口，段 3 为当前

        // 从段 1 起：a + b + c
        @Assert(readAll(log.openEntryStream(1, 0)) == join([a, b, c]))
        // 从段 1 的第 30 字节起：a[30..60] + b + c
        @Assert(readAll(log.openEntryStream(1, 30)) == join([a[30..60], b, c]))
        // 从段 2 的第 10 字节起：b[10..60] + c
        @Assert(readAll(log.openEntryStream(2, 10)) == join([b[10..60], c]))
        // 从当前段（3）的第 5 字节起：读已写入长度，不读预分配区
        @Assert(readAll(log.openEntryStream(3, 5)) == c[5..60])
        // 起点越过当前段末尾：空流
        @Assert(readAll(log.openEntryStream(3, 999)).size == 0)

        // 已删除/不存在的段号：报错而不是静默从头读
        log.removeById(1)
        var threw = false
        try {
            readAll(log.openEntryStream(1, 0))
        } catch (_: IllegalArgumentException) {
            threw = true
        }
        @Assert(threw)
        // 段 1 删除后，从段 2 起仍可正常读到末尾
        @Assert(readAll(log.openEntryStream(2, 0)) == join([b, c]))
        // 负偏移：报错
        threw = false
        try {
            log.openEntryStream(2, -1)
        } catch (_: IllegalArgumentException) {
            threw = true
        }
        @Assert(threw)
        log.close()
    }

    @TestCase
    public func initPathKeepsNumberingMonotonic(): Unit {
        cleanDir()
        atExit { cleanDir() }
        let config = LogConfig(testDir(), "seed", 100, 100, fileExt: ".seg")
        let data = Array<Byte>(60, repeat: 0x88u8)
        // 先造出 seed_1、seed_2
        let seed = SegmentedLog(config)
        seed.append(data)
        seed.append(data)
        seed.close()

        // 指定自定义初始文件：rotate 产生的新段不能复用已存在的编号
        let log = SegmentedLog(config, "${testDir()}/custom.wal")
        log.append(data)
        log.rotate()
        @Assert(exists("${testDir()}/seed_3.seg"))
        @Assert(exists("${testDir()}/seed_1.seg"))
        @Assert(exists("${testDir()}/seed_2.seg"))
        let metas = log.logMetas()
        @Assert(metas.size == 3)
        @Assert(metas[0].index == 1)
        @Assert(metas[1].index == 2)
        @Assert(metas[2].index == 3)
        @Assert(metas[2].last)
        log.close()
    }

    @TestCase
    public func appendPositionIsReadableAndReusable(): Unit {
        cleanDir()
        atExit { cleanDir() }
        // 每段 100 字节，写入 60 字节的数据 ⇒ 第二条必然轮转到新段
        let log = SegmentedLog(LogConfig(testDir(), "pos", 100, 100, fileExt: ".seg"))
        let a = Array<Byte>(60, repeat: 0xA1u8)
        let b = Array<Byte>(60, repeat: 0xB2u8)
        let posA = log.append(a)
        let posB = log.append(b)

        // append 返回的位置字段可读（跨模块读取依赖 public 可见性）
        @Assert(posA.seq == 1)
        @Assert(posA.offset == 0)
        @Assert(posB.seq == 2)
        @Assert(posB.offset == 0)

        // 两个字段可原样回传 openEntryStream 并续读到末尾
        @Assert(readAll(log.openEntryStream(posA.seq, posA.offset)) == join([a, b]))
        @Assert(readAll(log.openEntryStream(posB.seq, posB.offset)) == join([b]))
        log.close()
    }
}
