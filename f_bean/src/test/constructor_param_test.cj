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
public import fountain::f_bean.*
import fountain::f_bean.macros.*

/** 可被注入的元素 bean（作 HashSet 元素需要 Hashable & Equatable） */
@Bean
public class CtorParamItem <: Hashable & Equatable<CtorParamItem> {
    public func hashCode(): Int64 {
        0
    }
    public operator func ==(other: CtorParamItem): Bool {
        refEq(this, other)
    }
}

/**
 * §1.8 / `BEAN-1`：`@Constructor` 的集合/可选形参形态覆盖。
 * 宏按形参类型生成 `lookupList`/`lookupHashSet`/`lookupHashMap`/`lookupOption`；
 * 修前 `Set`/`HashSet` 生成 `lookupSet`、`Map`/`HashMap` 生成 `lookupMap`（全仓无定义）⇒ 本文件编译失败。
 * 注意 `HashMap`/`Map` 形参的 KEY 必须是 `String`（按 bean name 注入，见 `lookupHashMap` 的返回类型）。
 */
@Bean
public class CtorParamShapes {
    @Constructor
    public CtorParamShapes(
        public let list: ArrayList<CtorParamItem>,
        public let arr: Array<CtorParamItem>,
        public let hashSet: HashSet<CtorParamItem>,
        public let set: Set<CtorParamItem>,
        public let hashMap: HashMap<String, CtorParamItem>,
        public let map: Map<String, CtorParamItem>,
        public let opt: ?CtorParamItem
    ) {}
}

@Test
public class CtorParamShapes_test {
    @TestCase
    public func testCollectionParamsInjected(): Unit {
        let bean = BeanFactory.instance.getFirst<CtorParamShapes>()
        @Assert(bean.isSome(), true)
        let shapes = bean.getOrThrow()
        // 本文件注册了一个 CtorParamItem，各集合/可选形态都应注入到它
        @Assert(shapes.list.size, 1)
        @Assert(shapes.arr.size, 1)
        @Assert(shapes.hashSet.size, 1)
        @Assert(shapes.set.size, 1)
        @Assert(shapes.hashMap.size, 1)
        @Assert(shapes.map.size, 1)
        @Assert(shapes.opt.isSome(), true)
    }
}
