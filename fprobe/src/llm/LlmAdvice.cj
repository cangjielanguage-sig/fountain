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

import fountain::f_data.*
import fountain::f_data.macros.*

/** 一条可展示的建议；`action` 只有白名单动作会被执行。 */
@DataAssist[props fields]
public class LlmSolution {
    private var title: String = ""
    private var action: String = "none"
    private var risk: String = ""

    public init() {}

    public init(title: String, action: String, risk: String) {
        this.title = title
        this.action = action
        this.risk = risk
    }
}

/** LLM 结构化输出（spec「结构化建议」）。 */
@DataAssist[props fields]
public class LlmAdvice {
    private var summary: String = ""
    private var problems: Array<String> = []
    private var solutions: Array<LlmSolution> = []

    public init() {}

    public init(summary: String, problems: Array<String>, solutions: Array<LlmSolution>) {
        this.summary = summary
        this.problems = problems
        this.solutions = solutions
    }
}
