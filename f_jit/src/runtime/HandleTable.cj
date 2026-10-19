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
package fountain::f_jit.runtime

import std.collection.ArrayList
import std.collection.HashMap
import std.math.numeric.Decimal
import std.sync.Mutex
import std.time.DateTime
import fountain::f_jit.base.ErrCode
import fountain::f_jit.base.TypeToken
import fountain::f_jit.bytecode.ConstMapKey

/**
 * helper 边界的失败信号 —— design D5 / §9 附则 5。
 *
 * helper 内部**绝不把异常抛给字节码或机器码**：一切失败都先转成错误码写进 ctx 错误槽。
 * 本异常只在 helper 的仓颉实现内部传播，立刻被 helper 的 `catch` 捕获并转码（§6 模板）。
 */
public class HelperFail <: Exception {
    public let code: Int64

    public init(code: Int64) {
        super(ErrCode.describe(code))
        this.code = code
    }
}

/** 抛出一个 helper 失败信号（错误码见 §2）。 */
public func failWith(code: Int64): Nothing {
    throw HelperFail(code)
}

/**
 * 句柄表（ID 形态） —— design-m1 §5.3.2、plan-m1 S4.2–S4.5。
 *
 * 权威 = `doc/jit-bytecode-m1.md` §1（槽 = `idx:u32 + tag:u16 + gen:u16`）、§8.1（四条路径）、
 * §9 附则 6（窗口容量与扩容）、§9 附则 14（冻结决策 ④：ID 形态而非裸指针）。
 *
 * 槽位三元组编码（低 → 高）：`idx` 32 位、`tag` 16 位、`gen` 16 位。`idx = 0` 不用（保留给
 * null），因此**任何已分配句柄的 `gen ≥ 1` ⇒ ID ≥ 2^48**，与普通整数值域天然不交（这也是
 * 运行期「某 cell 是否为句柄」能被确定性判定的依据）。
 *
 * 四条路径：A 常量（`markConst`，跨调用共享、写入 → 20）、B 宿主 pin（参数 / 常量登记）、
 * C 窗口 `append`（分配型 helper，每次至多 1 个新槽）、D 逃逸（窗口重置后仍可用且 ID 不变）。
 */
public class HandleTable {
    /** 窗口初始容量（调用前可调，不追溯进行中的调用；§9 附则 6）。 */
    public static var initialCapacity: Int64 = 128
    /** 句柄表全局槽上限（触顶 → 16；运行中调大即时生效、调小不追溯）。 */
    public static var capacityLimit: Int64 = 1048576

    private static let mtx = Mutex()
    // **索引 0 是哨兵**（不可达）：ID 编码里 idx=0 与「空句柄」共用 0 值域，且全表遍历从 1 起
    // （`for i in 1..objs.size`）——没有哨兵时**第一个 pin 的对象必然拿 idx=0 而永久不可读**。
    private static let objs: ArrayList<Any> = HandleTable.seedObjs()
    private static let tags: ArrayList<UInt16> = HandleTable.seedU16()
    private static let gens: ArrayList<UInt16> = HandleTable.seedU16()
    private static let alive: ArrayList<Bool> = HandleTable.seedBool()
    private static let constFlags: ArrayList<Bool> = HandleTable.seedBool()
    /** 路径 A 引用计数：同一常量被多个单元共享时按 pin 次数计数，归零才回收。 */
    private static let constRefs: ArrayList<Int64> = HandleTable.seedI64()
    private static let escapeFlags: ArrayList<Bool> = HandleTable.seedBool()
    private static let freeSlots: ArrayList<Int64> = ArrayList<Int64>()

    private static func seedObjs(): ArrayList<Any> {
        let a = ArrayList<Any>()
        a.add('')
        a
    }

    private static func seedU16(): ArrayList<UInt16> {
        let a = ArrayList<UInt16>()
        a.add(0u16)
        a
    }

    private static func seedBool(): ArrayList<Bool> {
        let a = ArrayList<Bool>()
        a.add(false)
        a
    }

    private static func seedI64(): ArrayList<Int64> {
        let a = ArrayList<Int64>()
        a.add(0)
        a
    }

