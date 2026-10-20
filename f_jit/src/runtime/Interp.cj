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
import std.overflow.*
import std.regex.Regex
import fountain::f_jit.base.ErrCode
import fountain::f_jit.base.LocalType
import fountain::f_jit.base.TypeToken
import fountain::f_jit.bytecode.ConstPayload
import fountain::f_jit.bytecode.DecodedInsn
import fountain::f_jit.bytecode.FuncEntry
import fountain::f_jit.bytecode.InsnDecoder
import fountain::f_jit.bytecode.LoadedUnit
import fountain::f_jit.bytecode.LocalTypes

/**
 * 解释器帧 —— design-m1 §5.3.6、plan-m1 S4.20。
 *
 * 与 §3.1 的机器帧同构：`locals`（参数即 `locals[0..nargs-1]`）+ 操作数栈；**帧尺寸由
 * §3.1 公式在编译期算出**，解释器按同一公式分配（16 字节对齐）。
 */
internal class InterpFrame {
    internal var locals: Array<Int64>
    internal let stack: ArrayList<Int64> = ArrayList<Int64>()
    internal let fnId: Int64

    internal init(fnId: Int64, nLocals: Int64) {
        this.fnId = fnId
        this.locals = Array<Int64>(nLocals, repeat: 0)
    }

    internal func push(v: Int64): Unit {
        this.stack.add(v)
    }

    internal func pop(): Int64 {
        this.stack.remove(at: this.stack.size - 1)
    }

    internal func top(): Int64 {
        this.stack[this.stack.size - 1]
    }

    internal func at(i: Int64): Int64 {
        this.stack[i]
    }
}

/**
 * 解释器（**语义基准** I7）—— design-m1 §5.3.6、plan-m1 S4.20–S4.22。
 *
 * 权威 = `doc/jit-bytecode-m1.md` §5（ISA）、§11.9（语义组）、§0（fail-fast 冻结）：
 *
 * - **错误即终止（fail-fast）**：任何错误码写入 ctx 错误槽的瞬间，本次调用语义结束——
 *   自错误点起的剩余指令不再执行、操作数栈不再消费，控制收敛到唯一出口；
 * - `CALL_HELPER` / `CALL_HELPER_V` 由汇编器自动尾随 `CHECK_ERR` ⇒ 解释器在 helper 调用后
 *   同样立即短路（`CALL_HELPER_NC` 不检查）；
 * - `CALL_FUNC` 与调用方**共窗口**（§5 0x78），`CALL_CLOSURE` 走闭包对象的 `fnId`；
 * - 常量 / 目录 / 类型表**只读**（design §5.3.6 实现约束）。
 */
public class Interp {
    private let unit: LoadedUnit
    /** 常量句柄（懒登记；常量经 `pinConst` ⇒ 只读，写入 → 20）。 */
    private var constIds: Array<Int64>
    private var retCell: Int64 = 0

    public init(unit: LoadedUnit) {
        this.unit = unit
        this.constIds = Array<Int64>(unit.consts.size, repeat: 0)
    }

    /** 复用已登记的常量句柄（避免每次调用重复 pin；句柄生命周期由调用方持有）。 */
    public init(unit: LoadedUnit, constIds: Array<Int64>) {
        this.unit = unit
        this.constIds = constIds
    }

    /** 已登记的路径 A 句柄（值型常量为 0；调用方负责 releaseConst）。 */
    public func pinnedConstIds(): Array<Int64> {
        this.constIds
    }

    /** 帧尺寸信息 `(nLocals, maxStack)`（§3.1）。 */
    public func frameInfo(fnId: UInt32): (Int64, Int64) {
        let e = this.unit.dir.get(fnId)
        (Int64(e.nLocals), Int64(e.maxStack))
    }

    /** 帧字节尺寸：`32 + 8*nLocals + 8*maxStack + 8` 向上取整到 16 的倍数（§3.1）。 */
    public func frameSize(fnId: UInt32): Int64 {
        let e = this.unit.dir.get(fnId)
        let raw = 32 + 8 * Int64(e.nLocals) + 8 * Int64(e.maxStack) + 8
        align16(raw)
    }

    /** 16 字节对齐后的帧尺寸（两后端共享，§12.2）。 */
    public static func align16(v: Int64): Int64 {
        if ((v % 16) == 0) {
            v
        } else {
            v + (16 - (v % 16))
        }
    }

    /**
     * 解释执行一个函数（语义基准入口）。
     *
     * `args` 即 `locals[0..nargs-1]`；返回**结果 cell**（I5：失败时槽已写码，返回值未定义）。
     */
    public func run(fnId: UInt32, args: Array<Int64>, ctx: JitContext): Int64 {
        let e = this.unit.dir.get(fnId)
        let f = InterpFrame(Int64(fnId), Int64(e.nLocals))
        var i: Int64 = 0
        while (i < args.size && i < Int64(e.nLocals)) {
            f.locals[i] = args[i]
            i = i + 1
        }
        let r = this.exec(e, f, ctx)
        this.retCell = r
        r
    }

    /** 最近一次 `run` 的结果 cell。 */
    public func result(): Int64 {
        this.retCell
    }

