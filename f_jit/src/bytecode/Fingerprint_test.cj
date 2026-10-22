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

import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_jit.base.*
import fountain::f_base.*
import fountain::f_util.*

/**
 * S2.16 指纹接入的失败用例（先写红）。
 *
 * 权威 = design-m1 §3.3.8「指纹口径」与 design D8：
 *
 * | 指纹 | 算法 / 输入 | 用途 | 落盘 |
 * |---|---|---|---|
 * | 源码指纹 | FNV-1a-128（**换行规范化之后**的源码 UTF-8 字节） | `compile(source)` 去重键 | 不进 `.fbc` |
 * | 字节码指纹 | FNV-1a-128（**整份** raw：头 + 目录 + 类型表 + 四段） | `compile(unit)` 去重键 + JIT 缓存键 | 不进 `.fbc` |
 * | 常量指纹 | FNV-1a-64（常量表内容） | 缓存键辅助 / 诊断 | 落盘（§11.5） |
 *
 * **碰撞 = 语义错误** ⇒ 命中后做**长度 + 字节二次校验**（不符按 Miss 重编）。
 * 三者**互不混用**；实现一律经 `fountain::f_util` 的 FNV（`Fnv64` / `Fnv128`），
 * **禁止自实现哈希**（design D8）。
 */
@Test
public class Fingerprint_test {
    /** 64 位 FNV-1a 基准向量：空串 / `123456789`（与 S0.1 骨架、`Fnv_test` 同一组黄金值）。 */
    @TestCase
    public func fnv64GoldenVectors(): Unit {
        @Assert(Fnv64.fnv1a(''), 0xCBF29CE484222325u64)
        @Assert(Fnv64.fnv1a('123456789'), 0x06D5573923C6CDFCu64)
        // 本模块只经 f_util 取値，不自带实现：与直接调用逐位一致
        @Assert(Fingerprint.fnv1a64(''), 0xCBF29CE484222325u64)
        @Assert(Fingerprint.fnv1a64('123456789'), 0x06D5573923C6CDFCu64)
        @Assert(Fingerprint.fnv1a64('123456789'.unsafeBytes()), 0x06D5573923C6CDFCu64)
    }

    /** 128 位 FNV-1a 基准向量（空串：高位 `0x6C62272E07BB0142`、低位 `0x62B821756295C58D`）。 */
    @TestCase
    public func fnv128GoldenVectors(): Unit {
        let k = Fingerprint.fnv1a128('')
        @Assert(k.left, 0x6C62272E07BB0142u64)
        @Assert(k.right, 0x62B821756295C58Du64)
        // 与 f_util 直接调用一致
        @Assert(Fnv128.fnv1a('').left, k.left)
        @Assert(Fnv128.fnv1a('').right, k.right)
    }

    /** 常量指纹 = FNV-1a-64（常量段内容）：内容变则指纹变，内容同则指纹同。 */
    @TestCase
    public func constFingerprintTracksContent(): Unit {
        let a = ConstRegistry()
        a.addI64(1)
        a.freeze()
        let b = ConstRegistry()
        b.addI64(1)
        b.freeze()
        let c = ConstRegistry()
        c.addI64(2)
        c.freeze()
        @Assert(Fingerprint.constFingerprint(a), Fingerprint.constFingerprint(b))
        @Assert(Fingerprint.constFingerprint(a) != Fingerprint.constFingerprint(c), true)
        // 与对整段字节直接取 FNV-1a-64 一致（不是另一种摘要）
        @Assert(Fingerprint.constFingerprint(a), Fnv64.fnv1a(a.encode()))
    }

    /** 源码指纹：先做**换行规范化**（CRLF / CR → LF）再取 FNV-1a-128。 */
    @TestCase
    public func sourceKeyNormalizesNewlines(): Unit {
        let lf = 'a\nb'
        let crlf = 'a\r\nb'
        let cr = 'a\rb'
        @Assert(Fingerprint.sourceKey(lf), Fingerprint.sourceKey(crlf))
        @Assert(Fingerprint.sourceKey(lf), Fingerprint.sourceKey(cr))
        @Assert(Fingerprint.normalizeSource(crlf), lf)
        @Assert(Fingerprint.normalizeSource(cr), lf)
        @Assert(Fingerprint.sourceKey(lf) != Fingerprint.sourceKey('a\n\nb'), true)
    }

    /** 字节码指纹 = 整份 raw 的 FNV-1a-128（头 + 目录 + 类型表 + 四段全在内）。 */
    @TestCase
    public func bytecodeKeyCoversWholeRaw(): Unit {
        let raw = [0x46u8, 0x42u8, 0x43u8, 0x31u8, 0x01u8]
        @Assert(Fingerprint.bytecodeKey(raw), Fnv128.fnv1a(raw))
        // 头里改一个字节 ⇒ 指纹变（与 crc32 只覆盖四段形成对照）
        let raw2 = raw.clone()
        raw2[0] = 0x47u8
        @Assert(Fingerprint.bytecodeKey(raw) != Fingerprint.bytecodeKey(raw2), true)
    }

    /** 命中后**二次校验原字节**：等长但内容不同 ⇒ 判定不命中（碰撞不靠概率兜底）。 */
    @TestCase
    public func dedupGuardRejectsEqualLengthCollision(): Unit {
        let a = 'aaaa'
        let b = 'aaab'
        @Assert(a.size, b.size) // 等长
        let key = Fingerprint.sourceKey(a)
        let guard = DedupGuard(key, a.unsafeBytes())
        // 同指纹 + 同字节 ⇒ 命中
        @Assert(guard.matches(key, a.unsafeBytes()), true)
        // 人为构造「指纹命中但字节不同」（模拟碰撞）⇒ 二次校验判定不命中
        @Assert(guard.matches(key, b.unsafeBytes()), false)
        // 指纹不同 ⇒ 直接不命中
        @Assert(guard.matches(Fingerprint.sourceKey(b), b.unsafeBytes()), false)
        // 长度不同 ⇒ 不命中
        @Assert(guard.matches(key, 'aaa'.unsafeBytes()), false)
    }

    /** 三类摘要分工不混用：同一输入的 crc32 / FNV-1a-64 / FNV-1a-128 互不替代。 */
    @TestCase
    public func threeDigestsAreNotInterchangeable(): Unit {
        let src = 'let x = 1'
        let crc = Crc32.isoHdlc.compute(src.unsafeBytes())
        let f64 = Fingerprint.fnv1a64(src)
        let f128 = Fingerprint.fnv1a128(src)
        @Assert(UInt64(crc) != f64, true)
        @Assert(f128.left != f64, true)
        // crc32 只有 32 位，不得作为去重键（design D8「去重用 CRC-32：碰撞语义不可接受」）
        @Assert(crc <= 0xFFFFFFFFu32, true)
        @Assert(f128.left != f128.right, true)
    }
}
