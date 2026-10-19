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
package fountain::fmq.config

import std.convert.*
import std.fs.Path
import fountain::f_config.Config
import fountain::f_mq.base.MQConfigKey
import fountain::f_process.getAbsoluteCommandDir

/** 配置缺失 / 非法。启动期打印后以退出码 2 结束。 */
public class MQConfigException <: Exception {
    public init(message: String) {
        super(message)
    }
}

/**
 * `fmq server` 配置项。
 *
 * `protected`：模块内兄弟包（server/meta/queue/cluster）都要读，`internal` 到不了兄弟包。
 * 静态属性在首次使用时读配置，避免包初始化期 `Config` 未就绪。
 */
protected struct MQConfig {
    private static const PREFIX = "mqServer"

    static let PORT = "${PREFIX}_port"
    static let ACK_TIMEOUT = "${PREFIX}_ackTimeout"
    static let DEAD_MSG_THRESHOLD = "${PREFIX}_deadMsgThreshold"
    static let DEAD_MSG_TTL = "${PREFIX}_deadMsgTTL"
    static let SEGMENTED_LOG_DIR = "${PREFIX}_segmentedLogDir"
    static let DEAD_MSG_DIR = "${PREFIX}_deadMsgDir"
    static let SEGMENTED_LOG_MAX_SIZE = "${PREFIX}_segmentedLogMaxSize"
    static let SEGMENTED_LOG_TTL = "${PREFIX}_segmentedLogTTL"
    static let BACKUP = "${PREFIX}_backup"

    static let DEFAULT_PORT: UInt16 = 2350
    static let DEFAULT_ACK_TIMEOUT = Duration.second * 10
    static let DEFAULT_DEAD_MSG_THRESHOLD: Int64 = 3
    static let DEFAULT_DEAD_MSG_TTL = Duration.hour * 72
    static let DEFAULT_SEGMENTED_LOG_DIR = "/var/log/fmq/segmentedLogs"
    static let DEFAULT_DEAD_MSG_DIR = "/var/log/fmq/deadMsgs"
    static let DEFAULT_SEGMENTED_LOG_MAX_SIZE: Int64 = 1024 * 1024 * 1024
    static let DEFAULT_SEGMENTED_LOG_TTL = Duration.hour * 72
    static let DEFAULT_BACKUP: Int64 = 0

    private init() {}

    protected static prop port: UInt16 {
        get() {
            Config.getValue<UInt16>(PORT) ?? DEFAULT_PORT
        }
    }

    protected static prop ackTimeout: Duration {
        get() {
            Config.getDuration(ACK_TIMEOUT) ?? DEFAULT_ACK_TIMEOUT
        }
    }

    protected static prop deadMsgThreshold: Int64 {
        get() {
            Config.getValue<Int64>(DEAD_MSG_THRESHOLD) ?? DEFAULT_DEAD_MSG_THRESHOLD
        }
    }

    protected static prop deadMsgTTL: Duration {
        get() {
            Config.getDuration(DEAD_MSG_TTL) ?? DEFAULT_DEAD_MSG_TTL
        }
    }

    protected static prop segmentedLogDir: String {
        get() {
            Config.getString(SEGMENTED_LOG_DIR) ?? DEFAULT_SEGMENTED_LOG_DIR
        }
    }

    protected static prop deadMsgDir: String {
        get() {
            Config.getString(DEAD_MSG_DIR) ?? DEFAULT_DEAD_MSG_DIR
        }
    }

    protected static prop segmentedLogMaxSize: Int64 {
        get() {
            var value = DEFAULT_SEGMENTED_LOG_MAX_SIZE
            if (let Some(text) <- Config.getString(SEGMENTED_LOG_MAX_SIZE)) {
                if (let Some(parsed) <- parseByteSize(text)) {
                    value = parsed
                }
            }
            value
        }
    }

    protected static prop segmentedLogTTL: Duration {
        get() {
            Config.getDuration(SEGMENTED_LOG_TTL) ?? DEFAULT_SEGMENTED_LOG_TTL
        }
    }

    protected static prop backup: Int64 {
        get() {
            Config.getValue<Int64>(BACKUP) ?? DEFAULT_BACKUP
        }
    }

