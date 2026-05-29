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
 * io_uring 高级封装类
 *
 * 实现 Resource 接口，支持 try-with-resource 自动清理。
 * 持有堆分配的 IOUring 结构体指针，管理完整生命周期。
 *
 * 使用示例：
 * ```cj
 * try(ring = IoUring(64)) {
 *     let sqe = ring.getSQE()
 *     if (let Some(s) <- sqe) {
 *         ioUringPrepNop(s)
 *         ioUringSQESetData64(s, 1)
 *         ring.submit()
 *     }
 *     if (let Some(cqe) <- ring.waitCQE()) {
 *         println("result: ${ioUringCQEGetRes(cqe)}")
 *         ring.cqeSeen(cqe)
 *     }
 * }
 * ```
 */
@When[os == "Linux"]
public class IoUring <: Resource {
    private let ringPtr: CPointer<IOUring>
    private let cqeOutSlot: CPointer<CPointer<IOUringCQE>>
    private var closed: Bool = false
    private let initFlags: UInt32
    private let registry: CompletionRegistry = CompletionRegistry()

    /**
     * 基本初始化
     * @param entries SQ 队列大小（必须是 2 的幂）
     * @param flags 初始化标志
     * @throws IoUringException 初始化失败时抛出
     */
    public init(entries: UInt32, flags!: UInt32 = 0) {
        this.initFlags = flags
        ringPtr = unsafe { LibC.malloc<IOUring>(count: 1) }
        cqeOutSlot = unsafe { LibC.malloc<CPointer<IOUringCQE>>(count: 1) }

        // 零初始化
        unsafe {
            ringPtr.write(IOUring())
            cqeOutSlot.write(CPointer<IOUringCQE>())
        }

        let ret = unsafe { io_uring_queue_init(entries, ringPtr, flags) }
        if (ret < 0) {
            unsafe {
                LibC.free<CPointer<IOUringCQE>>(cqeOutSlot)
                LibC.free<IOUring>(ringPtr)
            }
            throw IoUringException("io_uring_queue_init failed: ${ret}")
        }
    }

    /**
     * 带参数初始化
     * @param entries SQ 队列大小
     * @param params 初始化参数（值类型，内部拷贝到堆上用于 FFI）
     * @throws IoUringException 初始化失败时抛出
     */
    public init(entries: UInt32, params: IOUringParams) {
        this.initFlags = params.flags
        ringPtr = unsafe { LibC.malloc<IOUring>(count: 1) }
        cqeOutSlot = unsafe { LibC.malloc<CPointer<IOUringCQE>>(count: 1) }

        // 将值类型 params 拷贝到堆上用于 FFI 调用
        let paramsPtr = unsafe { LibC.malloc<IOUringParams>(count: 1) }

        unsafe {
            ringPtr.write(IOUring())
            cqeOutSlot.write(CPointer<IOUringCQE>())
            paramsPtr.write(params)
        }

        let ret = unsafe { io_uring_queue_init_params(entries, ringPtr, paramsPtr) }

        // 内核会填充 params 的 sqEntries/cqEntries/features/offsets 等字段
        // 如果调用者需要这些信息，应在调用前读取 paramsPtr
        unsafe { LibC.free<IOUringParams>(paramsPtr) }

        if (ret < 0) {
            unsafe {
                LibC.free<CPointer<IOUringCQE>>(cqeOutSlot)
                LibC.free<IOUring>(ringPtr)
            }
            throw IoUringException("io_uring_queue_init_params failed: ${ret}")
        }
    }

    // ==================== Resource 接口 ====================

    public func isClosed(): Bool {
        closed
    }

    public func close(): Unit {
        if (!closed) {
            closed = true
            unsafe {
                io_uring_queue_exit(ringPtr)
                LibC.free<CPointer<IOUringCQE>>(cqeOutSlot)
                LibC.free<IOUring>(ringPtr)
            }
        }
    }

    // ==================== SQ 操作 ====================

    /**
     * 获取一个空闲的 SQE
     * 
     * 自动推进 sqeTail。
     * 
     * @return SQE 指针，SQ 满时返回 None
     */
    public func getSQE(): ?CPointer<IOUringSQE> {
        checkNotClosed()
        unsafe {
            let sqe = io_uring_get_sqe(ringPtr)
            if (sqe.isNull()) {
                None
            } else {
                Some(sqe)
            }
        }
    }

    /**
     * 提交 SQ 中的所有请求
     * 
     * liburing 内部处理 SQPOLL 唤醒逻辑。
     * 
     * @return 提交的请求数量，负值表示错误
     */
    public func submit(): Int32 {
        checkNotClosed()
        let ret = unsafe { io_uring_submit(ringPtr) }
        ret
    }

    /**
     * 提交并等待指定数量完成
     * @param waitNr 等待完成的数量
     * @return 提交的请求数量，负值表示错误
     */
    public func submitAndWait(waitNr: UInt32): Int32 {
        checkNotClosed()
        unsafe { io_uring_submit_and_wait(ringPtr, waitNr) }
    }

    // ==================== CQ 操作 ====================

