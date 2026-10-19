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
package fountain::f_base

import std.fs.{File, OpenMode}
import std.io.StringReader

/**
 * x86_64 指令集能力探测（M1 只关心 SSE4.1，用于 `roundsd`）。
 *
 * Linux 下读 `/proc/cpuinfo` 的 `sse4_1` 标志；非 x86_64 平台恒 false。
 * 读取失败一律按「不支持」处理，调用方退回解释器（T7/T9 静默降级）。
 */
public class CpuFeatures {
    @When[arch == 'x86_64' && os == 'Linux']
    public static prop hasSse41: Bool {
        get() {
            CpuFeatures.detectSse41()
        }
    }

    @When[arch != 'x86_64' || os != 'Linux']
    public static prop hasSse41: Bool {
        get() {
            false
        }
    }

    @When[arch == 'x86_64' && os == 'Linux']
    private static func detectSse41(): Bool {
        try {
            let f = File('/proc/cpuinfo', OpenMode.Read)
            try {
                StringReader(f).readToEnd().contains('sse4_1')
            } finally {
                f.close()
            }
        } catch (e: Exception) {
            false
        }
    }
}
