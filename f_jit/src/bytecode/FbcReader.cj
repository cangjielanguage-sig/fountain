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

import std.collection.ArrayList
import fountain::f_jit.base.Version
import fountain::f_util.Crc32

/** `SET_SITE` 的 opcode（§10.3）。 */
internal const OP_SET_SITE: UInt8 = 0x03u8


/**
 * `.fbc` 加载器 —— design-m1 §3.3.8、plan-m1 S2.13 / S2.14。
 *
 * 权威 = `doc/jit-bytecode-m1.md` §11.5（常量段）、§11.6（容器头 / site / name 段）、
 * §11.7（code 段、函数目录、局部类型表）、§13.3（版本演进约束）。
 *
 * **design D11**：11 类非法情形**集中在一个 `validate` 里**逐条拒绝，**每条一条独立用例、
 * 互不掩盖**：
 *
 * | # | 情形 | 码 |
 * |---|---|---|
 * | ① | 魔数错 | 18 |
 * | ② | 主版本不受支持（verMajor 2/3；verMinor 高于自身） | 18 |
 * | ③ | 未知 flags 位 / `bit1`（要求 JIT）= 1 | 18 |
 * | ④ | 段长不符（payload ≠ code+const+site+name） | 18 |
 * | ⑤ | 常量图成环 | 18 |
 * | ⑥ | 坏载荷（非 canonical F64 / 非法 kind / 非法 UTF-8 / 坏 Decimal 系数） | 18 |
 * | ⑦ | 目录越界（含 `entryFn` 不命中） | 18 |
 * | ⑧ | 类型表非法（按 verMajor 分派） | 18 |
 * | ⑨ | site 未覆盖（`SET_SITE` 无条目）/ 乱序 / 越界 / 行列 < 1 | 18 |
 * | ⑩ | name 坏键（`fnId` 不命中 / `slot ≥ nLocals` / 未升序 / 空名 / 越界 / 非 UTF-8） | 18 |
 * | ⑪ | crc32 不符 | 18 |
 *
 * 唯一的例外码是 **14**：正则常量非法 / 空 pattern（§3.3「加载期拒绝（`JitException(14)`，
 * site=-1）」）——它属于**常量语义**而非容器格式。
 */
public class FbcReader {
    /**
     * legacy 单版本字段：M1 的主版本（= 1）。
     *
     * M2 加载器已按 `verMajor` 分派 v1/v2 规则集；本字段保留供 M1 公开调用面零回归
     * （版本能力请读 `rulesFor` / `minVerMinorOf`）。
     */
    public static let supportedMajor: UInt16 = Version.MAJOR

    /** legacy 单版本字段：M1 的 `verMinor` 上限（= 14）；按主版本的上限见对应规则集。 */
    public static let maxSupportedMinor: UInt16 = Version.MINOR

    /**
     * 兼容矩阵哨兵：该主版本**没有**任何本加载器可接受的次版本（design D11「按兼容矩阵给出
     * 最小可接受 verMinor 信息」）。
     */
    public static let UNSUPPORTED_MINOR: UInt16 = 0xFFFFu16

    /**
     * 兼容矩阵：就给定 `verMajor`，本加载器所能接受的**最小** `verMinor`。
     *
     * - `1` ⇒ 0（v1 全系列，上限 `maxSupportedMinor`）；
     * - `2` ⇒ 0（M2 产物从 verMinor 0 起算，上限 0）；
     * - `3` ⇒ `UNSUPPORTED_MINOR`（M3 规则集仅登记，未实现语义）；
     * - 其余主版本 ⇒ `UNSUPPORTED_MINOR`。
     *
     * 拒绝信息里带上它，便于宿主判断「需要哪个版本的加载器」。
     */
    public static func minVerMinorOf(major: UInt16): UInt16 {
        match (FbcRuleRegistry.get(major)) {
            case Some(r) => if (r.implemented) {
                r.minVerMinor
            } else {
                UNSUPPORTED_MINOR
            }
            case None => UNSUPPORTED_MINOR
        }
    }

