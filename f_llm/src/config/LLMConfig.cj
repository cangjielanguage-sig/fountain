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
package fountain::f_llm.config

import std.convert.*
import std.env.*
import std.fs.{Path, exists, Directory}
import fountain::f_config.*

public struct LLMConfig {
    private init() {}
    public static const LLM_REBUILD_INDEX_ON_START = 'llm_rebuildIndexOnStart'
    public static const LLM_REBUILD_INDEX_USER_ID = 'llm_rebuildIndexUserId'
    public static const LLM_REBUILD_INDEX_NAMESPACE = 'llm_rebuildIndexNamespace'
    public static const LLM_EMBEDDING_URL = 'llm_embeddingUrl'
    public static const LLM_EMBEDDING_TIMEOUT_MS = 'llm_embeddingTimeoutMs'
    public static const LLM_EMBEDDING_RETRIES = 'llm_embeddingRetries'
    public static const LLM_MEMORY_USER_ID = 'llm_memoryUserId'
    public static const LLM = 'llm'
    public static const AUTO = LLM + '_auto'
    public static const FILE_SANDBOX_PATH = LLM + '_fileSandboxPath'
    public static const LLM_ACCESS_TRYING_COUNT = LLM + '_accessTryingCount'
    public static const LLM_ACCESS_TRYING_ELAPSED = LLM + '_accessTryingElapsed'
    public static const LLM_FAITHFUL_MEMORY_PATH = LLM + '_faithfulMemoryPath'
    public static const LLM_MAKING_MEMORY = LLM + '_makingMemory'
    public static const SUMMARISING_MODEL = LLM + '_summarisingModel'
    public static const SUMMARISING_ACTION_KIND = LLM + '_summarisingActionKind'
    /** 配置是否从数据库读取；false 时走其它来源（文件 / 环境变量 / 静态注册） */
    public static const LLM_DB = LLM + '_db'

    public static func isAuto(): Bool {
        Config.getValue<Bool>(AUTO) ?? false
    }

    /** 数据库配置源开关：`llm_db=true` */
    public static func isDatabaseEnabled(): Bool {
        Config.getValue<Bool>(LLM_DB) ?? false
    }

    /** Supervisor 开关：`llm_supervisor=true` 才启用流程路由（默认关闭） */
    public static const LLM_SUPERVISOR = LLM + '_supervisor'
    /** 无可用流程时是否自动编排新流程；仅 `llm_supervisor=true` 时生效 */
    public static const LLM_LOOM_ON_NO_USABLE = LLM + '_loomOnNoUsable'

    public static func supervisorEnabled(): Bool {
        Config.getValue<Bool>(LLM_SUPERVISOR) ?? false
    }

    /** 无可用流程时才自动编排；supervisor 没开时该开关一律不生效 */
    public static func loomOnNoUsable(): Bool {
        if (!supervisorEnabled()) {
            return false
        }
        Config.getValue<Bool>(LLM_LOOM_ON_NO_USABLE) ?? false
    }

    /** 第三方平台账号配置（JSON 数组，一条一个账号） */
    public static const LLM_CHANNELS = LLM + '_channels'

    /** 原始 JSON 串；装配时由 `ChannelBootstrap` 解析 */
    public static func channelsJson(): String {
        Config.getString(LLM_CHANNELS) ?? ''
    }

    /** 配置来源名：database（默认）/ env / file:<path> */
    public static const LLM_CONF_SOURCE = LLM + '_confSource'
    /** env 来源内联的配置 JSON 数组 */
    public static const LLM_CONFS = LLM + '_confs'
    /** 配置刷新周期（秒），懒式 TTL */
    public static const LLM_CONF_REFRESH_SECONDS = LLM + '_confRefreshSeconds'

    public static func getConfSource(): String {
        Config.getString(LLM_CONF_SOURCE) ?? 'database'
    }

    public static func getConfRefreshInterval(): Duration {
        Duration.second * (Config.getValue<Int64>(LLM_CONF_REFRESH_SECONDS) ?? 60)
    }

    /** 权重调度算法：randomWeight（默认）/ roundRobin */
    public static const LLM_LOAD_BALANCE_ALGO = LLM + '_loadBalanceAlgo'
    /** 连续可重试失败多少次触发临时下线 */
    public static const LLM_FAILURE_THRESHOLD = LLM + '_failureThreshold'
    /** 临时下线时长（秒） */
    public static const LLM_COOLDOWN_SECONDS = LLM + '_cooldownSeconds'

    /** 裁剪策略（Summary/Keywords）调用 LLM 时用的逻辑配置名 */
    public static const LLM_PRUNER_LLM_NAME = LLM + '_prunerLlmName'
    /** 记忆摘要调用 LLM 时用的逻辑配置名 */
    public static const LLM_SUMMARISING_LLM_NAME = LLM + '_summarisingLlmName'

    public static func getPrunerLlmName(): String {
        Config.getString(LLM_PRUNER_LLM_NAME) ?? 'chat-pro'
    }

    /** BGE-M3 端点（默认本机 8000） */
    public static func getEmbeddingUrl(): String {
        Config.getString(LLM_EMBEDDING_URL) ?? 'http://127.0.0.1:8000/v1/embeddings'
    }

