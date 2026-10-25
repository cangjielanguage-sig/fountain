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

import std.unittest.*
import std.unittest.testmacro.*

@Test
class JsonSchemaValidator_test {
    static func arr(values: Array<JsonValue>): JsonArray {
        let list = ArrayList<JsonValue>()
        for (v in values) {
            list.add(v)
        }
        JsonArray(list: list)
    }

    @TestCase
    public func testStringMinLength(): Unit {
        let result = JsonStringSchema(minLength: 2).validate(JsonString('a'))
        @Assert(false, result.isValid)
        @Assert(1, result.errors.size)
        @Assert('', result.errors[0].path)
        @Assert('minLength', result.errors[0].keyword)
    }

    @TestCase
    public func testStringMaxLength(): Unit {
        let result = JsonStringSchema(maxLength: 2).validate(JsonString('abc'))
        @Assert(false, result.isValid)
        @Assert('maxLength', result.errors[0].keyword)
    }

    @TestCase
    public func testStringLengthCountsRunes(): Unit {
        // "😀" 是一个字符，四个 UTF-8 字节：maxLength 1 必须通过
        let result = JsonStringSchema(maxLength: 1).validate(JsonString('😀'))
        @Assert(true, result.isValid)
    }

    @TestCase
    public func testEnum(): Unit {
        let schema = JsonStringSchema(enumeration: '["a","b"]')
        @Assert(true, schema.validate(JsonString('a')).isValid)
        let result = schema.validate(JsonString('c'))
        @Assert(false, result.isValid)
        @Assert('enum', result.errors[0].keyword)
    }

    @TestCase
    public func testTypeMismatch(): Unit {
        let result = JsonIntSchema().validate(JsonString('1'))
        @Assert(false, result.isValid)
        @Assert('type', result.errors[0].keyword)
    }

    @TestCase
    public func testIntRange(): Unit {
        let schema = JsonIntSchema(minimum: 2, maximum: 4)
        @Assert(true, schema.validate(JsonInt(3)).isValid)
        @Assert(
            'minimum',
            schema.validate(JsonInt(1)).errors[0].keyword)
        @Assert(
            'maximum',
            schema.validate(JsonInt(5)).errors[0].keyword)
    }

    @TestCase
    public func testPattern(): Unit {
        let schema = JsonStringSchema(pattern: '^ab+$')
        @Assert(true, schema.validate(JsonString('abb')).isValid)
        let result = schema.validate(JsonString('ac'))
        @Assert(false, result.isValid)
        @Assert('pattern', result.errors[0].keyword)
    }

    @TestCase
    public func testFormatEmail(): Unit {
        let schema = JsonStringSchema(format: 'email')
        @Assert(true, schema.validate(JsonString('a@b.cn')).isValid)
        @Assert(false, schema.validate(JsonString('nope')).isValid)
    }

    @TestCase
    public func testArrayItemsRecursion(): Unit {
        let schema = JsonArraySchema(items: JsonStringSchema(minLength: 2))
        let result = schema.validate(arr([JsonString('ok'), JsonString('a')]))
        @Assert(false, result.isValid)
        @Assert('/1', result.errors[0].path)
        @Assert('minLength', result.errors[0].keyword)
    }

    @TestCase
    public func testArrayUniqueItems(): Unit {
        let schema = JsonArraySchema(uniqueItems: true)
        let result = schema.validate(arr([JsonInt(1), JsonInt(1)]))
        @Assert(false, result.isValid)
        @Assert('uniqueItems', result.errors[0].keyword)
    }

    @TestCase
    public func testDocumentObjectProperties(): Unit {
        let schema = JsonObject()
        schema.add('type', 'object')
        let properties = JsonObject()
        let query = JsonObject()
        query.add('type', 'string')
        query.add('minLength', 2)
        properties.add('query', query)
        schema.add('properties', properties)
        schema.add('required', arr([JsonString('query')]))

        let okValue = JsonObject()
        okValue.add('query', 'abc')
        @Assert(true, JsonSchemaValidator.validate(schema, okValue).isValid)

        let missing = JsonObject()
        let missingResult = JsonSchemaValidator.validate(schema, missing)
        @Assert(false, missingResult.isValid)
        @Assert('required', missingResult.errors[0].keyword)

        let tooShort = JsonObject()
        tooShort.add('query', 'a')
        let shortResult = JsonSchemaValidator.validate(schema, tooShort)
        @Assert(false, shortResult.isValid)
        @Assert('/query', shortResult.errors[0].path)
    }

    @TestCase
    public func testDocumentAdditionalProperties(): Unit {
        let schema = JsonObject()
        schema.add('type', 'object')
        schema.add('additionalProperties', false)
        let properties = JsonObject()
        let name = JsonObject()
        name.add('type', 'string')
        properties.add('name', name)
        schema.add('properties', properties)

        let bad = JsonObject()
        bad.add('name', 'x')
        bad.add('extra', 'y')
        let result = JsonSchemaValidator.validate(schema, bad)
        @Assert(false, result.isValid)
        @Assert('additionalProperties', result.errors[0].keyword)
    }

    @TestCase
    public func testDocumentNullable(): Unit {
        let schema = JsonObject()
        schema.add('type', 'string')
        schema.add('nullable', true)
        @Assert(true, JsonSchemaValidator.validate(schema, JsonNull.instance).isValid)
    }

    @TestCase
    public func testRefIsRejected(): Unit {
        let schema = JsonObject()
        schema.add('$ref', '#/defs/x')
        let result = JsonSchemaValidator.validate(schema, JsonString('x'))
        @Assert(false, result.isValid)
        @Assert('$schema', result.errors[0].keyword)
    }

    @TestCase
    public func testBadSchemaIsRejected(): Unit {
        let schema = JsonObject()
        schema.add('type', 'object')
        schema.add('required', 'query')      // 必须是数组
        let result = JsonSchemaValidator.validate(schema, JsonObject())
        @Assert(false, result.isValid)
        @Assert('$schema', result.errors[0].keyword)
    }

    @TestCase
    public func testUnknownKeywordSkip(): Unit {
        let schema = JsonObject()
        schema.add('allOf', JsonArray())
        let result = JsonSchemaValidator.validate(schema, JsonString('x'),
            options: ValidationOptions(unknownKeyword: UnknownKeyword.Skip))
        @Assert(true, result.isValid)
        @Assert(true, result.skipped.size > 0)
    }

    @TestCase
    public func testMaxErrors(): Unit {
        let schema = JsonArraySchema(items: JsonStringSchema(minLength: 2))
        let items = ArrayList<JsonValue>()
        for (_ in 0..50) {
            items.add(JsonString('a'))
        }
        let result = schema.validate(JsonArray(list: items),
            options: ValidationOptions(maxErrors: 8))
        @Assert(8, result.errors.size)
    }

    @TestCase
    public func testToJson(): Unit {
        let result = JsonStringSchema(minLength: 2).validate(JsonString('a'))
        let json = result.toJson()
        @Assert(1, json.size)
        let item = json[0].asObject()
        @Assert(true, item.contains('path'))
        @Assert(true, item.contains('keyword'))
        @Assert(true, item.contains('message'))
        @Assert('minLength', item['keyword'].asString().value)
    }

    @TestCase
    public func testValidResultToJsonIsEmpty(): Unit {
        let result = JsonIntSchema().validate(JsonInt(1))
        @Assert(true, result.isValid)
        @Assert(0, result.toJson().size)
    }
}