    /** 按主版本取加载规则集（v1/v2 已实现，v3 仅登记）；未登记返回 `None`。 */
    public static func rulesFor(major: UInt16): ?FbcRuleSet {
        FbcRuleRegistry.get(major)
    }

    /**
     * 加载一份 `.fbc`（正向全流程）。
     *
     * 顺序：`validate`（集中拒绝）→ 段解析 → 目录 / 类型表 / 常量 / site / name 校验 →
     * 常量**加载期实例化**（S2.15）。
     */
    public static func load(raw: Array<UInt8>): LoadedUnit {
        let header = FbcHeader.read(ByteReader(raw))
        let rules = requireRules(header.verMajor)
        validate(header, raw, rules)
        let off = header.payloadOff()
        let code = sliceOf(raw, off, Int64(header.codeLen))
        let constBytes = sliceOf(raw, off + Int64(header.codeLen), Int64(header.constLen))
        let siteBytes = sliceOf(raw, off + Int64(header.codeLen) + Int64(header.constLen), Int64(header.siteLen))
        let nameBytes = sliceOf(
            raw,
            off + Int64(header.codeLen) + Int64(header.constLen) + Int64(header.siteLen),
            Int64(header.nameLen))

        let dir = readDir(code, rules)
        dir.validate(header.codeLen, header.entryFn)
        checkInstructionSet(code, dir, rules)
        let types = readTypes(code, dir)
        for (i in 0..dir.size) {
            types[i].validate(dir, dir.at(i).fnId, rules)
        }

        let consts = ConstRegistry.decode(constBytes)
        consts.instantiateAll()

        let site = SiteTable.decode(siteBytes)
        site.validate(header.codeLen)
        checkSiteCoverage(code, dir, site)

        let name = if (header.isLegacyLayout()) {
            NameTable()
        } else {
            NameTable.decode(nameBytes)
        }
        if (!header.isLegacyLayout()) {
            name.validate(dir, types)
        }

        LoadedUnit(header, code, consts, site, name, dir, types, rules)
    }

    /**
     * **无注册表分发入口**（design-m2 §11 / m2 §12.4/§15/§16）：装载既有 `.fbc`，不接受宿主
     * 类注册表上下文。
     *
     * 依赖类注册表的单元（14 槽、成员访问/构造物化出的 user helper）在此**加载期拒绝**；
     * HostClosure（13）与 M3 JSON 内建码（16–19）零注册，不触发本拒绝面。
     */
    public static func loadWithoutRegistry(raw: Array<UInt8>): LoadedUnit {
        let unit = load(raw)
        if (unit.requiresClassRegistry()) {
            rejectFormat(
                '单元依赖宿主类注册表（14 槽或 user helper），无注册表分发入口拒绝（m2 §12.4/§15/§16）')
        }
        unit
    }

    /** 取主版本对应的规则集；未登记的主版本按 18 拒绝（规则集注册表为唯一分派点）。 */
    private static func requireRules(major: UInt16): FbcRuleSet {
        match (rulesFor(major)) {
            case Some(r) => r
            case None => rejectFormat(
                '不受支持的 verMajor=${major}（规则集注册表仅登记 v1/v2/v3；已实现 v1/v2）')
        }
    }

    /**
     * 加载期校验的**唯一入口**（design D11）：11 类非法情形集中在这里逐条拒绝。
     *
     * 每条检查都是**独立的**——一个只违反其中一条的容器一定走到该条并被拒绝，不会被前面的
     * 检查「顺带」拦下（这是「互不掩盖」的可测定义）。
     *
     * Q0.2 起校验规则按 `verMajor` 分派（design-m2 D12）：本重载按注册表取规则集，
     * 三参数重载允许测试/宿主显式指定规则集（例如以 M1 规则集验证 M1 加载器拒绝 v2 产物）。
     */
    public static func validate(h: FbcHeader, raw: Array<UInt8>): Unit {
        validate(h, raw, requireRules(h.verMajor))
    }

