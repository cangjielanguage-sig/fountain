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
import std.collection.HashMap
import std.math.numeric.BigInt
import std.math.numeric.Decimal
import std.regex.RegexFlag
import std.time.DateTime
import fountain::f_base.*
import fountain::f_data.json.JsonValue
import fountain::f_regex.*

/** 每秒纳秒数（`DateTime` epochNanos 拆解，§11.5 kind 7）。 */
internal const NANOS_PER_SECOND: Int64 = 1_000_000_000


/**
 * 常量表：拼装期注册 + 常量段编解码 + 冻结 —— design-m1 §3.3.6、plan-m1 S2.7 / S2.8。
 *
 * 权威 = `doc/jit-bytecode-m1.md` §11.5「常量表序列化（与句柄解耦）」与 §3.3「常量表（拼装期
 * 构造，只读共享）」。
 *
 * 用 class 而非 struct：它持有**可变状态且必须被共享同一实例**（若用 struct，赋值处会被静默
 * 浅拷贝成两份常量表，`PUSH_KH` 索引就不再唯一）。
 *
 * **注册 API 的口径**：`addList` / `addMap` 接受**已登记子常量的索引**（`u32`），构成 DAG；
 * 只有 `addRegex` 做去重（§3.3「同 (pattern, flags) 去重为同一常量」），其余 `add` 一律返回
 * **递增** hid（拼装期不去重——去重会破坏「字面值按出现顺序稳定编号」的可观察性质）。
 */
public class ConstRegistry {
    /** 常量段格式版本（`ConstTable.version` 字段）。 */
    public static const CONST_VERSION: UInt16 = 1u16

    private let payloads: ArrayList<ConstPayload>
    /** 正则去重键：`pattern|flags` → hid（§3.3「同单元内同 (pattern, flags) 去重」）。 */
    private let regexKeys: HashMap<String, Int64>
    /** 加载期实例缓存（下标与 `payloads` 对齐）；DAG 共享子结构由此天然解出**同一对象**。 */
    private let instances: ArrayList<?Any>
    private var frozenFlag: Bool

    /**
     * 正则**编译次数**计数器（可观测性接缝，§3.3「同 (pattern, flags) 单元内同 ID、
     * **编译次数 == 常量数**（一次编译断言）」，T20）。
     *
     * 每真正构造一次 `Regex` 就 +1；去重与缓存都发生在它之前，故「多次引用同一常量」⇒ +0。
     */
    public static var regexCompileCount: Int64 = 0

    public init() {
        this.payloads = ArrayList<ConstPayload>()
        this.regexKeys = HashMap<String, Int64>()
        this.instances = ArrayList<?Any>()
        this.frozenFlag = false
    }

    /** 已登记常量数（`PUSH_KH idx < size` 的校验依据，§11.5）。 */
    public prop size: Int64 {
        get() {
            this.payloads.size
        }
    }

    /** 是否已冻结（冻结后只读）。 */
    public prop isFrozen: Bool {
        get() {
            this.frozenFlag
        }
    }

    /** 取第 `i` 条载荷；越界 ⇒ 拒绝。 */
    public func get(i: Int64): ConstPayload {
        if (i < 0 || i >= this.payloads.size) {
            rejectFormat('常量索引越界: ${i} / ${this.payloads.size}')
        }
        this.payloads[i]
    }

    /** 冻结：之后只读（`PUSH_KH` 校验依赖，§3.3）。 */
    public func freeze(): Unit {
        this.frozenFlag = true
    }

    private func ensureWritable(): Unit {
        if (this.frozenFlag) {
            rejectFormat('常量表已冻结，拒绝写入（§3.3「冻结（之后只读）」）')
        }
    }

    private func append(p: ConstPayload): Int64 {
        ensureWritable()
        this.payloads.add(p)
        this.instances.add(None)
        this.payloads.size - 1
    }

    // ---- 加载期实例化（plan-m1 S2.15）----

    /**
     * 按 kind 实例化全部常量（kind 1–10，§11.5）。
     *
     * 实例化**经 std**（`Decimal` / `DateTime` / `Duration` / `Range` / `ArrayList` / `HashMap`），
     * 正则经 `fountain::f_regex`（§3.2「std 类型映射」）；非法或空 pattern ⇒ **加载期 14**，
     * 不推迟到执行期（§3.3）。
     */
    public func instantiateAll(): Unit {
        for (i in 0..this.payloads.size) {
            let unused = instanceAt(i)
            let _ = unused
        }
    }

