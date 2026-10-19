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

/**
 * 固定 helper 编号（hid）常量命名空间 —— design-m1 §5.3.4、plan-m1 S4.7。
 *
 * 数值权威 = `doc/jit-bytecode-m1.md` §6「M1 @C helper 清单」。M1 登记 **1–62 与 69–72**；
 * M2 追加 **63 `host_call_trampoline`**（m2 §2/§5），**64–68** 仍保留给后续增量。
 * 单元私有预定义 helper 走 `[0x0100, 0xFFFF]`（§8.4），与本表不重叠。
 *
 * 与 `LocalType` / `ErrCode` / `TypeToken` 同族：hid 是要**烘焙进机器码**的线上码，用
 * 「类 + `static const`」承载（design D3）。
 */
public class HelperId {
    public static const H_LEN: UInt16 = 1u16
    public static const HL_GET: UInt16 = 2u16
    public static const HM_LEN: UInt16 = 3u16
    public static const HM_GET: UInt16 = 4u16
    public static const HM_GET_OR: UInt16 = 5u16
    public static const HM_HAS: UInt16 = 6u16
    public static const HS_LEN: UInt16 = 7u16
    public static const HS_AT: UInt16 = 8u16
    public static const HS_CMP: UInt16 = 9u16
    public static const H_REF_EQ: UInt16 = 10u16
    public static const HD_CMP: UInt16 = 11u16
    public static const HD_IS_INT: UInt16 = 12u16
    public static const HT_CMP: UInt16 = 13u16
    public static const HT_FIELD: UInt16 = 14u16
    public static const HDUR_CMP: UInt16 = 15u16
    public static const HDUR_TICKS: UInt16 = 16u16
    public static const H_IS_TYPE: UInt16 = 17u16
    public static const H_TAG_OF: UInt16 = 18u16
    public static const H_GUARD: UInt16 = 19u16
    public static const H_NONNULL: UInt16 = 20u16
    public static const ERR_RAISE: UInt16 = 21u16
    public static const INTERRUPT_POLL: UInt16 = 22u16
    public static const HW_CHECK: UInt16 = 23u16
    public static const DEC_ADD: UInt16 = 24u16
    public static const DEC_SUB: UInt16 = 25u16
    public static const DEC_MUL: UInt16 = 26u16
    public static const DEC_DIV: UInt16 = 27u16
    public static const DEC_FROM_I64: UInt16 = 28u16
    public static const DEC_FROM_F64: UInt16 = 29u16
    public static const DEC_TO_I64: UInt16 = 30u16
    public static const DEC_TO_F64: UInt16 = 31u16
    public static const STR_CAT: UInt16 = 32u16
    public static const TO_STR: UInt16 = 33u16
    public static const DT_ADD: UInt16 = 34u16
    public static const DT_SUB: UInt16 = 35u16
    public static const DUR_ADD: UInt16 = 36u16
    public static const DUR_SUB: UInt16 = 37u16
    public static const DUR_MUL: UInt16 = 38u16
    public static const DUR_DIV: UInt16 = 39u16
    public static const DUR_NEG: UInt16 = 40u16
    public static const RANGE_NEW: UInt16 = 41u16
    public static const RANGE_CONTAINS: UInt16 = 42u16
    public static const LIST_ADD: UInt16 = 43u16
    public static const MAP_PUT: UInt16 = 44u16
    public static const LIST_INSERT: UInt16 = 45u16
    public static const LIST_SET: UInt16 = 46u16
    public static const LIST_REMOVE: UInt16 = 47u16
    public static const MAP_REMOVE: UInt16 = 48u16
    public static const MAP_ITER_BEGIN: UInt16 = 49u16
    public static const STR_SUB: UInt16 = 50u16
    public static const STR_REPLACE: UInt16 = 51u16
    public static const REGEX_IS_MATCH: UInt16 = 52u16
    public static const REGEX_FIND: UInt16 = 53u16
    public static const CLOSURE_NEW: UInt16 = 54u16
    public static const CLOSURE_FNID: UInt16 = 55u16
    public static const CLOSURE_CAP: UInt16 = 56u16
    public static const FN_TABLE: UInt16 = 57u16
    public static const REGEX_REPLACE_ALL: UInt16 = 58u16
    public static const REGEX_REPLACE_NTH: UInt16 = 59u16
    public static const STR_REPEAT: UInt16 = 60u16
    public static const DT_DIFF: UInt16 = 61u16
    public static const MAP_ITER_STEP: UInt16 = 62u16