    /** 当前窗口：`[windowBase, windowTop)`（M1 只增不减）。 */
    private static var windowBase: Int64 = 0
    private static var windowCap: Int64 = 0
    private static var windowTop: Int64 = 0
    /** 本次窗口实际占用的槽索引（允许复用旧 freeSlots，故不能用连续区间表示）。 */
    private static let windowSlots: ArrayList<Int64> = ArrayList<Int64>()
    private static var windowUsedCount: Int64 = 0

    // ---- 槽位三元组编码 ----

    /** 由 `(idx, tag, gen)` 组装 ID。 */
    public static func makeId(idx: Int64, tag: UInt16, gen: UInt16): Int64 {
        var u: UInt64 = UInt64(gen) << 48
        u = u | (UInt64(tag) << 32)
        u = u | UInt64(UInt32(idx))
        Int64(u)
    }

    /** ID → 槽索引（低 32 位）。 */
    public static func idxOf(id: Int64): Int64 {
        if (id <= 0) {
            0
        } else {
            Int64(UInt64(id) & 0x00000000FFFFFFFFu64)
        }
    }

    /** ID → 类型标签（次 16 位）。 */
    public static func tagOf(id: Int64): UInt16 {
        if (id <= 0) {
            0u16
        } else {
            UInt16((UInt64(id) >> 32) & 0xFFFFu64)
        }
    }

    /** ID → 世代号（高 16 位）。 */
    public static func genOf(id: Int64): UInt16 {
        if (id <= 0) {
            0u16
        } else {
            UInt16((UInt64(id) >> 48) & 0xFFFFu64)
        }
    }

    // ---- 类型标签判定 ----

    /** 宿主对象 → 类型 token（§6 token 表）；无对应 token ⇒ 0（保留）。 */
    public static func tokenOf(obj: Any): UInt16 {
        match (obj) {
            case _: ArrayList<Any> => TypeToken.LIST
            case _: HashMap<ConstMapKey, Any> => TypeToken.MAP
            case _: String => TypeToken.STRING
            case _: Decimal => TypeToken.DECIMAL
            case _: DateTime => TypeToken.DATETIME
            case _: Duration => TypeToken.DURATION
            case _: Range<Int64> => TypeToken.RANGE
            case _: JitRegex => TypeToken.REGEX
            case _: JitClosure => TypeToken.CLOSURE
            case _: HostCallback => TypeToken.HOST_CLOSURE
            case _ => TypeToken.RESERVED
        }
    }

    /**
     * 规范键文本（等值判定与哈希的依据）。
     *
     * 不可变值（String / Decimal / DateTime / Duration / Range / Regex）按**值**取键：值不可变
     * ⇒ 等值即等价，两个等值常量共用同一槽不会引入可观察差异。可变容器（List / Map）**不参与
     * 去重**（见 `pin` 的实现说明）。
     */
    public static func canonKeyOf(obj: Any): String {
        match (obj) {
            case v: String => 's:${v}'
            case v: Decimal => 'd:${v.toString()}'
            case v: DateTime => 't:${safeNanos(v.toUnixTimeStamp())}'
            case v: Duration => 'u:${safeNanos(v)}'
            case v: Range<Int64> => 'r:${v.start}|${v.end}|${v.step}|${v.isClosed}'
            case v: JitRegex => 'x:${v.re.string()}|${v.flags}'
            case _ => ''
        }
    }

    // ---- 窗口 ----

    /** 当前窗口起点（= `ctx.hwBase` 镜像）。 */
    public static func windowBaseOf(): Int64 {
        windowBase
    }

    /** 当前窗口容量（= `ctx.hwCap` 镜像）。 */
    public static func windowCapOf(): Int64 {
        windowCap
    }

    /** 当前窗口已用数（逻辑计数；槽索引允许复用旧 freeSlots）。 */
    public static func windowUsed(): Int64 {
        windowUsedCount
    }

    /**
     * 打开一次调用的窗口（桥 `call<T>` 第 1 步；§8.2）。
     *
     * `hwBase` = 表尾（本次调用的起点），`hwCap` = `initialCapacity`（无分配单元传 0）。
     */
    public static func openWindow(cap: Int64): Unit {
        synchronized(mtx) {
            windowBase = objs.size
            windowTop = windowBase
            windowCap = if (cap <= 0) { initialCapacity } else { cap }
            windowSlots.clear()
            windowUsedCount = 0
        }
    }

