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
package fountain::f_rpc.base

import fountain::f_data.macros.*

@DataAssist[fields props]
public class RPCMessage {
    private static let EMPTY_META = unsafeZeroValue<ServiceMeta>()
    private var meta: ServiceMeta = EMPTY_META
    private var params: Array<DataAny> = []
    public init(){}
    public init(meta: ServiceMeta, params: Array<DataAny>){
        this.meta = meta
        this.params = params
    }
}
@DataAssist[fields props hash equal]
public class ServiceMeta {
    private var version: String = ''
    private var name: String = ''
    private var typeName: String = ''
    private var methodName: String = ''
    private var argTypeNames: Array<String> = []

    public init(){}
    public init(version: String, name: String, typeName: String, methodName: String, argTypeNames: Array<String>, exactlyVersion!: Bool = false){
        this.version = if(exactlyVersion || version == '*'){
            version
        }else{
            let v = version.split('.')
            '${v[0]}.${v[1]}'
        }
        this.name = name
        this.typeName = typeName
        this.methodName = methodName
        this.argTypeNames = argTypeNames
    }
    public init(version: String, name: String, typeName: TypeInfo, methodName: String, argTypeNames: Array<TypeInfo>, exactlyVersion!: Bool = false){
        this(version, name, typeName.qualifiedName, methodName, Array<String>(argTypeNames.size){i => argTypeNames[i].qualifiedName}, exactlyVersion: exactlyVersion)
    }
    @DataExclude[prop]
    private var trace_: String = ''
    public mut prop trace: String {
        get(){
            if(trace_.isEmpty()){
                trace_ = currentTrace()
            }
            trace_
        }
        set(value){
            currentTrace_.set(value)
            trace_ = value
        }
    }
    private static var currentTrace_ = ThreadLocal<String>()
    public static func currentTrace(): String {
        if(let Some(x) <- currentTrace_.get()){
            x
        }else{
            let id = MessageID().toString()
            currentTrace_.set(id)
            id
        }
    }
    public static func clearCurrentTrace(): Unit {
        currentTrace_.set(None)
    }
}