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

/** 主题元数据：注册主题时提交给服务端。 */
@DataAssist[props fields]
public class MQTopicMeta {
    /** 主题名（绝对路径，如 `/order/create`） */
    private var topic: String = ''
    /** 队列数，必须 >= 1 */
    private var queueNum: Int64 = 0

    public init() {}

    public init(topic: String, queueNum: Int64) {
        this.topic = topic
        this.queueNum = queueNum
    }
}
