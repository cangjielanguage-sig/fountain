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
import std.sync.Mutex

/**
 * aarch64 Linux 的生成式 CRC-64 折叠核（`PMULL` / `PMULL2`）。
 *
 * 只服务 `CRC-64/XZ` 家族（`poly = 0x42F0E1EBA9EA3693`、`refin && refout`）。
 * 入口对 `crc` 与每个 16 字节块做位反转（`RBIT` + 16 字节序反转），
 * 折叠走正常域常量 `x^128` / `x^192`，收尾用 `clmul(accLo,P) ^ clmul(accHi,x^128)` + Barrett。
 *
 * 失败（mmap/mprotect/无 PMULL/`F_UTIL_CRC_HW=off`）返回 `None`，调用方回退表路径。
 */
@When[os == "Linux" && arch == "aarch64"]
class Crc64Hw {
    private static let lock = Mutex()
    private static var ready = false
    private static var nativeEnabled = true
    private static var fn: ?CFunc<(UInt64, CPointer<Byte>, UInt64, CPointer<UInt64>) -> UInt64> = None
    /** 保活代码页：`CFunc` 指向它，不能提前释放。 */
    private static let codes = ArrayList<CodeBuffer>()
    /** 折叠常量：`[P, x^128, x^192, mu]`，构造期由 `CrcGf` 推导。 */
    private static var consts: ?Array<UInt64> = None

    /** 反射域折叠核（汇编源与字节见 `f_util/doc/spec/accelerate-f-util-crc/design.md` D5）。 */
    private static let CODE: Array<UInt8> = [
        0x00, 0x00, 0xc0, 0xda, 0x64, 0x00, 0x40, 0xfd, 0x84, 0x04, 0x08, 0x4e, 0x65, 0x04, 0x40, 0xfd,
        0xa5, 0x04, 0x08, 0x4e, 0x66, 0x08, 0x40, 0xfd, 0xc6, 0x04, 0x08, 0x4e, 0x67, 0x0c, 0x40, 0xfd,
        0xe7, 0x04, 0x08, 0x4e, 0x21, 0x04, 0xc1, 0x3c, 0x21, 0x58, 0x60, 0x6e, 0x21, 0x08, 0x20, 0x4e,
        0x21, 0x40, 0x01, 0x6e, 0x00, 0x00, 0x67, 0x9e, 0x02, 0xe4, 0x00, 0x6f, 0x40, 0x04, 0x18, 0x6e,
        0x02, 0xe0, 0xe4, 0x0e, 0x40, 0x1c, 0x21, 0x6e, 0x42, 0x40, 0x00, 0xd1, 0x5f, 0x40, 0x00, 0xf1,
        0x83, 0x01, 0x00, 0x54, 0x21, 0x04, 0xc1, 0x3c, 0x21, 0x58, 0x60, 0x6e, 0x21, 0x08, 0x20, 0x4e,
        0x21, 0x40, 0x01, 0x6e, 0x02, 0xe0, 0xe5, 0x0e, 0x03, 0xe0, 0xe6, 0x4e, 0x42, 0x1c, 0x23, 0x6e,
        0x40, 0x1c, 0x21, 0x6e, 0x42, 0x40, 0x00, 0xd1, 0x5f, 0x40, 0x00, 0xf1, 0xc2, 0xfe, 0xff, 0x54,
        0x02, 0xe0, 0xe4, 0x0e, 0x03, 0xe0, 0xe5, 0x4e, 0x42, 0x1c, 0x23, 0x6e, 0x44, 0x3c, 0x08, 0x4e,
        0x45, 0x3c, 0x18, 0x4e, 0x03, 0xe4, 0x00, 0x6f, 0xa3, 0x1c, 0x08, 0x4e, 0x63, 0xe0, 0xe7, 0x0e,
        0x66, 0x3c, 0x18, 0x4e, 0xc6, 0x00, 0x05, 0xca, 0x03, 0xe4, 0x00, 0x6f, 0xc3, 0x1c, 0x08, 0x4e,
        0x63, 0xe0, 0xe4, 0x0e, 0x67, 0x3c, 0x08, 0x4e, 0xe0, 0x00, 0x04, 0xca, 0x00, 0x00, 0xc0, 0xda,
        0xc0, 0x03, 0x5f, 0xd6
    ]

    static func available(): Bool {
        if (!nativeEnabled) {
            return false
        }
        ensureReady()
        fn.isSome()
    }

    /**
     * 对 `data[0..aligned]` 做折叠；`aligned` 必须是 16 的倍数且 >= 16。
     * 返回未收尾的寄存器值，尾部由调用方用表路径补齐。
     */
    static func update(crc: UInt64, data: Array<Byte>, aligned: Int64): ?UInt64 {
        if (!nativeEnabled || aligned < 16 || aligned > data.size) {
            return None
        }
        if (!ensureReady()) {
            return None
        }
        match (fn) {
            case Some(f) =>
                match (consts) {
                    case Some(c) =>
                        let handle = unsafe { acquireArrayRawData<Byte>(data) }
                        let chandle = unsafe { acquireArrayRawData<UInt64>(c) }
                        try {
                            Some(unsafe {
                                f(crc, handle.pointer, UInt64(aligned), chandle.pointer)
                            })
                        } finally {
                            unsafe { releaseArrayRawData(handle) }
                            unsafe { releaseArrayRawData(chandle) }
                        }
                    case None => None
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
            fn = None
            consts = None
            codes.clear()
        }
    }

    private static func ensureReady(): Bool {
        synchronized(lock) {
            if (ready) {
                fn.isSome()
            } else {
                ready = true
                if (!envEnabled() || !hasPmull()) {
                    false
                } else {
                    fn = make()
                    consts = CrcGf.reflectConstants64(0x42F0E1EBA9EA3693u64)
                    fn.isSome()
                }
            }
        }
    }

    private static func make(): ?CFunc<(UInt64, CPointer<Byte>, UInt64, CPointer<UInt64>) -> UInt64> {
        match (CodeBuffer.alloc(CODE.size + 64)) {
            case Some(buffer) =>
                if (!buffer.write(CODE, 0) || !buffer.seal()) {
                    None
                } else {
                    codes.add(buffer)
                    Some(CFunc<(UInt64, CPointer<Byte>, UInt64, CPointer<UInt64>) -> UInt64>(
                        CPointer<Unit>(buffer.rawPointer())))
                }
            case None => None
        }
    }

    private static func envEnabled(): Bool {
        match (getVariable("F_UTIL_CRC_HW")) {
            case Some(v) => v != "0"
            case None => true
        }
    }

    private static func hasPmull(): Bool {
        // AT_HWCAP = 16；HWCAP_ASIMD = 1<<1，HWCAP_PMULL = 1<<4
        let cap = unsafe { getauxval(16) }
        ((cap & 2u64) != 0) && ((cap & 16u64) != 0)
    }
}
