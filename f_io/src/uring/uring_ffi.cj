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

/**
 * liburing FFI 函数声明
 * 
 * 所有函数调用必须在 unsafe 块中执行。
 * 仅在 Linux 平台可用。
 */

// ==================== 初始化与清理 ====================

@When[os == "Linux"]
foreign {
    /**
     * 初始化 io_uring 实例
     * @param entries SQ 队列大小
     * @param ring io_uring 结构体指针
     * @param flags 初始化标志
     * @return 0 成功，负值表示错误
     */
    func io_uring_queue_init(
        entries: UInt32,
        ring: CPointer<IOUring>,
        flags: UInt32
    ): Int32

    /**
     * 带参数初始化 io_uring 实例
     * @param entries SQ 队列大小
     * @param ring io_uring 结构体指针
     * @param params 初始化参数
     * @return 0 成功，负值表示错误
     */
    func io_uring_queue_init_params(
        entries: UInt32,
        ring: CPointer<IOUring>,
        params: CPointer<IOUringParams>
    ): Int32

    /**
     * 使用自定义内存初始化 io_uring 实例
     * @param entries SQ 队列大小
     * @param ring io_uring 结构体指针
     * @param params 初始化参数
     * @param buf 自定义内存缓冲区
     * @param bufSize 缓冲区大小
     * @return 0 成功，负值表示错误
     */
    func io_uring_queue_init_mem(
        entries: UInt32,
        ring: CPointer<IOUring>,
        params: CPointer<IOUringParams>,
        buf: CPointer<Unit>,
        bufSize: UIntNative
    ): Int32

    /**
     * 通过 mmap 方式初始化
     * @param fd io_uring 文件描述符
     * @param params 初始化参数
     * @param ring io_uring 结构体指针
     * @return 0 成功，负值表示错误
     */
    func io_uring_queue_mmap(
        fd: Int32,
        params: CPointer<IOUringParams>,
        ring: CPointer<IOUring>
    ): Int32

    /**
     * 清理 io_uring 实例
     * @param ring io_uring 结构体指针
     */
    func io_uring_queue_exit(ring: CPointer<IOUring>): Unit

    /**
     * 防止 fork 继承 ring
     * @param ring io_uring 结构体指针
     * @return 0 成功，负值表示错误
     */
    func io_uring_ring_dontfork(ring: CPointer<IOUring>): Int32
}

// ==================== FFI 包装函数（供子包使用）====================

/**
 * io_uring_submit 的包装函数
 *
 * foreign 函数无法跨动态库子包边界直接访问，
 * 提供此包装函数供 lockfree 子包使用。
 *
 * @param ring io_uring 结构体指针
 * @return 提交的请求数量，负值表示错误
 */
@When[os == "Linux"]
public func ioUringSubmitFFI(ring: CPointer<IOUring>): Int32 {
    unsafe { io_uring_submit(ring) }
}

/**
 * io_uring_get_sqe 的包装函数
 *
 * foreign 函数无法跨动态库子包边界直接访问，
 * 提供此包装函数供 lockfree 子包使用。
 *
 * @param ring io_uring 结构体指针
 * @return SQE 指针，SQ 满时返回 null
 */
@When[os == "Linux"]
public func ioUringGetSQEFFI(ring: CPointer<IOUring>): CPointer<IOUringSQE> {
    unsafe { io_uring_get_sqe(ring) }
}

// ==================== SQE 操作 ====================

@When[os == "Linux"]
foreign {
    /**
     * 获取一个空闲的 SQE
     * @param ring io_uring 结构体指针
     * @return SQE 指针，SQ 满时返回 null
     */
    func io_uring_get_sqe(ring: CPointer<IOUring>): CPointer<IOUringSQE>
}

// ==================== 提交与等待 ====================

