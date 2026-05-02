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
 * io_uring 集成测试
 *
 * 测试多线程并发提交、IoUringPool、IoUringFuture 等场景。
 * 仅在 Linux 平台执行。
 */
@When[os == "Linux"]
@Test
public class IoUringIntegrationTest {

    /** 测试用的 ring entries 数量 */
    static let TEST_ENTRIES: UInt32 = 32

    // ==================== 多线程并发提交 ====================

    @TestCase
    public func testConcurrentSubmit(): Unit {
        try(ring = IoUring(64)) {
            try(lf = IoUringLockFree(ring)) {
                let threadCount: Int64 = 2
                let opsPerThread: Int64 = 2
                let totalOps = threadCount * opsPerThread
                let completedCount = AtomicInt64(0)

                // 启动提交线程
                let futures = Array<Future<Unit>>(threadCount) { threadIdx =>
                    spawn {
                        for (j in 0..opsPerThread) {
                            let ok = lf.submitAsync(
                                { sqe => ioUringPrepNop(sqe) },
                                LambdaCompletionCallback({ _ =>
                                    completedCount.fetchAdd(1)
                                })
                            )
                        }
                    }
                }

                // 主线程做收割
                var reaped: Int64 = 0
                var loopCount: Int64 = 0
                while (reaped < totalOps && loopCount < 200) {
                    loopCount += 1
                    let count = lf.reap()
                    if (count > 0) {
                        reaped += Int64(count)
                    } else {
                        sleep(Duration.millisecond * 10)
                    }
                }

                // 等待提交线程
                for (i in 0..threadCount) {
                    futures[Int64(i)].get()
                }

                @Expect(completedCount.load() == totalOps)
            }
        }
    }

    // ==================== IoUringPool 并发测试 ====================

    @TestCase
    public func testPoolConcurrentAccess(): Unit {
        try(pool = IoUringPool(16, ringCount: 2)) {
            let iterations: Int64 = 20
            let successCount = AtomicInt64(0)

            // 每个线程固定分配一个 ring，避免 getSQE/submit 的并发竞争。
            // IoUring 实例不是线程安全的，round-robin 分配可能让多线程共享同一 ring。
            let futures = Array<Future<Unit>>(2) { threadIdx =>
                let ringIndex: Int64 = threadIdx  // 线程 0 → ring[0]，线程 1 → ring[1]
                spawn {
                    for (j in 0..iterations) {
                        let r = pool.getRing(ringIndex)
                        let sqeOpt = r.getSQE()
                        if (let Some(sqe) <- sqeOpt) {
                            ioUringPrepNop(sqe)
                            ioUringSQESetData64(sqe, UInt64(j))
                        }
                        let ret = r.submit()
                        if (ret > 0) {
                            let cqeOpt = r.waitCQE()
                            if (let Some(cqe) <- cqeOpt) {
                                r.cqeSeen(cqe)
                                successCount.fetchAdd(1)
                            }
                        }
                    }
                }
            }

            for (i in 0..2) {
                futures[Int64(i)].get()
            }

            @Expect(successCount.load() == iterations * 2)
        }
    }

    // ==================== IoUringFuture 测试 ====================

    @TestCase
    public func testFutureBasic(): Unit {
        try(ring = IoUring(TEST_ENTRIES)) {
            let registry = ring.getRegistry()
            var futureCreated = false

            let sqeOpt = ring.getSQE()
            if (let Some(sqe) <- sqeOpt) {
                ioUringPrepNop(sqe)
                let id = registry.nextId()
                let promise = IoUringPromise<Int32>(id, { cqe =>
                    ioUringCQEGetRes(cqe)
                })
                let future = IoUringFuture(promise)
                futureCreated = true

                registry.register(id, promise)
                ioUringSQESetData64(sqe, id)
                ring.submit()

                // 处理完成
                ring.waitAndProcess()

                // 获取结果（阻塞版本，返回 T）
                let res = future.get()
                @Expect(res == 0)
            }
            @Expect(futureCreated)
        }
    }

    // ==================== 批量 nop 压力测试 ====================

    @TestCase
    public func testStressBatchNop(): Unit {
        try(ring = IoUring(64)) {
            let batchSize: UInt32 = 32
            let roundCount: Int64 = 10

            for (round in 0..roundCount) {
                var submitted: UInt32 = 0
                for (i in 0..Int64(batchSize)) {
                    let sqeOpt = ring.getSQE()
                    if (let Some(sqe) <- sqeOpt) {
                        ioUringPrepNop(sqe)
                        ioUringSQESetData64(sqe, UInt64(round) * UInt64(batchSize) + UInt64(i))
                        submitted += 1
                    }
                }
                if (submitted > 0) {
                    ring.submit()
                }

                // 收割
                var reaped: UInt32 = 0
                while (reaped < submitted) {
                    let cqeOpt = ring.waitCQE()
                    if (let Some(cqe) <- cqeOpt) {
                        ring.cqeSeen(cqe)
                        reaped += 1
                    }
                }
            }
            // 如果到这里没崩溃就算通过
            @Expect(true)
        }
    }
}
