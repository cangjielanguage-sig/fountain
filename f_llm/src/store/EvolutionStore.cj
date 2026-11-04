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
import std.convert.*
import std.sync.*

import fountain::f_store.Store

/** 一条技能演进记录（独立表的一行） */
public class EvolutionEntry {
    public let id: Int64
    public let skillTitle: String
    /** evolved / created / rejected / skipped */
    public let action: String
    public let detail: String
    public let at: Int64

    public init(id: Int64, skillTitle: String, action: String, detail: String, at: Int64) {
        this.id = id
        this.skillTitle = skillTitle
        this.action = action
        this.detail = detail
        this.at = at
    }
}

/**
 * 技能演进报告表。
 *
 * 只按「技能 + 时间」查，不做向量检索——报告是审计数据，关键词/前缀足够；
 * 因此默认实现走 f_store（KV + 前缀扫描），不依赖 `f_hydra` 的向量能力。
 */
public interface EvolutionStore {
    /** @return 记录 id（`entry.id <= 0` 时自动分配） */
    func save(entry: EvolutionEntry): Int64
    func list(offset: Int64, limit: Int64): ArrayList<EvolutionEntry>
    func bySkill(skillTitle: String, limit: Int64): ArrayList<EvolutionEntry>
}

/** 内存实现：测试与零配置启动用 */
public class InMemoryEvolutionStore <: EvolutionStore {
    private let mutex = Mutex()
    private var entries = ArrayList<EvolutionEntry>()
    private var seq: Int64 = 0

    public init() {
    }

    public func save(entry: EvolutionEntry): Int64 {
        let box = IdBox()
        synchronized(mutex){
            var id = entry.id
            if(id <= 0){
                seq++
                id = seq
            }else if(id > seq){
                seq = id
            }
            entries.add(EvolutionEntry(id, entry.skillTitle, entry.action, entry.detail, entry.at))
            box.value = id
        }
        box.value
    }

    public func list(offset: Int64, limit: Int64): ArrayList<EvolutionEntry> {
        let box = EntryListBox()
        synchronized(mutex){
            // 最近的在前：按 at 倒序，同时间按 id 倒序
            let sorted = ArrayList<EvolutionEntry>()
            for(item in entries){
                sorted.add(item)
            }
            for(index in 1..sorted.size){
                let current = sorted[index]
                var position = index - 1
                while(position >= 0 && before(current, sorted[position])){
                    sorted[position + 1] = sorted[position]
                    position--
                }
                sorted[position + 1] = current
            }
            let page = ArrayList<EvolutionEntry>()
            var index = offset
            while(index < Int64(sorted.size) && Int64(page.size) < limit){
                page.add(sorted[index])
                index++
            }
            box.value = page
        }
        box.value
    }

    public func bySkill(skillTitle: String, limit: Int64): ArrayList<EvolutionEntry> {
        let result = ArrayList<EvolutionEntry>()
        for(entry in list(0, 1000)){
            if(Int64(result.size) >= limit){
                break
            }
            if(entry.skillTitle == skillTitle){
                result.add(entry)
            }
        }
        result
    }

    private static func before(left: EvolutionEntry, right: EvolutionEntry): Bool {
        if(left.at != right.at){
            return left.at > right.at
        }
        left.id > right.id
    }
}

/**
 * f_store 版报告表。
 *
 * 键布局（按字段拆分，避免把 detail 里的换行/分隔符再转义一遍）：
 *
 * ```
 * f_llm:evolution:index:{id}   → 空值，仅用于前缀扫描
 * f_llm:evolution:data:{id}    → skillTitle \u0003 action \u0003 at \u0003 detail
 * ```
 *
 * 记录只追加不改写，所以不需要事务；`id` 用「扫描到的最大 id + 1」分配，
 * 单进程写入足够（演进是低频批处理）。
 */
