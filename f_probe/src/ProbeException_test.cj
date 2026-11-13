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
package fountain::f_probe

import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_base.BaseException

@Test
public class ProbeException_test {
    /** 四类错误码可由调用方直接判别，消息里带有出错对象名。 */
    @TestCase
    public func errorCodesAndMessages(): Unit {
        let duplicate = ProbeException(ProbeErrorCode.DUPLICATE, "duplicate probe kind: cpu")
        let config = ProbeException(ProbeErrorCode.CONFIG, "invalid config: probe_port")
        let load = ProbeException(ProbeErrorCode.LOAD, "load failed: /opt/custom/libk8s.so")
        let collect = ProbeException(ProbeErrorCode.COLLECT, "collect failed: memory")

        @Assert(duplicate.code, ProbeErrorCode.DUPLICATE)
        @Assert(config.code, ProbeErrorCode.CONFIG)
        @Assert(load.code, ProbeErrorCode.LOAD)
        @Assert(collect.code, ProbeErrorCode.COLLECT)

        @Assert(duplicate.message.contains("cpu"))
        @Assert(config.message.contains("probe_port"))
        @Assert(load.message.contains("libk8s.so"))
        @Assert(collect.message.contains("memory"))
    }

    /** ProbeException 必须保持 BaseException 的可捕获语义。 */
    @TestCase
    public func isBaseException(): Unit {
        var caught = false
        try {
            throw ProbeException(ProbeErrorCode.COLLECT, "collect failed: disk")
        } catch (e: BaseException) {
            caught = true
        }
        @Assert(caught)
    }
}
