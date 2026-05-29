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
package fountain::f_uring.base

/**
 * 固定缓冲区注册
 *
 * io_uring 的 registered buffers 机制允许将缓冲区预注册到内核，
 * 后续 I/O 请求使用 IORING_OP_READ_FIXED / IORING_OP_WRITE_FIXED 操作码
 * 直接引用缓冲区索引，避免内核每次验证缓冲区地址的合法性。
 *
 * 注册方式：
 * - 密集注册：一次性提供所有 iovec 数组
 * - 稀疏注册：先注册空槽位，后续逐个更新
 *
 * 线程安全：
 * - update 操作不是线程安全的，多线程并发更新需要外部同步
 *
 * 使用示例：
 * ```cj
 * try(ring = IoUring(64)) {
 *     // 分配缓冲区
 *     let buf1 = unsafe { LibC.malloc<UInt8>(count: 4096) }
 *     let buf2 = unsafe { LibC.malloc<UInt8>(count: 4096) }
 *
 *     // 构建 iovec 数组
 *     let iovecs = unsafe { LibC.malloc<IOVec>(count: 2) }
 *     unsafe {
 *         (iovecs + 0).write(IOVec(iovBase: CPointer<Unit>(buf1), iovLen: 4096))
 *         (iovecs + 1).write(IOVec(iovBase: CPointer<Unit>(buf2), iovLen: 4096))
 *     }
 *
 *     try(buffers = RegisteredBuffers(ring, iovecs, 2)) {
 *         // 使用固定缓冲区读
 *         if (let Some(sqe) <- ring.getSQE()) {
 *             ioUringPrepReadFixed(sqe, fd, 0, 4096, 0) // buf_index = 0
 *             ring.submit()
 *         }
 *     }
 * }
 * ```
 */
@When[os == "Linux"]
public class RegisteredBuffers <: Resource {
    /** 底层 IoUring 实例（不持有所有权） */
    private let ring: IoUring
    /** 注册的缓冲区数量 */
    private let nrBuffers: UInt32
    /** iovec 数组指针（堆分配） */
    private let iovecsPtr: CPointer<IOVec>
    /** 是否使用稀疏注册 */
    private let sparse: Bool
    /** 是否已关闭 */
    private var closed: Bool = false

    /**
     * 密集注册缓冲区
     *
     * 使用 io_uring_register_buffers 注册一组缓冲区。
     *
     * @param ring 已初始化的 IoUring 实例
     * @param iovecs iovec 数组指针
     * @param nrBuffers 缓冲区数量
     * @throws IoUringException 注册失败时抛出
     */
    public init(ring: IoUring, iovecs: CPointer<IOVec>, nrBuffers: UInt32) {
        this.ring = ring
        this.nrBuffers = nrBuffers
        this.sparse = false

        // 拷贝 iovec 数组到本地管理的内存
        this.iovecsPtr = unsafe { LibC.malloc<IOVec>(count: Int64(nrBuffers)) }
        unsafe {
            for (i in 0..Int64(nrBuffers)) {
                (iovecsPtr + i).write((iovecs + i).read())
            }
        }

        let ret = unsafe { io_uring_register_buffers(ring.unsafeRingPtr(), iovecsPtr, nrBuffers) }
        if (ret < 0) {
            unsafe { LibC.free<IOVec>(iovecsPtr) }
            throw IoUringException("io_uring_register_buffers failed: ${ret}")
        }
    }

