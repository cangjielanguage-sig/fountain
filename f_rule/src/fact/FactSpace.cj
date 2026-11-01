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
package fountain::f_rule.fact

import std.collection.{ArrayList, HashMap}
import fountain::f_rule.exception.*

/**
 * 单个 `typeTag` 的类型描述（`doc/02-fact-model.md` §6.2）。
 *
 * 只存元信息，不存事实实例；`TypedFact` 的取值闭包留在 `FactSchema` 里。
 * `hostTypeName` 对动态类型为空串。
 */
public class TypeDescriptor {
    public let typeTag: String
    public let hostTypeName: String
    /** 宿主类简单名（`f_jit` 注册表口径）；动态类型为空串。 */
    public let hostSimpleName: String
    private let names_: ArrayList<String>
    private let types_: HashMap<String, FieldType>

    init(typeTag: String, hostTypeName: String, hostSimpleName: String, names: Array<String>,
        types: HashMap<String, FieldType>) {
        this.typeTag = typeTag
        this.hostTypeName = hostTypeName
        this.hostSimpleName = hostSimpleName
        this.names_ = ArrayList<String>()
        for (name in names) {
            this.names_.add(name)
        }
        this.types_ = types
    }

    public func fieldNames(): Array<String> {
        names_.toArray()
    }

    public func fieldTypes(): HashMap<String, FieldType> {
        let copy = HashMap<String, FieldType>()
        for ((name, t) in types_) {
            copy[name] = t
        }
        copy
    }

    public func fieldType(field: String): ?FieldType {
        types_.get(field)
    }

    /** 字段集合与类型完全一致；用于重复注册的一致性判定。 */
    func sameShape(names: Array<String>, types: HashMap<String, FieldType>): Bool {
        if (names_.size != names.size || types_.size != types.size) {
            return false
        }
        for (name in names_.toArray()) {
            let left = types_.get(name)
            let right = types.get(name)
            match ((left, right)) {
                case (Some(l), Some(r)) =>
                    if (l != r) {
                        return false
                    }
                case _ => return false
            }
        }
        true
    }
}

/**
 * 事实库命名空间（`doc/02-fact-model.md` §6.2）。
 *
 * 一条规则绑定一个空间；相同 id 即共享事实与网络分片，不同 id 完全隔离。
 * `"default"` 为保留 id。冻结后类型描述只读，运行期新增抛 `NETWORK_FROZEN`。
 */
public class FactSpace {
    private let id_: String
    private let descriptors_: HashMap<String, TypeDescriptor>
    private let order_: ArrayList<String>
    private var frozen_: Bool

    public init(id: String) {
        this.id_ = id
        this.descriptors_ = HashMap<String, TypeDescriptor>()
        this.order_ = ArrayList<String>()
        this.frozen_ = false
    }

    public prop id: String {
        get() {
            id_
        }
    }

    public prop frozen: Bool {
        get() {
            frozen_
        }
    }

    /** 注册强类型事实；同一 `typeTag` 字段声明不一致时抛 `DUPLICATE_TYPE`。 */
    public func register<T>(schema: FactSchema<T>): FactSpace {
        ensureMutable()
        let types = HashMap<String, FieldType>()
        for (name in schema.names()) {
            types[name] = schema.fieldType(name)
        }
        addDescriptor(TypeDescriptor(schema.typeTag, schema.hostTypeName, schema.hostSimpleName,
            schema.names(), types))
        this
    }

    /** 注册动态类型：只声明字段名与类型，不绑定宿主类。 */
    public func registerDynamic(typeTag: String, fields: Array<(String, FieldType)>): FactSpace {
        ensureMutable()
        let names = ArrayList<String>()
        let types = HashMap<String, FieldType>()
        for ((name, fieldType) in fields) {
            names.add(name)
            types[name] = fieldType
        }
        addDescriptor(TypeDescriptor(typeTag, "", "", names.toArray(), types))
        this
    }

    public func hasType(typeTag: String): Bool {
        descriptors_.contains(typeTag)
    }

    /** 未注册类型返回空数组。 */
    public func fieldNames(typeTag: String): Array<String> {
        match (descriptors_.get(typeTag)) {
            case Some(desc) => desc.fieldNames()
            case None => Array<String>()
        }
    }

    public func fieldType(typeTag: String, field: String): ?FieldType {
        match (descriptors_.get(typeTag)) {
            case Some(desc) => desc.fieldType(field)
            case None => None
        }
    }

    /** 未注册类型返回空表，便于校验器统一处理。 */
    public func fieldTypes(typeTag: String): HashMap<String, FieldType> {
        match (descriptors_.get(typeTag)) {
            case Some(desc) => desc.fieldTypes()
            case None => HashMap<String, FieldType>()
        }
    }

    public func descriptor(typeTag: String): ?TypeDescriptor {
        descriptors_.get(typeTag)
    }

    public func typeTags(): Array<String> {
        order_.toArray()
    }

    /** 冻结类型描述；可重复调用。 */
    public func freeze(): Unit {
        frozen_ = true
    }

    private func addDescriptor(desc: TypeDescriptor): Unit {
        match (descriptors_.get(desc.typeTag)) {
            case Some(existing) =>
                if (!existing.sameShape(desc.fieldNames(), desc.fieldTypes())) {
                    throw RuleException(
                        RuleErrorCode.DUPLICATE_TYPE,
                        "空间 ${id_} 的类型 ${desc.typeTag} 被不一致的字段声明重复注册"
                    )
                }
            case None =>
                descriptors_[desc.typeTag] = desc
                order_.add(desc.typeTag)
        }
    }

    private func ensureMutable(): Unit {
        if (frozen_) {
            throw RuleException(
                RuleErrorCode.NETWORK_FROZEN,
                "空间 ${id_} 已冻结，不能新增类型或空间"
            )
        }
    }
}