    /**
     * 常量索引 → cell（句柄型登记为路径 A 常量；Int64/F64 直接返回位值）。
     *
     * `PUSH_KH` 只引用句柄型常量；非句柄常量（容器常量内部的元素）若也走 `pin`，
     * `tokenOf` 会以 19 拒绝——故此处先按值型返回。
     */
    public func constHandle(idx: Int64): Int64 {
        let obj = this.unit.consts.instanceAt(idx)
        match (obj) {
            case v: Int64 => return v
            case v: Float64 =>
                let bits = v.toBits()
                if (bits >= 0x8000000000000000u64) {
                    return Int64(bits - 0x8000000000000000u64) + Int64.Min
                }
                return Int64(bits)
            case _ => ()
        }
        if (this.constIds[idx] == 0) {
            let wrapped = wrapConst(idx, obj)
            let hid = HandleTable.pinConst(wrapped)
            // M3 S2.5：JSON 常量（kind 11）登记即 frozen —— H82 写保护与「读/拆箱传播」的起点
            match (this.unit.consts.get(idx)) {
                case ConstPayload.PJson(_) => HandleTable.markFrozen(hid)
                case _ => ()
            }
            this.constIds[idx] = hid
        }
        this.constIds[idx]
    }

    /** kind 10（Regex）的常量按 `(Regex, flags)` 承载，其余原样（§11.5）。 */
    private func wrapConst(idx: Int64, obj: Any): Any {
        match (this.unit.consts.get(idx)) {
            case ConstPayload.PRegex(_, flags) =>
                match (obj) {
                    case re: Regex => JitRegex(re, flags)
                    case _ => obj
                }
            case _ => obj
        }
    }

    private func typesOf(fnId: UInt32): LocalTypes {
        var i: Int64 = 0
        while (i < this.unit.dir.size) {
            if (this.unit.dir.at(i).fnId == fnId) {
                return this.unit.types[i]
            }
            i = i + 1
        }
        this.unit.types[0]
    }

    // ========================================================================
    // 指令循环
    // ========================================================================

    private func exec(e: FuncEntry, f: InterpFrame, ctx: JitContext): Int64 {
        let code = this.unit.code
        var pc = Int64(e.codeOff)
        let end = Int64(e.codeOff) + Int64(e.codeLen)
        while (pc < end) {
            let insn = InsnDecoder.decode(code, pc)
            var next = pc + insn.size
            let op = insn.op

            // ---- 0x00–0x0F 控制 / 杂项 ----
            if (op == 0x00u8 || op == 0x01u8 || op == 0x02u8 || op == 0x06u8 || op == 0x07u8) {
                () // NOP / TRAP / BREAKPOINT / CHECK_ERR_NC / STACK_GUARD（解释器无机器栈余量概念）
            } else if (op == 0x03u8) {
                ctx.site = Int64(InsnDecoder.i32(insn, 0))
            } else if (op == 0x04u8) {
                if (ctx.errCode != 0) {
                    return bail(ctx, f, 0)
                }
            } else if (op == 0x05u8) {
                let k = Int64(InsnDecoder.u8(insn, 0))
                ctx.errCode = k
                return bail(ctx, f, 0)
            } else if (op >= 0x10u8 && op <= 0x1Cu8) {
                constOrStack(op, insn, f, ctx)
            } else if (op >= 0x20u8 && op <= 0x26u8) {
                localOp(op, insn, f, ctx)
            } else if (op >= 0x30u8 && op <= 0x08 && false) {
                ()
            } else if (op >= 0x30u8 && op <= 0x3Bu8) {
                intOp(op, f, ctx)
            } else if (op >= 0x40u8 && op <= 0x4Du8) {
                floatOp(op, f)
            } else if (op >= 0x50u8 && op <= 0x6Eu8) {
                cmpOp(op, f, ctx)
            } else if (op >= 0x70u8 && op <= 0x7Fu8) {
                let jumped = ctrlOp(op, insn, pc, f, ctx, e)
                match (jumped) {
                    case Some(t) =>
                        if (t < 0) {
                            return this.retCell
                        }
                        next = t
                    case None => return bail(ctx, f, 0)
                }
            } else if (op >= 0x80u8 && op <= 0x89u8) {
                typeOp(op, insn, f, ctx)
            } else if (op >= 0x90u8 && op <= 0xBFu8) {
                helperOp(op, insn, f, ctx)
            } else {
                ctx.errCode = ErrCode.NOT_IMPL
                return bail(ctx, f, 0)
            }

            // fail-fast：错误槽一被写码，本次调用语义即结束（§0）
            if (ctx.errCode != 0) {
                return bail(ctx, f, 0)
            }
            pc = next
        }
        // 函数体跑完而没有 RET ⇒ 视作 RET_VOID（唯一出口）
        bail(ctx, f, 0)
        0
    }

    /** 失败收敛：错误槽已写码时做**单次转储**，然后走唯一出口。 */
    private func bail(ctx: JitContext, f: InterpFrame, _: Int64): Int64 {
        if (ctx.errCode > 0) {
            DbgDump.writeOnce(ctx, f.fnId, f.locals)
        }
        this.retCell = 0
        0
    }

