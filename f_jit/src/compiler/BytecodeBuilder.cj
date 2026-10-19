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
package fountain::f_jit.compiler

import std.collection.ArrayList
import fountain::f_jit.base.SourcePos
import fountain::f_jit.bytecode.ConstRegistry
import fountain::f_jit.bytecode.FuncFlags
import fountain::f_jit.bytecode.OpInfo

/**
 * 单函数发射器 —— design-m1 §4.3.6、plan-m1 S3.19、规格 §5 / §7 / §11.6。
 *
 * 五件事（其余一概交给 `Assembler`，发射器不做 M1 的规则判定）：
 *
 * 1. **编码**：`emit*` 按 `OpInfo.operandSize` 显式小端写（`PUSH_F64` 位模式、`i32` 站点值）；
 * 2. **标签**：`newLabel / place / fixupRel`，`rel32` 口径恒为「目标 −（本条偏移 + 条长）」；
 *    标签**已放置就即时回填**（`place` 后立刻补），未放置的留在 `finish` 前统一处理；
 * 3. **栈深**：按 `StackEffect` 跟踪当前深度与 `maxStack`——分支汇合时两边深度必须相等，
 *    这是 §7 校验 3「sink 前回到帧基线」能在汇编期被判定出来的前提；
 * 4. **自动 `CHECK_ERR`**（I3）：`CALL_HELPER` / `CALL_HELPER_V` 各尾随一条跳向**收敛块**的
 *    `CHECK_ERR`；`_NC` 不尾随；收敛块本身在 `finish` 时置于函数体末尾（落点即「函数跑完」，
 *    错误槽已被写入 ⇒ 解释器 / 机器码都按既有路径 fail-fast，不会被 `BAIL k` 二次覆盖）；
 * 5. **站点**：`setSite` 只记「可能失败点之前」的位置，`SET_SITE` 立即数 = **自身在函数体内的
 *    偏移**（汇编期再加 `codeOff` 并写站点表，§11.6）。
 *
 * **与设计稿的一处形态偏差（显式记录）**：构造签名不接 `localTypes: LocalTypes`（该类的槽数
 * 在构造时被固定，而降低阶段是**边降低边申请槽**的）。改为由发射器持有**可增长的槽类型表**
 * （`allocSlot`），`finish` 时按实际槽数产出 —— 行为等价且避免「先猜一个上限」的臆测。
 */
internal class BytecodeBuilder {
    private let fnId: UInt32
    private let consts: ConstRegistry

    private var code: ArrayList<UInt8>
    private var depth: Int64
    private var maxStack: Int64
    private var flags: UInt16
    /** 当前是否为可达代码（无条件跳转 / 终结语之后、下一个 `place` 之前为伪 dead code）。 */
    private var reachable: Bool

    /** 标签目标偏移（−1 = 未放置）。 */
    private var labelTargets: ArrayList<Int64>
    /** 标签是否**收敛块**（跳入即终结，不参与深度汇合判定）。 */
    private var labelIsSink: ArrayList<Bool>
    /** 待回填：`(指令偏移, 标签号, 跳转点深度)`。 */
    private var fixups: ArrayList<(Int64, Int64, Int64)>
    /** 本站点的待落地条目（相对偏移 + 源位置）。 */
    private var sites: ArrayList<PendingSite>
    /** 局部槽类型（可增长，见类注释）。 */
    private var slotTypes: ArrayList<UInt16>

    /** 收敛块标签（每条 `CHECK_ERR` 的落点）。 */
    private let bailLabel: Int64

    public init(fnId: UInt32, consts: ConstRegistry) {
        this.fnId = fnId
        this.consts = consts
        this.code = ArrayList<UInt8>()
        this.depth = 0
        this.maxStack = 0
        this.flags = 0u16
        this.reachable = true
        this.labelTargets = ArrayList<Int64>()
        this.labelIsSink = ArrayList<Bool>()
        this.fixups = ArrayList<(Int64, Int64, Int64)>()
        this.sites = ArrayList<PendingSite>()
        this.slotTypes = ArrayList<UInt16>()
        this.bailLabel = 0
        let _ = this.newLabel()
    }

