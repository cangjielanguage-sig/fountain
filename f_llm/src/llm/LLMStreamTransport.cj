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

// HttpClient / SseReader 由 f_httpclient 的 public import 带出
import fountain::f_httpclient.*

import fountain::f_llm.config.*

/**
 * 流式传输抽象：把 SSE 的 `data` 原文逐条回调，返回 HTTP 状态码。
 *
 * 与 `LLMTransport` 分开的理由：非流式只需要状态码 + 完整响应体，
 * 流式要保证「边到边处理」，两者的失败语义与测试桩完全不同。
 */
public interface LLMStreamTransport {
    func stream(url: String, headers: HashMap<String, String>, body: String, onData: (String) -> Unit): Int64
}

public class DefaultStreamTransport <: LLMStreamTransport {
    public func stream(
        url: String,
        headers: HashMap<String, String>,
        body: String,
        onData: (String) -> Unit
    ): Int64 {
        let client = HttpClient(url)
        for((key, value) in headers){
            client.header(key, value)
        }
        client.header('Accept-Encoding', 'identity')
        var tls = TlsClientConfig()
        tls.verifyMode = CertificateVerifyMode.TrustAll
        client.tlsConfig(tls)
        resource(client){http =>
            let response = http.post(body)
            let status = Int64(response.status)
            if(status < 400){
                resource(response.sseReader(
                    maxLineBytes: LLMConfig.getStreamMaxLineBytes(),
                    idleTimeout: LLMConfig.getStreamIdleTimeout()
                )){reader =>
                    while(let Some(event) <- reader.next()){
                        onData(event.data)
                    }
                }
            }
            status
        }
    }
}
