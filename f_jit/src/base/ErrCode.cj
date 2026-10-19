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
package fountain::f_jit.base

/**
 * 运行期错误码常量命名空间 —— design-m1 §2.3.10、plan-m1 S1.3。
 *
 * 数值权威 = `doc/jit-bytecode-m1.md` §2 错误码表 + `doc/jit-bytecode-m2.md` §2 增量。三条非错误态
 * （`0 OK` / `-1 DEOPT` / `-2 INTERRUPT`）与 1–21、`23`、`99` 全部按表登记；`21
 * ERR_HOST_EXCEPTION`（M2）为**仓颉侧异常专用码**，`22 ERR_ANY_CAST`（M3）仍落在「未登记码」的
 * 兜底分支。
 *
 * 与 `LocalType` / `TypeToken` 同族，用「类 + `static const`」承载（design D3）：错误码要写进
 * ctx 错误槽、要参与 `Report.throwJit` 的分派，`describe` 是**静态表、无宏**（design §2.3.10）。
 */
public class ErrCode {
    /** 非错误态：0 走值路径、-1 由桥退回解释器重跑、-2 抛 InterruptedException（§2 表头三行）。 */
    public static const OK: Int64 = 0
    public static const DEOPT: Int64 = -1
    public static const INTERRUPT: Int64 = -2

    public static const DIV_ZERO: Int64 = 1
    public static const MOD_ZERO: Int64 = 2
    /** 含 `INT_MIN / -1` 与 `INT_MIN` 取负（§2 行 3）。 */
    public static const OVERFLOW_I64: Int64 = 3
    /** 下标越界：`GET_IDX` / `STR_AT` / `STR_SUB`（后者 a/b 为码点索引）。 */
    public static const IDX_OOB: Int64 = 4
    public static const KEY_MISSING: Int64 = 5
    /** 对 null 句柄取用。 */
    public static const NULL_HANDLE: Int64 = 6
    /** 值转型失败（仅 `CAST` 用；句柄类型不符走 8）。 */
    public static const BAD_CAST: Int64 = 7
    /** 句柄类型不符：helper fetch 与 `GUARD_TYPE` 共用。 */
    public static const HANDLE_TYPE: Int64 = 8
    /** `DEC_TO_I64` 越界（Decimal 任意精度，算术本身无范围溢出）。 */
    public static const DEC_RANGE: Int64 = 9
    /** Decimal ÷0，含 0÷0。 */
    public static const DEC_DIV_ZERO: Int64 = 10
    /** `DT ± DUR` 结果超出 DateTime 值域。 */
    public static const DT_RANGE: Int64 = 11
    /** Duration 算术溢出。 */
    public static const DUR_OVERFLOW: Int64 = 12
    /** NaN / Inf 转整型，以及 F64 → Decimal。 */
    public static const FP_INVALID: Int64 = 13
    /** `CALL_FUNC` argc 不符；`RANGE_NEW` step=0；`STR_REPLACE` 空模式；正则非法 pattern/flags；桥入口断言。 */
    public static const ARG_MISMATCH: Int64 = 14
    /** DEOPT 后解释器余量亦不足、无法重跑时由桥写入。 */
    public static const STACK_GUARD: Int64 = 15
    /** 宿主句柄表全局上限（资源耗尽）。 */
    public static const HANDLE_WINDOW_FULL: Int64 = 16
    /** 源语言 `throw`；具体码放 site 附加表。 */
    public static const EXPLICIT: Int64 = 17
    /** 汇编器遇到未实现特性时主动 bail。 */
    public static const NOT_IMPL: Int64 = 18
    /** `call` 的调用契约错误：桥层产生、`site = -1`、不经字节码执行。 */
    public static const CALL_CONTRACT: Int64 = 19
    /** 对常量 / 冻结容器写入（变更型 helper 的目标槽属路径 A）。 */
    public static const READONLY: Int64 = 20
    /**
     * 宿主（仓颉侧）调用面执行期异常且未回译（M2 §2、§13-6）。
     *
     * 覆盖 CALL_HOST 闭包、预定义与包装调用、构造适配器、成员访问器；`cause` 附原始异常全文
     * （含完整仓颉栈），`site` = 对应调用指令偏移。与引擎侧兜底 `99` **严格区分**。
     */
    public static const HOST_EXCEPTION: Int64 = 21
    /** for-in 遍历 Map 期间修改同一 map（fail-fast，转码自 std 的 ConcurrentModificationException）。 */
    public static const CONCURRENT_MOD: Int64 = 23
    /** 引擎侧未识别异常兜底（msg 前缀 `internal helper failure`）。 */
    public static const HELPER_PANIC: Int64 = 99