    // ==================================================================
    // 基本发射
    // ==================================================================

    /** 当前偏移（= 下一条指令的偏移）。 */
    public prop size: Int64 {
        get() {
            this.code.size
        }
    }

    /** 当前已发射的字节（未 `finish` 时标签可能尚未回填）。 */
    public func bytes(): Array<UInt8> {
        this.code.toArray()
    }

    /** 当前操作数栈深度（测试与诊断用）。 */
    public func depthNow(): Int64 {
        this.depth
    }

    /** 已观测到的栈上界（`finish` 前的值，用于中途断言）。 */
    public func maxStackSeen(): Int64 {
        this.maxStack
    }

    /** 发射一条无操作数指令。 */
    public func emit(op: UInt8): Unit {
        let at = this.emitRaw(op)
        this.account(op, at)
    }

    /** 发射 `u8` 操作数指令。 */
    public func emitU8(op: UInt8, v: UInt8): Unit {
        let at = this.emitRaw(op)
        this.code.add(v)
        this.account(op, at)
    }

    /** 发射 `u16` 操作数指令（显式小端）。 */
    public func emitU16(op: UInt8, v: UInt16): Unit {
        let at = this.emitRaw(op)
        this.code.add(UInt8(v & 0xFFu16))
        this.code.add(UInt8((v >> 8) & 0xFFu16))
        this.account(op, at)
    }

    /** 发射 `i32` 操作数指令（站点值 / 立即数）。 */
    public func emitI32(op: UInt8, v: Int32): Unit {
        let at = this.emitRaw(op)
        let u = toU32(v)
        for (i in 0..4) {
            this.code.add(UInt8((u >> (8 * UInt32(i))) & 0xFFu32))
        }
        this.account(op, at)
    }

    /** 发射 `i64` 操作数指令（整数值或 Float64 位模式）。 */
    public func emitI64(op: UInt8, v: Int64): Unit {
        let at = this.emitRaw(op)
        let u = toU64(v)
        for (i in 0..8) {
            this.code.add(UInt8((u >> (8 * UInt64(i))) & 0xFFu64))
        }
        this.account(op, at)
    }

    /** 发射 `u16 u8` 双操作数指令。 */
    public func emitU16U8(op: UInt8, a: UInt16, b: UInt8): Unit {
        let at = this.emitRaw(op)
        this.code.add(UInt8(a & 0xFFu16))
        this.code.add(UInt8((a >> 8) & 0xFFu16))
        this.code.add(b)
        this.account(op, at)
    }

    /**
     * 发射一条 `rel32` 指令，目标为 `label`。
     *
     * 立即数口径（§10.2 / `InsnDecoder.rel32`）：`target = 本条偏移 + 条长 + offset`。
     */
    public func emitRel(op: UInt8, label: Int64): Unit {
        let at = this.emitRaw(op)
        for (_ in 0..4) {
            this.code.add(0u8)
        }
        this.account(op, at)
        let jumpDepth = this.depth
        let target = this.labelTargets[label]
        if (target >= 0) {
            this.patch(at, target)
        } else {
            this.fixups.add((at, label, jumpDepth))
        }
        // 无条件跳转 / 回边 = 本基本块终结：其后直到下一个 `place` 之前是伪 dead code，
        // 栈深由标签接管（`place` 会把它复位成跳转点深度）。
        if (op == Op.JMP || op == Op.LOOP_BACK) {
            this.reachable = false
        }
    }

    // ==================================================================
    // 标签
    // ==================================================================

    /** 申请一个新标签（返回标签号）。 */
    public func newLabel(): Int64 {
        this.labelTargets.add(-1)
        this.labelIsSink.add(false)
        this.labelTargets.size - 1
    }

