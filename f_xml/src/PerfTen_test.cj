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
package fountain::f_xml

import std.unittest.*
import std.unittest.testmacro.*

/**
 * Gate T：10 MB 事件解析 `min(5) < 1000 ms`（默认运行时、空载、独立进程）。
 *
 * 单独一个类是为了让门禁独占进程：`VmHWM` 是进程级单调峰值，同进程内先跑的
 * 10 MB 会垫高 50 MB 的读数（`design.md` §3.2）。
 */
@Test
public class PerfTen_test {
    @TestCase
    public func gateTenMegabytes(): Unit {
        if (!perfGateEnabled()) {
            println("gate: disabled (set F_XML_PERF=1)")
            return
        }
        println(environmentLine())
        if (!gateEnvironmentOk()) {
            println("gate: invalid (env/load)")
            return
        }
        let runs: Int64 = 5
        let times = Array<Float64>(runs, repeat: 0.0)
        var events: Int64 = 0
        var i: Int64 = 0
        while (i < runs) {
            let result = runSyntheticPass(10 * 1024 * 1024, 8192)
            times[i] = result[0]
            events = result[1]
            i++
        }
        var minMs = times[0]
        var maxMs = times[0]
        for (value in times) {
            if (value < minMs) {
                minMs = value
            }
            if (value > maxMs) {
                maxMs = value
            }
        }
        let ratio = if (minMs <= 0.0) {
            maxMs
        } else {
            maxMs / minMs
        }
        let mem = readProcMem()
        let hwm = match (mem) {
            case Some(value) => value.hwmKb
            case None => -1
        }
        println("gate: ten_mb events=${events} ms=${times} min=${minMs} max=${maxMs} ratio=${ratio} hwm_kb=${hwm}")
        if (ratio > 1.4) {
            println("gate: noisy (max/min > 1.4) — 本轮不得用于判定")
        }
        assertTrue(minMs < 1000.0, "Gate T 未达标：10 MB min=${minMs} ms ≥ 1000 ms")
    }
}
