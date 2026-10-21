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
package fountain::fmq.server

import fountain::fmq.config.MQConfig

/**
 * 服务端装配参数。
 *
 * 生产路径由 `fromConfig` 读取 `mqServer_*` 与 `mqClient_hosts`；
 * 测试通过构造参数注入临时目录与端口，避免写 `/var/log` 或占用固定端口。
 */
protected struct MQServerOptions {
    let port: UInt16
    let nodes: Array<String>
    let selfIndex: Int64
    let ackTimeout: Duration
    let deadMsgThreshold: Int64
    let deadMsgTTL: Duration
    let segmentedLogDir: String
    let deadMsgDir: String
    let segmentedLogMaxSize: Int64
    let segmentedLogTTL: Duration
    let backup: Int64
    let metaDir: String
    let tombstoneTTL: Duration
    let antiEntropyInterval: Duration

    protected init(port: UInt16, nodes: Array<String>, selfIndex: Int64, ackTimeout: Duration,
        deadMsgThreshold: Int64, deadMsgTTL: Duration, segmentedLogDir: String, deadMsgDir: String,
        segmentedLogMaxSize: Int64, segmentedLogTTL: Duration, backup: Int64, metaDir: String,
        tombstoneTTL!: Duration = Duration.hour * 24 * 7,
        antiEntropyInterval!: Duration = Duration.second * 30) {
        this.port = port
        this.nodes = nodes
        this.selfIndex = selfIndex
        this.ackTimeout = ackTimeout
        this.deadMsgThreshold = deadMsgThreshold
        this.deadMsgTTL = deadMsgTTL
        this.segmentedLogDir = segmentedLogDir
        this.deadMsgDir = deadMsgDir
        this.segmentedLogMaxSize = segmentedLogMaxSize
        this.segmentedLogTTL = segmentedLogTTL
        this.backup = backup
        this.metaDir = metaDir
        this.tombstoneTTL = tombstoneTTL
        this.antiEntropyInterval = antiEntropyInterval
    }

    protected static func fromConfig(): MQServerOptions {
        MQConfig.validate()
        MQServerOptions(
            MQConfig.port,
            MQConfig.nodes,
            MQConfig.selfIndex,
            MQConfig.ackTimeout,
            MQConfig.deadMsgThreshold,
            MQConfig.deadMsgTTL,
            MQConfig.segmentedLogDir,
            MQConfig.deadMsgDir,
            MQConfig.segmentedLogMaxSize,
            MQConfig.segmentedLogTTL,
            MQConfig.backup,
            MQConfig.metaDir.toString(),
            tombstoneTTL: MQConfig.tombstoneTTL,
            antiEntropyInterval: MQConfig.antiEntropyInterval
        )
    }
}