    /**
     * 把标签落到**当前偏移**；此后该标签的全部待回填项立即补上。
     *
     * **汇合判定**：所有跳到这里的路径，其跳转点深度必须**彼此相等且等于落点深度**
     * （收敛块标签除外 —— 它是一条「丢弃操作数栈」的终结边）。这是 §7 校验 3 的前端侧兑现：
     * 不平衡的分支在**构建期**就被拒，不会等到汇编期才以「sink 前栈不平衡」含糊报出。
     */
    public func place(label: Int64): Unit {
        if (label < 0 || label >= this.labelTargets.size) {
            codeFail('标签号越界: ${label}')
        }
        if (this.labelTargets[label] >= 0) {
            codeFail('标签 ${label} 已被放置（不得重复 place）')
        }
        let at = this.code.size
        this.labelTargets[label] = at
        if (!this.labelIsSink[label]) {
            var expected: Int64 = -1
            var remaining = ArrayList<(Int64, Int64, Int64)>()
            for (fx in this.fixups) {
                if (fx[1] == label) {
                    if (expected < 0) {
                        expected = fx[2]
                    } else if (expected != fx[2]) {
                        codeFail('分支汇合栈深不等: 标签 ${label} 上出现 ${expected} 与 ${fx[2]}（§7 校验 3）')
                    }
                    // 立即回填（此前的实现只在 patchAll 里补，但那时 fixups 已被过滤掉 ⇒ 立即数恒 0）
                    this.patch(fx[0], at)
                } else {
                    remaining.add(fx)
                }
            }
            if (expected >= 0) {
                // 落点前若刚经过无条件跳转，当前 depth 属于伪 dead code，不可作为汇合深度；
                // 由跳转点深度接管（design §4.3.6「其后直到 place 之前由标签接管」）。
                if (this.reachable && expected != this.depth) {
                    codeFail(
                        '分支汇合栈深与落点不等: 标签 ${label} 跳转点 ${expected} ≠ 落点 ${this.depth}（§7 校验 3）')
                }
                this.depth = expected
            }
            this.fixups = remaining
        }
        this.reachable = true
    }

    /** 手动触发某标签的回填（`place` 已自动做；保留该成员是为了让「回填时机」可被用例观察）。 */
    public func fixupRel(label: Int64): Unit {
        if (label < 0 || label >= this.labelTargets.size) {
            codeFail('标签号越界: ${label}')
        }
        let target = this.labelTargets[label]
        if (target < 0) {
            return
        }
        var remaining = ArrayList<(Int64, Int64, Int64)>()
        for (fx in this.fixups) {
            if (fx[1] == label) {
                this.patch(fx[0], target)
            } else {
                remaining.add(fx)
            }
        }
        this.fixups = remaining
    }

    // ==================================================================
    // 站点
    // ==================================================================

    /**
     * 记一个「可能失败点」的源位置（§7 / §9.16）。
     *
     * 立即数 = `SET_SITE` **自身**在函数体内的偏移（汇编期再加 `codeOff`，§11.6）。
     */
    public func setSite(pos: SourcePos): Unit {
        let at = this.code.size
        this.emitI32(Op.SET_SITE, Int32(at))
        this.sites.add(PendingSite(at, pos))
    }

    /** 待落地站点（按发射顺序）。 */
    public func pendingSites(): Array<PendingSite> {
        this.sites.toArray()
    }

    // ==================================================================
    // 调用 / 返回 / 失败
    // ==================================================================

    /** `CALL_HELPER`：调 helper 并**自动尾随 `CHECK_ERR`**（I3）。 */
    public func callHelper(hid: UInt16, argc: UInt8): Unit {
        this.callHelperRaw(Op.CALL_HELPER, hid, argc)
        this.trailCheck()
    }

    /** `CALL_HELPER_NC`：永不失败的纯 helper，**不**尾随检查。 */
    public func callHelperNoCheck(hid: UInt16, argc: UInt8): Unit {
        this.callHelperRaw(Op.CALL_HELPER_NC, hid, argc)
    }

    /** `CALL_HELPER_V`：返回 Unit（不压栈），同样自动尾随检查。 */
    public func callHelperVoid(hid: UInt16, argc: UInt8): Unit {
        this.callHelperRaw(Op.CALL_HELPER_V, hid, argc)
        this.trailCheck()
    }

    /** `CALL_FUNC fid, argc`（共窗口；§11.7 目录校验在汇编期）。 */
    public func callFunc(fid: UInt16, argc: UInt8): Unit {
        this.emitU16U8(Op.CALL_FUNC, fid, argc)
    }

