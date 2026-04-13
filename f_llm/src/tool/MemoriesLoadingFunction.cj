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
package fountain::f_llm.tool

import fountain::f_bean.macros.*
import fountain::f_data.macros.*
import fountain::f_llm.model.SkillReferenceParam

@DataAssist[props fields]
public class MemoryLoading {
    @JsonStringSchema[description:'流程当前步骤的事件名称']
    private var event: String = ''
    @JsonStringSchema[description:'查询与本参数相关性最强的经验']
    private var query: String = ''
}

@Bean
public class MemoriesLoadingFunction <: FunctionCalling<MemoryLoading> {
    private let finder = lookup<MemorySummaryFinder>()
    /**
     * 函数名称
     */
    public prop name: String {
        get(){
            'loadMemories'
        }
    }
    /**
     * 函数描述
     */
    public prop description: String {
        get(){
            '加载经验、教训、用户个性等的详细内容，这些内容来自过往会话的记忆总结'
        }
    }
    /**
     * 用来加载经验详细描述
     * @param params 函数参数
     * @return 函数调用结果
     */
    public func call(params: MemoryLoading): FunctionResult {
        let list = finder.query(params.query)
        FunctionResult(event: params.event, result: list, resultType: ResultType.MemorySummary)
    }
}