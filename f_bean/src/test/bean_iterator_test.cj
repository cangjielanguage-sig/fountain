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
import std.collection.*
import std.time.*
public import fountain::f_bean.*

/**
 * §2.16 / `BEAN-3` 的用例：`iterator<T>` 每次调用新建 filter 闭包并逐元素重跑
 * `matches`（子类型复检 + `cond.on(name)`）；`getFirstTuple<T>` 的循环同族
 * （`matches<T>(cond, m)` 每元素重算 `TypeInfo.of<T>()` + `isSubtypeOf`）。
 *
 * 两层证据：① 行为（`iterator`/`getList`/`getMap`/`getAllTuples`/`getFirstTuple` 的结果集合不变）；
 * ② 基准（IgnoreCond 迭代器 / 带条件迭代器 / `getFirstTuple` 三段 ns/op，修前修后对照）。
 */
private func collectNames(it: Iterator<BeanManager>): TreeSet<String> {
    let names = TreeSet<String>()
    while (let Some(m) <- it.next()) {
        names.add(m.name)
    }
    names
}

@Test
public class BeanIterator_test {
    @TestCase
    public func testIteratorAndCollectionEquivalence(): Unit {
        let f = BeanFactory.instance
        let wildPattern = 'fountain::f_bean.test.*'
        let reDog = '.*BeanTestDog.*'
        let dogName = f.getFirstTuple<BeanTestDog>().getOrThrow()[0]
        let catName = f.getFirstTuple<BeanTestCat>().getOrThrow()[0]

        // IgnoreCond：两个实现类都在（快路径不得漏元素）
        let all = collectNames(f.iterator<BeanTestAnimal>())
        @Assert(all.size, 2)
        @Assert(all.contains(dogName), true)
        @Assert(all.contains(catName), true)
        // 带条件：只看狗
        let onlyDog = collectNames(f.iterator<BeanTestAnimal>(cond: Regexp(reDog)))
        @Assert(onlyDog.size, 1)
        @Assert(onlyDog.contains(dogName), true)
        // getList / getMap / getAllTuples 与迭代器口径一致
        @Assert(f.getList<BeanTestAnimal>().size, 2)
        @Assert(f.getList<BeanTestAnimal>(cond: Wildcard(wildPattern)).size, 2)
        @Assert(f.getMap<BeanTestAnimal>().size, 2)
        @Assert(f.getAllTuples<BeanTestAnimal>().size, 2)
    }

    @TestCase
    public func testFirstTupleEquivalence(): Unit {
        let f = BeanFactory.instance
        let reCat = '.*BeanTestCat.*'
        let reDog = '.*BeanTestDog.*'
        let dogName = f.getFirstTuple<BeanTestDog>().getOrThrow()[0]
        let catName = f.getFirstTuple<BeanTestCat>().getOrThrow()[0]
        // 同一类型重复取一致
        @Assert(f.getFirstTuple<BeanTestDog>().getOrThrow()[0], dogName)
        // 条件路径（`T <: Object`，只能用类类型）：命中猫 ⇒ 拿到猫；用狗的模式 ⇒ None
        @Assert(f.getFirstTuple<BeanTestCat>(cond: Regexp(reCat)).getOrThrow()[0], catName)
        @Assert(f.getFirstTuple<BeanTestCat>(cond: Regexp(reDog)).isNone(), true)
        // Exactly：同类名字命中、异类名字 None
        @Assert(f.getFirstTuple<BeanTestDog>(cond: Exactly(dogName)).isSome(), true)
        @Assert(f.getFirstTuple<BeanTestDog>(cond: Exactly(catName)).isNone(), true)
    }

    @TestCase
    public func testBenchmarkIteratorAndTuple(): Unit {
        let f = BeanFactory.instance
        let reAll = Regexp('.*')
        let n: Int64 = 60_000
        let f64 = Float64(n)
        var seen: Int64 = 0

        // ① IgnoreCond 迭代器：1 轮热身 + 4 轮取最快
        for (_ in 0..n) {
            let it = f.iterator<BeanTestAnimal>()
            while (let Some(_) <- it.next()) {
                seen += 1
            }
        }
        var bestIgnore = 0.0
        for (r in 0..4) {
            let t = DateTime.now()
            for (_ in 0..n) {
                let it = f.iterator<BeanTestAnimal>()
                while (let Some(_) <- it.next()) {
                    seen += 1
                }
            }
            let ms = (DateTime.now() - t) / Duration.millisecond
            if (r == 0 || ms < bestIgnore) {
                bestIgnore = ms
            }
        }
        // ② 带条件迭代器（Regexp，两个都命中）：1 轮热身 + 4 轮取最快
        for (_ in 0..n) {
            let it = f.iterator<BeanTestAnimal>(cond: reAll)
            while (let Some(_) <- it.next()) {
                seen += 1
            }
        }
        var bestRegexp = 0.0
        for (r in 0..4) {
            let t = DateTime.now()
            for (_ in 0..n) {
                let it = f.iterator<BeanTestAnimal>(cond: reAll)
                while (let Some(_) <- it.next()) {
                    seen += 1
                }
            }
            let ms = (DateTime.now() - t) / Duration.millisecond
            if (r == 0 || ms < bestRegexp) {
                bestRegexp = ms
            }
        }
        // ③ getFirstTuple：单次更便宜、抖动占比更大 ⇒ 8 轮取最快
        for (_ in 0..n) {
            if (f.getFirstTuple<BeanTestDog>().isSome()) {
                seen += 1
            }
        }
        var bestTuple = 0.0
        for (r in 0..8) {
            let t = DateTime.now()
            for (_ in 0..n) {
                if (f.getFirstTuple<BeanTestDog>().isSome()) {
                    seen += 1
                }
            }
            let ms = (DateTime.now() - t) / Duration.millisecond
            if (r == 0 || ms < bestTuple) {
                bestTuple = ms
            }
        }
        println("BENCH iterator/getFirstTuple x${n}: iterator(IgnoreCond) ${bestIgnore}ms (${bestIgnore * 1000000.0 / f64} ns/op, min of 4), iterator(Regexp) ${bestRegexp}ms (${bestRegexp * 1000000.0 / f64} ns/op, min of 4), getFirstTuple ${bestTuple}ms (${bestTuple * 1000000.0 / f64} ns/op, min of 8)")
        @Assert(seen, n * 29)
    }
}
