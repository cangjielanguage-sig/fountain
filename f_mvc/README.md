## STDX依赖
配置环境变量：`export CANGJIE_STDX_DYNAMIC_PATH=/path/to/dynamic_stdx`

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

    # 以下配置stdx.net.http没有默认值，不过MVC指定了默认值
    export mvc_downloadBufferSize=4096 # 下载文件缓冲区大小，默认是4096
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
//@WeavedController除了拥有@Controller的完整功能，还会执行切点宏@Pointcut展开，织入规则由切面开发者自己定义
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
/**
 * controller函数返回Redirect实例，MVC会按照Redirect的实例执行重定向
 */
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

## `HttpStatus`
```cj
public class HttpStatus <: ToString & Equatable<HttpStatus> {
    // 1xx Informational

    /**
     * 100 Continue.
     * https://tools.ietf.org/html/rfc7231#section-6.2.1
     * HTTP/1.1: Semantics and Content, section 6.2.1
     */
    public static let CONTINUE = HttpStatus(
        HttpStatusCode.STATUS_CONTINUE,
        Series.INFORMATIONAL,
        "Continue"
    )

    /**
     * 101 Switching Protocols.
     * https://tools.ietf.org/html/rfc7231#section-6.2.2
     * HTTP/1.1: Semantics and Content, section 6.2.2
     */
    public static let SWITCHING_PROTOCOLS = HttpStatus(
        HttpStatusCode.STATUS_SWITCHING_PROTOCOLS,
        Series.INFORMATIONAL,
        "Switching Protocols"
    )

    /**
     * 102 Processing.
     * https://tools.ietf.org/html/rfc2518#section-10.1
     * WebDAV
     */
    public static let PROCESSING = HttpStatus(
        HttpStatusCode.STATUS_PROCESSING,
        Series.INFORMATIONAL,
        "Processing"
    )

    /**
     * 103 Checkpoint.
     * https://code.google.com/p/gears/wiki/ResumableHttpRequestsProposal
     * A proposal for supporting
     * resumable POST/PUT HTTP requests in HTTP/1.0
     */
    public static let CHECKPOINT = HttpStatus(
        HttpStatusCode.STATUS_EARLY_HINTS,
        Series.INFORMATIONAL,
        "Checkpoint"
    )
    public static let EARLY_HINTS = HttpStatus(
        HttpStatusCode.STATUS_EARLY_HINTS,
        Series.INFORMATIONAL,
        "Early Hints"
    )

    // 2xx Success

    /**
     * 200 OK.
     * https://tools.ietf.org/html/rfc7231#section-6.3.1
     * HTTP/1.1: Semantics and Content, section 6.3.1
     */
    public static let OK = HttpStatus(
        HttpStatusCode.STATUS_OK,
        Series.SUCCESSFUL,
        "OK"
    )

    /**
     * 201 Created.
     * https://tools.ietf.org/html/rfc7231#section-6.3.2
     * HTTP/1.1: Semantics and Content, section 6.3.2
     */
    public static let CREATED = HttpStatus(
        HttpStatusCode.STATUS_CREATED,
        Series.SUCCESSFUL,
        "Created"
    )

    /**
     * 202 Accepted.
     * https://tools.ietf.org/html/rfc7231#section-6.3.3
     * HTTP/1.1: Semantics and Content, section 6.3.3
     */
    public static let ACCEPTED = HttpStatus(
        HttpStatusCode.STATUS_ACCEPTED,
        Series.SUCCESSFUL,
        "Accepted"
    )

    /**
     * 203 Non-Authoritative Information.
     * https://tools.ietf.org/html/rfc7231#section-6.3.4
     * HTTP/1.1: Semantics and Content, section 6.3.4
     */
    public static let NON_AUTHORITATIVE_INFORMATION = HttpStatus(
        HttpStatusCode.STATUS_NON_AUTHORITATIVE_INFO,
        Series.SUCCESSFUL,
        "Non-Authoritative Information"
    )

    /**
     * 204 No Content.
     * https://tools.ietf.org/html/rfc7231#section-6.3.5
     * HTTP/1.1: Semantics and Content, section 6.3.5
     */
    public static let NO_CONTENT = HttpStatus(
        HttpStatusCode.STATUS_NO_CONTENT,
        Series.SUCCESSFUL,
        "No Content"
    )

    /**
     * 205 Reset Content.
     * https://tools.ietf.org/html/rfc7231#section-6.3.6
     * HTTP/1.1: Semantics and Content, section 6.3.6
     */
    public static let RESET_CONTENT = HttpStatus(
        HttpStatusCode.STATUS_RESET_CONTENT,
        Series.SUCCESSFUL,
        "Reset Content"
    )

    /**
     * 206 Partial Content.
     * https://tools.ietf.org/html/rfc7233#section-4.1
     * HTTP/1.1: Range Requests, section 4.1
     */
    public static let PARTIAL_CONTENT = HttpStatus(
        HttpStatusCode.STATUS_PARTIAL_CONTENT,
        Series.SUCCESSFUL,
        "Partial Content"
    )

    /**
     * 207 Multi-Status.
     * https://tools.ietf.org/html/rfc4918#section-13
     * WebDAV
     */
    public static let MULTI_STATUS = HttpStatus(
        HttpStatusCode.STATUS_MULTI_STATUS,
        Series.SUCCESSFUL,
        "Multi-Status"
    )

    /**
     * 208 Already Reported.
     * https://tools.ietf.org/html/rfc5842#section-7.1
     * WebDAV Binding Extensions
     */
    public static let ALREADY_REPORTED = HttpStatus(
        HttpStatusCode.STATUS_ALREADY_REPORTED,
        Series.SUCCESSFUL,
        "Already Reported"
    )

    /**
     * 226 IM Used.
     * https://tools.ietf.org/html/rfc3229#section-10.4.1
     * Delta encoding in HTTP
     */
    public static let IM_USED = HttpStatus(
        HttpStatusCode.STATUS_IM_USED,
        Series.SUCCESSFUL,
        "IM Used"
    )

    // 3xx Redirection

    /**
     * 300 Multiple Choices.
     * https://tools.ietf.org/html/rfc7231#section-6.4.1
     * HTTP/1.1: Semantics and Content, section 6.4.1
     */
    public static let MULTIPLE_CHOICES = HttpStatus(
        HttpStatusCode.STATUS_MULTIPLE_CHOICES,
        Series.REDIRECTION,
        "Multiple Choices"
    )

    /**
     * 301 Moved Permanently.
     * https://tools.ietf.org/html/rfc7231#section-6.4.2
     * HTTP/1.1: Semantics and Content, section 6.4.2
     */
    public static let MOVED_PERMANENTLY = HttpStatus(
        HttpStatusCode.STATUS_MOVED_PERMANENTLY,
        Series.REDIRECTION,
        "Moved Permanently"
    )

    /**
     * 302 Found.
     * https://tools.ietf.org/html/rfc7231#section-6.4.3
     * HTTP/1.1: Semantics and Content, section 6.4.3
     */
    public static let FOUND = HttpStatus(
        HttpStatusCode.STATUS_FOUND,
        Series.REDIRECTION,
        "Found"
    )

    /**
     * 302 Moved Temporarily.
     * https://tools.ietf.org/html/rfc1945#section-9.3
     * HTTP/1.0, section 9.3
     * deprecated in favor of FOUND which will be returned from HttpStatus.valueOf = HttpStatus(302)
     */
    public static let MOVED_TEMPORARILY = HttpStatus(
        HttpStatusCode.STATUS_FOUND,
        Series.REDIRECTION,
        "Moved Temporarily"
    )

    /**
     * 303 See Other.
     * https://tools.ietf.org/html/rfc7231#section-6.4.4
     * HTTP/1.1: Semantics and Content, section 6.4.4
     */
    public static let SEE_OTHER = HttpStatus(
        HttpStatusCode.STATUS_SEE_OTHER,
        Series.REDIRECTION,
        "See Other"
    )

    /**
     * 304 Not Modified.
     * https://tools.ietf.org/html/rfc7232#section-4.1
     * HTTP/1.1: Conditional Requests, section 4.1
     */
    public static let NOT_MODIFIED = HttpStatus(
        HttpStatusCode.STATUS_NOT_MODIFIED,
        Series.REDIRECTION,
        "Not Modified"
    )

    /**
     * 305 Use Proxy.
     * https://tools.ietf.org/html/rfc7231#section-6.4.5
     * HTTP/1.1: Semantics and Content, section 6.4.5
     * deprecated due to security concerns regarding in-band configuration of a proxy
     */
    public static let USE_PROXY = HttpStatus(
        HttpStatusCode.STATUS_USE_PROXY,
        Series.REDIRECTION,
        "Use Proxy"
    )

    /**
     * 307 Temporary Redirect.
     * https://tools.ietf.org/html/rfc7231#section-6.4.7
     * HTTP/1.1: Semantics and Content, section 6.4.7
     */
    public static let TEMPORARY_REDIRECT = HttpStatus(
        HttpStatusCode.STATUS_TEMPORARY_REDIRECT,
        Series.REDIRECTION,
        "Temporary Redirect"
    )

    /**
     * 308 Permanent Redirect.
     * https://tools.ietf.org/html/rfc7238
     * RFC 7238
     */
    public static let PERMANENT_REDIRECT = HttpStatus(
        HttpStatusCode.STATUS_PERMANENT_REDIRECT,
        Series.REDIRECTION,
        "Permanent Redirect"
    )

    // --- 4xx Client Error ---

    /**
     * 400 Bad Request.
     * https://tools.ietf.org/html/rfc7231#section-6.5.1
     * HTTP/1.1: Semantics and Content, section 6.5.1
     */
    public static let BAD_REQUEST = HttpStatus(
        HttpStatusCode.STATUS_BAD_REQUEST,
        Series.CLIENT_ERROR,
        "Bad Request"
    )

    /**
     * 401 Unauthorized.
     * https://tools.ietf.org/html/rfc7235#section-3.1
     * HTTP/1.1: Authentication, section 3.1
     */
    public static let UNAUTHORIZED = HttpStatus(
        HttpStatusCode.STATUS_UNAUTHORIZED,
        Series.CLIENT_ERROR,
        "Unauthorized"
    )

    /**
     * 402 Payment Required.
     * https://tools.ietf.org/html/rfc7231#section-6.5.2
     * HTTP/1.1: Semantics and Content, section 6.5.2
     */
    public static let PAYMENT_REQUIRED = HttpStatus(
        HttpStatusCode.STATUS_PAYMENT_REQUIRED,
        Series.CLIENT_ERROR,
        "Payment Required"
    )

    /**
     * 403 Forbidden.
     * https://tools.ietf.org/html/rfc7231#section-6.5.3
     * HTTP/1.1: Semantics and Content, section 6.5.3
     */
    public static let FORBIDDEN = HttpStatus(
        HttpStatusCode.STATUS_FORBIDDEN,
        Series.CLIENT_ERROR,
        "Forbidden"
    )

    /**
     * 404 Not Found.
     * https://tools.ietf.org/html/rfc7231#section-6.5.4
     * HTTP/1.1: Semantics and Content, section 6.5.4
     */
    public static let NOT_FOUND = HttpStatus(
        HttpStatusCode.STATUS_NOT_FOUND,
        Series.CLIENT_ERROR,
        "Not Found"
    )

    /**
     * 405 Method Not Allowed.
     * https://tools.ietf.org/html/rfc7231#section-6.5.5
     * HTTP/1.1: Semantics and Content, section 6.5.5
     */
    public static let METHOD_NOT_ALLOWED = HttpStatus(
        HttpStatusCode.STATUS_METHOD_NOT_ALLOWED,
        Series.CLIENT_ERROR,
        "Method Not Allowed"
    )

    /**
     * 406 Not Acceptable.
     * https://tools.ietf.org/html/rfc7231#section-6.5.6
     * HTTP/1.1: Semantics and Content, section 6.5.6
     */
    public static let NOT_ACCEPTABLE = HttpStatus(
        HttpStatusCode.STATUS_NOT_ACCEPTABLE,
        Series.CLIENT_ERROR,
        "Not Acceptable"
    )

    /**
     * 407 Proxy Authentication Required.
     * https://tools.ietf.org/html/rfc7235#section-3.2
     * HTTP/1.1: Authentication, section 3.2
     */
    public static let PROXY_AUTHENTICATION_REQUIRED = HttpStatus(
        HttpStatusCode.STATUS_PROXY_AUTH_REQUIRED,
        Series.CLIENT_ERROR,
        "Proxy Authentication Required"
    )

    /**
     * 408 Request Timeout.
     * https://tools.ietf.org/html/rfc7231#section-6.5.7
     * HTTP/1.1: Semantics and Content, section 6.5.7
     */
    public static let REQUEST_TIMEOUT = HttpStatus(
        HttpStatusCode.STATUS_REQUEST_TIMEOUT,
        Series.CLIENT_ERROR,
        "Request Timeout"
    )

    /**
     * 409 Conflict.
     * https://tools.ietf.org/html/rfc7231#section-6.5.8
     * HTTP/1.1: Semantics and Content, section 6.5.8
     */
    public static let CONFLICT = HttpStatus(
        HttpStatusCode.STATUS_CONFLICT,
        Series.CLIENT_ERROR,
        "Conflict"
    )

    /**
     * 410 Gone.
     * https://tools.ietf.org/html/rfc7231#section-6.5.9
     *
     *     HTTP/1.1: Semantics and Content, section 6.5.9
     */
    public static let GONE = HttpStatus(
        HttpStatusCode.STATUS_GONE,
        Series.CLIENT_ERROR,
        "Gone"
    )

    /**
     * 411 Length Required.
     * https://tools.ietf.org/html/rfc7231#section-6.5.10
     *
     *     HTTP/1.1: Semantics and Content, section 6.5.10
     */
    public static let LENGTH_REQUIRED = HttpStatus(
        HttpStatusCode.STATUS_LENGTH_REQUIRED,
        Series.CLIENT_ERROR,
        "Length Required"
    )

    /**
     * 412 Precondition failed.
     * https://tools.ietf.org/html/rfc7232#section-4.2
     *
     *     HTTP/1.1: Conditional Requests, section 4.2
     */
    public static let PRECONDITION_FAILED = HttpStatus(
        HttpStatusCode.STATUS_PRECONDITION_FAILED,
        Series.CLIENT_ERROR,
        "Precondition Failed"
    )

    /**
     * 413 Payload Too Large.
     * https://tools.ietf.org/html/rfc7231#section-6.5.11
     *
     *     HTTP/1.1: Semantics and Content, section 6.5.11
     */
    public static let PAYLOAD_TOO_LARGE = HttpStatus(
        HttpStatusCode.STATUS_REQUEST_CONTENT_TOO_LARGE,
        Series.CLIENT_ERROR,
        "Payload Too Large"
    )

    /**
     * 413 Request Entity Too Large.
     * https://tools.ietf.org/html/rfc2616#section-10.4.14
     * HTTP/1.1, section 10.4.14
     * deprecated in favor of PAYLOAD_TOO_LARGE which will be
     * returned from HttpStatus.valueOf = HttpStatus(413)
     */
    public static let REQUEST_ENTITY_TOO_LARGE = HttpStatus(
        HttpStatusCode.STATUS_REQUEST_CONTENT_TOO_LARGE,
        Series.CLIENT_ERROR,
        "Request Entity Too Large"
    )

    /*
     * 414 URI Too Long.
     * https://tools.ietf.org/html/rfc7231#section-6.5.12
     * HTTP/1.1: Semantics and Content, section 6.5.12
     */
    public static let URI_TOO_LONG = HttpStatus(
        HttpStatusCode.STATUS_REQUEST_URI_TOO_LONG,
        Series.CLIENT_ERROR,
        "URI Too Long"
    )

    /**
     * 414 Request-URI Too Long.
     * https://tools.ietf.org/html/rfc2616#section-10.4.15
     * HTTP/1.1, section 10.4.15
     * deprecated in favor of URI_TOO_LONG which will be returned from HttpStatus.valueOf = HttpStatus(414)
     */
    public static let REQUEST_URI_TOO_LONG = HttpStatus(
        HttpStatusCode.STATUS_REQUEST_URI_TOO_LONG,
        Series.CLIENT_ERROR,
        "Request-URI Too Long"
    )

    /**
     * 415 Unsupported Media Type.
     * https://tools.ietf.org/html/rfc7231#section-6.5.13
     * HTTP/1.1: Semantics and Content, section 6.5.13
     */
    public static let UNSUPPORTED_MEDIA_TYPE = HttpStatus(
        HttpStatusCode.STATUS_UNSUPPORTED_MEDIA_TYPE,
        Series.CLIENT_ERROR,
        "Unsupported Media Type"
    )

    /**
     * 416 Requested Range Not Satisfiable.
     * https://tools.ietf.org/html/rfc7233#section-4.4
     * HTTP/1.1: Range Requests, section 4.4
     */
    public static let REQUESTED_RANGE_NOT_SATISFIABLE = HttpStatus(
        HttpStatusCode.STATUS_REQUESTED_RANGE_NOT_SATISFIABLE,
        Series.CLIENT_ERROR,
        "Requested range not satisfiable"
    )

    /**
     * 417 Expectation Failed.
     * https://tools.ietf.org/html/rfc7231#section-6.5.14
     * HTTP/1.1: Semantics and Content, section 6.5.14
     */
    public static let EXPECTATION_FAILED = HttpStatus(
        HttpStatusCode.STATUS_EXPECTATION_FAILED,
        Series.CLIENT_ERROR,
        "Expectation Failed"
    )

    /**
     * 418 I'm a teapot.
     * https://tools.ietf.org/html/rfc2324#section-2.3.2
     * HTCPCP/1.0
     */
    public static let I_AM_A_TEAPOT = HttpStatus(
        HttpStatusCode.STATUS_TEAPOT,
        Series.CLIENT_ERROR,
        "I'm a teapot"
    )

    /**
     * deprecated See
     * https://tools.ietf.org/rfcdiff?difftype=--hwdiff&ampurl2=draft-ietf-webdav-protocol-06.txt
     * WebDAV Draft Changes
     */
    public static let INSUFFICIENT_SPACE_ON_RESOURCE = HttpStatus(
        419,
        Series.CLIENT_ERROR,
        "Insufficient Space On Resource"
    )

    /**
     * deprecated See
     * https://tools.ietf.org/rfcdiff?difftype=--hwdiff&ampurl2=draft-ietf-webdav-protocol-06.txt
     * WebDAV Draft Changes
     */
    public static let METHOD_FAILURE = HttpStatus(
        420,
        Series.CLIENT_ERROR,
        "Method Failure"
    )

    /**
     * deprecated
     * https://tools.ietf.org/rfcdiff?difftype=--hwdiff&ampurl2=draft-ietf-webdav-protocol-06.txt
     * WebDAV Draft Changes
     */
    public static let DESTINATION_LOCKED = HttpStatus(
        HttpStatusCode.STATUS_MISDIRECTED_REQUEST,
        Series.CLIENT_ERROR,
        "Destination Locked"
    )
    public static let MISDIRECTED_REQUEST = HttpStatus(
        HttpStatusCode.STATUS_MISDIRECTED_REQUEST,
        Series.CLIENT_ERROR,
        "Misdirected Request"
    )

    /**
     * 422 Unprocessable Entity.
     * https://tools.ietf.org/html/rfc4918#section-11.2
     * WebDAV
     */
    public static let UNPROCESSABLE_ENTITY = HttpStatus(
        HttpStatusCode.STATUS_UNPROCESSABLE_ENTITY,
        Series.CLIENT_ERROR,
        "Unprocessable Entity"
    )

    /**
     * 423 Locked.
     * https://tools.ietf.org/html/rfc4918#section-11.3
     * WebDAV
     */
    public static let LOCKED = HttpStatus(
        HttpStatusCode.STATUS_LOCKED,
        Series.CLIENT_ERROR,
        "Locked"
    )

    /**
     * 424 Failed Dependency.
     * https://tools.ietf.org/html/rfc4918#section-11.4
     * WebDAV
     */
    public static let FAILED_DEPENDENCY = HttpStatus(
        HttpStatusCode.STATUS_FAILED_DEPENDENCY,
        Series.CLIENT_ERROR,
        "Failed Dependency"
    )

    /**
     * 425 Too Early.
     * https://tools.ietf.org/html/rfc8470
     * RFC 8470
     */
    public static let TOO_EARLY = HttpStatus(
        HttpStatusCode.STATUS_TOO_EARLY,
        Series.CLIENT_ERROR,
        "Too Early"
    )

    /**
     * 426 Upgrade Required.
     * https://tools.ietf.org/html/rfc2817#section-6
     * Upgrading to TLS Within HTTP/1.1
     */
    public static let UPGRADE_REQUIRED = HttpStatus(
        HttpStatusCode.STATUS_UPGRADE_REQUIRED,
        Series.CLIENT_ERROR,
        "Upgrade Required"
    )

    /**
     * 428 Precondition Required.
     * https://tools.ietf.org/html/rfc6585#section-3
     * Additional HTTP Status Codes
     */
    public static let PRECONDITION_REQUIRED = HttpStatus(
        HttpStatusCode.STATUS_PRECONDITION_REQUIRED,
        Series.CLIENT_ERROR,
        "Precondition Required"
    )

    /**
     * 429 Too Many Requests.
     * https://tools.ietf.org/html/rfc6585#section-4
     * Additional HTTP Status Codes
     */
    public static let TOO_MANY_REQUESTS = HttpStatus(
        HttpStatusCode.STATUS_TOO_MANY_REQUESTS,
        Series.CLIENT_ERROR,
        "Too Many Requests"
    )

    /**
     * 431 Request Header Fields Too Large.
     * https://tools.ietf.org/html/rfc6585#section-5
     * Additional HTTP Status Codes
     */
    public static let REQUEST_HEADER_FIELDS_TOO_LARGE = HttpStatus(
        HttpStatusCode.STATUS_REQUEST_HEADER_FIELDS_TOO_LARGE,
        Series.CLIENT_ERROR,
        "Request Header Fields Too Large"
    )

    /**
     * 451 Unavailable For Legal Reasons.
     * https://tools.ietf.org/html/draft-ietf-httpbis-legally-restricted-status-04
     * An HTTP Status Code to Report Legal Obstacles
     */
    public static let UNAVAILABLE_FOR_LEGAL_REASONS = HttpStatus(
        HttpStatusCode.STATUS_UNAVAILABLE_FOR_LEGAL_REASONS,
        Series.CLIENT_ERROR,
        "Unavailable For Legal Reasons"
    )

    // --- 5xx Server Error ---

    /**
     * 500 Internal Server Error.
     * https://tools.ietf.org/html/rfc7231#section-6.6.1
     * HTTP/1.1: Semantics and Content, section 6.6.1
     */
    public static let INTERNAL_SERVER_ERROR = HttpStatus(
        HttpStatusCode.STATUS_INTERNAL_SERVER_ERROR,
        Series.SERVER_ERROR,
        "Internal Server Error"
    )

    /**
     * 501 Not Implemented.
     * https://tools.ietf.org/html/rfc7231#section-6.6.2
     * HTTP/1.1: Semantics and Content, section 6.6.2
     */
    public static let NOT_IMPLEMENTED = HttpStatus(
        HttpStatusCode.STATUS_NOT_IMPLEMENTED,
        Series.SERVER_ERROR,
        "Not Implemented"
    )

    /**
     * 502 Bad Gateway.
     * https://tools.ietf.org/html/rfc7231#section-6.6.3
     * HTTP/1.1: Semantics and Content, section 6.6.3
     */
    public static let BAD_GATEWAY = HttpStatus(
        HttpStatusCode.STATUS_BAD_GATEWAY,
        Series.SERVER_ERROR,
        "Bad Gateway"
    )

    /**
     * 503 Service Unavailable.
     * https://tools.ietf.org/html/rfc7231#section-6.6.4
     * HTTP/1.1: Semantics and Content, section 6.6.4
     */
    public static let SERVICE_UNAVAILABLE = HttpStatus(
        HttpStatusCode.STATUS_SERVICE_UNAVAILABLE,
        Series.SERVER_ERROR,
        "Service Unavailable"
    )

    /**
     * 504 Gateway Timeout.
     * https://tools.ietf.org/html/rfc7231#section-6.6.5
     * HTTP/1.1: Semantics and Content, section 6.6.5
     */
    public static let GATEWAY_TIMEOUT = HttpStatus(
        HttpStatusCode.STATUS_GATEWAY_TIMEOUT,
        Series.SERVER_ERROR,
        "Gateway Timeout"
    )

    /**
     * 505 HTTP Version Not Supported.
     * https://tools.ietf.org/html/rfc7231#section-6.6.6
     * HTTP/1.1: Semantics and Content, section 6.6.6
     */
    public static let HTTP_VERSION_NOT_SUPPORTED = HttpStatus(
        HttpStatusCode.STATUS_HTTP_VERSION_NOT_SUPPORTED,
        Series.SERVER_ERROR,
        "HTTP Version not supported"
    )

    /**
     * 506 Variant Also Negotiates
     * https://tools.ietf.org/html/rfc2295#section-8.1
     * Transparent Content Negotiation
     */
    public static let VARIANT_ALSO_NEGOTIATES = HttpStatus(
        HttpStatusCode.STATUS_VARIANT_ALSO_NEGOTIATES,
        Series.SERVER_ERROR,
        "Variant Also Negotiates"
    )

    /**
     * 507 Insufficient Storage
     * https://tools.ietf.org/html/rfc4918#section-11.5
     * WebDAV
     */
    public static let INSUFFICIENT_STORAGE = HttpStatus(
        HttpStatusCode.STATUS_INSUFFICIENT_STORAGE,
        Series.SERVER_ERROR,
        "Insufficient Storage"
    )

    /**
     * 508 Loop Detected
     * https://tools.ietf.org/html/rfc5842#section-7.2
     * WebDAV Binding Extensions
     */
    public static let LOOP_DETECTED = HttpStatus(
        HttpStatusCode.STATUS_LOOP_DETECTED,
        Series.SERVER_ERROR,
        "Loop Detected"
    )

    /**
     * 509 Bandwidth Limit Exceeded
     */
    public static let BANDWIDTH_LIMIT_EXCEEDED = HttpStatus(
        509,
        Series.SERVER_ERROR,
        "Bandwidth Limit Exceeded"
    )

    /**
     * 510 Not Extended
     * https://tools.ietf.org/html/rfc2774#section-7
     * HTTP Extension Framework
     */
    public static let NOT_EXTENDED = HttpStatus(
        HttpStatusCode.STATUS_NOT_EXTENDED,
        Series.SERVER_ERROR,
        "Not Extended"
    )

    /**
     * 511 Network Authentication Required.
     * https://tools.ietf.org/html/rfc6585#section-6
     * Additional HTTP Status Codes
     */
    public static let NETWORK_AUTHENTICATION_REQUIRED = HttpStatus(
        HttpStatusCode.STATUS_NETWORK_AUTHENTICATION_REQUIRED,
        Series.SERVER_ERROR,
        "Network Authentication Required"
    )

    private HttpStatus(
        public let value: UInt16,
        public let series: Series,
        public let reasonPhrase: String
    ) {}

    /**
     * 返回全部HttpStatus
     */
    public static prop values: Array<HttpStatus> 

    /**
     * 是否属于 HTTP 状态码1xx系列。这是检查 series 值的快捷方式。
     */
    public prop is1xxInformational: Bool 

    /**
     * 是否属于 HTTP 状态码2xx系列。这是检查 series 值的快捷方式。
     */
    public prop is2xxSuccessful: Bool 

    /**
     * 是否属于 HTTP 状态码3xx系列。这是检查 series 值的快捷方式。
     */
    public prop is3xxRedirection: Bool 

    /**
     * 是否属于 HTTP 状态码4xx系列。这是检查 series 值的快捷方式。
     */
    public prop is4xxClientError: Bool 

    /**
     * 是否属于 HTTP 状态码5xx系列。这是检查 series 值的快捷方式。
     */
    public prop is5xxServerError: Bool 

    /**
     * 是否属于 HTTP 错误状态码系列。这是检查 series 值的快捷方式。
     * is4xxClientError()
     * is5xxServerError()
     */
    public prop isError: Bool 

    /**
     * 返回该状态码的字符串表示形式。
     */
    public func toString(): String 

    public operator func ==(other: HttpStatus): Bool 

    /**
     * 返回与指定数值对应的 HttpStatus 枚举常量。
     *
     * @param：status - 要返回的枚举常量对应的数值。
     * @return：具有指定数值的枚举常量。
     * @throws：IllegalArgumentException - 如果该类中没有与指定数值对应的常量。
     */
    public static func valueOf(status: UInt16): HttpStatus 

    /**
     * 尝试将给定的状态码解析为对应的 HttpStatus 枚举实例。
     * 
     * @param status  HTTP 状态码（可能为非标准代码）
     * @return        对应的 HttpStatus 实例，如果未找到则返回 None
     */
    public static func resolve(status: UInt16): ?HttpStatus 
}
```

