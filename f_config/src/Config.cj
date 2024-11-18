/*
    Copyright (c) [2022] [WuJingrun（吴京润）]
    fountain is licensed under Mulan PSL v2.
    You can use this software according to the terms and conditions of the Mulan PSL v2.
    You may obtain a copy of Mulan PSL v2 at:
            http://license.coscl.org.cn/MulanPSL2
    THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
    See the Mulan PSL v2 for more details.  
*/
package f_config

import std.collection.{HashMap, Map}
import std.collection.concurrent.ConcurrentHashMap
import std.convert.Parsable
import std.process.{Process, CurrentProcess}
import std.time.{DateTime, DateTimeFormat}

import f_data.DataParsable

public class Config{
    private static let ARGS = ConcurrentHashMap<String, String>()
    static init(){
        let process = Process.current
        for((k, v) in Process.current.environment){
            ARGS[k] = v
        }
        for(arg in process.arguments where arg.startsWith('--')){
            if(let Some(idx) <- arg.indexOf('=')){
                let key = arg[2 .. idx].trimAscii()
                let val = arg[idx + 1 .. ].trimAscii()
                ARGS[key] = val
            }
        }
    }
    private init(){}
    
    public static func getString(key: String): ?String{
        ARGS.get(key)
    }
    public static func getValue<T>(key: String, parser: (String) -> ?T): ?T {
        if(let Some(x) <- getString(key)){
            parser(x)
        }else{
            None<T>
        }
    }
    public static func getValue<T>(key: String): ?T where T <: Parsable<T> {
        getValue<T>(key){s => T.tryParse(s)}
    }
    public static func getStringArray(key: String, delim!: String = ','): Array<String> {
        if(let Some(x) <- getString(key)){
            let arr = x.split(delim, removeEmpty: true)
            Array<String>(arr.size){i => arr[i].trimAscii()}
        }else{
            []
        }
    }
    public static func getValues<T>(key: String, delim!: String = ',', parser!: (String) -> T): Array<T> {
        let arr = getStringArray(key, delim: delim)
        Array<T>(arr.size){i => parser(arr[i])}
    }
    public static func getValues<T>(key: String, delim!: String = ','): Array<T> where T <: Parsable<T> {
        getValues<T>(key, delim: delim){s => T.parse(s)}
    }
    private static func parseDateTime(s: String, format: String){
        if(format.isEmpty()){
            DateTime.parse(s)
        }else{
            DateTime.parse(s, format)
        }
    }
    public static func getDateTime(key: String, format!: String = ''): ?DateTime {
        getValue<DateTime>(key){s => parseDateTime(s, format)}
    }
    public static func getDateTimes(key: String, format!: String = '', delim!: String = ','): Array<DateTime> {
        getValues<DateTime>(key, delim: delim){s => parseDateTime(s, format)}
    }
    public static func getData<T>(key: String): ?T where T <: DataParsable<T> {
        getValue<T>(key){s => T.tryParse(s)}
    }
    public static func getDatas<T>(key: String, delim!: String = ','): Array<T> where T <: DataParsable<T> {
        getValues<T>(key, delim: delim){s => T.parse(s)}
    }
    public static func getDuration(key: String): ?Duration {
        getData<Duration>(key)
    }
    public static func getDurations(key: String, delim!: String = ','): Array<Duration> {
        getDatas<Duration>(key, delim: delim)
    }
}