    // ---- 0x10–0x1F 常量 / 栈 ----

    private func constOrStack(op: UInt8, insn: DecodedInsn, f: InterpFrame, ctx: JitContext): Unit {
        match (op) {
            case 0x10u8 => f.push(Int64(Int8(InsnDecoder.u8(insn, 0))))
            case 0x11u8 => f.push(Int64(InsnDecoder.i32(insn, 0)))
            case 0x12u8 => f.push(InsnDecoder.i64(insn, 0))
            case 0x13u8 => f.push(InsnDecoder.i64(insn, 0))
            case 0x14u8 => f.push(if (InsnDecoder.u8(insn, 0) == 0u8) { 0 } else { 1 })
            case 0x15u8 => f.push(0)
            case 0x16u8 => f.push(this.constHandle(Int64(InsnDecoder.u16(insn, 0))))
            case 0x17u8 => f.push(f.top())
            case 0x18u8 =>
                let b = f.at(f.stack.size - 1)
                let a = f.at(f.stack.size - 2)
                f.push(a)
                f.push(b)
            case 0x19u8 => f.pop()
            case 0x1Au8 => f.pop(); f.pop()
            case 0x1Bu8 =>
                let b = f.pop()
                let a = f.pop()
                f.push(b)
                f.push(a)
            case 0x1Cu8 =>
                let n = Int64(InsnDecoder.u8(insn, 0))
                f.push(f.at(f.stack.size - 1 - n))
            case _ => ()
        }
    }

    // ---- 0x20–0x2F 局部变量 ----

    private func localOp(op: UInt8, insn: DecodedInsn, f: InterpFrame, ctx: JitContext): Unit {
        match (op) {
            case 0x20u8 => f.push(f.locals[Int64(InsnDecoder.u16(insn, 0))])
            case 0x21u8 => f.locals[Int64(InsnDecoder.u16(insn, 0))] = f.pop()
            case 0x22u8 => f.push(f.locals[0])
            case 0x23u8 => f.push(f.locals[1])
            case 0x24u8 => f.push(f.locals[2])
            case 0x25u8 => f.push(f.locals[3])
            case 0x26u8 =>
                // LOAD_CAP：locals[0] 是闭包句柄 ⇒ 经 H56 取捕获
                let idx = Int64(InsnDecoder.u16(insn, 0))
                let r = invokeHelper(ctx, Int64(HelperId.CLOSURE_CAP), [f.locals[0], idx])
                f.push(r)
            case _ => ()
        }
    }

    // ---- 0x30–0x3B 整型（溢出检查 / 除零 / 求余四象限，§5）----

    private func intOp(op: UInt8, f: InterpFrame, ctx: JitContext): Unit {
        let one = op == 0x35u8 || op == 0x36u8 || op == 0x3Au8 || op == 0x3Bu8
        let b = if (one) { 0 } else { f.pop() }
        let a = f.pop()
        match (op) {
            case 0x30u8 => f.push(checked(a.checkedAdd(b), ctx))
            case 0x31u8 => f.push(checked(a.checkedSub(b), ctx))
            case 0x32u8 => f.push(checked(a.checkedMul(b), ctx))
            case 0x33u8 =>
                if (b == 0) {
                    ctx.errCode = ErrCode.DIV_ZERO
                    f.push(0)
                } else if (a == Int64.Min && b == -1) {
                    ctx.errCode = ErrCode.OVERFLOW_I64
                    f.push(0)
                } else {
                    f.push(a / b) // 向零截断
                }
            case 0x34u8 =>
                if (b == 0) {
                    ctx.errCode = ErrCode.MOD_ZERO
                    f.push(0)
                } else if (a == Int64.Min && b == -1) {
                    f.push(0) // INT_MIN % -1 → 0，不报溢出（§5 / v0.18.24）
                } else {
                    f.push(a % b) // 符号随被除数
                }
            case 0x35u8 => f.push(checked((0 - a).checkedSub(0), ctx))
            case 0x36u8 =>
                if (a == Int64.Min) {
                    ctx.errCode = ErrCode.OVERFLOW_I64
                    f.push(0)
                } else if (a < 0) {
                    f.push(0 - a)
                } else {
                    f.push(a)
                }
            case 0x37u8 => f.push(if (a < b) { a } else { b })
            case 0x38u8 => f.push(if (a > b) { a } else { b })
            case 0x39u8 => f.push(a + b) // 显式无检查
            case 0x3Au8 => f.push(clz64(a))
            case 0x3Bu8 => f.push(popcnt64(a))
            case _ => f.push(0)
        }
    }

    private func checked(v: ?Int64, ctx: JitContext): Int64 {
        match (v) {
            case Some(x) => x
            case None =>
                ctx.errCode = ErrCode.OVERFLOW_I64
                0
        }
    }

    internal static func clz64(v: Int64): Int64 {
        if (v == 0) {
            return 64
        }
        let u = UInt64(v)
        var n: Int64 = 0
        var mask: UInt64 = 0x8000000000000000u64
        while ((u & mask) == 0u64) {
            n = n + 1
            mask = mask >> 1
        }
        n
    }

