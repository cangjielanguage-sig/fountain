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
 * 固定文件描述符注册
 *
 * io_uring 的 registered files 机制允许将文件描述符预注册到内核，
 * 后续 I/O 请求使用固定索引代替文件描述符，减少内核查找开销。
 *
 * 当 SQE 设置 IOSQE_FIXED_FILE 标志时，SQE 的 fd 字段表示注册表索引
 * 而非实际文件描述符。
 *
 * 注册方式：
 * - 密集注册：一次性提供所有文件描述符数组
 * - 稀疏注册：先注册空槽位，后续逐个更新
 *
 * 线程安全：
 * - update 操作不是线程安全的，多线程并发更新需要外部同步
 *
 * 使用示例：
 * ```cj
 * try(ring = IoUring(64)) {
 *     try(files = RegisteredFiles(ring, 4)) {
 *         // 更新文件描述符
 *         files.update(0, stdinFd)
 *         files.update(1, stdoutFd)
 *         files.update(2, fileFd)
 *
 *         // 使用固定文件描述符提交读请求
 *         if (let Some(sqe) <- ring.getSQE()) {
 *             ioUringPrepRead(sqe, 2, buf, 4096, 0) // 2 = fileFd 的索引
 *             ioUringSQESetFlags(sqe, IOSQE_FIXED_FILE)
 *             ring.submit()
 *         }
 *     }
 * }
 * ```
 */
@When[os == "Linux"]
public class RegisteredFiles <: Resource {
    /** 底层 IoUring 实例（不持有所有权） */
    private let ring: IoUring
    /** 注册的文件描述符数量 */
    private let nrFiles: UInt32
    /** 文件描述符数组（堆分配，用于 FFI 调用） */
    private let filesPtr: CPointer<Int32>
    /** 是否使用稀疏注册 */
    private let sparse: Bool
    /** 是否已关闭 */
    private var closed: Bool = false

    /**
     * 密集注册文件描述符
     *
     * 使用 io_uring_register_files 注册一组文件描述符。
     * 数组中的每个元素可以是有效的 fd 或 IORING_REGISTER_FILES_SKIP。
     *
     * @param ring 已初始化的 IoUring 实例
     * @param nrFiles 文件描述符数量
     * @throws IoUringException 注册失败时抛出
     */
    public init(ring: IoUring, nrFiles: UInt32) {
        this.ring = ring
        this.nrFiles = nrFiles
        this.sparse = false

        // 分配并初始化文件描述符数组
        this.filesPtr = unsafe { LibC.malloc<Int32>(count: Int64(nrFiles)) }
        unsafe {
            for (i in 0..Int64(nrFiles)) {
                (filesPtr + i).write(IORING_REGISTER_FILES_SKIP)
            }
        }

        let ret = unsafe { io_uring_register_files(ring.unsafeRingPtr(), filesPtr, nrFiles) }
        if (ret < 0) {
            unsafe { LibC.free<Int32>(filesPtr) }
            throw IoUringException("io_uring_register_files failed: ${ret}")
        }
    }

    /**
     * 稀疏注册文件描述符
     *
     * 使用 io_uring_register_files_sparse 注册空槽位，
     * 后续通过 update 逐个更新。适用于文件描述符不连续的场景。
     *
     * @param ring 已初始化的 IoUring 实例
     * @param nrFiles 槽位数量
     * @param sparse 是否使用稀疏注册（必须为 true）
     * @throws IoUringException 注册失败时抛出
     */
    public init(ring: IoUring, nrFiles: UInt32, sparse!: Bool) {
        this.ring = ring
        this.nrFiles = nrFiles
        this.sparse = sparse

        if (!sparse) {
            // 非稀疏模式应使用两参数构造函数
            this.filesPtr = unsafe { LibC.malloc<Int32>(count: Int64(nrFiles)) }
            unsafe {
                for (i in 0..Int64(nrFiles)) {
                    (filesPtr + i).write(IORING_REGISTER_FILES_SKIP)
                }
            }
            let ret = unsafe { io_uring_register_files(ring.unsafeRingPtr(), filesPtr, nrFiles) }
            if (ret < 0) {
                unsafe { LibC.free<Int32>(filesPtr) }
                throw IoUringException("io_uring_register_files failed: ${ret}")
            }
            return
        }

        // 稀疏注册：分配本地数组用于 update，但 FFI 调用 register_files_sparse
        this.filesPtr = unsafe { LibC.malloc<Int32>(count: Int64(nrFiles)) }
        unsafe {
            for (i in 0..Int64(nrFiles)) {
                (filesPtr + i).write(IORING_REGISTER_FILES_SKIP)
            }
        }

        let ret = unsafe { io_uring_register_files_sparse(ring.unsafeRingPtr(), nrFiles) }
        if (ret < 0) {
            unsafe { LibC.free<Int32>(filesPtr) }
            throw IoUringException("io_uring_register_files_sparse failed: ${ret}")
        }
    }

