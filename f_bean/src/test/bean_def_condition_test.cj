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
 * `BeanDef` 条件的判定语义钉住（§3.1 / `BEAN-L1` 与 `BEAN-L12`）。
 *
 * - `(IgnoreType, …)`：**现实现一律判真** —— `BeanDefCondition.cj` 首个 case
 *   `case (IgnoreType, IgnoreName)` 里的 `IgnoreName` 是**模式变量绑定**（不是 `StringCond` 的 case），
 *   该 case 即 catch-all，直接 `return true` ⇒ 名条件 / `count` / `scope` 全被忽略（缺陷见 `bug-bean.md` §3.1 `BEAN-L12`）。
 *   本文件按**现状**钉住，不美化。
 * - 类型条件（`Current` / `CurrentOrSuperOf` / `SubOfOnly` / `SuperOfOnly`）走原路径：类型桶 + 真实类型判定
 *   + 名条件 + `scope` 过滤，全部照常生效。
 */
public interface BeanDefSample {}

@Bean
public class BeanDefSampleA <: BeanDefSample {}

@Bean
@BeanMeta[scope: BeanScope.prototype]
public class BeanDefSampleB <: BeanDefSample {}

/**
 * 条件恒假（配置键不存在）的 bean。
 *
 * ⚠️ 测试进程**从不调用** `BeanFactory.afterRegistered()` ⇒ `check()` 不跑 ⇒ 本 bean 不会被丢弃，
 * 因此本文件不对它做「已被丢弃」的断言；被丢弃时的清理路径（§3.1 / `BEAN-L1(b)`）由定向验证覆盖。
 */
@Bean
@BeanMeta[condition: ConfCond.Exists('definitely.no.such.config.key')]
public class BeanDefDiscarded {}

@Test
public class BeanDefCondition_test {
    private let factory = BeanFactory.instance
    private let sampleA = 'fountain::f_bean.test.BeanDefSampleA'
    private let sampleIface = 'fountain::f_bean.test.BeanDefSample'
    private let neverName: StringCond = Exactly('definitely.no.such.bean')
    private let sampleName: StringCond = Wildcard('fountain::f_bean.test.BeanDefSample*')

    @TestCase
    public func testIgnoreTypeCurrentlyMatchesAll(): Unit {
        // ⚠️ 现状（缺陷）：`IgnoreType` 组合一律 true，名条件/count/scope 均不生效 ⇒ 见 §3.1 `BEAN-L12`
        @Assert(BeanDef(beanType: BeanDefType.IgnoreType, beanName: neverName).on(factory), true)
        @Assert(BeanDef(beanType: BeanDefType.IgnoreType, beanName: neverName, count: BeanDefCount.Zero).on(factory),
            true)
        @Assert(BeanDef(beanType: BeanDefType.IgnoreType, beanName: neverName, count: BeanDefCount.OnlyOne).on(factory),
            true)
        @Assert(BeanDef(beanType: BeanDefType.IgnoreType, beanName: neverName, scope: BeanScope.prototype).on(factory),
            true)
        @Assert(BeanDef(beanType: BeanDefType.IgnoreType, beanName: sampleName, count: BeanDefCount.MoreThanOne).on(
            factory), true)
    }

    @TestCase
    public func testTypeCondPaths(): Unit {
        // 类型条件：类型桶 + 真实类型判定照常
        @Assert(BeanDef(beanType: BeanDefType.Current(sampleA)).on(factory), true)
        @Assert(BeanDef(beanType: BeanDefType.CurrentOrSuperOf(sampleA)).on(factory), true)
        @Assert(BeanDef(beanType: BeanDefType.SubOfOnly(sampleIface)).on(factory), true)
        // 反向（接口/祖先本身）在「该接口自己的桶」内不成立
        @Assert(BeanDef(beanType: BeanDefType.CurrentOrSuperOf(sampleIface)).on(factory), false)
        // ⚠️ 该分支扫 `Object` 桶 ⇒ 只要进程里存在「类型为 Any/Object 的 bean」即为 true（本进程由 `obj_test` 提供）
        @Assert(BeanDef(beanType: BeanDefType.SuperOfOnly(sampleA)).on(factory), true)
        // 名条件在类型分支上仍生效
        @Assert(BeanDef(beanType: BeanDefType.SubOfOnly(sampleIface), beanName: neverName).on(factory), false)
        @Assert(BeanDef(beanType: BeanDefType.SubOfOnly(sampleIface), beanName: sampleName).on(factory), true)
        // scope 过滤在类型分支上仍生效（A 是单例、B 是 prototype）
        @Assert(BeanDef(beanType: BeanDefType.SubOfOnly(sampleIface), count: BeanDefCount.OnlyOne,
            scope: BeanScope.prototype).on(factory), true)
        @Assert(BeanDef(beanType: BeanDefType.SubOfOnly(sampleIface), count: BeanDefCount.MoreThanOne,
            scope: BeanScope.prototype).on(factory), false)
    }

    @TestCase
    public func testSamplesVisibleWithoutAfterRegistered(): Unit {
        // 测试进程**不调用** `BeanFactory.afterRegistered()` ⇒ `check()` 不跑 ⇒ 条件恒假的 `BeanDefDiscarded`
        // 在本进程里依然可见；「被丢弃 + 两张类型表清理且不留空键」那条路径由 `BEAN-L1(b)` 的定向验证覆盖
        // （`cjpm test --filter` 单独跑一次、显式调用 `afterRegistered()`；见 `bug-bean.md` §3.1）。
        @Assert(lookupList<BeanDefSample>().size, 2)
        @Assert(lookupList<BeanDefDiscarded>().size, 1)
    }
}