    /** 窗口镜像同步到 ctx（机器码按同一偏移读写的契约）。 */
    public static func syncTo(ctx: JitContext): Unit {
        ctx.hwBase = windowBase
        ctx.hwCap = windowCap
        ctx.hwTop = windowBase + windowUsedCount
    }

    /** 从 ctx 读回窗口镜像（机器码侧推 `hwTop` 后由桥同步）。 */
    public static func syncFrom(ctx: JitContext): Unit {
        windowBase = ctx.hwBase
        windowCap = ctx.hwCap
        windowTop = ctx.hwTop
        windowUsedCount = ctx.hwTop - ctx.hwBase
    }

    // ---- 路径 B / A：pin ----

    /**
     * 宿主对象 → 句柄 ID（路径 B；常量走 `pinConst`）。
     *
     * **同对象复用同 ID**：不可变值（String / Decimal / DateTime / Duration / Range / Regex）
     * 按规范键去重 —— 值不可变，等值即等价；可变容器（List / Map）每次 `pin` 取新槽，以保留
     * 「两个空列表是两个对象」的可区分性（仓颉没有引用相等运算符，`==` 对 `ArrayList` 是值
     * 相等，无法据此判身份；见实现说明）。
     *
     * 无类型 token 的对象 ⇒ `ERR_CALL_CONTRACT(19)`。
     */
    public static func pin(obj: Any): Int64 {
        let tok = tokenOf(obj)
        if (tok == TypeToken.RESERVED) {
            failWith(ErrCode.CALL_CONTRACT)
        }
        synchronized(mtx) {
            // 宿主闭包（tag=10）按**对象身份**去重：闭包没有值语义键，两个不同的闭包即使
            // 代码相同也是不同回调（捕获环境可能不同）。
            if (tok == TypeToken.HOST_CLOSURE) {
                match (obj) {
                    case cb: HostCallback =>
                        var i = 1
                        while (i < objs.size) {
                            if (alive[i] && !constFlags[i] && tags[i] == tok) {
                                match (objs[i]) {
                                    case old: HostCallback =>
                                        if (refEq(old, cb)) {
                                            return makeId(i, tok, gens[i])
                                        }
                                    case _ => ()
                                }
                            }
                            i = i + 1
                        }
                    case _ => ()
                }
            } else if (tok != TypeToken.LIST && tok != TypeToken.MAP) {
                let key = canonKeyOf(obj)
                var i = 1
                while (i < objs.size) {
                    if (alive[i] && !constFlags[i] && tags[i] == tok && canonKeyOf(objs[i]) == key) {
                        return makeId(i, tok, gens[i])
                    }
                    i = i + 1
                }
            }
            newSlotLocked(obj, tok, false)
        }
    }

    /**
     * 路径 B：宿主闭包 → tag=10 句柄（m2 §4/§10）。
     *
     * 同函数值 + 同签名 ⇒ 复用同 ID（幂等 Marshal）；签名不同则新槽（避免错用旧条目签名）。
     */
    public static func pinHostClosure(fn: Any, sig: SignatureDescriptor): Int64 {
        synchronized(mtx) {
            var i = 1
            while (i < objs.size) {
                if (alive[i] && !constFlags[i] && tags[i] == TypeToken.HOST_CLOSURE) {
                    match (objs[i]) {
                        case old: HostCallback =>
                            let sameFn = match (old.fn) {
                                case a: Object =>
                                    match (fn) {
                                        case b: Object => refEq(a, b)
                                        case _ => false
                                    }
                                case _ => false
                            }
                            if (sameFn) {
                                match (old.sig) {
                                    case Some(s) =>
                                        if (HandleTable.sigEquals(s, sig)) {
                                            return makeId(i, TypeToken.HOST_CLOSURE, gens[i])
                                        }
                                    case None => ()
                                }
                            }
                        case _ => ()
                    }
                }
                i = i + 1
            }
            newSlotLocked(HostCallback(fn, sig), TypeToken.HOST_CLOSURE, false)
        }
    }

    private static func sigEquals(a: SignatureDescriptor, b: SignatureDescriptor): Bool {
        if (a.ret != b.ret || a.params.size != b.params.size) {
            return false
        }
        var i = 0
        while (i < a.params.size) {
            if (a.params[i] != b.params[i]) {
                return false
            }
            i = i + 1
        }
        true
    }

