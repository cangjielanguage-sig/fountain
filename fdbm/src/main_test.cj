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
package fountain::fdbm

import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_version.FountainVersion

/** 阶段 0：证明可执行模块也能跑 `cjpm test`。 */
@Test
public class FdbmMainTest {

    @TestCase
    public func versionIsAvailable(): Unit {
        @Assert(!FountainVersion.isEmpty(), true)
    }
}
