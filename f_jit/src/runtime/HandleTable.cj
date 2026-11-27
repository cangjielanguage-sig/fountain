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
import std.sync.AtomicInt64
import std.time.DateTime
import fountain::f_jit.base.ErrCode
import fountain::f_jit.base.TypeToken
import fountain::f_data.json.JsonValue
import fountain::f_jit.bytecode.CanonKey
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
 * 句柄槽的**分块存储**（并行调用 P0 选型）—— 每段 1024 槽，段一经分配**永不搬迁**。
 *
 * 为什么不是「预分配整表」：`capacityLimit` 是运行期可调的上限，预分配要么按上限浪费
 * 数十 MB，要么在调大时重分配 ⇒ 搬迁与在飞读者竞态。分块后「增长」只是给目录挂一段新
 * 数组，已有段地址不变，活跃窗口期间的读路径不受影响。
 */
private class SlotSeg {
    let objs: Array<Any>
    let tags: Array<UInt16>
    let gens: Array<UInt16>
    let alive: Array<Bool>
    let constFlags: Array<Bool>
    let constRefs: Array<Int64>
    let escapeFlags: Array<Bool>
    let frozenFlags: Array<Bool>

    init(cap: Int64) {
        this.objs = Array<Any>(cap, repeat: 0)
        this.tags = Array<UInt16>(cap, repeat: 0u16)
        this.gens = Array<UInt16>(cap, repeat: 0u16)
        this.alive = Array<Bool>(cap, repeat: false)
        this.constFlags = Array<Bool>(cap, repeat: false)
        this.constRefs = Array<Int64>(cap, repeat: 0)
        this.escapeFlags = Array<Bool>(cap, repeat: false)
        this.frozenFlags = Array<Bool>(cap, repeat: false)
    }
}

/**
 * 空闲索引分片表（Phase 2）。
 *
 * 槽索引按 `idx & (n-1)` **固定归属**某个分片：释放只进归属分片，分配可扫描任意分片
 * （优先本线程上次命中的那个）。这样同一索引的「取出/归还」永远落在同一把锁上，
 * 同槽双释放被串行化；不同索引最多 1/64 概率争用。
 */
private class FreeStripes {
    let lists: Array<ArrayList<Int64>>
    let mtxs: Array<Mutex>

    init(n: Int64) {
        this.lists = Array<ArrayList<Int64>>(n, repeat: ArrayList<Int64>())
        this.mtxs = Array<Mutex>(n, repeat: Mutex())
        var i = 0
        while (i < n) {
            this.lists[i] = ArrayList<Int64>()
            this.mtxs[i] = Mutex()
            i = i + 1
        }
    }
}

/**
 * 一次调用的窗口记账（**线程私有**，并行调用 D3b）。
 *
 * 槽数据仍在全局分块表里（提升要求 ID 不变、包装要跨线程可解析）；这里只放
 * 只有本线程使用的记账：基址/容量/已用数、本窗口分配的 ID 清单。
 *
 * 两张清单都存 **ID（含 gen）** 而不是索引：槽可能被显式归还、又被别的线程复用 ——
 * 收尾只能按「代数仍匹配」释放，否则会误杀新槽。
 */
internal class Win {
    var base: Int64
    var cap: Int64
    var used: Int64 = 0
    /** 路径 C（`append`）登记的 ID：参与 `hwTop` / 容量记账，收尾时释放。 */
    let appendIds: ArrayList<Int64> = ArrayList<Int64>()
    /**
     * 路径 B（桥侧 `pin`）登记的 ID：**不占窗口、不随窗口重置释放**（跨调用存活，
     * 由 `CallMarshal.cleanup` / 宿主释放）；这里只用于本窗口内的同对象去重。
     */
    let pins: ArrayList<Int64> = ArrayList<Int64>()

    init(base: Int64, cap: Int64) {
        this.base = base
        this.cap = cap
    }
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
    /**
     * 窗口初始容量（调用前可调，不追溯进行中的调用；§9 附则 6）。
     *
     * H4：底层是 `AtomicInt64`——运行中改配置与并发开窗之间不再有数据竞争；
     * 赋值语法（`HandleTable.initialCapacity = n`）保持不变。
     */
    public static mut prop initialCapacity: Int64 {
        get() {
            initialCapacityAtomic.load()
        }
        set(v) {
            initialCapacityAtomic.store(v)
        }
    }

    /** 句柄表全局槽上限（触顶 → 16；运行中调大即时生效、调小不追溯）。 */
    public static mut prop capacityLimit: Int64 {
        get() {
            capacityLimitAtomic.load()
        }
        set(v) {
            capacityLimitAtomic.store(v)
        }
    }

    private static let initialCapacityAtomic = AtomicInt64(128)
    private static let capacityLimitAtomic = AtomicInt64(1048576)

    /** 分配器/回收/常量路径的**冷路径**锁；读路径不再进锁（D3）。 */
    private static let mtx = Mutex()

