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
package fountain::fprobe.channel

import fountain::f_data.*
import fountain::f_data.macros.*

/** 渠道收到的一条可回复消息；`receive()` 以该 DTO 的 JSON 文本返回。 */
@DataAssist[props fields]
public class ChannelMessage {
    private var id: String = ""
    private var from: String = ""
    private var subject: String = ""
    private var body: String = ""

    public init() {}

    public init(id: String, from: String, subject: String, body: String) {
        this.id = id
        this.from = from
        this.subject = subject
        this.body = body
    }
}
