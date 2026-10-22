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
package fountain::f_mq.base.model

import fountain::f_data.*
import fountain::f_data.macros.*

/** 订阅组元数据：订阅组挂在主题下，空串表示默认组。 */
@DataAssist[props fields]
public class MQSubscribeGroupMeta {
    /** 所属主题 */
    private var topic: String = ''
    /** 订阅组名；空串 = 默认组 */
    private var subscribeGroup: String = ''
    /** 元数据版本（Lamport 计数），0 表示旧数据 */
    private var revision: Int64 = 0
    /** 版本的产生节点；同 revision 时用于打破平局 */
    private var origin: Int64 = 0

    public init() {}

    public init(topic: String, subscribeGroup: String, revision!: Int64 = 0, origin!: Int64 = 0) {
        this.topic = topic
        this.subscribeGroup = subscribeGroup
        this.revision = revision
        this.origin = origin
    }
}
