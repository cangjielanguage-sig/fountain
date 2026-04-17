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
