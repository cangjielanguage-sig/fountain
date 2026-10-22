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
import fountain::f_log.*
import fountain::f_mq.base.{MQConfigKey, MQHost}
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
    private static let log = LoggerFactory.getLogger("fountain::fmq.config.MQConfig")

    static let PORT = "${PREFIX}_port"
    static let ACK_TIMEOUT = "${PREFIX}_ackTimeout"
    static let DEAD_MSG_THRESHOLD = "${PREFIX}_deadMsgThreshold"
    static let DEAD_MSG_TTL = "${PREFIX}_deadMsgTTL"
    static let SEGMENTED_LOG_DIR = "${PREFIX}_segmentedLogDir"
    static let DEAD_MSG_DIR = "${PREFIX}_deadMsgDir"
    static let SEGMENTED_LOG_MAX_SIZE = "${PREFIX}_segmentedLogMaxSize"
    static let SEGMENTED_LOG_TTL = "${PREFIX}_segmentedLogTTL"
    static let BACKUP = "${PREFIX}_backup"
    static let TOMBSTONE_TTL = "${PREFIX}_tombstoneTTL"
    static let ANTI_ENTROPY_INTERVAL = "${PREFIX}_antiEntropyInterval"

    static let DEFAULT_PORT: UInt16 = 2350
    static let DEFAULT_ACK_TIMEOUT = Duration.second * 10
    static let DEFAULT_DEAD_MSG_THRESHOLD: Int64 = 3
    static let DEFAULT_DEAD_MSG_TTL = Duration.hour * 72
    static let DEFAULT_SEGMENTED_LOG_DIR = "/var/log/fmq/segmentedLogs"
    static let DEFAULT_DEAD_MSG_DIR = "/var/log/fmq/deadMsgs"
    static let DEFAULT_SEGMENTED_LOG_MAX_SIZE: Int64 = 1024 * 1024 * 1024
    static let DEFAULT_SEGMENTED_LOG_TTL = Duration.hour * 72
    static let DEFAULT_BACKUP: Int64 = 0
    static let DEFAULT_TOMBSTONE_TTL = Duration.hour * 24 * 7
    static let DEFAULT_ANTI_ENTROPY_INTERVAL = Duration.second * 30

    private init() {}

    protected static prop port: UInt16 {
        get() {
            strictPort()
        }
    }

    protected static prop ackTimeout: Duration {
        get() {
            strictDuration(ACK_TIMEOUT, DEFAULT_ACK_TIMEOUT)
        }
    }

    protected static prop deadMsgThreshold: Int64 {
        get() {
            strictInt64(DEAD_MSG_THRESHOLD, DEFAULT_DEAD_MSG_THRESHOLD)
        }
    }

    protected static prop deadMsgTTL: Duration {
        get() {
            strictDuration(DEAD_MSG_TTL, DEFAULT_DEAD_MSG_TTL)
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
            match (Config.getString(SEGMENTED_LOG_MAX_SIZE)) {
                case None => DEFAULT_SEGMENTED_LOG_MAX_SIZE
                case Some(text) =>
                    match (parseByteSize(text)) {
                        case Some(parsed) => parsed
                        case None => throw MQConfigException(
                            "${SEGMENTED_LOG_MAX_SIZE} '${text}' is not a byte size")
                    }
            }
        }
    }

    protected static prop segmentedLogTTL: Duration {
        get() {
            strictDuration(SEGMENTED_LOG_TTL, DEFAULT_SEGMENTED_LOG_TTL)
        }
    }

    /** 墓碑保留时长：短于节点最长离线时间的节点会漏掉删除，文档要求全量重建（A25）。 */
    protected static prop tombstoneTTL: Duration {
        get() {
            strictDuration(TOMBSTONE_TTL, DEFAULT_TOMBSTONE_TTL)
        }
    }

    /** 反熵同步间隔。 */
    protected static prop antiEntropyInterval: Duration {
        get() {
            strictDuration(ANTI_ENTROPY_INTERVAL, DEFAULT_ANTI_ENTROPY_INTERVAL)
        }
    }

    protected static prop backup: Int64 {
        get() {
            strictInt64(BACKUP, DEFAULT_BACKUP)
        }
    }

    /**
     * 严格解析：显式配置项非法时启动失败，而不是静默回落默认值（A63）。
     *
     * 旧实现用 `getValue ?? default`，`port=abc`、`maxSize=not-a-size` 都会被悄悄吃掉。
     */
    private static func strictPort(): UInt16 {
        match (Config.getString(PORT)) {
            case None => DEFAULT_PORT
            case Some(text) =>
                match (UInt16.tryParse(text.trimAscii())) {
                    case Some(value) => value
                    case None => throw MQConfigException("${PORT} '${text}' is not a valid port")
                }
        }
    }

    private static func strictInt64(key: String, fallback: Int64): Int64 {
        match (Config.getString(key)) {
            case None => fallback
            case Some(text) =>
                match (Int64.tryParse(text.trimAscii())) {
                    case Some(value) => value
                    case None => throw MQConfigException("${key} '${text}' is not an integer")
                }
        }
    }

    private static func strictDuration(key: String, fallback: Duration): Duration {
        match (Config.getString(key)) {
            case None => fallback
            case Some(text) =>
                match (Config.getDuration(key)) {
                    case Some(value) => value
                    case None => throw MQConfigException("${key} '${text}' is not a duration")
                }
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
                match (MQHost.parseHost(entries[i])) {
                    case Some((_, p)) =>
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

    /** 启动期校验；失败抛 `MQConfigException`（调用方打印并退出 2）。 */
    protected static func validate(): Unit {
        // 先把所有配置项按严格模式读一遍：任何非法显式值都在这里失败（A63）
        let checkedPort = port
        let checkedAck = ackTimeout
        let checkedThreshold = deadMsgThreshold
        let checkedDeadTtl = deadMsgTTL
        let checkedMaxSize = segmentedLogMaxSize
        let checkedLogTtl = segmentedLogTTL
        let checkedBackup = backup
        let checkedTombstoneTtl = tombstoneTTL
        let checkedAntiEntropy = antiEntropyInterval
        let entries = nodes

        if (checkedPort == 0) {
            throw MQConfigException("${PORT} must not be 0")
        }
        if (checkedAck <= Duration.Zero) {
            throw MQConfigException("${ACK_TIMEOUT} must be positive, got ${checkedAck}")
        }
        if (checkedDeadTtl <= Duration.Zero) {
            throw MQConfigException("${DEAD_MSG_TTL} must be positive, got ${checkedDeadTtl}")
        }
        if (checkedLogTtl <= Duration.Zero) {
            throw MQConfigException("${SEGMENTED_LOG_TTL} must be positive, got ${checkedLogTtl}")
        }
        if (checkedTombstoneTtl <= Duration.Zero) {
            throw MQConfigException("${TOMBSTONE_TTL} must be positive, got ${checkedTombstoneTtl}")
        }
        if (checkedAntiEntropy <= Duration.Zero) {
            throw MQConfigException("${ANTI_ENTROPY_INTERVAL} must be positive, got ${checkedAntiEntropy}")
        }
        if (checkedMaxSize <= 0) {
            throw MQConfigException("${SEGMENTED_LOG_MAX_SIZE} must be positive, got ${checkedMaxSize}")
        }
        // 段上限压低单条记录上限：必须让运维看见真实可用值，而不是等到写入时才发现越界
        if (checkedMaxSize <= 64 * 1024 * 1024 + 4) {
            log.warn("${SEGMENTED_LOG_MAX_SIZE}=${checkedMaxSize} limits a single record to " +
                "${checkedMaxSize - 4} bytes; records above that are rejected at publish time")
        }
        if (checkedBackup < 0) {
            throw MQConfigException("${BACKUP} must not be negative, got ${checkedBackup}")
        }
        if (entries.size == 0) {
            throw MQConfigException("${MQConfigKey.CLIENT_HOSTS} is required")
        }
        for (entry in entries) {
            if (MQHost.parseHost(entry).isNone()) {
                throw MQConfigException("invalid node '${entry}' in ${MQConfigKey.CLIENT_HOSTS}, expect host:port")
            }
        }
        // 备份节点数不能超过除自身外的节点数
        if (checkedBackup > entries.size - 1) {
            throw MQConfigException("${BACKUP} ${checkedBackup} exceeds node count ${entries.size}")
        }
        // 任意两个节点端口重复都拒绝启动，不能只校验「重复端口是否等于本机端口」
        for (i in 0..entries.size) {
            match (MQHost.parseHost(entries[i])) {
                case Some((_, port)) =>
                    for (j in i + 1..entries.size) {
                        match (MQHost.parseHost(entries[j])) {
                            case Some((_, other)) =>
                                if (port == other) {
                                    throw MQConfigException("duplicate port ${port} in ${MQConfigKey.CLIENT_HOSTS}")
                                }
                            case None => ()
                        }
                    }
                case None => ()
            }
        }
        if (checkedThreshold < 1) {
            throw MQConfigException("${DEAD_MSG_THRESHOLD} must be at least 1, got ${checkedThreshold}")
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
  mqServer_tombstoneTTL         删除墓碑保留时长，默认 7d
  mqServer_antiEntropyInterval  反熵同步间隔，默认 30s
  mqClient_hosts                节点表，逗号分隔的 host:port（必填）
"""
    }
}
