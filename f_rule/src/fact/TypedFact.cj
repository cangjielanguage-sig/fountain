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

/**
 * 强类型事实适配器（`doc/02-fact-model.md` §3.2）。
 *
 * 不做字段拷贝，[get] 每次调用注册的 getter。因此**业务对象在事实生命周期内必须不可变**；
 * 可变对象需要在插入前用 `FactBase.assertCopy()` 转成 `DynamicFact`。
 */
public class TypedFact<T> <: Fact & HostFact & IdentifiedFact {
    /** 注册时的原对象引用，供宿主侧动作与 JIT 取值。 */
    public let value: T
    private let schema_: FactSchema<T>
    private let identity_: Int64

    public init(value: T, schema: FactSchema<T>) {
        this.value = value
        this.schema_ = schema
        this.identity_ = FactIdentity.next()
    }

    public prop identity: Int64 {
        get() {
            identity_
        }
    }

    /** 事实对应的 schema，供同一类型下按字段取证。 */
    public prop schema: FactSchema<T> {
        get() {
            schema_
        }
    }

    public prop typeTag: String {
        get() {
            schema_.typeTag
        }
    }

    public func get(field: String): ?Any {
        match (schema_.lookup(field)) {
            case Some(getter) => Some(getter(value))
            case None => None
        }
    }

    public func has(field: String): Bool {
        schema_.has(field)
    }

    public func hostObject(): Any {
        value
    }
}
