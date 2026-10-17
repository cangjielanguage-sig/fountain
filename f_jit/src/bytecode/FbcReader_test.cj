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
import std.collection.ArrayList
import std.math.numeric.Decimal
import std.time.DateTime
import fountain::f_jit.base.*
import fountain::f_base.*

/**
 * S2.13（正向）/ S2.14（11 类拒绝面）/ S2.15（加载期实例化）的失败用例（先写红）。
 *
 * 权威：
 *
 * - `doc/jit-bytecode-m1.md` §11.6（容器头、site/name 段）、§11.7（函数目录、局部类型表）、
 *   §11.5（常量段）、§13.3（版本演进约束）；
 * - design D11：**11 类非法情形集中在一个 `validate` 里**，**每条一条独立用例、互不掩盖**；
 * - §3.3 / §11.5：正则常量**加载期一次编译**，非法或空 pattern → **加载期 14**。
 *
 * 每类拒绝面都构造**只违反该条**的容器（其余全部合法），确保用例之间互不掩盖。
 */

// ---------------- 夹具（包内函数，供默认实参求值；测试文件不参与 `cjpm build`）----------------

/**
 * 最小合法 code 段：
 *
 * ```
 * @0  count = 1 (u32)
 * @4  FuncEntry(0, codeOff=31, codeLen=6, localTypesOff=30, 0, 1, 1, 0, 0)   26 B
 * @30 localTypes[0..1)                                                         1 B
 * @31 SET_SITE <imm>   5 B
 * @36 RET              1 B
 * ```
 */
internal func fixCode(siteImm: Int32, localType: UInt8): Array<UInt8> {
    let w = ByteWriter()
    w.wU32(1u32)
    FuncEntry(0u32, 31u32, 6u32, 30u32, 0u16, 1u16, 1u16, 0u16, 0u16).write(w)
    w.wU8(localType)
    w.wU8(0x03u8) // OP_SET_SITE
    w.wI32(siteImm)
    w.wU8(0x7Cu8) // OP_RET
    w.take()
}

internal func fixConsts(): Array<UInt8> {
    let reg = ConstRegistry()
    reg.addI64(1)
    reg.freeze()
    reg.encode()
}

internal func fixSite(off: UInt32): Array<UInt8> {
    let t = SiteTable()
    t.add(off, SourcePos(1, 1))
    t.freeze()
    t.encode()
}

internal func fixName(): Array<UInt8> {
    let t = NameTable()
    t.add(0u32, 0u32, 'x')
    t.freeze()
    t.encode()
}

/** 就地改写头的 magic / verMajor / verMinor（不影响 crc32 字段，也不动 payload）。 */
internal func fixHeader(raw: Array<UInt8>, verMajor: UInt16, verMinor: UInt16, magic: UInt32): Array<UInt8> {
    let out = raw.clone()
    out[0] = UInt8(magic & 0xFFu32)
    out[1] = UInt8((magic >> 8) & 0xFFu32)
    out[2] = UInt8((magic >> 16) & 0xFFu32)
    out[3] = UInt8((magic >> 24) & 0xFFu32)
    out[4] = UInt8(verMajor & 0xFFu16)
    out[5] = UInt8((verMajor >> 8) & 0xFFu16)
    out[6] = UInt8(verMinor & 0xFFu16)
    out[7] = UInt8((verMinor >> 8) & 0xFFu16)
    out
}

