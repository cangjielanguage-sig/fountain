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
import std.reflect.TypeInfo

/**
 * 字段静态类型（`doc/02-fact-model.md` §3.1）。
 *
 * 只用于构建期校验与决策表单元格解析；运行期取值仍以 getter 的返回值类型为准。
 */
public enum FieldType <: ToString & Hashable & Equatable<FieldType> {
    | Scalar
    | Number
    | Text
    | `Bool`
    | Time
    | List
    | `Any`

    public func toString(): String {
        match (this) {
            case Scalar => "Scalar"
            case Number => "Number"
            case Text => "Text"
            case `Bool` => "Bool"
            case Time => "Time"
            case List => "List"
            case `Any` => "Any"
        }
    }

    public func hashCode(): Int64 {
        "fountain::f_rule.fact.FieldType.${this}".hashCode()
    }

    public operator func ==(other: FieldType): Bool {
        this.toString() == other.toString()
    }

    public operator func !=(other: FieldType): Bool {
        !(this == other)
    }
}

/**
 * 强类型事实的字段访问器注册表（`doc/02-fact-model.md` §3.1）。
 *
 * 不要求业务类实现 `Fact`：这里注册闭包，把任意类适配成事实。注册顺序决定 [names]，
 * 同一字段重复注册以最后一次为准（不重复计入 `names`）。
 *
 * [hostTypeName] 记录 `TypeInfo.of<T>().qualifiedName`，[hostSimpleName] 记录 `f_jit`
 * 注册表使用的简单类名；`JitExpression` 拼 lambda 时用后者，诊断与文档用前者。
 */
public class FactSchema<T> {
    private let typeTag_: String
    private let names_: ArrayList<String>
    private let getters_: HashMap<String, (T) -> Any>
    private let types_: HashMap<String, FieldType>
    private let hostName_: String
    private let hostSimple_: String

    public init(typeTag: String) {
        this.typeTag_ = typeTag
        this.names_ = ArrayList<String>()
        this.getters_ = HashMap<String, (T) -> Any>()
        this.types_ = HashMap<String, FieldType>()
        let info = TypeInfo.of<T>()
        this.hostName_ = info.qualifiedName
        this.hostSimple_ = info.name
    }

    /** 类型标签，规则与决策表中引用该类型时使用同一字符串。 */
    public prop typeTag: String {
        get() {
            typeTag_
        }
    }

    /** 宿主类的完全限定名，用于诊断与日志。 */
    public prop hostTypeName: String {
        get() {
            hostName_
        }
    }

    /** 宿主类的简单名，供 `f_jit` 脚本形参使用。 */
    public prop hostSimpleName: String {
        get() {
            hostSimple_
        }
    }

    /** 注册一个字段访问器，静态类型按 `Any` 处理。 */
    public func field(name: String, getter: (T) -> Any): FactSchema<T> {
        field(name, FieldType.`Any`, getter)
    }

    /** 注册字段访问器并声明静态类型，供构建期校验使用。 */
    public func field(name: String, fieldType: FieldType, getter: (T) -> Any): FactSchema<T> {
        if (!getters_.contains(name)) {
            names_.add(name)
        }
        getters_[name] = getter
        types_[name] = fieldType
        this
    }

    public func lookup(name: String): ?((T) -> Any) {
        getters_.get(name)
    }

    /** 未声明的字段按 `Any` 处理（与未显式声明类型的注册一致）。 */
    public func fieldType(name: String): FieldType {
        match (types_.get(name)) {
            case Some(t) => t
            case None => FieldType.`Any`
        }
    }

    public func names(): Array<String> {
        names_.toArray()
    }

    public func has(name: String): Bool {
        getters_.contains(name)
    }
}