    internal static func popcnt64(v: Int64): Int64 {
        let u = UInt64(v)
        var n: Int64 = 0
        var i: Int64 = 0
        while (i < 64) {
            if (((u >> UInt64(i)) & 1u64) != 0u64) {
                n = n + 1
            }
            i = i + 1
        }
        n
    }

    // ---- 0x40–0x4D 浮点（NaN 规范化，§11.3）----

    private func floatOp(op: UInt8, f: InterpFrame): Unit {
        let one = op == 0x45u8 || op == 0x46u8 || op == 0x49u8 || op == 0x4Au8 || op == 0x4Bu8 ||
            op == 0x4Cu8 || op == 0x4Du8
        let bRaw = if (one) { 0 } else { f.pop() }
        let aRaw = f.pop()
        let a = Float64.fromBits(toBits(aRaw))
        let b = Float64.fromBits(toBits(bRaw))
        match (op) {
            case 0x40u8 => f.push(fromBits(canon(a + b).toBits()))
            case 0x41u8 => f.push(fromBits(canon(a - b).toBits()))
            case 0x42u8 => f.push(fromBits(canon(a * b).toBits()))
            case 0x43u8 => f.push(fromBits(canon(a / b).toBits())) // ÷0 ⇒ ±Inf，不报错
            case 0x44u8 =>
                if (b == 0.0) {
                    f.push(0)
                    failWith(ErrCode.DIV_ZERO)
                }
                f.push(fromBits(canon(a / b).toBits()))
            case 0x45u8 => f.push(fromBits((-a).toBits()))
            case 0x46u8 => f.push(fromBits((if (a < 0.0) { 0.0 - a } else { a }).toBits()))
            case 0x47u8 => f.push(fromBits(minF(a, b).toBits()))
            case 0x48u8 => f.push(fromBits(maxF(a, b).toBits()))
            case 0x49u8 => f.push(fromBits(canon(a ** 0.5).toBits()))
            case 0x4Au8 => f.push(floorF(a))
            case 0x4Bu8 => f.push(ceilF(a))
            case 0x4Cu8 => f.push(truncF(a))
            case 0x4Du8 => f.push(roundF(a))
            case _ => f.push(0)
        }
    }

    /** cell（补码 Int64）→ 位模式 UInt64（负数按补码折算，不做数值转换）。 */
    internal static func toBits(v: Int64): UInt64 {
        if (v < 0) {
            UInt64(v - Int64.Min) + 0x8000000000000000u64
        } else {
            UInt64(v)
        }
    }

    /** 位模式 UInt64 → cell（补码 Int64）。 */
    internal static func fromBits(b: UInt64): Int64 {
        if (b >= 0x8000000000000000u64) {
            Int64(b - 0x8000000000000000u64) + Int64.Min
        } else {
            Int64(b)
        }
    }

    /** NaN 规范化（§11.3）：任何 NaN 收敛到同一位模式 `0x7FF8000000000000`。 */
    internal static func canon(v: Float64): Float64 {
        if (isNanBits(v.toBits())) {
            Float64.fromBits(CANON_NAN)
        } else {
            v
        }
    }

    /** 规范 NaN 位模式（§11.3）。 */
    public static const CANON_NAN: UInt64 = 0x7FF8000000000000u64

    internal static func isNanBits(bits: UInt64): Bool {
        ((bits >> 52) & 0x7FFu64) == 0x7FFu64 && (bits & 0x000FFFFFFFFFFFFFu64) != 0u64
    }

    internal static func minF(a: Float64, b: Float64): Float64 {
        if (isNanBits(a.toBits()) || isNanBits(b.toBits())) {
            return Float64.fromBits(CANON_NAN)
        }
        if (a < b) { a } else { b }
    }

    internal static func maxF(a: Float64, b: Float64): Float64 {
        if (isNanBits(a.toBits()) || isNanBits(b.toBits())) {
            return Float64.fromBits(CANON_NAN)
        }
        if (a > b) { a } else { b }
    }

    // ---- 0x50–0x6E 比较 / 逻辑 / 位 ----

