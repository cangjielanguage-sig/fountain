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
package fountain::jsonrpcserver

import fountain::f_data.*
import fountain::f_data.macros.DataAssist
import fountain::f_jsonrpc.*
import fountain::f_jsonrpc.macros.*

@DataAssist[fields props]
public class DemoEcho {
    public var text: String = ''

    public init() {}

    public init(text: String) {
        this.text = text
    }
}

/**
 * 演示用 JSON-RPC 服务：类上的 namespace 是 `knowledge`，每个 public 实例方法注册成 `knowledge.<方法名>`。
 */
@JsonRpc[namespace: knowledge]
public class SearchRPC {
    public init() {}

    @JsonRpcMeta['知识库检索', '5s']
    public func search(param: String): String {
        'found:${param}'
    }

    @JsonRpcMeta['加法', '1s']
    public func add(a: Int64, b: Int64): Int64 {
        a + b
    }

    @JsonRpcMeta['回显对象', '2s']
    public func echo(req: DemoEcho): DemoEcho {
        DemoEcho(req.text + '!')
    }

    @JsonRpcMeta['无返回值', '']
    public func touch(): Unit {}
}