    /**
     * 稀疏注册缓冲区
     *
     * 使用 io_uring_register_buffers_sparse 注册空槽位，
     * 后续通过 update 逐个更新。适用于缓冲区不连续的场景。
     *
     * @param ring 已初始化的 IoUring 实例
     * @param nrBuffers 槽位数量
     * @param sparse 是否使用稀疏注册（必须为 true）
     * @throws IoUringException 注册失败时抛出
     */
    public init(ring: IoUring, nrBuffers: UInt32, sparse!: Bool) {
        this.ring = ring
        this.nrBuffers = nrBuffers
        this.sparse = sparse

        if (!sparse) {
            // 非稀疏模式应使用三参数构造函数
            this.iovecsPtr = unsafe { LibC.malloc<IOVec>(count: Int64(nrBuffers)) }
            unsafe {
                for (i in 0..Int64(nrBuffers)) {
                    (iovecsPtr + i).write(IOVec())
                }
            }
            let ret = unsafe { io_uring_register_buffers(ring.unsafeRingPtr(), iovecsPtr, nrBuffers) }
            if (ret < 0) {
                unsafe { LibC.free<IOVec>(iovecsPtr) }
                throw IoUringException("io_uring_register_buffers failed: ${ret}")
            }
            return
        }

        // 稀疏注册：分配本地 iovec 数组用于 update
        this.iovecsPtr = unsafe { LibC.malloc<IOVec>(count: Int64(nrBuffers)) }
        unsafe {
            for (i in 0..Int64(nrBuffers)) {
                (iovecsPtr + i).write(IOVec())
            }
        }

        let ret = unsafe { io_uring_register_buffers_sparse(ring.unsafeRingPtr(), nrBuffers) }
        if (ret < 0) {
            unsafe { LibC.free<IOVec>(iovecsPtr) }
            throw IoUringException("io_uring_register_buffers_sparse failed: ${ret}")
        }
    }

    // ==================== 缓冲区操作 ====================

    /**
     * 更新指定索引的缓冲区
     *
     * 使用 IORING_REGISTER_BUFFERS_UPDATE 命令更新注册表中的条目。
     * 需要 5.13+ 内核支持。
     *
     * @param index 缓冲区索引
     * @param iovec 新的缓冲区描述
     * @return 0 成功，负值表示错误
     */
    public func update(index: UInt32, iovec: IOVec): Int32 {
        checkNotClosed()
        if (index >= nrBuffers) {
            throw IoUringException("buffer index out of range: ${index}")
        }

        // 更新本地数组
        unsafe { (iovecsPtr + Int64(index)).write(iovec) }

        // 通过 io_uring_register 系统调用更新
        // IORING_REGISTER_BUFFERS_UPDATE = 16
        let updateArg = unsafe { LibC.malloc<IOUringRsrcUpdate>(count: 1) }
        unsafe {
            var arg = IOUringRsrcUpdate()
            arg.offset = index
            arg.resv = 0
            arg.data = UInt64(iovecsPtr.toUIntNative())
            updateArg.write(arg)
        }

        let ret = unsafe {
            io_uring_register(
                UInt32(ring.unsafeRingPtr().read().ringFd),
                IORING_REGISTER_BUFFERS_UPDATE,
                CPointer<Unit>(updateArg),
                1
            )
        }
        unsafe { LibC.free<IOUringRsrcUpdate>(updateArg) }
        ret
    }

    // ==================== 状态查询 ====================

    /**
     * 获取注册的缓冲区数量
     */
    public func getNrBuffers(): UInt32 {
        nrBuffers
    }

    /**
     * 是否使用稀疏注册
     */
    public func isSparse(): Bool {
        sparse
    }

    /**
     * 获取指定索引的 iovec
     *
     * @param index 缓冲区索引
     * @return IOVec 实例
     */
    public func getIOVec(index: UInt32): IOVec {
        if (index >= nrBuffers) {
            throw IoUringException("buffer index out of range: ${index}")
        }
        unsafe { (iovecsPtr + Int64(index)).read() }
    }

    // ==================== Resource 接口 ====================

    public func isClosed(): Bool {
        closed
    }

    public func close(): Unit {
        if (!closed) {
            closed = true
            if (!ring.isClosed()) {
                unsafe {
                    io_uring_unregister_buffers(ring.unsafeRingPtr())
                }
            }
            unsafe { LibC.free<IOVec>(iovecsPtr) }
        }
    }

    // ==================== 私有辅助 ====================

    private func checkNotClosed(): Unit {
        if (closed) {
            throw IoUringException("RegisteredBuffers instance has been closed")
        }
    }
}
