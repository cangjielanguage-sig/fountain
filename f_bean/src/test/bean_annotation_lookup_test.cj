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
import std.sync.AtomicInt64
public import fountain::f_bean.*
import fountain::f_bean.macros.*

/**
 * §3.1 / `BEAN-L6`：按注解取 bean（`getFirstByAnnotation`／`getListByAnnotation`／`getMapByAnnotation`
 * 与 `lookupByAnnotation`／`lookupListByAnnotation`／`lookupMapByAnnotation`）。
 *
 * 覆盖：注解在**自身类型**／**父类**／**接口**三种位置；`T` 类型过滤；名字条件；`order` 顺序；
 * `getMapByAnnotation` 以 bean 名为 KEY；空结果；无命中即抛；「未命中类型的 prototype 不被实例化」。
 * 元注解链（注解的注解）由 `doRegister` 的类型队列支持，本文件**暂未覆盖**。
 *
 * 注意：约束是 `T <: Object`，而仓颉里 **interface 不是 `Class-Object` 的子类型**
 * ⇒ `T` 只能用类（本例用基类 `AnnSelfItem`），不能用接口。
 */
@Annotation[target: [Type]]
public class AnnMark {
    public const init() {}
}

@Annotation[target: [Type]]
public class AnnOther {
    public const init() {}
}

@Annotation[target: [Type]]
public class AnnUnused {
    public const init() {}
}

/** 三个「自身类型带注解」的 bean 的基类（它自己不是 bean、也不带注解），便于用类作 `T` 精确圈定。 */
public open class AnnSelfItem {
    public open prop code: Int64 {
        get() { 0 }
    }
}

@Bean
@BeanMeta[order: 1]
@AnnMark
public class AnnSelf1 <: AnnSelfItem {
    public override prop code: Int64 {
        get() { 1 }
    }
}

@Bean
@BeanMeta[order: 2]
@AnnMark
public class AnnSelf2 <: AnnSelfItem {
    public override prop code: Int64 {
        get() { 2 }
    }
}

@Bean
@BeanMeta[order: 3]
@AnnMark
public class AnnSelf3 <: AnnSelfItem {
    public override prop code: Int64 {
        get() { 3 }
    }
}

/** 注解在父类上（子类自身无注解）。 */
@Bean
@AnnMark
public open class AnnParentMarked {}

@Bean
public class AnnParentChild <: AnnParentMarked {}

/** 注解在接口上（实现类自身无注解）。 */
@AnnMark
public interface AnnMarkedIface {}

@Bean
public class AnnIfaceImpl <: AnnMarkedIface {}

/** 另一个注解的 bean：用于验证 `A` 过滤。 */
@Bean
@AnnOther
public class AnnOtherBean {}

/** prototype 的 `@AnnMark` bean：用于验证「未命中类型的 prototype 不会被实例化」。 */
@Bean
@BeanMeta[scope: BeanScope.prototype]
@AnnMark
public class AnnPrototypeBean {
    public static let created = AtomicInt64(0)
    public init() {
        created.fetchAdd(1)
    }
}

@Test
public class BeanAnnotationLookup_test {
    private let factory = BeanFactory.instance

    @TestCase
    public func testSelfParentInterfacePositions(): Unit {
        // 自身类型上的注解
        @Assert(lookupListByAnnotation<AnnSelf1, AnnMark>().size, 1)
        @Assert(lookupListByAnnotation<AnnSelfItem, AnnMark>().size, 3)
        // 父类上的注解：子类自身没标注，用「子类」作 T 查得到 ⇒ 证明父类注解被继承
        @Assert(lookupListByAnnotation<AnnParentChild, AnnMark>().size, 1)
        @Assert(lookupListByAnnotation<AnnParentMarked, AnnMark>().size, 2)
        // 接口上的注解：实现类自身没标注，用「实现类」作 T 查得到 ⇒ 证明接口注解被继承
        @Assert(lookupListByAnnotation<AnnIfaceImpl, AnnMark>().size, 1)
    }

    @TestCase
    public func testTypeFilterAndOrder(): Unit {
        // T 圈定 AnnSelfItem ⇒ 恰好 3 个，顺序 = 注解桶的 order 升序（@BeanMeta[order: 1..3]）
        let list = lookupListByAnnotation<AnnSelfItem, AnnMark>()
        @Assert(list.size, 3)
        for (i in 0..list.size) {
            @Assert(list[i].code, i + 1)
        }
        // T = Object ⇒ 全部被 AnnMark 修饰的 bean：3（自身）+ 2（父类链）+ 1（接口实现）+ 1（prototype）= 7
        @Assert(lookupListByAnnotation<Object, AnnMark>().size, 7)
    }

