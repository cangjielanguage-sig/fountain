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
package fountain::f_io.uring

import std.sync.AtomicInt64

/**
 * io_uring 实例池
 *
 * 为多线程场景提供多个 IoUring 实例，消除 SQ 上的锁竞争。
 * 支持轮询和按索引两种分配策略。
 *
 * 使用示例：
 * ```cj
 * try(pool = IoUringPool(64, ringCount: 4)) {
 *     let ring = pool.getRing()
 *     // 使用 ring 提交和等待 I/O
 * }
 * ```
 */
@When[os == "Linux"]
public class IoUringPool <: Resource {
    private let rings: Array<IoUring>
    private let ringCount: Int64
    private let nextIndex: AtomicInt64 = AtomicInt64(0)
    private var closed: Bool = false

    /**
     * 初始化实例池
     * @param entriesPerRing 每个 ring 的 SQ 队列大小
     * @param ringCount ring 实例数量（默认 4）
     * @param flags 初始化标志
     * @throws IoUringException 任一 ring 初始化失败时抛出
     */
    public init(entriesPerRing: UInt32, ringCount!: Int64 = 4, flags!: UInt32 = 0) {
        this.ringCount = ringCount
        rings = Array<IoUring>(ringCount) { _ =>
            IoUring(entriesPerRing, flags: flags)
        }
    }

    /**
     * 轮询获取一个 ring 实例
     * 
     * 使用 AtomicInt64 实现无锁轮询分配。
     * 
     * @return IoUring 实例
     * @throws IoUringException 池已关闭时抛出
     */
    public func getRing(): IoUring {
        checkNotClosed()
        let index = nextIndex.fetchAdd(1) % ringCount
        rings[Int64(index)]
    }

    /**
     * 按索引获取 ring 实例
     * @param index ring 索引（0 到 ringCount-1）
     * @return IoUring 实例
     * @throws IoUringException 索引越界或池已关闭时抛出
     */
    public func getRing(index: Int64): IoUring {
        checkNotClosed()
        if (index < 0 || index >= ringCount) {
            throw IoUringException("Ring index out of range: ${index}")
        }
        rings[index]
    }

    /**
     * 获取 ring 实例数量
     */
    public func count(): Int64 {
        ringCount
    }

    // ==================== Resource 接口 ====================

    public func isClosed(): Bool {
        closed
    }

    public func close(): Unit {
        if (!closed) {
            closed = true
            for (ring in rings) {
                if (!ring.isClosed()) {
                    ring.close()
                }
            }
        }
    }

    // ==================== 私有辅助 ====================

    private func checkNotClosed(): Unit {
        if (closed) {
            throw IoUringException("IoUringPool has been closed")
        }
    }
}
