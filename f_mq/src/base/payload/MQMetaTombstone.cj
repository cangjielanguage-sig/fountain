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

/**
 * 删除墓碑。
 *
 * 删除只删本地文件时，离线节点重启后会把自己那份旧元数据当成有效数据（「静默复活」）。
 * 墓碑带 `revision/origin` 参与同一套比较规则，并随快照与广播传播；TTL 之后由反熵兜底。
 */
@DataAssist[props fields]
public class MQMetaTombstone {
    public static const KIND_TOPIC: String = "topic"
    public static const KIND_GROUP: String = "group"

    /** `topic` / `group` */
    private var kind: String = ''
    private var topic: String = ''
    /** `kind == "group"` 时使用；空串 = 默认组 */
    private var subscribeGroup: String = ''
    /** 删除发生的版本 */
    private var revision: Int64 = 0
    /** 版本的产生节点 */
    private var origin: Int64 = 0
    /** 删除时刻（毫秒），用于 TTL 回收 */
    private var deletedAtMs: Int64 = 0

    public init() {}

    public init(kind: String, topic: String, subscribeGroup: String, revision: Int64, origin: Int64,
        deletedAtMs: Int64) {
        this.kind = kind
        this.topic = topic
        this.subscribeGroup = subscribeGroup
        this.revision = revision
        this.origin = origin
        this.deletedAtMs = deletedAtMs
    }

    public func isTopic(): Bool {
        kind == KIND_TOPIC
    }

    /** 唯一键：主题墓碑按 topic，组墓碑按 topic + group。 */
    public func key(): String {
        if (isTopic()) {
            "${KIND_TOPIC}\u{0}${topic}"
        } else {
            "${KIND_GROUP}\u{0}${topic}\u{0}${subscribeGroup}"
        }
    }
}
