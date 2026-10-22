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
package fountain::f_config

import std.unittest.*
import std.unittest.testmacro.*

@Test
class ConfigTest {
    /** 删除后必须回到「键不存在」，而不是「值为空串」。 */
    @TestCase
    public func setThenRemoveRestoresAbsence(): Unit {
        Config.set([("mqTestKey", "v")])
        @Assert(Config.getString("mqTestKey") == Some("v"))
        Config.remove("mqTestKey")
        @Assert(Config.getString("mqTestKey").isNone())
    }

    @TestCase
    public func removeAbsentKeyIsNoOp(): Unit {
        Config.remove("mqTestMissingKey")
        @Assert(Config.getString("mqTestMissingKey").isNone())
    }
}
