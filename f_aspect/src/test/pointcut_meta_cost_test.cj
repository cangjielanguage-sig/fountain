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
package fountain::f_aspect.test

import std.unittest.*
import std.unittest.testmacro.*
import std.time.*
import fountain::f_base.*
import fountain::f_aspect.*
import fountain::f_aspect.macros.*

/**
 * `ASP-3`（§1.14）计时用：被织入的目标（**没有**任何切面规则命中它 ⇒ 链为空），
 * 另有同体的 `static` 方法（宏只改写 public 实例方法）作未织入基线。
 */
@WeavedBean
public class MetaCostTarget {
    public func c(v: Int64): Int64 {
        v
    }
    public static func cStatic(v: Int64): Int64 {
        v
    }
}

/**
 * `ASP-3`（§1.14）的观测方式说明：每次调用是否重建函数元信息（`QualifiedFuncInfo`）**对切面不可见**
 * ——切面拿到的是链里捕获的首次元数据（见 `PointcutMetaReuse_test` 的 `refEq` 守卫），
 * 所以用「同体方法 + 1e6 次调用」的耗时差来观测织入开销（修前基线 / 修后对比），把报告里
 * 「倍数待验证」的 `getInstanceFunction` 与分配成本量化。
 */
@Test
public class PointcutMetaCost_test {
    @TestCase
    public func testMeasureWeaveOverheadPerCall(): Unit {
        let rounds = 1000000
        let bean = MetaCostTarget()
        // 预热
        bean.c(0)
        MetaCostTarget.cStatic(0)

        let t0 = DateTime.now()
        for (i in 0..rounds) {
            bean.c(i)
        }
        let woven = (DateTime.now() - t0).toNanoseconds() / rounds

        let t1 = DateTime.now()
        for (i in 0..rounds) {
            MetaCostTarget.cStatic(i)
        }
        let plain = (DateTime.now() - t1).toNanoseconds() / rounds

        println(
            "每调用耗时：被织入 ${woven} ns，未织入(static 同体) ${plain} ns，差 ${woven - plain} ns（${rounds} 次）")
        @Assert(bean.c(7), 7)
    }
}
