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
package fountain::f_svg

import fountain::f_xml.QName

/** 元素上的一个属性。`name` 保留前缀与命名空间 URI。 */
public struct SvgAttribute <: Equatable<SvgAttribute> & ToString {
    public let name: QName
    public let value: String

    public init(name: QName, value: String) {
        this.name = name
        this.value = value
    }

    public func toString(): String {
        '${this.name}="${this.value}"'
    }

    public operator func ==(that: SvgAttribute): Bool {
        this.name == that.name && this.value == that.value
    }
}
