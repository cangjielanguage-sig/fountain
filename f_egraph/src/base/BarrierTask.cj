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
package fountain::f_egraph.base

public struct BarrierKey <: Hashable & Equatable<BarrierKey> {
    private let h: Int64
    public BarrierKey(
        public let category: String,
        public let tag: String,
        public let eventName: String,
        public let session: String
    ){
        h = HashBuilder().append(category).append(tag).append(eventName).append(session).build()
    }
    public func hashCode(): Int64 {
        h
    }
    public operator func ==(other: BarrierKey): Bool {
        h == other.h && category == other.category && tag == other.tag && 
        eventName == other.eventName && session == other.session
    }
}
/**
 * 事件标识做key的事件积累到指定数量，作为新事件一次发出
 */
public class BarrierTask<G> <: Task where G <: EndExecutorGetter{
    private let name_: String
    private let events_ = HashMap<String, String>()
    private let datas = ConcurrentHashMap<BarrierKey, ArrayList<Any>>()
    private let acceptable: Array<String>
    var flow: ?Flow<G> = None
    /**
     * @param name 任务名
     * @param events 可接收的和输出的事件，可接收的事件是元组的第一个元素，对应的发射事件是元组的第二个元素
     * @param count 触发一次输出的累计事件数量
     */
    public BarrierTask(
        name!: String,
        events!: Array<(String, String)>,
        private let count!: Int64
    ){
        this.name_ = name
        acceptable = Array<String>(events.size, repeat: '')
        for(i in 0 .. events.size){
            let e = events[i]
            this.events_[e[0]] = e[1]
            acceptable[i] = e[0]
        }
    }
    public prop name: String {
        get(){
            name_
        }
    }
    public prop acceptableEvents: Array<String> {
        get(){
            acceptable
        }
    }
    public func exec(e: Event): Event {
        let category = e.category
        let tag = e.tag
        let eventName = e.name
        let session = e.session
        let key = BarrierKey(category, tag, eventName, session)
        let list = if(let de: DataEvent <- e){
            let list = datas.computeIfAbsent(key){ArrayList<Any>()}
            list.add(de.data)
            list
        }else{
            throw GraphException("BarrierTask accepts only instance of DataEvent")
        }
        if(list.size >= count){
            flow?.emit(eventType: EventType.Task, name: events_[eventName], data: list)
        }
        DummyEvent.instance
    }
}
/*
public interface Task{
    prop name: String
    prop acceptableEvents: Array<String>
    func exec(e: Event): Event
}
*/