# Security module
`fountain::f_security` helps maintain the login state

## STDX dependency

Configure the environment variable: `export CANGJIE_STDX_DYNAMIC_PATH=/path/to/dynamic_stdx`


## Basic types

```cj
public abstract class SecurityContext<ID, U, P, S> where ID <: Hashable & Equatable<ID>, U <: BaseUserData<U>, P <: Principal<ID, P> {
    /**
     * @param store Stores the login state
     * @param principalMaker Creates the login state; U is the user login type
     * @param check Checks the login state
     */
    public SecurityContext(
        protected let store: PrincipalStore<ID, P>,
        private let principalMaker: (U) -> ?P,
        public let check: (S) -> Bool
    ){}
    /**
     * Log in
     * @param data Login data
     * @return Login state
     */
    public func login(data: U): ?P 

    /**
     * Get the login state by user ID
     */
    public func get(id: ID): ?P 
    /**
     * Check and return the login state; S is the necessary data type for checking the login state
     */
    public func checkAndGet(s: S): ?P
}
```
### Login state of a user token
The credential is `(ID, String)` (user identifier + token), passed in by the caller after taking it from request parameters or similar.
```cj
public class UserTokenSecurityContext<ID, U> <: SecurityContext<ID, U, UserTokenPrincipal<ID>, (ID, String)> where ID <: Hashable & Equatable<ID>, U <: BaseUserData<U>
```
### User token in HTTP request headers
The credential is `Unit`; both the user identifier and the token come from the HTTP request headers.
```cj
public class HttpHeaderUserTokenSecurityContext<U> <: SecurityContext<String, U, UserTokenPrincipal<String>, Unit> where U <: BaseUserData<U>
```
### Login state passing a JWT in the http Authorization header
```cj
public class JWTSecurityContext<U> <: SecurityContext<String, U, JWTPrincipal<String>, Unit> where U <: BaseUserData<U>
```

### Login state
```cj
public interface Principal<ID, P> where ID <: Hashable & Equatable<ID>, P <: Principal<ID, P> {
    prop id: ID
    prop username: String
}
```
### Storing the login state
```cj
public interface PrincipalStore<ID, P> where ID <: Hashable & Equatable<ID>, P <: Principal<ID, P> {
    func store(principal: P): Unit
    func get(id: ID): ?P
    func remove(id: ID): ?P
}
```
#### Login state in a heap cache
```cj
public struct HeapCacheStore<ID, P> <: PrincipalStore<ID, P> where ID <: Hashable & Equatable<ID> & ToString, P <: Object & Principal<ID, P>
```
##### JWT login state
```cj
public type JWTHeapCacheStore = HeapCacheStore<String, JWTPrincipal<String>> {
    /**
     * How long the login state is kept
     */
    public init(maxLife: Duration)
    public func store(principal: P): Unit 
    public func get(id: ID): ?P 
    public func remove(id: ID): ?P
}
```
```cj
public open class JWTPrincipal<ID> <: Principal<ID, JWTPrincipal<ID>> where ID <: Hashable & Equatable<ID> {
    public JWTPrincipal(
        private let uid: ID,//User ID
        private let name: String,//User name
        public let key: String//Signing key
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
```
##### Login state of a user ID and token
```cj
public struct UserTokenHeapCacheStore<ID> <: PrincipalStore<ID, UserTokenPrincipal<ID>> where ID <: Hashable & Equatable<ID> & ToString {
    /**
     * How long the login state is kept
     */
    public init(maxLife: Duration)
    public func store(principal: UserTokenPrincipal<ID>): Unit 
    public func get(id: ID): ?UserTokenPrincipal<ID> 
    public func remove(id: ID): ?UserTokenPrincipal<ID>
}
```

### Basic user data
```cj
public interface BaseUserData<U> where U <: BaseUserData<U> {
    prop username: String
}
```


## Example

```cj
public class UserSessionCache {
    private static let context = JWTSecurityContext<String>(JWTHeapCacheStore(Duration.hour),{id => 
        JWTPrincipal<String>(id, '', UUID.random().toHexString())
    }){verifier, principal => 
        hmacKey(verifier, principal)
    }
    private static func keyId(principal: JWTPrincipal<String>){
        principal.key.unsafeBytes()
    }
    private static func hmacKey<T>(jwt: T, principal: JWTPrincipal<String>): T where T <: JWT {
        hmacKey(jwt, keyId(principal))
    }
    private static func hmacKey<T>(jwt: T, key: Array<Byte>): T where T <: JWT {
        jwt.hmacMD5(key)
    }
    private static let expire = Duration.hour
    private init(){}
    public static func generate(userId: Int64): String {
        let uids = userId.toString()
        let principal = context.login(uids).getOrThrow{SecurityException()}
        hmacKey(JWT.encoder(), principal).keyId(uids).expire(expire).sign()
    }

    public static func verify(): Bool {
        let v = context.check(())
        v
    }
}
```