    /**
     * 路径 B：宿主注册类实例 → tag=11 句柄 ID（m2 §11/§16.2）。
     *
     * 注册类实例没有内建 token（`tokenOf` 对任意类返回 RESERVED），由调用方显式按
     * **不透明宿主对象**大类登记；同一对象复用同 ID（引用语义、零拷贝）。
     */
    public static func pinHostObject(obj: Object): Int64 {
        synchronized(mtx) {
            var i = 1
            while (i < objs.size) {
                if (alive[i] && !constFlags[i] && tags[i] == TypeToken.HOST_OBJECT) {
                    match (objs[i]) {
                        case old: Object =>
                            if (refEq(old, obj)) {
                                return makeId(i, TypeToken.HOST_OBJECT, gens[i])
                            }
                        case _ => ()
                    }
                }
                i = i + 1
            }
            newSlotLocked(obj, TypeToken.HOST_OBJECT, false)
        }
    }

    /**
     * 路径 A：常量登记（跨调用共享、只读；写入 → 20）。
     *
     * 与普通 `pin` 分开：常量槽只与常量槽去重，并维护引用计数；
     * `releaseConst` 归零后才真正回收，避免卸载一个单元误伤其他单元的常量句柄。
     */
    public static func pinConst(obj: Any): Int64 {
        let tok = tokenOf(obj)
        if (tok == TypeToken.RESERVED) {
            failWith(ErrCode.CALL_CONTRACT)
        }
        synchronized(mtx) {
            if (tok != TypeToken.LIST && tok != TypeToken.MAP) {
                let key = canonKeyOf(obj)
                var i = 1
                while (i < objs.size) {
                    if (alive[i] && constFlags[i] && tags[i] == tok && canonKeyOf(objs[i]) == key) {
                        constRefs[i] = constRefs[i] + 1
                        return makeId(i, tok, gens[i])
                    }
                    i = i + 1
                }
            }
            newSlotLocked(obj, tok, true)
        }
    }

    /** 归还一次路径 A 引用；归零时回收槽位（幂等，非常量/已回收槽忽略）。 */
    public static func releaseConst(id: Int64): Unit {
        let i = idxOf(id)
        synchronized(mtx) {
            if (i <= 0 || i >= objs.size || !alive[i] || !constFlags[i]) {
                return
            }
            constRefs[i] = constRefs[i] - 1
            if (constRefs[i] > 0) {
                return
            }
            alive[i] = false
            objs[i] = Int64(0)
            constFlags[i] = false
            escapeFlags[i] = false
            constRefs[i] = 0
            gens[i] = gens[i] + UInt16(1)
            freeSlots.add(i)
        }
    }

    /** 某槽是否属路径 A（常量）。 */
    public static func isConst(id: Int64): Bool {
        let i = idxOf(id)
        synchronized(mtx) {
            if (i <= 0 || i >= objs.size) {
                false
            } else {
                constFlags[i]
            }
        }
    }

    /** 某槽是否已登记为逃逸。 */
    public static func isEscaped(id: Int64): Bool {
        let i = idxOf(id)
        synchronized(mtx) {
            if (i <= 0 || i >= objs.size) {
                false
            } else {
                escapeFlags[i]
            }
        }
    }

    // ---- 路径 C：窗口登记 ----

    /**
     * 分配型 helper 登记新槽（路径 C）。
     *
     * `hwTop == hwCap`（即已用数 == 容量）时**就地倍增**（扩容后容量 ≥ 2×已用数，以
     * `capacityLimit` 封顶，§9 附则 6）；触及全局上限 ⇒ `ERR_HANDLE_WINDOW_FULL(16)`。
     * 返回新槽 ID。
     */
    public static func append(ctx: JitContext, obj: Any, tok: UInt16): Int64 {
        synchronized(mtx) {
            // 扩容触发点：保证追加后「容量 ≥ 2 × 已用数」（plan-m1 S4.3）
            let need = 2 * (windowUsedCount + 1)
            if (need > windowCap) {
                var nc = windowCap * 2
                if (nc <= 0) {
                    nc = initialCapacity
                }
                if (nc < need) {
                    nc = need
                }
                if (windowBase + nc > capacityLimit) {
                    nc = capacityLimit - windowBase
                }
                if (nc < windowUsedCount + 1) {
                    // 容量已到全局上限，无法再扩 ⇒ 触顶
                    syncTo(ctx)
                    failWith(ErrCode.HANDLE_WINDOW_FULL)
                }
                windowCap = nc
            }
            if (windowBase + windowUsedCount >= capacityLimit) {
                syncTo(ctx)
                failWith(ErrCode.HANDLE_WINDOW_FULL)
            }
            let id = newSlotLocked(obj, tok, false)
            windowSlots.add(idxOf(id))
            windowUsedCount = windowUsedCount + 1
            windowTop = windowBase + windowUsedCount
            syncTo(ctx)
            id
        }
    }