    /**
     * 错误码 → 静态描述文本（桥静态表，无宏；design-m1 §2.3.10）。
     *
     * 文本带常量名是为了让「描述含语义关键词」可被断言（spec「描述可断言」场景）；文案本身
     * **不冻结**，可自由改写。未登记码一律走非空兜底（不谎称属于已定义码）。
     */
    public static func describe(code: Int64): String {
        match (code) {
            case 0 => 'OK 成功：无错误，走值路径'
            case -1 => 'DEOPT 去优化：类型不符或资源不足，桥退回解释器重跑'
            case -2 => 'INTERRUPT 中断：取消或超时，桥抛 InterruptedException'
            case 1 => 'ERR_DIV_ZERO 除数为零'
            case 2 => 'ERR_MOD_ZERO 取模运算除数为零'
            case 3 => 'ERR_OVERFLOW_I64 整数溢出（含 INT_MIN / -1 与 INT_MIN 取负）'
            case 4 => 'ERR_IDX_OOB 下标越界'
            case 5 => 'ERR_KEY_MISSING 键不存在'
            case 6 => 'ERR_NULL_HANDLE 对 null 句柄取用'
            case 7 => 'ERR_BAD_CAST 值转型失败'
            case 8 => 'ERR_HANDLE_TYPE 句柄类型不符'
            case 9 => 'ERR_DEC_RANGE Decimal 转 Int64 越界'
            case 10 => 'ERR_DEC_DIV_ZERO Decimal 除数为零'
            case 11 => 'ERR_DT_RANGE DateTime 运算结果超出值域'
            case 12 => 'ERR_DUR_OVERFLOW Duration 算术溢出'
            case 13 => 'ERR_FP_INVALID 浮点值非法（NaN / Inf 转整型，F64 转 Decimal）'
            case 14 => 'ERR_ARG_MISMATCH 实参个数或参数非法'
            case 15 => 'ERR_STACK_GUARD 栈余量不足，无法重跑'
            case 16 => 'ERR_HANDLE_WINDOW_FULL 句柄表全局上限耗尽'
            case 17 => 'ERR_EXPLICIT 源语言 throw'
            case 18 => 'ERR_NOT_IMPL 未实现特性'
            case 19 => 'ERR_CALL_CONTRACT 调用契约错误（桥层产生，site = -1）'
            case 20 => 'ERR_READONLY 对常量或冻结容器写入'
            case 21 => 'ERR_HOST_EXCEPTION 宿主侧异常：仓颉侧调用面抛出且未回译（含完整仓颉栈）'
            case 23 => 'ERR_CONCURRENT_MOD 遍历期间并发修改'
            case 99 => 'ERR_HELPER_PANIC helper 内部未识别异常（引擎侧兜底）'
            case _ => 'ERR_UNREGISTERED 未登记错误码 ${code}'
        }
    }

    /**
     * 宿主侧（宿主 / 桥侧产生、不经字节码执行）错误码判定。
     *
     * M2 起仅 `21 ERR_HOST_EXCEPTION` 为真（design-m2 §2「`isHostSide(code)`（实现落地）」）；
     * 其余码——含引擎侧兜底 `99`——均为假，21/99 不得混用。
     */
    public static func isHostSide(code: Int64): Bool {
        match (code) {
            case 21 => true
            case _ => false
        }
    }
}
