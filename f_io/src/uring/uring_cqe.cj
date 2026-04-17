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
 * CQE (Completion Queue Entry) 操作辅助函数
 * 
 * 这些函数对应 liburing 的 inline 函数，需要手动重实现。
 * 所有函数仅在 Linux 平台可用。
 */

// ==================== UInt64 → CPointer<Unit> 辅助 ====================

/**
 * 将 UInt64 值重新解释为 CPointer<Unit>
 * 
 * 用于从 io_uring SQE/CQE 的 userData 字段恢复指针值。
 * 通过 acquireArrayRawData 获取指针，写入 UInt64 值，再类型转换为 CPointer<Unit>。
 * 
 * @param val 64位整数值（存储的指针地址）
 * @return 对应的 CPointer<Unit>
 */
@When[os == "Linux"]
public func uint64ToCPointer(val: UInt64): CPointer<Unit> {
    unsafe {
        var array = Array<Byte>(8, repeat: 0)
        var handler: ?CPointerHandle<Byte> = None
        try {
            let hdl = acquireArrayRawData<Byte>(array)
            handler = hdl
            let bytePtr = hdl.pointer
            let uint64Ptr = CPointer<UInt64>(bytePtr)
            uint64Ptr.write(val)
            CPointer<Unit>(uint64Ptr)
        } finally {
            if (let Some(h) <- handler) {
                releaseArrayRawData<Byte>(h)
            }
        }
    }
}

// ==================== CQE 数据获取 ====================

/**
 * 从 CQE 获取用户数据（指针形式）
 * 
 * 返回提交 SQE 时设置的用户数据指针。
 * 
 * @param cqe CQE 指针
 * @return 用户数据指针
 */
@When[os == "Linux"]
public func ioUringCQEGetData(cqe: CPointer<IOUringCQE>): CPointer<Unit> {
    unsafe {
        // userData 存储的是指针值，需要转换回来
        let userData = cqe.read().userData
        uint64ToCPointer(userData)
    }
}

/**
 * 从 CQE 获取用户数据（64位整数形式）
 * 
 * 返回提交 SQE 时设置的用户数据。
 * 常用于获取请求 ID 或槽位索引。
 * 
 * @param cqe CQE 指针
 * @return 用户数据（64位整数）
 */
@When[os == "Linux"]
public func ioUringCQEGetData64(cqe: CPointer<IOUringCQE>): UInt64 {
    unsafe { cqe.read().userData }
}

/**
 * 获取 CQE 的结果值
 * 
 * 结果值是系统调用的返回值。正值表示成功（如读写的字节数），
 * 负值表示错误（-errno）。
 * 
 * @param cqe CQE 指针
 * @return 结果值
 */
@When[os == "Linux"]
public func ioUringCQEGetRes(cqe: CPointer<IOUringCQE>): Int32 {
    unsafe { cqe.read().res }
}

/**
 * 获取 CQE 的标志位
 * 
 * @param cqe CQE 指针
 * @return 标志位
 */
@When[os == "Linux"]
public func ioUringCQEGetFlags(cqe: CPointer<IOUringCQE>): UInt32 {
    unsafe { cqe.read().flags }
}

/**
 * 从 CQE 提取缓冲区 ID
 * 
 * 当使用 buffer selection 时，缓冲区 ID 存储在 flags 的高 16 位。
 * 
 * @param cqe CQE 指针
 * @return 缓冲区 ID
 */
@When[os == "Linux"]
public func ioUringCQEGetBufferID(cqe: CPointer<IOUringCQE>): UInt16 {
    unsafe {
        let flags = cqe.read().flags
        UInt16((flags >> IORING_CQE_BUFFER_SHIFT) & 0xFFFF)
    }
}

// ==================== CQ 推进 ====================

/**
 * 推进 CQ head 指针
 * 
 * 标记指定数量的 CQE 已被处理。
 * 此函数是非线程安全的，多线程环境需要外部同步。
 * 
 * @param ring io_uring 结构体指针
 * @param nr 推进的数量
 */
@When[os == "Linux"]
public func ioUringCQAdvance(ring: CPointer<IOUring>, nr: UInt32): Unit {
    if (nr == 0) {
        return
    }
    
    unsafe {
        let cq = ring.read().cq
        let oldHead = cq.khead.read()
        
        // 使用 release 语义写入新的 head
        ioUringSmpStoreRelease(cq.khead, oldHead + nr)
    }
}

/**
 * 标记单个 CQE 已被处理
 * 
 * 这是 ioUringCQAdvance 的便捷封装，用于处理单个 CQE。
 * 
 * @param ring io_uring 结构体指针
 * @param cqe 已处理的 CQE 指针（可以为 null）
 */
