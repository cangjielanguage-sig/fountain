/*
Copyright (c) 2026 WuJingrun（吴京润）

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
package fountain::f_llm.store.it

import std.unittest.*
import std.unittest.testmacro.*

import fountain::f_bean.*
import fountain::f_bean.macros.*
import fountain::f_config.Config

/** 探针接口：两个条件互斥的 bean，用于验证 ConfCond 是否真的按配置过滤 */
public interface BeanProbe {
    func name(): String
}

@Bean
@BeanMeta[condition: ConfCond.Value('probe_conf', StringCond.Exactly('a'))]
public class BeanA <: BeanProbe {
    public func name(): String {
        'A'
    }
}

@Bean
@BeanMeta[condition: ConfCond.Value('probe_conf', StringCond.Exactly('b'))]
public class BeanB <: BeanProbe {
    public func name(): String {
        'B'
    }
}

@Test
public class BeanConditionTest {

    @TestCase
    func testConfCondSelectsMatchingBean(): Unit {
        Config.set<String>([('probe_conf', 'a')])
        let probe = lookupOption<BeanProbe>()
        @Expect(probe.isSome(), true)
        @Expect(probe.getOrThrow().name(), 'A')
    }

    @TestCase
    func testConfCondRejectsNonMatching(): Unit {
        Config.set<String>([('probe_conf', 'a')])
        // 条件不匹配的 BeanB 不会被选中：同一个 lookup 稳定返回 A
        @Expect(lookupOption<BeanProbe>().getOrThrow().name(), 'A')
    }
}
