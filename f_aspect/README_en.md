# AOP
`fountain::f_aspect` is an AOP framework
- An aspect is a class that implements the `fountain::f_aspect.Aspect` interface and is decorated with `@Bean`
- `@Pointcut`: the aspect weaving macro
- `@WeavedBean`: both weaves the aspects and registers the class with the IOC
---

## `Aspect`

  - Import the macro: `import fountain::f_aspect.Aspect`
```cj
/**
 * Every aspect must implement this interface and must be decorated with @AspectRoute.
 */
public interface Aspect {
    /**
     * Executed first, before around, the original function body, after, throwing and final; does nothing by default
     */
    func before(funcInfo: InvocationFuncInfo): Unit 
    /**
     * Executed after around returns; by default it returns result immediately
     */
    func after(funcInfo: InvocationFuncInfo, result: Any): Any 
    /**
     * Executed after before returns and before after; the original function is executed at some point inside around,
     * under the developer's control; by default the original function body is executed immediately
     */
    func around(funcInfo: InvocationFuncInfo, point: (Array<Any>) -> Any): Any 
    /**
     * Executed when any of before, the original function body, around or after throws; by default it returns the argument e
     */
    func throwing(funcInfo: InvocationFuncInfo, e: Exception): Exception 
    /**
     * Executed after before, the original function body, around, after and throwing have finished; does nothing by default
     */
    func final(funcInfo: InvocationFuncInfo): Unit {}
    /**
     * Developers may override this function to define the aspect freely; by default it runs in the order before,
     * around, the original function body, after, throwing, final
     * before, around, the original function body and after run in a try block
     * throwing runs in a catch block and is executed when any of before, around, the original function body or after throws
     * final runs in a finally block, after all the previous steps have finished
     */
    func proceed(funcInfo: InvocationFuncInfo, point: (Array<Any>) -> Any): Any 
}
```

## Concurrency and thread safety

An aspect (an implementation class of `Aspect`) is a **singleton bean** in the IoC: all pointcut functions of the same type and all threads share
the same aspect instance, and the framework does not synchronize aspect calls. Therefore:

  - The aspect implementation **must be thread safe itself**: do not keep per-call state in positions shared across calls, such as instance
    fields (counters, caches, the previous `funcInfo`/arguments, etc.); pass state between steps through local variables or arguments;
  - When a pointcut function is called concurrently, `before`/`after`/`around`/`throwing`/`final` enter the same aspect instance concurrently,
    so shared resources accessed inside the aspect (files, connections, containers, etc.) must be locked or built from concurrent containers;
  - Several instances of the same type share the same aspect chain, and the chain is built only once, on the first call of the pointcut function
    (see `Aspects`); "the concurrency safety of the aspect instance" is the aspect implementation's own responsibility.

## `@Pointcut`

  - Import the macro: `import fountain::f_aspect.macros.Pointcut`
  - Functions decorated with the `@Pointcut` macro perform the aspect weaving logic
  - All public functions of a class decorated with the `@Pointcut` macro perform the aspect weaving logic
  - The weaving logic runs on the first call of those functions
```cj
import fountain::f_bean.macros.*
@Bean
public class AspectClass <: Aspect {
  ...
}
```
```cj
import fountain::f_aspect.macros.*;

@Bean
public class ClassName {
  @Pointcut
  public func weavedFunc(): Unit {
    ...
  }
}
@WeavedBean//A class decorated with this macro is registered with the IOC, and every public member function of it performs the weaving logic
public class WeavedClass {
  public func weavedFunc(): Unit {
    ...
  }
}
```


## Nested calls and recursion (design)

- **No weaving inside the same weaving call chain**: when the weaved method of a pointcut function A calls another pointcut function B (or A calls itself recursively), **the inner call executes the original function body directly and does not run the aspects**.
  This is deliberate: it avoids executing aspects repeatedly when a pointcut function is called recursively (and avoids infinite recursion when an aspect calls a weaved function again).