    /**
     * 解析 `1G` / `2M` / `2048K` / `10b` 这类字节量写法。
     *
     * 不用 `f_util.computeBytes`：该实现对单位分组的取值在本 SDK 上不稳定（大写单位会落到
     * 「not supported byte unit」），这里用显式字节扫描，行为可测且无正则依赖。
     */
    private static func parseByteSize(text: String): ?Int64 {
        let trimmed = text.trimAscii()
        if (trimmed.isEmpty()) {
            return None<Int64>
        }
        let raw = trimmed.toArray()
        var end = raw.size
        var unit = b'b'
        var last = raw[end - 1]
        func isAlpha(b: Byte): Bool {
            (b >= b'a' && b <= b'z') || (b >= b'A' && b <= b'Z')
        }
        if (last == b'b' || last == b'B') {
            end--
            if (end == 0) {
                return None<Int64>
            }
            last = raw[end - 1]
            if (isAlpha(last)) {
                end--
                unit = last
            }
        } else if (isAlpha(last)) {
            end--
            unit = last
        }
        if (end == 0) {
            return None<Int64>
        }
        match (Int64.tryParse(String.fromUtf8(raw[0..end]))) {
            case None => None<Int64>
            case Some(n) =>
                let shift = match (unit) {
                    case b'b' | b'B' => 0
                    case b'k' | b'K' => 1
                    case b'm' | b'M' => 2
                    case b'g' | b'G' => 3
                    case b't' | b'T' => 4
                    case b'p' | b'P' => 5
                    case b'e' | b'E' => 6
                    case _ => -1
                }
                if (shift < 0) {
                    None<Int64>
                } else {
                    Some(n * (1024 ** UInt64(shift)))
                }
        }
    }

    /** 节点表复用客户端配置项，顺序即节点下标。 */
    protected static prop nodes: Array<String> {
        get() {
            Config.getStringArray(MQConfigKey.CLIENT_HOSTS)
        }
    }

    /** `metas` 目录：`<fmq 可执行文件目录>/metas`。 */
    protected static prop metaDir: Path {
        get() {
            getAbsoluteCommandDir().join("metas")
        }
    }

    /** 本机在节点表中的下标；端口缺失或重复时抛 `MQConfigException`。 */
    protected static prop selfIndex: Int64 {
        get() {
            let entries = nodes
            var found = -1i64
            for (i in 0..entries.size) {
                match (parsePort(entries[i])) {
                    case Some(p) =>
                        if (p == port) {
                            if (found >= 0) {
                                throw MQConfigException("duplicate port ${port} in ${MQConfigKey.CLIENT_HOSTS}")
                            }
                            found = i
                        }
                    case None => ()
                }
            }
            if (found < 0) {
                throw MQConfigException("${PORT} ${port} is not in ${MQConfigKey.CLIENT_HOSTS}")
            }
            found
        }
    }

    private static func parsePort(entry: String): ?UInt16 {
        let parts = entry.trimAscii().split(":")
        if (parts.size != 2) {
            return None<UInt16>
        }
        UInt16.tryParse(parts[1].trimAscii())
    }

    /** 启动期校验；失败抛 `MQConfigException`（调用方打印并退出 2）。 */
    protected static func validate(): Unit {
        if (backup < 0) {
            throw MQConfigException("${BACKUP} must not be negative, got ${backup}")
        }
        if (nodes.size == 0) {
            throw MQConfigException("${MQConfigKey.CLIENT_HOSTS} is required")
        }
        // 任意两个节点端口重复都拒绝启动，不能只校验「重复端口是否等于本机端口」
        let entries = nodes
        for (i in 0..entries.size) {
            match (parsePort(entries[i])) {
                case Some(port) =>
                    for (j in i + 1..entries.size) {
                        match (parsePort(entries[j])) {
                            case Some(other) =>
                                if (port == other) {
                                    throw MQConfigException("duplicate port ${port} in ${MQConfigKey.CLIENT_HOSTS}")
                                }
                            case None => ()
                        }
                    }
                case None => ()
            }
        }
        if (deadMsgThreshold < 1) {
            throw MQConfigException("${DEAD_MSG_THRESHOLD} must be at least 1, got ${deadMsgThreshold}")
        }
        // 触发端口定位（缺失 / 重复都会抛）
        selfIndex
    }

    /** `fmq server --help` 的配置项清单。 */
    protected static func helpText(): String {
        """
  mqServer_port                 监听端口，默认 2350
  mqServer_ackTimeout           未确认消息的重投超时，默认 10s
  mqServer_deadMsgThreshold     超过该投递次数进入死信，默认 3
  mqServer_deadMsgTTL           死信段保留时长，默认 72h
  mqServer_segmentedLogDir      消息段日志目录，默认 /var/log/fmq/segmentedLogs
  mqServer_deadMsgDir           死信日志目录，默认 /var/log/fmq/deadMsgs
  mqServer_segmentedLogMaxSize  单段最大字节数，默认 1G
  mqServer_segmentedLogTTL      消息段保留时长，默认 72h
  mqServer_backup               备份副本数，默认 0（不复制）
  mqClient_hosts                节点表，逗号分隔的 host:port（必填）
"""
    }
}
