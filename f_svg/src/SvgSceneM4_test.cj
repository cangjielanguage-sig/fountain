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
package fountain::f_svg

import std.unittest.*
import std.unittest.testmacro.*

/** M4 场景快照：逐像素容差 ≤ 1；M1–M3 快照仍由既有用例逐字节校验。 */
@Test
public class SvgSceneM4_test {
    @TestCase
    public func m4Clip(): Unit {
        compareScene(SvgRenderer().render(loadScene("m4-clip")), "m4-clip")
    }

    @TestCase
    public func m4Filter(): Unit {
        compareScene(SvgRenderer().render(loadScene("m4-filter")), "m4-filter")
    }

    @TestCase
    public func m4Text(): Unit {
        compareScene(SvgRenderer().render(loadScene("m4-text")), "m4-text")
    }

    @TestCase
    public func m4View(): Unit {
        compareScene(SvgRenderer().render(loadScene("m4-view")), "m4-view")
    }
}
