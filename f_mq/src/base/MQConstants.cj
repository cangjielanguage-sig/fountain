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
package fountain::f_mq.base

/**
 * MQ 协议错误码。
 *
 * 数值是对外契约，不得漂移；每个码都有一句固定的可读文案（日志与异常共用）。
 */
public class MQErrorCode {
    public static const OK: Int64 = 0
    public static const TOPIC_NOT_EXIST: Int64 = 1
    public static const TOPIC_ALREADY_EXIST: Int64 = 2
    public static const GROUP_NOT_EXIST: Int64 = 3
    public static const GROUP_ALREADY_EXIST: Int64 = 4
    public static const INVALID_TOPIC: Int64 = 5
    public static const INVALID_GROUP: Int64 = 6
    public static const SUBSCRIBE_NOT_EXIST: Int64 = 7
    public static const NOT_OWNER: Int64 = 8
    public static const ACK_UNKNOWN: Int64 = 9
    public static const FILTER_UNSUPPORTED_BODY: Int64 = 10
    public static const INTERNAL: Int64 = 11

    /** 未知码返回带数值的兜底文案，避免日志里出现空串。 */
    public static func messageOf(code: Int64): String {
        if (code == OK) {
            "success"
        } else if (code == TOPIC_NOT_EXIST) {
            "topic does not exist"
        } else if (code == TOPIC_ALREADY_EXIST) {
            "topic already exists"
        } else if (code == GROUP_NOT_EXIST) {
            "subscribe group does not exist"
        } else if (code == GROUP_ALREADY_EXIST) {
            "subscribe group already exists"
        } else if (code == INVALID_TOPIC) {
            "invalid topic"
        } else if (code == INVALID_GROUP) {
            "invalid subscribe group"
        } else if (code == SUBSCRIBE_NOT_EXIST) {
            "subscription does not exist"
        } else if (code == NOT_OWNER) {
            "this node does not own any queue of the topic"
        } else if (code == ACK_UNKNOWN) {
            "ack position does not belong to this subscription"
        } else if (code == FILTER_UNSUPPORTED_BODY) {
            "filter cannot be evaluated on this body"
        } else if (code == INTERNAL) {
            "internal server error"
        } else {
            "unknown error code ${code}"
        }
    }
}

/** 客户端侧配置项名。 */
public class MQConfigKey {
    public static const CLIENT_HOSTS: String = "mqClient_hosts"
}

/** 内部消息（`MQInternalMessage`）的 kind 常量。 */
public class MQInternalKind {
    public static const META_SYNC: String = "metaSync"
    public static const BACKUP: String = "backup"
    public static const STATS: String = "stats"
}

/** 载荷分派结果（`MQProtocol.kindOf`）。 */
public enum MQPayloadKind <: Equatable<MQPayloadKind> & ToString {
    | Record
    | TopicMeta
    | GroupMeta
    | Internal
    | Empty
    | Unknown

    public operator func ==(other: MQPayloadKind): Bool {
        match ((this, other)) {
            case (Record, Record) => true
            case (TopicMeta, TopicMeta) => true
            case (GroupMeta, GroupMeta) => true
            case (Internal, Internal) => true
            case (Empty, Empty) => true
            case (Unknown, Unknown) => true
            case _ => false
        }
    }

    public func toString(): String {
        match (this) {
            case Record => "Record"
            case TopicMeta => "TopicMeta"
            case GroupMeta => "GroupMeta"
            case Internal => "Internal"
            case Empty => "Empty"
            case Unknown => "Unknown"
        }
    }
}