    /**
     * 取第 `i` 条的**宿主对象**（首次访问时实例化并缓存）。
     *
     * DAG 共享子结构（多个父条目引用同一子索引）解出**同一对象**——缓存按下标命中，第二次
     * 访问直接返回同一个引用（§11.5「允许共享子结构」、T20）。
     */
    public func instanceAt(i: Int64): Any {
        if (i < 0 || i >= this.payloads.size) {
            rejectFormat('常量索引越界: ${i} / ${this.payloads.size}（PUSH_KH idx < size）')
        }
        match (this.instances[i]) {
            case Some(v) => v
            case None =>
                let v = makeInstance(i)
                this.instances[i] = Some(v)
                v
        }
    }

    private func makeInstance(i: Int64): Any {
        match (this.payloads[i]) {
            case PI64(v) => v
            case PF64(bits) => Float64.fromBits(bits)
            case PStr(s) => s
            case PList(xs) =>
                let out = ArrayList<Any>()
                for (x in xs) {
                    out.add(instanceAt(Int64(x)))
                }
                out
            case PMap(ps) =>
                let out = HashMap<ConstMapKey, Any>()
                for (kv in ps) {
                    let k = instanceAt(Int64(kv[0]))
                    out.add(ConstMapKey(k, tokenOf(Int64(kv[0]))), instanceAt(Int64(kv[1])))
                }
                out
            case PDec(sign, scale, coeff) => decimalFromParts(sign, scale, coeff)
            case PDateTime(nanos) => DateTime.ofEpoch(second: nanos / NANOS_PER_SECOND, nanosecond: nanos % NANOS_PER_SECOND)
            case PDuration(nanos) => Duration.nanosecond * nanos
            case PRange(start, end, step, isClosed) => Range<Int64>(start, end, step, true, true, isClosed)
            case PRegex(pattern, flags) => compileRegex(pattern, flags)
            case PJson(raw) => parseJsonConst(raw)
        }
    }

    /**
     * 递归规范化键（`DAG` 子索引会被展开），用于 Map 常量的哈希键。
     *
     * 两个**等值**但索引不同的键必须得到同一 token；两个不同值的键必须得到不同 token。
     */
    private func tokenOf(i: Int64): String {
        match (this.payloads[i]) {
            // 与运行期 `HandleTable.canonKeyOf` 共用 `CanonKey`（D5：单一事实来源）
            case PI64(v) => CanonKey.i64(v)
            // 值型键在运行期是裸 cell：Float64 常量键必须与 `mapKeyOf` 的 cell 键同形
            case PF64(b) => CanonKey.cell(Int64(b))
            case PStr(s) => CanonKey.str(s)
            case PList(xs) =>
                var t = 'l['
                for (x in xs) {
                    t = t + tokenOf(Int64(x)) + ','
                }
                t + ']'
            case PMap(ps) =>
                var t = 'm['
                for (kv in ps) {
                    t = t + tokenOf(Int64(kv[0])) + ':' + tokenOf(Int64(kv[1])) + ','
                }
                t + ']'
            case PDec(sign, scale, coeff) => CanonKey.dec(sign, scale, coeff)
            case PDateTime(n) => CanonKey.dateTime(n)
            case PDuration(n) => CanonKey.duration(n)
            case PRange(a, b, c, closed) => CanonKey.range(a, b, c, closed)
            case PRegex(p, f) => CanonKey.regex(p, f)
            case PJson(raw) => 'j${raw}'
        }
    }

    // ---- 注册 API ----

    /** 注册 Int64 常量。 */
    public func addI64(v: Int64): Int64 {
        append(ConstPayload.PI64(v))
    }

    /** 注册 Float64 常量（**位模式**；拼装期必须已规范化为 canonical NaN，§11.3）。 */
    public func addF64(bits: UInt64): Int64 {
        append(ConstPayload.PF64(bits))
    }

    /** 注册字符串常量（UTF-8，§11.4）。 */
    public func addStr(s: String): Int64 {
        append(ConstPayload.PStr(s))
    }

    /** 注册 List 常量，`children` 为**已登记**子常量的索引（DAG，允许共享子结构）。 */
    public func addList(children: Array<UInt32>): Int64 {
        checkChildren(children)
        append(ConstPayload.PList(children))
    }