    /** `Duration → 纳秒`；极端值（±Duration.Max）超出 Int64 ⇒ 退化为上下界哨兵（不抛异常）。 */
    internal static func safeNanos(d: Duration): Int64 {
        try {
            d.toNanoseconds()
        } catch (e: Exception) {
            if (d > Duration.Zero) { Int64.Max } else { Int64.Min }
        }
    }

    // ---- 取值 ----

    /** 宿主侧取回：`Option.Any`；类型不符 / 失效 ⇒ `None`（design §5.3.2 路径 D 读回）。 */
    public static func getAny(id: Int64): ?Any {
        if (id == 0) {
            return None
        }
        let i = idxOf(id)
        synchronized(mtx) {
            if (i <= 0 || i >= objs.size) {
                None
            } else if (!alive[i] || gens[i] != genOf(id)) {
                None
            } else {
                Some(objs[i])
            }
        }
    }

    /**
     * 宿主侧类型化取回（类型不符 ⇒ `None`）。
     *
     * 按**槽位 tag** 判定（与 `fetch` 同口径）：tag 11 的宿主类实例没有内建 `tokenOf`
     * （任意类都返回 RESERVED），故不能按载荷反推大类（m2 §11 / Q4.10）。
     */
    public static func getAs(id: Int64, tok: UInt16): ?Any {
        if (isType(id, tok)) {
            getAny(id)
        } else {
            None
        }
    }

    /**
     * helper 边界取值（内部 / protected）：null → 6、类型不符 → 8、坏索引 → 6（防御）。
     *
     * 失败以 `HelperFail` 抛出，由 helper 的 `catch` 转码写槽（design D5）。
     */
    public static func fetchAny(id: Int64, tok: UInt16): Any {
        if (id == 0) {
            failWith(ErrCode.NULL_HANDLE)
        }
        let i = idxOf(id)
        if (i <= 0) {
            failWith(ErrCode.NULL_HANDLE)
        }
        let v = synchronized(mtx) {
            if (i >= objs.size) {
                failWith(ErrCode.NULL_HANDLE)
            }
            if (!alive[i] || gens[i] != genOf(id)) {
                failWith(ErrCode.NULL_HANDLE)
            }
            objs[i]
        }
        if (tokenOf(v) != tok) {
            failWith(ErrCode.HANDLE_TYPE)
        }
        v
    }

    /** 取 String（null → 6、类型不符 → 8）。 */
    public static func fetchString(id: Int64): String {
        match (fetchAny(id, TypeToken.STRING)) {
            case v: String => v
            case _ => failWith(ErrCode.HANDLE_TYPE)
        }
    }

    /** 取 List（null → 6、类型不符 → 8）。 */
    public static func fetchList(id: Int64): ArrayList<Any> {
        match (fetchAny(id, TypeToken.LIST)) {
            case v: ArrayList<Any> => v
            case _ => failWith(ErrCode.HANDLE_TYPE)
        }
    }

    /** 取 Map（null → 6、类型不符 → 8）。 */
    protected static func fetchMap(id: Int64): HashMap<ConstMapKey, Any> {
        match (fetchAny(id, TypeToken.MAP)) {
            case v: HashMap<ConstMapKey, Any> => v
            case _ => failWith(ErrCode.HANDLE_TYPE)
        }
    }

    /** 取 Decimal。 */
    public static func fetchDecimal(id: Int64): Decimal {
        match (fetchAny(id, TypeToken.DECIMAL)) {
            case v: Decimal => v
            case _ => failWith(ErrCode.HANDLE_TYPE)
        }
    }

    /** 取 DateTime。 */
    public static func fetchDateTime(id: Int64): DateTime {
        match (fetchAny(id, TypeToken.DATETIME)) {
            case v: DateTime => v
            case _ => failWith(ErrCode.HANDLE_TYPE)
        }
    }

