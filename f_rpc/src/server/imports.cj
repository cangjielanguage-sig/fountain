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
package fountain::f_rpc.server

import fountain::f_data.macros.*
internal import fountain::f_concurrent.ConcurrentHashSet
public import fountain::f_rpc.base.* //public import只能导入顶级公共声明，
internal import fountain::f_rpc.base.* //所以还需要internal import 导入同包的顶级非公共声明

internal const SKELETON = "Skeleton"
func errorLog(id: MessageID, command: Command, message: ErrorMessage): Unit {
    errorLog(id, SKELETON, command, message)
}
func debugLog<T>(id: MessageID, command: Command, message: () -> T): Unit where T <: ToData {
    debugLog(id, SKELETON, command, message)
}
func infoLog<T>(id: MessageID, command: Command, message: () -> T): Unit where T <: ToData {
    infoLog(id, SKELETON, command, message)
}
private let EMPTY_DATA_ANY = unsafeZeroValue<DataAny>()
@DataAssist[props fields]
public class LogMessage {
    public LogMessage(
        public let param: DataAny,
        public let result: DataAny,
        public let consumed: Duration
    ){}
    public init(){
        this(EMPTY_DATA_ANY, EMPTY_DATA_ANY, Duration.Zero)
    }
    protected static func new<T, R>(param: T, result: R, consumed: Duration): LogMessage where T <: ToData, R <: ToData {
        return LogMessage(DataAny.new(param), DataAny.new(result), consumed)
    }
}
@DataAssist[props fields]
public class ErrorMessage {
    public ErrorMessage(
        public let param: DataAny,
        public let error: String
    ){}
    public init(){
        this(EMPTY_DATA_ANY, "")
    }
    public init(error: String){
        this(EMPTY_DATA_ANY, error)
    }
    protected static func new<T>(param: T, error: String): ErrorMessage where T <: ToData {
        return ErrorMessage(DataAny.new(param), error)
    }
}