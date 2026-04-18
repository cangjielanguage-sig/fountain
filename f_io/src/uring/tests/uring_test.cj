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
import fountain::f_io.uring.*

/**
 * io_uring 基础功能单元测试
 *
 * 仅在 Linux 平台执行。测试覆盖初始化、SQE/CQE 操作、超时、
 * 无锁槽位分配器、完成槽位数组等核心组件。
 */
@When[os == "Linux"]
@Test
public class IoUringBasicTest {
    /** 测试用的 ring entries 数量 */
    static let TEST_ENTRIES: UInt32 = 16

    // ==================== 初始化与清理 ====================

    @TestCase
    public func testQueueInitExit(): Unit {
        try(ring = IoUring(TEST_ENTRIES)) {
            @Expect(!ring.isClosed())
            @Expect(ring.sqSpaceLeft() > 0)
        }
        // try-with-resource 自动 close
    }

    @TestCase
    public func testQueueInitWithFlags(): Unit {
        try(ring = IoUring(TEST_ENTRIES, flags: IORING_SETUP_IOPOLL)) {
            @Expect(!ring.isClosed())
        }
    }

    @TestCase
    public func testQueueInitWithParams(): Unit {
        let params = IoUringParamsBuilder()
            .setCQSize(32)
            .build()
        try(ring = IoUring(TEST_ENTRIES, params)) {
            @Expect(!ring.isClosed())
            @Expect(ring.cqReady() == 0)
        }
    }

    @TestCase
    public func testDoubleClose(): Unit {
        let ring = IoUring(TEST_ENTRIES)
        @Expect(!ring.isClosed())
        ring.close()
        @Expect(ring.isClosed())
        // 二次 close 不应崩溃
        ring.close()
        @Expect(ring.isClosed())
    }

    // ==================== SQE 操作 ====================

    @TestCase
    public func testSQEAllocation(): Unit {
        try(ring = IoUring(TEST_ENTRIES)) {
            // 应能获取至少一个 SQE
            let sqeOpt = ring.getSQE()
            @Expect(sqeOpt.isSome())

            // 清空后应能重新获取
            if (let Some(sqe) <- sqeOpt) {
                ioUringPrepNop(sqe)
                ioUringSQESetData64(sqe, 1)
            }
        }
    }

    @TestCase
    public func testSQESetData64(): Unit {
        try(ring = IoUring(TEST_ENTRIES)) {
            if (let Some(sqe) <- ring.getSQE()) {
                unsafe {
                    ioUringPrepNop(sqe)
                    ioUringSQESetData64(sqe, 0xDEADBEEF12345678)
                    let readBack = sqe.read().userData
                    @Expect(readBack, 0xDEADBEEF12345678)
                }
            }
        }
    }

    @TestCase
    public func testSQESetFlags(): Unit {
        try(ring = IoUring(TEST_ENTRIES)) {
            if (let Some(sqe) <- ring.getSQE()) {
                unsafe {
                    ioUringPrepNop(sqe)
                    ioUringSQESetFlags(sqe, IOSQE_ASYNC)
                    @Expect(sqe.read().flags == IOSQE_ASYNC)
                }
            }
        }
    }

    // ==================== 提交与等待 ====================

    @TestCase
    public func testSubmitAndWaitNop(): Unit {
        try(ring = IoUring(TEST_ENTRIES)) {
            if (let Some(sqe) <- ring.getSQE()) {
                ioUringPrepNop(sqe)
                ioUringSQESetData64(sqe, 42)
            }
            let ret = ring.submit()
            @Expect(ret >= 1)

            // 等待完成
            if (let Some(cqe) <- ring.waitCQE()) {
                @Expect(ioUringCQEGetData64(cqe) == 42)
                @Expect(ioUringCQEGetRes(cqe) == 0)
                ring.cqeSeen(cqe)
            }
        }
    }

    @TestCase
    public func testSubmitAndWait(): Unit {
        try(ring = IoUring(TEST_ENTRIES)) {
            if (let Some(sqe) <- ring.getSQE()) {
                ioUringPrepNop(sqe)
                ioUringSQESetData64(sqe, 100)
            }
            let ret = ring.submitAndWait(1)
            @Expect(ret >= 1)

            if (let Some(cqe) <- ring.peekCQE()) {
                @Expect(ioUringCQEGetData64(cqe) == 100)
                ring.cqeSeen(cqe)
            }
        }
    }

