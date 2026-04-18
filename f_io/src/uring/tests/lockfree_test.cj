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

        let slot = allocator.alloc()
        if (let Some(s) <- slot) {
            @Expect(allocator.isAllocated(s))
            allocator.release(s)
            @Expect(!allocator.isAllocated(s))
        }
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
}
