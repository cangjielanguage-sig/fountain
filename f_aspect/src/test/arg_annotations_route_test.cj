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
package fountain::f_aspect.test

import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_base.*
import fountain::f_aspect.*

/** 规则要用到的目标函数（注解类复用同包 `arg_prefix_suffix_route_test.cj` 里的 `Arg1`/`Arg2`） */
public class ArgAnnotationsTarget {
    public func both(
        @Arg1 a: String,
        @Arg2 b: String
    ): Unit {}
    public func skipSecond(
        @Arg1 a: String,
        c: String
    ): Unit {}
    public func swapped(
        c: String,
        @Arg2 b: String
    ): Unit {}
    public func plain(c: String): Unit {}
    public func multi(
        @Arg1
        @Arg2
        a: String,
        @Arg2 b: String
    ): Unit {}
}

/**
 * §1.7 / `ASP-5` 回归：`ArgAnnotationsRouteRule` 的判定（规则串用 `&` 分割，逐参数对应）
 * ① 逐位命中（修前：内层 `continue` 后仍走到 `return false` ⇒ 恒 false）；
 * ② `*` 占位跳过某个参数；
 * ③ 规则项数与参数个数必须一致（修前：首项为 `*` 且规则项更少时 `annotationNames[i]` 越界崩溃）；
 * ④ "拥有"语义：参数多注解也算命中，参数无注解不得命中。
 */
@Test
public class ArgAnnotationsRoute_test {
    private static let ARG1 = TypeInfo.of<Arg1>().qualifiedName
    private static let ARG2 = TypeInfo.of<Arg2>().qualifiedName

    private static func info(funcName: String, argCount: Int64): InvocationFuncInfo {
        InvocationFuncInfo(TypeInfo.of<ArgAnnotationsTarget>(), funcName,
            Array<TypeInfo>(argCount, repeat: TypeInfo.of<String>()), [])
    }

    @TestCase
    public func testPositionalMatch(): Unit {
        // 逐位命中：修前恒 false
        @Assert(ArgAnnotationsRouteRule('${ARG1}&${ARG2}').matches(info('both', 2)), true)
        // * 占位跳过第二个参数：修前恒 false
        @Assert(ArgAnnotationsRouteRule('${ARG1}&*').matches(info('skipSecond', 2)), true)
        // 位置/顺序不符：不匹配
        @Assert(ArgAnnotationsRouteRule('${ARG1}&${ARG2}').matches(info('swapped', 2)), false)
        // 参数无注解：不匹配（"拥有"= 存在，不得真空通过）
        @Assert(ArgAnnotationsRouteRule(ARG1).matches(info('plain', 1)), false)
        // 参数多注解：拥有 ARG1 即可（修前恒 false）
        @Assert(ArgAnnotationsRouteRule('${ARG1}&*').matches(info('multi', 2)), true)
    }

    @TestCase
    public func testRuleLengthMustEqualParamCount(): Unit {
        // 规则项多于参数：不匹配
        @Assert(ArgAnnotationsRouteRule('${ARG1}&${ARG2}&${ARG2}').matches(info('both', 2)), false)
        // 规则项少于参数、且首项是 *：修前会走到 annotationNames[1] ⇒ 越界崩溃
        @Assert(ArgAnnotationsRouteRule('*').matches(info('both', 2)), false)
    }
}
