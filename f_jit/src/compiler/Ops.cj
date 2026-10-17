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

/**
 * 降低阶段用的 opcode 常量命名空间 —— design-m1 §4.3.6 / 附 B、plan-m1 S3.19。
 *
 * **为什么还要一份常量**（而不是直接用 `OpInfo.OPCODE_TABLE[i].code`）：降低写法要的是
 * **可阅读的发射点**（`b.emit(Op.IADD)`），拿下标写会让「加载的目标]意图不可审阅；而数值口径
 * 仍**只有一处权威**——本文件的每条常量与 `OpInfo.OPCODE_TABLE` 同源，并由
 * `selfCheckOk()` 在用例里逐条比对（`code == i` 与表自证一致，`Ops.agreeWithOpInfo()` 再比助记符）。
 */
internal class Op {
    // ---- 0x00–0x0F 控制 / 杂项 ----
    public static const NOP: UInt8 = 0x00u8
    public static const TRAP: UInt8 = 0x01u8
    public static const BREAKPOINT: UInt8 = 0x02u8
    public static const SET_SITE: UInt8 = 0x03u8
    public static const CHECK_ERR: UInt8 = 0x04u8
    public static const BAIL: UInt8 = 0x05u8
    public static const CHECK_ERR_NC: UInt8 = 0x06u8
    public static const STACK_GUARD: UInt8 = 0x07u8

    // ---- 0x10–0x1F 常量 / 栈 ----
    public static const PUSH_I8: UInt8 = 0x10u8
    public static const PUSH_I32: UInt8 = 0x11u8
    public static const PUSH_I64: UInt8 = 0x12u8
    public static const PUSH_F64: UInt8 = 0x13u8
    public static const PUSH_BOOL: UInt8 = 0x14u8
    public static const PUSH_NULL: UInt8 = 0x15u8
    public static const PUSH_KH: UInt8 = 0x16u8
    public static const DUP: UInt8 = 0x17u8
    public static const DUP2: UInt8 = 0x18u8
    public static const POP: UInt8 = 0x19u8
    public static const POP2: UInt8 = 0x1Au8
    public static const SWAP: UInt8 = 0x1Bu8
    public static const PICK: UInt8 = 0x1Cu8

    // ---- 0x20–0x2F 局部变量 ----
    public static const LOADL: UInt8 = 0x20u8
    public static const STOREL: UInt8 = 0x21u8
    public static const LOADL0: UInt8 = 0x22u8
    public static const LOADL1: UInt8 = 0x23u8
    public static const LOADL2: UInt8 = 0x24u8
    public static const LOADL3: UInt8 = 0x25u8
    public static const LOAD_CAP: UInt8 = 0x26u8

    // ---- 0x30–0x3B 整型算术 ----
    public static const IADD: UInt8 = 0x30u8
    public static const ISUB: UInt8 = 0x31u8
    public static const IMUL: UInt8 = 0x32u8
    public static const IDIV: UInt8 = 0x33u8
    public static const IMOD: UInt8 = 0x34u8
    public static const INEG: UInt8 = 0x35u8
    public static const IABS: UInt8 = 0x36u8
    public static const IMIN: UInt8 = 0x37u8
    public static const IMAX: UInt8 = 0x38u8
    public static const IADD_WRAP: UInt8 = 0x39u8
    public static const ICLZ: UInt8 = 0x3Au8
    public static const IPOPCNT: UInt8 = 0x3Bu8

    // ---- 0x40–0x4D 浮点 ----
    public static const FADD: UInt8 = 0x40u8
    public static const FSUB: UInt8 = 0x41u8
    public static const FMUL: UInt8 = 0x42u8
    public static const FDIV: UInt8 = 0x43u8
    public static const FDIV_CHK: UInt8 = 0x44u8
    public static const FNEG: UInt8 = 0x45u8
    public static const FABS: UInt8 = 0x46u8
    public static const FMIN: UInt8 = 0x47u8
    public static const FMAX: UInt8 = 0x48u8
    public static const FSQRT: UInt8 = 0x49u8
    public static const FFLOOR: UInt8 = 0x4Au8
    public static const FCEIL: UInt8 = 0x4Bu8
    public static const FTRUNC: UInt8 = 0x4Cu8
    public static const FROUND: UInt8 = 0x4Du8

