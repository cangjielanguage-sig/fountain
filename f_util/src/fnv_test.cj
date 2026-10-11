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
package fountain::f_util

import fountain::f_base.*
import std.unittest.*
import std.unittest.testmacro.*

/**
 * FNV 自检：**8 个变体**（FNV-1 / FNV-1a × 32 / 64 / 128 / 256）逐个核对黄金值。
 *
 * 黄金值来源：FNV 官方参数表（offset basis / prime）的**定义直算**（等价实现：Python 任意精度整数），
 * 其中 32 / 64 位与公开参考向量一致（`""`、`"a"`、`"abc"`、`"foobar"`）。
 *
 * 覆盖：变体选择（含 128/256 的 limb 乘与进位传播）、空输入 = offset basis、增量 ≡ 一次算完、
 * String 重载 ≡ 字节重载、`all` 表完整性。
 */
@Test
public class Fnv_test {
    private let check: Array<Byte> = '123456789'.unsafeBytes()
    private let empty: Array<Byte> = []
    private let a: Array<Byte> = 'a'.unsafeBytes()
    private let foobar: Array<Byte> = 'foobar'.unsafeBytes()
    private let cn: Array<Byte> = '仓颉'.unsafeBytes()
    private let lorem: Array<Byte> = 'chongo <Landon Curt Noll> /\\../\\'.unsafeBytes()

    /** 8 个变体 × `"123456789"` 的黄金值（十六进制小写、宽度定长）。 */
    @TestCase
    public func checkValues(): Unit {
        @Assert(Fnv32.fnv1.computeHex(check), "24148816")
        @Assert(Fnv32.fnv1a.computeHex(check), "bb86b11c")
        @Assert(Fnv64.fnv1.computeHex(check), "a72ffc362bf916d6")
        @Assert(Fnv64.fnv1a.computeHex(check), "06d5573923c6cdfc")
        @Assert(Fnv128.fnv1.computeHex(check), "8bea2c73be03b30fd4142fb1ec2c2066")
        @Assert(Fnv128.fnv1a.computeHex(check), "da2d42a08d04e4585dd325117f71d504")
        @Assert(Fnv256.fnv1.computeHex(check),
            "0c37a392d3522f845f2553c403a80f659b80c9a5b0151496cc37419f79b95ef6")
        @Assert(Fnv256.fnv1a.computeHex(check),
            "0c2033a9bfac21398d7ba2c403a80f659b80c9a5b01178b5cff0ab62e9d53c4c")
        // 变体内建黄金值必须与上表一致（防止常量与实现漂移）
        for (v in Fnv32.all) {
            @Assert(fnvHex64(UInt64(v.checkValue), 8), v.computeHex(check))
        }
        for (v in Fnv64.all) {
            @Assert(fnvHex64(v.checkValue, 16), v.computeHex(check))
        }
        for (v in Fnv128.all) {
            @Assert(fnvHex128(v.checkValue), v.computeHex(check))
        }
        for (v in Fnv256.all) {
            @Assert(v.checkHex, v.computeHex(check))
        }
    }

    /** 空输入 = offset basis（FNV-1 与 FNV-1a 同值：循环未执行）。 */
    @TestCase
    public func emptyInputIsOffsetBasis(): Unit {
        @Assert(Fnv32.fnv1a.computeHex(empty), "811c9dc5")
        @Assert(Fnv64.fnv1a.computeHex(empty), "cbf29ce484222325")
        @Assert(Fnv128.fnv1a.computeHex(empty), "6c62272e07bb014262b821756295c58d")
        @Assert(Fnv256.fnv1a.computeHex(empty),
            "dd268dbcaac550362d98c384c4e576ccc8b1536847b6bbb31023b4c8caee0535")
    }

    /** 公开参考向量（32/64 位与 FNV 官方参考一致；128/256 为定义直算值）。 */
    @TestCase
    public func referenceVectors(): Unit {
        @Assert(Fnv32.fnv1a.computeHex(a), "e40c292c")
        @Assert(Fnv32.fnv1a.computeHex(foobar), "bf9cf968")
        @Assert(Fnv64.fnv1a.computeHex(a), "af63dc4c8601ec8c")
        @Assert(Fnv64.fnv1a.computeHex(foobar), "85944171f73967e8")
        @Assert(Fnv64.fnv1.computeHex(a), "af63bd4c8601b7be")
        @Assert(Fnv128.fnv1a.computeHex(a), "d228cb696f1a8caf78912b704e4a8964")
        @Assert(Fnv128.fnv1.computeHex(a), "d228cb69101a8caf78912b704e4a141e")
        @Assert(Fnv128.fnv1a.computeHex(cn), "97f080337d3c64bf6d4aa193a4955085")
        @Assert(Fnv256.fnv1a.computeHex(a),
            "63323fb0f35303ec28dc751d0a33bdfa4de6a99b7266494f6183b2716811637c")
        @Assert(Fnv256.fnv1a.computeHex(cn),
            "b055ea2f3f82f58709c0e5c02d3889dc32453dad5ae35b753f1da4c1d19f6015")
        @Assert(Fnv256.fnv1.computeHex(lorem),
            "be08cda508edcbe77284caaa0e6f676103af865cf2c035bd55991613a70ef604")
        @Assert(Fnv256.fnv1a.computeHex(lorem),
            "4e4a25bfb530772a8232c94adffde11456e83ac788b47f47a8cce602fda72b16")
    }

