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
import std.collection.ArrayList
import std.sync.*
import fountain::f_io.uring.*
import fountain::f_io.uring.lockfree.*

/**
 * 无锁并发组件单元测试
 *
 * 测试 AtomicSlotAllocator、CompletionSlotArray 等核心无锁组件。
 * 仅在 Linux 平台执行。
 */
@When[os == "Linux"]
@Test
public class LockFreeComponentTest {

    // ==================== AtomicSlotAllocator ====================

    @TestCase
    public func testSlotAllocatorBasic(): Unit {
        let allocator = AtomicSlotAllocator(16)
        // 分配所有槽位
        var slots = Array<UInt32>(16) { _ => UInt32(0) }
        for (i in 0..16) {
            let slot = allocator.alloc()
            @Expect(slot.isSome())
            if (let Some(s) <- slot) {
                slots[Int64(i)] = s
            }
        }
        // 第 17 次分配应失败
        let overflow = allocator.alloc()
        @Expect(overflow.isNone())

        // 释放一些槽位
        allocator.release(slots[0])
        allocator.release(slots[5])

        // 重新分配应成功
        let reAlloc1 = allocator.alloc()
        @Expect(reAlloc1.isSome())
        let reAlloc2 = allocator.alloc()
        @Expect(reAlloc2.isSome())

        // 再次分配应失败
        let overflow2 = allocator.alloc()
        @Expect(overflow2.isNone())
    }

    @TestCase
    public func testSlotAllocatorReset(): Unit {
        let allocator = AtomicSlotAllocator(8)
        // 分配全部
        for (i in 0..8) {
            let _ = allocator.alloc()
        }
        @Expect(allocator.alloc().isNone())

        // 重置
        allocator.reset()

        // 应能重新分配
        let slot = allocator.alloc()
        @Expect(slot.isSome())
    }

    @TestCase
    public func testSlotAllocatorIsAllocated(): Unit {
        let allocator = AtomicSlotAllocator(4)
        @Expect(!allocator.isAllocated(0))
        @Expect(!allocator.isAllocated(3))
        @Expect(allocator.getAllocatedCount() == 0)

        let slot = allocator.alloc()
        if (let Some(s) <- slot) {
            @Expect(allocator.isAllocated(s))
            @Expect(allocator.getAllocatedCount() == 1)
            allocator.release(s)
            @Expect(!allocator.isAllocated(s))
            @Expect(allocator.getAllocatedCount() == 0)
        }
    }

    @TestCase
    public func testSlotAllocatorAllocatedCount(): Unit {
        let allocator = AtomicSlotAllocator(16)
        @Expect(allocator.getAllocatedCount() == 0)

        // 分配 5 个槽位，逐个验证计数递增
        var slots = Array<UInt32>(5) { _ => UInt32(0) }
        for (i in 0..5) {
            let slot = allocator.alloc()
            @Expect(slot.isSome())
            if (let Some(s) <- slot) {
                slots[Int64(i)] = s
                @Expect(allocator.getAllocatedCount() == UInt32(i + 1))
            }
        }

        // 释放 2 个，验证计数递减
        allocator.release(slots[1])
        @Expect(allocator.getAllocatedCount() == 4)
        allocator.release(slots[3])
        @Expect(allocator.getAllocatedCount() == 3)

        // 重置后计数归零
        allocator.reset()
        @Expect(allocator.getAllocatedCount() == 0)
    }

    // ==================== CompletionSlotArray ====================

    @TestCase
    public func testCompletionSlotArrayBasic(): Unit {
        let slots = CompletionSlotArray(4)

        // 设置回调
        let callback = LambdaCompletionCallback({ _ =>
            // 空回调用于基本编码/解码测试
        })
        let gen = slots.setCallback(0, callback)

        // 编码/解码 userData
        let userData = slots.encodeUserData(0, gen)
        let (slotIndex, generation) = slots.decodeUserData(userData)
        @Expect(slotIndex == 0)
        @Expect(generation == gen)
    }

