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
package f_jwt

import std.time.DateTime

public interface JwtIdCache<T> where T <: Equatable<T> {
    func put(id: T, expire: Duration): Unit
    func put(id: T, expireAt: DateTime): Unit
    func contains(id: T): Bool
    func remove(id: T): Unit
}

public class NoneJwtIdCache<T> <: JwtIdCache<T> where T <: Equatable<T> {
    public func put(id: T, expire: Duration): Unit {}
    public func put(id: T, expireAt: DateTime): Unit {}
    public func contains(id: T): Bool {
        false
    }
    public func remove(id: T): Unit {}
}
