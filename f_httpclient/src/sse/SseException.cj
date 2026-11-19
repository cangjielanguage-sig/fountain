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

/** SSE 读取失败的基类 */
public open class SseException <: Exception {
    public init(message: String) {
        super(message)
    }
}

/** 空闲超时：超过设定时长没有任何字节到达（区别于连接建立超时） */
public class SseTimeoutException <: SseException {
    public init(idle: Duration) {
        super('no data received in ${idle}')
    }
}

/** 单行超过上限：防止异常/恶意响应把内存吃光 */
public class SseLineTooLongException <: SseException {
    public init(limit: Int64) {
        super('sse line exceeds ${limit} bytes')
    }
}
