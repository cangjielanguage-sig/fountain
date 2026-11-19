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
package fountain::f_llm.loom

import fountain::f_egraph.base.*

/**
 * 把 JIT 编译出的步骤闭包注册成定时任务。
 *
 * `f_ticktock` 的任务体是 `() -> Unit`，既不吃事件也不返回事件；而 loom 的步骤闭包是
 * `(Event) -> Event`。两者的接法是：**在任务体内构造固定事件、调用闭包、丢弃返回值**——
 * 定时任务的成果由它产生的副作用（写库、发消息、落产物）体现，而不是靠返回值。
 */
public class JitTicktockTask {
    private init() {
    }

    /**
     * @param name 任务名（同名替换）
     * @param cron 七段式：秒 分 时 天 月 星期 年
     * @param step 要定时执行的步骤（`jit` / `tool` / `llm` 均可，按 `LoomCompiler` 的规则编译）
     * @param payload 透传进事件的 `data`，供步骤里的模板使用
     */
    public static func create(name: String, cron: String, step: StepPlan,
                              scheduler: LoomScheduler, payload!: String = ''): Unit {
        let fn = LoomCompiler().compileStep(step)
        let stepId = step.id
        scheduler.schedule(name, cron, { =>
            try{
                // 每次触发都构造新事件：session 与写入时间戳互不干扰
                let result = fn(StartEvent(category: 'loom', tag: name, name: stepId, data: payload))
                // 返回值无人接收：定时任务的成果由副作用体现
                let _ = result
                ()
            }catch(error: Exception){
                // 定时线程不能把异常抛出去，否则会中断后续调度
                ()
            }
        })
    }
}
