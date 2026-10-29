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
package fountain::f_llm.store

import std.collection.*

/**
 * 记忆种类注册表（2.2）。
 *
 * 预定义 7 值固化在代码；自定义 kind 归属用户，进程内先落内存，
 * 2.3 接入 `llm_memory_kind` 后再做启动补种与持久化。
 */
/** 种类持久化 SPI：PG/MySQL/f_store 各自实现，`seed` 只依赖它 */
public interface KindPersistence {
    func has(kind: String): Bool
    func insert(kind: String, predefined: Bool): Unit
}

public class MemoryKinds {
    public static let NOTE = 'note'
    public static let FACT = 'fact'
    public static let PREFERENCE = 'preference'
    public static let TASK = 'task'
    public static let DOC = 'doc'
    public static let KNOWLEDGE = 'knowledge'
    public static let SESSION = 'session'

    private static let CUSTOM = HashMap<Int64, ArrayList<String>>()

    public static func predefined(): ArrayList<String> {
        let kinds = ArrayList<String>()
        kinds.add(NOTE)
        kinds.add(FACT)
        kinds.add(PREFERENCE)
        kinds.add(TASK)
        kinds.add(DOC)
        kinds.add(KNOWLEDGE)
        kinds.add(SESSION)
        kinds
    }

    /** 预定义 + 该用户的自定义（去重、保序） */
    public static func all(userId: Int64): ArrayList<String> {
        let kinds = predefined()
        match(CUSTOM.get(userId)){
            case Some(custom) =>
                for(kind in custom){
                    if(!contains(kinds, kind)){
                        kinds.add(kind)
                    }
                }
            case None => ()
        }
        kinds
    }

    /** 新增自定义 kind；预定义或已存在返回 false；非法字符抛 IllegalArgumentException */
    public static func register(userId: Int64, kind: String): Bool {
        check(kind)
        if(contains(predefined(), kind)){
            return false
        }
        match(CUSTOM.get(userId)){
            case Some(custom) =>
                if(contains(custom, kind)){
                    return false
                }
                custom.add(kind)
            case None =>
                let custom = ArrayList<String>()
                custom.add(kind)
                CUSTOM[userId] = custom
        }
        true
    }

    /** 只删自己的自定义 kind；预定义抛异常；不存在或属于他人返回 false */
    public static func remove(userId: Int64, kind: String): Bool {
        if(contains(predefined(), kind)){
            throw IllegalArgumentException('predefined memory kind cannot be removed: ${kind}')
        }
        match(CUSTOM.get(userId)){
            case Some(custom) =>
                if(!contains(custom, kind)){
                    return false
                }
                let kept = ArrayList<String>()
                for(item in custom){
                    if(item != kind){
                        kept.add(item)
                    }
                }
                CUSTOM[userId] = kept
                true
            case None => false
        }
    }

    /**
     * 固定权重（§5.4）：人工记忆优先于自动记忆，不提供请求级/集合级覆盖。
     */
    public static func weightOf(kind: String): Float64 {
        if(kind == FACT || kind == PREFERENCE){
            1.0
        }else if(kind == NOTE){
            0.9
        }else if(kind == DOC || kind == KNOWLEDGE){
            0.8
        }else if(kind == TASK){
            0.6
        }else if(kind == SESSION){
            0.3
        }else{
            0.8
        }
    }

    public static func validate(userId: Int64, kind: String): Bool {
        if(contains(predefined(), kind)){
            return true
        }
        match(CUSTOM.get(userId)){
            case Some(custom) => contains(custom, kind)
            case None => false
        }
    }

    /**
     * 启动补种：预定义行已存在则跳过，缺了才插。
     * 幂等由 `has` 保证：重复调用不会产生重复行。
     */
    public static func seed(persistence: KindPersistence): Unit {
        for(kind in predefined()){
            if(!persistence.has(kind)){
                persistence.insert(kind, true)
            }
        }
    }

    /** 仅测试用 */
    public static func resetForTest(): Unit {
        CUSTOM.clear()
    }

    private static func check(kind: String): Unit {
        if(kind.isEmpty() || kind.size > 32){
            throw IllegalArgumentException('invalid memory kind: ${kind}')
        }
        for(index in 0..kind.size){
            let ch = kind[index]
            let ok = (ch >= b'a' && ch <= b'z') ||
                     (ch >= b'A' && ch <= b'Z') ||
                     (ch >= b'0' && ch <= b'9') ||
                     ch == b'_' || ch == b'-'
            if(!ok){
                throw IllegalArgumentException('invalid memory kind: ${kind}')
            }
        }
    }

    private static func contains(values: ArrayList<String>, target: String): Bool {
        for(value in values){
            if(value == target){
                return true
            }
        }
        false
    }
}
