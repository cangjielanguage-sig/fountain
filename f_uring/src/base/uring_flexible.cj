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

import std.collection.ArrayList

/**
 * 柔性数组访问扩展
 * 
 * 仓颉不支持 C99 柔性数组（如 `cmd[0]`），需要通过指针偏移访问。
 * 本文件为相关结构体提供柔性数组访问的扩展函数。
 * 
 * 仅在 Linux 平台可用。
 */

// ==================== IOUringSQE cmd 数组访问 ====================

/**
 * IOUringSQE 的 cmd 柔性数组辅助函数
 * 
 * cmd 数组仅在 IORING_SETUP_SQE128 模式下有效，
 * 用于存储 uring_cmd 操作的命令数据。
 */
@When[os == "Linux"]
public class SQECmdHelper {
    /**
     * cmd 数组相对于 SQE 结构体的偏移量
     * IOUringSQE 结构体大小为 48 字节（标准模式）
     */
    public static let CMD_OFFSET: Int64 = 48
    
    /**
     * cmd 数组的最大大小（128 字节模式下为 80 字节）
     */
    public static let CMD_MAX_SIZE: Int64 = 80
}

/**
 * 获取 SQE 的 cmd 数组起始指针
 * 
 * cmd 数组紧接在 SQE 结构体后面。
 * 
 * @param sqe SQE 指针
 * @return cmd 数组的起始指针
 */
@When[os == "Linux"]
public func sqeCmdPtr(sqe: CPointer<IOUringSQE>): CPointer<UInt8> {
    unsafe {
        let bytePtr = CPointer<Byte>(sqe)
        CPointer<UInt8>(bytePtr + SQECmdHelper.CMD_OFFSET)
    }
}

/**
 * 获取 SQE cmd 数组的指定字节
 * 
 * @param sqe SQE 指针
 * @param index 字节索引（0-79）
 * @return cmd 字节值
 */
@When[os == "Linux"]
public func sqeGetCmd(sqe: CPointer<IOUringSQE>, index: Int64): UInt8 {
    unsafe {
        if (index < 0 || index >= SQECmdHelper.CMD_MAX_SIZE) {
            throw IoUringException("cmd index out of range: ${index}")
        }
        (sqeCmdPtr(sqe) + index).read()
    }
}

/**
 * 设置 SQE cmd 数组的指定字节
 * 
 * @param sqe SQE 指针
 * @param index 字节索引（0-79）
 * @param value 要设置的字节值
 */
@When[os == "Linux"]
public func sqeSetCmd(sqe: CPointer<IOUringSQE>, index: Int64, value: UInt8): Unit {
    unsafe {
        if (index < 0 || index >= SQECmdHelper.CMD_MAX_SIZE) {
            throw IoUringException("cmd index out of range: ${index}")
        }
        (sqeCmdPtr(sqe) + index).write(value)
    }
}

/**
 * 批量读取 SQE cmd 数组
 * 
 * @param sqe SQE 指针
 * @param offset 起始偏移
 * @param length 读取长度
 * @return cmd 字节数组
 */
@When[os == "Linux"]
public func sqeReadCmd(sqe: CPointer<IOUringSQE>, offset: Int64, length: Int64): Array<UInt8> {
    unsafe {
        if (offset < 0 || length < 0 || offset + length > SQECmdHelper.CMD_MAX_SIZE) {
            throw IoUringException("cmd read range out of bounds: offset=${offset}, length=${length}")
        }
        
        let cmdPtr = sqeCmdPtr(sqe) + offset
        Array<UInt8>(length) { i => (cmdPtr + i).read() }
    }
}

/**
 * 批量写入 SQE cmd 数组
 * 
 * @param sqe SQE 指针
 * @param offset 起始偏移
 * @param data 要写入的字节数组
 */
@When[os == "Linux"]
public func sqeWriteCmd(sqe: CPointer<IOUringSQE>, offset: Int64, data: Array<UInt8>): Unit {
    unsafe {
        if (offset < 0 || offset + data.size > SQECmdHelper.CMD_MAX_SIZE) {
            throw IoUringException("cmd write range out of bounds")
        }
        
        let cmdPtr = sqeCmdPtr(sqe) + offset
        for (i in 0..data.size) {
            (cmdPtr + i).write(data[i])
        }
    }
}

// ==================== IOUringCQE big_cqe 数组访问 ====================

/**
 * IOUringCQE 的 big_cqe 柔性数组辅助函数
 * 
 * big_cqe 数组仅在 IORING_SETUP_CQE32 模式下有效，
 * 用于存储额外的 16 字节数据。
 */
@When[os == "Linux"]
public class CQEBigHelper {
    /**
     * big_cqe 数组相对于 CQE 结构体的偏移量
     * IOUringCQE 结构体大小为 16 字节
     */
    public static let BIG_CQE_OFFSET: Int64 = 16
    
    /**
     * big_cqe 数组大小（2 个 UInt64，共 16 字节）
     */
    public static let BIG_CQE_SIZE: Int64 = 2
}

