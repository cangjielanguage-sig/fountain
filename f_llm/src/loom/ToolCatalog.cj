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

import std.collection.*

import fountain::f_data.*

import fountain::f_llm.tool.*

/** 工具元数据：名称 + 描述 + 相关度得分 */
public class ToolEntry {
    public let name: String
    public let description: String
    public let score: Int64

    public init(name: String, description: String, score!: Int64 = 0) {
        this.name = name
        this.description = description
        this.score = score
    }
}

/**
 * 工具目录：直接以 `FunctionMediator` 里已注册的元数据为索引源，不另建存储。
 *
 * 这样「注册了什么」与「能被检索到什么」永远一致；代价是每次检索都读一遍
 * `definition(name)`（纯内存 JSON，量级在几十个工具时可接受）。
 */
public class ToolCatalog {
    private init() {
    }

    public static func entries(): ArrayList<ToolEntry> {
        let result = ArrayList<ToolEntry>()
        for(name in FunctionMediator.names()){
            result.add(ToolEntry(name, descriptionOf(name)))
        }
        result
    }

    /** 关键词检索：命中名称或描述，按命中次数排序 */
    public static func search(query: String, topK!: Int64 = 5): ArrayList<ToolEntry> {
        let keyword = query.trimAscii().toAsciiLower()
        let result = ArrayList<ToolEntry>()
        if(keyword.isEmpty()){
            return result
        }
        for(item in entries()){
            let score = scoreOf(item, keyword)
            if(score > 0){
                result.add(ToolEntry(item.name, item.description, score: score))
            }
        }
        sortDesc(result)
        if(topK > 0 && Int64(result.size) > topK){
            let trimmed = ArrayList<ToolEntry>()
            for(index in 0..topK){
                trimmed.add(result[index])
            }
            return trimmed
        }
        result
    }

    private static func scoreOf(entry: ToolEntry, keyword: String): Int64 {
        var score: Int64 = 0
        if(entry.name.toAsciiLower().contains(keyword)){
            score += 3
        }
        if(entry.description.toAsciiLower().contains(keyword)){
            score += 1
        }
        score
    }

    private static func sortDesc(items: ArrayList<ToolEntry>): Unit {
        for(index in 1..items.size){
            let current = items[index]
            var position = index - 1
            while(position >= 0 && items[position].score < current.score){
                items[position + 1] = items[position]
                position--
            }
            items[position + 1] = current
        }
    }

    private static func descriptionOf(name: String): String {
        let definition = FunctionMediator.definition(name)
        match(definition.get('function')){
            case Some(fn) =>
                match(fn as JsonObject){
                    case Some(body) =>
                        match(body.get('description')){
                            case Some(text) =>
                                match(text as JsonString){
                                    case Some(value) => value.value
                                    case None => ''
                                }
                            case None => ''
                        }
                    case None => ''
                }
            case None => ''
        }
    }
}
