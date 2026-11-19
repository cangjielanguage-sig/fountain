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
 * x86_64 Linux 的生成式硬件 CRC。
 *
 * - CRC32C：SSE4.2 `crc32` 指令（raw 语义，8 字节循环 + 尾部逐字节）；
 * - ISO-HDLC：PCLMULQDQ 折叠（raw 语义，只处理 16 字节整数倍，尾部由调用方软件补齐）。
 *
 * 生成失败（mmap/mprotect/CPU 不支持/关闭开关）一律返回 `None`，调用方回退软件。
 */
@When[os == "Linux" && arch == "x86_64"]
class Crc32Hw {
    private static let lock = Mutex()
    private static var ready = false
    private static var nativeEnabled = true
    private static var crc32c: ?CFunc<(UInt32, CPointer<Byte>, UInt64) -> UInt32> = None
    private static var iso: ?CFunc<(UInt32, CPointer<Byte>, UInt64) -> UInt32> = None
    /** 保活代码页：CFunc 指向它们，不能提前释放。 */
    private static let codes = ArrayList<CodeBuffer>()

    /** CRC32C raw：`crc32 rax, [rsi]` 8 字节循环 + 尾部逐字节（汇编器核对）。 */
    private static let CRC32C_CODE: Array<UInt8> = [
        0x89, 0xf8, 0x48, 0x83, 0xfa, 0x08, 0x72, 0x14,
        0xf2, 0x48, 0x0f, 0x38, 0xf1, 0x06, 0x48, 0x83,
        0xc6, 0x08, 0x48, 0x83, 0xea, 0x08, 0x48, 0x83,
        0xfa, 0x08, 0x73, 0xec, 0x48, 0x85, 0xd2, 0x74,
        0x0d, 0xf2, 0x0f, 0x38, 0xf0, 0x06, 0x48, 0xff,
        0xc6, 0x48, 0xff, 0xca, 0x75, 0xf3, 0xc3
    ]

    /**
     * ISO-HDLC raw：PCLMULQDQ 16 字节折叠 + Barrett 归约（汇编器核对）。
     *
     * 常量（GF(2)，x^D mod G，G=0x1DB710641）：1VECS_MULT_1=0xAE689191（x^159）、
     * 1VECS_MULT_2=0xCCAA009E（x^95）、FINAL=0xB8BC6765（x^63）、Barrett=0x1F7011641。
     * 生成函数只处理 16 字节整数倍；尾部由 `Crc32.update` 用软件补齐。
     */
    private static let ISO_CODE: Array<UInt8> = [
        0x48, 0x85, 0xd2, 0x0f, 0x84, 0x0a, 0x01, 0x00, 0x00, 0x48, 0xb8, 0x91,
        0x91, 0x68, 0xae, 0x00, 0x00, 0x00, 0x00, 0x66, 0x48, 0x0f, 0x6e, 0xc8,
        0x48, 0xb8, 0x9e, 0x00, 0xaa, 0xcc, 0x00, 0x00, 0x00, 0x00, 0x66, 0x48,
        0x0f, 0x6e, 0xc0, 0x66, 0x0f, 0x6c, 0xc8, 0x48, 0xb8, 0x65, 0x67, 0xbc,
        0xb8, 0x00, 0x00, 0x00, 0x00, 0x66, 0x0f, 0xef, 0xd2, 0x66, 0x48, 0x0f,
        0x6e, 0xd0, 0x48, 0xb8, 0x41, 0x16, 0x01, 0xf7, 0x01, 0x00, 0x00, 0x00,
        0x66, 0x48, 0x0f, 0x6e, 0xd8, 0x48, 0xb8, 0x41, 0x06, 0x71, 0xdb, 0x01,
        0x00, 0x00, 0x00, 0x66, 0x48, 0x0f, 0x6e, 0xc0, 0x66, 0x0f, 0x6c, 0xd8,
        0x48, 0xb8, 0xff, 0xff, 0xff, 0xff, 0x00, 0x00, 0x00, 0x00, 0x66, 0x0f,
        0xef, 0xe4, 0x66, 0x48, 0x0f, 0x6e, 0xe0, 0xf3, 0x0f, 0x6f, 0x06, 0x66,
        0x0f, 0xef, 0xed, 0x66, 0x0f, 0x6e, 0xef, 0x66, 0x0f, 0xef, 0xc5, 0x48,
        0x83, 0xc6, 0x10, 0x48, 0x83, 0xea, 0x10, 0x74, 0x26, 0x66, 0x0f, 0x6f,
        0xe8, 0x66, 0x0f, 0x3a, 0x44, 0xc1, 0x00, 0x66, 0x0f, 0x3a, 0x44, 0xe9,
        0x11, 0x66, 0x0f, 0xef, 0xc5, 0xf3, 0x0f, 0x6f, 0x2e, 0x66, 0x0f, 0xef,
        0xc5, 0x48, 0x83, 0xc6, 0x10, 0x48, 0x83, 0xea, 0x10, 0x75, 0xda, 0x66,
        0x0f, 0x6f, 0xe8, 0x66, 0x0f, 0x73, 0xdd, 0x08, 0x66, 0x0f, 0x3a, 0x44,
        0xc1, 0x10, 0x66, 0x0f, 0xef, 0xc5, 0x66, 0x0f, 0x6f, 0xe8, 0x66, 0x0f,
        0x73, 0xdd, 0x04, 0x66, 0x0f, 0x6f, 0xf0, 0x66, 0x0f, 0xdb, 0xf4, 0x66,
        0x0f, 0x3a, 0x44, 0xf2, 0x00, 0x66, 0x0f, 0xef, 0xee, 0x66, 0x0f, 0x6f,
        0xc5, 0x66, 0x0f, 0x6f, 0xe8, 0x66, 0x0f, 0xdb, 0xec, 0x66, 0x0f, 0x3a,
        0x44, 0xeb, 0x00, 0x66, 0x0f, 0x6f, 0xf5, 0x66, 0x0f, 0xdb, 0xf4, 0x66,
        0x0f, 0x3a, 0x44, 0xf3, 0x10, 0x66, 0x0f, 0xef, 0xc6, 0x66, 0x0f, 0x6f,
        0xe8, 0x66, 0x0f, 0x73, 0xdd, 0x04, 0x66, 0x0f, 0x7e, 0xe8, 0xc3, 0x89,
        0xf8, 0xc3
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

    /**
     * raw 更新。
     *
     * ISO 要求 `data.size` 是 16 的整数倍（由 `Crc32.update` 切好前缀，尾部走软件）；
     * CRC32C 接受任意长度。
     */
    static func update(kind: CrcHwKind, crc: UInt32, data: Array<Byte>): ?UInt32 {
        if (!nativeEnabled || data.size == 0) {
            return None
        }
        if (!ensureReady()) {
            return None
        }
        match (kind) {
            case Crc32c => call(crc32c, crc, data)
            case Iso =>
                if (data.size % 16 != 0) {
                    None
                } else {
                    call(iso, crc, data)
                }
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

    /** 测试/诊断钩子：关闭后立刻回退软件；重新打开需要 `resetForTest()`。 */
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
                if (!envEnabled()) {
                    false
                } else {
                    let flags = cpuFlags()
                    if (flags.contains("sse4_2")) {
                        crc32c = make(CRC32C_CODE)
                    }
                    if (flags.contains("pclmulqdq")) {
                        iso = make(ISO_CODE)
                    }
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
