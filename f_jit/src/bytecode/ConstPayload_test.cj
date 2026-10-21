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

/**
 * S2.7 `ConstKind` / `ConstPayload` 与 S2.8 `ConstRegistry` 拼装 API 的失败用例（先写红）。
 *
 * 权威 = `doc/jit-bytecode-m1.md` §11.5「常量表序列化（与句柄解耦）」：
 *
 * ```
 * ConstTable { version: u16, count: u32, entries: [Entry] }
 * Entry = (kind: u8, payload)
 *   kind 1 = Int64  i64        kind 6 = Decimal  u8 sign + i32 scale + u32 长度 + 系数字节串
 *   kind 2 = Float64 8B        kind 7 = DateTime i64 epochNanos
 *   kind 3 = String u32+UTF-8  kind 8 = Duration i64 nanos
 *   kind 4 = List u32 + u32[]  kind 9 = Range    i64 start + i64 end + i64 step + u8 isClosed
 *   kind 5 = Map  u32 + u32[]  kind 10 = Regex   u8 flags + u16 长度 + pattern 字节
 * ```
 *
 * 常量表必须是 **DAG**（允许共享子结构，禁止环），加载器做环检测；序列化**只有值、没有句柄 ID**。
 */
@Test
public class ConstPayload_test {
    /** kind 码 1–10 与 §11.5 逐值一致（M3 追加 11=Json，本步不登记）。 */
    @TestCase
    public func kindCodesMatchSpec(): Unit {
        @Assert(ConstKind.I64, 1u8)
        @Assert(ConstKind.F64, 2u8)
        @Assert(ConstKind.STRING, 3u8)
        @Assert(ConstKind.LIST, 4u8)
        @Assert(ConstKind.MAP, 5u8)
        @Assert(ConstKind.DECIMAL, 6u8)
        @Assert(ConstKind.DATETIME, 7u8)
        @Assert(ConstKind.DURATION, 8u8)
        @Assert(ConstKind.RANGE, 9u8)
        @Assert(ConstKind.REGEX, 10u8)
    }

    /** `ConstPayload` 十个构造器与 kind 一一对应，`match` 分派可取回载荷。 */
    @TestCase
    public func payloadKindsRoundTrip(): Unit {
        let all = [
            ConstPayload.PI64(-12345),
            ConstPayload.PF64(0x7FF8000000000000u64),
            ConstPayload.PStr('你好'),
            ConstPayload.PList([0u32, 1u32]),
            ConstPayload.PMap([(0u32, 1u32)]),
            ConstPayload.PDec(1u8, 2i32, '123'),
            ConstPayload.PDateTime(1700000000000000000),
            ConstPayload.PDuration(-5),
            ConstPayload.PRange(0, 10, 2, true),
            ConstPayload.PRegex('a+', 0u8)
        ]
        @Assert(all.size, 10)
        let kinds = [1u8, 2u8, 3u8, 4u8, 5u8, 6u8, 7u8, 8u8, 9u8, 10u8]
        for (i in 0..10) {
            @Assert(ConstPayload.kindOf(all[i]), kinds[i])
        }
        // 逐构造器的字段读回
        match (all[0]) {
            case PI64(v) => @Assert(v, -12345)
            case _ => @Assert(0, 1)
        }
        match (all[3]) {
            case PList(xs) =>
                @Assert(xs.size, 2)
                @Assert(xs[1], 1u32)
            case _ => @Assert(0, 1)
        }
        match (all[5]) {
            case PDec(sign, scale, coeff) =>
                @Assert(sign, 1u8)
                @Assert(scale, 2i32)
                @Assert(coeff, '123')
            case _ => @Assert(0, 1)
        }
        match (all[8]) {
            case PRange(start, end, step, closed) =>
                @Assert(start, 0)
                @Assert(end, 10)
                @Assert(step, 2)
                @Assert(closed, true)
            case _ => @Assert(0, 1)
        }
        match (all[9]) {
            case PRegex(pattern, flags) =>
                @Assert(pattern, 'a+')
                @Assert(flags, 0u8)
            case _ => @Assert(0, 1)
        }
    }

    /** 各 `add` 返回**递增** hid；`get(i)` 载荷保真。 */
    @TestCase
    public func addReturnsIncreasingHid(): Unit {
        let reg = ConstRegistry()
        @Assert(reg.size, 0)
        let h0 = reg.addI64(7)
        let h1 = reg.addStr('abc')
        let h2 = reg.addRange(0, 5, 1, false)
        let h3 = reg.addF64(0x400921FB54442D18u64)
        @Assert(h0, 0)
        @Assert(h1, 1)
        @Assert(h2, 2)
        @Assert(h3, 3)
        @Assert(reg.size, 4)
        match (reg.get(1)) {
            case PStr(s) => @Assert(s, 'abc')
            case _ => @Assert(0, 1)
        }
        match (reg.get(3)) {
            case PF64(bits) => @Assert(bits, 0x400921FB54442D18u64)
            case _ => @Assert(0, 1)
        }
    }

