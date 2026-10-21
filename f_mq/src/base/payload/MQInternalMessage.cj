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
 * 内部消息信封：`kind` 区分元数据同步与备份，`payload` 是子载荷的 codec 字节。
 *
 * 不新增协议命令的代价是「一条 REGISTER 可能是注册，也可能是同步」；收益是不动命令空间。
 */
@DataAssist[props fields]
public class MQInternalMessage {
    private var kind: String = ''
    private var payload: MQBlob = MQBlob()

    public init() {}

    public init(kind: String, payload: Array<Byte>) {
        this.kind = kind
        this.payload = MQBlob(payload)
    }

    public init(kind: String, payload: MQBlob) {
        this.kind = kind
        this.payload = payload
    }
}