@When[os == "Linux"]
foreign {
    /**
     * 提交 SQ 中的所有请求
     * @param ring io_uring 结构体指针
     * @return 提交的请求数量，负值表示错误
     */
    func io_uring_submit(ring: CPointer<IOUring>): Int32

    /**
     * 提交并等待指定数量完成
     * @param ring io_uring 结构体指针
     * @param waitNr 等待完成的数量
     * @return 提交的请求数量，负值表示错误
     */
    func io_uring_submit_and_wait(
        ring: CPointer<IOUring>,
        waitNr: UInt32
    ): Int32

    /**
     * 提交并等待带超时
     * @param ring io_uring 结构体指针
     * @param cqePtr 输出 CQE 指针
     * @param waitNr 等待完成的数量
     * @param ts 超时时间
     * @param sigmask 信号掩码
     * @return 提交的请求数量，负值表示错误
     */
    func io_uring_submit_and_wait_timeout(
        ring: CPointer<IOUring>,
        cqePtr: CPointer<CPointer<IOUringCQE>>,
        waitNr: UInt32,
        ts: CPointer<KernelTimespec>,
        sigmask: CPointer<Unit>
    ): Int32

    /**
     * 获取完成事件（不等待）
     * @param ring io_uring 结构体指针
     * @return 获取的事件数量，负值表示错误
     */
    func io_uring_get_events(ring: CPointer<IOUring>): Int32

    /**
     * 提交并获取事件
     * @param ring io_uring 结构体指针
     * @return 提交或获取的事件数量，负值表示错误
     */
    func io_uring_submit_and_get_events(ring: CPointer<IOUring>): Int32
}

// ==================== CQE 操作 ====================

@When[os == "Linux"]
foreign {
    /**
     * 等待多个 CQE
     * @param ring io_uring 结构体指针
     * @param cqePtr 输出 CQE 指针
     * @param waitNr 等待数量
     * @param ts 超时时间
     * @param sigmask 信号掩码
     * @return 0 成功，负值表示错误
     */
    func io_uring_wait_cqes(
        ring: CPointer<IOUring>,
        cqePtr: CPointer<CPointer<IOUringCQE>>,
        waitNr: UInt32,
        ts: CPointer<KernelTimespec>,
        sigmask: CPointer<Unit>
    ): Int32

    /**
     * 带超时等待 CQE
     * @param ring io_uring 结构体指针
     * @param cqePtr 输出 CQE 指针
     * @param ts 超时时间
     * @return 0 成功，负值表示错误
     */
    func io_uring_wait_cqe_timeout(
        ring: CPointer<IOUring>,
        cqePtr: CPointer<CPointer<IOUringCQE>>,
        ts: CPointer<KernelTimespec>
    ): Int32

    /**
     * 批量 peek CQE
     * @param ring io_uring 结构体指针
     * @param cqes CQE 指针数组
     * @param count 数组大小
     * @return 实际获取的 CQE 数量
     */
    func io_uring_peek_batch_cqe(
        ring: CPointer<IOUring>,
        cqes: CPointer<CPointer<IOUringCQE>>,
        count: UInt32
    ): UInt32

    /**
     * 内部辅助函数：获取 CQE
     * @param ring io_uring 结构体指针
     * @param cqePtr 输出 CQE 指针
     * @param submit 提交数量
     * @param waitNr 等待数量
     * @param sigmask 信号掩码
     * @return 0 成功，负值表示错误
     */
    func __io_uring_get_cqe(
        ring: CPointer<IOUring>,
        cqePtr: CPointer<CPointer<IOUringCQE>>,
        submit: UInt32,
        waitNr: UInt32,
        sigmask: CPointer<Unit>
    ): Int32
}

// ==================== 注册操作 ====================

