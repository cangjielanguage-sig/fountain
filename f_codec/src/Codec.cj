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
package f_codec

public interface Encoder {
    func encode(data: Data): Encoder
    func encode<T>(data: T): Encoder where T <: ToData {
        encode(data.toData())
    }
    func encode(data: InputStream): Encoder
    func finish(): InputStream
    func encoder(): Encoder
}

public interface Decoder {
    func decode<T>(input: InputStream): ?T where T <: DataFields<T>
    func decoder(): Decoder
}

public interface Codec <: Encoder & Decoder {}
