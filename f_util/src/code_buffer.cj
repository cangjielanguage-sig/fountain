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
package fountain::f_util

/**
 * 可执行代码页：`mmap` RW → 写入 → `mprotect` RX（W^X）→ `__clear_cache`。
 *
 * 与 f_jit 的 `CodeBuffer` 同一模式（同仓库、同一许可证），但**不依赖 f_jit**：
 * 这里只保留 CRC 生成器需要的最小面。任何一步失败都返回 `None`/`false`，
 * 调用方回退纯软件；页面常驻进程生命周期（不 `munmap`，避免 `CFunc` 悬空）。
 */
@When[os == "Linux"]
class CodeBuffer {
    private var ptr: CPointer<UInt8>
    private let len: Int64
    private var sealed: Bool

    private init(ptr: CPointer<UInt8>, len: Int64) {
        this.ptr = ptr
        this.len = len
        this.sealed = false
    }

    private static func pageSize(): Int64 {
        let v = unsafe { sysconf(30) } // _SC_PAGESIZE
        if (v <= 0) {
            4096
        } else {
            v
        }
    }

    static func alloc(size: Int64): ?CodeBuffer {
        if (size <= 0) {
            return None
        }
        let page = CodeBuffer.pageSize()
        let rounded = ((size + page - 1) / page) * page
        // PROT_READ|PROT_WRITE = 3; MAP_PRIVATE|MAP_ANONYMOUS = 0x22
        let p = unsafe { mmap(CPointer<UInt8>(), rounded, 3, 0x22, -1, 0) }
        if (p.isNull() || p.toUIntNative() == UIntNative.Max) {
            None
        } else {
            Some(CodeBuffer(p, rounded))
        }
    }

    func rawPointer(): CPointer<UInt8> {
        if (sealed) {
            ptr
        } else {
            ptr
        }
    }

    func write(bytes: Array<UInt8>, off: Int64): Bool {
        if (sealed || off < 0 || off + bytes.size > len) {
            return false
        }
        unsafe {
            for (i in 0..bytes.size) {
                ptr.write(off + i, bytes[i])
            }
        }
        true
    }

    func seal(): Bool {
        if (sealed) {
            return true
        }
        // PROT_READ|PROT_EXEC = 5
        if (unsafe { mprotect(ptr, len, 5) } != 0) {
            return false
        }
        sealed = true
        unsafe {
            __clear_cache(ptr, ptr + len)
        }
        true
    }
}

@FastNative
@When[os == "Linux"]
foreign func mmap(addr: CPointer<UInt8>, length: Int64, prot: Int32, flags: Int32, fd: Int32,
    offset: Int64): CPointer<UInt8>
@FastNative
@When[os == "Linux"]
foreign func mprotect(addr: CPointer<UInt8>, length: Int64, prot: Int32): Int32
@FastNative
@When[os == "Linux"]
foreign func sysconf(name: Int32): Int64
@FastNative
@When[os == "Linux"]
foreign func __clear_cache(begin: CPointer<UInt8>, end: CPointer<UInt8>): Unit