- The implementation is `recursiveInvocationFlag` in `src/Aspects.cj` (`private static let ... = ThreadLocal<Bool>`): during the outermost weaving it is set to `true` (`Aspects.proceed` wraps it in `try { ... } finally { remove() }`),
  and an inner weaving call that reads the flag calls `fn(funcInfo.args)` directly, so when A calls B the aspects of B are **not** executed.
- **To have both A and B weaved when A calls B**, the flag would have to be `false` during the inner call (that is, the outermost call would not set it to `true`).
  Note: this flag is currently an internal implementation detail of the framework with no public switch; if you need that semantics, confirm the change with the maintainers.


## Aspect set and when the chain is built (design)

- Which aspects exist (the `Aspect` beans decorated with `@AspectRoute`) and "which aspects can weave which functions" are both given by the
  annotations at **compile time**; at runtime only "matching + chain building" happens, and that **only once, on the first call of the pointcut
  function** (chains are cached by "(type, function)" in a static map of `Aspects` and reused afterwards).
- Therefore which aspects a function weaves at its **first call** (or that it has none) is **fixed** at that moment and never changes later:
  - Aspect beans must be registered **before the first call** of the weaved function (the framework startup/auto-assembly stage is early enough, which is how the auto-assembly of `f_orm`/`f_mvc` works); aspects registered later **do not** affect functions already called;
  - Rules given by annotations are determined at compile time; the `Config*RouteRule` classes (such as `ConfigAspectRouteRule`) read configuration only when matching —— also only once, at the **first call**, so changing the configuration afterwards only affects functions that have not been called;
  - Changing annotations/rules requires recompiling and restarting the process; functions already called do not rebuild their chain.


## Weaving rules

### Parent class of the weaving rules
Executing the weaving logic does not necessarily weave all aspects, and may even weave none at all
```cj
/**
 * This is the parent class of all weaving rules
 * Unless stated otherwise, the notes of this comment apply to all the rules below.
 * Any argument may use the wildcard * for any number of characters greater than or equal to 0, and ? for 0 or 1 character
 * The packageName argument is a package name,
 * - .*, *. and .*. mean any package name
 * - .. means a package name of any level
 * The typeName argument is a type name,
 * The argTypes argument is the fully qualified name of the arguments, separated by commas,
 *   and the wildcard ** means any number and any types of arguments
 * The returnType argument is the fully qualified name of the return type, and the wildcard * means any return type
 * Fully qualified type names do not support types that reflection does not yet support
 */
public abstract class RouteRule {
    public const init() {}
    public func matches(funcInfo: InvocationFuncInfo): Bool
    public operator const func &(right: RouteRule): RouteRule 
    public operator const func |(right: RouteRule): RouteRule 
    public operator const func !(): RouteRule 
}
```
### Weaving rule annotations
```cj
/**
 * This is the annotation that defines a weaving rule; it decorates an aspect, i.e. an implementation class of Aspect
 */
@Annotation[target: [Type]]
public class AspectRoute <: RouteRule {
    public const AspectRoute(public let route: RouteRule) {}
    public func isAspect<T>(): Bool 
    /**
     * A function decorated with @Pointcut is a pointcut function; the fully qualified name of its type, its name, its
     * argument types and its return type are wrapped into an InvocationFuncInfo
     * When matches returns true the aspect can be weaved into this function
     */
    public func matches(funcInfo: InvocationFuncInfo): Bool 
}
```

#### `InvocationFuncInfo`
  - A value type (`struct`): immutable, passed by value, one instance per call (per layer) —— argument state is not shared between concurrent calls
```cj
public struct InvocationFuncInfo {
    public InvocationFuncInfo(
        private let _funcInfo: QualifiedFuncInfo, //Function metadata
        private let _args: Array<Any>//Function arguments
    ) {}
    /**
     * typeInfo, funcName and argTypes form the function metadata
     */
    public init(
        typeInfo: TypeInfo, //Class containing the pointcut function
        funcName: String, //Pointcut function name
        argTypes: Array<TypeInfo>, //List of the parameter types of the pointcut function
        args: Array<Any>//Pointcut function arguments
    ) 
}
```
```cj
public class QualifiedFuncInfo <: Hashable & Equatable<QualifiedFuncInfo> {
    private let hash: Int64
    public QualifiedFuncInfo(
        public let typeInfo: TypeInfo,//Type containing the pointcut function
        public let funcInfo: InstanceFunctionInfo//Reflection information of the pointcut function, std.reflect.InstanceFunctionInfo
    )
    public init(
        typeInfo: TypeInfo,//Type containing the pointcut function
        funcName: String,//Pointcut function name
        argTypes: Array<TypeInfo>//Pointcut function argument types
    )
    public operator func ==(other: QualifiedFuncInfo): Bool
    public func hashCode(): Int64 
}
```

