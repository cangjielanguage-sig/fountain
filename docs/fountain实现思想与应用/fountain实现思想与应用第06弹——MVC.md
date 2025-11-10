# fountain实现思想与应用第六弹

##### ——MVC

项目链接：https://gitcode.com/Cangjie-SIG/fountain

![MVC-1760757097624](.assets/fountain%E5%AE%9E%E7%8E%B0%E6%80%9D%E6%83%B3%E4%B8%8E%E5%BA%94%E7%94%A8%E7%AC%AC06%E5%BC%B9%E2%80%94%E2%80%94MVC/MVC-1760757097624.jpg)

MVC的核心类型是RequestMeta。

@Controlller宏遍历它修饰的类每一个公共实例成员函数，它展开的代码利用这些函数的函数名和参数TypeInfo调用内部函数获得Mapping注解和参数注解，并利用这些注解从HttpContext获得函数参数将它们转换为参数类型调用相应的函数，它们会作为尾闭包注册到RequestMeta。

每次访问会从自定义的HttpRequestDistributorImpl利用请求路径找到MultiRequestMethodHandler实例，这个实例利用请求方法和Content-Type请求头找到相应的RequestMeta，MultiRequestMethodHandler会检查请求方法、Content-Type，并对不符合的访问返回相应的http状态码。然后调用RequestCondition实例检查表单参数和请求头，最后调用AuthHandler检查当前登录状态和用户访问权限，对于满足所有条件的访问会调用注册到RequestMeta的handle闭包，闭包内部从BeanFactory获得相应的Controller类实例并用这个实例调用controller函数。

@Controller宏会利用各种参数注解解析各种参数。@RequestBody会利用Content-Type从MediaTypes获得注册的MediaType实现，将请求体转换为controller函数参数，@RequestParam会利用它的注解参数或函数参数名从表单获得请求参数，@RequestHeader会利用它的注解参数函数参数名从请求头获得请求参数，@PathVariable会利用它的注解参数或函数参数名从请求路径获得参数。

开发者还可以向MVC注册自定义的AuthHandler实现登录状态和权限检查，并且可以实现ErrorHttpRequestHandler向MVC注册统一的各种错误结果HTTP响应状态码和HTTP响应体。

对于某些不需要检查登录和权限的controller函数可以使用@IgnoreAuth @IgnorePrivilege @IgnoreSecurity忽略检查，@IgnoreAuth会忽略检查登录状态，@IgnorePrivilege会忽略检查权限，@IgnoreSecurity会两个检查都忽略。

MVCStarter.initialize()从配置类获得配置信息完成stdx.net.http.Server初始化。