    private func cmpOp(op: UInt8, f: InterpFrame, ctx: JitContext): Unit {
        let one = op == 0x5Eu8 || op == 0x65u8
        let b = if (one) { 0 } else { f.pop() }
        let a = if (one && op == 0x65u8) { 0 } else { if (one) { f.pop() } else { f.pop() } }
        match (op) {
            case 0x50u8 => f.push(if (a < b) { -1 } else { if (a > b) { 1 } else { 0 } })
            case 0x51u8 =>
                let x = Float64.fromBits(toBits(a))
                let y = Float64.fromBits(toBits(b))
                f.push(if (x < y) { -1 } else { if (x > y) { 1 } else { 0 } })
            case 0x52u8 => f.push(if (a == b) { 1 } else { 0 })
            case 0x53u8 => f.push(if (a != b) { 1 } else { 0 })
            case 0x54u8 => f.push(if (a < b) { 1 } else { 0 })
            case 0x55u8 => f.push(if (a <= b) { 1 } else { 0 })
            case 0x56u8 => f.push(if (a > b) { 1 } else { 0 })
            case 0x57u8 => f.push(if (a >= b) { 1 } else { 0 })
            case 0x58u8 =>
                let x = Float64.fromBits(toBits(a))
                let y = Float64.fromBits(toBits(b))
                f.push(if (x == y) { 1 } else { 0 }) // NaN 恒 false
            case 0x59u8 =>
                let x = Float64.fromBits(toBits(a))
                let y = Float64.fromBits(toBits(b))
                f.push(if (x != y) { 1 } else { 0 }) // NaN ≠ 任意 ⇒ true
            case 0x5Au8 =>
                let x = Float64.fromBits(toBits(a))
                let y = Float64.fromBits(toBits(b))
                f.push(if (x < y) { 1 } else { 0 })
            case 0x5Bu8 =>
                let x = Float64.fromBits(toBits(a))
                let y = Float64.fromBits(toBits(b))
                f.push(if (x <= y) { 1 } else { 0 })
            case 0x5Cu8 =>
                let x = Float64.fromBits(toBits(a))
                let y = Float64.fromBits(toBits(b))
                f.push(if (x > y) { 1 } else { 0 })
            case 0x5Du8 =>
                let x = Float64.fromBits(toBits(a))
                let y = Float64.fromBits(toBits(b))
                f.push(if (x >= y) { 1 } else { 0 })
            case 0x5Eu8 => f.push(if (a == 0) { 1 } else { 0 })
            case 0x5Fu8 => f.push(if (a != 0 && b != 0) { 1 } else { 0 })
            case 0x60u8 => f.push(if (a != 0 || b != 0) { 1 } else { 0 })
            case 0x61u8 => f.push(if ((a != 0) != (b != 0)) { 1 } else { 0 })
            case 0x62u8 => f.push(a & b)
            case 0x63u8 => f.push(a | b)
            case 0x64u8 => f.push(a ^ b)
            case 0x65u8 => f.push(0 - a - 1)
            case 0x66u8 => f.push(a << (b & 63)) // 取低 6 位（§9 附则 2）
            case 0x67u8 => f.push(a >> (b & 63))
            case 0x68u8 => f.push(fromBits(toBits(a) >> UInt64(b & 63)))
            case 0x69u8 => f.push(if (a == b) { 1 } else { 0 })
            case 0x6Au8 => f.push(if (a != b) { 1 } else { 0 })
            case 0x6Bu8 => f.push(invokeHelper(ctx, Int64(HelperId.HS_CMP), [a, b]))
            case 0x6Cu8 => f.push(invokeHelper(ctx, Int64(HelperId.HD_CMP), [a, b]))
            case 0x6Du8 => f.push(invokeHelper(ctx, Int64(HelperId.HT_CMP), [a, b]))
            case 0x6Eu8 => f.push(invokeHelper(ctx, Int64(HelperId.HDUR_CMP), [a, b]))
            case _ => f.push(0)
        }
    }

    // ---- 0x70–0x7F 控制流与调用 ----

