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

import std.time.MonoTime
import fountain::f_httpclient.*

/**
 * 一次 HTTP GET 的结果。
 *
 * `timedOut` 与普通网络错误分开标记：健康探针需要区分「慢」与「错」，
 * 但两者都不向调用方抛异常，避免单个目标影响整次采集。
 */
public struct HttpProbeResult {
    public let statusCode: Int64
    public let body: String
    public let latencyMs: Float64
    public let timedOut: Bool
    public let error: String

    public init(statusCode: Int64, body: String, latencyMs: Float64, timedOut: Bool, error: String) {
        this.statusCode = statusCode
        this.body = body
        this.latencyMs = latencyMs
        this.timedOut = timedOut
        this.error = error
    }
}

/** HTTP 探测抽象；用例注入假实现，不连外网。 */
public interface HttpProbe {
    func get(url: String, timeoutMs: Int64): HttpProbeResult
}

/** 基于 `f_httpclient` 的生产实现。 */
public class FHttpClientProbe <: HttpProbe {
    public init() {}

    public func get(url: String, timeoutMs: Int64): HttpProbeResult {
        let start = MonoTime.now()
        let client = HttpClient(url)
        try {
            client.readTimeout(Duration.millisecond * timeoutMs)
            client.header("Accept", "application/json")
            let response = client.get()
            let body = response.readEntire()
            HttpProbeResult(Int64(response.status), body, elapsedMs(start), false, "")
        } catch (_: TimeoutException) {
            HttpProbeResult(0, "", elapsedMs(start), true, 'HTTP 请求超时（${timeoutMs}ms）')
        } catch (e: Exception) {
            HttpProbeResult(0, "", elapsedMs(start), false, 'HTTP 请求失败: ${e.message}')
        } finally {
            client.close()
        }
    }
}

private func elapsedMs(start: MonoTime): Float64 {
    Float64((MonoTime.now() - start).toNanoseconds()) / 1000000.0
}
