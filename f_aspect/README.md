# AOP
`fountain::f_aspect`是一个AOP框架
- 切面是实现了`fountain::f_aspect.Aspect`接口有被`@Bean`修饰的类
- `@Pointcut`：切面织入宏
- `@WeavedBean`: 同时织入切面并且注册到IOC
---

## `Aspect`

- [Aspect](doc/Aspect.md)

## `@Pointcut`

- [Pointcut](doc/Pointcut.md)

## 织入规则

- [织入规则](doc/织入规则.md)

