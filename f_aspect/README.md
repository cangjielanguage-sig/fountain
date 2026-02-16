# AOP
`fountain::f_aspect`是一个AOP框架
- 切面是实现了`fountain::f_aspect.Aspect`接口有被`@Bean`修饰的类
- `@Pointcut`：切面织入宏
- `@WeavedBean`: 同时织入切面并且注册到IOC
---

## `Aspect` 
  - 导入宏：`import fountain::f_aspect.Aspect`
```cj
/**
 * 所有切面必须实现本接口，且必须被@AspectRoute修饰。
 */
public interface Aspect {
    /**
     * 最先执行，先于around 原函数体 after throwing final，默认什么也不做
     */
    func before(funcInfo: InvocationFuncInfo): Unit 
    /**
     * 在around返回后执行，默认是立即返回result
     */
    func after(funcInfo: InvocationFuncInfo, result: Any): Any 
    /**
     * 在before返回后after之前执行，原函数在around内部某个时机执行，由开发者控制，默认是立即执行原函数体
     */
    func around(funcInfo: InvocationFuncInfo, point: (Array<Any>) -> Any): Any 
    /**
     * 在before、原函数体、around、after任意一个抛出异常时执行，默认返回参数e
     */
    func throwing(funcInfo: InvocationFuncInfo, e: Exception): Exception 
    /**
     * 在before、原函数体、around、after、throwing执行完成后执行，默认什么也不做
     */
    func final(funcInfo: InvocationFuncInfo): Unit {}
    /**
     * 开发者可以覆盖这个函数自由定义切面，默认是按照before around 原函数体 after throwing final这个顺序执行
     * before around 原函数体 after 在try块执行
     * throwing在catch块执行，会在before around 原函数体 after 等任意一步抛出异常时执行
     * final在finally块执行，会在前面各步结束后执行
     */
    func proceed(funcInfo: InvocationFuncInfo, point: (Array<Any>) -> Any): Any 
}
```
## `@Pointcut`
  - 导入宏：`import fountain::f_aspect.macros.Pointcut`
  - `@Pointcut`宏修饰的函数会执行切面织入逻辑
  - `@Pointcut`宏修饰的类的公共函数都会执行切面织入逻辑
  - 织入逻辑会在这些函数首次调用时执行
```cj
import fountain::f_bean.macros.*
@Bean
public class AspectClass <: Aspect {
  ...
}
```
```cj
import fountain::f_aspect.macros.*

@Bean
public class ClassName {
  @Pointcut
  public func weavedFunc(): Unit {
    ...
  }
}
@WeavedBean//此宏修饰的类会注册到IOC，并且此类的每个公共成员函数都会执行织入逻辑
public class WeavedClass {
  public func weavedFunc(): Unit {
    ...
  }
}
```

## 织入规则
### 织入规则的父类
执行织入逻辑不一定会织入全部切面，甚至可能不会织入任何切面
```cj
/**
 * 这是所有织入规则的父类
 * 以下所有规则除非特别说明都适用本注释的说明。
 * 任意参数都可以用通配符*表示任意大于等于0个字符，?表示0或1个字符
 * packageName参数是包名，
 * - .*、*.、.*. 表示任意包名
 * - .. 表示任意级别的包名
 * typeName参数是类型名，
 * argTypes参数是参数全限定名，多个参数之间用,分割，适用通配符**表示任意数量和类型的参数类型
 * returnType参数是返回类型全限定名，适用通配符*表示任意返回类型
 * 类型全限定名不支持反射尚不支持的类型
 */
public abstract class RouteRule {
    public const init() {}
    public func matches(funcInfo: InvocationFuncInfo): Bool
    public operator const func &(right: RouteRule): RouteRule 
    public operator const func |(right: RouteRule): RouteRule 
    public operator const func !(): RouteRule 
}
```
### 织入规则注解
```cj
/**
 * 这是定义织入规则的注解，用来修饰切面也就是Aspect的实现类
 */
@Annotation[target: [Type]]
public class AspectRoute <: RouteRule {
    public const AspectRoute(public let route: RouteRule) {}
    public func isAspect<T>(): Bool 
    /**
     * 被@Pointcut修饰的函数是切点函数，函数所在类型全限定名、函数名、函数参数类型、函数返回类型会包装成InvocationFuncInfo
     * matches函数返回true的表示这个切面可以织入这个函数
     */
    public func matches(funcInfo: InvocationFuncInfo): Bool 
}
```

