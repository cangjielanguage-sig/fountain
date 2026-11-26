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
import fountain::f_data.JsonObject

@Test
public class ProbeAgent_test {
    /** 只覆写 kind / data 的实现必须拿到 host 的默认值空字符串。 */
    @TestCase
    public func hostDefaultsToEmptyString(): Unit {
        let agent: ProbeAgent = HostlessAgent()
        @Assert(agent.kind, "k8s")
        @Assert(agent.host, "")
        @Assert(agent.data.isEmpty())
    }
}

class HostlessAgent <: ProbeAgent {
    public prop kind: String {
        get() {
            "k8s"
        }
    }

    public prop data: JsonObject {
        get() {
            JsonObject()
        }
    }
}
