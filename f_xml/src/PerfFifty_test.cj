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
        // 改前同轮值（a077dc6，2026-10-30，同一份零分配基准）。
        println("gate: fifty_mb old_hwm_kb=295136 old_ms=5322.9 baseline=a077dc6")
        if (hwm <= 0) {
            println("gate: invalid (rss unavailable) — 未测量即通过是不可接受的，请在有 /proc 的 Linux 上重测")
            return
        }
        assertTrue(hwm < 262144, "Gate M 未达标：VmHWM(50 MB) = ${hwm} kB ≥ 262144 kB")
    }
}
