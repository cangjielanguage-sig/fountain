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
package fountain::f_jit.base

import std.unittest.*
import std.unittest.testmacro.*

/**
 * S1.5 公共值类型的失败用例（先写红）：`SourcePos` / `JitMode` / `Engine` / `JitValue`。
 *
 * 权威 = design-m1 §2.3.3（`SourcePos`）与 §2.3.6（三个枚举）：
 *
 * - `SourcePos` = `line`（1 起）+ `column`（1 起，Unicode 码点），站点表条目值（§9.16）；
 * - `JitMode` = `Off | Auto | Force`（**输入侧「用户意图」**，§12.1）；
 * - `Engine` = `Interp | Jit`（**输出侧「实际事实」**，§12.1；`protected`，design §8.7 D6 结案）；
 * - `JitValue` = `Int(Int64) | Float(Float64) | Handle(Int64) | Unit`（桥内三态收尾结果，§8；
 *   `protected`，design §8.7 D3 结案）。
 *
 * `JitValue` 的分派提醒（§2.3.6）：`Handle` 与 `Int` 载荷同型 ⇒ **按构造器标签分派，
 * 不得按载荷类型判断**——本文件用 `Int(7) != Handle(7)` 把这条钉住。
 */
@Test
public class ValueTypes_test {
    /** `SourcePos` 字段读回与构造入参一致，且具值语义（`==` / `!=`）。 */
    @TestCase
    public func sourcePosIsAValueType(): Unit {
        let p = SourcePos(3, 7)
        @Assert(p.line, 3)
        @Assert(p.column, 7)
        @Assert(p == SourcePos(3, 7), true)
        @Assert(p == SourcePos(3, 8), false)
        @Assert(p == SourcePos(7, 3), false)
        @Assert(p != SourcePos(3, 8), true)
    }

    /** 站点表条目构造自 1 起：行/列的最小值 1 亦要能原样读回（§9.16「line/column 1 起」）。 */
    @TestCase
    public func sourcePosKeepsOneBasedOrigin(): Unit {
        let p = SourcePos(1, 1)
        @Assert(p.line, 1)
        @Assert(p.column, 1)
        @Assert(p == SourcePos(1, 1), true)
    }

    /** `JitMode` 三档齐全，`match` 穷尽且 `==` 语义正确（§12.1）。 */
    @TestCase
    public func jitModeHasThreeOptions(): Unit {
        let all = [JitMode.Off, JitMode.Auto, JitMode.Force]
        @Assert(all.size, 3)
        @Assert(all[0], JitMode.Off)
        @Assert(all[1], JitMode.Auto)
        @Assert(all[2], JitMode.Force)
        for (m in all) {
            let text = match (m) {
                case JitMode.Off => 'Off'
                case JitMode.Auto => 'Auto'
                case JitMode.Force => 'Force'
            }
            @Assert(text.isEmpty(), false)
        }
        @Assert(JitMode.Off == JitMode.Auto, false)
        @Assert(JitMode.Force == JitMode.Force, true)
    }

    /** `Engine` 两档齐全，`match` 穷尽；它与 `JitMode` 是两条独立信息（不可互转）。 */
    @TestCase
    public func engineHasTwoOptions(): Unit {
        let all = [Engine.Interp, Engine.Jit]
        @Assert(all.size, 2)
        for (e in all) {
            let text = match (e) {
                case Engine.Interp => 'Interp'
                case Engine.Jit => 'Jit'
            }
            @Assert(text.isEmpty(), false)
        }
        @Assert(Engine.Interp == Engine.Jit, false)
        @Assert(Engine.Interp == Engine.Interp, true)
    }

    /** `JitValue` 四个构造器与 cell 载荷一一对应（§3.2），`match` 穷尽。 */
    @TestCase
    public func jitValueHasFourConstructors(): Unit {
        let all = [JitValue.Int(1), JitValue.Float(1.0), JitValue.Handle(2), JitValue.`Unit`]
        @Assert(all.size, 4)
        for (v in all) {
            let text = match (v) {
                case JitValue.Int(x) => 'Int(${x})'
                case JitValue.Float(x) => 'Float(${x})'
                case JitValue.Handle(x) => 'Handle(${x})'
                case JitValue.`Unit` => 'Unit'
            }
            @Assert(text.isEmpty(), false)
        }
    }

    /** `Handle` 与 `Int` 载荷同型 ⇒ 必须按构造器标签分派（§2.3.6 分派提醒）。 */
    @TestCase
    public func jitValueDispatchesByConstructorNotPayload(): Unit {
        @Assert(JitValue.Int(7) == JitValue.Handle(7), false)
        @Assert(JitValue.Int(7) == JitValue.Int(7), true)
        @Assert(JitValue.Handle(7) == JitValue.Handle(7), true)
        @Assert(JitValue.Float(1.0) == JitValue.Int(1), false)
        @Assert(JitValue.`Unit` == JitValue.`Unit`, true)
        @Assert(JitValue.`Unit` == JitValue.Int(0), false)
        @Assert(JitValue.`Unit` == JitValue.Handle(0), false)
    }
}
