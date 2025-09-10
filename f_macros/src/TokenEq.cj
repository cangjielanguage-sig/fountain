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
package f_macros

public interface TokensEq<T> where T <: TokensEq<T> {
    func equalsIgnorePos(other: T): Bool
}
extend Tokens <: TokensEq<Tokens> {
    public func equalsIgnorePos(other: Tokens): Bool {
        refEq(this, other) || 
        if (this.size == other.size) {
            for (i in 0..this.size where !this[i].equalsIgnorePos(other[i])) {
                return false
            }
            return true
        }else{
            false
        }
    }
}

public interface TokenEq<T> where T <: TokenEq<T> {
    func equalsIgnorePos(other: T): Bool
}
extend Token <: TokenEq<Token> {
    public func equalsIgnorePos(other: Token): Bool {
        this.kind == other.kind && this.value == other.value
    }
}