    /**
     * 阻塞等待一个 CQE
     * @return CQE 指针，错误时返回 None
     */
    public func waitCQE(): ?CPointer<IOUringCQE> {
        checkNotClosed()
        unsafe {
            cqeOutSlot.write(CPointer<IOUringCQE>())
            // io_uring_wait_cqe 是内联函数，等价于 __io_uring_get_cqe(ring, cqePtr, 0, 1, NULL)
            let ret = __io_uring_get_cqe(ringPtr, cqeOutSlot, 0, 1, CPointer<Unit>())
            let cqe = cqeOutSlot.read()
            if (ret < 0 || cqe.isNull()) {
                None
            } else {
                Some(cqe)
            }
        }
    }

    /**
     * 非阻塞获取一个 CQE
     * 
     * 如果没有可用的 CQE，立即返回 None。
     * 
     * @return CQE 指针，无可用 CQE 时返回 None
     */
    public func peekCQE(): ?CPointer<IOUringCQE> {
        checkNotClosed()
        if (ioUringCQReady(ringPtr) == 0) {
            return None
        }
        unsafe {
            let ringVal = ringPtr.read()
            let cq = ringVal.cq
            let head = cq.khead.read()
            let shift = if ((ringVal.flags & IORING_SETUP_CQE32) != 0) { 1 } else { 0 }
            let index = (head & cq.ringMask) << shift
            let cqe = cq.cqes + Int64(index)
            if (cqe.isNull()) {
                None
            } else {
                Some(cqe)
            }
        }
    }

    /**
     * 标记一个 CQE 已被处理
     * @param cqe 已处理的 CQE 指针
     */
    public func cqeSeen(cqe: CPointer<IOUringCQE>): Unit {
        checkNotClosed()
        ioUringCQESeen(ringPtr, cqe)
    }

    /**
     * 批量推进 CQ head 指针
     * @param nr 推进数量
     */
    public func cqAdvance(nr: UInt32): Unit {
        checkNotClosed()
        ioUringCQAdvance(ringPtr, nr)
    }

    // ==================== 队列状态查询 ====================

    /**
     * 查询 SQ 中待提交的请求数量
     */
    public func sqReady(): UInt32 {
        ioUringSQReady(ringPtr)
    }

    /**
     * 查询 SQ 中剩余可用空间
     */
    public func sqSpaceLeft(): UInt32 {
        ioUringSQSpaceLeft(ringPtr)
    }

    /**
     * 查询 CQ 中待处理的完成数量
     */
    public func cqReady(): UInt32 {
        ioUringCQReady(ringPtr)
    }

    // ==================== 注册操作 ====================

    /**
     * 注册缓冲区
     * @param iovecs iovec 数组
     * @param nr iovec 数量
     * @return 0 成功，负值错误
     */
    public func registerBuffers(iovecs: CPointer<IOVec>, nr: UInt32): Int32 {
        checkNotClosed()
        unsafe { io_uring_register_buffers(ringPtr, iovecs, nr) }
    }

    /**
     * 注销缓冲区
     * @return 0 成功，负值错误
     */
    public func unregisterBuffers(): Int32 {
        checkNotClosed()
        unsafe { io_uring_unregister_buffers(ringPtr) }
    }

    /**
     * 注册文件描述符
     * @param files 文件描述符数组
     * @param nr 文件数量
     * @return 0 成功，负值错误
     */
    public func registerFiles(files: CPointer<Int32>, nr: UInt32): Int32 {
        checkNotClosed()
        unsafe { io_uring_register_files(ringPtr, files, nr) }
    }

    /**
     * 注销文件描述符
     * @return 0 成功，负值错误
     */
    public func unregisterFiles(): Int32 {
        checkNotClosed()
        unsafe { io_uring_unregister_files(ringPtr) }
    }

    // ==================== 异步操作 ====================

    /**
     * 获取完成槽位注册表
     */
    public func getRegistry(): CompletionRegistry {
        registry
    }

    /**
     * 处理所有待完成的 CQE（非阻塞）
     * 
     * 遍历 CQ 中的所有 CQE，通过 userData 查找注册的槽位并完成。
     * 
     * @return 处理的完成事件数量
     */
    public func processCompletions(): UInt32 {
        checkNotClosed()
        var processed: UInt32 = 0
        while (true) {
            let cqeOpt = peekCQE()
            if (let Some(cqe) <- cqeOpt) {
                let userData = ioUringCQEGetData64(cqe)
                if (userData != 0) {
                    registry.completeSlot(userData, cqe)
                }
                cqeSeen(cqe)
                processed += 1
            } else {
                break
            }
        }
        processed
    }

    /**
     * 等待并处理至少一个完成事件
     * @return 处理的完成事件数量
     */
    public func waitAndProcess(): UInt32 {
        checkNotClosed()
        if (let Some(cqe) <- waitCQE()) {
            let userData = ioUringCQEGetData64(cqe)
            if (userData != 0) {
                registry.completeSlot(userData, cqe)
            }
            cqeSeen(cqe)
            1
        } else {
            0
        }
    }

    // ==================== 底层访问 ====================

    /**
     * 获取底层 IOUring 指针（高级用法）
     * 
     * 用于直接调用 Phase 2 的低级函数。
     * 调用者需自行保证安全性。
     */
    public func unsafeRingPtr(): CPointer<IOUring> {
        ringPtr
    }

    // ==================== 私有辅助 ====================

    private func checkNotClosed(): Unit {
        if (closed) {
            throw IoUringException("IoUring instance has been closed")
        }
    }
}
