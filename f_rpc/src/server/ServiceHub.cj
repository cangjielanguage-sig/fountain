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

import std.collection.{ArrayQueue, HashSet}
import std.collection.concurrent.ConcurrentHashMap
import std.env
import std.fs.File
import std.reflect.*

public struct ServiceHub {
    private init(){}
    private static let version = extractVersion()
    private static let exactlyVersion = ServerConfig.exactlyVersion
    private static let hub = ConcurrentHashMap<ServiceMeta, (String, Array<DataAny>) -> ToData>()
    public static func register<T>(funcName: String, argTypes: Array<TypeInfo>, fn: (String, Array<DataAny>) -> ToData): Unit where T <: Object {
        let classInfo = ClassTypeInfo.of<T>()
        let name = if(let Some(beanMeta) <- classInfo.findAnnotation<BeanMeta>()){
            beanMeta.name
        }else{
            ''
        }
        let argTypeNames = Array<String>(argTypes.size){i => argTypes[i].qualifiedName}
        let beanName = if(name.size > 0){
            name
        }else{
            '<UnspecifiedName>'
        }
        rpclog.debug{'[FOUNTAIN_RPC.${SKELETON}] [${beanName}(${version})]class-${classInfo.qualifiedName}.${funcName}${argTypeNames};${exactlyVersion}'}
        let types = HashSet<String>()
        let q = ArrayQueue<TypeInfo>()
        q.add(classInfo)
        while(let Some(t) <- q.remove()){
            if(let ti: InterfaceTypeInfo <- t){
                let hasFunc = try{
                    ti.getInstanceFunction(funcName, argTypes)
                }catch(_){
                    None<InstanceFunctionInfo>
                }.isSome()
                //如果在try块返回true，在catch块返回false，可能会由于getInstanceFunction的结果没有实际应用而被编译器剪枝。
                //并不确定是否发生这种情况，但是以防万一，而改为这种方式
                if(hasFunc){
                    types.add(ti.qualifiedName)//只要判定当前接口拥有这个函数声明，这个接口和之前遍历过的子接口都要注册这个函数
                    for(tin in types){
                        var meta = ServiceMeta(version, name, tin, funcName, argTypeNames, exactlyVersion: exactlyVersion)
                        let m1 = meta
                        rpclog.debug{'[FOUNTAIN_RPC.${SKELETON}] [${beanName}(${version})]interface-${tin}.${funcName}${argTypeNames};${hub.contains(m1)}'}
                        hub.addIfAbsent(meta, fn)
                        meta = ServiceMeta('*', name, tin, funcName, argTypeNames, exactlyVersion: exactlyVersion)
                        let m2 = meta
                        rpclog.debug{'[FOUNTAIN_RPC.${SKELETON}] [${beanName}(*)]interface-${tin}.${funcName}${argTypeNames};${hub.contains(m2)}'}
                        hub.addIfAbsent(meta, fn)
                        if(name.size != 0){
                            meta = ServiceMeta(version, '', tin, funcName, argTypeNames, exactlyVersion: exactlyVersion)
                            let m3 = meta
                            rpclog.debug{'[FOUNTAIN_RPC.${SKELETON}] [<NoName>(${version})]interface-${tin}.${funcName}${argTypeNames};${hub.contains(m3)}'}
                            hub.addIfAbsent(meta, fn)
                            meta = ServiceMeta('*', '', tin, funcName, argTypeNames, exactlyVersion: exactlyVersion)
                            let m4 = meta
                            rpclog.debug{'[FOUNTAIN_RPC.${SKELETON}] [<NoName>(*)]interface-${tin}.${funcName}${argTypeNames};${hub.contains(m4)}'}
                            hub.addIfAbsent(meta, fn)
                        }
                    }
                }
            }
            if(let cti: ClassTypeInfo <- t && cti != ClassTypeInfo.of<Object>() && let Some(sti) <- cti.superClass && sti != ClassTypeInfo.of<Object>() && sti != cti){
                q.add(sti)
            }
            func isNotStdInterface(sti: InterfaceTypeInfo){
                if(sti == TypeInfo.of<Any>() || sti == t){
                    return false
                }
                let qualifiedName = sti.qualifiedName
                !(qualifiedName.startsWith('std.') || qualifiedName.startsWith('fountain::') || 
                  qualifiedName.startsWith('Equatable') || qualifiedName.startsWith('Comparable') || 
                  qualifiedName.startsWith('Iterable') || qualifiedName.startsWith('Collection') || 
                  qualifiedName.startsWith('Equal') || qualifiedName.startsWith('NotEqual') ||
                  qualifiedName.startsWith('Less') || qualifiedName.startsWith('LessOrEqual') ||
                  qualifiedName.startsWith('Greater') || qualifiedName.startsWith('GreaterOrEqual'))
            }
            for(sti in t.superInterfaces where isNotStdInterface(sti)){
                q.add(sti)
            }
        }
    }
    internal static func call(message: RPCMessage): Data {
        let meta = message.meta
        hub[meta](meta.name, message.params).toData()
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