/*
    Copyright (c) [2022] [WuJingrun（吴京润）]
    fountain is licensed under Mulan PSL v2.
    You can use this software according to the terms and conditions of the Mulan PSL v2.
    You may obtain a copy of Mulan PSL v2 at:
            http://license.coscl.org.cn/MulanPSL2
    THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
    See the Mulan PSL v2 for more details.
 */
package f_log

import std.collection.concurrent.ConcurrentHashMap
import std.reflect.TypeInfo
import std.sync.ReentrantMutex

import log.Attr

import f_base.*

internal let globalAttrMap = ConcurrentHashMap<String, Array<Attr>>()
public class LoggerFactory {
    private static let mutex = ReentrantMutex()
    private static let loggers = ConcurrentHashMap<String, LoggerWrapper>()

    private init() {}

    public static func getLogger(name: String, attrs: Array<Attr>): Logger {
        if(!attrs.isEmpty()){
            globalAttrMap[name] = attrs
        }
        if(let Some(x) <- loggers.get(name)){
            x
        }else{
            synchronized(mutex){
                if(let Some(x) <- loggers.get(name)){
                    x
                }else{
                    let wrapper = LoggerWrapper(name)
                    loggers[name] = wrapper
                    wrapper
                }
            }
        }
    }
    public static func getLogger<O>(attrs: Array<Attr>): Logger{
        getLogger(TypeInfos.get<O>(), attrs)
    }
    public static func getLogger(typeInfo: TypeInfo, attrs: Array<Attr>): Logger {
        getLogger(typeInfo.qualifiedName, attrs)
    }
    public static func refresh(){
        for((_, w) in loggers){
            w.refresh()
        }
    }
}