#### `InvocationFuncInfo`
```cj
public class InvocationFuncInfo {
    public InvocationFuncInfo(
        private let _funcInfo: QualifiedFuncInfo, //函数元数据
        private var _args: Array<Any>//函数实参
    ) {}
    /**
     * typeInfo funcName argTypes 构成函数元数据
     */
    public init(
        typeInfo: TypeInfo, //切点函数所在类
        funcName: String, //切点函数名
        argTypes: Array<TypeInfo>, //切点函数形参类型列表
        args: Array<Any>//切点函数实参
    ) 
}
```
```cj
public class QualifiedFuncInfo <: Hashable & Equatable<QualifiedFuncInfo> {
    private let hash: Int64
    public QualifiedFuncInfo(
        public let typeInfo: TypeInfo,//切点函数所在类型
        public let funcInfo: InstanceFunctionInfo//切点函数的反射信息std.reflect.InstanceFunctionInfo
    )
    public init(
        typeInfo: TypeInfo,//切点函数所在类型
        funcName: String,//切点函数名
        argTypes: Array<TypeInfo>//切点函数参数类型
    )
    public operator func ==(other: QualifiedFuncInfo): Bool
    public func hashCode(): Int64 
}
```

#### `ExecutionRouteRule`
```cj
/**
 * 匹配的公共实例函数将被织入
 */
public class ExecutionRouteRule <: AndRouteRule {
    public const init(
        within: WithinRouteRule,
        funcType: FuncRouteRule
    )
    /**
     * @param qualifiedName 切点函数所在类的全限定名
     * @param funcName 切点函数名
     * @param argTypes 切点函数参数类型，多个参数类型用,分隔
     * @param returnType 切点函数返回类型
     */
    public const init(qualifiedName: String, funcName: String, argTypes: String, returnType: String) 
}
```

#### `WithinRouteRule`
```cj
/**
 * 类型包名匹配packageName，类型名匹配typeName的全部类型将会匹配，匹配的类型全部公共实例函数将被织入，
 */
public class WithinRouteRule <: RouteRule {
    public const WithinRouteRule(public let qualifiedName: String) {}
    public func matches(funcInfo: InvocationFuncInfo): Bool 
}
```

#### `ArgsRouteRule`
```cj
/**
 * 因为切面修改以后的参数必须是原函数参数的子类型，原函数才能接收切面的修改，
 * 所以参数匹配argTypes的全部公共实例函数将被织入。
 * 多个参数使用,分割，*,表示忽略第一个参数，,*,表示忽略中间某个参数，,*表示忽略最后一个参数
 * **表示任意数量任意类型的参数，可以**在本规则结尾。
 * 本规则指定的明确参数类型如果是目标函数参数的子类型则判定通过，切面对参数的修改可以是目标函数参数的子类型或原类型。
 * 规则指定的类型可以使用`<: TypeQualifiedName`表示目标函数参数是指定参数类型的子类型即符合规则。
 * 规则指定的类型可以使用`TypeQualifiedName <:`表示指定参数类型是目标函数参数的子类型即符合规则。
 * 按照仓颉的子类型关系，任意类型都是其自身的子类型。
 */
public class ArgsRouteRule <: RouteRule {
    public const ArgsRouteRule(public let argTypes: String) {}
    public func matches(funcInfo: InvocationFuncInfo): Bool
}
```

#### `ReturnTypeRouteRule`
```cj
/**
 * 因为切面修改以后的返回类型必须是原函数返回类型的子类型，才能按原函数的返回类型返回，
 * 所以returnType是目标函数返回类型的子类型将被织入，returnType是一个类型全限定名
 */
public class ReturnTypeRouteRule <: RouteRule {
    public const ReturnTypeRouteRule(public let returnType: String) {}
    public func matches(funcInfo: InvocationFuncInfo): Bool 
}
```

#### `FuncTypeRouteRule`
```cj
/**
 * 参数和返回类型匹配的全部公共实例函数将被织入
 */
public class FuncTypeRouteRule <: AndRouteRule {
    public const init(
        argTypes: ArgsRouteRule,
        returnType: ReturnTypeRouteRule
    ) 
    public const init(argTypes: String, returnType: String) 
}
```

#### `FuncNameRouteRule`
```cj
/**
 * 函数名织入规则
 */
public class FuncNameRouteRule <: RouteRule {
    public const FuncNameRouteRule(public let name: String) {}
    public func matches(funcInfo: InvocationFuncInfo): Bool 
}
```

#### `TargetRouteRule`
```cj
/**
 * 参数是一个类型全限定名，这个类型及它的子类型全部公共实例函数将被织入
 */
public class TargetRouteRule <: RouteRule {
    public const TargetRouteRule(public let targetQualifiedName: String) {}
    public func matches(funcInfo: InvocationFuncInfo): Bool 
}
```

#### `TargetAnnotationRouteRule`
```cj
/**
 * 如果目标类型有指定类型的注解则目标类型的全部公共实例函数将被织入，本规则不适用通配符
 * 参数是注解类型的全限定名，多个注解类名用&分割，每个注解类型都要能够跟目标类型的注解匹配到才返回true。
 * sub是true时，要求目标类型的注解是指定注解的子类型，否则要求指定的注解全限定名是目标类型注解全限定名的子集。
 */
public class TargetAnnotationRouteRule <: RouteRule {
    public const TargetAnnotationRouteRule(
        public let annotationTypes: String,
        public let sub!: Bool = false
    ) {}
    public func matches(funcInfo: InvocationFuncInfo): Bool 
}
```