    // ---- 0x50–0x6E 比较 / 逻辑 / 位 ----
    public static const CMP_I: UInt8 = 0x50u8
    public static const CMP_F: UInt8 = 0x51u8
    public static const EQ_I: UInt8 = 0x52u8
    public static const NE_I: UInt8 = 0x53u8
    public static const LT_I: UInt8 = 0x54u8
    public static const LE_I: UInt8 = 0x55u8
    public static const GT_I: UInt8 = 0x56u8
    public static const GE_I: UInt8 = 0x57u8
    public static const EQ_F: UInt8 = 0x58u8
    public static const NE_F: UInt8 = 0x59u8
    public static const LT_F: UInt8 = 0x5Au8
    public static const LE_F: UInt8 = 0x5Bu8
    public static const GT_F: UInt8 = 0x5Cu8
    public static const GE_F: UInt8 = 0x5Du8
    public static const NOT_B: UInt8 = 0x5Eu8
    public static const AND_B: UInt8 = 0x5Fu8
    public static const OR_B: UInt8 = 0x60u8
    public static const XOR_B: UInt8 = 0x61u8
    public static const BAND_I: UInt8 = 0x62u8
    public static const BOR_I: UInt8 = 0x63u8
    public static const BXOR_I: UInt8 = 0x64u8
    public static const BNOT_I: UInt8 = 0x65u8
    public static const SHL_I: UInt8 = 0x66u8
    public static const SHR_I: UInt8 = 0x67u8
    public static const USHR_I: UInt8 = 0x68u8
    public static const EQ_H: UInt8 = 0x69u8
    public static const NE_H: UInt8 = 0x6Au8
    public static const CMP_STR: UInt8 = 0x6Bu8
    public static const CMP_DEC: UInt8 = 0x6Cu8
    public static const CMP_DT: UInt8 = 0x6Du8
    public static const CMP_DUR: UInt8 = 0x6Eu8

    // ---- 0x70–0x7F 控制流与调用 ----
    public static const JMP: UInt8 = 0x70u8
    public static const JZ: UInt8 = 0x71u8
    public static const JNZ: UInt8 = 0x72u8
    public static const LOOP_BACK: UInt8 = 0x74u8
    public static const CALL_HELPER: UInt8 = 0x75u8
    public static const CALL_HELPER_NC: UInt8 = 0x76u8
    public static const CALL_HELPER_V: UInt8 = 0x77u8
    public static const CALL_FUNC: UInt8 = 0x78u8
    public static const CALL_HOST: UInt8 = 0x79u8
    public static const HW_OPEN: UInt8 = 0x7Au8
    public static const HW_CLOSE: UInt8 = 0x7Bu8
    public static const RET: UInt8 = 0x7Cu8
    public static const RET_VOID: UInt8 = 0x7Du8
    public static const RET_NULL: UInt8 = 0x7Eu8
    public static const CALL_CLOSURE: UInt8 = 0x7Fu8

    // ---- 0x80–0x89 类型 / 转换 / 错误 ----
    public static const CAST: UInt8 = 0x80u8
    public static const TO_I64: UInt8 = 0x81u8
    public static const TO_F64: UInt8 = 0x82u8
    public static const IS_TYPE: UInt8 = 0x83u8
    public static const GUARD_TYPE: UInt8 = 0x84u8
    public static const THROW: UInt8 = 0x85u8
    public static const ASSERT: UInt8 = 0x86u8
    public static const ABORT: UInt8 = 0x87u8
    public static const GUARD_NNZ: UInt8 = 0x88u8
    public static const TYPE_OF: UInt8 = 0x89u8

