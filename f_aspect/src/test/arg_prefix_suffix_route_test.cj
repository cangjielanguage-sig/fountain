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

/** 参数注解（规则里要用全限定名） */
@Annotation[target: [Parameter]]
public class Arg1 {
    public const init() {}
}

@Annotation[target: [Parameter]]
public class Arg2 {
    public const init() {}
}

/** 规则要匹配的目标函数：按 ArgPrefixAnnotationsRouteRule / ArgSuffixAnnotationsRouteRule 的文档示例摆位 */
public class PrefixSuffixTarget {
    public func test1(
        @Arg1 a: String,
        @Arg2 b: String
    ): Unit {}
    public func test2Prefix(
        @Arg1 a: String,
        @Arg2 b: String,
        c: String
    ): Unit {}
    public func test2Suffix(
        c: String,
        @Arg1 a: String,
        @Arg2 b: String
    ): Unit {}
    public func test3(
        @Arg1 a: String,
        c: String,
        @Arg2 b: String
    ): Unit {}
    public func noAnnotation(c: String): Unit {}
    public func twoAnnotations(
        @Arg1
        @Arg2
        a: String,
        @Arg2 b: String
    ): Unit {}
}

/**
 * §1.6 / `ASP-4` 回归：前缀/后缀参数注解规则不得越界，且"拥有指定注解"按**存在**判定。
 * 覆盖：规则项数 == 参数数、规则项数 < 参数数（文档 test2 形状；修前前缀越界崩溃、后缀因 range 缺 `: -1`
 * 是空循环 ⇒ 恒 true）、规则项数 > 参数数（应 false）、参数无注解（应 false，防真空通过）、
 * 参数多注解（"拥有"即可，应 true）。
 */
@Test
public class ArgPrefixSuffixRoute_test {
    private static let ARG1 = TypeInfo.of<Arg1>().qualifiedName
    private static let ARG2 = TypeInfo.of<Arg2>().qualifiedName

    /** 规则只读 funcInfo.funcInfo.parameters[*].annotations，args 传空数组即可 */
    private static func info(funcName: String, argCount: Int64): InvocationFuncInfo {
        InvocationFuncInfo(TypeInfo.of<PrefixSuffixTarget>(), funcName,
            Array<TypeInfo>(argCount, repeat: TypeInfo.of<String>()), [])
    }

    @TestCase
    public func testPrefixRule(): Unit {
        let rule = ArgPrefixAnnotationsRouteRule('${ARG1},${ARG2}')
        // 参数数 == 规则项数：逐位对应
        @Assert(rule.matches(info('test1', 2)), true)
        // 参数数 > 规则项数：只看最前面 N 个（文档 test2 形状；修前这里越界崩溃）
        @Assert(rule.matches(info('test2Prefix', 3)), true)
        // 位置/顺序不符：不匹配（文档 test3）
        @Assert(rule.matches(info('test3', 3)), false)
        // 首参无注解：不匹配（"拥有"= 存在，空注解集合不得真空通过）
        @Assert(ArgPrefixAnnotationsRouteRule(ARG1).matches(info('noAnnotation', 1)), false)
        // 多注解参数：拥有 ARG1 即可
        @Assert(ArgPrefixAnnotationsRouteRule(ARG1).matches(info('twoAnnotations', 2)), true)
        // 规则项多于参数：不匹配（修前：静默忽略多余规则项）
        @Assert(ArgPrefixAnnotationsRouteRule('${ARG1},${ARG2},${ARG2}').matches(info('test1', 2)), false)
    }

    @TestCase
    public func testSuffixRule(): Unit {
        let rule = ArgSuffixAnnotationsRouteRule('${ARG1},${ARG2}')
        // 参数数 == 规则项数：逐位对应
        @Assert(rule.matches(info('test1', 2)), true)
        // 规则项正序对应最后 N 个参数（文档 test2 形状）：
        // 修前 range = params.size - 1..=0 缺 `: -1` 是空循环 ⇒ 恒 true，这里"碰巧"也是 true
        @Assert(rule.matches(info('test2Suffix', 3)), true)
        // 最后两个参数是 (c, @Arg2 b)：A1 缺位 ⇒ 不匹配（修前：空循环 ⇒ 误判 true）
        @Assert(rule.matches(info('test3', 3)), false)
        // 唯一参数无注解：不匹配（修前：空循环 ⇒ 误判 true）
        @Assert(ArgSuffixAnnotationsRouteRule(ARG1).matches(info('noAnnotation', 1)), false)
        // 规则项多于参数：不匹配（修前：空循环 ⇒ 误判 true）
        @Assert(ArgSuffixAnnotationsRouteRule('${ARG1},${ARG2},${ARG2}').matches(info('test1', 2)), false)
    }
}
