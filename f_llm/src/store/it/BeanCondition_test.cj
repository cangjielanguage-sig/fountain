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

    /**
     * 进程内 BeanFactory 只初始化一次，所以配置只设一次、两个断言放在同一个用例里：
     * 1) `lookupList` 必须只剩 1 个实现（条件真的把另一个过滤掉）；
     * 2) `lookupOption` 必须给出配置指定的那个（B），而不是排在最前的 A。
     */
    @TestCase
    func testConfCondFiltersAndSelects(): Unit {
        Config.set<String>([('probe_conf', 'b')])
        // 配置设完之后必须重新触发一次条件初始化，否则 bean 仍是按旧配置筛的
        BeanFactory.instance.afterRegistered()

        let probes = lookupList<BeanProbe>()
        @Expect(probes.size, 1)
        @Expect(probes[0].name(), 'B')

        let selected = lookupOption<BeanProbe>()
        @Expect(selected.isSome(), true)
        @Expect(selected.getOrThrow().name(), 'B')
    }
}
