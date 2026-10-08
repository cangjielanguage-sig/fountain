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

## 并发与线程安全

切面（`Aspect` 的实现类）是 IoC 里的 bean，**实例怎么取由该 bean 的作用域决定**（`Aspects` 按 `scope.isSingleton` 分两条路径）：

  - **singleton**（`BeanScope.singleton`，默认值）：链在切点函数首次调用时构建一次，建链时取到的那个实例被整条链捕获，
    之后同一类型的所有切点函数、所有线程共用它；
  - **prototype**（`BeanScope.prototype`）：每次调用（链上每层）都重新从 IoC 取一个新实例，实例不跨调用共享。

框架不对切面的调用做同步，因此：

  - 切面实现**必须自身线程安全**：singleton 切面的同一个实例会被并发进入，不要在实例字段等跨调用共享的位置保存每次调用的状态
    （计数器、缓存、上一次的 `funcInfo`/参数等），需要跨步骤传递时用局部变量或参数；
  - 切点函数被并发调用时，singleton 切面的 `before`/`after`/`around`/`throwing`/`final` 会并发进入同一个实例，
    切面内访问的共享资源（文件、连接、容器等）要自行加锁或使用并发容器；prototype 切面每次调用都是新实例，
    但仍要保证单个实例在**一次调用内部**的状态一致；
  - 同一类型的多个实例共享同一条切面链，链只在切点函数首次调用时构建一次（见 `Aspects`），
    "切面实例的并发安全"由切面实现自己负责。

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


## 嵌套调用与递归（设计）

- **同一次织入调用链内不再织入**：切点函数 A 的织入方法内部再调用切点函数 B（或 A 递归调用自己）时，**内层调用直接执行原函数体，不再执行切面**。
  这是刻意的设计：避免递归调用切点函数时切面被重复执行（也避免切面里再调用织入函数造成无限递归）。
- 实现位于 `src/Aspects.cj` 的 `recursiveInvocationFlag`（`private static let ... = ThreadLocal<Bool>`）：最外层织入期间被置为 `true`（`Aspects.proceed` 里 `try { ... } finally { remove() }`），
  内层织入调用读到该标志就直接 `fn(funcInfo.args)`，因此 A 调 B 时 B 的切面**不会**执行。
- **如果希望 A 调 B 时 A、B 都织入切面**，就需要让该标志在内层调用时为 `false`（即最外层不把它置 `true`）。
  注意：该标志当前是框架内部实现，没有公开开关；需要这种语义时请与维护者确认改法。


## 切面集合与建链时机（设计）

- 有哪些切面（被 `@AspectRoute` 注解修饰的 `Aspect` bean）、以及「哪些切面可以织入哪些函数」，都是**编译期**由注解给出的；运行期只做「判定 + 建链」，并且**只在切点函数首次被调用时做一次**（链按「(类型, 函数)」缓存在 `Aspects` 的静态 map 里，之后一直复用）。
- 因此，某个函数**首次调用时**织入了哪些切面（或者没有切面），此刻就**固定**了，以后不会变化：
  - 切面 bean 必须在织入函数**首次调用之前**注册完成（框架启动/自动装配阶段即可，`f_orm`/`f_mvc` 的自动装配就是这样）；之后再注册的切面**不会**影响已经调用过的函数；
  - 以注解给出的规则是编译期确定的；`Config*RouteRule`（如 `ConfigAspectRouteRule`）匹配时才读配置 —— 也是在**首次调用**时读那一次，之后改配置同样只对未调用过的函数生效；
  - 改注解/规则需要重新编译并重启进程，已调用过的函数不会重新建链。


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
  - 值类型（`struct`）：不可变、按值传递，每次调用（每层）各一个实例 —— 并发调用之间不共享参数
```cj
public struct InvocationFuncInfo {
    public InvocationFuncInfo(
        private let _funcInfo: QualifiedFuncInfo, //函数元数据
        private let _args: Array<Any>//函数实参
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
     * @param qualifiedName 切点函数所在类的全限定名，详细规则见WithinRouteRule
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
 * 支持通配符匹配，?表示任意一个字符，*表示任意多个字符，..表示任意数量的包名。
 * 如果要匹配组织名，需要使用::，::前面是匹配组织名的通配符模式。
 * 如果qualifiedName模式不以^.+::开头，则自动在qualifiedName前面加上*::
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
 * 参数是注解类型的全限定名，多个注解类型用&分割，每个注解类型依次对应一个参数（个数必须与参数个数一致）。
 * 忽略某个参数的注解需要使用*占位，
 * 比如*&a.b.c.AnnotationType表示目标函数有两个参数，忽略第一个参数的注解，第二个参数必须有a.b.c.AnnotationType注解
 * a.Annotation1&*&b.Annotation2表示目标函数有三个参数，忽略第二个参数的注解，第一第三个参数必须有a.Annotation1和b.Annotation2
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


