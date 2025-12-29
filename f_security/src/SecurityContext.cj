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
package f_security

public struct SecurityContext<ID, U, P> where ID <: Hashable & Equatable<ID>, U <: BaseUserData<U> & DataFields<U>, P <: Principal<ID, P> & DataFields<P>{
    public SecurityContext(
        private let store: PrincipalStore<ID, P>,
        private let principalMaker: (BaseUserData<U>) -> ?P
    ){}
    public func login(data: BaseUserData<U>): ?P {
        if(let Some(principal) <- principalMaker(data)){
            store.store(principal)
            principal
        }else{
            None<P>
        }
    }
    public func get(id: ID): ?P {
        store.get(id)
    }
}

public interface BaseUserData<U> where U <: DataFields<U> & BaseUserData<U> {
    prop username: String
}
public interface UserNamePasswordUserData<U> <: BaseUserData<U> where U <: DataFields<U> & UserNamePasswordUserData<U>{
    prop password: String
}
public interface Principal<ID, P> where ID <: Hashable & Equatable<ID>, P <: Principal<ID, P> & DataFields<P> {
    prop id: ID
    prop username: String
}
public interface PrincipalStore<ID, P> where ID <: Hashable & Equatable<ID>, P <: Principal<ID, P> & DataFields<P> {
    func store(principal: P): Unit
    func get(id: ID): ?P
}