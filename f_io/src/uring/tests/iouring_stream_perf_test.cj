/*
Copyright (c) 2025 WuJingrun（吴京润）

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
package fountain::f_io.uring.tests

import std.unittest.testmacro.*
import std.fs.*
import std.time.*
import fountain::f_base.*
import fountain::f_io.*

/**
 * IOUringStream 与 File 的性能对比测试
 *
 * 对比相同负载下 IOUringStream 和 std.fs.File 的读写耗时。
 * 包含普通模式和注册缓冲区（Registered Buffers）模式。
 */
@When[os == "Linux"]
@Test
public class IOUringStreamPerfTest {

    private let tempDir: String = "/tmp/cj_uring_stream_perf"

    /** 写入总字节数 */
    static let TOTAL_BYTES: Int64 = 1024 * 1024  // 1 MB
    /** 每次写入块大小 */
    static let BLOCK_SIZE: Int64 = 4096          // 4 KB
    /** 迭代次数 */
    static let ITERATIONS: Int64 = TOTAL_BYTES / BLOCK_SIZE  // 256

    private func ensureTempDir(): Unit {
        try {
            Directory.create(tempDir, recursive: true)
        } catch (_: FSException) {}
    }

    /**
     * 使用 IOUringStream 写入并计时
     */
    @TestCase
    public func benchmarkIOUringStreamWrite(): Unit {
        ensureTempDir()
        let tempFile = File.createTemp(tempDir)
        let path = tempFile.info.path.toString()
        tempFile.close()

        let rwFile = File(path, OpenMode.ReadWrite)
        let fd = Int32(rwFile.fileDescriptor.fileHandle)

        let block = Array<Byte>(Int64(BLOCK_SIZE), repeat: 0xAA)

        // 预热
        try(stream = IOUringStream(fd)) {
            stream.write(block)
            stream.flush()
        }
        rwFile.close()

        // 正式测试
        let rwFile2 = File(path, OpenMode.ReadWrite)
        let fd2 = Int32(rwFile2.fileDescriptor.fileHandle)
        let start = MonoTime.now()
        try(stream = IOUringStream(fd2)) {
            for (_ in 0..ITERATIONS) {
                stream.write(block)
            }
        }
        let elapsed = MonoTime.now() - start
        rwFile2.close()

        let ns = elapsed.toNanoseconds()
        println("[IOUringStream Write] ${ITERATIONS} x ${BLOCK_SIZE}B = ${TOTAL_BYTES}B, ${ns}ns")
        @Expect(ns >= 0)

        removeIfExists(Path(path))
    }

    /**
     * 使用 File 写入 TOTAL_BYTES 数据并计时
     */
    @TestCase
    public func benchmarkFileWrite(): Unit {
        ensureTempDir()
        let tempFile = File.createTemp(tempDir)
        let path = tempFile.info.path.toString()
        tempFile.close()

        let block = Array<Byte>(Int64(BLOCK_SIZE), repeat: 0xAA)

        // 预热
        let warmupFile = File(path, OpenMode.Write)
        warmupFile.write(block)
        warmupFile.close()

        // 正式测试
        let rwFile = File(path, OpenMode.ReadWrite)
        let start = MonoTime.now()
        for (_ in 0..ITERATIONS) {
            rwFile.write(block)
        }
        let elapsed = MonoTime.now() - start
        rwFile.close()

        let ns = elapsed.toNanoseconds()
        println("[File Write] ${ITERATIONS} x ${BLOCK_SIZE}B = ${TOTAL_BYTES}B, ${ns}ns")
        @Expect(ns >= 0)

        removeIfExists(Path(path))
    }

    /**
     * 使用 IOUringStream 读取并计时
     */
    @TestCase
    public func benchmarkIOUringStreamRead(): Unit {
        ensureTempDir()
        let tempFile = File.createTemp(tempDir)
        let path = tempFile.info.path.toString()
        tempFile.close()

        // 先写入测试数据
        let block = Array<Byte>(Int64(BLOCK_SIZE), repeat: 0xBB)
        let writeFile = File(path, OpenMode.Write)
        for (_ in 0..ITERATIONS) {
            writeFile.write(block)
        }
        writeFile.close()

        // 正式读取测试（双ring架构：read同线程submit+waitCQE）
        let readFile = File(path, OpenMode.Read)
        let fd = Int32(readFile.fileDescriptor.fileHandle)
        let buf = Array<Byte>(Int64(BLOCK_SIZE), repeat: 0)

        let start = MonoTime.now()
        try(stream = IOUringStream(fd)) {
            var totalRead: Int64 = 0
            while (true) {
                let n = stream.read(buf)
                if (n <= 0) {
                    break
                }
                totalRead += n
            }
        }
        let elapsed = MonoTime.now() - start
        readFile.close()

        let ns = elapsed.toNanoseconds()
        println("[IOUringStream Read] ${TOTAL_BYTES}B, ${ns}ns")
        @Expect(ns >= 0)

        removeIfExists(Path(path))
    }