    /** M2 §5：CALL_HOST 的宿主闭包转发器。 */
    public static const HOST_CALL_TRAMPOLINE: UInt16 = 63u16
    /** M2 §12.2：实例字段读 / 写（H64/H65）。 */
    public static const HOST_GET_FIELD: UInt16 = 64u16
    public static const HOST_SET_FIELD: UInt16 = 65u16
    public static const STR_TO_REGEX: UInt16 = 69u16
    public static const LIST_NEW: UInt16 = 70u16
    public static const MAP_NEW: UInt16 = 71u16
    public static const REGEX_REPLACE_RANGE: UInt16 = 72u16

    /** 时间构造（M1 扩展）。 */
    public static const DATETIME_NOW: UInt16 = 73u16
    public static const DATETIME_PARSE: UInt16 = 74u16
    public static const DATETIME_OF: UInt16 = 75u16
    public static const DURATION_PARSE: UInt16 = 76u16

    /** M1 登记区间下界 / 上界（`CALL_HELPER` 的 hid 合法值域，§5）。 */
    public static const MIN_FIXED: UInt16 = 1u16
    public static const MAX_FIXED: UInt16 = 72u16
    /** 单元私有预定义 helper 起址（§8.4）。 */
    public static const USER_BASE: UInt16 = 0x0100u16

    /** hid → 名称（诊断用）；63–68 与未登记值给非空兜底。 */
    public static func name(hid: UInt16): String {
        match (hid) {
            case 1u16 => 'hl_len'
            case 2u16 => 'hl_get'
            case 3u16 => 'hm_len'
            case 4u16 => 'hm_get'
            case 5u16 => 'hm_get_or'
            case 6u16 => 'hm_has'
            case 7u16 => 'hs_len'
            case 8u16 => 'hs_at'
            case 9u16 => 'hs_cmp'
            case 10u16 => 'h_ref_eq'
            case 11u16 => 'hd_cmp'
            case 12u16 => 'hd_is_int'
            case 13u16 => 'ht_cmp'
            case 14u16 => 'ht_field'
            case 15u16 => 'hdur_cmp'
            case 16u16 => 'hdur_ticks'
            case 17u16 => 'h_is_type'
            case 18u16 => 'h_tag_of'
            case 19u16 => 'h_guard'
            case 20u16 => 'h_nonnull'
            case 21u16 => 'err_raise'
            case 22u16 => 'interrupt_poll'
            case 23u16 => 'hw_check'
            case 24u16 => 'dec_add'
            case 25u16 => 'dec_sub'
            case 26u16 => 'dec_mul'
            case 27u16 => 'dec_div'
            case 28u16 => 'dec_from_i64'
            case 29u16 => 'dec_from_f64'
            case 30u16 => 'dec_to_i64'
            case 31u16 => 'dec_to_f64'
            case 32u16 => 'str_cat'
            case 33u16 => 'to_str'
            case 34u16 => 'dt_add'
            case 35u16 => 'dt_sub'
            case 36u16 => 'dur_add'
            case 37u16 => 'dur_sub'
            case 38u16 => 'dur_mul'
            case 39u16 => 'dur_div'
            case 40u16 => 'dur_neg'
            case 41u16 => 'range_new'
            case 42u16 => 'range_contains'
            case 43u16 => 'list_add'
            case 44u16 => 'map_put'
            case 45u16 => 'list_insert'
            case 46u16 => 'list_set'
            case 47u16 => 'list_remove'
            case 48u16 => 'map_remove'
            case 49u16 => 'map_iter_begin'
            case 50u16 => 'str_sub'
            case 51u16 => 'str_replace'
            case 52u16 => 'regex_is_match'
            case 53u16 => 'regex_find'
            case 54u16 => 'closure_new'
            case 55u16 => 'closure_fnid'
            case 56u16 => 'closure_cap'
            case 57u16 => 'fn_table'
            case 58u16 => 'regex_replace_all'
            case 59u16 => 'regex_replace_nth'
            case 60u16 => 'str_repeat'
            case 61u16 => 'dt_diff'
            case 62u16 => 'map_iter_step'
            case 63u16 => 'host_call_trampoline'
            case 64u16 => 'host_get_field'
            case 65u16 => 'host_set_field'
            case 69u16 => 'str_to_regex'
            case 70u16 => 'list_new'
            case 71u16 => 'map_new'
            case 72u16 => 'regex_replace_range'
            // ---- 时间构造（M1 扩展，73–76）----
            case 73u16 => 'datetime_now'
            case 74u16 => 'datetime_parse'
            case 75u16 => 'datetime_of'
            case 76u16 => 'duration_parse'
            case _ =>
                if (hid == 66u16 || hid == 67u16 || hid == 68u16) {
                    'reserved(${hid})'
                } else {
                    'unknown(${hid})'
                }
        }
    }

    /** 是否为 M1 已登记的固定 helper（63–68 与区间外 ⇒ false）。 */
    public static func isFixed(hid: UInt16): Bool {
        let n = name(hid)
        !(n.startsWith('reserved(') || n.startsWith('unknown('))
    }
}