    public static func validate(h: FbcHeader, raw: Array<UInt8>, rules: FbcRuleSet): Unit {
        // ① 魔数
        if (h.magic != Version.MAGIC) {
            rejectFormat('容器魔数错: 0x${hexOf32(h.magic)}（应为 "FBC1" = 0x${hexOf32(Version.MAGIC)}）')
        }
        // ② 版本（按规则集分派：主版本一致、规则集已实现、verMinor 落在区间内）
        if (h.verMajor != rules.verMajor) {
            rejectFormat(
                '不受支持的 verMajor=${h.verMajor}（当前规则集 verMajor=${rules.verMajor}）')
        }
        if (!rules.implemented) {
            rejectFormat(
                '不受支持的 verMajor=${h.verMajor}（规则集仅登记合法集，未实现加载语义）')
        }
        if (!rules.isVerMinorSupported(h.verMinor)) {
            rejectFormat(
                'verMinor=${h.verMinor} 超出 verMajor=${h.verMajor} 的接受区间 [${rules.minVerMinor}, ${rules.maxVerMinor}]（§11.6）')
        }
        // ③ flags
        if ((h.flags | FbcFlags.KNOWN_MASK) != FbcFlags.KNOWN_MASK) {
            rejectFormat('容器 flags 含未知位: 0x${hexOf32(h.flags)}（已知位掩码 0x${hexOf32(FbcFlags.KNOWN_MASK)}）')
        }
        if ((h.flags & FbcFlags.NEED_JIT) != 0u32) {
            rejectFormat('flags.bit1（需要 JIT）= 1（§11.6 冻结决策：必须恒为 0）')
        }
        // 头长度与布局一致（新布局 36、旧布局 32）
        if (h.isLegacyLayout()) {
            if (h.hdrSize != FbcHeader.LEGACY_HDR_SIZE) {
                rejectFormat('旧布局头长度错: hdrSize=${h.hdrSize}（应为 ${FbcHeader.LEGACY_HDR_SIZE}）')
            }
        } else if (h.hdrSize != Version.HDR_SIZE) {
            rejectFormat('新布局头长度错: hdrSize=${h.hdrSize}（应为 ${Version.HDR_SIZE}）')
        }
        // ④ 段长不符
        let declared = Int64(h.codeLen) + Int64(h.constLen) + Int64(h.siteLen) + Int64(h.nameLen)
        let actual = raw.size - h.payloadOff()
        if (actual != declared) {
            rejectFormat('段长不符: 声明 ${declared} 字节，实际 ${actual} 字节（§11.6）')
        }
        // name 段在新布局下恒存在（段长 ≥ 4），旧布局由 isLegacyLayout 分支跳过
        if (!h.isLegacyLayout() && h.nameLen < 4u32) {
            rejectFormat('name 段长度非法: nameLen=${h.nameLen}（§11.6「≥ 4」）')
        }
        // ⑪ crc32（放在解段之前：格式完整性优先于语义解析）
        checkCrc32(h, raw)
    }

    /** ⑪ crc32 覆盖 code + const + site + name 四段（写方口径 = 读方口径，design D8）。 */
    private static func checkCrc32(h: FbcHeader, raw: Array<UInt8>): Unit {
        let off = h.payloadOff()
        let all = ArrayList<UInt8>()
        for (i in off..raw.size) {
            all.add(raw[i])
        }
        let actual = Crc32.isoHdlc.compute(all.toArray())
        if (actual != h.crc32) {
            rejectFormat('crc32 不符: 声明 0x${hexOf32(h.crc32)}, 实算 0x${hexOf32(actual)}（§11.6）')
        }
    }

    /** code 段头 = 函数目录（§11.7）；返回类型合法集按规则集判定。 */
    private static func readDir(code: Array<UInt8>, rules: FbcRuleSet): FuncDir {
        let r = ByteReader(code)
        let count = r.u32()
        if (Int64(count) * FuncEntry.SIZE > r.remaining()) {
            rejectFormat('函数目录条目数与字节数不符: count=${count}, 剩余=${r.remaining()}')
        }
        let dir = FuncDir()
        for (_ in 0..Int64(count)) {
            let e = FuncEntry.read(r)
            if (!rules.isLocalTypeLegal(e.retType)) {
                rejectFormat(
                    '非法返回类型: fnId=${e.fnId}, retType=${e.retType}（verMajor=${rules.verMajor} 合法集 0–${rules.maxLocalType}）')
            }
            dir.add(e)
        }
        dir
    }

