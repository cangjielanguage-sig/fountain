/*
    Copyright (c) [2022] [WuJingrun（吴京润）]
    fountain is licensed under Mulan PSL v2.
    You can use this software according to the terms and conditions of the Mulan PSL v2.
    You may obtain a copy of Mulan PSL v2 at:
            http://license.coscl.org.cn/MulanPSL2
    THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
    See the Mulan PSL v2 for more details.
*/
package f_base

import std.collection.concurrent.ConcurrentHashMap

public class TypeMemberInfos{
    private init(){}
    private static let staticPropertyMap = ConcurrentHashMap<TypeInfo, Map<String, StaticPropertyInfo>>()
    private static func getStaticPropertyMap(typeInfo: TypeInfo): Map<String, StaticPropertyInfo> {
        match(staticPropertyMap.get(typeInfo)){
                case Some(map) => map
                case _ =>
                    let map = HashMap<String, StaticPropertyInfo>()
                    staticPropertyMap[typeInfo] = map
                    for(p in typeInfo.staticProperties){
                        map[p.name] = p
                    }
                    map
            }
    }
    public static func staticProperties(typeInfo: TypeInfo): Collection<StaticPropertyInfo> {
        getStaticPropertyMap(typeInfo).values()
    }
    public static func staticProperty(typeInfo: TypeInfo, name: String): ?StaticPropertyInfo {
        getStaticPropertyMap(typeInfo).get(name)
    }

    private static let instancePropertyMap = ConcurrentHashMap<TypeInfo, Map<String, InstancePropertyInfo>>()
    private static func getInstancePropertyMap(typeInfo: TypeInfo): Map<String, InstancePropertyInfo> {
        match(instancePropertyMap.get(typeInfo)){
                case Some(map) => map
                case _ =>
                    let map = HashMap<String, InstancePropertyInfo>()
                    instancePropertyMap[typeInfo] = map
                    for(p in typeInfo.instanceProperties){
                        map[p.name] = p
                    }
                    map
            }
    }
    public static func instanceProperties(typeInfo: TypeInfo): Collection<InstancePropertyInfo> {
        getInstancePropertyMap(typeInfo).values()
    }
    public static func instanceProperty(typeInfo: TypeInfo, name: String): ?InstancePropertyInfo {
        getInstancePropertyMap(typeInfo).get(name)
    }

    private static let staticFunctionMap = ConcurrentHashMap<TypeInfo, Map<FuncMeta, StaticFunctionInfo>>()
    private static func getStaticFunctionMap(typeInfo: TypeInfo): Map<FuncMeta, StaticFunctionInfo> {
        match(staticFunctionMap.get(typeInfo)){
                case Some(map) => map
                case _ =>
                    let map = HashMap<FuncMeta, StaticFunctionInfo>()
                    staticFunctionMap[typeInfo] = map
                    for(f in typeInfo.staticFunctions){
                        let params = f.parameters
                        map[FuncMeta(f.name, Array<TypeInfo>(params.size){i =>
                            params[i].typeInfo
                        })] = f
                    }
                    map
            }
    }
    public static func staticFunctions(typeInfo: TypeInfo): Collection<StaticFunctionInfo> {
        getStaticFunctionMap(typeInfo).values()
    }
    public static func staticFunction(typeInfo: TypeInfo, name: String, paramTypes: Array<TypeInfo>): ?StaticFunctionInfo {
        getStaticFunctionMap(typeInfo).get(FuncMeta(name, paramTypes))
    }

    private static let instanceFunctionMap = ConcurrentHashMap<TypeInfo, Map<FuncMeta, InstanceFunctionInfo>>()
    private static func getInstanceFunctionMap(typeInfo: TypeInfo): Map<FuncMeta, InstanceFunctionInfo> {
        match(instanceFunctionMap.get(typeInfo)){
                case Some(map) => map
                case _ =>
                    let map = HashMap<FuncMeta, InstanceFunctionInfo>()
                    instanceFunctionMap[typeInfo] = map
                    for(f in typeInfo.instanceFunctions){
                        let params = f.parameters
                        map[FuncMeta(f.name, Array<TypeInfo>(params.size){i =>
                            params[i].typeInfo
                        })] = f
                    }
                    map
            }
    }
    public static func instanceFunctions(typeInfo: TypeInfo): Collection<InstanceFunctionInfo> {
        getInstanceFunctionMap(typeInfo).values()
    }
    public static func instanceFunction(typeInfo: TypeInfo, name: String, params: Array<TypeInfo>): ?InstanceFunctionInfo {
        getInstanceFunctionMap(typeInfo).get(FuncMeta(name, params))
    }


    private static let staticVariableMap = ConcurrentHashMap<TypeInfo, Map<String, StaticVariableInfo>>()
    private static func getStaticVariableMap(typeInfo: TypeInfo): Map<String, StaticVariableInfo> {
        match(staticVariableMap.get(typeInfo)){
                case Some(map) => map
                case _ =>
                    match(typeInfo) {
                        case x: StructTypeInfo =>
                            let map = HashMap<String, StaticVariableInfo>()
                            staticVariableMap[typeInfo] = map
                            for(v in x.staticVariables){
                                map[v.name] = v
                            }
                            map
                        case x: ClassTypeInfo =>
                            let map = HashMap<String, StaticVariableInfo>()
                            staticVariableMap[typeInfo] = map
                            for(v in x.staticVariables){
                                map[v.name] = v
                            }
                            map
                        case _ => EmptyMap<String, StaticVariableInfo>.INSTANCE
                    }
            }
    }
    public static func staticVariables(typeInfo: TypeInfo): Collection<StaticVariableInfo> {
        getStaticVariableMap(typeInfo).values()
    }
    public static func staticVariable(typeInfo: TypeInfo, name: String): ?StaticVariableInfo {
        getStaticVariableMap(typeInfo).get(name)
    }

    private static let instanceVariableMap = ConcurrentHashMap<TypeInfo, Map<String, InstanceVariableInfo>>()
    private static func getInstanceVariableMap(typeInfo: TypeInfo): Map<String, InstanceVariableInfo> {
        match(instanceVariableMap.get(typeInfo)){
                case Some(map) => map
                case _ =>
                    match(typeInfo) {
                        case x: StructTypeInfo =>
                            let map = HashMap<String, InstanceVariableInfo>()
                            instanceVariableMap[typeInfo] = map
                            for(v in x.instanceVariables){
                                map[v.name] = v
                            }
                            map
                        case x: ClassTypeInfo =>
                            let map = HashMap<String, InstanceVariableInfo>()
                            instanceVariableMap[typeInfo] = map
                            for(v in x.instanceVariables){
                                map[v.name] = v
                            }
                            map
                        case _ => EmptyMap<String, InstanceVariableInfo>.INSTANCE
                    }
            }
    }
    public static func instanceVariables(typeInfo: TypeInfo): Collection<InstanceVariableInfo> {
        getInstanceVariableMap(typeInfo).values()
    }
    public static func instanceVariable(typeInfo: TypeInfo, name: String): ?InstanceVariableInfo {
        getInstanceVariableMap(typeInfo).get(name)
    }
}
class FuncMeta <: Hashable & Equatable<FuncMeta> {
    private let hash: Int64
    FuncMeta(private let name: String, private let param: Array<TypeInfo>){
        let hasher = HashBuilder()
        hasher.append(name)
        hasher.append(param)
        hash = hasher.finish()
    }
    public operator func ==(other: FuncMeta) {
        hash == other.hash && name == other.name && param == other.param
    }
    public func hashCode(): Int64 {
        hash
    }
}
