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
package fountain::fprobe.llm

import std.collection.ArrayList
import fountain::f_data.*

/**
 * 解析 LLM 输出（spec「结构化建议」）。
 *
 * 先剥离 Markdown 代码围栏，再按固定 DTO 解析；任何失败都把原文放进
 * `summary`，保证分析结果不会因为格式问题被丢弃。
 */
public class AdviceParser {
    public static func parse(text: String): LlmAdvice {
        let candidate = stripFence(text)
        if (!candidate.isEmpty()) {
            try {
                match (JsonValue.fromStr(candidate)) {
                    case object: JsonObject =>
                        match (DataObject<LlmAdvice>.populate(object.toData())) {
                            case Some(advice) =>
                                if (!advice.summary.trimAscii().isEmpty()) {
                                    return advice
                                }
                            case None => ()
                        }
                    case _ => ()
                }
            } catch (_: Exception) {
            } catch (_: Error) {
            }
        }
        LlmAdvice(text, Array<String>(), Array<LlmSolution>())
    }

    private static func stripFence(text: String): String {
        let trimmed = text.trimAscii()
        let lines = trimmed.split("\n")
        if (lines.size >= 2 && lines[0].trimAscii().startsWith("```")) {
            var end = lines.size
            if (lines[end - 1].trimAscii().startsWith("```")) {
                end -= 1
            }
            let body = ArrayList<String>()
            for (i in 1..end) {
                body.add(lines[i])
            }
            return join(body, "\n").trimAscii()
        }
        trimmed
    }

    private static func join(lines: ArrayList<String>, separator: String): String {
        var result = ""
        var first = true
        for (line in lines) {
            if (!first) {
                result += separator
            }
            result += line
            first = false
        }
        result
    }
}
