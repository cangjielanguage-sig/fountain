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
package fountain::f_rule.exception

import std.collection.HashSet
import std.unittest.*
import std.unittest.testmacro.*

/**
 * `RuleErrorCode` 与 `RuleException` 的契约（`doc/01-architecture.md` §6、`doc/10-roadmap.md` D12）。
 *
 * 27 个错误码的名字是日志与决策表错误定位的稳定契约，不允许随重构改名；
 * 枚举值同时要能作为 `HashMap` 键（`==` 与 `hashCode` 必须自洽）。
 */
@Test
class RuleException_test {
    /**
     * 27 个错误码与它们的稳定名。
     *
     * 名字重排/改名会让下游按日志文本做的匹配失效，因此这里是**显式清单**而非 `toString()` 回读。
     */
    private static let names: Array<(RuleErrorCode, String)> = [
        (RuleErrorCode.DUPLICATE_RULE, "DUPLICATE_RULE"),
        (RuleErrorCode.DUPLICATE_FACT, "DUPLICATE_FACT"),
        (RuleErrorCode.EMPTY_PATTERN, "EMPTY_PATTERN"),
        (RuleErrorCode.UNKNOWN_FACT_SPACE, "UNKNOWN_FACT_SPACE"),
        (RuleErrorCode.EMPTY_FACT_SPACE_SET, "EMPTY_FACT_SPACE_SET"),
        (RuleErrorCode.CROSS_SPACE_JOIN, "CROSS_SPACE_JOIN"),
        (RuleErrorCode.SAME_SPACE_FANOUT, "SAME_SPACE_FANOUT"),
        (RuleErrorCode.DUPLICATE_TYPE, "DUPLICATE_TYPE"),
        (RuleErrorCode.UNKNOWN_TYPE, "UNKNOWN_TYPE"),
        (RuleErrorCode.UNKNOWN_FIELD, "UNKNOWN_FIELD"),
        (RuleErrorCode.UNKNOWN_BINDING, "UNKNOWN_BINDING"),
        (RuleErrorCode.TYPE_MISMATCH, "TYPE_MISMATCH"),
        (RuleErrorCode.ILLEGAL_STATE, "ILLEGAL_STATE"),
        (RuleErrorCode.TABLE_INVALID, "TABLE_INVALID"),
        (RuleErrorCode.TABLE_NO_MATCH, "TABLE_NO_MATCH"),
        (RuleErrorCode.TABLE_MULTI_MATCH, "TABLE_MULTI_MATCH"),
        (RuleErrorCode.TABLE_MODE_CONFLICT, "TABLE_MODE_CONFLICT"),
        (RuleErrorCode.NETWORK_FROZEN, "NETWORK_FROZEN"),
        (RuleErrorCode.CYCLE_LIMIT, "CYCLE_LIMIT"),
        (RuleErrorCode.SCRIPT_COMPILE, "SCRIPT_COMPILE"),
        (RuleErrorCode.SCRIPT_BINDING_MISSING, "SCRIPT_BINDING_MISSING"),
        (RuleErrorCode.FANOUT_WITHOUT_JOIN, "FANOUT_WITHOUT_JOIN"),
        (RuleErrorCode.EMPTY_FANOUT, "EMPTY_FANOUT"),
        (RuleErrorCode.REENTRANT_FIRE, "REENTRANT_FIRE"),
        (RuleErrorCode.ACTION_FAILED, "ACTION_FAILED"),
        (RuleErrorCode.NO_CONTEXT, "NO_CONTEXT"),
        (RuleErrorCode.CLOSED, "CLOSED")
    ]

    /** 27 个码逐一 `toString()`，结果是大写蛇形名。 */
    @TestCase
    public func toStringIsStableUpperSnakeCase(): Unit {
        @Assert(RuleException_test.names.size, 27)
        for ((code, name) in RuleException_test.names) {
            @Assert(code.toString(), name)
        }
    }

    /** `==` 自洽：同值相等、异值不等。 */
    @TestCase
    public func equalityIsIdentityOfVariant(): Unit {
        @Expect(RuleErrorCode.CLOSED == RuleErrorCode.CLOSED, true)
        @Expect(RuleErrorCode.CLOSED == RuleErrorCode.NO_CONTEXT, false)

        // 判等不依赖 message：错误码可以直接 match
        let codes = [RuleErrorCode.CROSS_SPACE_JOIN, RuleErrorCode.UNKNOWN_FIELD]
        var seen = ""
        for (code in codes) {
            match (code) {
                case RuleErrorCode.CROSS_SPACE_JOIN => seen = seen + "cross"
                case RuleErrorCode.UNKNOWN_FIELD => seen = seen + "field"
                case _ => seen = seen + "other"
            }
        }
        @Assert(seen, "crossfield")
    }

    /** `hashCode` 自洽且 27 个码互不相同，可直接作 `HashMap` 键。 */
    @TestCase
    public func hashCodeIsUniquePerVariant(): Unit {
        let hashes = HashSet<Int64>()
        for ((code, _) in RuleException_test.names) {
            @Assert(code.hashCode(), code.hashCode())
            hashes.add(code.hashCode())
        }
        @Assert(hashes.size, 27)
    }

    /** 异常携带 `code` 与 `message`。 */
    @TestCase
    public func exceptionCarriesCodeAndMessage(): Unit {
        var caught: ?RuleException = None
        try {
            throw RuleException(RuleErrorCode.CROSS_SPACE_JOIN, "orders vs users")
        } catch (e: RuleException) {
            caught = e
        }
        let e = caught.getOrThrow()
        @Assert(e.code, RuleErrorCode.CROSS_SPACE_JOIN)
        @Assert(e.message, "orders vs users")
        @Expect(e.causedBy.isNone(), true)
    }

    /** 只给错误码时，`message` 回落到码名，便于日志直接可读。 */
    @TestCase
    public func messageFallsBackToCodeName(): Unit {
        @Assert(RuleException(RuleErrorCode.CLOSED).message, "CLOSED")
    }

    /** `caused` 构造把原异常挂到 `causedBy`，`code`/`message` 不丢。 */
    @TestCase
    public func causedIsPreserved(): Unit {
        let cause = RuleException(RuleErrorCode.TYPE_MISMATCH, "inner")
        let e = RuleException(RuleErrorCode.ACTION_FAILED, "outer", cause)
        @Assert(e.code, RuleErrorCode.ACTION_FAILED)
        @Assert(e.message, "outer")
        @Assert(e.causedBy.getOrThrow().message, "inner")
        // 原因链上的错误码也要能取回（异常包装不吞码）
        var innerCode = RuleErrorCode.CLOSED
        match (e.causedBy.getOrThrow()) {
            case inner: RuleException => innerCode = inner.code
            case _ => ()
        }
        @Assert(innerCode, RuleErrorCode.TYPE_MISMATCH)

        let bare = RuleException(RuleErrorCode.NO_CONTEXT, cause)
        @Assert(bare.message, "NO_CONTEXT")
        @Assert(bare.causedBy.getOrThrow().message, "inner")
    }
}