    @TestCase
    public func testAnnotationAndCondFilters(): Unit {
        // A 过滤：AnnOther 的 bean 不出现在 AnnMark 的结果里
        @Assert(lookupListByAnnotation<AnnOtherBean, AnnOther>().size, 1)
        @Assert(lookupListByAnnotation<AnnOtherBean, AnnMark>().size, 0)
        // cond 过滤
        @Assert(lookupListByAnnotation<AnnSelfItem, AnnMark>(Wildcard('fountain::f_bean.test.AnnSelf*')).size, 3)
        @Assert(lookupListByAnnotation<AnnSelfItem, AnnMark>(Exactly('no.such.bean')).size, 0)
        // 没有任何 bean 的注解 ⇒ 空
        @Assert(lookupListByAnnotation<AnnSelfItem, AnnUnused>().size, 0)
        @Assert(factory.getMapByAnnotation<AnnSelfItem, AnnUnused>().size, 0)
        @Assert(factory.getFirstByAnnotation<AnnSelfItem, AnnUnused>().isNone(), true)
    }

    @TestCase
    public func testMapKeysAreBeanNames(): Unit {
        let map = factory.getMapByAnnotation<AnnSelfItem, AnnMark>()
        @Assert(map.size, 3)
        var seen: Int64 = 0
        for ((name, bean) in map) {
            // KEY 是 bean 名：按名字能查回同一个 bean
            let found = lookupOption<AnnSelfItem>(Exactly(name))
            if (let Some(f) <- found) {
                @Assert(f.code, bean.code)
            } else {
                @Assert(false, true)
            }
            seen += bean.code
        }
        @Assert(seen, 6)
    }

    @TestCase
    public func testFirstAndThrowWhenAbsent(): Unit {
        // 命中：取 order 最小的那个
        let first = factory.getFirstByAnnotation<AnnSelfItem, AnnMark>()
        if (let Some(f) <- first) {
            @Assert(f.code, 1)
        } else {
            @Assert(false, true)
        }
        // 未命中：get* 返回 None，lookup* 抛 BeanException
        @Assert(factory.getFirstByAnnotation<AnnOtherBean, AnnMark>().isNone(), true)
        var thrown = false
        var got: ?AnnOtherBean = None
        try {
            got = lookupByAnnotation<AnnOtherBean, AnnMark>()
        } catch (e: BeanException) {
            thrown = true
        }
        @Assert(thrown, true)
        @Assert(got.isNone(), true)
    }

    @TestCase
    public func testAnnotationOnlyVersions(): Unit {
        // 只限注解、不限制 bean 类型 ⇒ 与 T = Object 的结果一致（AnnMark 的全部 bean = 7）
        let only = lookupListByAnnotationOnly<AnnMark>()
        @Assert(only.size, 7)
        @Assert(only.size, factory.getListByAnnotation<Object, AnnMark>().size)
        @Assert(factory.getListByAnnotationOnly<AnnMark>().size, 7)
        @Assert(factory.getMapByAnnotationOnly<AnnMark>().size, 7)
        @Assert(lookupMapByAnnotationOnly<AnnMark>().size, 7)
        // cond 过滤 / 无 bean 的注解 ⇒ 空
        @Assert(lookupListByAnnotationOnly<AnnMark>(Wildcard('fountain::f_bean.test.AnnSelf*')).size, 3)
        @Assert(lookupListByAnnotationOnly<AnnUnused>().size, 0)
        @Assert(factory.getFirstByAnnotationOnly<AnnUnused>().isNone(), true)
        @Assert(lookupOptionByAnnotationOnly<AnnUnused>().isNone(), true)
        // 命中并取回同一 bean：限定 AnnSelf* ⇒ 桶内 order 最小的是 AnnSelf1（code = 1）
        let one = lookupOptionByAnnotationOnly<AnnMark>(Wildcard('fountain::f_bean.test.AnnSelf*'))
        if (let Some(o) <- one) {
            if (let v: AnnSelf1 <- o) {
                @Assert(v.code, 1)
            } else {
                @Assert(false, true)
            }
        } else {
            @Assert(false, true)
        }
        // 抛异常版：命中不抛、未命中抛 BeanException
        var notThrown = false
        try {
            let o = lookupByAnnotationOnly<AnnMark>(Wildcard('fountain::f_bean.test.AnnSelf1*'))
            notThrown = true
        } catch (e: BeanException) {
            notThrown = false
        }
        @Assert(notThrown, true)
        var thrown = false
        try {
            let o = lookupByAnnotationOnly<AnnMark>(Exactly('no.such.bean'))
            thrown = false
        } catch (e: BeanException) {
            thrown = true
        }
        @Assert(thrown, true)
    }

    @TestCase
    public func testPrototypeNotInstantiatedWhenTypeMismatched(): Unit {
        let before = AnnPrototypeBean.created.load()
        // 查询 AnnSelfItem：AnnPrototypeBean 不是它的子类型 ⇒ 不应实例化那个 prototype bean
        @Assert(lookupListByAnnotation<AnnSelfItem, AnnMark>().size, 3)
        @Assert(AnnPrototypeBean.created.load(), before)
        // 反向对照：类型匹配（T = Object）时它会被实例化
        @Assert(lookupListByAnnotation<Object, AnnMark>().size, 7)
        @Assert(AnnPrototypeBean.created.load() > before, true)
    }
}