@Test
public class FbcReader_test {
    /**
     * 组装一份**全部合法**的 `.fbc`（crc32 由 `FbcWriter` 计算，口径与读方一致）。
     *
     * 各 `!` 形参都有默认値 ⇒ 每条拒绝面用例只需改写**一处**，保证「只违反该条、互不掩盖」。
     */
    public func buildUnit(
        siteImm!: Int32 = 31i32,
        localType!: UInt8 = 0u8,
        consts!: Array<UInt8> = fixConsts(),
        site!: Array<UInt8> = fixSite(31u32),
        name!: Array<UInt8> = fixName(),
        entryFn!: UInt32 = 0u32,
        flags!: UInt32 = FbcFlags.UTF8,
        verMajor!: UInt16 = Version.MAJOR,
        verMinor!: UInt16 = Version.MINOR,
        magic!: UInt32 = Version.MAGIC,
        code!: Array<UInt8> = Array<UInt8>()
    ): Array<UInt8> {
        // 未显式给出 code 段时按 `siteImm` / `localType` 现造一份（默认实参无法引用前序参数）
        let body = if (code.size == 0) {
            fixCode(siteImm, localType)
        } else {
            code
        }
        let w = FbcWriter()
        w.setEntryFn(entryFn)
        w.setFlags(flags)
        w.setCode(body)
        w.setConst(consts)
        w.setSite(site)
        w.setName(name)
        let raw = w.build()
        fixHeader(raw, verMajor, verMinor, magic)
    }

    // ---------------- S2.13 正向 ----------------

    /** 最小合法单元：全字段解出（header / code / consts / site / name / dir / types），`entryFn` 命中目录。 */
    @TestCase
    public func loadMinimalUnit(): Unit {
        let raw = buildUnit()
        let u = FbcReader.load(raw)
        @Assert(u.header.magic, Version.MAGIC)
        @Assert(u.header.verMajor, Version.MAJOR)
        @Assert(u.header.verMinor, Version.MINOR)
        @Assert(u.header.codeLen, UInt32(fixCode(31i32, 0u8).size))
        @Assert(u.header.entryFn, 0u32)
        @Assert(u.code.size, Int64(u.header.codeLen))
        @Assert(u.dir.size, 1)
        @Assert(u.dir.get(0u32).codeOff, 31u32)
        @Assert(u.types.size, 1)
        @Assert(u.types[0].size, 1)
        @Assert(u.consts.size, 1)
        @Assert(u.consts.isFrozen, true)
        @Assert(u.site.size, 1)
        @Assert(u.name.size, 1)
        // 站点查询：SET_SITE 立即数 31 命中条目
        match (u.site.lookup(31)) {
            case Some(p) =>
                @Assert(p.line, 1)
                @Assert(p.column, 1)
            case None => @Assert(0, 1)
        }
    }

    // ---------------- S2.14 拒绝面（11 类，每类一条） ----------------

    /** ① 魔数错 ⇒ 18。 */
    @TestCase
    public func rejectBadMagic(): Unit {
        let raw = buildUnit(magic: 0x32434246u32) // "FBC2"
        expectReject(raw, ErrCode.NOT_IMPL)
    }

    /** ② verMajor 2 / 3 ⇒ 18 语义；兼容矩阵给出「最小可接受 verMinor」信息。 */
    @TestCase
    public func rejectUnsupportedVerMajor(): Unit {
        expectReject(buildUnit(verMajor: 2u16, verMinor: 15u16), ErrCode.NOT_IMPL)
        expectReject(buildUnit(verMajor: 3u16, verMinor: 16u16), ErrCode.NOT_IMPL)
        // 兼容矩阵：本加载器只接受 verMajor 1，且 verMinor ≤ 自身版本
        @Assert(FbcReader.supportedMajor, Version.MAJOR)
        @Assert(FbcReader.maxSupportedMinor, Version.MINOR)
        @Assert(FbcReader.minVerMinorOf(1u16), 0u16)
        @Assert(FbcReader.minVerMinorOf(2u16), FbcReader.UNSUPPORTED_MINOR)
        @Assert(FbcReader.minVerMinorOf(3u16), FbcReader.UNSUPPORTED_MINOR)
        // verMinor 高于自身版本 ⇒ 同样拒绝（§11.6「加载器接受 ≤ 自身版本的 verMinor」）
        expectReject(buildUnit(verMinor: 99u16), ErrCode.NOT_IMPL)
    }

