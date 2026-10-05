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
import fountain::f_aspect.macros.*

/**
 * `ASP-L7`（§3.1）空链快路径的行为用例：**没有任何切面命中**时，方法体应在**本次调用的接收者**上执行。
 * 修复前链被包装成 `{args => fn(args)}`，固化了首次调用的 `callee` ⇒ 第二个实例上执行的是第一个实例的函数体
 * （本用例即该现象的 RED）。有切面命中的链保持「固化首次 callee」的设计不变。
 */
@WeavedBean
public class EmptyChainTarget {
    public var tag = 0
    /** 现有规则只匹配函数名 n/p/m ⇒ `who` 不会被任何切面命中，链为空 */
    public func who(): Int64 {
        tag
    }
}

@Test
public class EmptyChainFastPath_test {
    @TestCase
    public func testTargetRunsOnCurrentReceiver(): Unit {
        let a = EmptyChainTarget()
        a.tag = 1
        let b = EmptyChainTarget()
        b.tag = 2
        @Assert(a.who(), 1)
        @Assert(b.who(), 2)
    }
}