public class FStoreEvolutionStore <: EvolutionStore {
    private static const INDEX = 'f_llm:evolution:index:'
    private static const DATA = 'f_llm:evolution:data:'
    private static let SEP = String.fromUtf8([3u8])

    private let store: Store
    private let mutex = Mutex()
    private var nextId: Int64 = 0

    public init(path: String) {
        this.store = Store(path)
    }

    /** 容器用：路径取 `llm_metaStorePath`（与 `FStoreLoomStore` 同一份配置） */
    public init() {
        this.store = Store(DeployPaths.resolve(StoreSettings.load().metaStorePath))
    }

    public func save(entry: EvolutionEntry): Int64 {
        let box = IdBox()
        synchronized(mutex){
            var id = entry.id
            if(id <= 0){
                if(nextId <= 0){
                    nextId = maxId()
                }
                nextId++
                id = nextId
            }else if(id > nextId){
                nextId = id
            }
            let payload = '${entry.skillTitle}${SEP}${entry.action}${SEP}${entry.at}${SEP}${entry.detail}'
            store.add('${DATA}${id}'.toArray(), payload.toArray())
            store.add('${INDEX}${id}'.toArray(), '1'.toArray())
            box.value = id
        }
        box.value
    }

    public func list(offset: Int64, limit: Int64): ArrayList<EvolutionEntry> {
        let ids = ArrayList<Int64>()
        for((key, _) in store.prefix(INDEX.toArray())){
            let text = String.fromUtf8(key)
            if(text.size > INDEX.size){
                match(Int64.tryParse(text[INDEX.size..])){
                    case Some(value) => ids.add(value)
                    case None => ()
                }
            }
        }
        // 倒序：新记录在前
        sortDesc(ids)
        let result = ArrayList<EvolutionEntry>()
        var index = offset
        while(index < Int64(ids.size) && Int64(result.size) < limit){
            match(read(ids[index])){
                case Some(entry) => result.add(entry)
                case None => ()
            }
            index++
        }
        result
    }

    public func bySkill(skillTitle: String, limit: Int64): ArrayList<EvolutionEntry> {
        let result = ArrayList<EvolutionEntry>()
        for(entry in list(0, 1000)){
            if(Int64(result.size) >= limit){
                break
            }
            if(entry.skillTitle == skillTitle){
                result.add(entry)
            }
        }
        result
    }

    private func read(id: Int64): ?EvolutionEntry {
        match(store.get('${DATA}${id}'.toArray())){
            case Some(bytes) =>
                let parts = String.fromUtf8(bytes).split(SEP)
                if(parts.size < 4){
                    return None
                }
                let at = Int64.tryParse(parts[2]) ?? 0
                // detail 可能自身含分隔符：第 4 段起全部拼回去
                var detail = parts[3]
                for(index in 4..parts.size){
                    detail += SEP + parts[index]
                }
                Some(EvolutionEntry(id, parts[0], parts[1], detail, at))
            case None => None
        }
    }

    /** 倒序（选择排序，id 数量在千级以内） */
    private static func sortDesc(items: ArrayList<Int64>): Unit {
        for(left in 0..items.size){
            var largest = left
            for(right in left + 1..items.size){
                if(items[right] > items[largest]){
                    largest = right
                }
            }
            if(largest != left){
                let temp = items[left]
                items[left] = items[largest]
                items[largest] = temp
            }
        }
    }

    private func maxId(): Int64 {
        var max: Int64 = 0
        for((key, _) in store.prefix(INDEX.toArray())){
            let text = String.fromUtf8(key)
            if(text.size > INDEX.size){
                match(Int64.tryParse(text[INDEX.size..])){
                    case Some(value) =>
                        if(value > max){
                            max = value
                        }
                    case None => ()
                }
            }
        }
        max
    }
}

class IdBox {
    public var value: Int64 = 0
}

class EntryListBox {
    public var value: ArrayList<EvolutionEntry> = ArrayList<EvolutionEntry>()
}