    /** ③ 未知 flags 位 ⇒ 18；`bit1`（要求 JIT）= 1 ⇒ 18（§11.6 冻结决策）。 */
    @TestCase
    public func rejectUnknownFlagsAndNeedJit(): Unit {
        expectReject(buildUnit(flags: FbcFlags.UTF8 | 0x10u32), ErrCode.NOT_IMPL) // 未知 bit4
        expectReject(buildUnit(flags: FbcFlags.UTF8 | FbcFlags.NEED_JIT), ErrCode.NOT_IMPL)
        // 对照：bit2（值运算类）合法
        let ok = buildUnit(flags: FbcFlags.UTF8 | FbcFlags.VALUE_OPS)
        @Assert(FbcReader.load(ok).header.flags, FbcFlags.UTF8 | FbcFlags.VALUE_OPS)
    }

    /** ④ 段长不符（payload 长度 ≠ 四段之和）⇒ 18。 */
    @TestCase
    public func rejectSegmentLengthMismatch(): Unit {
        let raw = buildUnit()
        // 截断 1 字节 ⇒ payload 比头声明的短
        let short = Array<UInt8>(raw.size - 1, repeat: 0u8)
        for (i in 0..raw.size - 1) {
            short[i] = raw[i]
        }
        expectReject(short, ErrCode.NOT_IMPL)
        // 追加 1 字节 ⇒ 比声明长
        let long = Array<UInt8>(raw.size + 1, repeat: 0u8)
        for (i in 0..raw.size) {
            long[i] = raw[i]
        }
        expectReject(long, ErrCode.NOT_IMPL)
    }

    /** ⑤ 常量 DAG 成环 ⇒ 18（§11.5「必须是 DAG」）。 */
    @TestCase
    public func rejectConstCycle(): Unit {
        let w = ByteWriter()
        w.wU16(ConstRegistry.CONST_VERSION)
        w.wU32(2u32)
        w.wU8(ConstKind.LIST)
        w.wU32(1u32)
        w.wU32(1u32) // 引用后一项（前向引用 ⇒ 环 / 非法 DAG）
        w.wU8(ConstKind.LIST)
        w.wU32(1u32)
        w.wU32(1u32) // 自引用
        expectReject(buildUnit(consts: w.take()), ErrCode.NOT_IMPL)
    }

    /** ⑥ 坏载荷：非 canonical Float64 ⇒ 18（§11.3「加载器校验，非 canonical → 拒绝」）。 */
    @TestCase
    public func rejectNonCanonicalFloatPayload(): Unit {
        let w = ByteWriter()
        w.wU16(ConstRegistry.CONST_VERSION)
        w.wU32(1u32)
        w.wU8(ConstKind.F64)
        w.wU64(0x7FF8000000000001u64)
        expectReject(buildUnit(consts: w.take()), ErrCode.NOT_IMPL)
        // 对照：canonical NaN 合法
        let w2 = ByteWriter()
        w2.wU16(ConstRegistry.CONST_VERSION)
        w2.wU32(1u32)
        w2.wU8(ConstKind.F64)
        w2.wU64(0x7FF8000000000000u64)
        @Assert(FbcReader.load(buildUnit(consts: w2.take())).consts.size, 1)
    }

    /** ⑦ 目录越界（`codeOff + codeLen` 超出 code 段）⇒ 18。 */
    @TestCase
    public func rejectDirOutOfRange(): Unit {
        let w = ByteWriter()
        w.wU32(1u32)
        FuncEntry(0u32, 31u32, 999u32, 30u32, 0u16, 1u16, 1u16, 0u16, 0u16).write(w)
        w.wU8(0u8)
        w.wU8(0x03u8)
        w.wI32(31i32)
        w.wU8(0x7Cu8)
        expectReject(buildUnit(code: w.take()), ErrCode.NOT_IMPL)

        // 入口函数号不在目录中 ⇒ 同样拒绝
        expectReject(buildUnit(entryFn: 42u32), ErrCode.NOT_IMPL)
    }

    /** ⑧ 类型表非法（v1 遇类型码 13）⇒ 18（§11.7「13–255 保留（加载器拒绝）」）。 */
    @TestCase
    public func rejectIllegalLocalType(): Unit {
        expectReject(buildUnit(localType: 13u8), ErrCode.NOT_IMPL)
        // 对照：0–12 合法
        @Assert(FbcReader.load(buildUnit(localType: 12u8)).types[0].get(0), 12u8)
    }