    /** 注册 Map 常量，`pairs` 为**已登记**键/值常量的索引。 */
    public func addMap(pairs: Array<(UInt32, UInt32)>): Int64 {
        for (kv in pairs) {
            checkChildren([kv[0], kv[1]])
        }
        append(ConstPayload.PMap(pairs))
    }

    /** 注册 Decimal 常量（载荷形态：`sign` / `scale` / 系数数字串，§11.5 kind 6）。 */
    public func addDecimal(sign: UInt8, scale: Int32, coeff: String): Int64 {
        append(ConstPayload.PDec(sign, scale, coeff))
    }

    /** 注册 DateTime 常量（epochNanos，UTC，§11.4）。 */
    public func addDateTime(epochNanos: Int64): Int64 {
        append(ConstPayload.PDateTime(epochNanos))
    }

    /** 注册 Duration 常量（nanos）。 */
    public func addDuration(nanos: Int64): Int64 {
        append(ConstPayload.PDuration(nanos))
    }

    /** 注册 Range 常量（`isClosed` = 左闭右闭 `..=`，§11.5 kind 9）。 */
    public func addRange(start: Int64, end: Int64, step: Int64, isClosed: Bool): Int64 {
        append(ConstPayload.PRange(start, end, step, isClosed))
    }

    /**
     * 注册 JSON 常量（M3 §11）：**只登记规范化后的原始字节，拼装期不解析**。
     *
     * 空串与超长（> 16 MiB）在这里就被拒绝——空串必定是非法 JSON，超长更可能是拼装错误，
     * 没必要等到加载期。真正的 JSON 语法校验发生在加载期（`PJson` 实例化）。
     */
    public func addJson(raw: String): Int64 {
        if (raw.isEmpty()) {
            rejectFormat('JSON 常量载荷为空（M3 §11）')
        }
        if (raw.size > 16 * 1024 * 1024) {
            rejectFormat('JSON 常量超长: ${raw.size} 字节（上限 16 MiB）')
        }
        append(ConstPayload.PJson(raw))
    }

    /** 值常量（Decimal）→ hid：按 `std` 的文本化结果拆出 `sign / scale / 系数`（§11.4 表示）。 */
    public func addValue(v: Decimal): Int64 {
        let (sign, scale, coeff) = decimalParts(v)
        addDecimal(sign, scale, coeff)
    }

    /** 值常量（DateTime）→ hid：epochNanos（UTC）。 */
    public func addValue(v: DateTime): Int64 {
        addDateTime(v.toUnixTimeStamp().toNanoseconds())
    }

    /** 值常量（Duration）→ hid：nanos。 */
    public func addValue(v: Duration): Int64 {
        addDuration(v.toNanoseconds())
    }

    /**
     * 注册 Regex 常量（字符形态 flags：`i` / `m` / `u` 任意组合，**顺序无关、重复幂等**，
     * v0.18.18 冻结）；同 (pattern, 归一 flags) **去重为同一常量**（§3.3）。
     *
     * `i` / `m` / `u` 之外的字符 ⇒ 14（§3.3「`i/m/u` 之外的字符仍属非法 flags」）。
     */
    public func addRegex(pattern: String, flags: String): Int64 {
        addRegex(pattern, normalizeRegexFlags(flags))
    }

    /** 注册 Regex 常量（位域形态 flags：bit0=i bit1=m bit2=u，§11.5 kind 10）。 */
    public func addRegex(pattern: String, flags: UInt8): Int64 {
        if ((flags & 0xF8u8) != 0u8) {
            rejectRegex('非法正则 flags 位域: ${flags}（仅 bit0=i bit1=m bit2=u）')
        }
        ensureWritable()
        let key = '${flags}|${pattern}'
        match (this.regexKeys.get(key)) {
            case Some(hid) => hid
            case None =>
                let hid = append(ConstPayload.PRegex(pattern, flags))
                this.regexKeys.add(key, hid)
                hid
        }
    }

    private func checkChildren(children: Array<UInt32>): Unit {
        for (c in children) {
            if (UInt64(c) >= UInt64(this.payloads.size)) {
                rejectFormat('常量子索引越界: ${c} / ${this.payloads.size}（DAG 只允许引用已登记项）')
            }
        }
    }

    // ---- 常量段编解码（§11.5）----