    /** DAG：`addList` / `addMap` 引用**已登记**子常量的索引（共享子结构）。 */
    @TestCase
    public func listAndMapReferenceChildIndices(): Unit {
        let reg = ConstRegistry()
        let a = UInt32(reg.addI64(1))
        let b = UInt32(reg.addI64(2))
        let lst = reg.addList([a, b])
        @Assert(lst, 2)
        match (reg.get(lst)) {
            case PList(xs) =>
                @Assert(xs.size, 2)
                @Assert(xs[0], a)
                @Assert(xs[1], b)
            case _ => @Assert(0, 1)
        }
        let mp = reg.addMap([(a, b)])
        @Assert(mp, 3)
        match (reg.get(mp)) {
            case PMap(ps) =>
                @Assert(ps.size, 1)
                @Assert(ps[0][0], a)
                @Assert(ps[0][1], b)
            case _ => @Assert(0, 1)
        }
    }

    /** `addRegex` 去重且 flags 归一：`im` ≡ `mi` ≡ `ii` 同键；非法 flags 字符 ⇒ 14。 */
    @TestCase
    public func addRegexDeduplicatesAndNormalizesFlags(): Unit {
        let reg = ConstRegistry()
        let h0 = reg.addRegex('a+', 'im') // bit0|bit1
        let h1 = reg.addRegex('a+', 'mi') // 顺序无关 ⇒ 同键
        let h2 = reg.addRegex('a+', 'ii') // 重复幂等 ⇒ 与 'i' 同键（≠ 'im'）
        let h2b = reg.addRegex('a+', 'i')
        let h3 = reg.addRegex('a+', '') // 无 flags
        let h4 = reg.addRegex('b+', 'im') // 同 flags 不同 pattern
        @Assert(h0, h1)
        @Assert(h2, h2b)
        @Assert(h0, 0)
        @Assert(h2, 1)
        @Assert(h3, 2)
        @Assert(h4, 3)
        @Assert(reg.size, 4)

        // 位域形态与字符形态等价（bit0=i bit1=m bit2=u）
        @Assert(reg.addRegex('a+', 3u8), h0)

        var rejected = 0
        try {
            reg.addRegex('a+', 'x')
        } catch (ex: JitException) {
            @Assert(ex.code, ErrCode.ARG_MISMATCH)
            rejected = rejected + 1
        }
        try {
            reg.addRegex('a+', 'iz')
        } catch (ex: JitException) {
            rejected = rejected + 1
        }
        @Assert(rejected, 2)
    }

    /** `freeze` 后写操作拒绝、读取仍保真（§3.3「冻结（之后只读；`PUSH_KH` 校验依赖）」）。 */
    @TestCase
    public func freezeMakesRegistryReadOnly(): Unit {
        let reg = ConstRegistry()
        reg.addStr('x')
        @Assert(reg.isFrozen, false)
        reg.freeze()
        @Assert(reg.isFrozen, true)
        match (reg.get(0)) {
            case PStr(s) => @Assert(s, 'x')
            case _ => @Assert(0, 1)
        }
        var rejected = 0
        try {
            reg.addStr('y')
        } catch (ex: JitException) {
            rejected = rejected + 1
        }
        try {
            reg.addI64(1)
        } catch (ex: JitException) {
            rejected = rejected + 1
        }
        try {
            reg.addRegex('z', '')
        } catch (ex: JitException) {
            rejected = rejected + 1
        }
        @Assert(rejected, 3)
        @Assert(reg.size, 1)
    }

    /** 常量段编解码往返：DAG 子索引、各 kind 载荷逐字节保真。 */
    @TestCase
    public func constSectionRoundTrips(): Unit {
        let reg = ConstRegistry()
        reg.addI64(-1)
        reg.addF64(0x7FF8000000000000u64)
        reg.addStr('héllo')
        reg.addDecimal(1u8, 3i32, '250') // -0.250
        reg.addDateTime(1700000000000000000)
        reg.addDuration(-9)
        reg.addRange(1, 9, 3, true)
        reg.addRegex('[a-z]+', 'iu')
        reg.addList([0u32, 2u32])
        let bytes = reg.encode()
        @Assert(bytes.size > 0, true)

        let back = ConstRegistry.decode(bytes)
        @Assert(back.size, reg.size)
        @Assert(back.isFrozen, true)
        for (i in 0..reg.size) {
            @Assert(ConstPayload.kindOf(back.get(i)), ConstPayload.kindOf(reg.get(i)))
        }
        match (back.get(2)) {
            case PStr(s) => @Assert(s, 'héllo')
            case _ => @Assert(0, 1)
        }
        match (back.get(8)) {
            case PList(xs) =>
                @Assert(xs.size, 2)
                @Assert(xs[0], 0u32)
                @Assert(xs[1], 2u32)
            case _ => @Assert(0, 1)
        }
    }

