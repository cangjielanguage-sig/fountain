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
package fountain::fprobe.collect.health

import std.unittest.*
import std.unittest.testmacro.*

private let HEALTH_JSON = '''
{"allocatedHeapSize":1024,"heapPhysicalMemory":2048,"blockingThreadCount":1,"gcCount":3,
 "gcFreedSize":4096,"gcTime":10,"maxHeapSize":8192,"nativeThreadCount":2,"processorCount":8,
 "threadCount":16,"usedHeapSize":512}
'''

class FakeHttpProbe <: HttpProbe {
    private let result: HttpProbeResult

    init(result: HttpProbeResult) {
        this.result = result
    }

    public func get(url: String, timeoutMs: Int64): HttpProbeResult {
        result
    }
}

@Test
public class MvcHealthProbe_test {
    @TestCase
    public func mapsHealthyResponseFields(): Unit {
        let http = FakeHttpProbe(HttpProbeResult(200, HEALTH_JSON, 12.5, false, ""))
        let data = MvcHealthProbe(http, "http://127.0.0.1:8080/health").data
        @Assert(data.get("statusCode").getOrThrow().asInt().toInt64(), 200)
        @Assert(data.get("latencyMs").getOrThrow().asDecimal().toFloat64(), 12.5)
        @Assert(data.get("allocatedHeapSize").getOrThrow().asInt().toInt64(), 1024)
        @Assert(data.get("heapPhysicalMemory").getOrThrow().asInt().toInt64(), 2048)
        @Assert(data.get("blockingThreadCount").getOrThrow().asInt().toInt64(), 1)
        @Assert(data.get("gcCount").getOrThrow().asInt().toInt64(), 3)
        @Assert(data.get("gcFreedSize").getOrThrow().asInt().toInt64(), 4096)
        @Assert(data.get("gcTime").getOrThrow().asInt().toInt64(), 10)
        @Assert(data.get("maxHeapSize").getOrThrow().asInt().toInt64(), 8192)
        @Assert(data.get("nativeThreadCount").getOrThrow().asInt().toInt64(), 2)
        @Assert(data.get("processorCount").getOrThrow().asInt().toInt64(), 8)
        @Assert(data.get("threadCount").getOrThrow().asInt().toInt64(), 16)
        @Assert(data.get("usedHeapSize").getOrThrow().asInt().toInt64(), 512)
        @Assert(data.get("error").getOrThrow().asString().value.isEmpty())
    }

    @TestCase
    public func non200KeepsStatusCodeAndError(): Unit {
        let http = FakeHttpProbe(HttpProbeResult(500, "boom", 7.5, false, ""))
        let data = MvcHealthProbe(http, "http://127.0.0.1:8080/health").data
        @Assert(data.get("statusCode").getOrThrow().asInt().toInt64(), 500)
        @Assert(data.get("latencyMs").getOrThrow().asDecimal().toFloat64(), 7.5)
        @Assert(data.get("error").getOrThrow().asString().value.contains("500"))
    }

    @TestCase
    public func timeoutIsReportedAsError(): Unit {
        let http = FakeHttpProbe(HttpProbeResult(0, "", 2000.0, true, "HTTP 请求超时"))
        let data = MvcHealthProbe(http, "http://127.0.0.1:8080/health").data
        @Assert(data.get("statusCode").getOrThrow().asInt().toInt64(), 0)
        @Assert(data.get("latencyMs").getOrThrow().asDecimal().toFloat64(), 2000.0)
        @Assert(data.get("error").getOrThrow().asString().value.contains("超时"))
    }

    @TestCase
    public func invalidJsonIsReportedAsError(): Unit {
        let http = FakeHttpProbe(HttpProbeResult(200, "not-json", 1.0, false, ""))
        let data = MvcHealthProbe(http, "http://127.0.0.1:8080/health").data
        @Assert(data.get("statusCode").getOrThrow().asInt().toInt64(), 200)
        @Assert(data.get("error").getOrThrow().asString().value.contains("JSON"))
    }

    @TestCase
    public func emptyUrlReportsConfigurationError(): Unit {
        let data = MvcHealthProbe(FakeHttpProbe(HttpProbeResult(200, HEALTH_JSON, 1.0, false, "")), "").data
        @Assert(data.get("error").getOrThrow().asString().value.contains("probe_mvcHealthUrl"))
    }
}
