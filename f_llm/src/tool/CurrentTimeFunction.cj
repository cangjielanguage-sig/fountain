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

import std.time.DateTime

import fountain::f_bean.macros.*
import fountain::f_data.macros.*
import fountain::f_time.*

@DataAssist[props fields]
public class CurrentTimeParams {
    @JsonStringSchema[description:'流程下一步的事件名称']
    private var nextEvent: String = ''
    @JsonStringSchema[description:'返回格式：iso（默认，如 2026-10-27T10:00:00+08:00）或 epoch（Unix 秒）']
    private var format: String = 'iso'
    @JsonStringSchema[description:'时区：留空或 local 表示本机时区；当前只支持本机时区，其它值会返回说明文本']
    private var timezone: String = ''
}

/**
 * 内置函数：返回本机当前时间。
 *
 * 只读本机时区——要拿别的时区，调用方应自己按 epoch 换算，而不是让工具去猜夏令时。
 * 参数非法时返回说明文本（不抛异常），让模型自己改参数重试。
 */
@Bean
public class CurrentTimeFunction <: FunctionCalling<CurrentTimeParams> {
    public prop name: String {
        get() {
            'currentTime'
        }
    }

    public prop description: String {
        get() {
            '返回本机当前时间。format=iso 返回可读时间，format=epoch 返回 Unix 秒'
        }
    }

    public func call(params: CurrentTimeParams): FunctionResult {
        let zone = params.timezone.trimAscii().toAsciiLower()
        if(!zone.isEmpty() && zone != 'local'){
            return FunctionResult(
                event: params.nextEvent,
                result: '[currentTime] unsupported timezone: ${params.timezone}, only local is supported'
            )
        }
        let format = if(params.format.trimAscii().isEmpty()){
            'iso'
        }else{
            params.format.trimAscii().toAsciiLower()
        }
        match(format){
            case 'iso' => FunctionResult(event: params.nextEvent, result: DateTime.now().toString())
            case 'epoch' => FunctionResult(event: params.nextEvent, result: '${DateTime.now().toUnixEpochSeconds()}')
            case _ => FunctionResult(
                event: params.nextEvent,
                result: '[currentTime] unsupported format: ${params.format}, use iso or epoch'
            )
        }
    }
}
