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

/** `DEREGISTER` 载荷。`kind` 取 `topic` / `group`。 */
@DataAssist[props fields]
public class MQDeregisterPayload {
    public static const TOPIC: String = "topic"
    public static const GROUP: String = "group"

    private var kind: String = ''
    private var topic: String = ''
    /** `kind == "group"` 时使用；空串 = 默认组 */
    private var subscribeGroup: String = ''

    public init() {}

    public init(kind: String, topic: String, subscribeGroup!: String = '') {
        this.kind = kind
        this.topic = topic
        this.subscribeGroup = subscribeGroup
    }

    public func isTopic(): Bool {
        kind == TOPIC
    }
}