    // ---- 0x90–0x9E 容器 / 值提取 / 数值转换 ----
    public static const LEN: UInt8 = 0x90u8
    public static const GET_IDX: UInt8 = 0x91u8
    public static const GET_KEY: UInt8 = 0x92u8
    public static const GET_KEY_OR: UInt8 = 0x93u8
    public static const HAS_KEY: UInt8 = 0x94u8
    public static const STR_AT: UInt8 = 0x95u8
    public static const DT_FIELD: UInt8 = 0x96u8
    public static const DUR_TICKS: UInt8 = 0x97u8
    public static const DEC_IS_INT: UInt8 = 0x98u8
    public static const HANDLE_TAG: UInt8 = 0x99u8
    public static const RANGE_NEW: UInt8 = 0x9Au8
    public static const RANGE_CONTAINS: UInt8 = 0x9Bu8
    public static const TO_DEC: UInt8 = 0x9Cu8
    public static const DEC_TO_I64: UInt8 = 0x9Du8
    public static const DEC_TO_F64: UInt8 = 0x9Eu8

    // ---- 0xA0–0xAF 分配 / 变更区 ----
    public static const MAKE_LIST: UInt8 = 0xA0u8
    public static const LIST_APPEND: UInt8 = 0xA1u8
    public static const MAKE_MAP: UInt8 = 0xA2u8
    public static const MAP_PUT: UInt8 = 0xA3u8
    public static const STR_CAT: UInt8 = 0xA4u8
    public static const DEC_ADD: UInt8 = 0xA5u8
    public static const DEC_SUB: UInt8 = 0xA6u8
    public static const DEC_MUL: UInt8 = 0xA7u8
    public static const DEC_DIV: UInt8 = 0xA8u8
    public static const DT_NEW: UInt8 = 0xA9u8
    public static const DUR_NEW: UInt8 = 0xAAu8
    public static const LIST_INSERT: UInt8 = 0xABu8
    public static const LIST_SET: UInt8 = 0xACu8
    public static const LIST_REMOVE: UInt8 = 0xADu8
    public static const MAP_REMOVE: UInt8 = 0xAEu8
    public static const MAP_ITER_BEGIN: UInt8 = 0xAFu8

    // ---- 0xB0–0xBF 时间 / 文本化 / 字符串 / 正则 ----
    public static const DT_ADD: UInt8 = 0xB0u8
    public static const DT_SUB: UInt8 = 0xB1u8
    public static const DUR_ADD: UInt8 = 0xB2u8
    public static const DUR_SUB: UInt8 = 0xB3u8
    public static const DUR_MUL: UInt8 = 0xB4u8
    public static const DUR_DIV: UInt8 = 0xB5u8
    public static const DUR_NEG: UInt8 = 0xB6u8
    public static const TO_STR: UInt8 = 0xB7u8
    public static const STR_SUB: UInt8 = 0xB8u8
    public static const STR_REPLACE: UInt8 = 0xB9u8
    public static const REGEX_IS_MATCH: UInt8 = 0xBAu8
    public static const REGEX_FIND: UInt8 = 0xBBu8
    public static const STR_REPEAT: UInt8 = 0xBCu8
    public static const DT_DIFF: UInt8 = 0xBDu8
    public static const MAP_ITER_STEP: UInt8 = 0xBEu8
    public static const STR_TO_REGEX: UInt8 = 0xBFu8
}