#### `FuncAnnotationRouteRule`
```cj
/**
 * 目标函数有指定类型的注解将被织入，本规则不适用通配符
 * 参数是注解类型的全限定名，多个注解类名用&分割，每个注解类型都要能够跟目标函数的注解匹配到才返回true。
 * sub是true时，要求目标函数的注解是指定注解的子类型，否则要求指定的注解的全限定名是目标函数注解全限定名的子集。
 */
public class FuncAnnotationRouteRule <: RouteRule {
    public const FuncAnnotationRouteRule(
        public let annotationTypes: String,
        public let sub!: Bool = false
    ) {}
    public func matches(funcInfo: InvocationFuncInfo): Bool 
}
```

#### `ArgAnnotationsRouteRule`
```cj
/**
 * 目标函数参数都有指定类型注解将被织入，本规则不适用通配符
 * 参数是注解类型的全限定名，多个注解类型用&分割，每个注解类型依次对应一个参数。
 * 忽略某个参数的注解需要使用*占位，
 * 比如*,a.b.c.AnnotationType表示目标函数有两个参数，忽略第一个参数的注解，第二个参数必须有a.b.c.AnnotationType注解
 * a.Annotation1,*,b.Annotation2表示目标函数有三个参数，忽略第二个参数的注解，第一第三个参数必须有a.Annotation1和b.Annotation2
 */
public class ArgAnnotationsRouteRule <: RouteRule {
    public const ArgAnnotationsRouteRule(public let annotationTypes: String) {}
    public func matches(funcInfo: InvocationFuncInfo): Bool
}
```

#### `AnyArgAnnotationsRouteRule`
```cj
/**
 * 目标函数任意一个参数拥有指定的全部注解将被织入，本规则不适用通配符，多个注解用,分割
 */
public class AnyArgAnnotationsRouteRule <: RouteRule {
    public const AnyArgAnnotationsRouteRule(public let annotationTypes: String) {}
    public func matches(funcInfo: InvocationFuncInfo): Bool 
}
```

#### `ArgPrefixAnnotationsRouteRule`
```cj
/**
 * 目标函数开头的每个参数拥有指定注解将被织入，本规则不适用通配符，多个注解用,分割
 * 比如a.Annotation1,b.Annotation2 匹配下面的test1和test2
 * public func test1(@Annotation1 a: String, @Annotation2 b: String){}
 * public func test2(@Annotation1 a: String, @Annotation2 b: String, c: String){}
 * public func test3(@Annotation1 a: String, c: String, @Annotation2 b: String){}
 */
public class ArgPrefixAnnotationsRouteRule <: RouteRule {
    public const ArgPrefixAnnotationsRouteRule(public let annotationTypes: String) {}
    public func matches(funcInfo: InvocationFuncInfo): Bool 
}
```

#### `ArgSuffixAnnotationsRouteRule`
```cj
/**
 * 目标函数结尾的每个参数拥有指定注解将被织入，本规则不适用通配符，多个注解用,分割
 * 比如a.Annotation1,b.Annotation2 匹配下面的test1和test2
 * public func test1(@Annotation1 a: String, @Annotation2 b: String){}
 * public func test2(c: String, @Annotation1 a: String, @Annotation2 b: String){}
 * public func test3(@Annotation1 a: String, c: String, @Annotation2 b: String){}
 */
public class ArgSuffixAnnotationsRouteRule <: RouteRule {
    public const ArgSuffixAnnotationsRouteRule(public let annotationTypes: String) {}
    public func matches(funcInfo: InvocationFuncInfo): Bool 
}
```

#### `BeanNameRouteRule`
```cj
/**
 * 目标对象的beanName符合本规则，目标的全部公共实例函数将被织入
 */
public class BeanNameRouteRule <: RouteRule {
    public const BeanNameRouteRule(public let beanName: String) {}
    public func matches(funcInfo: InvocationFuncInfo): Bool
}
```

#### `AndRouteRule`
```cj
/**
 * 两个规则都匹配的公共实例函数将被织入
 */
public open class AndRouteRule <: RouteRule {
    public const AndRouteRule(private let left: RouteRule, private let right: RouteRule) {}
    public func matches(funcInfo: InvocationFuncInfo): Bool
}
```

#### `OrRouteRule`
```cj
/**
 * 匹配任意一个规则的公共实例函数将被织入
 */
public class OrRouteRule <: RouteRule {
    public const OrRouteRule(public let left: RouteRule, public let right: RouteRule) {}
    public func matches(funcInfo: InvocationFuncInfo): Bool 
}
```

#### `NotRouteRule`
```cj
/**
 * 对指定规则匹配结果取反。
 */
public class NotRouteRule <: RouteRule {
    public const NotRouteRule(public let rule: RouteRule) {}
    public func matches(funcInfo: InvocationFuncInfo): Bool 
}
```
