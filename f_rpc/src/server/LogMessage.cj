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

// 不能用 unsafeZeroValue<DataAny>()：它是零值对象，JsonValue.from这样的反射式遍历会直接段错误，
// 而这里正是错误响应路径（ErrorMessage）要用的“空数据”
private let EMPTY_DATA_ANY = DataAny(DataNone.INSTANCE)
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
    protected static func new<T>(param: T, e: Exception): ErrorMessage where T <: ToData {
        // 堆栈长度不可预期，不能写进固定容量缓冲（曾把875B堆栈写进80B缓冲抛IndexOutOfBoundsException，
        // 结果错误响应本身失败、连接被重置，真正的异常原因反而丢失）
        var errmsg = 'An exception has occured:\n${e}\n'
        for (stack in e.getStackTrace()) {
            errmsg = errmsg + '        at ${stack.declaringClass}.${stack.methodName}(${stack.fileName}: ${stack.lineNumber})\n'
        }
        return ErrorMessage(DataAny.new(param), errmsg)
    }
}