    /** 单次向量化请求超时（毫秒） */
    public static func getEmbeddingTimeoutMs(): Int64 {
        Config.getValue<Int64>(LLM_EMBEDDING_TIMEOUT_MS) ?? 3000
    }

    /** 向量化失败重试次数（不含首次） */
    public static func getEmbeddingRetries(): Int64 {
        Config.getValue<Int64>(LLM_EMBEDDING_RETRIES) ?? 2
    }

    /** 启动后是否重建 sparse/colbert 索引（默认 false） */
    public static func isIndexRebuildEnabled(): Bool {
        Config.getValue<Bool>(LLM_REBUILD_INDEX_ON_START) ?? false
    }

    /** 重建目标用户（默认 0：系统级） */
    public static func getIndexRebuildUserId(): Int64 {
        Config.getValue<Int64>(LLM_REBUILD_INDEX_USER_ID) ?? 0
    }

    /** 重建目标命名空间（默认 global） */
    public static func getIndexRebuildNamespace(): String {
        Config.getString(LLM_REBUILD_INDEX_NAMESPACE) ?? 'global'
    }

    /** 会话摘要写入向量记忆时归属的用户（默认 0：系统级） */
    public static func getMemoryUserId(): Int64 {
        Int64.tryParse(Config.getString(LLM_MEMORY_USER_ID) ?? '0') ?? 0
    }

    public static func getSummarisingLlmName(): String {
        Config.getString(LLM_SUMMARISING_LLM_NAME) ?? 'chat-pro'
    }

    public static func getLoadBalanceAlgo(): String {
        Config.getString(LLM_LOAD_BALANCE_ALGO) ?? 'randomWeight'
    }

    public static func getFailureThreshold(): Int64 {
        Config.getValue<Int64>(LLM_FAILURE_THRESHOLD) ?? 5
    }

    public static func getCooldownDuration(): Duration {
        Duration.second * (Config.getValue<Int64>(LLM_COOLDOWN_SECONDS) ?? 60)
    }

    /** 流式无数据超时（秒） */
    public static const LLM_STREAM_IDLE_TIMEOUT = LLM + '_streamIdleTimeout'
    /** SSE 单行上限（字节） */
    public static const LLM_STREAM_MAX_LINE = LLM + '_streamMaxLineBytes'

    public static func getStreamIdleTimeout(): Duration {
        Duration.second * (Config.getValue<Int64>(LLM_STREAM_IDLE_TIMEOUT) ?? 120)
    }

    public static func getStreamMaxLineBytes(): Int64 {
        Config.getValue<Int64>(LLM_STREAM_MAX_LINE) ?? 1024 * 1024
    }

    /** 单次工具结果进上下文的上限（字节） */
    public static const LLM_TOOL_RESULT_LIMIT = LLM + '_toolResultMaxBytes'

    public static func getToolResultMaxBytes(): Int64 {
        Config.getValue<Int64>(LLM_TOOL_RESULT_LIMIT) ?? 64 * 1024
    }

    /** webFetch 单页正文上限（字节） */
    public static const LLM_FETCH_MAX_BYTES = LLM + '_fetchMaxBytes'

    public static func getFetchMaxBytes(): Int64 {
        Config.getValue<Int64>(LLM_FETCH_MAX_BYTES) ?? 256 * 1024
    }

    /** 低余额告警阈值（与余额同币种口径） */
    public static const LLM_BALANCE_LOW_THRESHOLD = LLM + '_balanceLowThreshold'

    public static func getBalanceLowThreshold(): Int64 {
        Config.getValue<Int64>(LLM_BALANCE_LOW_THRESHOLD) ?? 100
    }
    private static func getPath(key: String, join!: String = '') {
        var path = if (let Some(p) <- Config.getString(key)) {
            Path(p)
        } else {
            getWorkingDirectory()
        }
        if (join.size > 0) {
            path = path.join(join)
        }
        if (!exists(path)) {
            Directory.create(path, recursive: true)
        }
        path
    }
    public static func getFileSandboxPath(): Path {
        getPath(FILE_SANDBOX_PATH)
    }
    public static func getLLMAccessTryingCount(): Int64 {
        Config.getValue<Int64>(LLM_ACCESS_TRYING_COUNT) ?? Int64.Max
    }
    public static func getLLMAccessTryingElapsed(): Duration {
        Duration.second * (Config.getValue<Int64>(LLM_ACCESS_TRYING_ELAPSED) ?? Int64.Max)
    }
    public static func getFaithfulMemoryPath(): Path {
        getPath(LLM_FAITHFUL_MEMORY_PATH, join: '.memory')
    }
    public static func getMakingMemory(): Bool {
        Config.getValue<Bool>(LLM_MAKING_MEMORY) ?? false
    }
    public static func getSummarisingModel(): String {
        Config.getString(SUMMARISING_MODEL) ?? 'glm-4.7-flash'
    }
    public static func getSummarisingActionKind(): String {
        Config.getString(SUMMARISING_ACTION_KIND) ?? ''
    }
}
