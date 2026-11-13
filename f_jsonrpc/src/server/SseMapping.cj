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
package fountain::f_jsonrpc.server

import fountain::f_mvc.*

/**
 * SSE 端点：`method` 固定 `GET`、`produces` 固定 `text/event-stream`。
 *
 * 与 `@JsonRpcMapping` 并列而不复用：一个是 POST + JSON 一问一答，一个是 GET + 长连接流，
 * 放在同一个注解里会让「这条路由到底是什么语义」变模糊。
 */
@Annotation[target: [MemberFunction]]
public class SseMapping <: RequestMapping {
    public const init(
        path!: String,
        params!: String = '',
        headers!: String = '',
        ignoreAuth!: Bool = false,
        ignorePrivilege!: Bool = false
    ) {
        super(
            path: path,
            method: RequestMethod.GET,
            produces: 'text/event-stream',
            consumes: '',
            params: params,
            headers: headers,
            ignoreAuth: ignoreAuth,
            ignorePrivilege: ignorePrivilege
        )
    }
}
