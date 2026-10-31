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

/**
 * 源位置：1-based 的行列号。
 *
 * 不提供字节偏移——`TextReader` 不暴露底层字节位置，硬算出来的值跨缓冲边界就是错的。
 */
public struct SourcePosition <: ToString {
    public let line: Int64
    public let column: Int64

    public init(line: Int64, column: Int64) {
        this.line = line
        this.column = column
    }

    public func toString(): String {
        "第 ${line} 行第 ${column} 列"
    }
}

/**
 * 限定名：`prefix` + `local` + 命名空间 URI。
 *
 * 比较按**展开名**（`uri + local`），不按字面名——`<a xmlns:p="u" xmlns:q="u" p:x="1" q:x="2"/>`
 * 的两个 `x` 字面名不同、展开名相同，属于重复属性。
 */
public struct QName <: Equatable<QName> & ToString {
    /** 未加前缀时为 `None`。 */
    public let prefix: ?String

    public let local: String

    /** 未绑定命名空间时为 `None`。 */
    public let uri: ?String

    public init(local: String, prefix!: ?String = None, uri!: ?String = None) {
        this.local = local
        this.prefix = prefix
        this.uri = uri
    }

    /** 展开名比较：`uri` 与 `local` 相同即相等，前缀不参与。 */
    public operator func ==(that: QName): Bool {
        this.local == that.local && this.uri == that.uri
    }

    /** 字面名：有前缀时为 `prefix:local`。 */
    public func toString(): String {
        match (this.prefix) {
            case Some(p) => '${p}:${this.local}'
            case None => this.local
        }
    }
}

/** 元素上的一个属性。 */
public struct XmlAttribute <: ToString {
    public let name: QName
    public let value: String

    public init(name: QName, value: String) {
        this.name = name
        this.value = value
    }

    public func toString(): String {
        '${this.name}="${this.value}"'
    }
}
