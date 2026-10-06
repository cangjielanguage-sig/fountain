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
package fountain::f_bean.test

import std.unittest.*
import std.unittest.testmacro.*
public import fountain::f_bean.*
import fountain::f_bean.macros.*

/**
 * §2.18 / `BEAN-5` 的行为用例：`BeanManager` 把 `scope.isSingleton` 预存成普通 `Bool` 成员后，
 * 「单例/原型/自定义 scope 实例」三类 bean 的取值语义与 `initIfNeed` 的启动期判定必须一字不差。
 */
@BeanMeta[lazy: false]
@Bean
public class ScopeEagerBean {
    public static let created = AtomicInt64(0)
    public init() {
        ScopeEagerBean.created.fetchAdd(1)
    }
}

@Bean
public class ScopeSingletonBean {}

@BeanMeta[scope: BeanScope.prototype]
@Bean
public class ScopePrototypeBean {}

@Test
public class BeanScope_test {
    @TestCase
    public func testSingletonScopeSemantics(): Unit {
        let f = BeanFactory.instance
        let a = f.getFirst<ScopeSingletonBean>().getOrThrow()
        let b = f.getFirst<ScopeSingletonBean>().getOrThrow()
        @Assert(refEq(a, b), true)                       // 单例：同一实例
        let m = f.iterator<ScopeSingletonBean>().next().getOrThrow()
        @Assert(refEq(m.bean, m.bean), true)             // 直接走 getter 也是同一实例
    }

    @TestCase
    public func testPrototypeScopeSemantics(): Unit {
        let f = BeanFactory.instance
        let m = f.iterator<ScopePrototypeBean>().next().getOrThrow()
        @Assert(refEq(m.bean, m.bean), false)            // prototype：每次 new
    }

    @TestCase
    public func testCustomScopeInstanceTreatedAsSingleton(): Unit {
        // 非常量 SingletonBeanScope 实例 ⇒ `BeanScope.==` 走 typeInfo 比较（原先每次取 bean 都要算）
        let mgr = BeanManager(BeanMeta(scope: SingletonBeanScope()),
                              TypeInfo.of<ScopeSingletonBean>(), {=> ScopeSingletonBean()})
        let x = mgr.bean
        @Assert(refEq(x, mgr.bean), true)                // 语义仍是「单例」
    }

    @TestCase
    public func testInitIfNeedJudgement(): Unit {
        // internal 可见（测试包是 f_bean 的子包）：直接钉「非 lazy 且单例才预初始化」的判定
        let lazyMgr = BeanManager(BeanMeta(), TypeInfo.of<ScopeSingletonBean>(), {=> ScopeSingletonBean()})
        let eagerMgr = BeanManager(BeanMeta(lazy: false), TypeInfo.of<ScopeSingletonBean>(), {=> ScopeSingletonBean()})
        let protoMgr = BeanManager(BeanMeta(lazy: false, scope: BeanScope.prototype),
                                   TypeInfo.of<ScopePrototypeBean>(), {=> ScopePrototypeBean()})
        @Assert(lazyMgr.initIfNeed(), false)             // lazy ⇒ 恒 false
        @Assert(protoMgr.initIfNeed(), false)            // 非单例 ⇒ 恒 false（这条才区分得出 _singleton=false）
        let inited = eagerMgr.initIfNeed()               // 非 lazy 单例 ⇒ 随 shouldInitBean（默认 true）
        @Assert(inited == eagerMgr.initIfNeed() || !inited, true)   // 重复调用结果稳定
        let x = eagerMgr.bean
        @Assert(refEq(x, eagerMgr.bean), true)
    }

    @TestCase
    public func testEagerBeanCreatedAtMostOnce(): Unit {
        let f = BeanFactory.instance
        let p1 = f.getFirst<ScopeEagerBean>().getOrThrow()
        let afterFirst = ScopeEagerBean.created.load()
        let p2 = f.getFirst<ScopeEagerBean>().getOrThrow()
        @Assert(refEq(p1, p2), true)
        @Assert(afterFirst >= 1, true)
        @Assert(ScopeEagerBean.created.load(), afterFirst)   // 二次取不得再构造
    }
}
