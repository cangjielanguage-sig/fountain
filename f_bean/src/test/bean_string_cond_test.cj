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

/**
 * §2.17 / `BEAN-4` 的用例：`StringCond` 求值里 `Wildcard` / `Regexp` 每次现场构造正则。
 *
 * - `Wildcard(v)`：`Regex.wildcard(v)` 每次做 6 次 `String.replace`（`f_regex/src/ExtendRegex.cj:76-85`）；
 * - `Regexp(v)`：`v.regex()` 自身有缓存（`f_regex/src/RegexFromString.cj:28-65`），但每次仍要现构造键串
 *   `"/${this}/${flagsstr()}"` —— `flagsstr()` 会建 `HashSet` + `StringGenerator`。
 *
 * 两层证据：① 行为（`on` 与注册表查询结果不变）；② 基准（同一模式 N 次 `on` 的 ns/op，修前/修后对照）。
 */
private let WILD_PATTERN = 'fountain::f_bean.test.*'
private let WILD_MISS = 'other.pkg.*'
private let REGEX_HIT = '.*BeanTestDog.*'
private let REGEX_MISS = '.*BeanTestCat.*'

@Test
public class BeanStringCond_test {
    @TestCase
    public func testMatchingAndRegistryIntegration(): Unit {
        let f = BeanFactory.instance
        let dogName = f.getFirstTuple<BeanTestDog>().getOrThrow()[0]
        let wild = Wildcard(WILD_PATTERN)
        let wildMiss = Wildcard(WILD_MISS)
        let reHit = Regexp(REGEX_HIT)
        let reMiss = Regexp(REGEX_MISS)
        // on 语义：命中 / 不命中
        @Assert(wild.on(dogName), true)
        @Assert(wildMiss.on(dogName), false)
        @Assert(reHit.on(dogName), true)
        @Assert(reMiss.on(dogName), false)
        // 重复求值结果一致（缓存不得改变语义）
        @Assert(wild.on(dogName), true)
        @Assert(reHit.on(dogName), true)
        // 与注册表联用：接口键 + 条件筛出的 bean 与预期一致
        @Assert(f.getList<BeanTestAnimal>(cond: wild).size, 2)     // BeanTestDog + BeanTestCat
        @Assert(f.getList<BeanTestAnimal>(cond: wildMiss).size, 0)
        @Assert(f.getFirst<BeanTestDog>(cond: reHit).isSome(), true)
        @Assert(f.getFirst<BeanTestDog>(cond: reMiss).isNone(), true)
    }

    @TestCase
    public func testBenchmarkCondRegexPaths(): Unit {
        let dogName = BeanFactory.instance.getFirstTuple<BeanTestDog>().getOrThrow()[0]
        let wild = Wildcard(WILD_PATTERN)
        let re = Regexp(REGEX_HIT)
        // 先确认基准量的是「命中」路径，否则量到的是快速拒绝
        @Assert(wild.on(dogName) && re.on(dogName), true)

        let n: Int64 = 300_000
        var ok: Int64 = 0
        let t0 = DateTime.now()
        for (_ in 0..n) {
            if (wild.on(dogName)) {
                ok += 1
            }
        }
        let ms1 = (DateTime.now() - t0) / Duration.millisecond
        let t1 = DateTime.now()
        for (_ in 0..n) {
            if (re.on(dogName)) {
                ok += 1
            }
        }
        let ms2 = (DateTime.now() - t1) / Duration.millisecond
        println("BENCH StringCond.on x${n}: Wildcard total=${ms1}ms (${ms1 * 1000000.0 / Float64(n)} ns/op), Regexp total=${ms2}ms (${ms2 * 1000000.0 / Float64(n)} ns/op)")
        @Assert(ok, n * 2)
    }
}