#### `ExecutionRouteRule`
```cj
/**
 * Matching public instance functions are weaved
 */
public class ExecutionRouteRule <: AndRouteRule {
    public const init(
        within: WithinRouteRule,
        funcType: FuncRouteRule
    )
    /**
     * @param qualifiedName Fully qualified name of the class containing the pointcut function; see WithinRouteRule for the detailed rules
     * @param funcName Pointcut function name
     * @param argTypes Pointcut function argument types, several separated by commas
     * @param returnType Pointcut function return type
     */
    public const init(qualifiedName: String, funcName: String, argTypes: String, returnType: String) 
}
```

#### `WithinRouteRule`
```cj
/**
 * All types whose package name matches packageName and whose type name matches typeName are matched, and all public
 * instance functions of the matched types are weaved.
 * Wildcards are supported: ? means any single character, * means any number of characters, and .. means any number of
 * package names.
 * To match an organization name, use ::, with the wildcard pattern for the organization name before ::.
 * If the qualifiedName pattern does not start with ^.+::, *:: is prepended to qualifiedName automatically
 */
public class WithinRouteRule <: RouteRule {
    public const WithinRouteRule(public let qualifiedName: String) {}
    public func matches(funcInfo: InvocationFuncInfo): Bool 
}
```

#### `ArgsRouteRule`
```cj
/**
 * Because arguments modified by an aspect must be subtypes of the original function arguments for the original function
 * to accept the modifications, all public instance functions whose arguments match argTypes are weaved.
 * Separate several arguments with commas; *, ignores the first argument, ,*, ignores some argument in the middle and
 * ,* ignores the last argument.
 * ** means any number of arguments of any type and may be at the end of this rule.
 * If an explicit argument type given by this rule is a subtype of the target function argument, the check passes; the
 * modification an aspect makes to an argument may be a subtype of the target function argument or the original type.
 * A type given by the rule may use `<: TypeQualifiedName` to mean the target function argument being a subtype of the
 * given argument type satisfies the rule.
 * A type given by the rule may use `TypeQualifiedName <:` to mean the given argument type being a subtype of the target
 * function argument satisfies the rule.
 * According to Cangjie's subtype relations, any type is a subtype of itself.
 */
public class ArgsRouteRule <: RouteRule {
    public const ArgsRouteRule(public let argTypes: String) {}
    public func matches(funcInfo: InvocationFuncInfo): Bool
}
```

#### `ReturnTypeRouteRule`
```cj
/**
 * Because a return value modified by an aspect must be a subtype of the original return type to be returned as the
 * original function's return type, functions whose return type is a subtype of the target function's return type are
 * weaved; returnType is a fully qualified type name
 */
public class ReturnTypeRouteRule <: RouteRule {
    public const ReturnTypeRouteRule(public let returnType: String) {}
    public func matches(funcInfo: InvocationFuncInfo): Bool 
}
```

#### `FuncTypeRouteRule`
```cj
/**
 * All public instance functions whose arguments and return type match are weaved
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
 * Weaving rule on the function name
 */
public class FuncNameRouteRule <: RouteRule {
    public const FuncNameRouteRule(public let name: String) {}
    public func matches(funcInfo: InvocationFuncInfo): Bool 
}
```

#### `TargetRouteRule`
```cj
/**
 * The argument is a fully qualified type name; all public instance functions of that type and its subtypes are weaved
 */
public class TargetRouteRule <: RouteRule {
    public const TargetRouteRule(public let targetQualifiedName: String) {}
    public func matches(funcInfo: InvocationFuncInfo): Bool 
}
```

