/*
Copyright (c) 2025 WuJingrun（吴京润）

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
package f_base

public func stringJoin<T>(parts: Array<T>, delimiter!: String = '', leftPadding!: String = '',
    rightPadding!: String = ''): String where T <: ToString {
    stringJoin<T, Array<T>>(parts, delimiter: delimiter, leftPadding: leftPadding, rightPadding: rightPadding)
}

public func stringJoin<T, C>(parts: C, delimiter!: String = '', leftPadding!: String = '', rightPadding!: String = ''): String where T <: ToString,
    C <: Iterable<T> {
    let builder = StringGenerator()
    builder.append(leftPadding)
    var i = 0
    for (p in parts) {
        if (i > 0) {
            builder.append(delimiter)
        }
        builder.append(p)
        i++
    }
    builder.append(rightPadding)
    builder.toString()
}
