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
package fountain::f_llm.util

import std.unittest.*
import std.unittest.testmacro.*

import fountain::f_data.*

@Test
public class RedactorTest {

    @TestCase
    func testMaskLongSecret(): Unit {
        @Expect(Redactor.mask('sk-1234567890abcdef'), 'sk-1****cdef')
    }

    @TestCase
    func testMaskShortSecret(): Unit {
        @Expect(Redactor.mask('short'), '****')
        @Expect(Redactor.mask('12345678'), '****')
    }

    @TestCase
    func testRedactNestedJson(): Unit {
        let json = JsonValue.fromStr('''
        {
          "model": "deepseek-chat",
          "auth": "sk-1234567890abcdef",
          "nested": {"token": "abcdefghijklmnop", "note": "keep me"}
        }''').asObject()
        let cleaned = Redactor.redactJson(json).asObject()
        @Expect(cleaned.get('model')?.asString().value ?? '', 'deepseek-chat')
        @Expect(cleaned.get('auth')?.asString().value ?? '', 'sk-1****cdef')
        let nested = cleaned.get('nested')?.asObject() ?? JsonObject()
        @Expect(nested.get('token')?.asString().value ?? '', 'abcd****mnop')
        @Expect(nested.get('note')?.asString().value ?? '', 'keep me')
    }

    @TestCase
    func testRedactKeepsNonSensitiveKeys(): Unit {
        let json = JsonValue.fromStr('{"chatPath": "/chat/completions"}').asObject()
        let cleaned = Redactor.redactJson(json).asObject()
        @Expect(cleaned.get('chatPath')?.asString().value ?? '', '/chat/completions')
    }
}
