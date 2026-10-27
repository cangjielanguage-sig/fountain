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
package fountain::f_llm.llm

import std.collection.HashMap
import stdx.net.tls.common.*

// HttpClient / TlsClientConfig 由 f_httpclient 的 public import 带出（stdx.net.http / stdx.net.tls）
import fountain::f_httpclient.*

/** HTTP 层的原始结果；门面只关心状态码与响应体 */
public class LLMHttpResponse {
    public LLMHttpResponse(public let status: Int64, public let body: String){}
}

/**
 * 门面依赖的传输抽象。
 *
 * 生产用 `DefaultHttpTransport`（f_httpclient）；单元测试注入假实现，
 * 这样「按权重选平台、失败转移、错误分类」都能脱离网络验证。
 */
public interface LLMTransport {
    func post(url: String, headers: HashMap<String, String>, body: String): LLMHttpResponse
}

public class DefaultHttpTransport <: LLMTransport {
    public func post(url: String, headers: HashMap<String, String>, body: String): LLMHttpResponse {
        let client = HttpClient(url)
        for((key, value) in headers){
            client.header(key, value)
        }
        var tls = TlsClientConfig()
        tls.verifyMode = CertificateVerifyMode.TrustAll
        client.tlsConfig(tls)
        resource(client){http =>
            let response = http.post(body)
            LLMHttpResponse(Int64(response.status), response.readEntire())
        }
    }
}
