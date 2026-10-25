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
package fountain::f_data.test

import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_data.*
import fountain::f_data.json.*
import fountain::f_data.macros.DataAssist
import fountain::f_data.base.MutableField

/**
 * 覆盖 2026-10-15 修复的 JsonStringSchema.format 丢弃问题（详见 doc/REVIEW_2026-10-15.md）。
 */
@DataAssist[fields props]
public class SchemaTestBean {
    @JsonStringSchema[format: 'email', minLength: 3]
    private var email: String = ''

    /**
     * 注意：`JsonObject.toJsonSchema<T>()` 反射查找的是**静态** `mutableFields()`，
     * 而 f_data 的 `@DataAssist[fields]` 只生成 `dataFields()`（生成 `mutableFields` 的是 f_bean 的 `@Bean`）。
     * 这里手写一份以便在 f_data 内覆盖 schema 生成；该耦合已记入 REVIEW §2。
     */
    public static func mutableFields(): Iterator<MutableField> {
        SchemaTestBean.dataFields().mutableFields()
    }
}

@DataAssist[fields props]
public class SchemaDataAssistBean {
    @JsonStringSchema[minLength: 2]
    public var name: String = ''
}

@Test
public class JsonSchemaDataAssistTest {
    @TestCase
    public func testDataFieldsFallback(): Unit {
        let schema = JsonObject.toJsonSchema<SchemaDataAssistBean>().toString()
        @Assert(true, schema.contains('"name"'))
        @Assert(true, schema.contains('"minLength"'))
    }
}

@Test
public class JsonSchemaFormatTest {
    @TestCase
    public func testFormatIsEmitted(): Unit {
        let schema = JsonObject.toJsonSchema<SchemaTestBean>().toString()
        // 修复前 format 参数被静默丢弃，生成结果里没有 "format"
        @Assert(schema.contains('"format"'))
        @Assert(schema.contains('email'))
        @Assert(schema.contains('"minLength"'))
    }
}