/**
 * 获取 CQE 的 big_cqe 数组起始指针
 * 
 * big_cqe 数组紧接在 CQE 结构体后面。
 * 
 * @param cqe CQE 指针
 * @return big_cqe 数组的起始指针（UInt64 类型）
 */
@When[os == "Linux"]
public func cqeBigCQEPtr(cqe: CPointer<IOUringCQE>): CPointer<UInt64> {
    unsafe {
        let bytePtr = CPointer<Byte>(cqe)
        CPointer<UInt64>(bytePtr + CQEBigHelper.BIG_CQE_OFFSET)
    }
}

/**
 * 获取 CQE big_cqe 数组的指定元素
 * 
 * @param cqe CQE 指针
 * @param index 元素索引（0-1）
 * @return big_cQE 元素值
 */
@When[os == "Linux"]
public func cqeGetBigCQE(cqe: CPointer<IOUringCQE>, index: Int64): UInt64 {
    unsafe {
        if (index < 0 || index >= CQEBigHelper.BIG_CQE_SIZE) {
            throw IoUringException("big_cqe index out of range: ${index}")
        }
        (cqeBigCQEPtr(cqe) + index).read()
    }
}

/**
 * 设置 CQE big_cqe 数组的指定元素
 * 
 * 注意：big_cQE 是内核写入的，应用层通常不应修改。
 * 
 * @param cqe CQE 指针
 * @param index 元素索引（0-1）
 * @param value 要设置的值
 */
@When[os == "Linux"]
public func cqeSetBigCQE(cqe: CPointer<IOUringCQE>, index: Int64, value: UInt64): Unit {
    unsafe {
        if (index < 0 || index >= CQEBigHelper.BIG_CQE_SIZE) {
            throw IoUringException("big_cqe index out of range: ${index}")
        }
        (cqeBigCQEPtr(cqe) + index).write(value)
    }
}

// ==================== IOUringProbeHeader ops 数组访问 ====================

/**
 * IOUringProbeHeader 的 ops 柔性数组辅助函数
 * 
 * ops 数组用于探测内核支持的 io_uring 操作。
 */
@When[os == "Linux"]
public class ProbeOpsHelper {
    /**
     * ops 数组相对于 ProbeHeader 结构体的偏移量
     * IOUringProbeHeader 结构体大小为 16 字节
     */
    public static let OPS_OFFSET: Int64 = 16
    
    /**
     * IOUringProbeOp 结构体大小
     */
    public static let PROBE_OP_SIZE: Int64 = 8
}

/**
 * 获取 Probe 的 ops 数组起始指针
 * 
 * @param probe Probe 结构体指针
 * @return ops 数组的起始指针
 */
@When[os == "Linux"]
public func probeOpsPtr(probe: CPointer<IOUringProbeHeader>): CPointer<IOUringProbeOp> {
    unsafe {
        let bytePtr = CPointer<Byte>(probe)
        CPointer<IOUringProbeOp>(bytePtr + ProbeOpsHelper.OPS_OFFSET)
    }
}

/**
 * 获取 Probe 的指定 ops 元素
 * 
 * @param probe Probe 结构体指针
 * @param index ops 元素索引
 * @return IOUringProbeOp 实例
 */
@When[os == "Linux"]
public func probeGetOp(probe: CPointer<IOUringProbeHeader>, index: Int64): IOUringProbeOp {
    unsafe {
        let opsLen = Int64(probe.read().opsLen)
        if (index < 0 || index >= opsLen) {
            throw IoUringException("probe ops index out of range: ${index}")
        }
        (probeOpsPtr(probe) + index).read()
    }
}

/**
 * 检查指定的操作码是否被内核支持
 * 
 * @param probe Probe 结构体指针
 * @param opcode 要检查的操作码
 * @return 是否支持
 */
@When[os == "Linux"]
public func probeIsOpcodeSupported(probe: CPointer<IOUringProbeHeader>, opcode: UInt8): Bool {
    unsafe {
        let probeVal = probe.read()
        
        // 检查操作码是否在范围内
        if (opcode > probeVal.lastOp) {
            return false
        }
        
        // 获取对应的 ops 条目
        let opEntry = (probeOpsPtr(probe) + Int64(opcode)).read()
        
        // 检查支持标志
        (opEntry.flags & IO_URING_OP_SUPPORTED) != 0
    }
}

/**
 * 获取 Probe 支持的所有操作码列表
 * 
 * @param probe Probe 结构体指针
 * @return 支持的操作码数组
 */
@When[os == "Linux"]
public func probeGetSupportedOpcodes(probe: CPointer<IOUringProbeHeader>): Array<UInt8> {
    unsafe {
        let probeVal = probe.read()
        let result = ArrayList<UInt8>()
        
        for (i in 0..=probeVal.lastOp) {
            if (probeIsOpcodeSupported(probe, UInt8(i))) {
                result.add(UInt8(i))
            }
        }
        
        result.toArray()
    }
}