    /** FNV-1 与 FNV-1a 必须给出不同结果（顺序敏感；`"a"` 单字节即可分辨）。 */
    @TestCase
    public func flavorOrderIsDistinct(): Unit {
        @Assert(Fnv32.fnv1.computeHex(a) != Fnv32.fnv1a.computeHex(a))
        @Assert(Fnv64.fnv1.computeHex(a) != Fnv64.fnv1a.computeHex(a))
        @Assert(Fnv128.fnv1.computeHex(a) != Fnv128.fnv1a.computeHex(a))
        @Assert(Fnv256.fnv1.computeHex(a) != Fnv256.fnv1a.computeHex(a))
    }

    /** 增量接口 ≡ 一次算完（分片边界任意；128/256 走 limb 路径同样成立）。 */
    @TestCase
    public func incrementalEqualsOneShot(): Unit {
        let text = '123456789'
        let data = text.unsafeBytes()
        let head = data[0..4]
        let tail = data[4..]

        var h32 = Fnv32.fnv1a.update(Fnv32.fnv1a.initRegister(), head)
        h32 = Fnv32.fnv1a.finish(Fnv32.fnv1a.update(h32, tail))
        @Assert(h32, Fnv32.fnv1a.compute(data))

        var h64 = Fnv64.fnv1a.update(Fnv64.fnv1a.initRegister(), head)
        h64 = Fnv64.fnv1a.finish(Fnv64.fnv1a.update(h64, tail))
        @Assert(h64, Fnv64.fnv1a.compute(data))

        var h128 = Fnv128.fnv1a.update(Fnv128.fnv1a.initRegister(), head)
        h128 = Fnv128.fnv1a.finish(Fnv128.fnv1a.update(h128, tail))
        @Assert(h128, Fnv128.fnv1a.compute(data))

        var h256 = Fnv256.fnv1a.update(Fnv256.fnv1a.initRegister(), head)
        h256 = Fnv256.fnv1a.finish(Fnv256.fnv1a.update(h256, tail))
        @Assert(fnvHexBytes(h256), Fnv256.fnv1a.computeHex(data))

        // FNV-1（先乘后异或）的增量同样成立
        var r64 = Fnv64.fnv1.update(Fnv64.fnv1.initRegister(), head)
        r64 = Fnv64.fnv1.update(r64, tail)
        @Assert(r64, Fnv64.fnv1.compute(data))
    }

    /** String 重载 ≡ 字节重载（UTF-8）。 */
    @TestCase
    public func stringOverloadMatchesBytes(): Unit {
        @Assert(Fnv32.fnv1a.computeHex('仓颉'), Fnv32.fnv1a.computeHex(cn))
        @Assert(Fnv64.fnv1a.computeHex('仓颉'), Fnv64.fnv1a.computeHex(cn))
        @Assert(Fnv128.fnv1a.computeHex('仓颉'), Fnv128.fnv1a.computeHex(cn))
        @Assert(Fnv256.fnv1a.computeHex('仓颉'), Fnv256.fnv1a.computeHex(cn))
    }

    /** `all` 表完整（每个宽度两个变体；与 `name` 对应）。 */
    @TestCase
    public func allTablesAreComplete(): Unit {
        @Assert(Fnv32.all.size, 2)
        @Assert(Fnv64.all.size, 2)
        @Assert(Fnv128.all.size, 2)
        @Assert(Fnv256.all.size, 2)
        @Assert(Fnv32.all[0].name, "FNV-1-32")
        @Assert(Fnv32.all[1].name, "FNV-1a-32")
        @Assert(Fnv64.all[0].name, "FNV-1-64")
        @Assert(Fnv64.all[1].name, "FNV-1a-64")
        @Assert(Fnv128.all[0].name, "FNV-1-128")
        @Assert(Fnv128.all[1].name, "FNV-1a-128")
        @Assert(Fnv256.all[0].name, "FNV-1-256")
        @Assert(Fnv256.all[1].name, "FNV-1a-256")
    }
}
