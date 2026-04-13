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
 
public open class Event <: ToString & Hashable & Equatable<Event> {
    private let hash: Int64
    public Event(
        public let eventType!: EventType,
        public let category!: String,
        public let tag!: String,
        public let name!: String,
        public let session!: String = UUID.random().toHexString()
    ){
        hash = HashBuilder().append(eventType).append(category).append(tag).append(name).build()
    }
    public operator func ==(other: Event): Bool {
        return hash == other.hash && eventType == other.eventType && category == other.category && 
                tag == other.tag && name == other.name
    }
    public func hashCode(): Int64 {
        return hash
    }
    public func toString(): String {
        return "Event(eventType: ${eventType}, category: ${category}, tag: ${tag}, name: ${name})"
    }
}

public open class DataEvent <: Event {
    public DataEvent (
        eventType!: EventType,
        category!: String,
        tag!: String,
        name!: String,
        session!: String = UUID.random().toHexString(),
        public let data!: Any
    ) {
        super(eventType: eventType, category: category, tag: tag, name: name, session: session)
    }
    public func tryGet<T>(): ?T {
        data as T
    }
}
public class StartEvent <: DataEvent {
    public init(category!: String, tag!: String, name!: String, data!: Any, 
                session!: String = UUID.random().toHexString()){
        super(eventType: Start, category: category, tag: tag, name: name, data: data, session: session)
    }
}
public class EndEvent <: DataEvent {
    public init(category!: String, tag!: String, data!: Any,
                session!: String = UUID.random().toHexString()){
        super(eventType: End, category: category, tag: tag, name: EventType.End.toString(), data: data, session: session)
    }
}
public open class TaskEvent <: DataEvent {
    public init(category!: String, tag!: String, name!: String, data!: Any,
                session!: String = UUID.random().toHexString()){
        super(eventType: EventType.Task, category: category, tag: tag, name: name, data: data, session: session)
    }
}
public class ErrorEvent <: DataEvent {
    public init(category!: String, tag!: String, message!: String,
                session!: String = UUID.random().toHexString()){
        super(eventType: EventType.Error, category: category, tag: tag, name: EventType.Error.toString(), data: message, session: session)
    }
    public init(category!: String, tag!: String, error!: Exception, 
                session!: String = UUID.random().toHexString()){
        super(eventType: EventType.Error, category: category, tag: tag, name: EventType.Error.toString(), data: error, session: session)
    }
}
public class MultiEvent <: DataEvent {
    public init(category!: String, tag!: String, name!: String, events!: Iterable<Event>, 
                session!: String = UUID.random().toHexString()){
        super(eventType: EventType.Multi, category: category, tag: tag, name: name, data: events, session: session)
    }
}
public class DummyEvent <: Event {
    public static let instance = DummyEvent()
    private init(){
        super(eventType: EventType.Dummy, category: '', tag: '', name: '', session: '')
    }
}