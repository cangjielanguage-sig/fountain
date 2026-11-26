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
package fountain::f_llm.llm

import fountain::f_log.*

import fountain::f_llm.model.po.*
import fountain::f_llm.util.*

/**
 * 一次调用的汇总日志（默认 `info`，评审 R8/R10）。
 *
 * 只记**一行**：平台、模型、耗时、TTFT、用量、结束原因、是否估算；
 * 不记报文正文（要报文得显式开 `debug`，且经过 `Redactor`）。
 * `usage` 不落库——本模块不做持久化。
 */
public struct CallLog {
    private static let log = LoggerFactory.getLogger<CallLog>()

    private init(){}

    public static func summary(conf: LLMConf, response: LLMResp, elapsedMs: Int64, ttftMs!: Int64 = -1): String {
        let ttft = if(ttftMs < 0){ '-' }else{ '${ttftMs}' }
        'llm call, provider: ${conf.provider}, model: ${conf.actualLlmName}, auth: ${Redactor.mask(conf.auth)}, elapsedMs: ${elapsedMs}, ttftMs: ${ttft}, prompt: ${response.usage.prompt}, completion: ${response.usage.completion}, total: ${response.usage.total}, estimated: ${response.usageEstimated}, finish: ${response.finishReason}'
    }

    public static func info(conf: LLMConf, response: LLMResp, elapsedMs: Int64, ttftMs!: Int64 = -1): Unit {
        let line = summary(conf, response, elapsedMs, ttftMs: ttftMs)
        log.info{'${line}'}
    }
}
