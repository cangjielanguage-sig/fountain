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
package fountain::f_rpc

import fountain::f_data.macros.*

@DataAssist[fields props]
public class RPCMessage {
    private let meta: ServiceMeta = ServiceMeta()
    private var params: Array<Data> = [] 
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
        this.version = if(exactlyVersion){
            version
        }else{
            let v = version.split('.')
            '${v[0].v[1]}'
        }
        this.name = name
        this.typeName = typeName
        this.methodName = methodName
        this.argTypeNames = argTypeNames
    }
    public init(version: String, name: String, typeName: TypeInfo, methodName: String, argTypeNames: Array<TypeInfo>, exactlyVersion!: Bool = false){
        this(version, name, typeName, methodName, Array<String>(argTypeNames.size){i => argTypeNames[i].qualifiedName}, exactlyVersion: exactlyVersion)
    }
}