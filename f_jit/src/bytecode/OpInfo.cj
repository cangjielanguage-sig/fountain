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

/**
 * 单条 opcode 的元信息 + 全量 256 项 opcode 表 —— design-m1 §3.3.1、plan-m1 S2.1。
 *
 * 数值权威 = `doc/jit-bytecode-m1.md` §10.3「opcode 常量表（Cangjie 骨架）」；操作数编码种类
 * 见 §10.2，保留/禁用区的语义见 §10.1。
 *
 * **为什么是 `struct`**（design-m1 §3.3.1 的理由）：它是**只读元信息**（五字段全 `let`、
 * 无身份、无行为），访问模式是「按下标取一条 → 读字段」；`Array<OpInfo>` 对 struct 元素
 * **内联连续存储**（256 项紧排、缓存友好），而 `Array<class>` 是引用数组（指针追逐 + 静态期
 * 256 次堆分配 + 别名风险）。`DecodedInsn`（S2.3）持有 `OpInfo` 副本也不会与表项共享可变状态。
 *
 * **为什么类别码是 `static const` 而不是 `enum`**（design D3）：类别码要参与序列化分派与
 * 编译期判定（§10.3 一致性校验第 3 条：汇编器对 `CAT_FORBID` / `CAT_RSVD` 一律拒绝），
 * 而仓颉 `enum` 的构造器不携带数值。
 */
public struct OpInfo {
    /** opcode 编码（恒等于表下标，§10.3 一致性校验第 1 条）。 */
    public let code: UInt8
    /** 助记符（`OP_<助记符>`，§10.1）。 */
    public let name: String
    /** 操作数编码，见 §10.2（`-` / `u8` / `i8` / `u16` / `i32` / `rel32` / `i64` / `u16 u8`）。 */
    public let fmt: String
    /** 指令总长（1 + 操作数字节）；**平台无关**（§11.2）。 */
    public let len: Int64
    /** 类别码，取值域为 `CAT_*`。 */
    public let cat: UInt8

    public const init(code: UInt8, name: String, fmt: String, len: Int64, cat: UInt8) {
        this.code = code
        this.name = name
        this.fmt = fmt
        this.len = len
        this.cat = cat
    }

    // ---- 类别码：static const 成员（访问形式 `OpInfo.CAT_*`）----
    /** 控制 / 杂项。 */
    public static const CAT_MISC: UInt8 = 0u8
    /** 常量 / 栈。 */
    public static const CAT_CONST: UInt8 = 1u8
    /** 局部变量。 */
    public static const CAT_LOCAL: UInt8 = 2u8
    /** 整型算术。 */
    public static const CAT_I64: UInt8 = 3u8
    /** 浮点算术。 */
    public static const CAT_F64: UInt8 = 4u8
    /** 比较 / 逻辑 / 位。 */
    public static const CAT_CMP: UInt8 = 5u8
    /** 控制流。 */
    public static const CAT_CTRL: UInt8 = 6u8
    /** 调用。 */
    public static const CAT_CALL: UInt8 = 7u8
    /** 类型 / 转换 / 错误。 */
    public static const CAT_TYPE: UInt8 = 8u8
    /** 容器 / 值运算 / 转换（helper 路由，含分配型）。 */
    public static const CAT_BOX: UInt8 = 9u8
    /** 禁用（时间构造 0xA9–AA，M2 启用）；M1 发射即 `ERR_NOT_IMPL`。 */
    public static const CAT_FORBID: UInt8 = 10u8
    /** 保留（未分配槽 + 0xC0–0xFF 预留区）；M1 发射即 `ERR_NOT_IMPL`。 */
    public static const CAT_RSVD: UInt8 = 11u8

    /** 操作数编码 → 字节数（§10.2 表；与 `len` 的一致性由 `selfCheckOk` 断言）。 */
    public static func operandSize(fmt: String): Int64 {
        match (fmt) {
            case '-' => 0
            case 'u8' => 1
            case 'i8' => 1
            case 'u16' => 2
            case 'i32' => 4
            case 'rel32' => 4
            case 'i64' => 8
            case 'u16 u8' => 3
            case _ => -1
        }
    }