    /** 常量图成环 ⇒ 加载期拒绝（§11.5「必须是 DAG（允许共享子结构，禁止环）」）。 */
    @TestCase
    public func cyclicConstGraphIsRejected(): Unit {
        // 手工构造：entry0 = List，元素指向自身（索引 0）
        let w = ByteWriter()
        w.wU16(ConstRegistry.CONST_VERSION)
        w.wU32(1u32)
        w.wU8(ConstKind.LIST)
        w.wU32(1u32)
        w.wU32(0u32) // 自引用
        var rejected = false
        try {
            ConstRegistry.decode(w.take())
        } catch (ex: JitException) {
            @Assert(ex.code, ErrCode.NOT_IMPL)
            rejected = true
        }
        @Assert(rejected, true)

        // 前向引用（索引 >= 自身）同样拒绝：DAG 只允许引用已登记项
        let w2 = ByteWriter()
        w2.wU16(ConstRegistry.CONST_VERSION)
        w2.wU32(2u32)
        w2.wU8(ConstKind.LIST)
        w2.wU32(1u32)
        w2.wU32(1u32) // 指向后一项
        w2.wU8(ConstKind.I64)
        w2.wI64(1)
        var rejected2 = false
        try {
            ConstRegistry.decode(w2.take())
        } catch (ex: JitException) {
            rejected2 = true
        }
        @Assert(rejected2, true)
    }

    /** 坏载荷：非法 kind ⇒ 拒绝；非 canonical Float64 ⇒ 拒绝（§11.3「加载器校验，非 canonical → 拒绝」）。 */
    @TestCase
    public func badPayloadIsRejected(): Unit {
        // 非法 kind 0
        var r1 = false
        let w1 = ByteWriter()
        w1.wU16(ConstRegistry.CONST_VERSION)
        w1.wU32(1u32)
        w1.wU8(0u8)
        try {
            ConstRegistry.decode(w1.take())
        } catch (ex: JitException) {
            @Assert(ex.code, ErrCode.NOT_IMPL)
            r1 = true
        }
        @Assert(r1, true)

        // 非法 kind 11（M3 才登记）
        var r2 = false
        let w2 = ByteWriter()
        w2.wU16(ConstRegistry.CONST_VERSION)
        w2.wU32(1u32)
        w2.wU8(11u8)
        try {
            ConstRegistry.decode(w2.take())
        } catch (ex: JitException) {
            r2 = true
        }
        @Assert(r2, true)

        // 非 canonical NaN（payload 非零）
        var r3 = false
        let w3 = ByteWriter()
        w3.wU16(ConstRegistry.CONST_VERSION)
        w3.wU32(1u32)
        w3.wU8(ConstKind.F64)
        w3.wU64(0x7FF8000000000001u64)
        try {
            ConstRegistry.decode(w3.take())
        } catch (ex: JitException) {
            r3 = true
        }
        @Assert(r3, true)

        // 对照组：canonical NaN 合法
        let w4 = ByteWriter()
        w4.wU16(ConstRegistry.CONST_VERSION)
        w4.wU32(1u32)
        w4.wU8(ConstKind.F64)
        w4.wU64(0x7FF8000000000000u64)
        @Assert(ConstRegistry.decode(w4.take()).size, 1)
    }

    /** Decimal 系数必须是 ASCII '0'–'9'（§11.5 kind 6「与 §11.4 表示一致」）。 */
    @TestCase
    public func nonDigitDecimalCoefficientIsRejected(): Unit {
        let w = ByteWriter()
        w.wU16(ConstRegistry.CONST_VERSION)
        w.wU32(1u32)
        w.wU8(ConstKind.DECIMAL)
        w.wU8(0u8)
        w.wI32(0i32)
        w.wU32(3u32)
        w.wBytes([0x31u8, 0x32u8, 0x61u8]) // "12a"
        var rejected = false
        try {
            ConstRegistry.decode(w.take())
        } catch (ex: JitException) {
            rejected = true
        }
        @Assert(rejected, true)
    }
}
