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
package fountain::f_data.path

import std.unittest.*
import std.unittest.testmacro.*
import std.collection.*
import fountain::f_data.base.*
import fountain::f_data.exception.DataException

@Test
public class DataPath_compile_error_test {
    @TestCase
    public func testMissingRootDollar(): Unit {
        var ok = false
        try {
            DataPath.cache("x.y")
        } catch (_: DataException) {
            ok = true
        }
        @Assert(true, ok)
    }

    @TestCase
    public func testUnclosedBracket(): Unit {
        var ok = false
        try {
            DataPath.cache("$[0")
        } catch (_: DataException) {
            ok = true
        }
        @Assert(true, ok)
    }

    @TestCase
    public func testIllegalFunction(): Unit {
        var ok = false
        try {
            DataPath.cache("$.unknownFunc()")
        } catch (_: DataException) {
            ok = true
        }
        @Assert(true, ok)
    }
}
