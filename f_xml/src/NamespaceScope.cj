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

import std.collection.ArrayList

/** XML 命名空间的固定 URI。 */
internal const XML_NS_URI: String = "http://www.w3.org/XML/1998/namespace"
/** `xmlns` 前缀本身绑定到该 URI，且不能作为元素 / 属性前缀。 */
internal const XMLNS_NS_URI: String = "http://www.w3.org/2000/xmlns/"

internal enum NsLookup {
    | Declared(String)
    | Reset
    | Missing
}

/** 一条命名空间绑定：`prefix = None` 表示默认命名空间；`uri = None` 表示 `xmlns=""` 重置。 */
internal struct NsBinding {
    let prefix: ?String
    let uri: ?String

    init(prefix: ?String, uri: ?String) {
        this.prefix = prefix
        this.uri = uri
    }
}

/**
 * 命名空间作用域栈。
 *
 * 进入元素时 `push()` 并压入本元素的 `xmlns` 声明，离开时 `pop()`。
 * 规则：
 * 1. `xml` 前缀固定绑定，无需声明；
 * 2. `xmlns` 不能作为元素 / 属性前缀；
 * 3. 未声明前缀报错，不静默当作无命名空间；
 * 4. 默认命名空间只作用于元素名，不作用于属性名；
 * 5. `xmlns=""` 重置默认命名空间。
 */
internal class NamespaceScope {
    private let stack = ArrayList<NsBinding>()
    private let marks = ArrayList<Int64>()

    func push(): Unit {
        this.marks.add(this.stack.size)
    }

    func pop(): Unit {
        let mark = this.marks.remove(at: this.marks.size - 1)
        while (this.stack.size > mark) {
            this.stack.remove(at: this.stack.size - 1)
        }
    }

    /** 记录一条声明；`prefix = None` 是默认命名空间，`uri = None` 是 `xmlns=""`。 */
    func declare(prefix: ?String, uri: ?String): Unit {
        this.stack.add(NsBinding(prefix, uri))
    }

    func lookup(prefix: String): NsLookup {
        if (prefix == "xml") {
            return NsLookup.Declared(XML_NS_URI)
        }
        var i = this.stack.size - 1
        while (i >= 0) {
            match (this.stack[i].prefix) {
                case Some(p) => if (p == prefix) {
                    return match (this.stack[i].uri) {
                        case Some(uri) => NsLookup.Declared(uri)
                        case None => NsLookup.Reset
                    }
                }
                case None => ()
            }
            i--
        }
        NsLookup.Missing
    }

    func lookupDefault(): NsLookup {
        var i = this.stack.size - 1
        while (i >= 0) {
            if (this.stack[i].prefix.isNone()) {
                return match (this.stack[i].uri) {
                    case Some(uri) => NsLookup.Declared(uri)
                    case None => NsLookup.Reset
                }
            }
            i--
        }
        NsLookup.Missing
    }

    /** 元素名的命名空间：无前缀时取默认命名空间（可能被 `xmlns=""` 重置）。 */
    func elementNamespace(prefix: ?String): NsLookup {
        match (prefix) {
            case Some(p) => lookup(p)
            case None => lookupDefault()
        }
    }

    /** 属性名的命名空间：**属性不受默认命名空间影响**。 */
    func attributeNamespace(prefix: String): NsLookup {
        lookup(prefix)
    }
}
