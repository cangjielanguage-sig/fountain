/*
Copyright (c) 2025 WuJingrun（吴京润）

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
package fountain::f_data.base

import std.unittest.*
import std.unittest.testmacro.*

/**
 * 覆盖 2026-10-15 修复的数值转换缺陷（详见 doc/REVIEW_2026-10-15.md）：
 * - 浮点字符串正则的指数符号位置：`1e-5` 应可转换，`1-e5` 应被拒绝
 * - IntNative 字符串正则缺负号：`-5` 应可转换
 * - tryToUIntNative 误用 int64Range
 * - 溢出策略优先于 IGNORE_FIELD_NOT_CONVERTABLE，且 DEFAULT 不再夹带 WRAPPING
 */
@Test
public class NumberDataConversionTest {
    private func optFloat64(r: Any): ?Float64 {
        match (r) {
            case x: Float64 => Some(x)
            case x: Option<Float64> => x
            case _ => None<Float64>
        }
    }

    private func optFloat32(r: Any): ?Float32 {
        match (r) {
            case x: Float32 => Some(x)
            case x: Option<Float32> => x
            case _ => None<Float32>
        }
    }

    private func optInt8(r: Any): ?Int8 {
        match (r) {
            case x: Int8 => Some(x)
            case x: Option<Int8> => x
            case _ => None<Int8>
        }
    }

    private func optIntNative(r: Any): ?IntNative {
        match (r) {
            case x: IntNative => Some(x)
            case x: Option<IntNative> => x
            case _ => None<IntNative>
        }
    }

    @TestCase
    public func testFloatScientificNotationAccepted(): Unit {
        @Assert(optFloat64(Float64.tryFromData(DataString('1e-5'), DEFAULT_DATA_FLAG)).isSome())
        @Assert(optFloat64(Float64.tryFromData(DataString('1.5E-3'), DEFAULT_DATA_FLAG)).isSome())
        @Assert(optFloat64(Float64.tryFromData(DataString('1e+5'), DEFAULT_DATA_FLAG)).isSome())
        @Assert(optFloat32(Float32.tryFromData(DataString('1e-5'), DEFAULT_DATA_FLAG)).isSome())
    }

    @TestCase
    public func testMalformedExponentRejected(): Unit {
        // 修复前 `1-e5`、`1-p3` 会被正则当作合法浮点串
        @Assert(optFloat64(Float64.tryFromData(DataString('1-e5'), DEFAULT_DATA_FLAG)).isNone())
        @Assert(optFloat64(Float64.tryFromData(DataString('1-p3'), DEFAULT_DATA_FLAG)).isNone())
    }

    @TestCase
    public func testIntNativeAcceptsNegativeString(): Unit {
        // 修复前 IntNative 的 4 个字符串正则漏 -?，"-5" 落 None（同文件其他整数类型都支持）
        @Assert(Some(IntNative(-5)), optIntNative(IntNative.tryFromData(DataString('-5'), DEFAULT_DATA_FLAG)))
        @Assert(Some(IntNative(5)), optIntNative(IntNative.tryFromData(DataString('5'), DEFAULT_DATA_FLAG)))
    }

    @TestCase
    public func testTryToUIntNativeUsesUnsignedRange(): Unit {
        // 修复前用 int64Range 判定：UInt64.Max 被判「不可转换」；-1 通过检查后由 toUIntNative() 抛异常
        @Assert(DataReal(UInt64.Max).tryToUIntNative().isSome())
        @Assert(DataReal(0).tryToUIntNative().isSome())
        @Assert(DataReal(-1).tryToUIntNative().isNone())
    }

    @TestCase
    public func testDefaultFlagSilentlyIgnoresOverflow(): Unit {
        // DEFAULT 不再夹带 WRAPPING：越界仍是 None（保持 f_orm JSON→PO 的既有行为）
        @Assert(DEFAULT_DATA_FLAG, SILENCE)
        @Assert(optInt8(Int8.tryFromData(DataReal(300), DEFAULT_DATA_FLAG)).isNone())
    }

    @TestCase
    public func testExplicitOverflowStrategyWins(): Unit {
        // 修复前 IGNORE_FIELD_NOT_CONVERTABLE 排在策略分支之前，显式 WRAPPING 也被吞成 None
        @Assert(Some(Int8(44)), optInt8(Int8.tryFromData(DataReal(300), DEFAULT_DATA_FLAG | WRAPPING_ON_INT_OVERFLOW)))
        @Assert(Some(Int8(127)), optInt8(Int8.tryFromData(DataReal(300), SILENCE | SATURATING_ON_INT_OVERFLOW)))
        @Assert(Some(Int8(-128)), optInt8(Int8.tryFromData(DataReal(-300), SILENCE | SATURATING_ON_INT_OVERFLOW)))
    }

    @TestCase
    public func testExplicitThrowingStrategyThrows(): Unit {
        var thrown = false
        try {
            Int8.tryFromData(DataReal(300), SILENCE | THROWING_ON_INT_OVERFLOW)
        } catch (_: Exception) {
            thrown = true
        }
        @Assert(thrown)
    }
}
