/*
Copyright (c) 2026 WuJingrun（吴京润）

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
package fountain::f_jit.backend

/**
 * 代码内存（design §12.5、plan S5.1）：`mmap(PROT_READ|PROT_WRITE)` → 写入 →
 * `mprotect(PROT_READ|PROT_EXEC)`（W^X）→ `munmap`。
 *
 * - `alloc` 失败返回 `None`，**不抛异常**（桥据此降级解释器、不写错误槽）；
 * - 基址与映射长度都按页对齐（`sysconf(_SC_PAGESIZE)`）；
 * - `seal` 后 `write/patch` 返回 `false`（页已不可写）；
 * - `free` 幂等；`flushICache` 走 libgcc 的 `__clear_cache`（aarch64 必需，x86 同接口）。
 */
public class CodeBuffer {
    private static var flushCounter: Int64 = 0

    private var ptr: CPointer<UInt8>
    private var len: Int64
    private var sealed: Bool
    private var freed: Bool

    private init(ptr: CPointer<UInt8>, len: Int64) {
        this.ptr = ptr
        this.len = len
        this.sealed = false
        this.freed = false
    }

    /** 系统页大小（失败时回退 4096）。 */
    public static func pageSize(): Int64 {
        let v = unsafe { sysconf(30) } // _SC_PAGESIZE (Linux)
        if (v <= 0) {
            4096
        } else {
            v
        }
    }

    /** 分配 RW 代码内存；失败 → None。`size <= 0` 视为失败。 */
    public static func alloc(size: Int64): ?CodeBuffer {
        if (size <= 0) {
            return None
        }
        let page = CodeBuffer.pageSize()
        let rounded = ((size + page - 1) / page) * page
        // PROT_READ=1, PROT_WRITE=2；MAP_PRIVATE=2, MAP_ANONYMOUS=0x20
        let p = unsafe { mmap(CPointer<UInt8>(), rounded, 3, 0x22, -1, 0) }
        if (p.isNull() || p.toUIntNative() == UIntNative.Max) {
            return None
        }
        Some(CodeBuffer(p, rounded))
    }

    /** 基址（未分配 / 已释放 → 0）。 */
    public prop base: Int64 {
        get() {
            if (this.freed) {
                0
            } else {
                Int64(this.ptr.toUIntNative())
            }
        }
    }

    /** 映射长度（按页对齐；已释放 → 0）。 */
    public prop size: Int64 {
        get() {
            if (this.freed) {
                0
            } else {
                this.len
            }
        }
    }

    /** 写入（sealed / 越界 / 已释放 → false）。 */
    public func write(bytes: Array<UInt8>, off: Int64): Bool {
        if (this.freed || this.sealed || off < 0 || off + bytes.size > this.len) {
            return false
        }
        unsafe {
            for (i in 0..bytes.size) {
                this.ptr.write(off + i, bytes[i])
            }
        }
        true
    }

    /** 重定位补丁（与 `write` 同口径；sealed 后拒绝）。 */
    public func patch(pos: Int64, bytes: Array<UInt8>): Bool {
        this.write(bytes, pos)
    }

    /** 读回（未释放 / 未越界；否则返回空数组）。 */
    public func read(off: Int64, len: Int64): Array<UInt8> {
        if (this.freed || off < 0 || len < 0 || off + len > this.len) {
            return Array<UInt8>()
        }
        let out = Array<UInt8>(len, repeat: 0u8)
        unsafe {
            for (i in 0..len) {
                out[i] = this.ptr.read(off + i)
            }
        }
        out
    }

    /** 切换为 RX（W^X）并清理 I-cache；失败 → false。重复调用幂等。 */
    public func seal(): Bool {
        if (this.freed) {
            return false
        }
        if (this.sealed) {
            return true
        }
        // PROT_READ=1, PROT_EXEC=4
        let rc = unsafe { mprotect(this.ptr, this.len, 5) }
        if (rc != 0) {
            return false
        }
        this.sealed = true
        this.flushICache()
        true
    }

    /** 清理指令缓存（`__clear_cache`；aarch64 必需，x86 同接口）。 */
    public func flushICache(): Unit {
        if (this.freed) {
            return
        }
        unsafe {
            __clear_cache(this.ptr, this.ptr + this.len)
        }
        CodeBuffer.flushCounter = CodeBuffer.flushCounter + 1
    }

    /** 释放映射；幂等。 */
    public func free(): Unit {
        if (this.freed) {
            return
        }
        unsafe {
            let _ = munmap(this.ptr, this.len)
        }
        this.ptr = CPointer<UInt8>()
        this.len = 0
        this.freed = true
    }

    /** 测试/诊断：累计 `flushICache` 次数。 */
    public static func flushCount(): Int64 {
        CodeBuffer.flushCounter
    }

    /** 测试用：清零计数。 */
    public static func resetFlushCount(): Unit {
        CodeBuffer.flushCounter = 0
    }
}

// ---- libc（Linux）----

foreign func mmap(addr: CPointer<UInt8>, length: Int64, prot: Int32, flags: Int32, fd: Int32,
    offset: Int64): CPointer<UInt8>

foreign func mprotect(addr: CPointer<UInt8>, length: Int64, prot: Int32): Int32

foreign func munmap(addr: CPointer<UInt8>, length: Int64): Int32

foreign func sysconf(name: Int32): Int64

foreign func __clear_cache(begin: CPointer<UInt8>, end: CPointer<UInt8>): Unit
