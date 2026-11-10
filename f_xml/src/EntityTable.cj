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
package fountain::f_xml

import std.collection.{ArrayList, HashMap}

/**
 * DTD 内部子集的实体表（普通 + 参数）与属性类型映射。
 *
 * 规则：
 * - 同名实体**第一个声明生效**，重复声明不报错；
 * - 外部实体（`SYSTEM` / `PUBLIC`）只记录声明，**引用即报错**，永不加载；
 * - 声明数超过 `maxDeclarations` 直接抛 `Declarations` 分类的异常；
 * - `attTypes` 只服务属性值规范化，不服务有效性（见 `AttTypeMap`）。
 */
internal class EntityTable {
    private let generalTable = HashMap<String, EntityDecl>()
    private let parameterTable = HashMap<String, EntityDecl>()
    private let ordered = ArrayList<EntityDecl>()
    private let limit: Int64
    /** `<!ATTLIST>` 的「元素字面名 → 属性名 → AttType」，仅用于属性值规范化。 */
    let attTypes = AttTypeMap()
    /** 内部子集里是否出现过参数实体引用（决定未声明实体能否按「外部声明」原谅）。 */
    var sawParameterRef = false

    init(limit: Int64) {
        this.limit = limit
    }

    func declare(decl: EntityDecl): Unit {
        let target = if (decl.parameter) { this.parameterTable } else { this.generalTable }
        if (target.contains(decl.name)) {
            return
        }
        if (this.ordered.size + 1 > this.limit) {
            throw XmlException(
                "实体声明数超过上限 ${this.limit}",
                0,
                0,
                kind: EntityLimitKind.Declarations
            )
        }
        target[decl.name] = decl
        this.ordered.add(decl)
    }

    func general(name: String): ?EntityDecl {
        this.generalTable.get(name)
    }

    func parameter(name: String): ?EntityDecl {
        this.parameterTable.get(name)
    }

    func declarations(): Array<EntityDecl> {
        this.ordered.toArray()
    }
}
