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

/** 通用结果 / 错误载荷。 */
@DataAssist[props fields]
public class MQResult {
    /** 0 = 成功；非 0 见 `MQErrorCode` */
    private var code: Int64 = 0
    private var message: String = ''

    public init() {}

    public init(code: Int64, message: String) {
        this.code = code
        this.message = message
    }

    public func isOk(): Bool {
        code == 0
    }
}