    /** ⑨ site 未覆盖（`SET_SITE` 立即数无对应条目）/ 乱序 ⇒ 18。 */
    @TestCase
    public func rejectSiteUncoveredOrUnordered(): Unit {
        // 未覆盖：SET_SITE 立即数 99，站点表只有 off=31
        expectReject(buildUnit(siteImm: 99i32), ErrCode.NOT_IMPL)
        // 乱序：两条条目 off 递减
        let w = ByteWriter()
        w.wU32(2u32)
        w.wU32(20u32)
        w.wU32(1u32)
        w.wU32(1u32)
        w.wU32(10u32)
        w.wU32(2u32)
        w.wU32(1u32)
        expectReject(buildUnit(site: w.take()), ErrCode.NOT_IMPL)
    }

    /** ⑩ name 坏键（`slot ≥ nLocals`）⇒ 18（§11.6「slot < 该函数 nLocals」）。 */
    @TestCase
    public func rejectBadNameKey(): Unit {
        // 手工构造 slot=5（该函数 nLocals = 1）
        let w = ByteWriter()
        w.wU32(1u32)
        w.wU32(0u32)
        w.wU32(5u32)
        w.wU32(0u32)
        w.wU32(1u32)
        w.wBytes([0x78u8])
        expectReject(buildUnit(name: w.take()), ErrCode.NOT_IMPL)
    }

    /** ⑪ crc32 不符 ⇒ 18（§11.6「覆盖 code+const+site+name」）。 */
    @TestCase
    public func rejectCrc32Mismatch(): Unit {
        let raw = buildUnit()
        let out = raw.clone()
        // 只改头里的 crc32 字段（@36），四段字节不动 ⇒ 唯一的违规点就是校验和
        out[36] = out[36] ^ 0xFFu8
        expectReject(out, ErrCode.NOT_IMPL)
        // 改一段 payload 的一个字节而不重算 crc32 ⇒ 同样被校验和拦下
        let out2 = raw.clone()
        out2[40] = out2[40] ^ 0xFFu8 // code 段首字节
        expectReject(out2, ErrCode.NOT_IMPL)
    }

    // ---------------- S2.15 加载期实例化 ----------------

    /** kind 3–9 实例化：对象等值（String / Decimal / DateTime / Duration / Range）。 */
    @TestCase
    public func instantiateValueKinds(): Unit {
        let reg = ConstRegistry()
        reg.addStr('hi')
        reg.addDecimal(1u8, 3i32, '250') // -0.250
        reg.addDateTime(1_000_000_000_000_000_000)
        reg.addDuration(-5)
        reg.addRange(0, 10, 2, true)
        reg.freeze()
        reg.instantiateAll()

        match (reg.instanceAt(0)) {
            case s: String => @Assert(s, 'hi')
            case _ => @Assert(0, 1)
        }
        match (reg.instanceAt(1)) {
            case d: Decimal => @Assert(d.toString(), '-0.250')
            case _ => @Assert(0, 1)
        }
        match (reg.instanceAt(2)) {
            case t: DateTime => @Assert(t.toUnixTimeStamp().toNanoseconds(), 1_000_000_000_000_000_000)
            case _ => @Assert(0, 1)
        }
        match (reg.instanceAt(3)) {
            case d: Duration => @Assert(d.toNanoseconds(), -5)
            case _ => @Assert(0, 1)
        }
        match (reg.instanceAt(4)) {
            case r: Range<Int64> =>
                @Assert(r.start, 0)
                @Assert(r.end, 10)
                @Assert(r.step, 2)
            case _ => @Assert(0, 1)
        }
    }