    // ==================== 文件描述符操作 ====================

    /**
     * 更新指定索引的文件描述符
     *
     * 使用 io_uring_register_files_update 更新注册表中的条目。
     *
     * @param index 注册表索引
     * @param fd 新的文件描述符，或 IORING_REGISTER_FILES_SKIP 标记未使用
     * @return 更新的数量，负值表示错误
     */
    public func update(index: UInt32, fd: Int32): Int32 {
        checkNotClosed()
        if (index >= nrFiles) {
            throw IoUringException("file index out of range: ${index}")
        }

        // 更新本地数组
        unsafe { (filesPtr + Int64(index)).write(fd) }

        // 调用内核更新
        unsafe {
            io_uring_register_files_update(ring.unsafeRingPtr(), index, filesPtr + Int64(index), 1)
        }
    }

    /**
     * 批量更新文件描述符
     *
     * @param offset 起始索引
     * @param fds 文件描述符数组
     * @param count 更新数量
     * @return 更新的数量，负值表示错误
     */
    public func updateBatch(offset: UInt32, fds: CPointer<Int32>, count: UInt32): Int32 {
        checkNotClosed()
        if (offset + count > nrFiles) {
            throw IoUringException("file update range out of bounds")
        }

        // 同步本地数组
        unsafe {
            for (i in 0..Int64(count)) {
                (filesPtr + Int64(offset) + i).write((fds + i).read())
            }
        }

        unsafe {
            io_uring_register_files_update(ring.unsafeRingPtr(), offset, fds, count)
        }
    }

    /**
     * 自动分配一个固定文件描述符索引
     *
     * 使用 IORING_FILE_INDEX_ALLOC 让内核自动选择可用槽位。
     * 需要 5.15+ 内核支持。
     *
     * @param fd 文件描述符
     * @return 分配的索引，负值表示错误
     */
    public func allocIndex(fd: Int32): Int32 {
        checkNotClosed()
        let singleFd = unsafe { LibC.malloc<Int32>(count: 1) }
        unsafe { singleFd.write(fd) }

        let ret = unsafe {
            io_uring_register_files_update(
                ring.unsafeRingPtr(),
                IORING_FILE_INDEX_ALLOC,
                singleFd,
                1
            )
        }
        unsafe { LibC.free<Int32>(singleFd) }
        ret
    }

    // ==================== 状态查询 ====================

    /**
     * 获取注册的文件描述符数量
     */
    public func getNrFiles(): UInt32 {
        nrFiles
    }

    /**
     * 是否使用稀疏注册
     */
    public func isSparse(): Bool {
        sparse
    }

    /**
     * 获取指定索引的文件描述符
     *
     * @param index 索引
     * @return 文件描述符值
     */
    public func getFd(index: UInt32): Int32 {
        if (index >= nrFiles) {
            throw IoUringException("file index out of range: ${index}")
        }
        unsafe { (filesPtr + Int64(index)).read() }
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
                    io_uring_unregister_files(ring.unsafeRingPtr())
                }
            }
            unsafe { LibC.free<Int32>(filesPtr) }
        }
    }

    // ==================== 私有辅助 ====================

    private func checkNotClosed(): Unit {
        if (closed) {
            throw IoUringException("RegisteredFiles instance has been closed")
        }
    }
}