    /**
     * 使用 File 读取 TOTAL_BYTES 数据并计时
     */
    @TestCase
    public func benchmarkFileRead(): Unit {
        ensureTempDir()
        let tempFile = File.createTemp(tempDir)
        let path = tempFile.info.path.toString()
        tempFile.close()

        // 先写入测试数据
        let block = Array<Byte>(Int64(BLOCK_SIZE), repeat: 0xBB)
        let writeFile = File(path, OpenMode.Write)
        for (_ in 0..ITERATIONS) {
            writeFile.write(block)
        }
        writeFile.close()

        // 正式读取测试
        let readFile = File(path, OpenMode.Read)
        let buf = Array<Byte>(Int64(BLOCK_SIZE), repeat: 0)

        let start = MonoTime.now()
        var totalRead: Int64 = 0
        while (true) {
            let n = readFile.read(buf)
            if (n <= 0) {
                break
            }
            totalRead += n
        }
        let elapsed = MonoTime.now() - start
        readFile.close()

        let ns = elapsed.toNanoseconds()
        println("[File Read] ${TOTAL_BYTES}B, ${ns}ns")
        @Expect(ns >= 0)

        removeIfExists(Path(path))
    }

    /**
     * 使用 IOUringStream 注册缓冲区模式写入并计时
     */
    @TestCase
    public func benchmarkIOUringStreamFixedWrite(): Unit {
        ensureTempDir()
        let tempFile = File.createTemp(tempDir)
        let path = tempFile.info.path.toString()
        tempFile.close()

        let rwFile = File(path, OpenMode.ReadWrite)
        let fd = Int32(rwFile.fileDescriptor.fileHandle)

        let block = Array<Byte>(Int64(BLOCK_SIZE), repeat: 0xAA)

        // 预热
        try(stream = IOUringStream(fd, 64, fixedBufCount: 4, fixedBufSize: UInt32(BLOCK_SIZE))) {
            stream.write(block)
            stream.flush()
        }
        rwFile.close()

        // 正式测试
        let rwFile2 = File(path, OpenMode.ReadWrite)
        let fd2 = Int32(rwFile2.fileDescriptor.fileHandle)
        let start = MonoTime.now()
        try(stream = IOUringStream(fd2, 64, fixedBufCount: 4, fixedBufSize: UInt32(BLOCK_SIZE))) {
            for (_ in 0..ITERATIONS) {
                stream.write(block)
            }
        }
        let elapsed = MonoTime.now() - start
        rwFile2.close()

        let ns = elapsed.toNanoseconds()
        println("[IOUringStream FixedBuf Write] ${ITERATIONS} x ${BLOCK_SIZE}B = ${TOTAL_BYTES}B, ${ns}ns")
        @Expect(ns >= 0)

        removeIfExists(Path(path))
    }

    /**
     * 使用 IOUringStream 注册缓冲区模式读取并计时
     */
    @TestCase
    public func benchmarkIOUringStreamFixedRead(): Unit {
        ensureTempDir()
        let tempFile = File.createTemp(tempDir)
        let path = tempFile.info.path.toString()
        tempFile.close()

        // 先写入测试数据
        let block = Array<Byte>(Int64(BLOCK_SIZE), repeat: 0xBB)
        let writeFile = File(path, OpenMode.Write)
        for (_ in 0..ITERATIONS) {
            writeFile.write(block)
        }
        writeFile.close()

        // 正式读取测试
        let readFile = File(path, OpenMode.Read)
        let fd = Int32(readFile.fileDescriptor.fileHandle)
        let buf = Array<Byte>(Int64(BLOCK_SIZE), repeat: 0)

        let start = MonoTime.now()
        try(stream = IOUringStream(fd, 64, fixedBufCount: 4, fixedBufSize: UInt32(BLOCK_SIZE))) {
            var totalRead: Int64 = 0
            while (true) {
                let n = stream.read(buf)
                if (n <= 0) {
                    break
                }
                totalRead += n
            }
        }
        let elapsed = MonoTime.now() - start
        readFile.close()

        let ns = elapsed.toNanoseconds()
        println("[IOUringStream FixedBuf Read] ${TOTAL_BYTES}B, ${ns}ns")
        @Expect(ns >= 0)

        removeIfExists(Path(path))
    }
}
