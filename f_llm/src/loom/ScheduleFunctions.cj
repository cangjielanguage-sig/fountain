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

import fountain::f_bean.*
import fountain::f_bean.macros.*
import fountain::f_data.macros.*
import fountain::f_egraph.base.*

import fountain::f_llm.tool.*

/** 注册一个定时任务：到点执行同名 loom 流程（若已安装服务与宿主） */
@DataAssist[props fields]
public class ScheduleCreateParam {
    @JsonStringSchema[description:'流程下一步的事件名称']
    private var nextEvent: String = ''
    @JsonStringSchema[description:'任务名与流程名（同名替换）']
    private var name: String = ''
    @JsonStringSchema[description:'cron 七段式：秒 分 时 天 月 星期 年，通配符只支持 *']
    private var cron: String = ''
}

@Bean
public class ScheduleCreateFunction <: FunctionCalling<ScheduleCreateParam> {
    public init() {
    }

    public prop name: String {
        get() {
            'scheduleCreate'
        }
    }

    public prop description: String {
        get() {
            '注册（或替换同名）定时任务，到点执行同名 loom 流程；cron 为七段式'
        }
    }

    public func call(params: ScheduleCreateParam): FunctionResult {
        if(params.name.trimAscii().isEmpty()){
            return FunctionResult(event: params.nextEvent, result: 'scheduleCreate requires name')
        }
        if(params.cron.trimAscii().isEmpty()){
            return FunctionResult(event: params.nextEvent, result: 'scheduleCreate requires cron')
        }
        match(LoomSchedules.current()){
            case Some(scheduler) =>
                let taskName = params.name
                let body = { =>
                    match(LoomServices.current()){
                        case Some(service) => runFlow(service, taskName)
                        case None => ()
                    }
                }
                scheduler.schedule(params.name, params.cron, body)
                FunctionResult(event: params.nextEvent,
                    result: 'scheduled: ${params.name} at ${params.cron}')
            case None =>
                FunctionResult(event: params.nextEvent,
                    result: 'scheduleCreate failed: no loom scheduler installed')
        }
    }

    /** 触发时按名执行一次流程；宿主缺失时静默跳过（不打断调度线程） */
    private static func runFlow(service: LoomService, name: String): Unit {
        match(LoomServices.currentHost()){
            case Some(host) =>
                try{
                    service.executeNow(name, host,
                        StartEvent(category: 'loom', tag: name, name: 'start', data: ''))
                }catch(error: Exception){
                    ()
                }
            case None => ()
        }
    }
}

/** 取消定时任务 */
@DataAssist[props fields]
public class ScheduleDeleteParam {
    @JsonStringSchema[description:'流程下一步的事件名称']
    private var nextEvent: String = ''
    @JsonStringSchema[description:'任务名']
    private var name: String = ''
}

@Bean
public class ScheduleDeleteFunction <: FunctionCalling<ScheduleDeleteParam> {
    public init() {
    }

    public prop name: String {
        get() {
            'scheduleDelete'
        }
    }

    public prop description: String {
        get() {
            '取消指定名称的定时任务'
        }
    }

    public func call(params: ScheduleDeleteParam): FunctionResult {
        if(params.name.trimAscii().isEmpty()){
            return FunctionResult(event: params.nextEvent, result: 'scheduleDelete requires name')
        }
        match(LoomSchedules.current()){
            case Some(scheduler) =>
                scheduler.cancel(params.name)
                FunctionResult(event: params.nextEvent, result: 'cancelled: ${params.name}')
            case None =>
                FunctionResult(event: params.nextEvent,
                    result: 'scheduleDelete failed: no loom scheduler installed')
        }
    }
}
