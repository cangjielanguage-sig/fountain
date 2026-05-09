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
package fountain::fmq.common

/**
 * MQ 协议错误码
 */
public enum MqErrorCode <: Equatable<MqErrorCode> & ToString {
    | SUCCESS
    | TOPIC_NOT_FOUND
    | TOPIC_EXISTS
    | GROUP_NOT_FOUND
    | GROUP_EXISTS
    | MESSAGE_TOO_LARGE
    | TOO_MANY_LABELS
    | BROKER_NOT_AVAILABLE
    | PERMISSION_DENIED
    | ACK_TIMEOUT
    | INVALID_TOPIC_FORMAT

    public operator func ==(other: MqErrorCode): Bool {
        match ((this, other)) {
            case (SUCCESS, SUCCESS) => true
            case (TOPIC_NOT_FOUND, TOPIC_NOT_FOUND) => true
            case (TOPIC_EXISTS, TOPIC_EXISTS) => true
            case (GROUP_NOT_FOUND, GROUP_NOT_FOUND) => true
            case (GROUP_EXISTS, GROUP_EXISTS) => true
            case (MESSAGE_TOO_LARGE, MESSAGE_TOO_LARGE) => true
            case (TOO_MANY_LABELS, TOO_MANY_LABELS) => true
            case (BROKER_NOT_AVAILABLE, BROKER_NOT_AVAILABLE) => true
            case (PERMISSION_DENIED, PERMISSION_DENIED) => true
            case (ACK_TIMEOUT, ACK_TIMEOUT) => true
            case (INVALID_TOPIC_FORMAT, INVALID_TOPIC_FORMAT) => true
            case _ => false
        }
    }

    public func toString(): String {
        match (this) {
            case SUCCESS => "SUCCESS"
            case TOPIC_NOT_FOUND => "TOPIC_NOT_FOUND"
            case TOPIC_EXISTS => "TOPIC_EXISTS"
            case GROUP_NOT_FOUND => "GROUP_NOT_FOUND"
            case GROUP_EXISTS => "GROUP_EXISTS"
            case MESSAGE_TOO_LARGE => "MESSAGE_TOO_LARGE"
            case TOO_MANY_LABELS => "TOO_MANY_LABELS"
            case BROKER_NOT_AVAILABLE => "BROKER_NOT_AVAILABLE"
            case PERMISSION_DENIED => "PERMISSION_DENIED"
            case ACK_TIMEOUT => "ACK_TIMEOUT"
            case INVALID_TOPIC_FORMAT => "INVALID_TOPIC_FORMAT"
        }
    }
}

/**
 * MQ 异常类
 */
public class MqException <: BaseException {
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