/**
 * `CALL_HELPER` 系列的操作数位置与 hid 编码 —— §5 / §6 / §8.4。
 *
 * hid 的合法值域：`1–62`、`69–72` 为固定 helper；`[0x0100, 0xFFFF]` 为单元私有预定义 helper
 * （user helper，slot = hid − 0x0100）；`63–68` 与 `0` 保留。
 *
 * **为什么本文件自带这几个 hid 而不是 import `runtime.HelperId`**：仓颉禁止包间循环依赖，
 * 且 design D2 明确「`compiler` / `runtime` / `backend` **彼此不 import**」——`compiler` 只能
 * 引用 `base` 与 `bytecode`。hid 是**线上码**（烘焙进 `.fbc` 与机器码立即数），两侧各持一份
 * 常量是分包必须付的代价；本文件只登记**降低阶段真正直呼**的那几个（其余指令由解释器 /
 * 后端按 opcode → helper 路由，降低侧不出现 hid），取值与 `runtime/HelperId.cj` 逐条同源，
 * 由「hid 合法值域」用例（`HelperId.isFixed`）在差分层守住一致性。
 */
internal class HelperCodec {
    /** 单元私有 helper（user helper）的 hid 起址（§8.4）。 */
    public static const USER_BASE: UInt16 = 0x0100u16

    /** H54 `closure_new`（§8.6 闭包构造；无专用 opcode，降低阶段直呼）。 */
    public static const CLOSURE_NEW: UInt16 = 54u16
    /** H58 `regex_replace_all`（§11.9 替换三形；无专用 opcode）。 */
    public static const REGEX_REPLACE_ALL: UInt16 = 58u16
    /** H59 `regex_replace_nth`。 */
    public static const REGEX_REPLACE_NTH: UInt16 = 59u16
    /** H72 `regex_replace_range`（v0.18.19 区间替换）。 */
    public static const REGEX_REPLACE_RANGE: UInt16 = 72u16

    /** 变更型 helper 的 hid 区间（H43–H48，§9.15 / §7 校验 11）。 */
    public static const MUTATION_MIN: UInt16 = 43u16
    public static const MUTATION_MAX: UInt16 = 48u16

    /** slot → hid（user helper）。 */
    public static func hidOfSlot(slot: UInt16): UInt16 {
        slot + USER_BASE
    }

    /** 是否 `CALL_HELPER` 家族的三个 opcode 之一（§7 校验 1 / 6 的共同前提）。 */
    public static func isCallHelper(op: UInt8): Bool {
        op == Op.CALL_HELPER || op == Op.CALL_HELPER_NC || op == Op.CALL_HELPER_V
    }

    /** 是否**需要**自动尾随 `CHECK_ERR` 的变体（`_NC` 不需要，§5）。 */
    public static func needsAutoCheck(op: UInt8): Bool {
        op == Op.CALL_HELPER || op == Op.CALL_HELPER_V
    }

    /**
     * 该 hid 是否为变更型 helper（§7 校验 11 的保守判定输入）。
     *
     * 除 H43–H48 外，**user helper（§8.4 预定义函数）同样按变更型保守处理**——宿主实现体
     * 静态不可知，§9.15 的「整函数保守判定」要求把它算进去。
     */
    public static func isMutating(hid: UInt16): Bool {
        (hid >= MUTATION_MIN && hid <= MUTATION_MAX) || hid >= USER_BASE
    }
}

/**
 * 栈效应（`pop` / `push`）与终结语判定 —— design-m1 §4.3.6 / 附 B、§7 校验 3。
 *
 * 栈作用是 **按 opcode +  opcode 自己的操作数** 唯一确定的（M1 指令全部定长，附 B 逐条列明）；
 * `BytecodeBuilder` 用它跟踪当前深度与 `maxStack`，`Assembler` 用同一份表做「sink 前回到帧基线」
 * 的平衡校验 —— **两处必须同源**，否则「构建期通过、汇编期被拒」就会出现永假分支。
 *
 * 终结语（`RET` / `RET_VOID` / `RET_NULL`）的 `pop` 只用于 validator；构建器在之后把深度归零。
 */
internal class StackEffect {
    /**
     * 每 opcode 的 `(pop, push)`；未登记者保持 `(-1, -1)`（由调用方转为拒绝，§7 校验 2）。
     *
     * **argc 相关的 opcode 不进本表**（`CALL_*` 家族），由 `of` 另行处理。
     */
    private static let TABLE: Array<(Int64, Int64)> = StackEffect.build()

