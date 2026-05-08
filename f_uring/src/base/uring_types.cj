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
 * io_uring 核心结构体定义
 * 仅在 Linux 平台可用
 */

// ==================== IOVec ====================

/** I/O 向量结构 */
@When[os == "Linux"]
@C
public struct IOVec {
    public var iovBase: CPointer<Unit> = CPointer<Unit>()
    public var iovLen: UIntNative = 0
}

// ==================== KernelTimespec ====================

/** 内核时间规格 */
@When[os == "Linux"]
@C
public struct KernelTimespec {
    public var tvSec: Int64 = 0
    public var tvNsec: Int64 = 0
}

// ==================== SQ Ring Offsets ====================

/** SQ 环形队列偏移量 */
@When[os == "Linux"]
@C
public struct IOSQRingOffsets {
    public var head: UInt32 = 0
    public var tail: UInt32 = 0
    public var ringMask: UInt32 = 0
    public var ringEntries: UInt32 = 0
    public var flags: UInt32 = 0
    public var dropped: UInt32 = 0
    public var array: UInt32 = 0
    public var resv1: UInt32 = 0
    public var userAddr: UInt64 = 0
}

// ==================== CQ Ring Offsets ====================

/** CQ 环形队列偏移量 */
@When[os == "Linux"]
@C
public struct IOCQRingOffsets {
    public var head: UInt32 = 0
    public var tail: UInt32 = 0
    public var ringMask: UInt32 = 0
    public var ringEntries: UInt32 = 0
    public var overflow: UInt32 = 0
    public var cqes: UInt32 = 0
    public var flags: UInt32 = 0
    public var resv1: UInt32 = 0
    public var userAddr: UInt64 = 0
}

// ==================== IOUringParams ====================

/** io_uring 初始化参数 */
@When[os == "Linux"]
@C
public struct IOUringParams {
    public var sqEntries: UInt32 = 0
    public var cqEntries: UInt32 = 0
    public var flags: UInt32 = 0
    public var sqThreadCpu: UInt32 = 0
    public var sqThreadIdle: UInt32 = 0
    public var features: UInt32 = 0
    public var wqFd: UInt32 = 0
    public var resv: VArray<UInt32, $3> = VArray<UInt32, $3>(repeat: 0)
    public var sqOff: IOSQRingOffsets = IOSQRingOffsets()
    public var cqOff: IOCQRingOffsets = IOCQRingOffsets()
}

// ==================== IOUringSQE ====================

/**
 * 提交队列条目 (Submission Queue Entry)
 * 
 * 注意：C 结构体中的 union 在仓颉中无法直接表示。
 * 这里只声明最常用的字段，其他 union 成员通过指针偏移访问。
 * 
 * 柔性数组 cmd[0] 通过扩展函数访问。
 */
@When[os == "Linux"]
@C
public struct IOUringSQE {
    /** 操作码 (IORING_OP_*) */
    public var opcode: UInt8 = 0
    
    /** SQE 标志 (IOSQE_*) */
    public var flags: UInt8 = 0
    
    /** I/O 优先级 */
    public var ioprio: UInt16 = 0
    
    /** 文件描述符 */
    public var fd: Int32 = 0
    
    /** 
     * union: off / addr2 / {cmd_op, __pad1}
     * 文件偏移量（最常用）
     */
    public var off: UInt64 = 0
    
    /** 
     * union: addr / splice_off_in
     * 缓冲区地址（最常用）
     */
    public var addr: UInt64 = 0
    
    /** 缓冲区长度或 iovec 数量 */
    public var len: UInt32 = 0
    
    /** 
     * union: rw_flags / fsync_flags / poll32_events / ...
     * 读写标志（最常用）
     */
    public var rwFlags: UInt32 = 0
    
    /** 用户数据，完成时原样返回 */
    public var userData: UInt64 = 0
    
    /** 
     * union: buf_index / buf_group
     * 固定缓冲区索引
     */
    public var bufIndex: UInt16 = 0
    
    /** 凭证 ID */
    public var personality: UInt16 = 0
    
    /** 
     * union: splice_fd_in / file_index / {addr_len, __pad3}
     * splice 输入 fd
     */
    public var spliceFdIn: Int32 = 0
    
    /** 
     * union: {addr3, __pad2} / cmd[0]
     * 第三个地址参数
     * cmd 柔性数组通过扩展函数访问
     */
    public var addr3: UInt64 = 0
}

// ==================== IOUringCQE ====================

/**
 * 完成队列条目 (Completion Queue Entry)
 * 
 * 柔性数组 big_cqe[] 仅在 IORING_SETUP_CQE32 时存在，
 * 通过指针访问。
 */
@When[os == "Linux"]
@C
public struct IOUringCQE {
    /** 对应 SQE 的 userData */
    public var userData: UInt64 = 0
    
    /** 操作结果（返回值或负错误码） */
    public var res: Int32 = 0
    
    /** CQE 标志 (IORING_CQE_F_*) */
    public var flags: UInt32 = 0
}

// ==================== IOUringBuf ====================

/** buffer ring 中的缓冲区条目 */
@When[os == "Linux"]
@C
public struct IOUringBuf {
    public var addr: UInt64 = 0
    public var len: UInt32 = 0
    public var bid: UInt16 = 0
    public var resv: UInt16 = 0
}

// ==================== IOUringBufReg ====================

