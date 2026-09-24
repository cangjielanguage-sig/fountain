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
package fountain::f_uring.tests

import std.unittest.testmacro.*
import std.fs.*
import std.time.*
import std.sync.Mutex
import fountain::f_base.*
import fountain::f_io.*
import fountain::f_uring.base.*

/**
 * IOUringStream Read 路径微基准测试
 *
 * 精确拆解 read 路径每步操作的耗时，分析与 File.read 的性能差距来源。
 */
@When[os == "Linux"]
@Test
public class IOUringStreamReadMicroPerfTest {

    private let tempDir: String = "/tmp/cj_uring_read_micro"

    static let TOTAL_BYTES: Int64 = 1024 * 1024
    static let BLOCK_SIZE: Int64 = 4096
    static let ITERATIONS: Int64 = TOTAL_BYTES / BLOCK_SIZE

    private func ensureTempDir(): Unit {
        try {
            Directory.create(tempDir, recursive: true)
        } catch (_: FSException) {}
    }

    /**
     * 拆解 IOUringStream read 路径每步耗时
     */
    @TestCase
    public func microReadPathBreakdown(): Unit {
        ensureTempDir()
        let tempFile = File.createTemp(tempDir)
        let path = tempFile.info.path.toString()
        tempFile.close()

        // 写入测试数据
        let block = Array<Byte>(Int64(BLOCK_SIZE), repeat: 0xBB)
        let writeFile = File(path, OpenMode.Write)
        for (_ in 0..ITERATIONS) {
            writeFile.write(block)
        }
        writeFile.close()

        let readFile = File(path, OpenMode.Read)
        let fd = Int32(readFile.fileDescriptor.fileHandle)
        let ring = IoUring(64)
        let buf = Array<Byte>(Int64(BLOCK_SIZE), repeat: 0)

        var totalGetSQE: Int64 = 0
        var totalPrep: Int64 = 0
        var totalSubmit: Int64 = 0
        var totalWaitCQE: Int64 = 0
        var totalCQESeen: Int64 = 0
        var totalAcquireBuf: Int64 = 0

        var offset: UInt64 = 0
        for (i in 0..ITERATIONS) {
            let t0 = MonoTime.now()
            let sqeOpt = ring.getSQE()
            let t1 = MonoTime.now()

            unsafe {
                let t2 = MonoTime.now()
                let bufPtr = acquireArrayRawData(buf)
                let t3 = MonoTime.now()
                if (let Some(sqe) <- sqeOpt) {
                    ioUringPrepRead(sqe, fd, CPointer<Unit>(bufPtr.pointer), UInt32(BLOCK_SIZE), offset)
                    ioUringSQESetData64(sqe, UInt64(1))
                }
                let t4 = MonoTime.now()
                totalAcquireBuf += (t3 - t2).toNanoseconds()
                totalPrep += (t4 - t3).toNanoseconds()
            }

            let t5 = MonoTime.now()
            ring.submit()
            let t6 = MonoTime.now()

            let t7 = MonoTime.now()
            let cqeOpt = ring.waitCQE()
            let t8 = MonoTime.now()

            if (let Some(cqe) <- cqeOpt) {
                let result = ioUringCQEGetRes(cqe)
                let t9 = MonoTime.now()
                ring.cqeSeen(cqe)
                let t10 = MonoTime.now()
                if (result > 0) {
                    offset += UInt64(result)
                }
                totalCQESeen += (t10 - t9).toNanoseconds()
            }

            totalGetSQE += (t1 - t0).toNanoseconds()
            totalSubmit += (t6 - t5).toNanoseconds()
            totalWaitCQE += (t8 - t7).toNanoseconds()
        }

        ring.close()
        readFile.close()
        removeIfExists(Path(path))

        println("[Read Breakdown] ${ITERATIONS} iterations:")
        println("  getSQE:       ${totalGetSQE}ns total, ${totalGetSQE / ITERATIONS}ns/iter")
        println("  acquireBuf:   ${totalAcquireBuf}ns total, ${totalAcquireBuf / ITERATIONS}ns/iter")
        println("  prepRead+sqe: ${totalPrep}ns total, ${totalPrep / ITERATIONS}ns/iter")
        println("  submit:       ${totalSubmit}ns total, ${totalSubmit / ITERATIONS}ns/iter")
        println("  waitCQE:      ${totalWaitCQE}ns total, ${totalWaitCQE / ITERATIONS}ns/iter")
        println("  cqeSeen:      ${totalCQESeen}ns total, ${totalCQESeen / ITERATIONS}ns/iter")
        let total = totalGetSQE + totalAcquireBuf + totalPrep + totalSubmit + totalWaitCQE + totalCQESeen
        println("  TOTAL:        ${total}ns, ${total / ITERATIONS}ns/iter")

        @Expect(total > 0)
    }