    /**
     * 表自检（§10.3「表的一致性校验」第 1、2 条）：长度 256、`table[i].code == i`、
     * `len == 1 + operandSize(fmt)`、类别码落在 0–11。
     *
     * 由测试用例调用（模块初始化不做隐式自检，避免加载期不可控副作用）。
     */
    public static func selfCheckOk(): Bool {
        let t = OPCODE_TABLE
        var ok = t.size == 256
        for (i in 0..256) {
            let e = t[i]
            if (Int64(e.code) != Int64(i)) {
                return false
            }
            if (e.len != 1 + operandSize(e.fmt)) {
                return false
            }
            if (e.cat > CAT_RSVD) {
                ok = false
            }
        }
        ok
    }

    // ---- 全量 256 项：static let 成员 ----
    public static let OPCODE_TABLE: Array<OpInfo> = [
        // ---- 0x00–0x0F 控制 / 杂项 ----
        OpInfo(0x00u8, 'OP_NOP', '-', 1, CAT_MISC),
        OpInfo(0x01u8, 'OP_TRAP', 'u8', 2, CAT_MISC),
        OpInfo(0x02u8, 'OP_BREAKPOINT', '-', 1, CAT_MISC),
        OpInfo(0x03u8, 'OP_SET_SITE', 'i32', 5, CAT_MISC),
        OpInfo(0x04u8, 'OP_CHECK_ERR', 'rel32', 5, CAT_MISC),
        OpInfo(0x05u8, 'OP_BAIL', 'i8', 2, CAT_MISC),
        OpInfo(0x06u8, 'OP_CHECK_ERR_NC', '-', 1, CAT_MISC),
        OpInfo(0x07u8, 'OP_STACK_GUARD', 'u16', 3, CAT_MISC),
        // ---- 0x08–0x0F 未分配（RSVD）----
        OpInfo(0x08u8, 'OP_RSVD', '-', 1, CAT_RSVD),
        OpInfo(0x09u8, 'OP_RSVD', '-', 1, CAT_RSVD),
        OpInfo(0x0Au8, 'OP_RSVD', '-', 1, CAT_RSVD),
        OpInfo(0x0Bu8, 'OP_RSVD', '-', 1, CAT_RSVD),
        OpInfo(0x0Cu8, 'OP_RSVD', '-', 1, CAT_RSVD),
        OpInfo(0x0Du8, 'OP_RSVD', '-', 1, CAT_RSVD),
        OpInfo(0x0Eu8, 'OP_RSVD', '-', 1, CAT_RSVD),
        OpInfo(0x0Fu8, 'OP_RSVD', '-', 1, CAT_RSVD),
        // ---- 0x10–0x1F 常量 / 栈 ----
        OpInfo(0x10u8, 'OP_PUSH_I8', 'i8', 2, CAT_CONST),
        OpInfo(0x11u8, 'OP_PUSH_I32', 'i32', 5, CAT_CONST),
        OpInfo(0x12u8, 'OP_PUSH_I64', 'i64', 9, CAT_CONST),
        OpInfo(0x13u8, 'OP_PUSH_F64', 'i64', 9, CAT_CONST),
        OpInfo(0x14u8, 'OP_PUSH_BOOL', 'u8', 2, CAT_CONST),
        OpInfo(0x15u8, 'OP_PUSH_NULL', '-', 1, CAT_CONST),
        OpInfo(0x16u8, 'OP_PUSH_KH', 'u16', 3, CAT_CONST),
        OpInfo(0x17u8, 'OP_DUP', '-', 1, CAT_CONST),
        OpInfo(0x18u8, 'OP_DUP2', '-', 1, CAT_CONST),
        OpInfo(0x19u8, 'OP_POP', '-', 1, CAT_CONST),
        OpInfo(0x1Au8, 'OP_POP2', '-', 1, CAT_CONST),
        OpInfo(0x1Bu8, 'OP_SWAP', '-', 1, CAT_CONST),
        OpInfo(0x1Cu8, 'OP_PICK', 'u8', 2, CAT_CONST),
        // ---- 0x1D–0x1F 未分配（RSVD）----
        OpInfo(0x1Du8, 'OP_RSVD', '-', 1, CAT_RSVD),
        OpInfo(0x1Eu8, 'OP_RSVD', '-', 1, CAT_RSVD),
        OpInfo(0x1Fu8, 'OP_RSVD', '-', 1, CAT_RSVD),
        // ---- 0x20–0x2F 局部变量 ----
        OpInfo(0x20u8, 'OP_LOADL', 'u16', 3, CAT_LOCAL),
        OpInfo(0x21u8, 'OP_STOREL', 'u16', 3, CAT_LOCAL),
        OpInfo(0x22u8, 'OP_LOADL0', '-', 1, CAT_LOCAL),
        OpInfo(0x23u8, 'OP_LOADL1', '-', 1, CAT_LOCAL),
        OpInfo(0x24u8, 'OP_LOADL2', '-', 1, CAT_LOCAL),
        OpInfo(0x25u8, 'OP_LOADL3', '-', 1, CAT_LOCAL),
        OpInfo(0x26u8, 'OP_LOAD_CAP', 'u16', 3, CAT_LOCAL),
        // ---- 0x27–0x2F 未分配（RSVD）----
        OpInfo(0x27u8, 'OP_RSVD', '-', 1, CAT_RSVD),
        OpInfo(0x28u8, 'OP_RSVD', '-', 1, CAT_RSVD),
        OpInfo(0x29u8, 'OP_RSVD', '-', 1, CAT_RSVD),
        OpInfo(0x2Au8, 'OP_RSVD', '-', 1, CAT_RSVD),
        OpInfo(0x2Bu8, 'OP_RSVD', '-', 1, CAT_RSVD),
        OpInfo(0x2Cu8, 'OP_RSVD', '-', 1, CAT_RSVD),
        OpInfo(0x2Du8, 'OP_RSVD', '-', 1, CAT_RSVD),
        OpInfo(0x2Eu8, 'OP_RSVD', '-', 1, CAT_RSVD),
        OpInfo(0x2Fu8, 'OP_RSVD', '-', 1, CAT_RSVD),
        // ---- 0x30–0x3F 整型算术 ----
        OpInfo(0x30u8, 'OP_IADD', '-', 1, CAT_I64),
        OpInfo(0x31u8, 'OP_ISUB', '-', 1, CAT_I64),
        OpInfo(0x32u8, 'OP_IMUL', '-', 1, CAT_I64),
        OpInfo(0x33u8, 'OP_IDIV', '-', 1, CAT_I64),
        OpInfo(0x34u8, 'OP_IMOD', '-', 1, CAT_I64),
        OpInfo(0x35u8, 'OP_INEG', '-', 1, CAT_I64),
        OpInfo(0x36u8, 'OP_IABS', '-', 1, CAT_I64),
        OpInfo(0x37u8, 'OP_IMIN', '-', 1, CAT_I64),
        OpInfo(0x38u8, 'OP_IMAX', '-', 1, CAT_I64),
        OpInfo(0x39u8, 'OP_IADD_WRAP', '-', 1, CAT_I64),
        OpInfo(0x3Au8, 'OP_ICLZ', '-', 1, CAT_I64),
        OpInfo(0x3Bu8, 'OP_IPOPCNT', '-', 1, CAT_I64),
        // ---- 0x3C–0x3F 未分配（RSVD）----
        OpInfo(0x3Cu8, 'OP_RSVD', '-', 1, CAT_RSVD),
        OpInfo(0x3Du8, 'OP_RSVD', '-', 1, CAT_RSVD),
        OpInfo(0x3Eu8, 'OP_RSVD', '-', 1, CAT_RSVD),
        OpInfo(0x3Fu8, 'OP_RSVD', '-', 1, CAT_RSVD),
        // ---- 0x40–0x4F 浮点运算 ----
        OpInfo(0x40u8, 'OP_FADD', '-', 1, CAT_F64),
        OpInfo(0x41u8, 'OP_FSUB', '-', 1, CAT_F64),
        OpInfo(0x42u8, 'OP_FMUL', '-', 1, CAT_F64),
        OpInfo(0x43u8, 'OP_FDIV', '-', 1, CAT_F64),
        OpInfo(0x44u8, 'OP_FDIV_CHK', '-', 1, CAT_F64),
        OpInfo(0x45u8, 'OP_FNEG', '-', 1, CAT_F64),
        OpInfo(0x46u8, 'OP_FABS', '-', 1, CAT_F64),
        OpInfo(0x47u8, 'OP_FMIN', '-', 1, CAT_F64),
        OpInfo(0x48u8, 'OP_FMAX', '-', 1, CAT_F64),
        OpInfo(0x49u8, 'OP_FSQRT', '-', 1, CAT_F64),
        OpInfo(0x4Au8, 'OP_FFLOOR', '-', 1, CAT_F64),
        OpInfo(0x4Bu8, 'OP_FCEIL', '-', 1, CAT_F64),
        OpInfo(0x4Cu8, 'OP_FTRUNC', '-', 1, CAT_F64),
        OpInfo(0x4Du8, 'OP_FROUND', '-', 1, CAT_F64),
        // ---- 0x4E–0x4F 未分配（RSVD）----
        OpInfo(0x4Eu8, 'OP_RSVD', '-', 1, CAT_RSVD),
        OpInfo(0x4Fu8, 'OP_RSVD', '-', 1, CAT_RSVD),
        // ---- 0x50–0x6F 比较 / 逻辑 / 位 ----
        OpInfo(0x50u8, 'OP_CMP_I', '-', 1, CAT_CMP),
        OpInfo(0x51u8, 'OP_CMP_F', '-', 1, CAT_CMP),
        OpInfo(0x52u8, 'OP_EQ_I', '-', 1, CAT_CMP),
        OpInfo(0x53u8, 'OP_NE_I', '-', 1, CAT_CMP),
        OpInfo(0x54u8, 'OP_LT_I', '-', 1, CAT_CMP),
        OpInfo(0x55u8, 'OP_LE_I', '-', 1, CAT_CMP),
        OpInfo(0x56u8, 'OP_GT_I', '-', 1, CAT_CMP),
        OpInfo(0x57u8, 'OP_GE_I', '-', 1, CAT_CMP),
        OpInfo(0x58u8, 'OP_EQ_F', '-', 1, CAT_CMP),
        OpInfo(0x59u8, 'OP_NE_F', '-', 1, CAT_CMP),
        OpInfo(0x5Au8, 'OP_LT_F', '-', 1, CAT_CMP),
        OpInfo(0x5Bu8, 'OP_LE_F', '-', 1, CAT_CMP),
        OpInfo(0x5Cu8, 'OP_GT_F', '-', 1, CAT_CMP),
        OpInfo(0x5Du8, 'OP_GE_F', '-', 1, CAT_CMP),
        OpInfo(0x5Eu8, 'OP_NOT_B', '-', 1, CAT_CMP),
        OpInfo(0x5Fu8, 'OP_AND_B', '-', 1, CAT_CMP),
        OpInfo(0x60u8, 'OP_OR_B', '-', 1, CAT_CMP),
        OpInfo(0x61u8, 'OP_XOR_B', '-', 1, CAT_CMP),
        OpInfo(0x62u8, 'OP_BAND_I', '-', 1, CAT_CMP),
        OpInfo(0x63u8, 'OP_BOR_I', '-', 1, CAT_CMP),
        OpInfo(0x64u8, 'OP_BXOR_I', '-', 1, CAT_CMP),
        OpInfo(0x65u8, 'OP_BNOT_I', '-', 1, CAT_CMP),
        OpInfo(0x66u8, 'OP_SHL_I', '-', 1, CAT_CMP),
        OpInfo(0x67u8, 'OP_SHR_I', '-', 1, CAT_CMP),
        OpInfo(0x68u8, 'OP_USHR_I', '-', 1, CAT_CMP),
        OpInfo(0x69u8, 'OP_EQ_H', '-', 1, CAT_CMP),
        OpInfo(0x6Au8, 'OP_NE_H', '-', 1, CAT_CMP),
        OpInfo(0x6Bu8, 'OP_CMP_STR', '-', 1, CAT_CMP),
        OpInfo(0x6Cu8, 'OP_CMP_DEC', '-', 1, CAT_CMP),
        OpInfo(0x6Du8, 'OP_CMP_DT', '-', 1, CAT_CMP),
        OpInfo(0x6Eu8, 'OP_CMP_DUR', '-', 1, CAT_CMP),
        // ---- 0x6F 未分配（RSVD）----
        OpInfo(0x6Fu8, 'OP_RSVD', '-', 1, CAT_RSVD),
        // ---- 0x70–0x7F 控制流与调用 ----
        OpInfo(0x70u8, 'OP_JMP', 'rel32', 5, CAT_CTRL),
        OpInfo(0x71u8, 'OP_JZ', 'rel32', 5, CAT_CTRL),
        OpInfo(0x72u8, 'OP_JNZ', 'rel32', 5, CAT_CTRL),
        // ---- 0x73 未分配（RSVD）----
        OpInfo(0x73u8, 'OP_RSVD', '-', 1, CAT_RSVD),
        OpInfo(0x74u8, 'OP_LOOP_BACK', 'rel32', 5, CAT_CTRL),
        OpInfo(0x75u8, 'OP_CALL_HELPER', 'u16 u8', 4, CAT_CALL),
        OpInfo(0x76u8, 'OP_CALL_HELPER_NC', 'u16 u8', 4, CAT_CALL),
        OpInfo(0x77u8, 'OP_CALL_HELPER_V', 'u16 u8', 4, CAT_CALL),
        OpInfo(0x78u8, 'OP_CALL_FUNC', 'u16 u8', 4, CAT_CALL),
        OpInfo(0x79u8, 'OP_CALL_HOST', 'u16 u8', 4, CAT_CALL),
        OpInfo(0x7Au8, 'OP_HW_OPEN', 'u16', 3, CAT_CALL),
        OpInfo(0x7Bu8, 'OP_HW_CLOSE', '-', 1, CAT_CALL),
        OpInfo(0x7Cu8, 'OP_RET', '-', 1, CAT_CALL),
        OpInfo(0x7Du8, 'OP_RET_VOID', '-', 1, CAT_CALL),
        OpInfo(0x7Eu8, 'OP_RET_NULL', '-', 1, CAT_CALL),
        OpInfo(0x7Fu8, 'OP_CALL_CLOSURE', 'u8', 2, CAT_CALL),
        // ---- 0x80–0x8F 类型 / 转换 / 错误 ----
        OpInfo(0x80u8, 'OP_CAST', 'u16 u8', 4, CAT_TYPE),
        OpInfo(0x81u8, 'OP_TO_I64', 'u8', 2, CAT_TYPE),
        OpInfo(0x82u8, 'OP_TO_F64', '-', 1, CAT_TYPE),
        OpInfo(0x83u8, 'OP_IS_TYPE', 'u16', 3, CAT_TYPE),
        OpInfo(0x84u8, 'OP_GUARD_TYPE', 'u16 u8', 4, CAT_TYPE),
        OpInfo(0x85u8, 'OP_THROW', 'u8', 2, CAT_TYPE),
        OpInfo(0x86u8, 'OP_ASSERT', 'u8', 2, CAT_TYPE),
        OpInfo(0x87u8, 'OP_ABORT', 'u8', 2, CAT_TYPE),
        OpInfo(0x88u8, 'OP_GUARD_NNZ', 'u8', 2, CAT_TYPE),
        OpInfo(0x89u8, 'OP_TYPE_OF', '-', 1, CAT_TYPE),
        // ---- 0x8A–0x8F 未分配（RSVD）----
        OpInfo(0x8Au8, 'OP_RSVD', '-', 1, CAT_RSVD),
        OpInfo(0x8Bu8, 'OP_RSVD', '-', 1, CAT_RSVD),
        OpInfo(0x8Cu8, 'OP_RSVD', '-', 1, CAT_RSVD),
        OpInfo(0x8Du8, 'OP_RSVD', '-', 1, CAT_RSVD),
        OpInfo(0x8Eu8, 'OP_RSVD', '-', 1, CAT_RSVD),
        OpInfo(0x8Fu8, 'OP_RSVD', '-', 1, CAT_RSVD),
        // ---- 0x90–0x9F 容器 / 值提取 / 数值转换 ----
        OpInfo(0x90u8, 'OP_LEN', '-', 1, CAT_BOX),
        OpInfo(0x91u8, 'OP_GET_IDX', '-', 1, CAT_BOX),
        OpInfo(0x92u8, 'OP_GET_KEY', '-', 1, CAT_BOX),
        OpInfo(0x93u8, 'OP_GET_KEY_OR', '-', 1, CAT_BOX),
        OpInfo(0x94u8, 'OP_HAS_KEY', '-', 1, CAT_BOX),
        OpInfo(0x95u8, 'OP_STR_AT', '-', 1, CAT_BOX),
        OpInfo(0x96u8, 'OP_DT_FIELD', 'u8', 2, CAT_BOX),
        OpInfo(0x97u8, 'OP_DUR_TICKS', '-', 1, CAT_BOX),
        OpInfo(0x98u8, 'OP_DEC_IS_INT', '-', 1, CAT_BOX),
        OpInfo(0x99u8, 'OP_HANDLE_TAG', '-', 1, CAT_BOX),
        OpInfo(0x9Au8, 'OP_RANGE_NEW', '-', 1, CAT_BOX),
        OpInfo(0x9Bu8, 'OP_RANGE_CONTAINS', '-', 1, CAT_BOX),
        OpInfo(0x9Cu8, 'OP_TO_DEC', 'u8', 2, CAT_BOX),
        OpInfo(0x9Du8, 'OP_DEC_TO_I64', 'u8', 2, CAT_BOX),
        OpInfo(0x9Eu8, 'OP_DEC_TO_F64', '-', 1, CAT_BOX),
        // ---- 0x9F 未分配（RSVD）----
        OpInfo(0x9Fu8, 'OP_RSVD', '-', 1, CAT_RSVD),
        // ---- 0xA0–0xAF 分配 / 变更区（0xA9–AA 禁用；其余随 v0.5 / v0.18 启用，归入 BOX）----
        OpInfo(0xA0u8, 'OP_MAKE_LIST', '-', 1, CAT_BOX),
        OpInfo(0xA1u8, 'OP_LIST_APPEND', '-', 1, CAT_BOX),
        OpInfo(0xA2u8, 'OP_MAKE_MAP', '-', 1, CAT_BOX),
        OpInfo(0xA3u8, 'OP_MAP_PUT', '-', 1, CAT_BOX),
        OpInfo(0xA4u8, 'OP_STR_CAT', '-', 1, CAT_BOX),
        OpInfo(0xA5u8, 'OP_DEC_ADD', '-', 1, CAT_BOX),
        OpInfo(0xA6u8, 'OP_DEC_SUB', '-', 1, CAT_BOX),
        OpInfo(0xA7u8, 'OP_DEC_MUL', '-', 1, CAT_BOX),
        OpInfo(0xA8u8, 'OP_DEC_DIV', '-', 1, CAT_BOX),
        OpInfo(0xA9u8, 'OP_DT_NEW', '-', 1, CAT_FORBID),
        OpInfo(0xAAu8, 'OP_DUR_NEW', '-', 1, CAT_FORBID),
        OpInfo(0xABu8, 'OP_LIST_INSERT', '-', 1, CAT_BOX),
        OpInfo(0xACu8, 'OP_LIST_SET', '-', 1, CAT_BOX),
        OpInfo(0xADu8, 'OP_LIST_REMOVE', '-', 1, CAT_BOX),
        OpInfo(0xAEu8, 'OP_MAP_REMOVE', '-', 1, CAT_BOX),
        OpInfo(0xAFu8, 'OP_MAP_ITER_BEGIN', '-', 1, CAT_BOX),
        // ---- 0xB0–0xB7 时间运算 / 文本化 ----
        OpInfo(0xB0u8, 'OP_DT_ADD', '-', 1, CAT_BOX),
        OpInfo(0xB1u8, 'OP_DT_SUB', '-', 1, CAT_BOX),
        OpInfo(0xB2u8, 'OP_DUR_ADD', '-', 1, CAT_BOX),
        OpInfo(0xB3u8, 'OP_DUR_SUB', '-', 1, CAT_BOX),
        OpInfo(0xB4u8, 'OP_DUR_MUL', '-', 1, CAT_BOX),
        OpInfo(0xB5u8, 'OP_DUR_DIV', '-', 1, CAT_BOX),
        OpInfo(0xB6u8, 'OP_DUR_NEG', '-', 1, CAT_BOX),
        OpInfo(0xB7u8, 'OP_TO_STR', 'u8', 2, CAT_BOX),
        // ---- 0xB8–0xBF 字符串切片替换 / 正则 / 重复 / 日期差 / Map 迭代步进 / 串建 Regex ----
        OpInfo(0xB8u8, 'OP_STR_SUB', '-', 1, CAT_BOX),
        OpInfo(0xB9u8, 'OP_STR_REPLACE', '-', 1, CAT_BOX),
        OpInfo(0xBAu8, 'OP_REGEX_IS_MATCH', '-', 1, CAT_BOX),
        OpInfo(0xBBu8, 'OP_REGEX_FIND', '-', 1, CAT_BOX),
        OpInfo(0xBCu8, 'OP_STR_REPEAT', '-', 1, CAT_BOX),
        OpInfo(0xBDu8, 'OP_DT_DIFF', '-', 1, CAT_BOX),
        OpInfo(0xBEu8, 'OP_MAP_ITER_STEP', 'u8', 2, CAT_BOX),
        OpInfo(0xBFu8, 'OP_STR_TO_REGEX', '-', 1, CAT_BOX),
        // ---- 0xC0–0xFF 保留（预留 M2：HW_OPEN 区块内批量分配、CALL_HOST）----
        OpInfo(0xC0u8, 'OP_RSVD', '-', 1, CAT_RSVD),
        OpInfo(0xC1u8, 'OP_RSVD', '-', 1, CAT_RSVD),
        OpInfo(0xC2u8, 'OP_RSVD', '-', 1, CAT_RSVD),
        OpInfo(0xC3u8, 'OP_RSVD', '-', 1, CAT_RSVD),
        OpInfo(0xC4u8, 'OP_RSVD', '-', 1, CAT_RSVD),
        OpInfo(0xC5u8, 'OP_RSVD', '-', 1, CAT_RSVD),
        OpInfo(0xC6u8, 'OP_RSVD', '-', 1, CAT_RSVD),
        OpInfo(0xC7u8, 'OP_RSVD', '-', 1, CAT_RSVD),
        OpInfo(0xC8u8, 'OP_RSVD', '-', 1, CAT_RSVD),
        OpInfo(0xC9u8, 'OP_RSVD', '-', 1, CAT_RSVD),
        OpInfo(0xCAu8, 'OP_RSVD', '-', 1, CAT_RSVD),
        OpInfo(0xCBu8, 'OP_RSVD', '-', 1, CAT_RSVD),
        OpInfo(0xCCu8, 'OP_RSVD', '-', 1, CAT_RSVD),
        OpInfo(0xCDu8, 'OP_RSVD', '-', 1, CAT_RSVD),
        OpInfo(0xCEu8, 'OP_RSVD', '-', 1, CAT_RSVD),
        OpInfo(0xCFu8, 'OP_RSVD', '-', 1, CAT_RSVD),
        OpInfo(0xD0u8, 'OP_RSVD', '-', 1, CAT_RSVD),
        OpInfo(0xD1u8, 'OP_RSVD', '-', 1, CAT_RSVD),
        OpInfo(0xD2u8, 'OP_RSVD', '-', 1, CAT_RSVD),
        OpInfo(0xD3u8, 'OP_RSVD', '-', 1, CAT_RSVD),
        OpInfo(0xD4u8, 'OP_RSVD', '-', 1, CAT_RSVD),
        OpInfo(0xD5u8, 'OP_RSVD', '-', 1, CAT_RSVD),
        OpInfo(0xD6u8, 'OP_RSVD', '-', 1, CAT_RSVD),
        OpInfo(0xD7u8, 'OP_RSVD', '-', 1, CAT_RSVD),
        OpInfo(0xD8u8, 'OP_RSVD', '-', 1, CAT_RSVD),
        OpInfo(0xD9u8, 'OP_RSVD', '-', 1, CAT_RSVD),
        OpInfo(0xDAu8, 'OP_RSVD', '-', 1, CAT_RSVD),
        OpInfo(0xDBu8, 'OP_RSVD', '-', 1, CAT_RSVD),
        OpInfo(0xDCu8, 'OP_RSVD', '-', 1, CAT_RSVD),
        OpInfo(0xDDu8, 'OP_RSVD', '-', 1, CAT_RSVD),
        OpInfo(0xDEu8, 'OP_RSVD', '-', 1, CAT_RSVD),
        OpInfo(0xDFu8, 'OP_RSVD', '-', 1, CAT_RSVD),
        OpInfo(0xE0u8, 'OP_RSVD', '-', 1, CAT_RSVD),
        OpInfo(0xE1u8, 'OP_RSVD', '-', 1, CAT_RSVD),
        OpInfo(0xE2u8, 'OP_RSVD', '-', 1, CAT_RSVD),
        OpInfo(0xE3u8, 'OP_RSVD', '-', 1, CAT_RSVD),
        OpInfo(0xE4u8, 'OP_RSVD', '-', 1, CAT_RSVD),
        OpInfo(0xE5u8, 'OP_RSVD', '-', 1, CAT_RSVD),
        OpInfo(0xE6u8, 'OP_RSVD', '-', 1, CAT_RSVD),
        OpInfo(0xE7u8, 'OP_RSVD', '-', 1, CAT_RSVD),
        OpInfo(0xE8u8, 'OP_RSVD', '-', 1, CAT_RSVD),
        OpInfo(0xE9u8, 'OP_RSVD', '-', 1, CAT_RSVD),
        OpInfo(0xEAu8, 'OP_RSVD', '-', 1, CAT_RSVD),
        OpInfo(0xEBu8, 'OP_RSVD', '-', 1, CAT_RSVD),
        OpInfo(0xECu8, 'OP_RSVD', '-', 1, CAT_RSVD),
        OpInfo(0xEDu8, 'OP_RSVD', '-', 1, CAT_RSVD),
        OpInfo(0xEEu8, 'OP_RSVD', '-', 1, CAT_RSVD),
        OpInfo(0xEFu8, 'OP_RSVD', '-', 1, CAT_RSVD),
        OpInfo(0xF0u8, 'OP_RSVD', '-', 1, CAT_RSVD),
        OpInfo(0xF1u8, 'OP_RSVD', '-', 1, CAT_RSVD),
        OpInfo(0xF2u8, 'OP_RSVD', '-', 1, CAT_RSVD),
        OpInfo(0xF3u8, 'OP_RSVD', '-', 1, CAT_RSVD),
        OpInfo(0xF4u8, 'OP_RSVD', '-', 1, CAT_RSVD),
        OpInfo(0xF5u8, 'OP_RSVD', '-', 1, CAT_RSVD),
        OpInfo(0xF6u8, 'OP_RSVD', '-', 1, CAT_RSVD),
        OpInfo(0xF7u8, 'OP_RSVD', '-', 1, CAT_RSVD),
        OpInfo(0xF8u8, 'OP_RSVD', '-', 1, CAT_RSVD),
        OpInfo(0xF9u8, 'OP_RSVD', '-', 1, CAT_RSVD),
        OpInfo(0xFAu8, 'OP_RSVD', '-', 1, CAT_RSVD),
        OpInfo(0xFBu8, 'OP_RSVD', '-', 1, CAT_RSVD),
        OpInfo(0xFCu8, 'OP_RSVD', '-', 1, CAT_RSVD),
        OpInfo(0xFDu8, 'OP_RSVD', '-', 1, CAT_RSVD),
        OpInfo(0xFEu8, 'OP_RSVD', '-', 1, CAT_RSVD),
        OpInfo(0xFFu8, 'OP_RSVD', '-', 1, CAT_RSVD)
    ]
}