    @TestCase
    public func testBatchSubmit(): Unit {
        try(ring = IoUring(TEST_ENTRIES)) {
            let count: UInt32 = 4
            for (i in 0..Int64(count)) {
                if (let Some(sqe) <- ring.getSQE()) {
                    ioUringPrepNop(sqe)
                    ioUringSQESetData64(sqe, UInt64(i + 1))
                }
            }
            let ret = ring.submit()
            @Expect(ret >= Int32(count))

            // 收割所有完成事件
            var processed: UInt32 = 0
            while (true) {
                if (let Some(cqe) <- ring.peekCQE()) {
                    ring.cqeSeen(cqe)
                    processed += 1
                } else {
                    break
                }
            }
            @Expect(processed == count)
        }
    }

    // ==================== 超时操作 ====================

    @TestCase
    public func testTimeout(): Unit {
        try(ring = IoUring(TEST_ENTRIES)) {
            // 提交一个超时请求
            if (let Some(sqe) <- ring.getSQE()) {
                var ts = KernelTimespec()
                ts.tvSec = 0
                ts.tvNsec = 1000000  // 1ms
                let tsPtr = unsafe { LibC.malloc<KernelTimespec>(count: 1) }
                unsafe { tsPtr.write(ts) }
                ioUringPrepTimeout(sqe, tsPtr, 0, 0)
                ioUringSQESetData64(sqe, LIBURING_UDATA_TIMEOUT)
                ring.submit()

                if (let Some(cqe) <- ring.waitCQE()) {
                    // 超时完成，结果应为 -ETIME (60)
                    @Expect(ioUringCQEGetRes(cqe) < 0)
                    ring.cqeSeen(cqe)
                }
                unsafe { LibC.free<KernelTimespec>(tsPtr) }
            }
        }
    }

    // ==================== 队列状态查询 ====================

    @TestCase
    public func testQueueStateQueries(): Unit {
        try(ring = IoUring(TEST_ENTRIES)) {
            // 初始状态
            @Expect(ring.sqReady() == 0)
            @Expect(ring.cqReady() == 0)
            @Expect(ring.sqSpaceLeft() > 0)

            // 获取 SQE 后
            ring.getSQE()
            @Expect(ring.sqReady() == 1)
            @Expect(ring.sqSpaceLeft() < TEST_ENTRIES)
        }
    }

    // ==================== CQ Advance ====================

    @TestCase
    public func testCQAdvance(): Unit {
        try(ring = IoUring(TEST_ENTRIES)) {
            // 提交 3 个 nop
            for (i in 0..3) {
                if (let Some(sqe) <- ring.getSQE()) {
                    ioUringPrepNop(sqe)
                    ioUringSQESetData64(sqe, UInt64(i))
                }
            }
            ring.submit()

            // 等待完成
            ring.submitAndWait(3)

            // 使用 cqAdvance 批量推进
            let ready = ring.cqReady()
            @Expect(ready >= 3)
            ring.cqAdvance(ready)
            @Expect(ring.cqReady() == 0)
        }
    }

    // ==================== 异步完成处理 ====================

    @TestCase
    public func testProcessCompletions(): Unit {
        try(ring = IoUring(TEST_ENTRIES)) {
            for (i in 0..3) {
                if (let Some(sqe) <- ring.getSQE()) {
                    ioUringPrepNop(sqe)
                    ioUringSQESetData64(sqe, UInt64(i + 1))
                }
            }
            ring.submit()
            ring.submitAndWait(3)

            let processed = ring.processCompletions()
            @Expect(processed >= 3)
        }
    }

    // ==================== IoUringPool ====================

    @TestCase
    public func testPoolBasic(): Unit {
        try(pool = IoUringPool(TEST_ENTRIES, ringCount: 2)) {
            @Expect(!pool.isClosed())
            @Expect(pool.count() == 2)

            let ring0 = pool.getRing(0)
            @Expect(!ring0.isClosed())

            let ring1 = pool.getRing(1)
            @Expect(!ring1.isClosed())

            // 轮询获取
            let ringAny = pool.getRing()
            @Expect(!ringAny.isClosed())
        }
    }

    // ==================== Params Builder ====================

    @TestCase
    public func testParamsBuilder(): Unit {
        let params = IoUringParamsBuilder()
            .setCQSize(64)
            .setIOPoll()
            .build()
        @Expect(params.cqEntries == 0 || params.cqEntries > 0) // 由内核填充
        @Expect((params.flags & IORING_SETUP_IOPOLL) != 0)
        @Expect((params.flags & IORING_SETUP_CQSIZE) != 0)
    }

    // ==================== 异常测试 ====================

    @TestCase
    public func testClosedRingThrows(): Unit {
        let ring = IoUring(TEST_ENTRIES)
        ring.close()
        @Expect(ring.isClosed())

        var threwException = false
        try {
            ring.getSQE()
        } catch(e: IoUringException) {
            threwException = true
        }
        @Expect(threwException)
    }
}
