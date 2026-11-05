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
package fountain::f_svg

private func buildCrc32Table(): Array<UInt32> {
    let table = Array<UInt32>(256, repeat: 0)
    for (index in 0..256) {
        var value = UInt32(index)
        for (_ in 0..8) {
            if ((value & 1) != 0) {
                value = (value >> 1) ^ UInt32(0xEDB88320)
            } else {
                value = value >> 1
            }
        }
        table[index] = value
    }
    table
}

private let SVG_CRC32_TABLE: Array<UInt32> = buildCrc32Table()

/** CRC-32（多项式 0xEDB88320）查表实现。 */
public class SvgCrc32 {
    public static func checksum(bytes: Array<Byte>): Int64 {
        Int64(updateState(UInt32(0xFFFFFFFF), bytes) ^ UInt32(0xFFFFFFFF))
    }

    /** 分块更新：`update(update(0, a), b)` 等于 `checksum(a + b)`。 */
    public static func update(previous: Int64, bytes: Array<Byte>): Int64 {
        let state = UInt32(previous) ^ UInt32(0xFFFFFFFF)
        Int64(updateState(state, bytes) ^ UInt32(0xFFFFFFFF))
    }

    private static func updateState(state: UInt32, bytes: Array<Byte>): UInt32 {
        var crc = state
        for (byte in bytes) {
            let index = Int64((crc ^ UInt32(byte)) & UInt32(0xFF))
            crc = (crc >> 8) ^ SVG_CRC32_TABLE[index]
        }
        crc
    }
}