    /**
     * 指令集合法性（design-m2 D12）：逐条扫描函数体，拒绝禁用/保留槽与版本不允许的指令。
     *
     * 版本差异唯一在 `CALL_HOST`：v1 规则集拒绝（M1 从不产出），v2 起合法（m2 §2）。
     * 扫描同时校验指令流严格止于 `codeOff + codeLen`（与 §11.6 的定长口径一致）。
     */
    private static func checkInstructionSet(code: Array<UInt8>, dir: FuncDir, rules: FbcRuleSet): Unit {
        for (i in 0..dir.size) {
            let e = dir.at(i)
            var p = Int64(e.codeOff)
            let end = Int64(e.codeOff) + Int64(e.codeLen)
            while (p < end) {
                let op = code[p]
                let info = OpInfo.OPCODE_TABLE[Int64(op)]
                if (info.cat == OpInfo.CAT_FORBID || info.cat == OpInfo.CAT_RSVD) {
                    rejectFormat(
                        '禁用/保留 opcode 0x${hex2(op)} @${p}（fnId=${e.fnId}，§10.1）')
                }
                if (!rules.isInstructionLegal(op)) {
                    rejectFormat(
                        'opcode 0x${hex2(op)} 在 verMajor=${rules.verMajor} 规则集下非法 @${p}（fnId=${e.fnId}，m2 §2）')
                }
                let insn = InsnDecoder.decode(code, p)
                p = p + insn.size
            }
            if (p != end) {
                rejectFormat('函数体指令流与 codeLen 不符: fnId=${e.fnId}, 结束于 ${p}, 声明 ${end}')
            }
        }
    }

    /** 每个函数一份局部类型表（`localTypesOff` 起 `nLocals` 字节，§11.7）。 */
    private static func readTypes(code: Array<UInt8>, dir: FuncDir): Array<LocalTypes> {        let out = ArrayList<LocalTypes>()
        for (i in 0..dir.size) {
            let e = dir.at(i)
            if (Int64(e.localTypesOff) + Int64(e.nLocals) > code.size) {
                rejectFormat('局部类型表越界: fnId=${e.fnId}, localTypesOff=${e.localTypesOff}, nLocals=${e.nLocals}')
            }
            let start = Int64(e.localTypesOff)
            let bs = Array<UInt8>(Int64(e.nLocals), repeat: 0u8)
            for (k in 0..Int64(e.nLocals)) {
                bs[k] = code[start + k]
            }
            out.add(LocalTypes.read(bs))
        }
        out.toArray()
    }

    /**
     * ⑨ 站点覆盖率：全部 `SET_SITE` 立即数必须命中站点条目（§11.6「条目集合必须覆盖全部
     * `SET_SITE` 位置」）。
     *
     * `ctx.site` 就是 `SET_SITE` 的立即数，且等于 code 段的绝对字节偏移（§9.16）⇒ 逐个函数
     * 线性扫描指令流（全部指令定长，§11.2）即可枚举。扫描中遇到 RSVD / FORBID 编码同样拒绝
     * （§10.1「发射即 `ERR_NOT_IMPL`」）。
     */
    private static func checkSiteCoverage(code: Array<UInt8>, dir: FuncDir, site: SiteTable): Unit {
        for (i in 0..dir.size) {
            let e = dir.at(i)
            var p = Int64(e.codeOff)
            let end = Int64(e.codeOff) + Int64(e.codeLen)
            while (p < end) {
                let insn = InsnDecoder.decode(code, p)
                if (insn.op == OP_SET_SITE) {
                    let key = InsnDecoder.i32(insn, 0)
                    if (!site.hasExact(Int64(key))) {
                        rejectFormat(
                            'site 未覆盖: SET_SITE 立即数 ${key}（@${p}, fnId=${e.fnId}）在站点表中无条目（§11.6）')
                    }
                }
                p = p + insn.size
            }
            if (p != end) {
                rejectFormat('函数体指令流与 codeLen 不符: fnId=${e.fnId}, 结束于 ${p}, 声明 ${end}')
            }
        }
    }
}

