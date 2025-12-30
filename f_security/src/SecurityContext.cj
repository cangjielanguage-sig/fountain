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

public abstract class SecurityContext<ID, U, P, S> where ID <: Hashable & Equatable<ID>, U <: BaseUserData<U>, P <: Principal<ID, P> {
    public SecurityContext(
        protected let store: PrincipalStore<ID, P>,
        private let principalMaker: (BaseUserData<U>) -> ?P,
        protected let check: (S) -> Bool
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
    public func checkAndGet(s: S): ?P
}
public class UserTokenSecurityContext<ID, U> <: SecurityContext<ID, U, UserTokenPrincipal<ID>, (ID, String)> where ID <: Hashable & Equatable<ID>, U <: BaseUserData<U>{
    public init(
        store: PrincipalStore<ID, UserTokenPrincipal<ID>>,
        principalMaker: (BaseUserData<U>) -> ?UserTokenPrincipal<ID>
    ){
        super(store, principalMaker){tpl => 
            if(let Some(p) <- store.get(tpl[0]) && p.token == tpl[1]){
                true
            }else{
                false
            }
        }
    }
    public func checkAndGet(s: (ID, String)): ?UserTokenPrincipal<ID> {
        checkAndGet(s[0], s[1])
    }
    public func checkAndGet(id: ID, token: String): ?UserTokenPrincipal<ID> {
        if(check((id, token))){
            get(id)
        }else{
            None
        }
    }
}
public class HttpHeaderUserTokenSecurityContext<U> <: SecurityContext<String, U, UserTokenPrincipal<String>, Unit> where U <: BaseUserData<U>{
    private let userIdHeader: String
    private let tokenHeader: String
    public init(
        userIdHeader: String,
        tokenHeader: String,
        store: PrincipalStore<String, UserTokenPrincipal<String>>,
        principalMaker: (BaseUserData<U>) -> ?UserTokenPrincipal<String>
    ){
        super(store, principalMaker){_ => 
            let headers = CurrentHttpContext.instance.request.headers
            if(let Some(token) <- headers.getFirst(tokenHeader) && let Some(p) <- getPricinpal(userIdHeader, tokenHeader, store) && p.token == token){
                true
            }else{
                false
            }
        }
        this.userIdHeader = userIdHeader
        this.tokenHeader = tokenHeader
    }
    private static func getPricinpal(userIdHeader: String, tokenHeader: String, store: PrincipalStore<String, UserTokenPrincipal<String>>): ?UserTokenPrincipal<String> {
        let headers = CurrentHttpContext.instance.request.headers
        if(let Some(uid) <- headers.getFirst(userIdHeader) && let Some(token) <- headers.getFirst(tokenHeader)){
            store.get(uid)
        }else{
            None
        }
    }
    public func checkAndGet(_: Unit): ?UserTokenPrincipal<String> {
        checkAndGet()
    }
    public func checkAndGet(): ?UserTokenPrincipal<String> {
        if(check(())){
            let headers = CurrentHttpContext.instance.request.headers
            if(let Some(uid) <- headers.getFirst(userIdHeader)){
                return get(uid)
            }
        }
        None
    }
}
public class JWTSecurityContext<U> <: SecurityContext<String, U, JWTPrincipal<String>, Unit> where U <: BaseUserData<U> {
    public init(
        store: PrincipalStore<String, JWTPrincipal<String>>,
        principalMaker: (BaseUserData<U>) -> ?JWTPrincipal<String>,
        check: (JWTVerifier, JWTPrincipal<String>) -> Bool
    ){
        super(store, principalMaker){_ =>
            let headers = CurrentHttpContext.instance.request.headers
            let jwt = if(let Some(header) <- headers.getFirst('Authorization')){
                if(header.startsWith('Bearer ')){
                    header['Bearer '.size ..]
                }else{
                    header
                }
            }else{
                ''
            }
            if(jwt.size > 0){
                let verifier = JWT.verifier(jwt)
                if(let Some(userId) <- verifier.getKeyId() && userId.size > 0 && 
                let Some(principal) <- store.get(userId)){
                    return check(verifier, principal)
                }
            }
            false
        }
    }
    private static func getPricinpal(store: PrincipalStore<String, JWTPrincipal<String>>): ?JWTPrincipal<String> {
        let headers = CurrentHttpContext.instance.request.headers
        let jwt = if(let Some(header) <- headers.getFirst('Authorization')){
            if(header.startsWith('Bearer ')){
                header['Bearer '.size ..]
            }else{
                header
            }
        }else{
            ''
        }
        if(jwt.size > 0){
            let verifier = JWT.verifier(jwt)
            if(let Some(userId) <- verifier.getKeyId() && userId.size > 0){
                return store.get(userId)
            }
        }
        None
    }
    public func checkAndGet(_: Unit): ?JWTPrincipal<String> {
        checkAndGet()
    }
    public func checkAndGet(): ?JWTPrincipal<String> {
        if(check(())){
            return getPricinpal(store)
        }
        None
    }
}

public interface BaseUserData<U> where U <: BaseUserData<U> {
    prop username: String
}
public interface UserNamePasswordUserData<U> <: BaseUserData<U> where U <: UserNamePasswordUserData<U>{
    prop password: String
}
public interface Principal<ID, P> where ID <: Hashable & Equatable<ID>, P <: Principal<ID, P> {
    prop id: ID
    prop username: String
}
public struct UserTokenPrincipal<ID> <: Principal<ID, UserTokenPrincipal<ID>> where ID <: Hashable & Equatable<ID> {
    public UserTokenPrincipal(
        private let uid: ID,
        private let name: String,
        public let token: String
    ){}
    public prop id: ID {
        get(){
            uid
        }
    }
    public prop username: String {
        get(){
            name
        }
    }
}
public struct JWTPrincipal<ID> <: Principal<ID, JWTPrincipal<ID>> where ID <: Hashable & Equatable<ID> {
    public JWTPrincipal(
        private let uid: ID,
        private let name: String,
        public let key: String
    ){}
    
    public prop id: ID {
        get(){
            uid
        }
    }
    public prop username: String {
        get(){
            name
        }
    }
}
public interface PrincipalStore<ID, P> where ID <: Hashable & Equatable<ID>, P <: Principal<ID, P> {
    func store(principal: P): Unit
    func get(id: ID): ?P
}