    /** `CALL_CLOSURE argc`：栈 [闭包句柄, 实参…]（§8.6）。 */
    public func callClosure(argc: UInt8): Unit {
        this.emitU8(Op.CALL_CLOSURE, argc)
    }

    /** `RET`：唯一出口（弹出返回值）。 */
    public func ret(): Unit {
        this.emitRaw(Op.RET)
        this.depth = 0
    }

    /** `RET_VOID`：无返回值的出口。 */
    public func retVoid(): Unit {
        this.emitRaw(Op.RET_VOID)
        this.depth = 0
    }

    /**
     * 失败块：**站点 + 无条件错误码**（`ABORT code`，§5）。
     *
     * 不用 `BAIL k` 是因为收敛块（`CHECK_ERR` 的落点）必须在**不改动错误槽**的前提下退出 ——
     * 码已由失败点写入，二次覆盖会把真实错误改成占位码。
     */
    public func bail(code: Int64, pos: SourcePos): Unit {
        this.setSite(pos)
        this.emitU8(Op.ABORT, UInt8(code))
    }

    // ==================================================================
    // 局部槽
    // ==================================================================

    /** 申请一个局部槽（返回槽号），类型码 `t`（§11.7）。 */
    public func allocSlot(t: UInt16): Int64 {
        this.slotTypes.add(t)
        this.slotTypes.size - 1
    }

    /** 改写既有槽的类型（类型推导晚于槽分配时）。 */
    public func setSlotType(slot: Int64, t: UInt16): Unit {
        if (slot < 0 || slot >= this.slotTypes.size) {
            codeFail('局部槽越界: ${slot} / ${this.slotTypes.size}')
        }
        this.slotTypes[slot] = t
    }

    public func slotCount(): Int64 {
        this.slotTypes.size
    }

    public func slotType(slot: Int64): UInt16 {
        if (slot < 0 || slot >= this.slotTypes.size) {
            codeFail('局部槽越界: ${slot} / ${this.slotTypes.size}')
        }
        this.slotTypes[slot]
    }

    /** 槽类型表（`Assembler` 据此产出 `LocalTypes` 与类型表段）。 */
    public func slotTypeTable(): Array<UInt16> {
        this.slotTypes.toArray()
    }

    /** 本函数的常量表（`PUSH_KH` 校验用）。 */
    public func constsOf(): ConstRegistry {
        this.consts
    }

    /** 本函数号。 */
    public func fnIdOf(): UInt32 {
        this.fnId
    }

    // ==================================================================
    // 收尾
    // ==================================================================

    /**
     * 产出函数体：收敛块落位 → 全部回填 → `FuncBody`（code 片段 + maxStack + flags）。
     *
     * 仍有未放置标签 ⇒ 硬错误（静默填 0 会造出「跳到函数头」的死循环码）。
     */
    public func finish(): FuncBody {
        if (this.labelTargets[this.bailLabel] < 0) {
            this.placeBail()
        }
        if (this.fixups.size > 0) {
            var names = ''
            for (fx in this.fixups) {
                names = names + ' @${fx[0]}→L${fx[1]}'
            }
            codeFail('存在未回填的跳转目标:${names}（§10.2 rel32 必须全部解析）')
        }
        FuncBody(this.code.toArray(), this.maxStack, this.flags)
    }

    // ==================================================================
    // 内部
    // ==================================================================

    /** 收敛块：置于函数体末尾（落点 = 「函数跑完」，错误槽已写 ⇒ fail-fast 生效）。 */
    private func placeBail(): Unit {
        this.labelTargets[this.bailLabel] = this.code.size
        this.labelIsSink[this.bailLabel] = true
        this.depth = 0
        this.patchAll(this.bailLabel, this.code.size)
    }

    private func trailCheck(): Unit {
        this.emitRel(Op.CHECK_ERR, this.bailLabel)
    }

    private func callHelperRaw(op: UInt8, hid: UInt16, argc: UInt8): Unit {
        this.emitU16U8(op, hid, argc)
    }