    /** 编码整个常量段：`version: u16 + count: u32 + entries`。 */
    public func encode(): Array<UInt8> {
        let w = ByteWriter()
        w.wU16(CONST_VERSION)
        w.wU32(UInt32(this.payloads.size))
        for (i in 0..this.payloads.size) {
            let p = this.payloads[i]
            w.wU8(ConstPayload.kindOf(p))
            encodePayload(w, p)
        }
        w.take()
    }

    /**
     * 解码常量段并冻结。
     *
     * 校验点（§11.5）：`version` 一致、`count` 与字节数相符、kind 合法、
     * Float64 位模式 canonical、Decimal 系数为 ASCII '0'–'9'、正则 flags 位域合法、
     * **DAG 子索引必须小于自身索引**（同时排除自环与前向引用）。
     */
    public static func decode(bytes: Array<UInt8>): ConstRegistry {
        let reg = ConstRegistry()
        let r = ByteReader(bytes)
        let version = r.u16()
        if (version != CONST_VERSION) {
            rejectFormat('常量段版本不符: ${version}（本实现 ${CONST_VERSION}）')
        }
        let count = r.u32()
        if (Int64(count) * 1 > r.remaining()) {
            rejectFormat('常量段条目数不符: count=${count}, 剩余字节=${r.remaining()}')
        }
        for (i in 0..Int64(count)) {
            let kind = r.u8()
            let p = decodePayload(kind, r)
            // DAG：子索引必须落在已登记区间 [0, i)
            match (p) {
                case PList(xs) => checkChildIndices(xs, Int64(i))
                case PMap(ps) =>
                    for (kv in ps) {
                        checkChildIndices([kv[0], kv[1]], Int64(i))
                    }
                case _ => ()
            }
            reg.payloads.add(p)
            reg.instances.add(None)
        }
        if (r.remaining() != 0) {
            rejectFormat('常量段尾部残留字节: ${r.remaining()}')
        }
        reg.freeze()
        reg
    }

    private static func checkChildIndices(children: Array<UInt32>, selfIndex: Int64): Unit {
        for (c in children) {
            if (UInt64(c) >= UInt64(selfIndex)) {
                rejectFormat('常量图成环或前向引用: 条目 ${selfIndex} 引用 ${c}（§11.5 必须是 DAG）')
            }
        }
    }
}

/**
 * Map 常量的哈希键承载体。
 *
 * **为什么需要它**：常量表的键是**异质的**（Int64 / String / Decimal / DateTime / …），宿主侧统一
 * 表示为 `Any`，而 `Any` 不满足 `std.collection.HashMap` 的 `K <: Hashable & Equatable<K>`
 * 约束 ⇒ 无法直接做 `HashMap<Any, Any>`。这里只补一个**哈希 / 相等的外壳**（token 来自载荷的
 * 规范化文本），容器本身仍是 §3.2 规定的 `std HashMap`。
 *
 * `protected`（module 级）：它是模型内部件，不进用户面（design D2 可见性三档）。
 */
protected class ConstMapKey <: Hashable & Equatable<ConstMapKey> {
    /** 实例化的键对象（宿主值）。 */
    public let value: Any
    /** 规范化键文本（哈希与相等的依据）。 */
    public let token: String

    public init(value: Any, token: String) {
        this.value = value
        this.token = token
    }

    public func hashCode(): Int64 {
        this.token.hashCode()
    }

    public operator func ==(other: ConstMapKey): Bool {
        this.token == other.token
    }
}

/** `(sign, scale, 系数)` → `std.math.numeric.Decimal`（§11.4「任意精度，不自定义类型」）。 */
internal func decimalFromParts(sign: UInt8, scale: Int32, coeff: String): Decimal {
    var mag = BigInt.parse(coeff)
    if (sign != 0u8) {
        mag = -mag
    }
    Decimal(mag, scale)
}

/**
 * kind 11 实例化：JSON 文本**只解析一次**（M3 §11），非法即加载期拒绝。
 *
 * 与正则同构：解析结果登记进 `instances` 缓存，跨调用同 ID。`f_data` 的解析器把 JSON
 * 数字一律读成 `JsonDecimal`，本层不做数值域转换（出口解包在 H81 里做）。
 */
internal func parseJsonConst(raw: String): Any {
    try {
        JsonValue.fromStr(raw)
    } catch (e: Exception) {
        rejectFormat('JSON 常量解析失败: ${e.message}（M3 §11 加载期防御拒绝）')
    }
}