/**
 * 获取 Probe 的 ops 数量
 * 
 * @param probe Probe 结构体指针
 * @return ops 数量
 */
@When[os == "Linux"]
public func probeGetOpsCount(probe: CPointer<IOUringProbeHeader>): Int64 {
    unsafe { Int64(probe.read().opsLen) }
}

/**
 * 获取 Probe 支持的最后一个操作码
 * 
 * @param probe Probe 结构体指针
 * @return 最后一个操作码
 */
@When[os == "Linux"]
public func probeGetLastOp(probe: CPointer<IOUringProbeHeader>): UInt8 {
    unsafe { probe.read().lastOp }
}

// ==================== IOUringBufRing bufs 数组访问 ====================

/**
 * IOUringBufRing 的 bufs 柔性数组辅助函数
 * 
 * bufs 数组用于 buffer ring 的缓冲区管理。
 */
@When[os == "Linux"]
public class BufRingHelper {
    /**
     * bufs 数组相对于结构体的偏移量
     * 需要注意 IOUringBufRing 的 union 结构
     * bufs 数组从结构体开头开始
     */
    public static let BUFS_OFFSET: Int64 = 0
    
    /**
     * IOUringBuf 结构体大小
     */
    public static let BUF_SIZE: Int64 = 16
}

/**
 * 获取 BufRing 的 bufs 数组起始指针
 * 
 * 注意：IOUringBufRing 的 bufs 数组与 tail 字段重叠，
 * 需要通过正确的偏移量访问。
 * 
 * @param bufRing BufRing 指针
 * @return bufs 数组的起始指针
 */
@When[os == "Linux"]
public func bufRingBufsPtr(bufRing: CPointer<Unit>): CPointer<IOUringBuf> {
    unsafe {
        CPointer<IOUringBuf>(bufRing)
    }
}

/**
 * 获取 BufRing 的指定 buf 元素
 * 
 * @param bufRing BufRing 指针
 * @param index buf 索引
 * @param ringEntries ring 总条目数（用于边界检查）
 * @return IOUringBuf 实例
 */
@When[os == "Linux"]
public func bufRingGetBuf(bufRing: CPointer<Unit>, index: Int64, ringEntries: UInt32): IOUringBuf {
    unsafe {
        if (index < 0 || index >= Int64(ringEntries)) {
            throw IoUringException("buf ring index out of range: ${index}")
        }
        (bufRingBufsPtr(bufRing) + index).read()
    }
}

/**
 * 设置 BufRing 的指定 buf 元素
 * 
 * @param bufRing BufRing 指针
 * @param index buf 索引
 * @param ringEntries ring 总条目数
 * @param addr 缓冲区地址
 * @param len 缓冲区长度
 * @param bid 缓冲区 ID
 */
@When[os == "Linux"]
public func bufRingSetBuf(
    bufRing: CPointer<Unit>,
    index: Int64,
    ringEntries: UInt32,
    addr: UInt64,
    len: UInt32,
    bid: UInt16
): Unit {
    unsafe {
        if (index < 0 || index >= Int64(ringEntries)) {
            throw IoUringException("buf ring index out of range: ${index}")
        }
        
        var buf = IOUringBuf()
        buf.addr = addr
        buf.len = len
        buf.bid = bid
        buf.resv = 0
        
        (bufRingBufsPtr(bufRing) + index).write(buf)
    }
}

/**
 * 获取 BufRing mask
 * 
 * mask 用于计算环形队列的索引。
 * 
 * @param ringEntries ring 条目数
 * @return mask 值
 */
@When[os == "Linux"]
public func bufRingMask(ringEntries: UInt32): Int64 {
    Int64(ringEntries - 1)
}

/**
 * 初始化 BufRing
 * 
 * 将 tail 设置为 0。
 * 
 * @param bufRing BufRing 指针
 */
@When[os == "Linux"]
public func bufRingInit(bufRing: CPointer<Unit>): Unit {
    unsafe {
        // tail 在 bufs 数组的第三个 UInt16 位置（offset 6）
        let tailPtr = CPointer<UInt16>(CPointer<Byte>(bufRing) + 6)
        tailPtr.write(0)
    }
}

/**
 * 获取 BufRing tail
 * 
 * @param bufRing BufRing 指针
 * @return tail 值
 */
@When[os == "Linux"]
public func bufRingGetTail(bufRing: CPointer<Unit>): UInt16 {
    unsafe {
        let tailPtr = CPointer<UInt16>(CPointer<Byte>(bufRing) + 6)
        tailPtr.read()
    }
}

/**
 * 设置 BufRing tail
 * 
 * @param bufRing BufRing 指针
 * @param tail 新的 tail 值
 */
@When[os == "Linux"]
public func bufRingSetTail(bufRing: CPointer<Unit>, tail: UInt16): Unit {
    unsafe {
        let tailPtr = CPointer<UInt16>(CPointer<Byte>(bufRing) + 6)
        tailPtr.write(tail)
    }
}