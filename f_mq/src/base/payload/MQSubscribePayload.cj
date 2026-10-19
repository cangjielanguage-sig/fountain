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
package fountain::f_mq.base.payload

import fountain::f_data.*
import fountain::f_data.macros.*

/** `SUBSCRIBE` 载荷。 */
@DataAssist[props fields]
public class MQSubscribePayload {
    /** 客户端生成的 UUID */
    private var subscribedId: String = ''
    private var topic: String = ''
    /** 空串 = 默认组 */
    private var subscribeGroup: String = ''
    private var tags: Array<String> = []
    /** `f_data.path` 表达式；空串 = 不关心 BODY */
    private var filter: String = ''
    private var autoAck: Bool = false

    public init() {}

    public init(subscribedId: String, topic: String, subscribeGroup: String, tags: Array<String>, filter: String,
        autoAck: Bool) {
        this.subscribedId = subscribedId
        this.topic = topic
        this.subscribeGroup = subscribeGroup
        this.tags = tags
        this.filter = filter
        this.autoAck = autoAck
    }
}
