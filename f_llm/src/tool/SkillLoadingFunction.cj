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

@DataAssist[props fields]
public class SkillLoading {
    @JsonStringSchema[description:'流程当前步骤的事件名称']
    private var event: String = ''
    @JsonStringSchema[description:'技能标题，具备唯一性']
    private var title: String = ''
}


@Bean
public class AnswerFunction <: FunctionCalling<SkillLoading> {
    private let skillsFinder = lookup<SkillsFinder>()
    /**
     * 函数名称
     */
    public prop name: String {
        get(){
            'loadSkill'
        }
    }
    /**
     * 函数描述
     */
    public prop description: String {
        get(){
            '加载技能详细描述'
        }
    }
    /**
     * 用来加载技能详细描述
     * @param params 函数参数
     * @return 函数调用结果
     */
    public func call(params: SkillLoading): FunctionResult {
        FunctionResult(event: params.event, result: skillsFinder.loadSkill(params.title))
    }
}