/** kind 10 实例化：正则**只编译一次**（§3.3）；非法 / 空 pattern ⇒ 加载期 14。 */
internal func compileRegex(pattern: String, flags: UInt8): Regex {
    if (pattern.isEmpty()) {
        rejectRegex('正则 pattern 为空（§3.3：防零宽匹配死循环，加载期拒绝）')
    }
    var list = ArrayList<RegexFlag>()
    if ((flags & 0x01u8) != 0u8) {
        list.add(RegexFlag.IgnoreCase)
    }
    if ((flags & 0x02u8) != 0u8) {
        list.add(RegexFlag.MultiLine)
    }
    if ((flags & 0x04u8) != 0u8) {
        list.add(RegexFlag.Unicode)
    }
    ConstRegistry.regexCompileCount = ConstRegistry.regexCompileCount + 1
    try {
        pattern.regex(flags: list.toArray())
    } catch (e: Exception) {
        rejectRegex('正则 pattern 非法: ${pattern}（§3.3 加载期拒绝，不推迟到执行期）')
    }
}

/** 正则 flags 字符 → 位域（bit0=i bit1=m bit2=u；顺序无关、重复幂等，v0.18.18）。 */
internal func normalizeRegexFlags(flags: String): UInt8 {
    var bits: UInt8 = 0u8
    // 逐**字节**扫描（不依赖 String 下标语义）：'i' = 0x69、'm' = 0x6D、'u' = 0x75
    for (b in flags.unsafeBytes()) {
        if (b == 0x69u8) {
            bits = bits | 0x01u8
        } else if (b == 0x6Du8) {
            bits = bits | 0x02u8
        } else if (b == 0x75u8) {
            bits = bits | 0x04u8
        } else {
            rejectRegex('非法正则 flags 字符: 0x${hex2(b)}（仅 i / m / u，§3.3）')
        }
    }
    bits
}

/** Decimal → `(sign, scale, 系数数字串)`（按 §11.4 / §11.5 kind 6 的表示）。 */
internal func decimalParts(v: Decimal): (UInt8, Int32, String) {
    let bs = v.toString().unsafeBytes()
    var sign: UInt8 = 0u8
    var digits = ArrayList<UInt8>()
    var scale: Int64 = 0
    var seenDot = false
    var i = 0
    for (b in bs) {
        // '-' = 0x2D、'.' = 0x2E、'0'..'9' = 0x30..0x39
        if (b == 0x2Du8 && i == 0) {
            sign = 1u8
        } else if (b == 0x2Eu8) {
            seenDot = true
        } else if (b >= 0x30u8 && b <= 0x39u8) {
            digits.add(b)
            if (seenDot) {
                scale = scale + 1
            }
        }
        i = i + 1
    }
    (sign, Int32(scale), String.fromUtf8(digits.toArray()))
}

/** 按 kind 写出载荷（§11.5）。 */
internal func encodePayload(w: ByteWriter, p: ConstPayload): Unit {
    match (p) {
        case PI64(v) => w.wI64(v)
        case PF64(bits) => w.wU64(bits)
        case PStr(s) =>
            let bs = s.unsafeBytes()
            w.wU32(UInt32(bs.size))
            w.wBytes(bs)
        case PList(xs) =>
            w.wU32(UInt32(xs.size))
            for (x in xs) {
                w.wU32(x)
            }
        case PMap(ps) =>
            w.wU32(UInt32(ps.size))
            for (kv in ps) {
                w.wU32(kv[0])
                w.wU32(kv[1])
            }
        case PDec(sign, scale, coeff) =>
            w.wU8(sign)
            w.wI32(scale)
            let bs = coeff.unsafeBytes()
            w.wU32(UInt32(bs.size))
            w.wBytes(bs)
        case PDateTime(nanos) => w.wI64(nanos)
        case PDuration(nanos) => w.wI64(nanos)
        case PRange(start, end, step, isClosed) =>
            w.wI64(start)
            w.wI64(end)
            w.wI64(step)
            w.wU8(if (isClosed) {
                1u8
            } else {
                0u8
            })
        case PRegex(pattern, flags) =>
            let bs = pattern.unsafeBytes()
            w.wU8(flags)
            w.wU16(UInt16(bs.size))
            w.wBytes(bs)
        case PJson(raw) =>
            let bs = raw.unsafeBytes()
            w.wU32(UInt32(bs.size))
            w.wBytes(bs)
    }
}