    /**
     * 返回 `Some(目标)` = 下一条指令位置；`Some(-1)` = 已 `RET`（走唯一出口）；
     * `None` = 已写错误码（fail-fast 收敛）。
     */
    private func ctrlOp(
        op: UInt8,
        insn: DecodedInsn,
        pc: Int64,
        f: InterpFrame,
        ctx: JitContext,
        e: FuncEntry
    ): ?Int64 {
        match (op) {
            case 0x70u8 => Some(InsnDecoder.rel32(insn, pc))
            case 0x71u8 =>
                let c = f.pop()
                if (c == 0) { Some(InsnDecoder.rel32(insn, pc)) } else { Some(pc + insn.size) }
            case 0x72u8 =>
                let c = f.pop()
                if (c != 0) { Some(InsnDecoder.rel32(insn, pc)) } else { Some(pc + insn.size) }
            case 0x74u8 =>
                // LOOP_BACK：回边 = 安全点（interrupt_poll）+ 跳（§5）
                invokeHelper(ctx, Int64(HelperId.INTERRUPT_POLL), [])
                if (ctx.errCode != 0) {
                    return None
                }
                Some(InsnDecoder.rel32(insn, pc))
            case 0x75u8 =>
                let hid = Int64(InsnDecoder.u16(insn, 0))
                let argc = Int64(InsnDecoder.u8(insn, 2))
                let args = popArgs(f, argc)
                let r = invokeHelper(ctx, hid, args)
                f.push(r)
                Some(pc + insn.size)
            case 0x76u8 =>
                let hid = Int64(InsnDecoder.u16(insn, 0))
                let argc = Int64(InsnDecoder.u8(insn, 2))
                let args = popArgs(f, argc)
                let r = invokeHelper(ctx, hid, args)
                f.push(r)
                Some(pc + insn.size)
            case 0x77u8 =>
                let hid = Int64(InsnDecoder.u16(insn, 0))
                let argc = Int64(InsnDecoder.u8(insn, 2))
                let args = popArgs(f, argc)
                invokeHelper(ctx, hid, args)
                Some(pc + insn.size)
            case 0x78u8 =>
                let fid = InsnDecoder.u16(insn, 0)
                let argc = Int64(InsnDecoder.u8(insn, 2))
                let target = this.unit.dir.find(UInt32(fid))
                match (target) {
                    case Some(te) =>
                        if (Int64(te.nargs) != argc) {
                            ctx.errCode = ErrCode.ARG_MISMATCH
                            return None
                        }
                        let args = popArgs(f, argc)
                        let r = this.run(UInt32(fid), args, ctx) // 共窗口
                        if (ctx.errCode != 0) {
                            return None
                        }
                        f.push(r)
                        Some(pc + insn.size)
                    case None =>
                        ctx.errCode = ErrCode.ARG_MISMATCH
                        None
                }
            case 0x79u8 =>
                // CALL_HOST：栈 `[h_fn, a1..an]`（h_fn 栈底）；与机器码共用 H63（m2 §5）。
                let argc = Int64(InsnDecoder.u8(insn, 0))
                let args = popArgs(f, argc + 1)
                let r = invokeHelper(ctx, Int64(HelperId.HOST_CALL_TRAMPOLINE), args)
                if (ctx.errCode != 0) {
                    return None
                }
                f.push(r)
                Some(pc + insn.size)
            case 0x7Au8 =>
                ctx.errCode = ErrCode.NOT_IMPL // HW_OPEN：M1 未启用
                None
            case 0x7Bu8 => Some(pc + insn.size) // HW_CLOSE
            case 0x7Cu8 =>
                this.retCell = f.pop()
                Some(-1)
            case 0x7Du8 =>
                this.retCell = 0
                Some(-1)
            case 0x7Eu8 =>
                this.retCell = 0
                Some(-1)
            case 0x7Fu8 =>
                let argc = Int64(InsnDecoder.u8(insn, 0))
                let args = popArgs(f, argc)
                let ch = f.pop()
                let c = HandleTable.fetchClosure(ch)
                let r = this.runClosure(UInt32(c.fnId), ch, args, ctx)
                if (ctx.errCode != 0) {
                    return None
                }
                f.push(r)
                Some(pc + insn.size)
            case _ =>
                ctx.errCode = ErrCode.NOT_IMPL
                None
        }
    }

    private func runClosure(fnId: UInt32, ch: Int64, args: Array<Int64>, ctx: JitContext): Int64 {
        match (this.unit.dir.find(fnId)) {
            case Some(e) =>
                var locals = Array<Int64>(Int64(e.nLocals), repeat: 0)
                locals[0] = ch
                var i: Int64 = 0
                while (i < args.size && (i + 1) < Int64(e.nLocals)) {
                    locals[i + 1] = args[i]
                    i = i + 1
                }
                let f = InterpFrame(Int64(fnId), Int64(e.nLocals))
                f.locals = locals
                let r = this.exec(e, f, ctx)
                r
            case None =>
                ctx.errCode = ErrCode.ARG_MISMATCH
                0
        }
    }

    /** 弹出 `argc` 个实参：`args[0]` 是**最深**的那个（§6 ABI）。 */
    private func popArgs(f: InterpFrame, argc: Int64): Array<Int64> {
        var out = Array<Int64>(argc, repeat: 0)
        var i = argc - 1
        while (i >= 0) {
            out[i] = f.pop()
            i = i - 1
        }
        out
    }

    // ---- 0x80–0x89 类型 / 转换 / 显式错误 ----

    private func typeOp(op: UInt8, insn: DecodedInsn, f: InterpFrame, ctx: JitContext): Unit {
        match (op) {
            case 0x80u8 =>
                let tok = UInt16(InsnDecoder.u16(insn, 0))
                let mode = InsnDecoder.u8(insn, 2)
                let v = f.pop()
                if (!HandleTable.isType(v, tok)) {
                    if (mode == 1u8) {
                        ctx.errCode = ErrCode.DEOPT
                    } else {
                        ctx.errCode = ErrCode.BAD_CAST
                    }
                    f.push(0)
                } else {
                    f.push(v)
                }
            case 0x81u8 =>
                let mode = InsnDecoder.u8(insn, 0)
                let bits = f.pop()
                let v = Float64.fromBits(toBits(bits))
                if (isNanBits(v.toBits()) || v >= Float64(9223372036854775807.0) ||
                    v <= Float64(-9223372036854775808.0)) {
                    if (mode == 1u8) {
                        ctx.errCode = ErrCode.DEOPT
                    } else {
                        ctx.errCode = ErrCode.FP_INVALID
                    }
                    f.push(0)
                } else {
                    f.push(truncF(v))
                }
            case 0x82u8 =>
                let a = f.pop()
                f.push(fromBits(Float64(a).toBits()))
            case 0x83u8 =>
                let tok = UInt16(InsnDecoder.u16(insn, 0))
                let v = f.pop()
                f.push(if (HandleTable.isType(v, tok)) { 1 } else { 0 })
            case 0x84u8 =>
                let tok = UInt16(InsnDecoder.u16(insn, 0))
                let mode = InsnDecoder.u8(insn, 2)
                let v = f.top()
                if (!HandleTable.isType(v, tok)) {
                    if (mode == 1u8) {
                        ctx.errCode = ErrCode.DEOPT
                    } else {
                        ctx.errCode = ErrCode.HANDLE_TYPE
                    }
                }
            case 0x85u8 =>
                let code = InsnDecoder.u8(insn, 0)
                ctx.errCode = ErrCode.EXPLICIT // 源语言 throw；具体码记在 site 附加表
                let unused = code
                let unused2 = unused
            case 0x86u8 =>
                let code = Int64(InsnDecoder.u8(insn, 0))
                let c = f.pop()
                if (c == 0) {
                    ctx.errCode = code
                }
            case 0x87u8 => ctx.errCode = Int64(InsnDecoder.u8(insn, 0))
            case 0x88u8 =>
                let mode = InsnDecoder.u8(insn, 0)
                if (f.top() == 0) {
                    if (mode == 1u8) {
                        ctx.errCode = ErrCode.DEOPT
                    } else {
                        ctx.errCode = ErrCode.NULL_HANDLE
                    }
                }
            case 0x89u8 =>
                let v = f.pop()
                f.push(invokeHelper(ctx, 18, [v]))
            case _ => ()
        }
    }