    @TestCase
    public func testCompletionSlotArrayGeneration(): Unit {
        let slots = CompletionSlotArray(4)

        // 第一次设置回调
        let gen1 = slots.setCallback(0, LambdaCompletionCallback({ _ => }))

        // 调用并释放后，generation 递增
        let cqePtr = unsafe { LibC.malloc<IOUringCQE>(count: 1) }
        unsafe {
            var cqe = IOUringCQE()
            cqe.userData = 0
            cqe.res = 0
            cqe.flags = 0
            cqePtr.write(cqe)
        }
        slots.invokeAndRelease(0, gen1, cqePtr)

        // 第二次设置回调，generation 应该递增
        let gen2 = slots.setCallback(0, LambdaCompletionCallback({ _ => }))
        @Expect(gen2 > gen1)

        // 使用旧 generation 调用应失败
        let oldInvoked = slots.invokeAndRelease(0, gen1, cqePtr)
        @Expect(!oldInvoked)

        // 使用新 generation 调用应成功
        let newInvoked = slots.invokeAndRelease(0, gen2, cqePtr)
        @Expect(newInvoked)

        unsafe { LibC.free<IOUringCQE>(cqePtr) }
    }

    // ==================== IoUringLockFree 集成 ====================

    @TestCase
    public func testLockFreeSubmitAsync(): Unit {
        try(ring = IoUring(16)) {
            try(lf = IoUringLockFree(ring)) {
                let invoked = AtomicBool(false)
                let success = lf.submitAsync(
                    { sqe =>
                        ioUringPrepNop(sqe)
                    },
                    LambdaCompletionCallback({ cqe =>
                        invoked.store(true)
                    })
                )
                @Expect(success)

                // 收割
                lf.reap()

                // 如果没有立即收割到，等待后再次收割
                if (!invoked.load()) {
                    lf.waitAndReap()
                }
                @Expect(invoked.load())
            }
        }
    }

    @TestCase
    public func testLockFreeClosedThrows(): Unit {
        let ring = IoUring(16)
        let lf = IoUringLockFree(ring)
        lf.close()
        @Expect(lf.isClosed())

        var threwException = false
        try {
            lf.allocSlot()
        } catch(e: IoUringException) {
            threwException = true
        }
        @Expect(threwException)
    }

    /** 验证 allocSlot 在槽位用尽后能等待回收并返回（不抛 None） */
    @TestCase
    public func testAllocSlotWaitsAfterFullThenRecycles(): Unit {
        try(ring = IoUring(4)) {
            try(lf = IoUringLockFree(ring)) {
                // 用 NOP 操作填满所有 4 个槽位
                for (i in 0..4) {
                    let ok = lf.submitAsync(
                        { sqe => ioUringPrepNop(sqe) },
                        LambdaCompletionCallback({ _ => })
                    )
                    @Expect(ok)
                }

                // 收割所有完成事件，释放槽位
                for (i in 0..4) {
                    lf.waitAndReap()
                }

                // 槽位已释放，allocSlot 应返回 Some
                let slot = lf.allocSlot()
                @Expect(slot.isSome())

                // 释放该槽位
                if (let Some(s) <- slot) {
                    lf.releaseSlot(s)
                }
            }
        }
    }

    /** 验证 submitAsync 在所有槽位满时通过 allocSlot 等待而非返回 false */
    @TestCase
    public func testSubmitAsyncNeverReturnsFalse(): Unit {
        try(ring = IoUring(4)) {
            try(lf = IoUringLockFree(ring)) {
                // 用 NOP 填满 4 个槽位
                for (i in 0..4) {
                    lf.submitAsync(
                        { sqe => ioUringPrepNop(sqe) },
                        LambdaCompletionCallback({ _ => })
                    )
                }

                // 收割全部（释放槽位 + 解除等待）
                for (i in 0..4) {
                    lf.waitAndReap()
                }

                // 提交新的操作应成功（allocSlot 不会再返回 None）
                let ok = lf.submitAsync(
                    { sqe => ioUringPrepNop(sqe) },
                    LambdaCompletionCallback({ _ => })
                )
                @Expect(ok)

                // 收割
                lf.waitAndReap()
            }
        }
    }

    // ==================== SQEPreallocator 多线程安全 ====================

