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
    private init(){}
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
    private static func getPath(key: String, join!: String = ''){
        var path =  if(let Some(p) <- Config.getString(key)){
            Path(p)
        }else{
            getWorkingDirectory()
        }
        if(join.size > 0){
            path = path.join(join)
        }
        if(!exists(path)){
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