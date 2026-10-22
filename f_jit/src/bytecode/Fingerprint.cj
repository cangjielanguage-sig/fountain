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
package fountain::f_jit.bytecode

import fountain::f_base.*
import fountain::f_util.Fnv128
import fountain::f_util.Fnv64
import fountain::f_util.UInt128

/**
 * 指纹原语（常量指纹 / 源码去重键 / 字节码去重键）—— design-m1 §3.3.8「指纹口径」、
 * design D8、plan-m1 S2.16。
 *
 * | 指纹 | 算法 / 输入 | 用途 | 落盘 |
 * |---|---|---|---|
 * | 源码指纹 | **FNV-1a-128**（**换行规范化之后**的源码 UTF-8 字节） | `compile(source)` 去重键 | 不进 `.fbc` |
 * | 字节码指纹 | **FNV-1a-128**（**整份** raw：头 + 目录 + 类型表 + 四段） | `compile(unit)` 去重键 + JIT 缓存键 | 不进 `.fbc` |
 * | 常量指纹 | **FNV-1a-64**（常量表内容） | 缓存键辅助 / 诊断 | **落盘**（§11.5） |
 *
 * **三者互不混用**；`.fbc` 四段校验和另用 CRC-32/ISO-HDLC（只覆盖 code+const+site+name，
 * 仅 32 位，**不得**当去重键——design D8「去重用 CRC-32：碰撞语义不可接受」）。
 *
 * **实现一律经 `fountain::f_util`**（`Fnv64` / `Fnv128`）：本文件**不自实现哈希**，只负责
 * 口径（输入字节的选取）与「命中后二次校验」。
 */
public class Fingerprint {
    /** FNV-1a-64（经 `f_util.Fnv64`）；常量指纹用（§11.5 `constFingerprint: u64`）。 */
    public static func fnv1a64(data: String): UInt64 {
        Fnv64.fnv1a(data)
    }

    /** FNV-1a-64（`Array<Byte>` 重载）。 */
    public static func fnv1a64(data: Array<UInt8>): UInt64 {
        Fnv64.fnv1a(data)
    }

    /** FNV-1a-128（经 `f_util.Fnv128`）；源码 / 字节码去重键用。 */
    public static func fnv1a128(data: String): UInt128 {
        Fnv128.fnv1a(data)
    }

    /** FNV-1a-128（`Array<Byte>` 重载）。 */
    public static func fnv1a128(data: Array<UInt8>): UInt128 {
        Fnv128.fnv1a(data)
    }

    /**
     * 常量指纹：**FNV-1a-64**（§11.5「每份 `.fbc` 附 `constFingerprint: u64`（FNV-1a-64）」）。
     *
     * 输入 = `ConstRegistry.encode()` 的整段字节（值与结构都在内，句柄 ID 不在内——§11.5
     * 「序列化中只有值，没有句柄 ID」）。
     */
    public static func constFingerprint(reg: ConstRegistry): UInt64 {
        Fnv64.fnv1a(reg.encode())
    }

    /**
     * 源码去重键：**FNV-1a-128**，输入是**换行规范化之后**的源码 UTF-8 字节（§12.6）。
     */
    public static func sourceKey(src: String): UInt128 {
        Fnv128.fnv1a(normalizeSource(src).unsafeBytes())
    }

    /**
     * 字节码去重键：**FNV-1a-128**，输入是**整份** raw `.fbc`
     * （头 + 目录 + 类型表 + 四段，§12.6）。
     */
    public static func bytecodeKey(raw: Array<UInt8>): UInt128 {
        Fnv128.fnv1a(raw)
    }

    /**
     * 源码换行规范化：**CRLF / CR → LF**（§8.8「换行规范化（CRLF/CR → `\n`）」）。
     *
     * 逐**字节**处理：不依赖字符边界，也不改动其它字节。
     */
    public static func normalizeSource(src: String): String {
        let bs = src.unsafeBytes()
        let out = ArrayList<UInt8>()
        var i = 0
        while (i < bs.size) {
            let b = bs[i]
            if (b == 0x0Du8) {
                // CR：若紧随 LF 则一并折叠为一个 LF
                if (i + 1 < bs.size && bs[i + 1] == 0x0Au8) {
                    i = i + 1
                }
                out.add(0x0Au8)
            } else {
                out.add(b)
            }
            i = i + 1
        }
        String.fromUtf8(out.toArray())
    }
}

/**
 * 去重条目的「命中 + 二次校验」守卫 —— design D8 / §12.6。
 *
 * > **碰撞 = 语义错误**（去重键撞车 ⇒ 返回**别的** `JitFunction`）⇒ 缓存条目**保存原始输入
 * > 字节**，命中后做**长度 + 字节二次校验**（不符按 Miss 重编）。
 *
 * 因此「命中」的定义是**双条件**：指纹相等 **且** 原字节逐字节相同。
 */
public class DedupGuard {
    private let key: UInt128
    private let bytes: Array<UInt8>

    public init(key: UInt128, bytes: Array<UInt8>) {
        this.key = key
        this.bytes = bytes
    }

    /** 指纹（用于第一次筛选）。 */
    public prop fingerprint: UInt128 {
        get() {
            this.key
        }
    }

    /** 原始输入字节（用于二次校验）。 */
    public prop rawBytes: Array<UInt8> {
        get() {
            this.bytes
        }
    }

    /**
     * 指纹相等 **且** 原字节逐字节相同 ⇒ 命中；否则按 Miss 处理。
     *
     * 长度不同或内容不同（含**等长但不同源**的碰撞）都判定为不命中——碰撞不靠概率兜底。
     */
    public func matches(key: UInt128, bytes: Array<UInt8>): Bool {
        if (key.left != this.key.left || key.right != this.key.right) {
            return false
        }
        if (bytes.size != this.bytes.size) {
            return false
        }
        for (i in 0..bytes.size) {
            if (bytes[i] != this.bytes[i]) {
                return false
            }
        }
        true
    }
}
