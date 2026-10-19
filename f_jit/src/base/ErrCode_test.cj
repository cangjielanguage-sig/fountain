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

import std.unittest.*
import std.unittest.testmacro.*

/**
 * S1.3 `ErrCode` 的失败用例（先写红）。
 *
 * 数值权威 = `doc/jit-bytecode-m1.md` §2 错误码表（`0 OK`、`-1 DEOPT`、`-2 INTERRUPT`、
 * `1–20`、`23 ERR_CONCURRENT_MOD`、`99 ERR_HELPER_PANIC`）；`21/22` 是 M2/M3 码，本步不登记
 * （design-m1 §2.3.10「21/22 的 M2/M3 行后续版本追加」）。
 *
 * `isHostSide` 的口径同样出自 design-m1 §2.3.10：`isHostSide` 是「M2 起 21 判定占位
 * （M1 恒 false）」，design-m2 §2 的 `isHostSide(code)（实现落地）` 亦标注「M1 占位返回 false」。
 */
@Test
public class ErrCode_test {
    /** 全部已定义码值与 §2 表逐项一致。 */
    @TestCase
    public func constantsMatchSpecTable(): Unit {
        @Assert(ErrCode.OK, 0)
        @Assert(ErrCode.DEOPT, -1)
        @Assert(ErrCode.INTERRUPT, -2)
        @Assert(ErrCode.DIV_ZERO, 1)
        @Assert(ErrCode.MOD_ZERO, 2)
        @Assert(ErrCode.OVERFLOW_I64, 3)
        @Assert(ErrCode.IDX_OOB, 4)
        @Assert(ErrCode.KEY_MISSING, 5)
        @Assert(ErrCode.NULL_HANDLE, 6)
        @Assert(ErrCode.BAD_CAST, 7)
        @Assert(ErrCode.HANDLE_TYPE, 8)
        @Assert(ErrCode.DEC_RANGE, 9)
        @Assert(ErrCode.DEC_DIV_ZERO, 10)
        @Assert(ErrCode.DT_RANGE, 11)
        @Assert(ErrCode.DUR_OVERFLOW, 12)
        @Assert(ErrCode.FP_INVALID, 13)
        @Assert(ErrCode.ARG_MISMATCH, 14)
        @Assert(ErrCode.STACK_GUARD, 15)
        @Assert(ErrCode.HANDLE_WINDOW_FULL, 16)
        @Assert(ErrCode.EXPLICIT, 17)
        @Assert(ErrCode.NOT_IMPL, 18)
        @Assert(ErrCode.CALL_CONTRACT, 19)
        @Assert(ErrCode.READONLY, 20)
        @Assert(ErrCode.HOST_EXCEPTION, 21)
        @Assert(ErrCode.CONCURRENT_MOD, 23)
        @Assert(ErrCode.HELPER_PANIC, 99)
    }

    /** 每个已定义码的 `describe` 非空，且含该码的语义关键词（常量名）。 */
    @TestCase
    public func describeIsNonEmptyAndCarriesKeyword(): Unit {
        let codes = [
            ErrCode.OK, ErrCode.DEOPT, ErrCode.INTERRUPT,
            ErrCode.DIV_ZERO, ErrCode.MOD_ZERO, ErrCode.OVERFLOW_I64, ErrCode.IDX_OOB,
            ErrCode.KEY_MISSING, ErrCode.NULL_HANDLE, ErrCode.BAD_CAST, ErrCode.HANDLE_TYPE,
            ErrCode.DEC_RANGE, ErrCode.DEC_DIV_ZERO, ErrCode.DT_RANGE, ErrCode.DUR_OVERFLOW,
            ErrCode.FP_INVALID, ErrCode.ARG_MISMATCH, ErrCode.STACK_GUARD,
            ErrCode.HANDLE_WINDOW_FULL, ErrCode.EXPLICIT, ErrCode.NOT_IMPL,
            ErrCode.CALL_CONTRACT, ErrCode.READONLY, ErrCode.HOST_EXCEPTION,
            ErrCode.CONCURRENT_MOD, ErrCode.HELPER_PANIC
        ]
        let keywords = [
            'OK', 'DEOPT', 'INTERRUPT',
            'DIV_ZERO', 'MOD_ZERO', 'OVERFLOW_I64', 'IDX_OOB',
            'KEY_MISSING', 'NULL_HANDLE', 'BAD_CAST', 'HANDLE_TYPE',
            'DEC_RANGE', 'DEC_DIV_ZERO', 'DT_RANGE', 'DUR_OVERFLOW',
            'FP_INVALID', 'ARG_MISMATCH', 'STACK_GUARD',
            'HANDLE_WINDOW_FULL', 'EXPLICIT', 'NOT_IMPL',
            'CALL_CONTRACT', 'READONLY', 'HOST_EXCEPTION',
            'CONCURRENT_MOD', 'HELPER_PANIC'
        ]
        @Assert(codes.size, 26)
        @Assert(keywords.size, codes.size)
        for (i in 0..codes.size) {
            let text = ErrCode.describe(codes[i])
            @Assert(text.isEmpty(), false)
            @Assert(text.contains(keywords[i]), true)
        }
    }

