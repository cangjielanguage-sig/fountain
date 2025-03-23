/*
    Copyright (c) [2022] [WuJingrun（吴京润）]
    fountain is licensed under Mulan PSL v2.
    You can use this software according to the terms and conditions of the Mulan PSL v2.
    You may obtain a copy of Mulan PSL v2 at:
            http://license.coscl.org.cn/MulanPSL2
    THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
    See the Mulan PSL v2 for more details.
 */
package f_aspect.macros_test

import f_aspect.*
import f_aspect.macros.*
import f_bean.*
import f_bean.macros.*
import std.unittest.*
import std.unittest.testmacro.*

@Bean
public class AspectTest <: Aspect {
    public func before(args: Array<Any>): Bool {
        println("before")
        true
    }
    public func after(args: Array<Any>, result: Any): Any {
        println("after")
        result
    }
    public func around(args: Array<Any>, point: () -> Any): Any {
        try {
            println("around start")
            let result = point()
            println("around end")
            return result
        } finally {
            println("around finally")
        }
    }
}

public class Aspected {
    @PointCut[RecursiveSensitive]
    public func test(): Unit {
        println("test")
    }
}
@Test
public class AOP_test {
    @TestCase
    public func test(): Unit {
        Aspected().test()
        /**  整个执行过程应该是
           before
           around start
           test
           around end
           around finally
           after
         */
    }
}
