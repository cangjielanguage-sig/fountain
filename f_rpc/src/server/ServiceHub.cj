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
    private static let version = extractVersion()
    private static let exactlyVersion = ServerConfig.exactlyVersion
    private static let hub = ConcurrentHashMap<ServiceMeta, (String, Array<Data>) -> ToData>()
    public static func register<T>(funcName: String, argTypes: Array<TypeInfo>, fn: (String, Array<Data>) -> ToData): Unit where T <: Object {
        let classInfo = ClassTypeInfo.of<T>()
        let name = if(let Some(beanMeta) <- classInfo.findAnnotation<BeanMeta>()){
            beanMeta.name
        }else{
            ''
        }
        let argTypeNames = Array<String>(argTypes.size){i => argTypes[i].qualifiedName}
        rpclog.debug{'[FOUNTAIN_RPC.${SKELETON}] [${name}(${version})]class-${classInfo}.${funcName}${argTypeNames};${exactlyVersion}'}
        let q = ArrayQueue<TypeInfo>()
        q.add(classInfo)
        while(let Some(t) <- q.remove()){
            if(let ti: InterfaceTypeInfo <- t){
                let hasFunc = try{
                    ti.findInstanceFunction(funcName, argTypes)
                    true
                }catch(_){
                    false
                }
                if(hasFunc){
                    let meta = ServiceMeta(version, name, ti.qualifiedName, funcName, argTypeNames, exactlyVersion: exactlyVersion)
                    rpclog.debug{'[FOUNTAIN_RPC.${SKELETON}] [${name}(${version})]interface-${ti}.${funcName}${argTypeNames}; ${hub.contains(meta)}'}
                    hub.addIfAbsent(meta, fn)
                }
            }
            if(let cti: ClassTypeInfo <- ti && cti != ClassTypeInfo.of<Object>() && let sti <- cti.superClass && sti != ClassTypeInfo.of<Object>() && sti != ti){
                q.add(sti)
            }
            func isNotStdInterface(sti: InterfaceTypeInfo){
                if(sti == TypeInfo.of<Any>() || sti == ti){
                    return false
                }
                let qualifiedName = sti.qualifiedName
                !(qualifiedName.startsWith('std.') || qualifiedName.startsWith('fountain::') || 
                  qualifiedName.startsWith('Equatable') || qualifiedName.startsWith('Comparable') || 
                  qualifiedName.startsWith('Iterable') || qualifiedName.startsWith('Collection') || 
                  qualifiedName.startsWith('Equal') || qualifiedName.startsWith('NotEqual') ||
                  qualifiedName.startsWith('Less') || qualifiedName.startsWith('LessOrEqual') ||
                  qualifiedName.startsWith('Greater') || qualifiedName.startsWith('GreaterOrEqual') ||
                  qualifiedName.startsWith('std.Equatable') || qualifiedName.startsWith('std.Comparable') || 
                  qualifiedName.startsWith('std.Equal') || qualifiedName.startsWith('std.NotEqual') ||
                  qualifiedName.startsWith('std.Less') || qualifiedName.startsWith('std.LessOrEqual') ||
                  qualifiedName.startsWith('std.Greater') || qualifiedName.startsWith('std.GreaterOrEqual') ||
                  qualifiedName.startsWith('std.Iterable') || qualifiedName.startsWith('std.Collection'))
            }
            for(sti in ti.superInterfaces where isNotStdInterface(sti)){
                q.add(sti)
            }
        }
    }
    internal static func call(message: RPCMessage): ToData {
        let meta = message.meta
        hub[meta](meta.name, message.params)
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