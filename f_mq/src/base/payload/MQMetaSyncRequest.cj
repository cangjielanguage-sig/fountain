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

/** 元数据同步请求：携带请求方节点下标（快照回给谁不影响内容，仅用于日志与排障）。 */
@DataAssist[props fields]
public class MQMetaSyncRequest {
    private var requesterIndex: Int64 = -1

    public init() {}

    public init(requesterIndex: Int64) {
        this.requesterIndex = requesterIndex
    }
}
