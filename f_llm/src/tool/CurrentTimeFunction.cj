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

import std.collection.ArrayList

import fountain::f_bean.*
import fountain::f_bean.macros.*
import fountain::f_data.macros.*
import fountain::f_time.*

@DataAssist[props fields]
public class CurrentTimeParams {
    @JsonStringSchema[description:'流程下一步的事件名称']
    private var nextEvent: String = ''
    @JsonStringSchema[description:'返回格式：iso（默认，如 2026-10-27T10:00:00+08:00）或 epoch（Unix 毫秒）']
    private var format: String = 'iso'
    @JsonStringSchema[description:'时区：留空/local 用本机；支持 UTC、+08:00、-05:00 以及 Asia/Shanghai、Asia/Tokyo、Asia/Seoul 等无夏令时的常见时区']
    private var timezone: String = ''
}

/**
 * 内置函数：返回当前时间。
 *
 * 时区只支持**固定偏移**（显式 `+08:00` 或少数无夏令时的常见时区），不做夏令时推算——
 * 猜错时区比报「不支持」更糟。参数非法时返回说明文本（不抛异常），让模型自己改参数重试。
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
            '返回当前时间。format=iso 返回带偏移量的可读时间，format=epoch 返回 Unix 毫秒'
        }
    }

    public func call(params: CurrentTimeParams): FunctionResult {
        let zone = params.timezone.trimAscii().toAsciiLower()
        let offset = match(offsetOf(zone)){
            case Some(value) => value
            case None => if(zone.isEmpty() || zone == 'local'){
                return localResult(params)
            }else{
                return FunctionResult(
                    event: params.nextEvent,
                    result: '[currentTime] unsupported timezone: ${params.timezone}, use local, UTC, +08:00 or a zone like Asia/Shanghai'
                )
            }
        }
        let format = if(params.format.trimAscii().isEmpty()){
            'iso'
        }else{
            params.format.trimAscii().toAsciiLower()
        }
        match(format){
            case 'iso' => FunctionResult(event: params.nextEvent, result: isoAt(DateTime.now().toUnixEpochMillis(), offset))
            case 'epoch' => FunctionResult(event: params.nextEvent, result: '${DateTime.now().toUnixEpochMillis()}')
            case _ => FunctionResult(
                event: params.nextEvent,
                result: '[currentTime] unsupported format: ${params.format}, use iso or epoch'
            )
        }
    }

    /** 本机时区：直接交给 `DateTime.toString()`（带本机偏移量） */
    private func localResult(params: CurrentTimeParams): FunctionResult {
        let format = if(params.format.trimAscii().isEmpty()){
            'iso'
        }else{
            params.format.trimAscii().toAsciiLower()
        }
        match(format){
            case 'iso' => FunctionResult(event: params.nextEvent, result: DateTime.now().toString())
            case 'epoch' => FunctionResult(event: params.nextEvent, result: '${DateTime.now().toUnixEpochMillis()}')
            case _ => FunctionResult(
                event: params.nextEvent,
                result: '[currentTime] unsupported format: ${params.format}, use iso or epoch'
            )
        }
    }
}

/** 时区名 → 固定偏移秒数；`None` 表示不是固定偏移（交给本机时区或报错） */
func offsetOf(zone: String): ?Int64 {
    match(zone){
        case 'utc' | 'gmt' | 'z' | '+00:00' | '+0000' => 0
        case 'asia/shanghai' | 'asia/chongqing' | 'asia/hong_kong' | 'asia/singapore' | 'prc' => 8 * 3600
        case 'asia/tokyo' | 'japan' => 9 * 3600
        case 'asia/seoul' | 'rok' => 9 * 3600
        case 'asia/kolkata' | 'asia/calcutta' => 5 * 3600 + 1800
        case 'australia/sydney' => 10 * 3600
        case _ => parseOffset(zone)
    }
}

/** `+08:00` / `-0530` 这类显式偏移 */
func parseOffset(zone: String): ?Int64 {
    if(zone.size < 5){
        return None<Int64>
    }
    let sign = zone[0 .. 1]
    if(sign != '+' && sign != '-'){
        return None<Int64>
    }
    let digits = zone[1 ..].replace(':', '')
    if(digits.size != 4){
        return None<Int64>
    }
    let hours = Int64.tryParse(digits[0 .. 2]) ?? -1
    let minutes = Int64.tryParse(digits[2 .. 4]) ?? -1
    if(hours < 0 || hours > 14 || minutes < 0 || minutes > 59){
        return None<Int64>
    }
    let total = hours * 3600 + minutes * 60
    if(sign == '-'){
        Some(-total)
    }else{
        Some(total)
    }
}

/** 把 epoch 毫秒按固定偏移渲染成 `yyyy-MM-ddTHH:mm:ss+HH:MM` */
func isoAt(epochMillis: Int64, offsetSeconds: Int64): String {
    let localMillis = epochMillis + offsetSeconds * 1000
    let seconds = floorDiv(localMillis, 1000)
    let (year, month, day, hour, minute, second) = civilFromEpoch(seconds)
    let sign = if(offsetSeconds < 0){ '-' }else{ '+' }
    let absolute = if(offsetSeconds < 0){ -offsetSeconds }else{ offsetSeconds }
    let offsetHour = absolute / 3600
    let offsetMinute = (absolute % 3600) / 60
    '${year}-${pad2(month)}-${pad2(day)}T${pad2(hour)}:${pad2(minute)}:${pad2(second)}${sign}${pad2(offsetHour)}:${pad2(offsetMinute)}'
}

func floorDiv(value: Int64, divisor: Int64): Int64 {
    if(value >= 0){
        value / divisor
    }else{
        -((-value + divisor - 1) / divisor)
    }
}

func pad2(value: Int64): String {
    if(value < 10){
        '0${value}'
    }else{
        '${value}'
    }
}

/** 1970-01-01 起的秒数 → 年月日时分秒（Howard Hinnant 的 days→civil） */
func civilFromEpoch(seconds: Int64): (Int64, Int64, Int64, Int64, Int64, Int64) {
    let days = floorDiv(seconds, 86400)
    var remain = seconds - days * 86400
    let hour = remain / 3600
    remain -= hour * 3600
    let minute = remain / 60
    let second = remain - minute * 60

    var z = days + 719468
    let era = floorDiv(z, 146097)
    let dayOfEra = z - era * 146097
    let yearOfEra = (dayOfEra - dayOfEra / 1460 + dayOfEra / 36524 - dayOfEra / 146096) / 365
    let year = yearOfEra + era * 400
    let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
    let mp = (5 * dayOfYear + 2) / 153
    let day = dayOfYear - (153 * mp + 2) / 5 + 1
    let month = if(mp < 10){ mp + 3 }else{ mp - 9 }
    let normalizedYear = if(month <= 2){ year + 1 }else{ year }
    (normalizedYear, month, day, hour, minute, second)
}