    /**
     * 求 `(pop, push)`。
     *
     * `arg` = opcode 的主操作数：`CALL_HELPER(_NC/_V)` / `CALL_FUNC` 为 `argc`，
     * `CALL_CLOSURE` 亦为 `argc`（另多弹一个闭包句柄）；其余忽略。
     */
    public static func of(op: UInt8, arg: Int64): (Int64, Int64) {
        if (op == Op.CALL_HELPER || op == Op.CALL_HELPER_NC || op == Op.CALL_FUNC) {
            return (arg, 1)
        }
        if (op == Op.CALL_HELPER_V) {
            return (arg, 0)
        }
        if (op == Op.CALL_CLOSURE) {
            return (arg + 1, 1)
        }
        TABLE[Int64(op)]
    }

    private static func build(): Array<(Int64, Int64)> {
        var t = Array<(Int64, Int64)>(256, repeat: (-1, -1))
        // ---- 控制 / 杂项 ----
        t[Int64(Op.NOP)] = (0, 0)
        t[Int64(Op.TRAP)] = (0, 0)
        t[Int64(Op.BREAKPOINT)] = (0, 0)
        t[Int64(Op.SET_SITE)] = (0, 0)
        t[Int64(Op.CHECK_ERR)] = (0, 0)
        t[Int64(Op.BAIL)] = (0, 0)
        t[Int64(Op.CHECK_ERR_NC)] = (0, 0)
        t[Int64(Op.STACK_GUARD)] = (0, 0)
        // ---- 控制流 ----
        t[Int64(Op.JMP)] = (0, 0)
        t[Int64(Op.JZ)] = (1, 0)
        t[Int64(Op.JNZ)] = (1, 0)
        t[Int64(Op.LOOP_BACK)] = (0, 0)
        // ---- 常量 / 栈 ----
        t[Int64(Op.PUSH_I8)] = (0, 1)
        t[Int64(Op.PUSH_I32)] = (0, 1)
        t[Int64(Op.PUSH_I64)] = (0, 1)
        t[Int64(Op.PUSH_F64)] = (0, 1)
        t[Int64(Op.PUSH_BOOL)] = (0, 1)
        t[Int64(Op.PUSH_NULL)] = (0, 1)
        t[Int64(Op.PUSH_KH)] = (0, 1)
        t[Int64(Op.DUP)] = (1, 2)
        t[Int64(Op.DUP2)] = (2, 4)
        t[Int64(Op.POP)] = (1, 0)
        t[Int64(Op.POP2)] = (2, 0)
        t[Int64(Op.SWAP)] = (2, 2)
        t[Int64(Op.PICK)] = (0, 1)
        // ---- 局部变量 ----
        t[Int64(Op.LOADL)] = (0, 1)
        t[Int64(Op.STOREL)] = (1, 0)
        t[Int64(Op.LOADL0)] = (0, 1)
        t[Int64(Op.LOADL1)] = (0, 1)
        t[Int64(Op.LOADL2)] = (0, 1)
        t[Int64(Op.LOADL3)] = (0, 1)
        t[Int64(Op.LOAD_CAP)] = (0, 1)
        // ---- 整型一元 ----
        t[Int64(Op.INEG)] = (1, 1)
        t[Int64(Op.IABS)] = (1, 1)
        t[Int64(Op.ICLZ)] = (1, 1)
        t[Int64(Op.IPOPCNT)] = (1, 1)
        t[Int64(Op.BNOT_I)] = (1, 1)
        // ---- 整型二元 ----
        t[Int64(Op.IADD)] = (2, 1)
        t[Int64(Op.ISUB)] = (2, 1)
        t[Int64(Op.IMUL)] = (2, 1)
        t[Int64(Op.IDIV)] = (2, 1)
        t[Int64(Op.IMOD)] = (2, 1)
        t[Int64(Op.IMIN)] = (2, 1)
        t[Int64(Op.IMAX)] = (2, 1)
        t[Int64(Op.IADD_WRAP)] = (2, 1)
        t[Int64(Op.BAND_I)] = (2, 1)
        t[Int64(Op.BOR_I)] = (2, 1)
        t[Int64(Op.BXOR_I)] = (2, 1)
        t[Int64(Op.SHL_I)] = (2, 1)
        t[Int64(Op.SHR_I)] = (2, 1)
        t[Int64(Op.USHR_I)] = (2, 1)
        // ---- 浮点一元 ----
        t[Int64(Op.FNEG)] = (1, 1)
        t[Int64(Op.FABS)] = (1, 1)
        t[Int64(Op.FSQRT)] = (1, 1)
        t[Int64(Op.FFLOOR)] = (1, 1)
        t[Int64(Op.FCEIL)] = (1, 1)
        t[Int64(Op.FTRUNC)] = (1, 1)
        t[Int64(Op.FROUND)] = (1, 1)
        // ---- 浮点二元 ----
        t[Int64(Op.FADD)] = (2, 1)
        t[Int64(Op.FSUB)] = (2, 1)
        t[Int64(Op.FMUL)] = (2, 1)
        t[Int64(Op.FDIV)] = (2, 1)
        t[Int64(Op.FDIV_CHK)] = (2, 1)
        t[Int64(Op.FMIN)] = (2, 1)
        t[Int64(Op.FMAX)] = (2, 1)
        // ---- 比较 / 逻辑 / 位 ----
        t[Int64(Op.CMP_I)] = (2, 1)
        t[Int64(Op.CMP_F)] = (2, 1)
        t[Int64(Op.EQ_I)] = (2, 1)
        t[Int64(Op.NE_I)] = (2, 1)
        t[Int64(Op.LT_I)] = (2, 1)
        t[Int64(Op.LE_I)] = (2, 1)
        t[Int64(Op.GT_I)] = (2, 1)
        t[Int64(Op.GE_I)] = (2, 1)
        t[Int64(Op.EQ_F)] = (2, 1)
        t[Int64(Op.NE_F)] = (2, 1)
        t[Int64(Op.LT_F)] = (2, 1)
        t[Int64(Op.LE_F)] = (2, 1)
        t[Int64(Op.GT_F)] = (2, 1)
        t[Int64(Op.GE_F)] = (2, 1)
        t[Int64(Op.NOT_B)] = (1, 1)
        t[Int64(Op.AND_B)] = (2, 1)
        t[Int64(Op.OR_B)] = (2, 1)
        t[Int64(Op.XOR_B)] = (2, 1)
        t[Int64(Op.EQ_H)] = (2, 1)
        t[Int64(Op.NE_H)] = (2, 1)
        t[Int64(Op.CMP_STR)] = (2, 1)
        t[Int64(Op.CMP_DEC)] = (2, 1)
        t[Int64(Op.CMP_DT)] = (2, 1)
        t[Int64(Op.CMP_DUR)] = (2, 1)
        // ---- 调用 / 返回 ----
        t[Int64(Op.CALL_HOST)] = (0, 0)
        t[Int64(Op.HW_OPEN)] = (0, 0)
        t[Int64(Op.HW_CLOSE)] = (0, 0)
        t[Int64(Op.RET)] = (1, 0)
        t[Int64(Op.RET_VOID)] = (0, 0)
        t[Int64(Op.RET_NULL)] = (0, 0)
        // ---- 类型 / 转换 / 错误 ----
        t[Int64(Op.CAST)] = (1, 1)
        t[Int64(Op.TO_I64)] = (1, 1)
        t[Int64(Op.TO_F64)] = (1, 1)
        t[Int64(Op.IS_TYPE)] = (1, 1)
        t[Int64(Op.GUARD_TYPE)] = (1, 1)
        t[Int64(Op.THROW)] = (0, 0)
        t[Int64(Op.ASSERT)] = (1, 0)
        t[Int64(Op.ABORT)] = (0, 0)
        t[Int64(Op.GUARD_NNZ)] = (1, 1)
        t[Int64(Op.TYPE_OF)] = (1, 1)
        // ---- 容器 / 值提取 / 数值转换 ----
        t[Int64(Op.LEN)] = (1, 1)
        t[Int64(Op.GET_IDX)] = (2, 1)
        t[Int64(Op.GET_KEY)] = (2, 1)
        t[Int64(Op.GET_KEY_OR)] = (3, 1)
        t[Int64(Op.HAS_KEY)] = (2, 1)
        t[Int64(Op.STR_AT)] = (2, 1)
        t[Int64(Op.DT_FIELD)] = (2, 1)
        t[Int64(Op.DUR_TICKS)] = (1, 1)
        t[Int64(Op.DEC_IS_INT)] = (1, 1)
        t[Int64(Op.HANDLE_TAG)] = (1, 1)
        t[Int64(Op.RANGE_NEW)] = (4, 1)
        t[Int64(Op.RANGE_CONTAINS)] = (2, 1)
        t[Int64(Op.TO_DEC)] = (1, 1)
        t[Int64(Op.DEC_TO_I64)] = (1, 1)
        t[Int64(Op.DEC_TO_F64)] = (1, 1)
        // ---- 分配 / 变更 / 迭代 / 时间 / 文本 ----
        t[Int64(Op.MAKE_LIST)] = (0, 1)
        t[Int64(Op.LIST_APPEND)] = (2, 1)
        t[Int64(Op.MAKE_MAP)] = (0, 1)
        t[Int64(Op.MAP_PUT)] = (3, 1)
        t[Int64(Op.STR_CAT)] = (2, 1)
        t[Int64(Op.DEC_ADD)] = (2, 1)
        t[Int64(Op.DEC_SUB)] = (2, 1)
        t[Int64(Op.DEC_MUL)] = (2, 1)
        t[Int64(Op.DEC_DIV)] = (2, 1)
        t[Int64(Op.LIST_INSERT)] = (3, 1)
        t[Int64(Op.LIST_SET)] = (3, 1)
        t[Int64(Op.LIST_REMOVE)] = (2, 1)
        t[Int64(Op.MAP_REMOVE)] = (2, 1)
        t[Int64(Op.MAP_ITER_BEGIN)] = (1, 1)
        t[Int64(Op.MAP_ITER_STEP)] = (1, 1)
        t[Int64(Op.DT_ADD)] = (2, 1)
        t[Int64(Op.DT_SUB)] = (2, 1)
        t[Int64(Op.DUR_ADD)] = (2, 1)
        t[Int64(Op.DUR_SUB)] = (2, 1)
        t[Int64(Op.DUR_MUL)] = (2, 1)
        t[Int64(Op.DUR_DIV)] = (2, 1)
        t[Int64(Op.DUR_NEG)] = (1, 1)
        t[Int64(Op.TO_STR)] = (1, 1)
        t[Int64(Op.STR_SUB)] = (3, 1)
        t[Int64(Op.STR_REPLACE)] = (3, 1)
        t[Int64(Op.REGEX_IS_MATCH)] = (2, 1)
        t[Int64(Op.REGEX_FIND)] = (2, 1)
        t[Int64(Op.STR_REPEAT)] = (2, 1)
        t[Int64(Op.DT_DIFF)] = (2, 1)
        t[Int64(Op.STR_TO_REGEX)] = (1, 1)
        t
    }

    /** 是否为**终结语**（执行后不再顺序推进到下一指令）。 */
    public static func isTerminator(op: UInt8): Bool {
        op == Op.RET || op == Op.RET_VOID || op == Op.RET_NULL || op == Op.BAIL
    }

    /** 是否为**无条件跳转**（其后直到 `place(label)` 之前是伪 dead code，深度由标签接管）。 */
    public static func isUncondJump(op: UInt8): Bool {
        op == Op.JMP || op == Op.LOOP_BACK
    }
}