/** 按 kind 读回载荷（§11.5）；任一处越界 / 非法 ⇒ 容器格式类拒绝。 */
internal func decodePayload(kind: UInt8, r: ByteReader): ConstPayload {
    match (kind) {
        case 1u8 => ConstPayload.PI64(r.i64())
        case 2u8 =>
            let bits = r.u64()
            let exp = bits & 0x7FF0000000000000u64
            let mant = bits & 0x000FFFFFFFFFFFFFu64
            if (exp == 0x7FF0000000000000u64 && mant != 0u64 && bits != 0x7FF8000000000000u64) {
                rejectFormat('非 canonical Float64 常量: 0x${hexOf64(bits)}（§11.3 canonical NaN = 0x7FF8000000000000）')
            }
            ConstPayload.PF64(bits)
        case 3u8 =>
            let n = r.u32()
            let bs = r.bytes(Int64(n))
            ConstPayload.PStr(utf8OrReject(bs))
        case 4u8 =>
            let n = r.u32()
            if (Int64(n) * 4 > r.remaining()) {
                rejectFormat('List 常量元素数与字节数不符: n=${n}')
            }
            let xs = Array<UInt32>(Int64(n), repeat: 0u32)
            for (i in 0..Int64(n)) {
                xs[i] = r.u32()
            }
            ConstPayload.PList(xs)
        case 5u8 =>
            let n = r.u32()
            if (Int64(n) * 8 > r.remaining()) {
                rejectFormat('Map 常量键值对数与字节数不符: n=${n}')
            }
            let ps = Array<(UInt32, UInt32)>(Int64(n), repeat: (0u32, 0u32))
            for (i in 0..Int64(n)) {
                let k = r.u32()
                let v = r.u32()
                ps[i] = (k, v)
            }
            ConstPayload.PMap(ps)
        case 6u8 =>
            let sign = r.u8()
            let scale = r.i32()
            let n = r.u32()
            let bs = r.bytes(Int64(n))
            for (b in bs) {
                if (b < 0x30u8 || b > 0x39u8) {
                    rejectFormat('Decimal 系数含非数字字节: 0x${hex2(b)}（§11.5 kind 6 只接受 ASCII 0–9）')
                }
            }
            if (bs.size == 0) {
                rejectFormat('Decimal 系数为空（§11.5 kind 6）')
            }
            ConstPayload.PDec(sign, scale, String.fromUtf8(bs))
        case 7u8 => ConstPayload.PDateTime(r.i64())
        case 8u8 => ConstPayload.PDuration(r.i64())
        case 9u8 =>
            let start = r.i64()
            let end = r.i64()
            let step = r.i64()
            let closed = r.u8()
            ConstPayload.PRange(start, end, step, closed != 0u8)
        case 10u8 =>
            let flags = r.u8()
            if ((flags & 0xF8u8) != 0u8) {
                rejectFormat('非法正则 flags 位域: ${flags}（仅 bit0=i bit1=m bit2=u）')
            }
            let n = r.u16()
            let bs = r.bytes(Int64(n))
            ConstPayload.PRegex(utf8OrReject(bs), flags)
        case 11u8 =>
            let n = r.u32()
            if (Int64(n) > r.remaining()) {
                rejectFormat('JSON 常量长度与字节数不符: n=${n}, 剩余=${r.remaining()}')
            }
            let bs = r.bytes(Int64(n))
            if (bs.isEmpty()) {
                rejectFormat('JSON 常量载荷为空（M3 §11）')
            }
            ConstPayload.PJson(utf8OrReject(bs))
        case _ => rejectFormat('非法常量 kind: ${kind}（M1 合法 1–10、M3 追加 11，§11.5）')
    }
}

/** UTF-8 解码；非法字节序列 ⇒ 容器格式类拒绝（§11.4「非法 UTF-8：拼装期拒绝」）。 */
internal func utf8OrReject(bs: Array<UInt8>): String {
    try {
        String.fromUtf8(bs)
    } catch (e: Exception) {
        rejectFormat('非法 UTF-8 字节序列（§11.4）')
    }
}

/** 64 位十六进制（诊断文本用）。 */
internal func hexOf64(v: UInt64): String {
    var out = ''
    for (i in 0..8) {
        let b = UInt8((v >> (8 * (7 - i))) & 0xFFu64)
        out = out + hex2(b)
    }
    out
}