    // ---- 0x90–0xBF 走 helper 的指令 ----

    private func helperOp(op: UInt8, insn: DecodedInsn, f: InterpFrame, ctx: JitContext): Unit {
        match (op) {
            // 0x90–0x9E 容器 / 值提取 / 数值转换
            case 0x90u8 =>
                let h = f.pop()
                let tag = HandleTable.tagOrZero(h)
                let hid = if (tag == TypeToken.LIST) { 1 } else { if (tag == TypeToken.MAP) { 3 } else { 7 } }
                f.push(invokeHelper(ctx, hid, [h]))
            case 0x91u8 =>
                let i = f.pop()
                let h = f.pop()
                f.push(invokeHelper(ctx, 2, [h, i]))
            case 0x92u8 =>
                let k = f.pop()
                let h = f.pop()
                f.push(invokeHelper(ctx, 4, [h, k]))
            case 0x93u8 =>
                let d = f.pop()
                let k = f.pop()
                let h = f.pop()
                f.push(invokeHelper(ctx, 5, [h, k, d]))
            case 0x94u8 =>
                let k = f.pop()
                let h = f.pop()
                f.push(invokeHelper(ctx, 6, [h, k]))
            case 0x95u8 =>
                let i = f.pop()
                let h = f.pop()
                f.push(invokeHelper(ctx, 8, [h, i]))
            case 0x96u8 =>
                let fld = Int64(InsnDecoder.u8(insn, 0))
                let h = f.pop()
                f.push(invokeHelper(ctx, 14, [h, fld]))
            case 0x97u8 =>
                let h = f.pop()
                f.push(invokeHelper(ctx, 16, [h]))
            case 0x98u8 =>
                let h = f.pop()
                f.push(invokeHelper(ctx, 12, [h]))
            case 0x99u8 =>
                let h = f.pop()
                f.push(invokeHelper(ctx, 18, [h]))
            case 0x9Au8 =>
                let closed = f.pop()
                let step = f.pop()
                let endV = f.pop()
                let start = f.pop()
                f.push(invokeHelper(ctx, 41, [start, endV, step, closed]))
            case 0x9Bu8 =>
                let v = f.pop()
                let h = f.pop()
                f.push(invokeHelper(ctx, 42, [h, v]))
            case 0x9Cu8 =>
                let src = InsnDecoder.u8(insn, 0)
                let v = f.pop()
                f.push(invokeHelper(ctx, if (src == 0u8) { 28 } else { 29 }, [v]))
            case 0x9Du8 =>
                let mode = InsnDecoder.u8(insn, 0)
                let h = f.pop()
                let r = invokeHelper(ctx, 30, [h])
                if (ctx.errCode == ErrCode.DEC_RANGE && mode == 1u8) {
                    ctx.errCode = ErrCode.DEOPT
                }
                f.push(r)
            case 0x9Eu8 =>
                let h = f.pop()
                f.push(invokeHelper(ctx, 31, [h]))
            // 0xA0–0xAF 分配 / 变更区
            case 0xA0u8 => f.push(invokeHelper(ctx, 70, []))
            case 0xA1u8 =>
                let cell = f.pop()
                let h = f.pop()
                f.push(invokeHelper(ctx, 43, [h, cell]))
            case 0xA2u8 => f.push(invokeHelper(ctx, 71, []))
            case 0xA3u8 =>
                let v = f.pop()
                let k = f.pop()
                let h = f.pop()
                f.push(invokeHelper(ctx, 44, [h, k, v]))
            case 0xA4u8 =>
                let b = f.pop()
                let a = f.pop()
                f.push(invokeHelper(ctx, 32, [a, b]))
            case 0xA5u8 =>
                let b = f.pop()
                let a = f.pop()
                f.push(invokeHelper(ctx, 24, [a, b]))
            case 0xA6u8 =>
                let b = f.pop()
                let a = f.pop()
                f.push(invokeHelper(ctx, 25, [a, b]))
            case 0xA7u8 =>
                let b = f.pop()
                let a = f.pop()
                f.push(invokeHelper(ctx, 26, [a, b]))
            case 0xA8u8 =>
                let b = f.pop()
                let a = f.pop()
                f.push(invokeHelper(ctx, 27, [a, b]))
            case 0xABu8 =>
                let cell = f.pop()
                let i = f.pop()
                let h = f.pop()
                f.push(invokeHelper(ctx, 45, [h, i, cell]))
            case 0xACu8 =>
                let cell = f.pop()
                let i = f.pop()
                let h = f.pop()
                f.push(invokeHelper(ctx, 46, [h, i, cell]))
            case 0xADu8 =>
                let i = f.pop()
                let h = f.pop()
                f.push(invokeHelper(ctx, 47, [h, i]))
            case 0xAEu8 =>
                let k = f.pop()
                let h = f.pop()
                f.push(invokeHelper(ctx, 48, [h, k]))
            case 0xAFu8 =>
                let h = f.pop()
                f.push(invokeHelper(ctx, 49, [h]))
            // 0xB0–0xBF 时间 / 文本化 / 正则 / 迭代
            case 0xB0u8 =>
                let u = f.pop()
                let d = f.pop()
                f.push(invokeHelper(ctx, 34, [d, u]))
            case 0xB1u8 =>
                let u = f.pop()
                let d = f.pop()
                f.push(invokeHelper(ctx, 35, [d, u]))
            case 0xB2u8 =>
                let b = f.pop()
                let a = f.pop()
                f.push(invokeHelper(ctx, 36, [a, b]))
            case 0xB3u8 =>
                let b = f.pop()
                let a = f.pop()
                f.push(invokeHelper(ctx, 37, [a, b]))
            case 0xB4u8 =>
                let k = f.pop()
                let d = f.pop()
                f.push(invokeHelper(ctx, 38, [d, k]))
            case 0xB5u8 =>
                let k = f.pop()
                let d = f.pop()
                f.push(invokeHelper(ctx, 39, [d, k]))
            case 0xB6u8 =>
                let d = f.pop()
                f.push(invokeHelper(ctx, 40, [d]))
            case 0xB7u8 =>
                let t = Int64(InsnDecoder.u8(insn, 0))
                let v = f.pop()
                f.push(invokeHelper(ctx, 33, [v, t]))
            case 0xB8u8 =>
                let b = f.pop()
                let a = f.pop()
                let h = f.pop()
                f.push(invokeHelper(ctx, 50, [h, a, b]))
            case 0xB9u8 =>
                let nw = f.pop()
                let old = f.pop()
                let h = f.pop()
                f.push(invokeHelper(ctx, 51, [h, old, nw]))
            case 0xBAu8 =>
                let s = f.pop()
                let re = f.pop()
                f.push(invokeHelper(ctx, 52, [re, s]))
            case 0xBBu8 =>
                let s = f.pop()
                let re = f.pop()
                f.push(invokeHelper(ctx, 53, [re, s]))
            case 0xBCu8 =>
                let n = f.pop()
                let h = f.pop()
                f.push(invokeHelper(ctx, 60, [h, n]))
            case 0xBDu8 =>
                let b = f.pop()
                let a = f.pop()
                f.push(invokeHelper(ctx, 61, [a, b]))
            case 0xBEu8 =>
                let mode = Int64(InsnDecoder.u8(insn, 0))
                let cur = f.pop()
                f.push(invokeHelper(ctx, 62, [cur, mode]))
            case 0xBFu8 =>
                let h = f.pop()
                f.push(invokeHelper(ctx, 69, [h]))
            case _ => ctx.errCode = ErrCode.NOT_IMPL
        }
    }

