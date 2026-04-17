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
 * io_uring 内存屏障函数
 * 
 * 这些函数用于确保在多线程环境下对共享内存环形队列的正确访问。
 * io_uring 的 SQ/CQ 环形队列是共享内存并发模型，需要正确的内存序。
 * 
 * 内存屏障语义：
 * - Acquire：确保后续读写操作不会被重排到此操作之前
 * - Release：确保之前读写操作不会被重排到此操作之后
 * 
 * 仅在 Linux 平台可用。
 */

// ==================== C 原子操作 FFI 声明 ====================

/**
 * 通过 FFI 调用 GCC 内置原子操作
 * 这些函数对应 C 的 __atomic_load_n 和 __atomic_store_n
 */
@When[os == "Linux"]
foreign {
    /**
     * 原子加载（acquire 语义）
     * @param ptr 指向 UInt32 的指针
     * @param memorder 内存序（0=relaxed, 2=acquire, 5=seq_cst）
     * @return 加载的值
     */
    func __atomic_load_4(ptr: CPointer<UInt32>, memorder: Int32): UInt32

    /**
     * 原子存储（release 语义）
     * @param ptr 指向 UInt32 的指针
     * @param val 要存储的值
     * @param memorder 内存序（0=relaxed, 3=release, 5=seq_cst）
     */
    func __atomic_store_4(ptr: CPointer<UInt32>, val: UInt32, memorder: Int32): Unit

    /**
     * 原子比较交换
     * @param ptr 指向 UInt32 的指针
     * @param expected 期望值的指针
     * @param desired 新值
     * @param success 成功时的内存序
     * @param failure 失败时的内存序
     * @return 是否成功
     */
    func __atomic_compare_exchange_4(
        ptr: CPointer<UInt32>,
        expected: CPointer<UInt32>,
        desired: UInt32,
        success: Int32,
        failure: Int32
    ): Bool

    /**
     * 原子加载 64 位
     * @param ptr 指向 UInt64 的指针
     * @param memorder 内存序
     * @return 加载的值
     */
    func __atomic_load_8(ptr: CPointer<UInt64>, memorder: Int32): UInt64

    /**
     * 原子存储 64 位
     * @param ptr 指向 UInt64 的指针
     * @param val 要存储的值
     * @param memorder 内存序
     */
    func __atomic_store_8(ptr: CPointer<UInt64>, val: UInt64, memorder: Int32): Unit

    /**
     * 全内存屏障
     */
    func __sync_synchronize(): Unit
}

// ==================== 内存序常量 ====================

/** relaxed 内存序 */
@When[os == "Linux"]
private const __ATOMIC_RELAXED: Int32 = 0

/** acquire 内存序 */
@When[os == "Linux"]
private const __ATOMIC_ACQUIRE: Int32 = 2

/** release 内存序 */
@When[os == "Linux"]
private const __ATOMIC_RELEASE: Int32 = 3

/** acq_rel 内存序 */
@When[os == "Linux"]
private const __ATOMIC_ACQ_REL: Int32 = 4

/** seq_cst 内存序 */
@When[os == "Linux"]
private const __ATOMIC_SEQ_CST: Int32 = 5

// ==================== 内存屏障辅助函数 ====================

/**
 * 使用 acquire 语义加载 UInt32 值
 * 
 * 用于读取 io_uring 环形队列的 tail 指针。
 * 确保后续对环形队列数据的读取不会被重排到此操作之前。
 * 
 * @param ptr 指向 UInt32 的指针
 * @return 加载的值
 */
@When[os == "Linux"]
public func ioUringSmpLoadAcquire(ptr: CPointer<UInt32>): UInt32 {
    unsafe { __atomic_load_4(ptr, __ATOMIC_ACQUIRE) }
}

/**
 * 使用 release 语义存储 UInt32 值
 * 
 * 用于更新 io_uring 环形队列的 head 指针。
 * 确保之前对环形队列数据的写入不会被重排到此操作之后。
 * 
 * @param ptr 指向 UInt32 的指针
 * @param value 要存储的值
 */
@When[os == "Linux"]
public func ioUringSmpStoreRelease(ptr: CPointer<UInt32>, value: UInt32): Unit {
    unsafe { __atomic_store_4(ptr, value, __ATOMIC_RELEASE) }
}

/**
 * 原子比较交换（CAS）操作
 * 
 * 用于无锁更新环形队列索引。
 * 
 * @param ptr 指向 UInt32 的指针
 * @param expected 期望的旧值（会被更新为实际值）
 * @param desired 新值
 * @return 是否成功交换
 */
@When[os == "Linux"]
public func ioUringAtomicCAS(
    ptr: CPointer<UInt32>,
    expected: CPointer<UInt32>,
    desired: UInt32
): Bool {
    unsafe {
        __atomic_compare_exchange_4(
            ptr,
            expected,
            desired,
            __ATOMIC_ACQ_REL,
            __ATOMIC_ACQUIRE
        )
    }
}

/**
 * 使用 acquire 语义加载 UInt64 值
 * 
 * @param ptr 指向 UInt64 的指针
 * @return 加载的值
 */
@When[os == "Linux"]
public func ioUringLoadAcquire64(ptr: CPointer<UInt64>): UInt64 {
    unsafe { __atomic_load_8(ptr, __ATOMIC_ACQUIRE) }
}

/**
 * 使用 release 语义存储 UInt64 值
 * 
 * @param ptr 指向 UInt64 的指针
 * @param value 要存储的值
 */
@When[os == "Linux"]
public func ioUringStoreRelease64(ptr: CPointer<UInt64>, value: UInt64): Unit {
    unsafe { __atomic_store_8(ptr, value, __ATOMIC_RELEASE) }
}

/**
 * 全内存屏障
 * 确保所有之前的内存操作在所有之后的内存操作之前完成
 */
@When[os == "Linux"]
public func ioUringSmpMB(): Unit {
    unsafe { __sync_synchronize() }
}

/**
 * 写屏障
 * 确保所有之前的写操作在所有之后的写操作之前完成
 */
@When[os == "Linux"]
public func ioUringSmpWMB(): Unit {
    // 在 x86 上，写操作本身是有序的，只需编译器屏障
    // 在 ARM 等弱序架构上需要实际的释放屏障
    ioUringSmpMB()
}

/**
 * 读屏障
 * 确保所有之前的读操作在所有之后的读操作之前完成
 */
@When[os == "Linux"]
public func ioUringSmpRMB(): Unit {
    // 在 x86 上，读操作本身是有序的，只需编译器屏障
    // 在 ARM 等弱序架构上需要实际的获取屏障
    ioUringSmpMB()
}
