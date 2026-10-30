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
 * Gate M：50 MB 事件解析的进程峰值 `VmHWM < 262 144 kB`（默认运行时、空载、独立进程）。
 *
 * 进程内**只**解析 50 MB。跑之前先解析一份极小文档记录「进程地板」，用来区分
 * 运行时底座与本题分配；地板必须在 50 MB 之前采（`VmHWM` 单调）。
 */
@Test
public class PerfFifty_test {
    @TestCase
    public func gateFiftyMegabytes(): Unit {
        if (!perfGateEnabled()) {
            println("gate: disabled (set F_XML_PERF=1)")
            return
        }
        println(environmentLine())
        if (!gateEnvironmentOk()) {
            println("gate: invalid (env/load)")
            return
        }
        // 进程地板：极小文档（约 1 KB）之后的 VmHWM。
        runSyntheticPass(1024, 8192)
        let floor = match (readProcMem()) {
            case Some(value) => value.hwmKb
            case None => -1
        }
        let result = runSyntheticPass(50 * 1024 * 1024, 8192)
        let mem = readProcMem()
        let hwm = match (mem) {
            case Some(value) => value.hwmKb
            case None => -1
        }
        let delta = if (hwm < 0 || floor < 0) {
            -1
        } else {
            hwm - floor
        }
        println("gate: fifty_mb ms=${result[0]} events=${result[1]} hwm_kb=${hwm} floor_kb=${floor} delta_kb=${delta}")
        if (hwm > 0) {
            assertTrue(hwm < 262144, "Gate M 未达标：VmHWM(50 MB) = ${hwm} kB ≥ 262144 kB")
        } else {
            println("gate: rss unavailable")
        }
    }
}