@When[os == "Linux"]
foreign {
    /**
     * 注册缓冲区
     * @param ring io_uring 结构体指针
     * @param iovecs iovec 数组
     * @param nrIOvecs iovec 数量
     * @return 0 成功，负值表示错误
     */
    func io_uring_register_buffers(
        ring: CPointer<IOUring>,
        iovecs: CPointer<IOVec>,
        nrIOvecs: UInt32
    ): Int32

    /**
     * 注册稀疏缓冲区
     * @param ring io_uring 结构体指针
     * @param nr 数量
     * @return 0 成功，负值表示错误
     */
    func io_uring_register_buffers_sparse(
        ring: CPointer<IOUring>,
        nr: UInt32
    ): Int32

    /**
     * 注销缓冲区
     * @param ring io_uring 结构体指针
     * @return 0 成功，负值表示错误
     */
    func io_uring_unregister_buffers(ring: CPointer<IOUring>): Int32

    /**
     * 注册文件描述符
     * @param ring io_uring 结构体指针
     * @param files 文件描述符数组
     * @param nrFiles 文件数量
     * @return 0 成功，负值表示错误
     */
    func io_uring_register_files(
        ring: CPointer<IOUring>,
        files: CPointer<Int32>,
        nrFiles: UInt32
    ): Int32

    /**
     * 注册稀疏文件描述符
     * @param ring io_uring 结构体指针
     * @param nr 数量
     * @return 0 成功，负值表示错误
     */
    func io_uring_register_files_sparse(
        ring: CPointer<IOUring>,
        nr: UInt32
    ): Int32

    /**
     * 注销文件描述符
     * @param ring io_uring 结构体指针
     * @return 0 成功，负值表示错误
     */
    func io_uring_unregister_files(ring: CPointer<IOUring>): Int32

    /**
     * 更新已注册的文件描述符
     * @param ring io_uring 结构体指针
     * @param off 偏移量
     * @param files 文件描述符数组
     * @param nrFiles 文件数量
     * @return 更新的数量，负值表示错误
     */
    func io_uring_register_files_update(
        ring: CPointer<IOUring>,
        off: UInt32,
        files: CPointer<Int32>,
        nrFiles: UInt32
    ): Int32

    /**
     * 注册 eventfd
     * @param ring io_uring 结构体指针
     * @param fd eventfd 文件描述符
     * @return 0 成功，负值表示错误
     */
    func io_uring_register_eventfd(ring: CPointer<IOUring>, fd: Int32): Int32

    /**
     * 注册异步 eventfd
     * @param ring io_uring 结构体指针
     * @param fd eventfd 文件描述符
     * @return 0 成功，负值表示错误
     */
    func io_uring_register_eventfd_async(ring: CPointer<IOUring>, fd: Int32): Int32

    /**
     * 注销 eventfd
     * @param ring io_uring 结构体指针
     * @return 0 成功，负值表示错误
     */
    func io_uring_unregister_eventfd(ring: CPointer<IOUring>): Int32

    /**
     * 注册 buffer ring
     * @param ring io_uring 结构体指针
     * @param reg 注册参数
     * @param flags 标志
     * @return 0 成功，负值表示错误
     */
    func io_uring_register_buf_ring(
        ring: CPointer<IOUring>,
        reg: CPointer<IOUringBufReg>,
        flags: UInt32
    ): Int32

    /**
     * 注销 buffer ring
     * @param ring io_uring 结构体指针
     * @param bgid buffer group ID
     * @return 0 成功，负值表示错误
     */
    func io_uring_unregister_buf_ring(ring: CPointer<IOUring>, bgid: Int32): Int32

    /**
     * 获取特性探测结构
     * @return 探测结构指针，NULL 表示失败
     */
    func io_uring_get_probe(): CPointer<IOUringProbeHeader>

    /**
     * 从 ring 获取特性探测结构
     * @param ring io_uring 结构体指针
     * @return 探测结构指针，NULL 表示失败
     */
    func io_uring_get_probe_ring(ring: CPointer<IOUring>): CPointer<IOUringProbeHeader>

    /**
     * 释放特性探测结构
     * @param probe 探测结构指针
     */
    func io_uring_free_probe(probe: CPointer<IOUringProbeHeader>): Unit

    /**
     * 注册特性探测
     * @param ring io_uring 结构体指针
     * @param p 探测结构指针
     * @param nr 探测数量
     * @return 0 成功，负值表示错误
     */
    func io_uring_register_probe(
        ring: CPointer<IOUring>,
        p: CPointer<IOUringProbeHeader>,
        nr: UInt32
    ): Int32

    /**
     * 注册 personality
     * @param ring io_uring 结构体指针
     * @return personality ID，负值表示错误
     */
    func io_uring_register_personality(ring: CPointer<IOUring>): Int32

    /**
     * 注销 personality
     * @param ring io_uring 结构体指针
     * @param id personality ID
     * @return 0 成功，负值表示错误
     */
    func io_uring_unregister_personality(ring: CPointer<IOUring>, id: Int32): Int32
}