    /** 取 Duration。 */
    public static func fetchDuration(id: Int64): Duration {
        match (fetchAny(id, TypeToken.DURATION)) {
            case v: Duration => v
            case _ => failWith(ErrCode.HANDLE_TYPE)
        }
    }

    /** 取 Range。 */
    public static func fetchRange(id: Int64): Range<Int64> {
        match (fetchAny(id, TypeToken.RANGE)) {
            case v: Range<Int64> => v
            case _ => failWith(ErrCode.HANDLE_TYPE)
        }
    }

    /** 取 Regex 承载对象（`JitRegex`：pattern + flags，供 §11.9 的 TO_STR 输出）。 */
    public static func fetchRegexEx(id: Int64): JitRegex {
        match (fetchAny(id, TypeToken.REGEX)) {
            case v: JitRegex => v
            case _ => failWith(ErrCode.HANDLE_TYPE)
        }
    }

    /** 取闭包对象。 */
    public static func fetchClosure(id: Int64): JitClosure {
        match (fetchAny(id, TypeToken.CLOSURE)) {
            case v: JitClosure => v
            case _ => failWith(ErrCode.HANDLE_TYPE)
        }
    }

    /** 取宿主闭包条目（tag=10；null → 6、类型不符 → 8）。 */
    public static func fetchHostCallback(id: Int64): HostCallback {
        match (fetchAny(id, TypeToken.HOST_CLOSURE)) {
            case v: HostCallback => v
            case _ => failWith(ErrCode.HANDLE_TYPE)
        }
    }

    /** 取宿主对象引用（tag=11；null → 6、类型不符 → 8）。 */
    public static func fetchHostObject(id: Int64): Object {
        // tag 11 是**显式写入**的大类（`pinHostObject`）：任意宿主类都没有内建 token，
        // 故不能走 `fetchAny` 的 `tokenOf` 校验，改按槽位 tag 判定。
        if (id == 0) {
            failWith(ErrCode.NULL_HANDLE)
        }
        let i = idxOf(id)
        if (i <= 0) {
            failWith(ErrCode.NULL_HANDLE)
        }
        let v = synchronized(mtx) {
            if (i >= objs.size) {
                failWith(ErrCode.NULL_HANDLE)
            }
            if (!alive[i] || gens[i] != genOf(id) || tags[i] != TypeToken.HOST_OBJECT) {
                failWith(ErrCode.HANDLE_TYPE)
            }
            objs[i]
        }
        match (v) {
            case o: Object => o
            case _ => failWith(ErrCode.HANDLE_TYPE)
        }
    }

    /** 句柄类型判定（helper H17；null ⇒ false，不失败）。 */
    public static func isType(id: Int64, tok: UInt16): Bool {
        if (id == 0) {
            return false
        }
        let i = idxOf(id)
        if (i <= 0 || i >= objs.size) {
            return false
        }
        synchronized(mtx) {
            if (!alive[i] || gens[i] != genOf(id)) {
                false
            } else {
                tags[i] == tok
            }
        }
    }

    /** 非抛出版本：取句柄 tag，失效 / null ⇒ 0（解释器内部的类型分派用）。 */
    public static func tagOrZero(id: Int64): UInt16 {
        if (id == 0) {
            return 0u16
        }
        let i = idxOf(id)
        if (i <= 0 || i >= objs.size) {
            return 0u16
        }
        synchronized(mtx) {
            if (!alive[i] || gens[i] != genOf(id)) {
                0u16
            } else {
                tags[i]
            }
        }
    }

    /** 取句柄 tag（helper H18；null → 6）。 */
    public static func tagOfHandle(id: Int64): UInt16 {
        if (id == 0) {
            failWith(ErrCode.NULL_HANDLE)
        }
        let i = idxOf(id)
        if (i <= 0 || i >= objs.size) {
            failWith(ErrCode.NULL_HANDLE)
        }
        synchronized(mtx) {
            if (!alive[i] || gens[i] != genOf(id)) {
                failWith(ErrCode.NULL_HANDLE)
            }
            tags[i]
        }
    }

    // ---- 释放 / 逃逸 / 重置 ----

