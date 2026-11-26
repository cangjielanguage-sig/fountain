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
package fountain::f_httpclient.sse

/**
 * 一条 SSE 事件。只承载语法层字段，不含任何业务含义
 * （不解释 `[DONE]`、不解析 JSON、不自动重连）。
 *
 * event: event 字段，缺省为空串；data: 多行以 '\n' 拼接；retry: 缺省 -1。
 */
public struct SseEvent {
    public SseEvent(
        public let event: String,
        public let data: String,
        public let id: String,
        public let retry: Int64
    ){}
}