// ==================== Buffer Ring 操作 ====================

@When[os == "Linux"]
foreign {
    /**
     * 设置 buffer ring
     * @param ring io_uring 结构体指针
     * @param nentries 条目数量
     * @param bgid buffer group ID
     * @param flags 标志
     * @param ret 输出返回值
     * @return buffer ring 指针，NULL 表示失败
     */
    func io_uring_setup_buf_ring(
        ring: CPointer<IOUring>,
        nentries: UInt32,
        bgid: Int32,
        flags: UInt32,
        ret: CPointer<Int32>
    ): CPointer<IOUringBuf>

    /**
     * 释放 buffer ring
     * @param ring io_uring 结构体指针
     * @param br buffer ring 指针
     * @param nentries 条目数量
     * @param bgid buffer group ID
     * @return 0 成功，负值表示错误
     */
    func io_uring_free_buf_ring(
        ring: CPointer<IOUring>,
        br: CPointer<IOUringBuf>,
        nentries: UInt32,
        bgid: Int32
    ): Int32
}

// ==================== 系统调用 ====================

@When[os == "Linux"]
foreign {
    /**
     * io_uring_setup 系统调用
     * @param entries SQ 队列大小
     * @param params 初始化参数
     * @return io_uring 文件描述符，负值表示错误
     */
    func io_uring_setup(
        entries: UInt32,
        params: CPointer<IOUringParams>
    ): Int32

    /**
     * io_uring_enter 系统调用
     * @param fd io_uring 文件描述符
     * @param toSubmit 提交数量
     * @param minComplete 最小完成数量
     * @param flags 标志
     * @param sig 信号掩码
     * @return 提交或完成的数量，负值表示错误
     */
    func io_uring_enter(
        fd: UInt32,
        toSubmit: UInt32,
        minComplete: UInt32,
        flags: UInt32,
        sig: CPointer<Unit>
    ): Int32

    /**
     * io_uring_enter2 系统调用
     * @param fd io_uring 文件描述符
     * @param toSubmit 提交数量
     * @param minComplete 最小完成数量
     * @param flags 标志
     * @param sig 信号掩码
     * @param sz 结构大小
     * @return 提交或完成的数量，负值表示错误
     */
    func io_uring_enter2(
        fd: UInt32,
        toSubmit: UInt32,
        minComplete: UInt32,
        flags: UInt32,
        sig: CPointer<Unit>,
        sz: UIntNative
    ): Int32

    /**
     * io_uring_register 系统调用
     * @param fd io_uring 文件描述符
     * @param opcode 操作码
     * @param arg 参数
     * @param nrArgs 参数数量
     * @return 0 成功，负值表示错误
     */
    func io_uring_register(
        fd: UInt32,
        opcode: UInt32,
        arg: CPointer<Unit>,
        nrArgs: UInt32
    ): Int32
}

// ==================== 辅助函数 ====================

@When[os == "Linux"]
foreign {
    /**
     * 获取所需锁定内存大小
     * @param entries SQ 队列大小
     * @param flags 标志
     * @return 字节数，负值表示错误
     */
    func io_uring_mlock_size(entries: UInt32, flags: UInt32): IntNative

    /**
     * 获取所需锁定内存大小（带参数）
     * @param entries SQ 队列大小
     * @param p 初始化参数
     * @return 字节数，负值表示错误
     */
    func io_uring_mlock_size_params(entries: UInt32, p: CPointer<IOUringParams>): IntNative

    /**
     * 等待 SQ ring 空间
     * @param ring io_uring 结构体指针
     * @return 0 成功，负值表示错误
     */
    func __io_uring_sqring_wait(ring: CPointer<IOUring>): Int32

    /**
     * 启用 ring
     * @param ring io_uring 结构体指针
     * @return 0 成功，负值表示错误
     */
    func io_uring_enable_rings(ring: CPointer<IOUring>): Int32
}