@When[os == "Linux"]
public func ioUringCQESeen(ring: CPointer<IOUring>, cqe: CPointer<IOUringCQE>): Unit {
    if (!cqe.isNull()) {
        ioUringCQAdvance(ring, 1)
    }
}

// ==================== 队列状态查询 ====================

/**
 * 查询 SQ 中待提交的请求数量
 * 
 * 返回已获取但尚未提交的 SQE 数量。
 * 
 * @param ring io_uring 结构体指针
 * @return 待提交的请求数量
 */
@When[os == "Linux"]
public func ioUringSQReady(ring: CPointer<IOUring>): UInt32 {
    unsafe {
        let ringVal = ring.read()
        let sq = ringVal.sq
        
        // 读取内核 head
        let head = if ((ringVal.flags & IORING_SETUP_SQPOLL) != 0) {
            ioUringSmpLoadAcquire(sq.khead)
        } else {
            sq.khead.read()
        }
        
        sq.sqeTail - head
    }
}

/**
 * 查询 SQ 中剩余可用空间
 * 
 * @param ring io_uring 结构体指针
 * @return 可用的 SQE 槽位数量
 */
@When[os == "Linux"]
public func ioUringSQSpaceLeft(ring: CPointer<IOUring>): UInt32 {
    unsafe {
        let ringVal = ring.read()
        let sq = ringVal.sq
        
        sq.ringEntries - ioUringSQReady(ring)
    }
}

/**
 * 查询 CQ 中待处理的完成数量
 * 
 * 返回已可用但尚未被收割的 CQE 数量。
 * 
 * @param ring io_uring 结构体指针
 * @return 待处理的完成数量
 */
@When[os == "Linux"]
public func ioUringCQReady(ring: CPointer<IOUring>): UInt32 {
    unsafe {
        let cq = ring.read().cq
        
        // 使用 acquire 语义读取 tail
        let tail = ioUringSmpLoadAcquire(cq.ktail)
        let head = cq.khead.read()
        
        tail - head
    }
}

/**
 * 检查 CQ 是否有溢出
 * 
 * @param ring io_uring 结构体指针
 * @return 是否有溢出
 */
@When[os == "Linux"]
public func ioUringCQHasOverflow(ring: CPointer<IOUring>): Bool {
    unsafe {
        let sq = ring.read().sq
        (sq.kflags.read() & IORING_SQ_CQ_OVERFLOW) != 0
    }
}

/**
 * 检查 SQ 是否需要唤醒
 * 
 * 仅在 SQPOLL 模式下有意义。
 * 
 * @param ring io_uring 结构体指针
 * @return 是否需要唤醒
 */
@When[os == "Linux"]
public func ioUringSQNeedWakeup(ring: CPointer<IOUring>): Bool {
    unsafe {
        let sq = ring.read().sq
        (sq.kflags.read() & IORING_SQ_NEED_WAKEUP) != 0
    }
}

// ==================== SQE tail 更新 ====================

/**
 * 更新 SQ 的 sqeTail
 * 
 * 用于在批量获取 SQE 后更新 tail。
 * 
 * 注意：由于 IOUringSQ 是值类型，此函数需要直接操作内存。
 * 
 * @param ring io_uring 结构体指针
 * @param newTail 新的 tail 值
 */
@When[os == "Linux"]
public func ioUringSetSQETail(ring: CPointer<IOUring>, newTail: UInt32): Unit {
    unsafe {
        // IOUringSQ 中 sqeTail 的偏移量
        // 需要根据实际结构体布局计算
        // sqeTail 在 IOUringSQ 中的偏移是 72 字节（8个指针 + 2个 UInt32）
        let sqPtr = CPointer<Byte>(ring)
        let sqeTailPtr = CPointer<UInt32>(sqPtr + 72)
        sqeTailPtr.write(newTail)
    }
}

/**
 * 获取当前的 sqeTail
 * 
 * @param ring io_uring 结构体指针
 * @return 当前的 sqeTail 值
 */
@When[os == "Linux"]
public func ioUringGetSQETail(ring: CPointer<IOUring>): UInt32 {
    unsafe {
        ring.read().sq.sqeTail
    }
}

/**
 * 增加 sqeTail
 * 
 * 每次成功获取 SQE 后调用此函数。
 * 
 * @param ring io_uring 结构体指针
 * @param delta 增量（默认为 1）
 */
@When[os == "Linux"]
public func ioUringAdvanceSQETail(ring: CPointer<IOUring>, delta!: UInt32 = 1): Unit {
    unsafe {
        let currentTail = ring.read().sq.sqeTail
        ioUringSetSQETail(ring, currentTail + delta)
    }
}