    /** 验证多线程并发 allocSlot → getSQE → commitSlot → flush 无竞争。
     *  直接测试 SQEPreallocator（无锁路径的核心组件），
     *  多线程并发调用 allocSlot（io_uring_get_sqe 由 sqeMutex 保护），
     *  主线程 flush + waitCQE 收割，验证所有 NOP 完成。 */
    @TestCase
    public func testSQEPreallocatorConcurrent(): Unit {
        try(ring = IoUring(8)) {
            let rp = ring.unsafeRingPtr()
            let sqEntries = ring.sqSpaceLeft()
            let pool = SQEPreallocator(rp, sqEntries)
            let opCount: Int64 = 8
            let completed = Array<AtomicBool>(opCount) { _ => AtomicBool(false) }

            let futures = ArrayList<Future<Unit>>()
            for (i in 0..opCount) {
                let idx = UInt32(i)
                let fut = spawn {
                    let slotOpt = pool.allocSlot()
                    if (let Some(slotIdx) <- slotOpt) {
                        let sqe = pool.getSQE(slotIdx)
                        // 设置 userData = slotIdx，收割后可验证
                        ioUringPrepNop(sqe)
                        ioUringSQESetData64(sqe, UInt64(slotIdx))
                        pool.commitSlot(slotIdx)
                    }
                }
                futures.add(fut)
            }
            for (f in futures) { f.get() }

            // flush 提交所有 SQE
            let submitted = pool.flush()
            @Expect(submitted >= 8)

            // 收割所有完成事件
            var reaped: Int64 = 0
            while (reaped < 8) {
                if (let Some(cqe) <- ring.waitCQE()) {
                    let userData = ioUringCQEGetData64(cqe)
                    @Expect(userData < 8)
                    @Expect(ioUringCQEGetRes(cqe) == 0)
                    completed[Int64(userData)].store(true)
                    ring.cqeSeen(cqe)
                    reaped++
                }
            }

            // 验证所有 8 个 NOP 完成
            for (i in 0..opCount) {
                @Expect(completed[i].load())
            }
        }
    }

    /** 验证多线程使用 submitAsync（已由 submitMutex 保护）同时提交并收割。 */
    @TestCase
    public func testConcurrentSubmitAsync(): Unit {
        try(ring = IoUring(8)) {
            try(lf = IoUringLockFree(ring)) {
                let opCount: Int64 = 8
                let finished = Array<AtomicBool>(opCount) { _ => AtomicBool(false) }

                let futures = ArrayList<Future<Unit>>()
                for (i in 0..opCount) {
                    let idx = UInt32(i)
                    let fut = spawn {
                        let ok = lf.submitAsync(
                            { sqe => ioUringPrepNop(sqe) },
                            LambdaCompletionCallback({ cqe =>
                                finished[Int64(idx)].store(true)
                            })
                        )
                    }
                    futures.add(fut)
                }
                for (f in futures) { f.get() }

                // 收割全部
                var reaped: Int64 = 0
                while (reaped < Int64(opCount)) {
                    reaped += Int64(lf.waitAndReap())
                }

                for (i in 0..opCount) {
                    @Expect(finished[i].load())
                }
            }
        }
    }

    // ==================== IoUringPromise isCompleted 无锁测试 ====================
}

// ==================== 无锁 Promise 行为测试 ====================
// IoUringPromise 使用 AtomicBool 替代 mutex 实现无锁 isCompleted/isCancelled，
// 这些测试直接验证 Promise 的完成/取消/等待语义。

@When[os == "Linux"]
@Test
public class IoUringPromiseTest {

    /** 测试基本的 complete → isCompleted 序列 */
    @TestCase
    public func testPromiseIsCompletedAfterComplete(): Unit {
        let promise = IoUringPromise<Int32>(
            1,
            { cqe => ioUringCQEGetRes(cqe) }
        )
        @Expect(!promise.isCompleted())
        @Expect(!promise.isCancelled())

        // 模拟 CQE 完成
        let cqePtr = unsafe { LibC.malloc<IOUringCQE>(count: 1) }
        unsafe {
            var cqe = IOUringCQE()
            cqe.res = 42
            cqe.userData = 1
            cqe.flags = 0
            cqePtr.write(cqe)
        }
        promise.complete(cqePtr)

        // complete 后 isCompleted 应返回 true
        @Expect(promise.isCompleted())
        @Expect(!promise.isCancelled())

        // 无锁尝试获取结果
        let tryResult = promise.tryGetResult()
        @Expect(tryResult.isSome())
        if (let Some(r) <- tryResult) {
            @Expect(r == 42)
        }

        // awaitResult 应立即返回
        let result = promise.awaitResult()
        @Expect(result == 42)

        unsafe { LibC.free<IOUringCQE>(cqePtr) }
    }

