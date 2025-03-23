/*
    Copyright (c) [2022] [WuJingrun（吴京润）]
    fountain is licensed under Mulan PSL v2.
    You can use this software according to the terms and conditions of the Mulan PSL v2.
    You may obtain a copy of Mulan PSL v2 at:
            http://license.coscl.org.cn/MulanPSL2
    THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
    See the Mulan PSL v2 for more details.
 */
package f_bean.macros_test

import f_bean.macros.*
import std.unittest.*
import std.unittest.testmacro.*

@Bean[injected]
public class Injected {
    func exec() {
        println("injected")
    }
}

@Bean[test1]
public class Test1 {
    @Autowired[injected]
    private let injected: Injected
    public func call() {
        println("Test1")
        injected.exec()
    }
}

@Test
public class IOC_test {
    @TestCase
    public func test1(): Unit {
        //每个受BeanFactory管理的bean都有一个名字，
        //还有使用名字前缀、后缀、通配符获取和使用bean的api
        //比如getByPrefix(prefix) getBySuffix(suffix) getWithwildcard(pattern)
        //get<T>() 这是仅按照类型获取bean的函数，
        //还有对应的use*函数
        App.beanFactory.get<Test1>("test1").call()
        App.beanFactory.use<Test1, Unit>("test1") {
            t => t.call()
        }
    }
}
