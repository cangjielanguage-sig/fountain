# MVC

## 配置
```bash
    export mvc_port=8080 # 这一行可以没有，默认就是8080
    export mvc_overallElapsedSwitch=true # 生产环境建议改为false，默认是false
    export mvc_internalServerErrorMessageKind=BEAN # 业务逻辑出异常时的响应消息来源
    export mvc_internalServerErrorMessage=NameOf500Handler # 业务逻辑出异常时的消息
    
    # 以下配置如果不指定都按照stdx.net.http的默认值
    export mvc_readTimeout=500ms # 按照Duration toString()的格式指定请求读超时
    export mvc_readHeaderTimeout=500ms # 按照Duration toString()的格式指定请求头读超时
    export mvc_writeTimeout=500ms # 按照Duration toString()的格式指定响应写超时
    export mvc_keepAliveTimeout=500s # 按照Duration toString()的格式指定keepalive超时
    export mvc_maxRequestHeaderSize=102400 # 请求头最大字节数
    export mvc_maxRequestBodySize=67108864 # 请求体最大字节数，不指定就是stdx.net.http的默认值2MB

    # 以下配置MVC指定了默认值
    export mvc_downloadHalfBufferSize=4096 # 下载文件缓冲区大小的一半
    export mvc_accessControlAllowOrigin='*' # 指定响应头Access-Control-Allow-Origin，默认就是* 
    export mvc_accessControlAllowHeaders='*' # 指定响应头Access-Control-Allow-Headers，默认就是*
    export mvc_accessControlMaxAge=0 # 指定响应头Access-Control-Max-Age，默认是0
```

### mvc_internalServerErrorMessageKind 的取值
- BEAN 表示错误响应来自`fountain::f_bean`管理的bean，此时mvc_internalServerErrorMessage的值是bean的名称。这个bean的类型需要实现以下接口
```cj
package fountain::f_mvc
public interface ErrorHttpRequestHandler {
    /**
     * @param ctx 当前http访问的stdx.net.http.HttpContext实例
     * @param e 处理当前http访问时发生的异常
     * @return HttpStatus是本次异常响应的http status，
     *         HttpStatus类型是fountain::f_mvc.HttpStatus，默认是HttpStatus.INTERNAL_SERVER_ERROR
     *         Any是本次异常响应体，实际返回的类型有以下可选项
     *           - String 响应体就是这个字符串
     *           - ToString 响应体是这个对象调用toString()返回的字符串
     *           - InputStream 响应体是从这个输入流读到的数据
     *           - Array<Byte> 响应体是这个字节数组
     *           - fountain::f_data.ToData 响应体会按照Accept请求头指定的类型将对象转换成字节数组，将转换结果作为响应体。
     *                 如果Accept指定了多个响应体格式，会按照Accept每个数据格式的q值以在Accept中出现的顺序排序，取第一个格式作为响应体格式 
     */
    func handle(ctx: HttpContext, e: ?Exception): (HttpStatus, Any)
}
```
- TEXT mvc_internalServerErrorMessage的值就是响应体的数据
- BASE64BINARY mvc_internalServerErrorMessage的值应该是一段BASE64文本，将这段文本转换成的字节数组作为响应体数据

## 声明controller
```cj
import fountain::f_mvc.*
import fountain::f_mvc.macros.*

//@Controller宏除了将controller公共实例函数函数注册到mvc，还会执行IOC @Bean宏展开，同时支持属性宏和非属性宏。
//@Controller属性宏的属性可以作为@Bean宏的属性
//如果需要为controller函数织入切面，可以使用@WeavedController修饰controller类
//@WeavedController除了拥有@Controller的完整功能，还会执行切点宏@Pointcut展开
@Controller
public class HelloworldController {
    //只有被Mapping结尾的注解修饰的公共实例函数才会注册到MVC
    //path 是http请求路径
    //produces 是响应体格式
    //consumes 是请求体格式
    @GetMapping[path:"/helloworld", produces:'text/plain', consumes:'application/x-www-form-urlencoded']
    public func helloworld(): String {
        return "helloworld"
    }
}
```

### controller函数注解
此类注解名称都是Mapping结尾，并且都有一样的初始化参数，初始化参数定义如下：
- path 请求路径，支持{}包含的路径参数，比如/api/user/{id}这个路径就定义了一个名为id的路径参数
- produces 响应体格式，可以用|分割多个响应体格式，默认是application/json
- consumes 请求体格式，可以用|分割多个请求体格式，默认是application/json
- params 表单参数符合本参数指定的规则可用本函数处理相应的http访问
- headers 请求头符合本参数指定的规则可用本函数处理相应的http访问

#### params和headers的规则定义
- rule1 & rule2 左右两个规则需要都满足，整个规则才满足
- rule1 | rule2 左右两个规则满足一个，整个规则就能满足
- !rule 对右面的规则取反
- (rules) 将规则包含起来，通常用它改变& | ! 规则的计算顺序
- contains('a', 'b', 'c',...) 表示表单参数或请求头名称需要包含括号内指定的参数名或请求头名
- subset('a', 'b', 'c',...)表示表单参数或请求头名是括号内指定字符串的子集
- eg. 对于表单参数，a.contains('1', '2') & (b.subset('s', 'd') | 'orderTime' | goodsId) 这个规则表示当前访问的表单参数a的值需要同时包含'1'和'2'，而且要么表单参数b的值必须是('s', 'd')的子集，要么表单参数包含参数名orderTime，要么包含表单参数名goodsId
- eg. 对于请求头也适用一样的规则 

#### Mapping的声明
只能修饰controller类的公共实例函数，修饰其它函数无效
- `@GetMapping` 请求方法GET
- `@PostMapping` 请求方法POST
- `@PutMapping` 请求方法PUT
- `@DeleteMapping` 请求方法DELETE
- `@PatchMapping` 请求方法PATCH 

## 安全注解
只能修饰controller类的公共实例函数，修饰其它函数无效
- `@IgnoreAuth` 忽略登录状态检查
- `@IgnorePrivilege` 忽略权限检查
- `@IgnoreSecurity` 同时忽略登录状态和权限检查

## 重定向
```cj
public struct Redirect {
    private Redirect(
        public let status: HttpStatus,
        public let location: String
    ) {}
    /**
     * 302
     */
    public static func found(location: String): Redirect
    /**
     * retain是false，301；否则是308
     */
    public static func permanently(location: String, retain!: Bool = false): Redirect
    /**
     * retain是false, 302; 否则是307
     */
    public static func temporarily(location: String, retain!: Bool = false): Redirect
}
```