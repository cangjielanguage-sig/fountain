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
package fountain::f_mq.exception

import fountain::f_base.BaseException

/**
 * MQ 异常基类。
 *
 * 客户端与服务端共用；`message` 直接面向使用者，应包含足够的排障信息。
 */
public open class MQException <: BaseException {
    public init() {}

    public init(message: String) {
        super(message)
    }

    public init(caused: Exception) {
        super(caused)
    }

    public init(message: String, caused: Exception) {
        super(message, caused)
    }
}

/** 连接、超时、客户端已关闭等「链路层」失败。 */
public open class MQConnectionException <: MQException {
    public init() {}

    public init(message: String) {
        super(message)
    }

    public init(caused: Exception) {
        super(caused)
    }

    public init(message: String, caused: Exception) {
        super(message, caused)
    }
}

/**
 * 服务端以 `MQResult{code != 0}` 明确拒绝的请求。
 *
 * `code` 即协议错误码（见 `MQErrorCode`），调用方可据此做分支处理。
 */
public open class MQServiceException <: MQException {
    public let code: Int64

    public init(code: Int64, message: String) {
        super(message)
        this.code = code
    }

    public init(code: Int64, message: String, caused: Exception) {
        super(message, caused)
        this.code = code
    }
}
