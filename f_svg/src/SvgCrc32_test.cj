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

import fountain::f_base.*
import std.unittest.*
import std.unittest.testmacro.*

@Test
public class SvgCrc32_test {
    /** 标准测试向量、空数据与分块更新。 */
    @TestCase
    public func standardVectors(): Unit {
        @Assert(SvgCrc32.checksum(Array<Byte>()) == 0)
        @Assert(SvgCrc32.checksum("123456789".unsafeBytes()) == 0xCBF43926)
        @Assert(SvgCrc32.checksum("The quick brown fox jumps over the lazy dog".unsafeBytes()) == 0x414FA339)
        let first = SvgCrc32.update(0, "1234".unsafeBytes())
        let second = SvgCrc32.update(first, "56789".unsafeBytes())
        @Assert(second == SvgCrc32.checksum("123456789".unsafeBytes()))
        @Assert(SvgCrc32.update(0, Array<Byte>()) == 0)
    }
}