    /** 段内位移：1024 槽一段。 */
    private static const SEG_SHIFT: Int64 = 10
    private static const SEG_SIZE: Int64 = 1024
    /** 目录上限：4096 段 = 4M 槽（`capacityLimit` 默认 1M，留足扩容余量）。 */
    private static const MAX_SEGS: Int64 = 4096
    /**
     * 世代号上限：`gen` 占 ID 的最高 16 位，最高位是符号位 ⇒ 只能用到 `0x7FFF`。
     * 到达上限的槽**退休**（不再 +1、不进空闲表、永不复用），否则 `makeId` 的受检转换会溢出。
     */
    private static const GEN_MAX: UInt16 = 0x7FFFu16
    /** 退休槽数（诊断/审计）：这些槽保持失效但永久占用索引空间。 */
    private static let retiredSlots = AtomicInt64(0)

    /** 目录占位段：未分配的段一律指向它（`alive` 恒 false ⇒ 读即失效）。 */
    private static let EMPTY_SEG: SlotSeg = SlotSeg(SEG_SIZE)
    /** 段目录：**定长**，只替换元素、不重分配 ⇒ 读者无需加锁。 */
    private static let segDir: Array<SlotSeg> = Array<SlotSeg>(MAX_SEGS, repeat: EMPTY_SEG)
    /**
     * 已分配过的槽位总数（高水位，代替原先 `objs.size`）。
     * 索引 0 是哨兵（不可达）：ID 编码里 idx=0 与「空句柄」共用 0 值域。
     */
    private static let totalSlots = AtomicInt64(1)
    /** 空闲索引分片数（必须是 2 的幂：按 `idx & (FREE_STRIPES-1)` 固定归属）。 */
    private static const FREE_STRIPES: Int64 = 64
    /**
     * 空闲索引分片（Phase 2）：每个分片一把锁。分配只在自己的分片上摘索引，
     * 释放只归还到该槽归属的分片 ⇒ 全局 `mtx` 不再参与每次分配/释放。
     */
    private static let stripes = FreeStripes(FREE_STRIPES)

    /**
     * 各线程的窗口栈（`optimize-runtime-tls`：存储在 `RuntimeState.wins`，不再单独占一个 TLS）。
     * 栈底是**环境窗口**（直接调 helper 的用例没有显式 openWindow）。
     */
    private static func winStackOf(rs: RuntimeState): ArrayList<Win> {
        if (rs.wins.size == 0) {
            rs.wins.add(Win(1, initialCapacity))
        }
        rs.wins
    }

    private static func winStack(): ArrayList<Win> {
        winStackOf(RuntimeEnv.current())
    }

    private static func currentWinOf(rs: RuntimeState): Win {
        let s = winStackOf(rs)
        s[s.size - 1]
    }

    /** 从池里取一个 `Win`（清空上一次的记账）；池空则新建。 */
    private static func acquireWin(rs: RuntimeState, base: Int64, cap: Int64): Win {
        if (rs.freeWins.size > 0) {
            let w = rs.freeWins.remove(at: rs.freeWins.size - 1)
            w.base = base
            w.cap = cap
            w.used = 0
            w.appendIds.clear()
            w.pins.clear()
            return w
        }
        Win(base, cap)
    }

    /** 回收一个已清空的 `Win`（上限 8；超出丢弃）。 */
    private static func recycleWin(rs: RuntimeState, w: Win): Unit {
        if (rs.freeWins.size < 8) {
            w.used = 0
            w.appendIds.clear()
            w.pins.clear()
            rs.freeWins.add(w)
        }
    }

    private static func currentWin(): Win {
        currentWinOf(RuntimeEnv.current())
    }

    private static func currentWinOrNone(): ?Win {
        let s = winStack()
        if (s.size == 0) {
            None
        } else {
            Some(s[s.size - 1])
        }
    }

    /** 窗口内去重的候选总数：路径 C 的追加槽 + 路径 B 的 pin 槽。 */
    private static func winPinSize(w: Win): Int64 {
        w.appendIds.size + w.pins.size
    }

    /** 按序号取候选 ID（先 `appendIds` 后 `pins`）。 */
    private static func winPinIdAt(w: Win, k: Int64): Int64 {
        if (k < w.appendIds.size) {
            w.appendIds[k]
        } else {
            w.pins[k - w.appendIds.size]
        }
    }

    // ---- 分块寻址 ----

    private static func segAt(i: Int64): SlotSeg {
        if (i <= 0) {
            return EMPTY_SEG
        }
        let c = i >> SEG_SHIFT
        if (c >= MAX_SEGS) {
            return EMPTY_SEG
        }
        segDir[c]
    }

    private static func offOf(i: Int64): Int64 {
        i & (SEG_SIZE - 1)
    }