    /** 写一条指令头（只写 opcode 字节）；栈账由 `account` 在操作数写完之后结算。 */
    private func emitRaw(op: UInt8): Int64 {
        let at = this.code.size
        this.code.add(op)
        at
    }

    /**
     * 结算一条指令的栈账（**操作数必须已写完**）。
     *
     * 之所以分成两步：`CALL_*` 家族的 `pop` 取决于 `argc` 操作数，而操作数在本方法之前
     * 才被写入字节流 —— 只有写完才能回读到它。
     */
    private func account(op: UInt8, at: Int64): Unit {
        let info = OpInfo.OPCODE_TABLE[Int64(op)]
        if (info.cat == OpInfo.CAT_FORBID || info.cat == OpInfo.CAT_RSVD) {
            notImplFail('禁用/保留 opcode 0x${CodeDump.hex([op])}（M1 发射即 ERR_NOT_IMPL，§10.1）')
        }
        let (pop, push) = StackEffect.of(op, this.argcOfInsn(op, at))
        if (pop < 0) {
            codeFail('未登记的 opcode 0x${CodeDump.hex([op])}（§10.3 未分配槽不得发射）')
        }
        if (this.depth < pop) {
            codeFail('操作数栈下越界: opcode 0x${CodeDump.hex([op])} @${at}，需要 ${pop} 实际 ${this.depth}')
        }
        let after = this.depth - pop + push
        if (after > this.maxStack) {
            this.maxStack = after
        }
        this.depth = after
        // 变更型调用按**字节流事实**置位（不依赖调用方走 `callHelper`/`callClosure` 便捷方法）：
        // H43–H48 / user helper（§9.15）与 `CALL_CLOSURE`（§8.6，被调闭包体静态不可知）/
        // `CALL_HOST`（m2 §2，宿主闭包体黑盒）保守按变更型处理。
        if (op == Op.CALL_CLOSURE || op == Op.CALL_HOST) {
            this.flags = this.flags | FuncFlags.MUTATION
        } else if (HelperCodec.isCallHelper(op)) {
            let hid = UInt16(this.code[at + 1]) | (UInt16(this.code[at + 2]) << 8)
            if (HelperCodec.isMutating(hid)) {
                this.flags = this.flags | FuncFlags.MUTATION
            }
        }
    }

    /** 取指令的 `argc`（只有 `CALL_*` 家族需要）。 */
    private func argcOfInsn(op: UInt8, at: Int64): Int64 {
        if (op == Op.CALL_HELPER || op == Op.CALL_HELPER_NC || op == Op.CALL_HELPER_V || op == Op.CALL_FUNC) {
            return Int64(this.code[at + 3])
        }
        if (op == Op.CALL_CLOSURE || op == Op.CALL_HOST) {
            return Int64(this.code[at + 1])
        }
        0
    }

    /** `i32` → `u32` 位模式（补码；与 `bytecode` 包同款，不引入跨包依赖）。 */
    private static func toU32(v: Int32): UInt32 {
        if (v < 0) {
            UInt32(v + 2147483647 + 1) + 0x80000000u32
        } else {
            UInt32(v)
        }
    }

    /** `i64` → `u64` 位模式（补码）。 */
    private static func toU64(v: Int64): UInt64 {
        if (v < 0) {
            UInt64(v + 9223372036854775807 + 1) + 0x8000000000000000u64
        } else {
            UInt64(v)
        }
    }

    /** 补一条 `rel32`：`offset = target − (指令偏移 + 条长)`。 */
    private func patch(insnOff: Int64, target: Int64): Unit {
        let rel = target - (insnOff + 5)
        let u = toU32(Int32(rel))
        for (i in 0..4) {
            this.code[insnOff + 1 + i] = UInt8((u >> (8 * UInt32(i))) & 0xFFu32)
        }
    }

    private func patchAll(label: Int64, target: Int64): Unit {
        var remaining = ArrayList<(Int64, Int64, Int64)>()
        for (fx in this.fixups) {
            if (fx[1] == label) {
                this.patch(fx[0], target)
            } else {
                remaining.add(fx)
            }
        }
        this.fixups = remaining
    }
}
