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

import std.collection.ArrayList
import std.env.getVariable
import std.fs.{File, OpenMode}
import std.io.StringReader
import std.sync.Mutex

/**
 * aarch64 Linux 的生成式硬件 CRC（ARMv8 CRC 扩展）。
 *
 * - CRC32C：`crc32cx` / `crc32cb`；
 * - ISO-HDLC：`crc32x` / `crc32b`；
 * - 两者都是 raw 语义，函数内处理 8 字节循环 + 不足 8 字节的尾部。
 *
 * CPU 探测：`getauxval(AT_HWCAP) & HWCAP_CRC32`，失败回落 `/proc/cpuinfo` 的 `crc32`。
 * 生成失败（mmap/mprotect/无扩展/关闭开关）返回 `None`，调用方回退软件。
 */
@When[os == "Linux" && arch == "aarch64"]
class Crc32Hw {
    private static let lock = Mutex()
    private static var ready = false
    private static var nativeEnabled = true
    private static var crc32c: ?CFunc<(UInt32, CPointer<Byte>, UInt64) -> UInt32> = None
    private static var iso: ?CFunc<(UInt32, CPointer<Byte>, UInt64) -> UInt32> = None
    /** 保活代码页：CFunc 指向它们，不能提前释放。 */
    private static let codes = ArrayList<CodeBuffer>()

    /**
     * ISO-HDLC raw：`crc32x` 8 字节循环 + `crc32b` 尾部。
     *
     * 汇编（`aarch64-linux-gnu-as` 核对）：
     * `cbz len` / `cmp 8` / `ldr x3,[x1],#8` / `crc32x w0,w0,x3` / `sub` / `cmp` / `b.hs`
     * / 尾部 `ldrb` + `crc32b` + `cbnz` / `ret`。
     */
    private static let ISO_CODE: Array<UInt8> = [
        0xa2, 0x01, 0x00, 0xb4, 0x5f, 0x20, 0x00, 0xf1, 0xc3, 0x00, 0x00, 0x54,
        0x23, 0x84, 0x40, 0xf8, 0x00, 0x4c, 0xc3, 0x9a, 0x42, 0x20, 0x00, 0xd1,
        0x5f, 0x20, 0x00, 0xf1, 0x82, 0xff, 0xff, 0x54, 0xa2, 0x00, 0x00, 0xb4,
        0x23, 0x14, 0x40, 0x38, 0x00, 0x40, 0xc3, 0x1a, 0x42, 0x04, 0x00, 0xd1,
        0xa2, 0xff, 0xff, 0xb5, 0xc0, 0x03, 0x5f, 0xd6
    ]

    /** CRC32C raw：同上，指令换成 `crc32cx` / `crc32cb`。 */
    private static let CRC32C_CODE: Array<UInt8> = [
        0xa2, 0x01, 0x00, 0xb4, 0x5f, 0x20, 0x00, 0xf1, 0xc3, 0x00, 0x00, 0x54,
        0x23, 0x84, 0x40, 0xf8, 0x00, 0x5c, 0xc3, 0x9a, 0x42, 0x20, 0x00, 0xd1,
        0x5f, 0x20, 0x00, 0xf1, 0x82, 0xff, 0xff, 0x54, 0xa2, 0x00, 0x00, 0xb4,
        0x23, 0x14, 0x40, 0x38, 0x00, 0x50, 0xc3, 0x1a, 0x42, 0x04, 0x00, 0xd1,
        0xa2, 0xff, 0xff, 0xb5, 0xc0, 0x03, 0x5f, 0xd6
    ]

    static func available(): Bool {
        if (!nativeEnabled) {
            return false
        }
        ensureReady()
        crc32c.isSome() || iso.isSome()
    }

    static func availableFor(kind: CrcHwKind): Bool {
        if (!nativeEnabled) {
            return false
        }
        ensureReady()
        match (kind) {
            case Crc32c => crc32c.isSome()
            case Iso => iso.isSome()
            case Unsupported => false
        }
    }

    static func update(kind: CrcHwKind, crc: UInt32, data: Array<Byte>): ?UInt32 {
        if (!nativeEnabled || data.size == 0) {
            return None
        }
        if (!ensureReady()) {
            return None
        }
        match (kind) {
            case Crc32c => call(crc32c, crc, data)
            case Iso => call(iso, crc, data)
            case Unsupported => None
        }
    }

    private static func call(fn: ?CFunc<(UInt32, CPointer<Byte>, UInt64) -> UInt32>, crc: UInt32,
        data: Array<Byte>): ?UInt32 {
        match (fn) {
            case Some(f) =>
                let handle = unsafe { acquireArrayRawData<Byte>(data) }
                try {
                    Some(unsafe { f(crc, handle.pointer, UInt64(data.size)) })
                } finally {
                    unsafe { releaseArrayRawData(handle) }
                }
            case None => None
        }
    }

    static func setNativeEnabled(value: Bool): Unit {
        nativeEnabled = value
    }

    static func resetForTest(): Unit {
        synchronized(lock) {
            ready = false
            crc32c = None
            iso = None
            codes.clear()
        }
    }

    private static func ensureReady(): Bool {
        synchronized(lock) {
            if (ready) {
                crc32c.isSome() || iso.isSome()
            } else {
                ready = true
                if (!envEnabled() || !hasCrc32()) {
                    false
                } else {
                    crc32c = make(CRC32C_CODE)
                    iso = make(ISO_CODE)
                    crc32c.isSome() || iso.isSome()
                }
            }
        }
    }

    private static func make(bytes: Array<UInt8>): ?CFunc<(UInt32, CPointer<Byte>, UInt64) -> UInt32> {
        match (CodeBuffer.alloc(bytes.size + 64)) {
            case Some(buffer) =>
                if (!buffer.write(bytes, 0) || !buffer.seal()) {
                    return None
                }
                codes.add(buffer)
                Some(CFunc<(UInt32, CPointer<Byte>, UInt64) -> UInt32>(
                    CPointer<Unit>(buffer.rawPointer())))
            case None => None
        }
    }

    private static func envEnabled(): Bool {
        match (getVariable("F_UTIL_CRC_HW")) {
            case Some(v) => v != "0"
            case None => true
        }
    }

    private static func hasCrc32(): Bool {
        // AT_HWCAP = 16, HWCAP_CRC32 = 1 << 7
        if ((unsafe { getauxval(16) } & 128u64) != 0) {
            return true
        }
        // 容器/受限环境可能屏蔽 auxv；退回 /proc/cpuinfo 的 Features
        cpuFlags().contains("crc32")
    }

    private static func cpuFlags(): String {
        try {
            let f = File("/proc/cpuinfo", OpenMode.Read)
            try {
                StringReader(f).readToEnd()
            } finally {
                f.close()
            }
        } catch (_: Exception) {
            ""
        }
    }
}

@FastNative
@When[os == "Linux" && arch == "aarch64"]
foreign func getauxval(kind: UInt64): UInt64
