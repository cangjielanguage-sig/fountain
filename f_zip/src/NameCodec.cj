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
package fountain::f_zip

import cangjie_tpc::charset4cj.charset.Charsets

/**
 * 文件名编码。
 *
 * **写入**：全 ASCII → 不置 bit 11、按 ASCII 字节写；否则置 bit 11、按 UTF-8 写。
 *
 * **读取**：bit 11 置位 → UTF-8；否则 UTF-8 严格解码 → GBK → Latin-1 逐字节映射。
 * 回退链固定写死，不引入编码检测库——ZIP 文件名通常只有几到几十字节，小样本上
 * 检测准确率低，误判（把 GBK 判成 UTF-8）就是全乱码。
 */
internal func isAsciiBytes(bytes: Array<Byte>): Bool {
    for (b in bytes) {
        if (b >= 0x80) {
            return false
        }
    }
    true
}

/**
 * 编码条目名。返回 `(名字字节, 是否置 bit 11)`。
 */
internal func encodeName(name: String): (Array<Byte>, Bool) {
    let bytes = name.toArray()
    if (isAsciiBytes(bytes)) {
        (bytes, false)
    } else {
        (bytes, true)
    }
}

/**
 * 按 bit 11 与固定回退链解码条目名。任何输入都能得到一个字符串，不抛异常。
 */
internal func decodeName(bytes: Array<Byte>, utf8Flag: Bool): String {
    if (utf8Flag) {
        return String.fromUtf8(bytes)
    }
    if (let Some(s) <- strictUtf8(bytes)) {
        return s
    }
    if (let Some(s) <- decodeGbk(bytes)) {
        return s
    }
    latin1(bytes)
}

/** GBK 严格解码；失败（含非法序列）返回 `None`。 */
internal func decodeGbk(bytes: Array<Byte>): ?String {
    if (bytes.size == 0) {
        return Some("")
    }
    try {
        Some(Charsets.GBK.newDecoder().decode(bytes))
    } catch (_: Exception) {
        None<String>
    }
}

/** Latin-1：每个字节直接映射到同码位的 Rune，保证不抛异常。 */
internal func latin1(bytes: Array<Byte>): String {
    // 逐字节映射，ASCII 之外不会产生多字节序列，所以直接构造字符串是安全的。
    let runes = Array<Rune>(bytes.size, repeat: r'\0')
    for (i in 0..bytes.size) {
        runes[i] = Rune(UInt32(bytes[i]))
    }
    String(runes)
}

/**
 * UTF-8 严格校验 + 解码：拒绝过长编码、代理区与超出 U+10FFFF 的码位。
 *
 * 不用 `charset4cj` 的 UTF-8 解码器，因为它遇到非法序列会替换成 U+FFFD 而不报错，
 * 那样"回退到 GBK"这一步永远不会触发。
 */
internal func strictUtf8(bytes: Array<Byte>): ?String {
    var i = 0
    let n = bytes.size
    while (i < n) {
        let b0 = Int64(bytes[i])
        if (b0 < 0x80) {
            i += 1
            continue
        }
        let need = if (b0 >= 0xC2 && b0 <= 0xDF) {
            1
        } else if (b0 >= 0xE0 && b0 <= 0xEF) {
            2
        } else if (b0 >= 0xF0 && b0 <= 0xF4) {
            3
        } else {
            return None<String>
        }
        if (i + need >= n) {
            return None<String>
        }
        var cp = b0 & (0x3F >> need)
        for (j in 1..(need + 1)) {
            let bj = Int64(bytes[i + j])
            if (bj < 0x80 || bj > 0xBF) {
                return None<String>
            }
            cp = (cp << 6) | (bj & 0x3F)
        }
        let minCp = if (need == 1) {
            0x80
        } else if (need == 2) {
            0x800
        } else {
            0x10000
        }
        if (cp < minCp || cp > 0x10FFFF || (cp >= 0xD800 && cp <= 0xDFFF)) {
            return None<String>
        }
        i += need + 1
    }
    Some(String.fromUtf8(bytes))
}
