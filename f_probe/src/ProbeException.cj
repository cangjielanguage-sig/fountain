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
package fountain::f_probe

import fountain::f_base.BaseException

/**
 * fprobe 的稳定错误码。
 *
 * 调用方按错误码区分失败类别，不解析异常文本。
 */
public enum ProbeErrorCode <: Equatable<ProbeErrorCode> {
    | DUPLICATE
    | CONFIG
    | LOAD
    | COLLECT

    public operator func ==(other: ProbeErrorCode): Bool {
        match ((this, other)) {
            case (DUPLICATE, DUPLICATE) | (CONFIG, CONFIG) | (LOAD, LOAD) | (COLLECT, COLLECT) => true
            case _ => false
        }
    }
}

/**
 * fprobe 统一异常。
 *
 * 消息必须携带出错对象（kind、渠道名或库路径），便于定位。
 */
public class ProbeException <: BaseException {
    /** 失败类别。 */
    public let code: ProbeErrorCode

    public init(code: ProbeErrorCode, message: String) {
        super(message)
        this.code = code
    }

    public init(code: ProbeErrorCode, message: String, caused: Exception) {
        super(message, caused)
        this.code = code
    }
}
