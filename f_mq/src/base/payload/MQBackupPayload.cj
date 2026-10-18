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

/** 备份推送载荷：一批记录及其状态。 */
@DataAssist[props fields]
public class MQBackupPayload {
    /** 主节点下标 */
    private var ownerIndex: Int64 = 0
    private var topic: String = ''
    private var queueIndex: Int64 = 0
    private var records: Array<Array<Byte>> = []
    private var states: Array<MQBackupState> = []

    public init() {}

    public init(ownerIndex: Int64, topic: String, queueIndex: Int64, records: Array<Array<Byte>>,
        states: Array<MQBackupState>) {
        this.ownerIndex = ownerIndex
        this.topic = topic
        this.queueIndex = queueIndex
        this.records = records
        this.states = states
    }
}
