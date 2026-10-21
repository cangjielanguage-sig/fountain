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
package fountain::f_dbm

import std.unittest.*
import std.unittest.testmacro.*

/** 只实现字符串能力的生成器：整型方法应沿用默认实现并抛契约异常。 */
class StringOnlyGenerator <: IdGenerator {
    public prop name: String {
        get() {
            'string-only'
        }
    }

    public func nextStringId(): String {
        'id-1'
    }
}

/** 只实现整型能力的生成器。 */
class IntOnlyGenerator <: IdGenerator {
    public prop name: String {
        get() {
            'int-only'
        }
    }

    public func nextIntId(): Int64 {
        7
    }
}

/** id 与 string 都不支持的生成器（两个默认实现）。 */
class NoCapabilityGenerator <: IdGenerator {
    public prop name: String {
        get() {
            'none'
        }
    }
}

/** 确定性分片算法：按 key 的字节和取模（用于验证「跨实例一致」）。 */
class StableAlgorithm <: PartitionAlgorithm {
    private let databases: Array<String>

    init(databases: Array<String>) {
        this.databases = databases
    }

    public prop name: String {
        get() {
            'stable'
        }
    }

    public func partition<K>(key: K): String {
        var sum: Int64 = 0
        let text = match (key) {
            case value: Int64 => value.toString()
            case value: String => value
            case _ => 'key'
        }
        for (byte in text.toArray()) {
            sum += Int64(byte)
        }
        databases[sum % databases.size]
    }
}

/** T01：`f_dbm` 扩展契约（默认实现、异常类型、只实现一种能力的合法性）。 */
@Test
public class IdGeneratorTest {

    @TestCase
    public func defaultIntMethodThrowsContractException(): Unit {
        var message = ''
        var threw = false
        try {
            StringOnlyGenerator().nextIntId()
        } catch (e: IdGeneratorException) {
            threw = true
            message = e.message
        }
        @Assert(threw, true)
        @Assert(message.contains('string-only'), true)
        @Assert(message.contains('int'), true)
    }

    @TestCase
    public func defaultStringMethodThrowsContractException(): Unit {
        var message = ''
        var threw = false
        try {
            IntOnlyGenerator().nextStringId()
        } catch (e: IdGeneratorException) {
            threw = true
            message = e.message
        }
        @Assert(threw, true)
        @Assert(message.contains('int-only'), true)
        @Assert(message.contains('string'), true)
    }

    /** 只实现一种能力是合法用法：另一种调用才失败，已实现的方法正常返回。 */
    @TestCase
    public func oneCapabilityIsLegal(): Unit {
        @Assert(StringOnlyGenerator().nextStringId(), 'id-1')
        @Assert(IntOnlyGenerator().nextIntId(), 7)
    }

    @TestCase
    public func noCapabilityThrowsForBoth(): Unit {
        @Assert(messageOf { NoCapabilityGenerator().nextIntId(); () },
            'none does not support int id')
        @Assert(messageOf { NoCapabilityGenerator().nextStringId(); () },
            'none does not support string id')
    }

    private func messageOf(body: () -> Unit): String {
        try {
            body()
        } catch (e: IdGeneratorException) {
            return e.message
        }
        ''
    }
}

/** T01：`PartitionAlgorithm` 必须对同一 key 稳定（与实例无关）。 */
@Test
public class PartitionAlgorithmTest {

    @TestCase
    public func sameKeyIsStableAcrossInstances(): Unit {
        let databases = ['db0', 'db1', 'db2', 'db3']
        let first = StableAlgorithm(databases)
        let second = StableAlgorithm(databases)
        for (key in ['abc', '123', '中文', '']) {
            @Assert(first.partition<String>(key), second.partition<String>(key))
        }
        @Assert(first.partition<Int64>(42), first.partition<String>('42'))
    }
}