    // ---- 浮点取整（不经平台库；NaN / ±Inf 保留，§5）----

    internal static func floorF(v: Float64): Int64 {
        if (isNanBits(v.toBits())) {
            return 0
        }
        let t = truncF(v)
        if (Float64(t) > v) { t - 1 } else { t }
    }

    internal static func ceilF(v: Float64): Int64 {
        if (isNanBits(v.toBits())) {
            return 0
        }
        let t = truncF(v)
        if (Float64(t) < v) { t + 1 } else { t }
    }

    internal static func truncF(v: Float64): Int64 {
        if (isNanBits(v.toBits())) {
            return 0
        }
        if (v >= Float64(9223372036854775807.0)) {
            return Int64.Max
        }
        if (v <= Float64(-9223372036854775808.0)) {
            return Int64.Min
        }
        Int64(v)
    }

    /** 四舍六入五成双（§5 `FROUND`）。 */
    internal static func roundF(v: Float64): Int64 {
        if (isNanBits(v.toBits())) {
            return 0
        }
        let t = truncF(v)
        let frac = v - Float64(t)
        let af = if (frac < 0.0) { 0.0 - frac } else { frac }
        if (af > 0.5) {
            if (v < 0.0) { t - 1 } else { t + 1 }
        } else if (af < 0.5) {
            t
        } else {
            // 恰好一半 ⇒ 取偶数
            if ((t % 2) == 0) { t } else { if (v < 0.0) { t - 1 } else { t + 1 } }
        }
    }
}
