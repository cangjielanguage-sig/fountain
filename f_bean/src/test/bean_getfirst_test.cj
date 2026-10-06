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
import std.time.*
public import fountain::f_bean.*
import fountain::f_bean.macros.*

/**
 * §2.15 / `BEAN-2` 的用例：该条是**性能**项，行为不应改变，所以分两层证据。
 *
 * 1）行为等价：类键 / 接口键 / 父类键 / `Any`·`Object` 桶 / `Exactly(名字)` / `beanType:` 重载 /
 *    非法 `beanType` 仍抛 `BeanException` / 同查询重复调用结果一致；
 * 2）基准：`getFirst<T>()` 走 N 次（与 `f_mvc/src/RequestMeta.cj:191` 每请求一次的调用形状相同），
 *    打印 ns/op。该断言只校验命中数，耗时数字用于 §2.15 修复记录里「修前 / 修后」对照。
 */
public interface BeanTestAnimal {}

@Bean
public class BeanTestDog <: BeanTestAnimal {}

@Bean
public class BeanTestCat <: BeanTestAnimal {}

// 父类本身不是 bean，只作类型键（`BeanTestDerived` 注册时按 superClass 闭包入桶）
public open class BeanTestBase {}

@Bean
public class BeanTestDerived <: BeanTestBase {}

@Test
public class BeanGetFirst_test {
    @TestCase
    public func testTypeKeys(): Unit {
        let f = BeanFactory.instance
        // 类键（beanTypeMap 的直接键）
        @Assert(f.getFirst<BeanTestDog>().isSome(), true)
        // 接口键：注册期按超类型闭包入桶（doRegister），并非按名字比对
        @Assert(f.getFirst<BeanTestAnimal>().isSome(), true)
        // 父类键
        @Assert(f.getFirst<BeanTestBase>().isSome(), true)
        @Assert(f.getFirst<BeanTestDerived>().isSome(), true)
        // Any / Object 桶：每个 bean 都入这两个键
        @Assert(f.getFirst<Any>().isSome(), true)
        @Assert(f.getFirst<Object>().isSome(), true)
    }

    @TestCase
    public func testBeanTypeOverloadAndExactly(): Unit {
        let f = BeanFactory.instance
        @Assert(f.getFirst<BeanTestDog>(TypeInfo.of<BeanTestDog>()).isSome(), true)

        let dogName = f.getFirstTuple<BeanTestDog>().getOrThrow()[0]
        let catName = f.getFirstTuple<BeanTestCat>().getOrThrow()[0]
        // Exactly 命中同类名字 ⇒ 返回
        @Assert(f.getFirst<BeanTestDog>(cond: Exactly(dogName)).isSome(), true)
        // Exactly 命中「别的类型」的 bean 名字 ⇒ None（该分支的类型复检必须保留）
        @Assert(f.getFirst<BeanTestDog>(cond: Exactly(catName)).isNone(), true)

        // 重复查询结果一致（去掉内部复检不得改变可见语义）
        let n1 = f.getFirstTuple<BeanTestDog>().getOrThrow()[0]
        let n2 = f.getFirstTuple<BeanTestDog>().getOrThrow()[0]
        @Assert(n1, n2)
    }

    @TestCase
    public func testIllegalBeanTypeStillThrows(): Unit {
        var thrown = false
        var got: ?BeanTestDog = None
        try {
            got = BeanFactory.instance.getFirst<BeanTestDog>(TypeInfo.of<String>())
        } catch (e: BeanException) {
            thrown = true
        }
        @Assert(thrown, true)
        @Assert(got.isNone(), true)
    }

    @TestCase
    public func testBenchmarkGetFirstHotPath(): Unit {
        let f = BeanFactory.instance
        let warmup: Int64 = 1000
        let n: Int64 = 300_000
        var hits: Int64 = 0
        for (_ in 0..warmup) {
            if (f.getFirst<BeanTestDog>().isSome()) {
                hits += 1
            }
        }
        let t0 = DateTime.now()
        for (_ in 0..n) {
            if (f.getFirst<BeanTestDog>().isSome()) {
                hits += 1
            }
        }
        let ms = (DateTime.now() - t0) / Duration.millisecond
        println("BENCH getFirst<BeanTestDog> x${n}: total=${ms}ms, ns/op=${ms * 1000000.0 / Float64(n)}")
        @Assert(hits, n + warmup)
    }
}