    /** `-2` 到 `99` 全区间调用 `describe` 都不返回空串（未登记码走非兜底描述）。 */
    @TestCase
    public func describeNeverReturnsEmptyOverFullRange(): Unit {
        for (code in -2..100) {
            @Assert(ErrCode.describe(code).isEmpty(), false)
        }
    }

    /** 未登记码（22 属 M3、24 起、以及任意越界值）走非空兜底描述，且不谎称是已定义码。 */
    @TestCase
    public func describeHasFallbackForUnregisteredCodes(): Unit {
        for (code in [22, 24, 50, 98, 100, -3, -99]) {
            let text = ErrCode.describe(code)
            @Assert(text.isEmpty(), false)
            @Assert(text.contains('未登记'), true)
        }
    }

    /** 宿主侧判定：仅 21 为真，M1 码、99 与未登记码均为假（design-m2 §2 / m2 §2 错误码表）。 */
    @TestCase
    public func isHostSideIsFalseForAllM1Codes(): Unit {
        let codes = [
            ErrCode.OK, ErrCode.DEOPT, ErrCode.INTERRUPT,
            ErrCode.DIV_ZERO, ErrCode.MOD_ZERO, ErrCode.OVERFLOW_I64, ErrCode.IDX_OOB,
            ErrCode.KEY_MISSING, ErrCode.NULL_HANDLE, ErrCode.BAD_CAST, ErrCode.HANDLE_TYPE,
            ErrCode.DEC_RANGE, ErrCode.DEC_DIV_ZERO, ErrCode.DT_RANGE, ErrCode.DUR_OVERFLOW,
            ErrCode.FP_INVALID, ErrCode.ARG_MISMATCH, ErrCode.STACK_GUARD,
            ErrCode.HANDLE_WINDOW_FULL, ErrCode.EXPLICIT, ErrCode.NOT_IMPL,
            ErrCode.CALL_CONTRACT, ErrCode.READONLY, ErrCode.CONCURRENT_MOD, ErrCode.HELPER_PANIC
        ]
        for (code in codes) {
            @Assert(ErrCode.isHostSide(code), false)
        }
        // 21 = 宿主（仓颉侧）异常专用码
        @Assert(ErrCode.isHostSide(ErrCode.HOST_EXCEPTION), true)
        // 未登记码（含 M3 的 22）同样不判为宿主侧
        @Assert(ErrCode.isHostSide(22), false)
        @Assert(ErrCode.isHostSide(-99), false)
    }

    /** 21 与 99 严格区分：描述与分类都不混用（21 宿主 / 99 引擎侧）。 */
    @TestCase
    public func hostExceptionAndPanicAreDistinguished(): Unit {
        let host = ErrCode.describe(ErrCode.HOST_EXCEPTION)
        let engine = ErrCode.describe(ErrCode.HELPER_PANIC)
        @Assert(host.contains('宿主'), true)
        @Assert(engine.contains('宿主'), false)
        @Assert(engine.contains('引擎'), true)
        @Assert(ErrCode.isHostSide(ErrCode.HOST_EXCEPTION), true)
        @Assert(ErrCode.isHostSide(ErrCode.HELPER_PANIC), false)
        @Assert(host == engine, false)
    }
}