/** buffer ring 注册参数 */
@When[os == "Linux"]
@C
public struct IOUringBufReg {
    public var ringAddr: UInt64 = 0
    public var ringEntries: UInt32 = 0
    public var bgid: UInt16 = 0
    public var flags: UInt16 = 0
    public var resv: VArray<UInt64, $3> = VArray<UInt64, $3>(repeat: 0)
}

// ==================== IOUringProbeOp ====================

/** 特性探测操作条目 */
@When[os == "Linux"]
@C
public struct IOUringProbeOp {
    public var op: UInt8 = 0
    public var resv: UInt8 = 0
    public var flags: UInt16 = 0
    public var resv2: UInt32 = 0
}

// ==================== IOUringProbeHeader ====================

/**
 * 特性探测结构体头部
 * 
 * 注意：io_uring_probe 包含柔性数组 ops[]，
 * 这里只声明头部，ops 数组通过指针偏移访问。
 */
@When[os == "Linux"]
@C
public struct IOUringProbeHeader {
    public var lastOp: UInt8 = 0
    public var opsLen: UInt8 = 0
    public var resv: UInt16 = 0
    public var resv2: VArray<UInt32, $3> = VArray<UInt32, $3>(repeat: 0)
}

// ==================== IOUringSQ ====================

/** liburing 内部 SQ 结构 */
@When[os == "Linux"]
@C
public struct IOUringSQ {
    public var khead: CPointer<UInt32> = CPointer<UInt32>()
    public var ktail: CPointer<UInt32> = CPointer<UInt32>()
    
    /** @deprecated use ringMask instead */
    public var kringMask: CPointer<UInt32> = CPointer<UInt32>()
    
    /** @deprecated use ringEntries instead */
    public var kringEntries: CPointer<UInt32> = CPointer<UInt32>()
    
    public var kflags: CPointer<UInt32> = CPointer<UInt32>()
    public var kdropped: CPointer<UInt32> = CPointer<UInt32>()
    public var array: CPointer<UInt32> = CPointer<UInt32>()
    public var sqes: CPointer<IOUringSQE> = CPointer<IOUringSQE>()
    
    public var sqeHead: UInt32 = 0
    public var sqeTail: UInt32 = 0
    
    public var ringSz: UIntNative = 0
    public var ringPtr: CPointer<Unit> = CPointer<Unit>()
    
    public var ringMask: UInt32 = 0
    public var ringEntries: UInt32 = 0
    
    public var pad: VArray<UInt32, $2> = VArray<UInt32, $2>(repeat: 0)
}

// ==================== IOUringCQ ====================

/** liburing 内部 CQ 结构 */
@When[os == "Linux"]
@C
public struct IOUringCQ {
    public var khead: CPointer<UInt32> = CPointer<UInt32>()
    public var ktail: CPointer<UInt32> = CPointer<UInt32>()
    
    /** @deprecated use ringMask instead */
    public var kringMask: CPointer<UInt32> = CPointer<UInt32>()
    
    /** @deprecated use ringEntries instead */
    public var kringEntries: CPointer<UInt32> = CPointer<UInt32>()
    
    public var kflags: CPointer<UInt32> = CPointer<UInt32>()
    public var koverflow: CPointer<UInt32> = CPointer<UInt32>()
    public var cqes: CPointer<IOUringCQE> = CPointer<IOUringCQE>()
    
    public var ringSz: UIntNative = 0
    public var ringPtr: CPointer<Unit> = CPointer<Unit>()
    
    public var ringMask: UInt32 = 0
    public var ringEntries: UInt32 = 0
    
    public var pad: VArray<UInt32, $2> = VArray<UInt32, $2>(repeat: 0)
}

// ==================== IOUring ====================

/** liburing 主结构体 */
@When[os == "Linux"]
@C
public struct IOUring {
    public var sq: IOUringSQ = IOUringSQ()
    public var cq: IOUringCQ = IOUringCQ()
    public var flags: UInt32 = 0
    public var ringFd: Int32 = 0
    
    public var features: UInt32 = 0
    public var enterRingFd: Int32 = 0
    public var intFlags: UInt8 = 0
    public var pad: VArray<UInt8, $3> = VArray<UInt8, $3>(repeat: 0)
    public var pad2: UInt32 = 0
}

// ==================== IOUringRsrcRegister ====================

/** 资源注册参数 */
@When[os == "Linux"]
@C
public struct IOUringRsrcRegister {
    public var nr: UInt32 = 0
    public var flags: UInt32 = 0
    public var resv2: UInt64 = 0
    public var data: UInt64 = 0
    public var tags: UInt64 = 0
}

// ==================== IOUringRsrcUpdate ====================

/** 资源更新参数 */
@When[os == "Linux"]
@C
public struct IOUringRsrcUpdate {
    public var offset: UInt32 = 0
    public var resv: UInt32 = 0
    public var data: UInt64 = 0
}

// ==================== IOUringSyncCancelReg ====================

/** 同步取消注册参数 */
@When[os == "Linux"]
@C
public struct IOUringSyncCancelReg {
    public var addr: UInt64 = 0
    public var fd: Int32 = 0
    public var flags: UInt32 = 0
    public var timeout: KernelTimespec = KernelTimespec()
    public var pad: VArray<UInt64, $4> = VArray<UInt64, $4>(repeat: 0)
}

// ==================== IOUringGeteventsArg ====================

/** getevents 参数 */
@When[os == "Linux"]
@C
public struct IOUringGeteventsArg {
    public var sigmask: UInt64 = 0
    public var sigmaskSz: UInt32 = 0
    public var pad: UInt32 = 0
    public var ts: UInt64 = 0
}