    /** 释放（宿主显式释放逃逸句柄；表项 gen+1 后方可复用 ⇒ 旧 ID 永久失效）。 */
    public static func release(id: Int64): Unit {
        let i = idxOf(id)
        if (i <= 0 || i >= objs.size) {
            return
        }
        synchronized(mtx) {
            if (alive[i] && gens[i] == genOf(id) && !constFlags[i]) {
                alive[i] = false
                objs[i] = Int64(0)
                gens[i] = gens[i] + UInt16(1)
                if (!escapeFlags[i]) {
                    freeSlots.add(i)
                }
            }
        }
    }

    /** 显式归还一个逃逸句柄（桥把返回值取成宿主对象后调用；常量槽不回收）。 */
    public static func releaseEscaped(id: Int64): Unit {
        let i = idxOf(id)
        synchronized(mtx) {
            if (i <= 0 || i >= objs.size || !alive[i] || constFlags[i]) {
                return
            }
            if (gens[i] != genOf(id)) {
                return
            }
            alive[i] = false
            objs[i] = Int64(0)
            escapeFlags[i] = false
            gens[i] = gens[i] + UInt16(1)
            freeSlots.add(i)
        }
    }

    /** 路径 D：登记逃逸（窗口重置后仍可用且 ID 不变）。 */
    public static func escape(id: Int64): Unit {
        let i = idxOf(id)
        if (i <= 0 || i >= objs.size) {
            return
        }
        synchronized(mtx) {
            if (alive[i] && gens[i] == genOf(id)) {
                escapeFlags[i] = true
            }
        }
    }

    /**
     * 调用结束重置窗口：窗口内**未逃逸**的槽全部释放（gen+1、可复用），逃逸槽保留。
     *
     * `hwBase` 给 ≥ 0 时按该值重建窗口（桥的口径）；给 < 0 时以表尾为起点。
     */
    public static func resetWindow(hwBase: Int64): Unit {
        synchronized(mtx) {
            var k = 0
            while (k < windowSlots.size) {
                let i = windowSlots[k]
                if (i > 0 && i < objs.size && alive[i] && !escapeFlags[i] && !constFlags[i]) {
                    alive[i] = false
                    objs[i] = Int64(0)
                    gens[i] = gens[i] + UInt16(1)
                    freeSlots.add(i)
                }
                k = k + 1
            }
            windowSlots.clear()
            windowUsedCount = 0
            windowBase = if (hwBase >= 0) { hwBase } else { objs.size }
            windowTop = windowBase
            windowCap = initialCapacity
        }
    }

    /**
     * 提升组协作：**原地提升**一组槽（m2 §14.1/§14.2）。
     *
     * - 迁出**窗口记账**（从 `windowSlots` 移除并递减已用数；`hwTop` 镜像随之下降）；
     * - 表项保留，**ID / gen 不变**，并打逃逸标记 ⇒ 窗口重置不释放；
     * - 不进入对象内部（**槽级、免级联**，§14.6）；参数里没给的槽一律不动。
     *
     * 幂等：已迁出的槽不会重复扣减记账。
     */
    public static func moveOutGroup(ids: Array<Int64>): Unit {
        synchronized(mtx) {
            var n = 0
            while (n < ids.size) {
                let id = ids[n]
                let i = idxOf(id)
                if (i > 0 && i < objs.size && alive[i] && gens[i] == genOf(id) && !constFlags[i]) {
                    escapeFlags[i] = true
                    var k = 0
                    var removed = false
                    while (k < windowSlots.size && !removed) {
                        if (windowSlots[k] == i) {
                            windowSlots.remove(at: k)
                            if (windowUsedCount > 0) {
                                windowUsedCount = windowUsedCount - 1
                            }
                            windowTop = windowBase + windowUsedCount
                            removed = true
                        } else {
                            k = k + 1
                        }
                    }
                }
                n = n + 1
            }
        }
    }

    /** M2 提升组占位：把槽提升为「不受窗口重置影响」的常驻槽（等价逃逸登记）。 */
    public static func promote(id: Int64): Unit {
        moveOutGroup([id])
    }

    // ---- 内部 ----

