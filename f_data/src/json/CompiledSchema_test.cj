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
package fountain::f_data.json

import std.collection.ArrayList
import std.unittest.*
import std.unittest.testmacro.*

@Test
class CompiledSchema_test {
    static func arr(values: Array<JsonValue>): JsonArray {
        let list = ArrayList<JsonValue>()
        for (v in values) {
            list.add(v)
        }
        JsonArray(list: list)
    }

    static func objectSchema(): JsonObject {
        let schema = JsonObject()
        schema.add('type', 'object')
        let props = JsonObject()
        let name = JsonObject()
        name.add('type', 'string')
        name.add('pattern', '^[a-z]+$')
        props.add('name', name)
        schema.add('properties', props)
        schema.add('required', arr([JsonString('name')]))
        schema
    }

    static func value(name: String): JsonValue {
        let obj = JsonObject()
        obj.add('name', name)
        obj
    }

    @TestCase
    public func testInvalidPatternTypeIsRejectedAtCompileTime(): Unit {
        let schema = JsonObject()
        schema.add('type', 'object')
        schema.add('pattern', 1)
        try {
            let _ = CompiledSchema.compile(schema)
            @Fail('expected IllegalArgumentException')
        } catch (e: IllegalArgumentException) {
            @Assert(true, e.message.contains('pattern'))
        }
    }

    @TestCase
    public func testInvalidRequiredTypeIsRejectedAtCompileTime(): Unit {
        let schema = JsonObject()
        schema.add('type', 'object')
        schema.add('required', 'x')
        try {
            let _ = CompiledSchema.compile(schema)
            @Fail('expected IllegalArgumentException')
        } catch (e: IllegalArgumentException) {
            @Assert(true, e.message.contains('required'))
        }
    }

    @TestCase
    public func testInvalidRegexIsRejectedAtCompileTime(): Unit {
        let schema = JsonObject()
        schema.add('type', 'string')
        schema.add('pattern', '[unclosed')
        try {
            let _ = CompiledSchema.compile(schema)
            @Fail('expected IllegalArgumentException')
        } catch (e: IllegalArgumentException) {
            @Assert(true, e.message.contains('pattern'))
        }
    }

    @TestCase
    public func testPatternsArePrecompiledOnce(): Unit {
        let compiled = CompiledSchema.compile(objectSchema())
        @Assert(1, compiled.patternCount)
        // 连续校验不改变预编译表（不会每次新建）
        for (_ in 0..100) {
            @Assert(true, compiled.validate(value('abc')).isValid)
        }
        @Assert(1, compiled.patternCount)
    }

    @TestCase
    public func testSameSemanticsAsDocumentValidator(): Unit {
        let schema = objectSchema()
        let compiled = CompiledSchema.compile(schema)
        let samples = [value('abc'), value('ABC'), value('a1'), value('')]
        for (sample in samples) {
            let expected = JsonSchemaValidator.validate(schema, sample)
            let actual = compiled.validate(sample)
            @Assert(expected.isValid, actual.isValid)
            @Assert(expected.errors.size, actual.errors.size)
        }
    }

    @TestCase
    public func testMissingPropertyStillFails(): Unit {
        let compiled = CompiledSchema.compile(objectSchema())
        let result = compiled.validate(JsonObject())
        @Assert(false, result.isValid)
        @Assert(true, result.errors[0].keyword == 'required')
    }
}
