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
import fountain::f_base.BaseException

/**
 * Q1.6 注册期拒绝异常的失败用例（先写红）。
 *
 * 权威 = `doc/jit-bytecode-m2.md` v0.8.32 §12.5「注册期拒绝」、`design-m2.md` §2.2、
 * spec「注册期拒绝异常」：六值 `RegistrationRejectKind`、`(kind, name, occupiedBy)`、
 * 三段消息 + 按 kind 固定 hint、`<: fountain::f_base.BaseException`、**不占 ErrCode**。
 */
@Test
public class RegistrationException_test {
    private func hintOf(kind: RegistrationRejectKind): String {
        match (kind) {
            case RegistrationRejectKind.JsonFamily => 'JSON 谱系为内建类型，无需注册'
            case RegistrationRejectKind.ReflectionUnavailable => '回退手工注册'
            case _ => '改名（成员名冲突请用手工注册起别名）'
        }
    }

    /** 六值逐值可断言；`kind` / `name` / `occupiedBy` 与入参一致。 */
    @TestCase
    public func sixKindsRoundTrip(): Unit {
        let kinds = [
            RegistrationRejectKind.DuplicateClass,
            RegistrationRejectKind.FunctionNameClash,
            RegistrationRejectKind.BuiltinTypeName,
            RegistrationRejectKind.Keyword,
            RegistrationRejectKind.JsonFamily,
            RegistrationRejectKind.ReflectionUnavailable
        ]
        @Assert(kinds.size, 6)
        for (k in kinds) {
            let e = RegistrationException(k, 'User', Some('class:Base'))
            @Assert(e.kind, k)
            @Assert(e.name, 'User')
            @Assert(e.occupiedBy.isSome(), true)
            match (e.occupiedBy) {
                case Some(v) => @Assert(v, 'class:Base')
                case None => @Fail('occupiedBy 丢失')
            }
        }
    }

    /** `occupiedBy=None` 分支可用，且消息不出现冲突段。 */
    @TestCase
    public func noneOccupiedByOmitsConflictClause(): Unit {
        let e = RegistrationException(
            RegistrationRejectKind.ReflectionUnavailable, 'User', None)
        @Assert(e.occupiedBy.isNone(), true)
        @Assert(e.message.contains('conflicts with'), false)
        @Assert(e.message.contains('回退手工注册'), true)
    }

    /** 三段消息：类名 + kind 说明 + 冲突对象 + 按 kind 固定的 hint。 */
    @TestCase
    public func messageHasThreeSegmentsAndFixedHint(): Unit {
        let e = RegistrationException(
            RegistrationRejectKind.FunctionNameClash, 'User', Some('func:size'))
        @Assert(e.message.contains("class 'User' rejected at registration"), true)
        @Assert(e.message.contains('func:size'), true)
        @Assert(e.message.contains(hintOf(RegistrationRejectKind.FunctionNameClash)), true)

        for (k in [
            RegistrationRejectKind.DuplicateClass,
            RegistrationRejectKind.BuiltinTypeName,
            RegistrationRejectKind.Keyword,
            RegistrationRejectKind.JsonFamily,
            RegistrationRejectKind.ReflectionUnavailable
        ]) {
            let ex = RegistrationException(k, 'Order', None)
            @Assert(ex.message.contains("class 'Order' rejected at registration"), true)
            @Assert(ex.message.contains(hintOf(k)), true)
        }
    }

    /** 宿主可 `catch (e: fountain::f_base.BaseException)` 读回结构化字段。 */
    @TestCase
    public func catchableAsBaseException(): Unit {
        var caught: ?RegistrationException = None
        try {
            throw RegistrationException(
                RegistrationRejectKind.DuplicateClass, 'User', Some('class:User'))
        } catch (e: BaseException) {
            match (e) {
                case re: RegistrationException => caught = Some(re)
                case _ => ()
            }
        }
        @Assert(caught.isSome(), true)
        match (caught) {
            case Some(e) =>
                @Assert(e.kind, RegistrationRejectKind.DuplicateClass)
                @Assert(e.name, 'User')
            case None => @Fail('未捕获为 BaseException')
        }
    }

    /** 不占运行期 ErrCode：不是 JitException，也不通过 21 通道表达。 */
    @TestCase
    public func doesNotOccupyErrCode(): Unit {
        let e = RegistrationException(RegistrationRejectKind.Keyword, 'match', None)
        @Assert(e is JitException, false)
        @Assert(ErrCode.isHostSide(ErrCode.HOST_EXCEPTION), true)
        var jitCaught = false
        try {
            throw e
        } catch (ex: JitException) {
            jitCaught = true
        } catch (ex: BaseException) {
            // 注册期异常走独立类型，不进入运行期错误码通道
        }
        @Assert(jitCaught, false)
    }
}