    /**
     * 测试 submitAndWait 替代 submit + waitCQE
     */
    @TestCase
    public func microSubmitAndWait(): Unit {
        ensureTempDir()
        let tempFile = File.createTemp(tempDir)
        let path = tempFile.info.path.toString()
        tempFile.close()

        let block = Array<Byte>(Int64(BLOCK_SIZE), repeat: 0xBB)
        let writeFile = File(path, OpenMode.Write)
        for (_ in 0..ITERATIONS) {
            writeFile.write(block)
        }
        writeFile.close()

        let readFile = File(path, OpenMode.Read)
        let fd = Int32(readFile.fileDescriptor.fileHandle)
        let ring = IoUring(64)
        let buf = Array<Byte>(Int64(BLOCK_SIZE), repeat: 0)

        var totalSubmitAndWait: Int64 = 0
        var totalPeekCQE: Int64 = 0
        var totalCQESeen: Int64 = 0

        var offset: UInt64 = 0
        for (i in 0..ITERATIONS) {
            let sqeOpt = ring.getSQE()
            if (let Some(sqe) <- sqeOpt) {
                unsafe {
                    let bufPtr = acquireArrayRawData(buf)
                    ioUringPrepRead(sqe, fd, CPointer<Unit>(bufPtr.pointer), UInt32(BLOCK_SIZE), offset)
                    ioUringSQESetData64(sqe, UInt64(1))
                }
            }

            let t0 = MonoTime.now()
            ring.submitAndWait(1)
            let t1 = MonoTime.now()

            let t2 = MonoTime.now()
            let cqeOpt = ring.peekCQE()
            let t3 = MonoTime.now()

            if (let Some(cqe) <- cqeOpt) {
                let result = ioUringCQEGetRes(cqe)
                let t4 = MonoTime.now()
                ring.cqeSeen(cqe)
                let t5 = MonoTime.now()
                if (result > 0) {
                    offset += UInt64(result)
                }
                totalCQESeen += (t5 - t4).toNanoseconds()
            }

            totalSubmitAndWait += (t1 - t0).toNanoseconds()
            totalPeekCQE += (t3 - t2).toNanoseconds()
        }

        ring.close()
        readFile.close()
        removeIfExists(Path(path))

        println("[submitAndWait Breakdown] ${ITERATIONS} iterations:")
        println("  submitAndWait: ${totalSubmitAndWait}ns total, ${totalSubmitAndWait / ITERATIONS}ns/iter")
        println("  peekCQE:       ${totalPeekCQE}ns total, ${totalPeekCQE / ITERATIONS}ns/iter")
        println("  cqeSeen:       ${totalCQESeen}ns total, ${totalCQESeen / ITERATIONS}ns/iter")
        let total = totalSubmitAndWait + totalPeekCQE + totalCQESeen
        println("  TOTAL:         ${total}ns, ${total / ITERATIONS}ns/iter")

        @Expect(total > 0)
    }

    /**
     * File.read 基准测试（对照组）
     */
    @TestCase
    public func microFileRead(): Unit {
        ensureTempDir()
        let tempFile = File.createTemp(tempDir)
        let path = tempFile.info.path.toString()
        tempFile.close()

        let block = Array<Byte>(Int64(BLOCK_SIZE), repeat: 0xBB)
        let writeFile = File(path, OpenMode.Write)
        for (_ in 0..ITERATIONS) {
            writeFile.write(block)
        }
        writeFile.close()

        let readFile = File(path, OpenMode.Read)
        let buf = Array<Byte>(Int64(BLOCK_SIZE), repeat: 0)

        let start = MonoTime.now()
        for (_ in 0..ITERATIONS) {
            readFile.read(buf)
        }
        let elapsed = MonoTime.now() - start
        readFile.close()

        let ns = elapsed.toNanoseconds()
        println("[File Read] ${TOTAL_BYTES}B, ${ns}ns, ${ns / ITERATIONS}ns/iter")
        @Expect(ns >= 0)

        removeIfExists(Path(path))
    }

    /**
     * Mutex synchronized 开销测量
     */
    @TestCase
    public func microMutexOverhead(): Unit {
        let mutex = Mutex()
        var counter: Int64 = 0

        let start = MonoTime.now()
        for (_ in 0..ITERATIONS) {
            synchronized(mutex) {
                counter += 1
            }
        }
        let elapsed = MonoTime.now() - start

        let ns = elapsed.toNanoseconds()
        println("[Mutex Overhead] ${ITERATIONS} iterations, ${ns}ns total, ${ns / ITERATIONS}ns/iter")
        @Expect(counter == ITERATIONS)
    }
}
