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
import std.sync.*

/** 流程状态（与 `llm_loom_flow.status` 一致） */
public struct LoomStatus {
    private init() {
    }

    public static const CLARIFYING = 'clarifying'
    public static const PENDING = 'pending'
    public static const COMPILED = 'compiled'
    public static const FAILED = 'failed'

    public static func valid(value: String): Bool {
        value == CLARIFYING || value == PENDING || value == COMPILED || value == FAILED
    }
}

/**
 * 一条流程定义的持久化形态（`llm_loom_flow` 的内存映射）。
 *
 * `JitFunction` 不可序列化，所以存的是**源码与状态**，重启后重新编译（§9.9）。
 */
public class LoomFlow {
    public let name: String
    public var description: String = ''
    public var planJson: String = ''
    public var flowSource: String = ''
    public var stepSources: HashMap<String, String> = HashMap<String, String>()
    public var status: String = LoomStatus.PENDING
    public var round: Int64 = 0
    public var questionsJson: String = ''
    public var tools: String = ''
    public var mcps: String = ''

    public init(name: String, description!: String = '') {
        if(name.trimAscii().isEmpty()){
            throw LoomException('loom flow name must not be blank')
        }
        this.name = name
        this.description = description
    }

    public func mark(status: String): Unit {
        if(!LoomStatus.valid(status)){
            throw LoomException('unknown loom status: ${status}')
        }
        this.status = status
    }
}

/** 流程定义的存储抽象：内存实现用于测试，PG/MySQL 由 DAO 实现 */
public interface LoomStore {
    func save(flow: LoomFlow): Unit
    func get(name: String): ?LoomFlow
    func list(offset: Int64, limit: Int64): ArrayList<LoomFlow>
    func remove(name: String): Bool
}

/** `synchronized` 的块是 Unit 语义，返回值用持有者带出（闭包不能捕获可变局部变量） */
class FlowBox {
    public var value: ?LoomFlow = None
}

class FlowListBox {
    public var value: ArrayList<LoomFlow> = ArrayList<LoomFlow>()
}

class BoolBox {
    public var value: Bool = false
}

class CountBox {
    public var value: Int64 = 0
}

/** 进程内存储（测试 / `llm_loomPersist=false`） */
public class MemoryLoomStore <: LoomStore {
    private let mutex = Mutex()
    private var flows = HashMap<String, LoomFlow>()

    public init() {
    }

    public func save(flow: LoomFlow): Unit {
        synchronized(mutex){
            flows[flow.name] = flow
        }
    }

    public func get(name: String): ?LoomFlow {
        let box = FlowBox()
        synchronized(mutex){
            box.value = flows.get(name)
        }
        box.value
    }

    public func list(offset: Int64, limit: Int64): ArrayList<LoomFlow> {
        let box = FlowListBox()
        synchronized(mutex){
            let names = ArrayList<String>()
            for((name, _) in flows){
                names.add(name)
            }
            sortNames(names)
            var index = offset
            while(index < Int64(names.size) && Int64(box.value.size) < limit){
                match(flows.get(names[index])){
                    case Some(flow) => box.value.add(flow)
                    case None => ()
                }
                index++
            }
        }
        box.value
    }

    public func remove(name: String): Bool {
        let box = BoolBox()
        synchronized(mutex){
            if(flows.contains(name)){
                flows.remove(name)
                box.value = true
            }
        }
        box.value
    }

    internal static func sortNames(names: ArrayList<String>): Unit {
        for(index in 1..names.size){
            let current = names[index]
            var position = index - 1
            while(position >= 0 && names[position] > current){
                names[position + 1] = names[position]
                position--
            }
            names[position + 1] = current
        }
    }
}

/**
 * 流程注册表：内存态 + 可选持久化。
 *
 * 写操作同时落 store（若有）；`compiledFlows()` 供启动时重新编译（§9.9）。
 * 不缓存编译产物——`JitFunction` 与源码可能不一致，以源码为准。
 */
public class LoomRegistry {
    private let mutex = Mutex()
    private var flows = HashMap<String, LoomFlow>()
    private let store: ?LoomStore

    public init(store!: ?LoomStore = None) {
        this.store = store
    }

    public func put(flow: LoomFlow): Unit {
        synchronized(mutex){
            flows[flow.name] = flow
        }
        match(store){
            case Some(target) => target.save(flow)
            case None => ()
        }
    }

    public func get(name: String): ?LoomFlow {
        let box = FlowBox()
        synchronized(mutex){
            box.value = flows.get(name)
        }
        box.value
    }

    public func remove(name: String): Bool {
        let box = BoolBox()
        synchronized(mutex){
            if(flows.contains(name)){
                flows.remove(name)
                box.value = true
            }
        }
        if(box.value){
            match(store){
                case Some(target) => target.remove(name)
                case None => ()
            }
        }
        box.value
    }

    public func size(): Int64 {
        let box = CountBox()
        synchronized(mutex){
            box.value = Int64(flows.size)
        }
        box.value
    }

    /** 需要重新编译的流程（status=compiled） */
    public func compiledFlows(): ArrayList<LoomFlow> {
        let box = FlowListBox()
        synchronized(mutex){
            let names = ArrayList<String>()
            for((name, _) in flows){
                names.add(name)
            }
            MemoryLoomStore.sortNames(names)
            for(name in names){
                match(flows.get(name)){
                    case Some(flow) =>
                        if(flow.status == LoomStatus.COMPILED){
                            box.value.add(flow)
                        }
                    case None => ()
                }
            }
        }
        box.value
    }

    /** 从持久化层恢复（启动时调用一次） */
    public func restore(): Int64 {
        match(store){
            case Some(target) =>
                var count: Int64 = 0
                var offset: Int64 = 0
                let batch: Int64 = 100
                while(true){
                    let page = target.list(offset, batch)
                    if(page.isEmpty()){
                        break
                    }
                    for(flow in page){
                        synchronized(mutex){
                            flows[flow.name] = flow
                        }
                        count++
                    }
                    if(Int64(page.size) < batch){
                        break
                    }
                    offset += batch
                }
                count
            case None => 0
        }
    }
}
