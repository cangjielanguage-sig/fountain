# 安全模块
`fountain::f_security` 用来帮助维持登录状态

## 基本类型
```cj
public abstract class SecurityContext<ID, U, P, S> where ID <: Hashable & Equatable<ID>, U <: BaseUserData<U>, P <: Principal<ID, P> {
    /**
     * @param store 储存登录状态
     * @param principalMaker 生成登录状态，U是用户登录类型
     * @param check 检查登录状态
     */
    public SecurityContext(
        protected let store: PrincipalStore<ID, P>,
        private let principalMaker: (U) -> ?P,
        public let check: (S) -> Bool
    ){}
    /**
     * 登录
     * @param data 登录数据
     * @return 登录状态
     */
    public func login(data: U): ?P 

    /**
     * 用户ID获取登录状态
     */
    public func get(id: ID): ?P 
    /**
     * 检查并返回登录状态，S是用来检查登录状态的必要数据类型
     */
    public func checkAndGet(s: S): ?P
}
```
### 用户http请求头传递的登录状态
```cj
public class UserTokenSecurityContext<ID, U> <: SecurityContext<ID, U, UserTokenPrincipal<ID>, (ID, String)> where ID <: Hashable & Equatable<ID>, U <: BaseUserData<U>
```
### 用http Authorization传递JWT的登录状态
```cj
public class JWTSecurityContext<U> <: SecurityContext<String, U, JWTPrincipal<String>, Unit> where U <: BaseUserData<U>
```
### 用请求参数传递的登录状态
```cj
public class UserTokenSecurityContext<ID, U> <: SecurityContext<ID, U, UserTokenPrincipal<ID>, (ID, String)> where ID <: Hashable & Equatable<ID>, U <: BaseUserData<U>
```

### 登录状态
```cj
public interface Principal<ID, P> where ID <: Hashable & Equatable<ID>, P <: Principal<ID, P> {
    prop id: ID
    prop username: String
}
```
### 储存登录状态
```cj
public interface PrincipalStore<ID, P> where ID <: Hashable & Equatable<ID>, P <: Principal<ID, P> {
    func store(principal: P): Unit
    func get(id: ID): ?P
    func remove(id: ID): ?P
}
```
#### 堆缓存登录状态
```cj
public struct HeapCacheStore<ID, P> <: PrincipalStore<ID, P> where ID <: Hashable & Equatable<ID> & ToString, P <: Object & Principal<ID, P>
```
##### JWT登录状态
```cj
public type JWTHeapCacheStore = HeapCacheStore<String, JWTPrincipal<String>> {
    /**
     * 登录状态的保持时间
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
        private let uid: ID,//用户ID
        private let name: String,//用户名
        public let key: String//签名密钥
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
##### 用户ID和token的登录状态
```cj
public struct UserTokenHeapCacheStore<ID> <: PrincipalStore<ID, UserTokenPrincipal<ID>> where ID <: Hashable & Equatable<ID> & ToString {
    /**
     * 登录状态的保持时间
     */
    public init(maxLife: Duration)
    public func store(principal: UserTokenPrincipal<ID>): Unit 
    public func get(id: ID): ?UserTokenPrincipal<ID> 
    public func remove(id: ID): ?UserTokenPrincipal<ID>
}
```

### 用户基本数据
```cj
public interface BaseUserData<U> where U <: BaseUserData<U> {
    prop username: String
}
```