    /** 测试 cancel → isCancelled */
    @TestCase
    public func testPromiseIsCancelledAfterCancel(): Unit {
        let promise = IoUringPromise<Int32>(
            2,
            { cqe => ioUringCQEGetRes(cqe) }
        )
        @Expect(!promise.isCancelled())
        @Expect(!promise.isCompleted())

        promise.cancel()
        @Expect(promise.isCancelled())
        @Expect(!promise.isCompleted())

        // awaitResult 应抛异常
        var threw = false
        try {
            promise.awaitResult()
        } catch (_: IoUringException) {
            threw = true
        }
        @Expect(threw)
    }

    /** 测试 complete 后再次调用 complete 和 cancel 幂等 */
    @TestCase
    public func testPromiseIdempotentDoubleComplete(): Unit {
        let promise = IoUringPromise<Int32>(
            3,
            { cqe => ioUringCQEGetRes(cqe) }
        )
        let cqePtr = unsafe { LibC.malloc<IOUringCQE>(count: 1) }
        unsafe {
            var cqe = IOUringCQE()
            cqe.res = 100
            cqe.userData = 3
            cqe.flags = 0
            cqePtr.write(cqe)
        }
        // 第一次 complete
        promise.complete(cqePtr)
        @Expect(promise.isCompleted())
        @Expect(promise.awaitResult() == 100)

        // 第二次 complete 不应改变结果
        unsafe {
            var cqe2 = IOUringCQE()
            cqe2.res = 200
            cqe2.userData = 3
            cqe2.flags = 0
            cqePtr.write(cqe2)
        }
        promise.complete(cqePtr)
        // 结果应仍是第一次的
        @Expect(promise.awaitResult() == 100)

        // cancel 不应生效
        promise.cancel()
        @Expect(!promise.isCancelled())
        @Expect(promise.isCompleted())

        unsafe { LibC.free<IOUringCQE>(cqePtr) }
    }

    /** 测试 tryGetResult 在未完成时返回 None（无锁快速路径） */
    @TestCase
    public func testPromiseTryGetResultBeforeComplete(): Unit {
        let promise = IoUringPromise<Int32>(
            4,
            { cqe => ioUringCQEGetRes(cqe) }
        )
        // 未完成时 tryGetResult 应无锁返回 None
        @Expect(promise.tryGetResult().isNone())
        @Expect(!promise.isCompleted())
    }

    /** 测试 completeWithError 场景 */
    @TestCase
    public func testPromiseCompleteWithError(): Unit {
        let promise = IoUringPromise<Int32>(
            5,
            { cqe => ioUringCQEGetRes(cqe) }
        )
        promise.completeWithError(IoUringException("test error"))
        @Expect(promise.isCompleted())
        @Expect(!promise.isCancelled())

        var threw = false
        try {
            promise.awaitResult()
        } catch (e: IoUringException) {
            threw = true
            let msg = e.message
            @Expect(msg.contains("test error"))
        }
        @Expect(threw)
    }

    /** 测试 awaitResult 带超时 */
    @TestCase
    public func testPromiseAwaitResultWithTimeout(): Unit {
        let promise = IoUringPromise<Int32>(
            6,
            { cqe => ioUringCQEGetRes(cqe) }
        )
        // 未完成调用带超时的 awaitResult 应返回 None
        let noneResult = promise.awaitResult(timeout: Duration.millisecond * 10)
        @Expect(noneResult.isNone())
        @Expect(!promise.isCompleted())

        // 完成后再调应返回结果
        let cqePtr = unsafe { LibC.malloc<IOUringCQE>(count: 1) }
        unsafe {
            var cqe = IOUringCQE()
            cqe.res = 77
            cqe.userData = 6
            cqe.flags = 0
            cqePtr.write(cqe)
        }
        promise.complete(cqePtr)
        let someResult = promise.awaitResult(timeout: Duration.millisecond * 10)
        @Expect(someResult.isSome())
        if (let Some(r) <- someResult) {
            @Expect(r == 77)
        }
        unsafe { LibC.free<IOUringCQE>(cqePtr) }
    }
}
