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

import std.collection.ArrayQueue
import std.collection.concurrent.ConcurrentHashMap
import std.env
import std.fs.File
import std.reflect.*

public struct ServiceHub {
    private static let hub = ConcurrentHashMap<ServiceMeta, (Array<Data>) -> Data>()

    public static func register<T>(funcName: String, argTypes: Array<TypeInfo>, fn: (String, Array<Data>) -> Data): Unit where T <: Object {
        let classInfo = ClassTypeInfo.of<T>()
        let version = extractVersion()
        let name = if(let Some(annotation) <- classInfo.findAnnotation<BeanMeta>()){
            annotation.name
        }else{
            ''
        }
        let argTypeNames = Array<String>(argTypes.size){i => argTypes[i].qualifiedName}
        let q = ArrayQueue<TypeInfo>()
        q.add(classInfo)
        while(let Some(ti) <- q.remove()){
            let typeInfo = ti.qualifiedName
            if(ti is InterfaceTypeInfo){
                let meta = ServiceMeta(version, name, typeInfo, funcName, argTypeNames)
                hub.addIfAbsent(meta, {args => 
                    fn(name, args)
                })
            }
            if(let cti: ClassTypeInfo <- ti && cti != ClassTypeInfo.of<Object>() && let sti <- cti.superClass && sti != ClassTypeInfo.of<Object>()){
                q.add(sti)
            }
            for(sti in ti.superInterfaces where sti != TypeInfo.of<Any>() && sti != ti){
                q.add(sti)
            }
        }
    }
    internal static func call(message: RPCMessage): Data {
        hub[message.meta](message.params)
    }
    internal static prop metas: Array<ServiceMeta> {
        get(){
            let itr = hub.iterator().map{e => e[0]}
            Array<ServiceMeta>(hub.size){_ => itr.next().getOrThrow()}
        }
    }
    private static func extractVersion(): String {
        let cjpm = 'cjpm.toml' |> env.getWorkingDirectory().join |> File.readFrom |> String.fromUtf8
        for(line in cjpm.lines()){
            let l = line.replace(' ', '').replace('\t', '')
            if(l.startsWith('version=')){
                return l['version='.size ..].trimAscii()
            }
        }
        throw RPCVersionException('There is no version in cjpm.toml which is in ${env.getWorkingDirectory()}')
    }
}
public class RPCVersionException <: BaseException {
    public init() {}

    public init(message: String) {
        super(message)
    }
    public init(caused: Exception) {
        super(caused)
    }
    public init(message: String, caused: Exception) {
        super(message, caused)
    }
}