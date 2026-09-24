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

public enum EventType <: ToString & Hashable & Equatable<EventType> {
    | Start
    | Task
    | End
    | Error
    | Multi
    | Dummy

    public func toString(): String {
        match(this){
            case Start => "Start"
            case Task => "Task"
            case End => "End"
            case Error => "Error"
            case Multi => "Multi"
            case Dummy => "Dummy"
        }
    }
    public func hashCode(): Int64 {
        'fountain::f_egraph.base.EventType.${this}'.hashCode()
    }
    public operator func ==(other: EventType): Bool {
        match((this, other)){
            case (Start, Start) | (Task, Task) | (End, End) | (Error, Error) | (Multi, Multi) | (Dummy, Dummy) => true
            case _ => false
        }
    }
}