#### `TargetAnnotationRouteRule`
```cj
/**
 * If the target type carries an annotation of the given type, all public instance functions of the target type are
 * weaved; wildcards do not apply to this rule.
 * The argument is the fully qualified name of the annotation type; several annotation class names are separated by &,
 * and every annotation type must be matched by an annotation of the target type for the rule to return true.
 * When sub is true, the annotation of the target type is required to be a subtype of the given annotation; otherwise
 * the fully qualified name of the given annotation is required to be a subset of the fully qualified name of the target
 * type's annotation.
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
 * The target function is weaved if it carries an annotation of the given type; wildcards do not apply to this rule.
 * The argument is the fully qualified name of the annotation type; several annotation class names are separated by &,
 * and every annotation type must be matched by an annotation of the target function for the rule to return true.
 * When sub is true, the annotation of the target function is required to be a subtype of the given annotation;
 * otherwise the fully qualified name of the given annotation is required to be a subset of the fully qualified name of
 * the target function's annotation.
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
 * The target function is weaved if all of its arguments carry the given annotations; wildcards do not apply to this rule.
 * The argument is the fully qualified name of the annotation types; several annotation types are separated by & and each
 * annotation type corresponds to one argument in turn (the count must equal the number of arguments).
 * Use the placeholder * to ignore the annotation of an argument,
 * for example *&a.b.c.AnnotationType means the target function has two arguments, the annotation of the first is ignored
 * and the second must carry the a.b.c.AnnotationType annotation
 * a.Annotation1&*&b.Annotation2 means the target function has three arguments, the annotation of the second is ignored
 * and the first and third must carry the a.Annotation1 and b.Annotation2 annotations
 */
public class ArgAnnotationsRouteRule <: RouteRule {
    public const ArgAnnotationsRouteRule(public let annotationTypes: String) {}
    public func matches(funcInfo: InvocationFuncInfo): Bool
}
```

#### `AnyArgAnnotationsRouteRule`
```cj
/**
 * The target function is weaved if any one of its arguments carries all of the given annotations; wildcards do not
 * apply to this rule and several annotations are separated by commas
 */
public class AnyArgAnnotationsRouteRule <: RouteRule {
    public const AnyArgAnnotationsRouteRule(public let annotationTypes: String) {}
    public func matches(funcInfo: InvocationFuncInfo): Bool 
}
```

#### `ArgPrefixAnnotationsRouteRule`
```cj
/**
 * The target function is weaved if each of its leading arguments carries the given annotation; wildcards do not apply
 * to this rule and several annotations are separated by commas
 * For example a.Annotation1,b.Annotation2 matches test1 and test2 below
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
 * The target function is weaved if each of its trailing arguments carries the given annotation; wildcards do not apply
 * to this rule and several annotations are separated by commas
 * For example a.Annotation1,b.Annotation2 matches test1 and test2 below
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
 * The beanName of the target object matches this rule; all public instance functions of the target are weaved
 */
public class BeanNameRouteRule <: RouteRule {
    public const BeanNameRouteRule(public let beanName: String) {}
    public func matches(funcInfo: InvocationFuncInfo): Bool
}
```

#### `AndRouteRule`
```cj
/**
 * Public instance functions matched by both rules are weaved
 */
public open class AndRouteRule <: RouteRule {
    public const AndRouteRule(private let left: RouteRule, private let right: RouteRule) {}
    public func matches(funcInfo: InvocationFuncInfo): Bool
}
```

#### `OrRouteRule`
```cj
/**
 * Public instance functions matched by either rule are weaved
 */
public class OrRouteRule <: RouteRule {
    public const OrRouteRule(public let left: RouteRule, public let right: RouteRule) {}
    public func matches(funcInfo: InvocationFuncInfo): Bool 
}
```

#### `NotRouteRule`
```cj
/**
 * Negates the matching result of the given rule.
 */
public class NotRouteRule <: RouteRule {
    public const NotRouteRule(public let rule: RouteRule) {}
    public func matches(funcInfo: InvocationFuncInfo): Bool 
}
```
