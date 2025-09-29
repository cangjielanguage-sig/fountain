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

import std.collection.ArrayList

public class StringGenerator <: ToString {
    private let utf8 = ArrayList<Byte>()

    public init() {}
    public init(s: String) {
        append(s)
    }

    public prop size: Int64 {
        get() {
            utf8.size
        }
    }
    public func reset(): This {
        utf8.clear()
        this
    }

    private func checkIndex(fromIndex: Int64, toIndex: Int64) {
        if (fromIndex < 0 || fromIndex > size || toIndex < fromIndex || toIndex > size) {
            throw IndexOutOfBoundsException('current size is ${size}, but fromIndex: ${fromIndex}, toIndex: ${toIndex}')
        }
    }
    public func append<T>(content: T): This where T <: ToString {
        utf8.add(all: content.toString().unsafeBytes())
        this
    }
    public func appendln<T>(content: T, nextLine!: String = OS.current.nextLine): This where T <: ToString {
        append<T>(content).append<String>(nextLine)
        this
    }
    private func indexOf(search: Array<Byte>, fromIndex: Int64): ?Int64 {
        utf8.unsafeData().indexOf(search, fromIndex)
    }
    public func indexOf<T>(content: T, fromIndex!: Int64 = 0): ?Int64 where T <: ToString {
        let search = content.toString().unsafeBytes()
        indexOf(search, fromIndex)
    }
    private func lastIndexOf(search: Array<Byte>, fromIndex: Int64): ?Int64 {
        let array = utf8.unsafeData()
        array.lastIndexOf(search, fromIndex)
    }
    public func lastIndexOf<T>(content: T, fromIndex!: Int64 = size): ?Int64 where T <: ToString {
        let search = content.toString().unsafeBytes()
        lastIndexOf(search, fromIndex)
    }
    public func contains<T>(content: T): Bool where T <: ToString {
        indexOf<T>(content).isSome()
    }
    public func removeFirst<T>(content: T, fromIndex!: Int64 = 0): This where T <: ToString {
        let bytes = content.toString().unsafeBytes()
        if (let Some(idx) <- indexOf(bytes, fromIndex)) {
            utf8.remove(idx..idx + bytes.size)
        }
        this
    }
    public func removeLast<T>(content: T, fromIndex!: Int64 = size): This where T <: ToString {
        let bytes = content.toString().unsafeBytes()
        if (let Some(idx) <- lastIndexOf(bytes, fromIndex)) {
            utf8.remove(idx..idx + bytes.size)
        }
        this
    }
    public func remove<T>(content: T, fromIndex!: Int64 = 0, toIndex!: Int64 = size): This where T <: ToString {
        checkIndex(fromIndex, toIndex)
        let search = content.toString().unsafeBytes()
        var fromIdx = fromIndex
        while (let Some(idx) <- indexOf(search, fromIdx) && idx < toIndex) {
            utf8.remove(idx..idx + search.size)
            fromIdx = idx
        }
        this
    }
    public func insert<T>(sub: T, at!: Int64): This where T <: ToString {
        utf8.add(all: sub.toString().unsafeBytes(), at: at)
        this
    }
    public func replace<O, T>(old: O, new: T, fromIndex!: Int64 = 0, toIndex!: Int64 = size): This where O <: ToString,
        T <: ToString {
        checkIndex(fromIndex, toIndex)
        let oldBytes = old.toString().unsafeBytes()
        let newBytes = new.toString().unsafeBytes()
        var fromIdx = fromIndex
        while (let Some(idx) <- indexOf(oldBytes, fromIdx) && idx < toIndex) {
            if (oldBytes.size == newBytes.size) {
                utf8.unsafeData()[idx..idx + oldBytes.size] = newBytes
            } else if (oldBytes.size < newBytes.size) {
                let utf8Bytes = utf8.unsafeData()
                utf8Bytes[idx..idx + oldBytes.size] = newBytes[0..oldBytes.size]
                utf8.add(all: newBytes[oldBytes.size..newBytes.size], at: idx + oldBytes.size)
            } else {
                let utf8Bytes = utf8.unsafeData()
                utf8Bytes[idx..idx + newBytes.size] = newBytes
                utf8.remove(idx + newBytes.size..idx + oldBytes.size)
            }
            fromIdx = idx + newBytes.size
        }
        this
    }
    public func replace<T>(new: T, fromIndex!: Int64 = 0, toIndex!: Int64 = size): This where T <: ToString {
        checkIndex(fromIndex, toIndex)
        let sub = new.toString().unsafeBytes()
        let replaced = toIndex - fromIndex
        let subSize = sub.size
        if (replaced < subSize) {
            utf8.unsafeData()[fromIndex..toIndex] = sub[0..replaced]
            utf8.add(all: sub[replaced..sub.size], at: toIndex)
        } else if (replaced > subSize) {
            utf8.unsafeData()[fromIndex..fromIndex + subSize] = sub
            utf8.remove(fromIndex + subSize..toIndex)
        } else {
            utf8.unsafeData()[fromIndex..toIndex] = sub
        }
        this
    }
    public func replaceFirst<O, T>(old: O, new: T, fromIndex!: Int64 = 0, toIndex!: Int64 = size): This where O <: ToString,
        T <: ToString {
        checkIndex(fromIndex, toIndex)
        let oldBytes = old.toString().unsafeBytes()
        let newBytes = new.toString().unsafeBytes()
        if (let Some(idx) <- indexOf(oldBytes, fromIndex) && idx < toIndex) {
            if (oldBytes.size == newBytes.size) {
                utf8.unsafeData()[idx..idx + oldBytes.size] = newBytes
            } else if (oldBytes.size < newBytes.size) {
                let utf8Bytes = utf8.unsafeData()
                utf8Bytes[idx..idx + oldBytes.size] = newBytes[0..oldBytes.size]
                utf8.add(all: newBytes[oldBytes.size..newBytes.size], at: idx + oldBytes.size)
            } else {
                let utf8Bytes = utf8.unsafeData()
                utf8Bytes[idx..idx + newBytes.size] = newBytes
                utf8.remove(idx + newBytes.size..idx + oldBytes.size)
            }
        }
        this
    }
    public func replaceLast<O, T>(old: O, new: T, fromIndex!: Int64 = 0, toIndex!: Int64 = size): This where O <: ToString,
        T <: ToString {
        checkIndex(fromIndex, toIndex)
        let oldBytes = old.toString().unsafeBytes()
        let newBytes = new.toString().unsafeBytes()
        if (let Some(idx) <- lastIndexOf(oldBytes, fromIndex) && idx < toIndex) {
            if (oldBytes.size == newBytes.size) {
                utf8.unsafeData()[idx..idx + oldBytes.size] = newBytes
            } else if (oldBytes.size < newBytes.size) {
                let utf8Bytes = utf8.unsafeData()
                utf8Bytes[idx..idx + oldBytes.size] = newBytes[0..oldBytes.size]
                utf8.add(all: newBytes[oldBytes.size..newBytes.size], at: idx + oldBytes.size)
            } else {
                let utf8Bytes = utf8.unsafeData()
                utf8Bytes[idx..idx + newBytes.size] = newBytes
                utf8.remove(idx + newBytes.size..idx + oldBytes.size)
            }
        }
        this
    }

    public func reverse(): This {
        let utf8 = this.utf8.unsafeData()
        var i = utf8.size
        for (rune in toString().runes()) {
            let runeBytes = rune.toString().unsafeBytes()
            utf8[i - runeBytes.size..i] = runeBytes
            i -= runeBytes.size
        }
        this
    }
    public func toString() {
        String.fromUtf8(utf8.unsafeData())
    }
    public unsafe func rawBytes() {
        utf8.getRawArray()
    }
    public func unsafeBytes(): Array<Byte> {
        utf8.unsafeData()
    }
}