    private static func newSlotLocked(obj: Any, tok: UInt16, isConst: Bool): Int64 {
        var idx = 0
        if (freeSlots.size > 0) {
            idx = freeSlots.remove(at: freeSlots.size - 1)
            objs[idx] = obj
            tags[idx] = tok
            alive[idx] = true
            constFlags[idx] = isConst
            constRefs[idx] = if (isConst) { 1 } else { 0 }
            escapeFlags[idx] = false
        } else {
            objs.add(obj)
            tags.add(tok)
            gens.add(1u16)
            alive.add(true)
            constFlags.add(isConst)
            constRefs.add(if (isConst) { 1 } else { 0 })
            escapeFlags.add(false)
            idx = objs.size - 1
        }
        makeId(idx, tok, gens[idx])
    }

    /** 用例/宿主审计：当前活槽数。 */
    public static func liveCount(): Int64 {
        synchronized(mtx) {
            var n = 0
            for (i in 1..objs.size) {
                if (alive[i]) {
                    n = n + 1
                }
            }
            n
        }
    }

    /** 用例/宿主审计：累计分配过的槽位数（表尾）。 */
    public static func slotCount(): Int64 {
        synchronized(mtx) {
            objs.size
        }
    }

    /** 测试专用：清空整张表并复位窗口（不用于生产路径）。 */
    public static func resetForTest(): Unit {
        synchronized(mtx) {
            objs.clear()
            tags.clear()
            gens.clear()
            alive.clear()
            constFlags.clear()
            constRefs.clear()
            escapeFlags.clear()
            freeSlots.clear()
            windowSlots.clear()
            windowUsedCount = 0
            // idx 0 保留（null 哨兵）
            objs.add(Int64(0))
            tags.add(TypeToken.RESERVED)
            gens.add(0u16)
            alive.add(false)
            constFlags.add(false)
            constRefs.add(0)
            escapeFlags.add(false)
            windowBase = 1
            windowTop = 1
            windowCap = initialCapacity
        }
    }

    /** `cell` 是否为活句柄（gen ≥ 1 ⇒ ID ≥ 2^48，与普通整数值域不交）。 */
    public static func isLiveHandle(cell: Int64): Bool {
        if (cell <= 0) {
            return false
        }
        let i = idxOf(cell)
        if (i <= 0 || i >= objs.size) {
            return false
        }
        synchronized(mtx) {
            alive[i] && gens[i] == genOf(cell)
        }
    }

    /** `cell` → 宿主对象（活句柄）；否则按原值装箱（容器元素按 §3.2 cell 表示原样存取）。 */
    public static func cellToAny(cell: Int64): Any {
        match (getAny(cell)) {
            case Some(v) => v
            case None => cell
        }
    }

    /** 宿主对象 → `cell`（活句柄取 ID；值型按其类型装箱后由调用方解释）。 */
    public static func anyToCell(v: Any): Int64 {
        match (v) {
            case i: Int64 => i
            case f: Float64 => Int64(f.toBits())
            case b: Bool => if (b) { 1 } else { 0 }
            case _ => pin(v)
        }
    }
}

/**
 * 逃逸区（per-call）—— design-m1 §5.3.2、plan-m1 S4.5。
 *
 * 桥在一次调用中把需要交回宿主的句柄登记进逃逸区；窗口重置时这些槽保持可用且 ID 不变，
 * 非逃逸槽随重置失效。
 */
public class EscapeArea {
    private let ids: ArrayList<Int64> = ArrayList<Int64>()

    /** 登记一个逃逸句柄（同步打逃逸标记）。 */
    public func add(id: Int64): Unit {
        if (!this.ids.contains(id)) {
            this.ids.add(id)
        }
        HandleTable.escape(id)
    }

    /** 已登记的句柄快照。 */
    public func snapshot(): Array<Int64> {
        this.ids.toArray()
    }

    public func size(): Int64 {
        this.ids.size
    }

    public func contains(id: Int64): Bool {
        this.ids.contains(id)
    }

    /** 调用收尾：清空登记（句柄本身由宿主 `release`）。 */
    public func clear(): Unit {
        this.ids.clear()
    }
}

/**
 * 闭包对象（§8.6）—— H54 `closure_new` 的产物。
 *
 * 形态冻结为 `{fnId, captured}`：捕获是**按值快照**（`Array<Int64>`，cell 表示），
 * `LOAD_CAP` 按序读取。M1 内只读使用，不可经 `call<T>` 逃逸（§8.6）。
 */
public class JitClosure {
    public let fnId: Int64
    public let captured: Array<Int64>

    public init(fnId: Int64, captured: Array<Int64>) {
        this.fnId = fnId
        this.captured = captured
    }
}