/** 加载产物（design-m1 §3.3.8）：runtime / backend / 桥共用。 */
public class LoadedUnit {
    public let header: FbcHeader
    /** code 段（函数目录 + 局部类型表 + 各函数体，§11.7）。 */
    public let code: Array<UInt8>
    /** 常量表（已冻结并**加载期实例化**，§11.5 / S2.15）。 */
    public let consts: ConstRegistry
    /** 站点表（偏移 → 源位置，§11.6）。 */
    public let site: SiteTable
    /** 变量名表（稀疏，§11.6 / §11.7）。 */
    public let name: NameTable
    /** 函数目录（§11.7）。 */
    public let dir: FuncDir
    /** 每个函数一份局部类型表，顺序与 `dir` 一致（§11.7）。 */
    public let types: Array<LocalTypes>
    /** 本次加载实际取用的校验规则集（按 `verMajor` 分派；Q0.2 起可断言）。 */
    public let rules: FbcRuleSet

    public init(
        header: FbcHeader,
        code: Array<UInt8>,
        consts: ConstRegistry,
        site: SiteTable,
        name: NameTable,
        dir: FuncDir,
        types: Array<LocalTypes>,
        rules: FbcRuleSet
    ) {
        this.header = header
        this.code = code
        this.consts = consts
        this.site = site
        this.name = name
        this.dir = dir
        this.types = types
        this.rules = rules
    }

    /** 入口函数条目（`entryFn` 已在加载期校验命中目录）。 */
    public func entry(): FuncEntry {
        this.dir.get(this.header.entryFn)
    }

    /**
     * 单元是否依赖宿主**类注册表**（design-m2 D12「14 槽注册表依赖校验」）。
     *
     * 依赖面只有两种：
     * - 任一函数的返回类型/局部槽为 14（不透明宿主对象）；
     * - 任一 `CALL_HELPER` 家族的 hid ≥ `0x0100`（成员访问/构造物化出的 user helper）。
     *
     * 13（HostClosure）与 M3 JSON 内建码（16–19）不在其中（零注册）。
     */
    public func requiresClassRegistry(): Bool {
        for (i in 0..this.dir.size) {
            if (this.rules.isRegistryDependent(this.dir.at(i).retType)) {
                return true
            }
        }
        for (t in this.types) {
            for (i in 0..t.size) {
                if (this.rules.isRegistryDependent(UInt16(t.get(i)))) {
                    return true
                }
            }
        }
        for (j in 0..this.dir.size) {
            let e = this.dir.at(j)
            var p = Int64(e.codeOff)
            let end = Int64(e.codeOff) + Int64(e.codeLen)
            while (p < end) {
                let op = this.code[p]
                let insn = InsnDecoder.decode(this.code, p)
                if ((op == OP_CALL_HELPER || op == OP_CALL_HELPER_NC || op == OP_CALL_HELPER_V) &&
                    insn.size >= 3) {
                    let hid = UInt16(this.code[p + 1]) | (UInt16(this.code[p + 2]) << 8)
                    if (hid >= HELPER_USER_BASE) {
                        return true
                    }
                }
                p = p + insn.size
            }
        }
        false
    }
}

/** 取 `raw[off, off+len)`；越界 ⇒ 容器格式类拒绝。 */
internal func sliceOf(raw: Array<UInt8>, off: Int64, len: Int64): Array<UInt8> {
    if (off < 0 || len < 0 || off + len > raw.size) {
        rejectFormat('段越界: off=${off}, len=${len}, raw=${raw.size}')
    }
    let out = Array<UInt8>(len, repeat: 0u8)
    for (i in 0..len) {
        out[i] = raw[off + i]
    }
    out
}

/** 32 位十六进制（诊断文本用）。 */
internal func hexOf32(v: UInt32): String {
    var out = ''
    for (i in 0..4) {
        out = out + hex2(UInt8((v >> (8 * (3 - i))) & 0xFFu32))
    }
    out
}
