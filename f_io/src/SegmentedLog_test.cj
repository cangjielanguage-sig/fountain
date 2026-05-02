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
import std.env.atExit

@Test
class SegmentedLogTest {
    private static func testDir(): String {
        "/tmp/f_io_test/segmented_log"
    }
    private static func cleanDir(): Unit {
        let dir = testDir()
        if (exists(dir)) {
            Directory.deleteIfExists(Path(dir), recursive: true)
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

        // firstFile 应有 400B，secondFile 应有 200B
        let f1 = File(firstFile, OpenMode.Read)
        @Assert(f1.info.size == 400)
        f1.close()
        let f2 = File(secondFile, OpenMode.Read)
        @Assert(f2.info.size == 200)
        f2.close()

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
            1024,
            100,
            fileExt: ".wal"
        )
        // 使用 initPath 构造器
        let log = SegmentedLog(config, initPath: customPath)

        let data = Array<Byte>(64, repeat: 0xDDu8)
        log.append(data)

        // 初始文件应为自定义路径
        @Assert(exists(customPath))

        // 轮转后使用 config 命名
        let bigData = Array<Byte>(512, repeat: 0xEEu8)
        log.append(bigData)  // 累计 576 < 1024，不触发
        log.append(bigData)  // 累计 1152 > 1024，触发 rotate
        let defaultFile = "${testDir()}/default_1.wal"
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
            4096,        // 4KB 确保在小规模测试中不触发轮转
            100,
            fileExt: ".log"
        )
        let log = SegmentedLog(config)
        let threadCount = 4
        let opsPerThread = 250
        let data = Array<Byte>(8, repeat: 0x42u8)  // 8B each

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

        // 验证文件总大小
        let filePath = "${testDir()}/conc_1.log"
        let info = File(filePath, OpenMode.Read).info
        let expectedSize = totalOps * data.size
        @Assert(info.size == expectedSize)

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
        Thread.sleep(Duration.millisecond * 100)
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
}
