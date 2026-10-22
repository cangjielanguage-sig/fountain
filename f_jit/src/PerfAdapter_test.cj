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
package fountain::f_jit

import std.reflect.*
import std.time.DateTime
import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_jit.test.ReflectUser
import fountain::f_jit.test.TCase

/**
 * 类型化包装闭包 vs 反射 `apply`（用户提案的量化验证）。
 *
 * 提案：把目标函数包成 `(Array<Any>) -> Any`，在包装体开头把每个实参 `as` 成形参类型，
 * 再用静态类型的调用表达式调用真实函数——于是每次调用退化为「普通闭包调用 + N 次 as」，
 * 不再走 `MapleRuntime::MethodInfo::ApplyCJMethod` 的参数打包与 MCC stub 跳转。
 *
 * 本用例测的是**这一层替换本身**能省多少（不含验签与 cell 搬运）：
 * - A 路径 = 现状：`InstanceFunctionInfo.apply(instance, tail(args))`；
 * - B 路径 = 提案：手写类型化 adapter `{ a => (a[0] as ReflectUser).greet(a[1] as String) }`。
 *
 * 两条路径都每次新建 `Array<Any>`（真实路径每次也新建）。
 * 实测（2026-10-20，release）：反射 9797 ns/次、类型化 270 ns/次 = **36×**；
 * 门禁取 3×（留足余量，只拦退化不锁死实现）。
 */
@Test
public class PerfAdapter_test {
    @TestCase
    public func typedAdapterVsReflectApply(): Unit {
        let cls = match (TypeInfo.of<ReflectUser>()) {
            case c: ClassTypeInfo => c
            case _ => @Fail('ReflectUser 不是 ClassTypeInfo')
        }
        var greetOpt: ?InstanceFunctionInfo = None
        for (f in cls.instanceFunctions) {
            if (f.name == 'greet') {
                greetOpt = Some(f)
            }
        }
        let gf = match (greetOpt) {
            case Some(x) => x
            case None => @Fail('未找到 ReflectUser.greet')
        }
        let u = ReflectUser('bob', 7)
        let rounds: Int64 = 2000
        // 提案形态：`as` 在仓颉返回 Option，故 adapter 体内是「解包 + 静态类型调用」。
        // 与宏将展开出的代码同形（宏拿到类型语法，写法相同）。
        let typed: (Array<Any>) -> Any = { a =>
            let r = match (a[0] as ReflectUser) {
                case Some(x) => x
                case None => throw Exception('arg0 不是 ReflectUser')
            }
            let s0 = match (a[1] as String) {
                case Some(x) => x
                case None => throw Exception('arg1 不是 String')
            }
            r.greet(s0)
        }
        // 预热（含反射元数据建立）
        var i = 0
        while (i < 64) {
            let w: Array<Any> = [u, 'z']
            let _ = gf.apply(w[0], PerfAdapter_test.tail(w))
            let _ = typed(w)
            i = i + 1
        }

        let t0 = DateTime.now()
        i = 0
        while (i < rounds) {
            let a: Array<Any> = [u, 'z']
            let _ = gf.apply(a[0], PerfAdapter_test.tail(a))
            i = i + 1
        }
        let appliedNs = (DateTime.now() - t0).toNanoseconds()

        let t1 = DateTime.now()
        i = 0
        while (i < rounds) {
            let a: Array<Any> = [u, 'z']
            let _ = typed(a)
            i = i + 1
        }
        let typedNs = (DateTime.now() - t1).toNanoseconds()

        // 门禁：类型化 adapter 必须**至少快 3 倍**（实测 36 倍，见 `doc/perf-m2.md`）。
        // 失效含义：反射 `apply` 的开销已不成瓶颈，或 adapter 被编译器劣化——两者都需重新评估。
        if (typedNs * 3 >= appliedNs) {
            @Fail('PERF-ADAPTER applied=' + appliedNs.toString() + 'ns typed=' +
                typedNs.toString() + 'ns ratioX100=' + (typedNs * 100 / appliedNs).toString())
        }
        @Assert(TCase.hit('T32/typed-adapter-beats-reflect', appliedNs > typedNs * 3), true)
    }

    static func tail(a: Array<Any>): Array<Any> {
        if (a.size <= 1) {
            return Array<Any>()
        }
        let out = Array<Any>(a.size - 1, repeat: 0)
        var i = 1
        while (i < a.size) {
            out[i - 1] = a[i]
            i = i + 1
        }
        out
    }
}
