/*
    Copyright (c) [2022] [WuJingrun（吴京润）]
    fountain is licensed under Mulan PSL v2.
    You can use this software according to the terms and conditions of the Mulan PSL v2.
    You may obtain a copy of Mulan PSL v2 at:
            http://license.coscl.org.cn/MulanPSL2
    THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
    See the Mulan PSL v2 for more details.  
*/
package f_bean.test

import std.unittest.*
import std.unittest.testmacro.*
import f_bean.*
import f_bean.macros.*

@Bean
public class A <: ToString {
    public func toString(){
        'A'
    }
}
@Bean
public class B <: ToString {
    @Constructor
    public B(public let a: A){}
    public func toString(){
        'B(${a})'
    }
}
@Test
public class BeanTest{
    @TestCase
    public func test(){
        let b = BeanFactory.instance.getFirst<B>()
        println(b)
    }
}