    /** DAG 共享子结构**同一对象**：经一侧改到的可变子结构，另一侧立刻可见。 */
    @TestCase
    public func instantiateSharesDagSubstructures(): Unit {
        let reg = ConstRegistry()
        reg.addList([]) // 0：空 List
        reg.addList([0u32, 0u32]) // 1：两次引用同一子结构
        reg.freeze()
        reg.instantiateAll()

        // 通过父表的第 0 个元素改动共享子结构，第 1 个元素必须同步可见 ⇒ 同一对象
        match (reg.instanceAt(1)) {
            case parent: ArrayList<Any> =>
                @Assert(parent.size, 2)
                match (parent[0]) {
                    case child0: ArrayList<Any> =>
                        @Assert(child0.size, 0)
                        child0.add(42)
                        match (parent[1]) {
                            case child1: ArrayList<Any> => @Assert(child1.size, 1)
                            case _ => @Assert(0, 1)
                        }
                    case _ => @Assert(0, 1)
                }
            case _ => @Assert(0, 1)
        }
    }

    /** kind 10：合法 pattern **只编译一次**（编译次数 == 常量条目数）；多处引用同 hid。 */
    @TestCase
    public func regexIsCompiledOnce(): Unit {
        ConstRegistry.regexCompileCount = 0
        let reg = ConstRegistry()
        let h0 = reg.addRegex('[a-z]+', 'i')
        let h1 = reg.addRegex('[a-z]+', 'i') // 去重 ⇒ 同一条目
        let h2 = reg.addRegex('\\d+', '')
        reg.freeze()
        reg.instantiateAll()
        @Assert(h0, h1)
        @Assert(h2, 1)
        @Assert(reg.size, 2)
        @Assert(ConstRegistry.regexCompileCount, 2) // == 常量条目数，不多不少
        // 再次取用不再编译
        let _ = reg.instanceAt(h0)
        @Assert(ConstRegistry.regexCompileCount, 2)
    }

    /** 非法 / 空 pattern ⇒ **加载期** 14（不推迟到执行期，§3.3）。 */
    @TestCase
    public func illegalRegexRejectedAtLoad(): Unit {
        // 非法 pattern
        let reg1 = ConstRegistry()
        reg1.addRegex('(', '')
        reg1.freeze()
        var r1 = 0
        try {
            reg1.instantiateAll()
        } catch (ex: JitException) {
            @Assert(ex.code, ErrCode.ARG_MISMATCH)
            r1 = 1
        }
        @Assert(r1, 1)

        // 空 pattern
        let reg2 = ConstRegistry()
        reg2.addRegex('', '')
        reg2.freeze()
        var r2 = 0
        try {
            reg2.instantiateAll()
        } catch (ex: JitException) {
            @Assert(ex.code, ErrCode.ARG_MISMATCH)
            r2 = 1
        }
        @Assert(r2, 1)

        // 经 `FbcReader.load` 的加载期路径同样以 14 拒绝（而非执行期）
        let w = ByteWriter()
        w.wU16(ConstRegistry.CONST_VERSION)
        w.wU32(1u32)
        w.wU8(ConstKind.REGEX)
        w.wU8(0u8)
        w.wU16(0u16) // 空 pattern
        var r3 = 0
        try {
            FbcReader.load(buildUnit(consts: w.take()))
        } catch (ex: JitException) {
            @Assert(ex.code, ErrCode.ARG_MISMATCH)
            r3 = 1
        }
        @Assert(r3, 1)
    }

    /** `PUSH_KH` 索引边界：`idx < size` 成立，越界 ⇒ 拒绝。 */
    @TestCase
    public func pushKhIndexBounds(): Unit {
        let u = FbcReader.load(buildUnit())
        @Assert(u.consts.size, 1)
        @Assert(u.consts.isFrozen, true)
        var rejected = false
        try {
            u.consts.get(1)
        } catch (ex: JitException) {
            rejected = true
        }
        @Assert(rejected, true)
    }

    // ---------------- 夹具工具 ----------------

    public func expectReject(raw: Array<UInt8>, code: Int64): Unit {
        var rejected = false
        try {
            FbcReader.load(raw)
        } catch (ex: JitException) {
            @Assert(ex.code, code)
            rejected = true
        }
        @Assert(rejected, true)
    }
}