### `Series`
```cj
/**
 * HTTP 状态码系列。
 * 可通过 HttpStatus.series 获取。
 */
public struct Series <: Equatable<Series> {
    /**
     * 1xx - 信息
     */
    public static let INFORMATIONAL = Series(1)
    /**
     * 2xx - 成功
     */
    public static let SUCCESSFUL = Series(2)
    /**
     * 3xx - 重定向
     */
    public static let REDIRECTION = Series(3)
    /**
     * 4xx - 客户端错误
     */
    public static let CLIENT_ERROR = Series(4)
    /**
     * 5xx - 服务器错误
     */
    public static let SERVER_ERROR = Series(5)

    private Series(public let value: Int64) {}

    /**
     * 获取全部HttpStatus系列
     */
    public static prop values: Array<Series> 
    public operator func ==(series: Series) 
    /**
     * 获取HttpStatus系列
     * @param status HttpStatus
     * @return HttpStatus系列
     */
    public static func valueOf(status: HttpStatus): Series 
    /**
     * 尝试将给定的状态码解析为对应的Series。
     * @param status 状态码
     * @return Series 实例
     * @throws IllegalArgumentException 如果无法解析给定的状态码
     */
    public static func valueOf(status: Int64): Series 
    /**
     * 尝试将给定的状态码解析为对应的Series。
     * @param status 状态码
     * @return Series 实例，如果没有找到就返回None<Series>
     */
    public static func resolve(status: Int64): Option<Series> {
        let code = status / 100
        series.get(code)
    }
}
```

## 当前数据不足以完成业务要求时
执行`perform BreakingCommand(...)`，status是希望本次响应的HTTP状态码，data是希望返回的数据，Data是`f_data.Data`。
所有基本类型、字符串、Duration、DateTime的实例，以及所有使用`f_data.macros.DataAssist`修饰的类的实例都可以调用`toData()`函数转换成`Data`实例。
```cj
public class BreakingCommand <: Command<Unit>{
    private BreakingCommand(public let status: HttpStatus, public let data: Data){}

    public static func new<T>(status: HttpStatus, data: T): BreakingCommand where T <: ToData 
    public static func new(status: HttpStatus): BreakingCommand 
    public static func new(): BreakingCommand 
    public static func new<T>(data: T): BreakingCommand where T <: ToData 
}
```