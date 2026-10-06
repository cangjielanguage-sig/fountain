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
 * §3.1 / `BEAN-L6`：**元注解链**（注解的注解）用例。
 *
 * `AnnComposedBean` 自身只标了 `@AnnComposed`，而 `@AnnMeta` 修饰的是注解类 `@AnnComposed`
 * ⇒ 只有把「注解节点自身的注解」也纳入 `annotationMap`，按 `@AnnMeta` 才查得到这个 bean。
 * （对应 `doRegister` 类型队列里 `!isClass || !白名单` 的那条改动。）
 */
@Annotation[target: [Type]]
public class AnnMeta {
    public const init() {}
}

@Annotation[target: [Type]]
@AnnMeta
public class AnnComposed {
    public const init() {}
}

@Bean
@AnnComposed
public class AnnComposedBean {
    public prop tag: Int64 {
        get() { 42 }
    }
}

@Test
public class BeanMetaAnnotationLookup_test {
    @TestCase
    public func testMetaAnnotationChain(): Unit {
        // 元注解链：bean 自身没标 `@AnnMeta`，但它的注解 `@AnnComposed` 被 `@AnnMeta` 修饰
        @Assert(lookupListByAnnotation<AnnComposedBean, AnnMeta>().size, 1)
        // 直接注解当然也查得到
        @Assert(lookupListByAnnotation<AnnComposedBean, AnnComposed>().size, 1)
        // 无 T 过滤（T = Object）同理
        @Assert(lookupListByAnnotation<Object, AnnMeta>().size, 1)
        // lookupOptionByAnnotation（本次新增的 `?T` 变体）
        let viaOption = lookupOptionByAnnotation<AnnComposedBean, AnnMeta>()
        if (let Some(v) <- viaOption) {
            @Assert(v.tag, 42)
        } else {
            @Assert(false, true)
        }
        @Assert(lookupOptionByAnnotation<AnnComposedBean, AnnComposed>().isSome(), true)
        // lookupByAnnotation（抛异常版）：命中时不该抛
        var hitByThrow = false
        try {
            let v = lookupByAnnotation<AnnComposedBean, AnnMeta>()
            hitByThrow = v.tag == 42
        } catch (e: BeanException) {
            hitByThrow = false
        }
        @Assert(hitByThrow, true)
        // 对照：拿别的注解查不到
        @Assert(lookupOptionByAnnotation<AnnComposedBean, AnnUnused>().isNone(), true)
        @Assert(lookupListByAnnotation<AnnComposedBean, AnnUnused>().size, 0)
    }
}