    /** 取（必要时分配）第 i 槽所在段；调用方必须持有 `mtx`。 */
    private static func ensureSegLocked(i: Int64): SlotSeg {
        let c = i >> SEG_SHIFT
        if (c >= MAX_SEGS) {
            failWith(ErrCode.HANDLE_WINDOW_FULL)
        }
        var s = segDir[c]
        if (refEq(s, EMPTY_SEG)) {
            s = SlotSeg(SEG_SIZE)
            segDir[c] = s
        }
        s
    }

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
            case _: JitAnyBox => TypeToken.ANY
            case _: JsonValue => TypeToken.HOST_OBJECT
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
        // 与常量表的 `ConstRegistry.tokenOf` 共用 `CanonKey`（D5）：Float64 / Decimal 等
        // 此前两边前缀不同，常量键在运行期永不命中（P1-7）。
        match (obj) {
            case v: String => CanonKey.str(v)
            case v: Float64 => CanonKey.f64(v.toBits())
            case v: Decimal => CanonKey.decFromText(v.toString())
            case v: DateTime => CanonKey.dateTime(safeNanos(v.toUnixTimeStamp()))
            case v: Duration => CanonKey.duration(safeNanos(v))
            case v: Range<Int64> => CanonKey.range(v.start, v.end, v.step, v.isClosed)
            case v: JitRegex => CanonKey.regex(v.re.string(), v.flags)
            case _ => ''
        }
    }

    // ---- 窗口 ----

    /** 当前窗口起点（= `ctx.hwBase` 镜像；线程私有）。 */
    public static func windowBaseOf(): Int64 {
        currentWin().base
    }

    /** 当前窗口容量（= `ctx.hwCap` 镜像；线程私有）。 */
    public static func windowCapOf(): Int64 {
        currentWin().cap
    }

    /** 当前窗口已用数（逻辑计数；槽索引允许复用旧空闲槽）。 */
    public static func windowUsed(): Int64 {
        currentWin().used
    }

    /**
     * 打开一次调用的窗口并返回 `(base, cap)`（`optimize-runtime-tls`）：
     * 调用方拿到上下界后直接建 ctx，不再分别 `windowBaseOf()` / `windowCapOf()`。
     */
    public static func openWindowWith(rs: RuntimeState, cap: Int64): (Int64, Int64) {
        // 原子读高水位：窗口基址只是容量账，不要求精确（槽允许复用、不要求连续）。
        let base = totalSlots.load()
        let c = if (cap <= 0) { initialCapacity } else { cap }
        winStackOf(rs).add(acquireWin(rs, base, c))
        (base, c)
    }

    public static func openWindow(cap: Int64): Unit {
        let _ = openWindowWith(RuntimeEnv.current(), cap)
    }

    /** 窗口镜像同步到 ctx（机器码按同一偏移读写的契约）。 */
    public static func syncTo(ctx: JitContext): Unit {
        HandleTable.syncTo(ctx, RuntimeEnv.current())
    }

    /** 窗口镜像同步（调用方已持有本线程状态，零 TLS）。 */
    public static func syncTo(ctx: JitContext, rs: RuntimeState): Unit {
        let w = currentWinOf(rs)
        ctx.hwBase = w.base
        ctx.hwCap = w.cap
        ctx.hwTop = w.base + w.used
    }

    /** 从 ctx 读回窗口镜像（机器码侧推 `hwTop` 后由桥同步）。 */
    public static func syncFrom(ctx: JitContext): Unit {
        let w = currentWin()
        w.base = ctx.hwBase
        w.cap = ctx.hwCap
        w.used = if (ctx.hwTop > ctx.hwBase) { ctx.hwTop - ctx.hwBase } else { 0 }
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
        HandleTable.pinWith(RuntimeEnv.current(), obj)
    }

    /** 调用方已持有本线程状态（零 TLS）。 */
    public static func pinWith(rs: RuntimeState, obj: Any): Int64 {
        let tok = tokenOf(obj)
        if (tok == TypeToken.RESERVED) {
            failWith(ErrCode.CALL_CONTRACT)
        }
        // 窗口内去重（D3c）：同一对象在「实参 / 闭包内引用 / 返回值带回」保持身份是**调用内**
        // 语义，只需扫本窗口分配过的 ID；不再在全局锁内做全表线性扫描。
        let w = currentWinOf(rs)
        var k = 0
        while (k < winPinSize(w)) {
            let id = winPinIdAt(w, k)
            let i = idxOf(id)
            let seg = segAt(i)
            let off = offOf(i)
            if (i > 0 && seg.alive[off] && seg.gens[off] == genOf(id) && !seg.constFlags[off] &&
                seg.tags[off] == tok) {
                // 身份型载荷（tag=10 宿主闭包 / tag=12 Any 盒）按**对象身份**去重：两者都没有
                // 值语义键——闭包即便代码相同也可能捕获不同环境；盒的值可以有等值副本，但盒本身
                // 有身份（容器里存的就是同一个盒，反复读出必须回到同一句柄，否则窗口会被读操作耗尽）。
                if (tok == TypeToken.HOST_CLOSURE || tok == TypeToken.ANY) {
                    match (obj) {
                        case target: Object =>
                            match (seg.objs[off]) {
                                case old: Object =>
                                    if (refEq(old, target)) {
                                        return id
                                    }
                                case _ => ()
                            }
                        case _ => ()
                    }
                } else if (tok != TypeToken.LIST && tok != TypeToken.MAP && !(obj is JsonValue)) {
                    if (canonKeyOf(seg.objs[off]) == canonKeyOf(obj)) {
                        return id
                    }
                }
            }
            k = k + 1
        }
        let id = newSlotWith(rs, obj, tok, false)
        w.pins.add(id)
        id
    }

    /**
     * 路径 B：宿主闭包 → tag=10 句柄（m2 §4/§10）。
     *
     * 同函数值 + 同签名 ⇒ 复用同 ID（幂等 Marshal）；签名不同则新槽（避免错用旧条目签名）。
     */
    public static func pinHostClosure(fn: Any, sig: SignatureDescriptor): Int64 {
        HandleTable.pinHostClosureWith(RuntimeEnv.current(), fn, sig)
    }

    /** 调用方已持有本线程状态（零 TLS）。 */
    public static func pinHostClosureWith(rs: RuntimeState, fn: Any, sig: SignatureDescriptor): Int64 {
        let w = currentWinOf(rs)
        var k = 0
        while (k < winPinSize(w)) {
            let id = winPinIdAt(w, k)
            let i = idxOf(id)
            let seg = segAt(i)
            let off = offOf(i)
            if (i > 0 && seg.alive[off] && seg.gens[off] == genOf(id) && !seg.constFlags[off] &&
                seg.tags[off] == TypeToken.HOST_CLOSURE) {
                match (seg.objs[off]) {
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
                                        return id
                                    }
                                case None => ()
                            }
                        }
                    case _ => ()
                }
            }
            k = k + 1
        }
        let id = newSlotWith(rs, HostCallback(fn, sig), TypeToken.HOST_CLOSURE, false)
        w.pins.add(id)
        id
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
        HandleTable.pinHostObjectWith(RuntimeEnv.current(), obj)
    }

    /** 调用方已持有本线程状态（零 TLS）。 */
    public static func pinHostObjectWith(rs: RuntimeState, obj: Object): Int64 {
        let w = currentWinOf(rs)
        var k = 0
        while (k < winPinSize(w)) {
            let id = winPinIdAt(w, k)
            let i = idxOf(id)
            let seg = segAt(i)
            let off = offOf(i)
            if (i > 0 && seg.alive[off] && seg.gens[off] == genOf(id) && !seg.constFlags[off] &&
                seg.tags[off] == TypeToken.HOST_OBJECT) {
                match (seg.objs[off]) {
                    case old: Object =>
                        if (refEq(old, obj)) {
                            return id
                        }
                    case _ => ()
                }
            }
            k = k + 1
        }
        let id = newSlotWith(rs, obj, TypeToken.HOST_OBJECT, false)
        w.pins.add(id)
        id
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
            // JSON 节点是可变的，按身份区分（它们的 canonKeyOf 为空，合并会把对象/数组混为一谈）
            if (tok != TypeToken.LIST && tok != TypeToken.MAP && !(obj is JsonValue)) {
                let key = canonKeyOf(obj)
                let top = totalSlots.load()
                var i = 1
                while (i < top) {
                    let seg = segAt(i)
                    let off = offOf(i)
                    if (seg.alive[off] && seg.constFlags[off] && seg.tags[off] == tok &&
                        canonKeyOf(seg.objs[off]) == key) {
                        seg.constRefs[off] = seg.constRefs[off] + 1
                        return makeId(i, tok, seg.gens[off])
                    }
                    i = i + 1
                }
            }
            newSlot(obj, tok, true)
        }
    }

    /** 归还一次路径 A 引用；归零时回收槽位（幂等，非常量/已回收槽忽略）。 */
    public static func releaseConst(id: Int64): Unit {
        let i = idxOf(id)
        synchronized(mtx) {
            let seg = segAt(i)
            let off = offOf(i)
            if (i <= 0 || !seg.alive[off] || !seg.constFlags[off]) {
                return
            }
            seg.constRefs[off] = seg.constRefs[off] - 1
            if (seg.constRefs[off] > 0) {
                return
            }
            seg.alive[off] = false
            seg.objs[off] = Int64(0)
            seg.constFlags[off] = false
            seg.escapeFlags[off] = false
            seg.frozenFlags[off] = false
            seg.constRefs[off] = 0
            // 锁序固定 mtx → 分片锁；反向（持分片锁取 mtx）在本文件不存在。
            synchronized(HandleTable.stripes.mtxs[i & (FREE_STRIPES - 1)]) {
                freeOrRetire(seg, off, i)
            }
        }
    }

    /** 某槽是否属路径 A（常量）。 */
    public static func isConst(id: Int64): Bool {
        let i = idxOf(id)
        let seg = segAt(i)
        let off = offOf(i)
        if (i <= 0) {
            return false
        }
        seg.constFlags[off]
    }

    /** 某槽是否已登记为逃逸。 */
    public static func isEscaped(id: Int64): Bool {
        let i = idxOf(id)
        let seg = segAt(i)
        let off = offOf(i)
        if (i <= 0) {
            return false
        }
        seg.escapeFlags[off]
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
        HandleTable.appendWith(RuntimeEnv.current(), ctx, obj, tok)
    }

    /** 调用方已持有本线程状态（零 TLS）。 */
    public static func appendWith(rs: RuntimeState, ctx: JitContext, obj: Any, tok: UInt16): Int64 {
        let w = currentWinOf(rs)
        // 扩容触发点：保证追加后「容量 ≥ 2 × 已用数」（plan-m1 S4.3）
        let need = 2 * (w.used + 1)
        if (need > w.cap) {
            var nc = w.cap * 2
            if (nc <= 0) {
                nc = initialCapacity
            }
            if (nc < need) {
                nc = need
            }
            if (w.base + nc > capacityLimit) {
                nc = capacityLimit - w.base
            }
            if (nc < w.used + 1) {
                // 容量已到全局上限，无法再扩 ⇒ 触顶
                syncTo(ctx, rs)
                failWith(ErrCode.HANDLE_WINDOW_FULL)
            }
            w.cap = nc
        }
        if (w.base + w.used >= capacityLimit) {
            syncTo(ctx, rs)
            failWith(ErrCode.HANDLE_WINDOW_FULL)
        }
        let id = newSlotWith(rs, obj, tok, false)
        w.appendIds.add(id)
        w.used = w.used + 1
        syncTo(ctx, rs)
        id
    }

    /**
     * 世界内的宿主类实例登记（H80 的 14 分支，tag 恒 **11**）。
     *
     * 与 `pinHostObject` 的唯一差异是**窗口记账**：本函数走路径 C（计入 `windowSlots` /
     * `hwTop`，容量触顶报 16），`pinHostObject` 走路径 B（桥侧参数封送，不占窗口）。
     * 同一对象在本窗口内复用同 ID（否则每次 `as C` 都新开一槽，窗口被读操作耗尽）；
     * 去重只看**本窗口已登记的槽**——复用窗口外（含桥侧 pin）的槽会让记账与实际分配脱节。
     */
    public static func appendHostObject(ctx: JitContext, obj: Object): Int64 {
        HandleTable.appendHostObjectWith(ctx, RuntimeEnv.current(), obj)
    }

    /** 调用方已持有本线程状态（零 TLS）。 */
    public static func appendHostObjectWith(ctx: JitContext, rs: RuntimeState, obj: Object): Int64 {
        let w = currentWinOf(rs)
        var k = 0
        while (k < w.appendIds.size) {
            let id = w.appendIds[k]
            let s = idxOf(id)
            let seg = segAt(s)
            let off = offOf(s)
            if (s > 0 && seg.alive[off] && seg.gens[off] == genOf(id) && !seg.constFlags[off] &&
                seg.tags[off] == TypeToken.HOST_OBJECT) {
                match (seg.objs[off]) {
                    case old: Object =>
                        if (refEq(old, obj)) {
                            return id
                        }
                    case _ => ()
                }
            }
            k = k + 1
        }
        HandleTable.appendWith(rs, ctx, obj, TypeToken.HOST_OBJECT)
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
        // 无锁读（D3）：槽只由 owner 写、发布后内容不变；跨线程可见性由 ID 传递路径上的
        // 同步边（线程创建 / 队列 / 锁）保证。
        let seg = segAt(i)
        let off = offOf(i)
        if (i <= 0 || !seg.alive[off] || seg.gens[off] != genOf(id)) {
            None
        } else {
            Some(seg.objs[off])
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
        let seg = segAt(i)
        let off = offOf(i)
        if (!seg.alive[off] || seg.gens[off] != genOf(id)) {
            failWith(ErrCode.NULL_HANDLE)
        }
        let v = seg.objs[off]
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
        let seg = segAt(i)
        let off = offOf(i)
        if (!seg.alive[off] || seg.gens[off] != genOf(id) ||
            seg.tags[off] != TypeToken.HOST_OBJECT) {
            failWith(ErrCode.HANDLE_TYPE)
        }
        let v = seg.objs[off]
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
        let seg = segAt(i)
        let off = offOf(i)
        if (i <= 0 || !seg.alive[off] || seg.gens[off] != genOf(id)) {
            false
        } else {
            seg.tags[off] == tok
        }
    }

    /** 非抛出版本：取句柄 tag，失效 / null ⇒ 0（解释器内部的类型分派用）。 */
    public static func tagOrZero(id: Int64): UInt16 {
        if (id == 0) {
            return 0u16
        }
        let i = idxOf(id)
        let seg = segAt(i)
        let off = offOf(i)
        if (i <= 0 || !seg.alive[off] || seg.gens[off] != genOf(id)) {
            0u16
        } else {
            seg.tags[off]
        }
    }

    /** 取句柄 tag（helper H18；null → 6）。 */
    public static func tagOfHandle(id: Int64): UInt16 {
        if (id == 0) {
            failWith(ErrCode.NULL_HANDLE)
        }
        let i = idxOf(id)
        let seg = segAt(i)
        let off = offOf(i)
        if (i <= 0 || !seg.alive[off] || seg.gens[off] != genOf(id)) {
            failWith(ErrCode.NULL_HANDLE)
        }
        seg.tags[off]
    }

    // ---- 释放 / 逃逸 / 重置 ----

    /**
     * 释放（宿主显式释放逃逸句柄；表项 gen+1 后方可复用 ⇒ 旧 ID 永久失效）。
     *
     * 逃逸标记必须在此复位并把槽归还 `freeSlots`：逃逸槽的唯一归宿就是宿主 `release`，
     * 旧实现只对「未逃逸」槽归还 ⇒ 逃逸槽既不可复用也不再可达，逐次调用净泄漏。
     */
    public static func release(id: Int64): Unit {
        let i = idxOf(id)
        if (i <= 0) {
            return
        }
        let seg = segAt(i)
        let off = offOf(i)
        // 分片锁覆盖「状态复位 + 世代号 + 归还」：同槽双释放被串行化，后者见 gen 已变即返回。
        synchronized(HandleTable.stripes.mtxs[i & (FREE_STRIPES - 1)]) {
            if (seg.alive[off] && seg.gens[off] == genOf(id) && !seg.constFlags[off]) {
                seg.alive[off] = false
                seg.objs[off] = Int64(0)
                seg.escapeFlags[off] = false
                seg.frozenFlags[off] = false
                freeOrRetire(seg, off, i)
            }
        }
    }

    /** 显式归还一个逃逸句柄（桥把返回值取成宿主对象后调用；常量槽不回收）。 */
    public static func releaseEscaped(id: Int64): Unit {
        let i = idxOf(id)
        if (i <= 0) {
            return
        }
        let seg = segAt(i)
        let off = offOf(i)
        synchronized(HandleTable.stripes.mtxs[i & (FREE_STRIPES - 1)]) {
            if (!seg.alive[off] || seg.constFlags[off]) {
                return
            }
            if (seg.gens[off] != genOf(id)) {
                return
            }
            seg.alive[off] = false
            seg.objs[off] = Int64(0)
            seg.escapeFlags[off] = false
            seg.frozenFlags[off] = false
            freeOrRetire(seg, off, i)
        }
    }

    /** 路径 D：登记逃逸（窗口重置后仍可用且 ID 不变）。 */
    public static func escape(id: Int64): Unit {
        let i = idxOf(id)
        if (i <= 0) {
            return
        }
        synchronized(mtx) {
            let seg = segAt(i)
            let off = offOf(i)
            if (seg.alive[off] && seg.gens[off] == genOf(id)) {
                seg.escapeFlags[off] = true
            }
        }
    }

    /**
     * 调用结束重置窗口：窗口内**未逃逸**的槽全部释放（gen+1、可复用），逃逸槽保留。
     *
     * `hwBase` 给 ≥ 0 时按该值重建窗口（桥的口径）；给 < 0 时以表尾为起点。
     */
    public static func resetWindow(hwBase: Int64): Unit {
        HandleTable.resetWindow(RuntimeEnv.current(), hwBase)
    }

    /** 调用结束重置窗口（调用方已持有本线程状态，零 TLS）。 */
    public static func resetWindow(rs: RuntimeState, hwBase: Int64): Unit {
        let s = winStackOf(rs)
        let w = if (s.size > 0) {
            s.remove(at: s.size - 1)
        } else {
            acquireWin(rs, 1, initialCapacity)
        }
        // 逐槽取所属分片锁（而不是整段持全局 mtx）：窗口槽彼此独立，收尾是释放热点之一。
        var k = 0
        // 只释放路径 C（`append`）的槽：路径 B 的 pin 是桥侧资产，跨调用存活，
        // 由 `CallMarshal.cleanup` / 宿主归还，窗口收尾不得动它。
        while (k < w.appendIds.size) {
            let id = w.appendIds[k]
            let i = idxOf(id)
            let seg = segAt(i)
            let off = offOf(i)
            if (i > 0) {
                // 只按「代数仍匹配」释放：槽可能已被显式归还并被别的线程复用 ——
                // 盲目按索引释放会误杀新槽。
                synchronized(HandleTable.stripes.mtxs[i & (FREE_STRIPES - 1)]) {
                    if (seg.alive[off] && seg.gens[off] == genOf(id) &&
                        !seg.escapeFlags[off] && !seg.constFlags[off]) {
                        seg.alive[off] = false
                        seg.objs[off] = Int64(0)
                        freeOrRetire(seg, off, i)
                    }
                }
            }
            k = k + 1
        }
        w.pins.clear()
        w.appendIds.clear()
        // 回收对象（字段已清空），下次 openWindow 直接复用。
        recycleWin(rs, w)
        // 重入：内层窗口收尾后外层窗口原样保留（各自独立的 Win 实例）；栈空则重建环境窗口。
        if (s.size == 0) {
            let base = if (hwBase >= 0) {
                hwBase
            } else {
                totalSlots.load()
            }
            s.add(acquireWin(rs, base, initialCapacity))
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
        let w = currentWin()
        synchronized(mtx) {
            var n = 0
            while (n < ids.size) {
                let id = ids[n]
                let i = idxOf(id)
                let seg = segAt(i)
                let off = offOf(i)
                if (i > 0 && seg.alive[off] && seg.gens[off] == genOf(id) && !seg.constFlags[off]) {
                    seg.escapeFlags[off] = true
                    var k = 0
                    var removed = false
                    while (k < w.appendIds.size && !removed) {
                        if (w.appendIds[k] == id) {
                            w.appendIds.remove(at: k)
                            if (w.used > 0) {
                                w.used = w.used - 1
                            }
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

    /**
     * 释放槽位的统一收尾（**调用方持有该槽归属分片的锁**）：世代号 +1 并归还分片；
     * 到达 `GEN_MAX` 则**退休**。
     *
     * 退休是保证「标识恒正」的唯一处置：`gen = 0x8000` 会让拼装值越过 `Int64.Max`
     * ——`makeId` 的受检转换抛 `OverflowException`，若换成非受检位转换则得到负 ID，
     * 会被全库的 `id <= 0` 判空当成空句柄。退休槽保持 `alive=false` 且不进空闲表，
     * 代价是每 32767 次复用占 1 个索引位（相对 4M 目录可忽略）。
     */
    private static func freeOrRetire(seg: SlotSeg, off: Int64, i: Int64): Unit {
        if (seg.gens[off] >= GEN_MAX) {
            let _ = retiredSlots.fetchAdd(1)
            return
        }
        seg.gens[off] = seg.gens[off] + UInt16(1)
        HandleTable.stripes.lists[i & (FREE_STRIPES - 1)].add(i)
    }

    /** 归还一个索引到其归属分片（调用方已释放对该槽的独占）。 */
    private static func pushFree(i: Int64): Unit {
        let s = i & (FREE_STRIPES - 1)
        synchronized(HandleTable.stripes.mtxs[s]) {
            HandleTable.stripes.lists[s].add(i)
        }
    }

    /**
     * 取一个空闲索引：优先本线程上次命中的分片，再顺序扫描其余分片；全空返回 -1。
     * 返回时该索引已从分片摘除 ⇒ 调用方对它独占，后续写入无需加锁。
     */
    private static func popFree(): Int64 {
        HandleTable.popFreeWith(RuntimeEnv.current())
    }

    /** 调用方已持有本线程状态（零 TLS）。 */
    private static func popFreeWith(rs: RuntimeState): Int64 {
        let start = if (rs.freeHint >= 0) { rs.freeHint } else { 0 }
        var k = 0
        while (k < FREE_STRIPES) {
            let s = (start + k) & (FREE_STRIPES - 1)
            let got = synchronized(HandleTable.stripes.mtxs[s]) {
                let list = HandleTable.stripes.lists[s]
                if (list.size > 0) {
                    list.remove(at: list.size - 1)
                } else {
                    -1
                }
            }
            if (got > 0) {
                rs.freeHint = s
                return got
            }
            k = k + 1
        }
        -1
    }

    /** 表尾增长（全局 `mtx`；每 1024 槽一次，冷路径）。 */
    private static func growSlot(): Int64 {
        synchronized(mtx) {
            let idx = totalSlots.load()
            // 全局硬上限：并发窗口各自按 base 记账，可能同时越过同一上限 ⇒ 这里兜底。
            if (idx >= capacityLimit) {
                failWith(ErrCode.HANDLE_WINDOW_FULL)
            }
            let _ = ensureSegLocked(idx)
            totalSlots.store(idx + 1)
            idx
        }
    }

    /**
     * 分配一个槽并写入（路径 A/B/C 共用）。
     *
     * 索引从分片摘除后即由本线程独占（不可达、`alive=false`），故**槽写入不再持全局锁**；
     * 新 ID 尚未交给调用方，持旧 ID 的读者会被 `gens` 不匹配拒绝。
     */
    private static func newSlot(obj: Any, tok: UInt16, isConst: Bool): Int64 {
        HandleTable.newSlotWith(RuntimeEnv.current(), obj, tok, isConst)
    }

    /** 调用方已持有本线程状态（零 TLS）。 */
    private static func newSlotWith(rs: RuntimeState, obj: Any, tok: UInt16, isConst: Bool): Int64 {
        var idx = popFreeWith(rs)
        var reused = true
        if (idx <= 0) {
            reused = false
            idx = growSlot()
        }
        let seg = segAt(idx)
        let off = offOf(idx)
        seg.objs[off] = obj
        seg.tags[off] = tok
        if (!reused) {
            seg.gens[off] = 1u16
        }
        seg.alive[off] = true
        seg.constFlags[off] = isConst
        seg.constRefs[off] = if (isConst) { 1 } else { 0 }
        seg.escapeFlags[off] = false
        seg.frozenFlags[off] = false
        makeId(idx, tok, seg.gens[off])
    }

    /** 用例/宿主审计：当前活槽数。 */
    public static func liveCount(): Int64 {
        synchronized(mtx) {
            var n = 0
            var i = 1
            let top = totalSlots.load()
            while (i < top) {
                let seg = segAt(i)
                if (seg.alive[offOf(i)]) {
                    n = n + 1
                }
                i = i + 1
            }
            n
        }
    }

    /** 用例/宿主审计：累计分配过的槽位数（高水位）。 */
    public static func slotCount(): Int64 {
        totalSlots.load()
    }

    /** 用例/宿主审计：因世代号耗尽而退休的槽数（退休槽永久失效、不可复用）。 */
    public static func retiredCount(): Int64 {
        retiredSlots.load()
    }

    /** 测试专用：清空整张表并复位窗口（不用于生产路径）。 */
    public static func resetForTest(): Unit {
        synchronized(mtx) {
            // 清掉高水位内的所有段；段本身保留（地址稳定），只复位内容。
            let segs = (totalSlots.load() + SEG_SIZE - 1) >> SEG_SHIFT
            var c = 0
            while (c < segs) {
                let s = segDir[c]
                if (!refEq(s, EMPTY_SEG)) {
                    var off = 0
                    while (off < SEG_SIZE) {
                        s.objs[off] = Int64(0)
                        s.tags[off] = TypeToken.RESERVED
                        s.gens[off] = 0u16
                        s.alive[off] = false
                        s.constFlags[off] = false
                        s.constRefs[off] = 0
                        s.escapeFlags[off] = false
                        s.frozenFlags[off] = false
                        off = off + 1
                    }
                }
                c = c + 1
            }
            var st = 0
            while (st < FREE_STRIPES) {
                synchronized(HandleTable.stripes.mtxs[st]) {
                    HandleTable.stripes.lists[st].clear()
                }
                st = st + 1
            }
            retiredSlots.store(0)
            totalSlots.store(1)
            let s0 = ensureSegLocked(0)
            s0.tags[0] = TypeToken.RESERVED
        }
        // 窗口栈是线程私有的：清当前线程并重建环境窗口（其它线程的窗口不追溯）。
        let ws = winStack()
        ws.clear()
        ws.add(Win(1, initialCapacity))
    }

    /** `cell` 是否为活句柄（gen ≥ 1 ⇒ ID ≥ 2^48，与普通整数值域不交）。 */
    public static func isLiveHandle(cell: Int64): Bool {
        if (cell <= 0) {
            return false
        }
        let i = idxOf(cell)
        let seg = segAt(i)
        let off = offOf(i)
        if (i <= 0) {
            return false
        }
        seg.alive[off] && seg.gens[off] == genOf(cell)
    }

    /** `cell` → 宿主对象（活句柄）；否则按原值装箱（容器元素按 §3.2 cell 表示原样存取）。 */
    public static func cellToAny(cell: Int64): Any {
        match (getAny(cell)) {
            case Some(v) => v
            case None => cell
        }
    }

    /** 宿主对象 → `cell`（活句柄取 ID；值型按其类型装箱后由调用方解释）。 */
    /**
     * M3：把任意宿主值装进 **Any 盒**（tag=12）并返回句柄。
     *
     * 盒不可变：存进去的是什么就取什么（值型已在调用侧拷贝、引用型即共享引用）。
     * 与 `pin` 分开是因为 `pin` 按对象类型选 tag，而盒的 tag 恒为 12；载荷是 `JitAnyBox`
     * 包装对象（保证盒在容器里保持身份，见 `JitAnyBox` 的类注释）。
     */
    public static func pinAnyBox(v: Any): Int64 {
        HandleTable.pinAnyBoxWith(RuntimeEnv.current(), v)
    }

    /** 调用方已持有本线程状态（零 TLS）。 */
    public static func pinAnyBoxWith(rs: RuntimeState, v: Any): Int64 {
        // 桥侧路径 B：不占窗口、不随窗口收尾释放（由调用方归还）。
        newSlotWith(rs, JitAnyBox(v), TypeToken.ANY, false)
    }

    /**
     * **世界内**装箱（H78/H81 用）：`JitAnyBox` 走 `append` ⇒ 计入窗口容量（m3 §8 hwCap 对账）。
     *
     * 与 `pinAnyBox` 的分工：`pinAnyBox` 是**桥侧**（`CallMarshal` 的 Any 行）路径 B，不占窗口；
     * 世界内分配必须占窗口，否则 `hwTop` 记账失真、容量触顶永远不触发（T40 抓到的缺陷）。
     */
    public static func appendAnyBox(ctx: JitContext, v: Any): Int64 {
        append(ctx, JitAnyBox(v), TypeToken.ANY)
    }

    /**
     * 取 Any 盒内容；tag ≠ 12 / 失效 / **代数不符** → 8（契约类错误）。
     *
     * 代数校验与 `fetchHostObject` 同构：槽被释放并复用后，旧 ID 必须失效，不能读到新盒。
     */
    public static func fetchAnyBox(id: Int64): Any {
        let i = idxOf(id)
        let seg = segAt(i)
        let off = offOf(i)
        if (i <= 0 || !seg.alive[off] || seg.gens[off] != genOf(id) ||
            seg.tags[off] != TypeToken.ANY) {
            failWith(ErrCode.HANDLE_TYPE)
        }
        match (seg.objs[off]) {
            case b: JitAnyBox => b.value
            case _ => failWith(ErrCode.HANDLE_TYPE)
        }
    }

    /** 标记/查询 frozen（M3 §11：常量实例化登记时置位，H82 写保护判定）。 */
    public static func markFrozen(id: Int64): Unit {
        let i = idxOf(id)
        if (i <= 0) {
            return
        }
        synchronized(mtx) {
            let seg = segAt(i)
            seg.frozenFlags[offOf(i)] = true
        }
    }

    public static func isFrozen(id: Int64): Bool {
        let i = idxOf(id)
        if (i <= 0) {
            return false
        }
        segAt(i).frozenFlags[offOf(i)]
    }

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
