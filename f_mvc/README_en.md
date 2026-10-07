# f_mvc


## STDX dependency

Configure the environment variable: `export CANGJIE_STDX_DYNAMIC_PATH=/path/to/dynamic_stdx`


## Configuration

```bash
    export mvc_port=8080 # This line may be omitted; the default is 8080
    export mvc_overallElapsedSwitch=true # Setting this to false in production is recommended; the default is false
    export mvc_internalServerErrorMessageKind=BEAN # Source of the response message when the business logic throws
    export mvc_internalServerErrorMessage=NameOf500Handler # The message when the business logic throws
    
    # The following configuration follows the defaults of stdx.net.http unless specified
    export mvc_readTimeout=500ms # Request read timeout, in the format of Duration toString()
    export mvc_readHeaderTimeout=500ms # Request header read timeout, in the format of Duration toString()
    export mvc_writeTimeout=500ms # Response write timeout, in the format of Duration toString()
    export mvc_keepAliveTimeout=500s # keepalive timeout, in the format of Duration toString()
    export mvc_maxRequestHeaderSize=102400 # Maximum number of bytes of the request header
    export mvc_maxRequestBodySize=67108864 # Maximum number of bytes of the request body; when unspecified it is the stdx.net.http default of 2MB

    # stdx.net.http has no defaults for the following, but MVC specifies defaults
    export mvc_downloadBufferSize=4096 # Buffer size for file downloads, 4096 by default
    export mvc_accessControlAllowOrigin='*' # Sets the response header Access-Control-Allow-Origin, '*' by default 
    export mvc_accessControlAllowHeaders='*' # Sets the response header Access-Control-Allow-Headers, '*' by default
    export mvc_accessControlMaxAge=0 # Sets the response header Access-Control-Max-Age, 0 by default

    # Listening address and the debugging switch
    export mvc_host=0.0.0.0 # Listening address, 0.0.0.0 by default
    export mvc_debugging=false # Debugging switch, false by default
    
    # HTTP/2 parameters; when unspecified the stdx.net.http defaults are used
    export mvc_headerTableSize=4096
    export mvc_maxConcurrentSteams=100 # Note: "Steams" in the key name is the spelling in the source code
    export mvc_initialWindowSize=65535
    export mvc_maxFrameSize=16384
    export mvc_maxHeaderListSize=16384
    
    # Static resource root directory
    export mvc_staticResourceRoot=/path/to/static
    
    # Business thread pool: all three keys must be given for it to take effect
    export mvc_servicePoolCapacity=64
    export mvc_servicePoolQueueCapacity=1024
    export mvc_servicePoolPreheat=8
    
    # TLS: mvc_tlsPath is "certificate file|private key file", the two parts separated by |
    export mvc_tlsPath=/path/to/cert.pem|/path/to/key.pem
    export mvc_tlsVerifyMode=trustAll # trustAll (trust_all/trust-all are also accepted) | any other value uses the stdx default verification | customCA | customVerify
    export mvc_tlsVerifyPem=/path/to/ca.pem # Used only when verifyMode=customCA
    export mvc_tlsVerifyBean=myVerifier # Used only when verifyMode=customVerify; the value is the name of the bean implementing CertificateVerifier
    export mvc_tlsSupportedAlpnProtocols=h2|http/1.1 # Several protocols separated by |
```

### Values of mvc_internalServerErrorMessageKind
- BEAN means the error response comes from a bean managed by `fountain::f_bean`; in that case the value of mvc_internalServerErrorMessage is the name of the bean. The type of that bean must implement the following interface
```cj
package fountain::f_mvc
public interface ErrorHttpRequestHandler {
    /**
     * @param ctx The stdx.net.http.HttpContext instance of the current http access
     * @param e The exception that occurred while handling the current http access
     * @return HttpStatus is the http status of this exception response;
     *         the HttpStatus type is fountain::f_mvc.HttpStatus and the default is HttpStatus.INTERNAL_SERVER_ERROR
     *         Any is the response body of this exception; the types actually returned may be
     *           - String: the response body is this string
     *           - ToString: the response body is the string returned by calling toString() on this object
     *           - InputStream: the response body is the data read from this input stream
     *           - Array<Byte>: the response body is this byte array
     *           - fountain::f_data.ToData: the response body is the object converted into a byte array according to the type
     *                 specified by the Accept request header
     *                 If Accept specifies several response body formats, they are sorted by the q value of each data format in the
     *                 order they appear in Accept, and the first format is taken as the response body format 
     */
    func handle(ctx: HttpContext, e: ?Exception): (HttpStatus, Any)
}
```
- TEXT: the value of mvc_internalServerErrorMessage is the data of the response body
- BASE64BINARY: the value of mvc_internalServerErrorMessage should be a piece of BASE64 text, and the byte array it decodes to is used as the response body data


## Declaring a controller

```cj
import fountain::f_mvc.*
import fountain::f_mvc.macros.*

//Besides registering the public instance functions of the controller with mvc, the @Controller macro expands the IOC @Bean macro; both
//the attributionless and the attribute form are supported.
//The attributes of the attribute form of @Controller can be used as attributes of the @Bean macro
//If aspects must be weaved into a controller function, decorate the controller class with @WeavedController
//Besides having the full functionality of @Controller, @WeavedController also expands the pointcut macro @Pointcut; the weaving rules
//are defined by the aspect developer
@Controller
public class HelloworldController {
    //Only public instance functions decorated with an annotation ending in Mapping are registered with MVC
    //path is the http request path
    //produces is the response body format
    //consumes is the request body format
    @GetMapping[path:"/helloworld", produces:'text/plain', consumes:'application/x-www-form-urlencoded']
    public func helloworld(): String {
        return "helloworld"
    }
}
```

### Controller function annotations
The names of these annotations all end in Mapping, and they all take the same initialization arguments, defined as follows:
- path the request path; path parameters contained in {} are supported, for example the path /api/user/{id} defines a path parameter named id
- produces the response body format; several response body formats may be separated by |; the default is application/json
- consumes the request body format; several request body formats may be separated by |; the default is application/json
- params this function handles the corresponding http access when the form parameters satisfy the rule given by this argument
- headers this function handles the corresponding http access when the request headers satisfy the rule given by this argument

#### Rule definition of params and headers
- rule1 & rule2 both the left and the right rule must be satisfied for the whole rule to be satisfied
- rule1 | rule2 the whole rule is satisfied when either the left or the right rule is satisfied
- !rule negates the rule on the right
- (rules) encloses the rules, usually used to change the evaluation order of the & | ! rules
- contains('a', 'b', 'c',...) means the form parameters or request header names must contain the parameter names or header names given in the brackets
- subset('a', 'b', 'c',...) means the form parameters or header names are a subset of the strings given in the brackets
- eg. for form parameters, the rule a.contains('1', '2') & (b.subset('s', 'd') | 'orderTime' | goodsId) means the value of the form parameter a of the current access must contain both '1' and '2', and either the value of the form parameter b must be a subset of ('s', 'd'), or the form parameters must contain the parameter name orderTime, or they must contain the form parameter name goodsId
- eg. the same rules also apply to request headers 

#### Declaration of Mapping
They may only decorate public instance functions of a controller class; decorating other functions has no effect
- `@GetMapping` request method GET
- `@PostMapping` request method POST
- `@PutMapping` request method PUT
- `@DeleteMapping` request method DELETE
- `@PatchMapping` request method PATCH


## Security annotations

They may only decorate public instance functions of a controller class; decorating other functions has no effect
- `@IgnoreAuth` ignores the login state check
- `@IgnorePrivilege` ignores the privilege check
- `@IgnoreSecurity` ignores both the login state and the privilege checks


## Redirect

```cj
/**
 * When a controller function returns a Redirect instance, MVC performs the redirection according to the Redirect instance
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
     * 301 when retain is false; 308 otherwise
     */
    public static func permanently(location: String, retain!: Bool = false): Redirect
    /**
     * 302 when retain is false; 307 otherwise
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
     * Returns all HttpStatus values
     */
    public static prop values: Array<HttpStatus> 

    /**
     * Whether it belongs to the HTTP status code 1xx series. This is a shortcut for checking the series value.
     */
    public prop is1xxInformational: Bool 

    /**
     * Whether it belongs to the HTTP status code 2xx series. This is a shortcut for checking the series value.
     */
    public prop is2xxSuccessful: Bool 

    /**
     * Whether it belongs to the HTTP status code 3xx series. This is a shortcut for checking the series value.
     */
    public prop is3xxRedirection: Bool 

    /**
     * Whether it belongs to the HTTP status code 4xx series. This is a shortcut for checking the series value.
     */
    public prop is4xxClientError: Bool 

    /**
     * Whether it belongs to the HTTP status code 5xx series. This is a shortcut for checking the series value.
     */
    public prop is5xxServerError: Bool 

    /**
     * Whether it belongs to the HTTP error status code series. This is a shortcut for checking the series value.
     * is4xxClientError()
     * is5xxServerError()
     */
    public prop isError: Bool 

    /**
     * Returns the string representation of this status code.
     */
    public func toString(): String 

    public operator func ==(other: HttpStatus): Bool 

    /**
     * Returns the HttpStatus enum constant corresponding to the given numeric value.
     *
     * @param: status - the numeric value of the enum constant to return.
     * @return: the enum constant with the given numeric value.
     * @throws: IllegalArgumentException - if there is no constant with the given numeric value in this class.
     */
    public static func valueOf(status: UInt16): HttpStatus 

    /**
     * Try to parse the given status code into the corresponding HttpStatus enum instance.
     * 
     * @param status  HTTP status code (possibly non-standard)
     * @return        The corresponding HttpStatus instance, or None if it is not found
     */
    public static func resolve(status: UInt16): ?HttpStatus 
}
```

### `Series`
```cj
/**
 * The HTTP status code series.
 * Available through HttpStatus.series.
 */
public struct Series <: Equatable<Series> {
    /**
     * 1xx - Informational
     */
    public static let INFORMATIONAL = Series(1)
    /**
     * 2xx - Successful
     */
    public static let SUCCESSFUL = Series(2)
    /**
     * 3xx - Redirection
     */
    public static let REDIRECTION = Series(3)
    /**
     * 4xx - Client error
     */
    public static let CLIENT_ERROR = Series(4)
    /**
     * 5xx - Server error
     */
    public static let SERVER_ERROR = Series(5)

    private Series(public let value: Int64) {}

    /**
     * Get all HttpStatus series
     */
    public static prop values: Array<Series> 
    public operator func ==(series: Series) 
    /**
     * Get the HttpStatus series
     * @param status HttpStatus
     * @return The HttpStatus series
     */
    public static func valueOf(status: HttpStatus): Series 
    /**
     * Try to parse the given status code into the corresponding Series.
     * @param status Status code
     * @return A Series instance
     * @throws IllegalArgumentException if the given status code cannot be parsed
     */
    public static func valueOf(status: Int64): Series 
    /**
     * Try to parse the given status code into the corresponding Series.
     * @param status Status code
     * @return A Series instance, or None<Series> if it is not found
     */
    public static func resolve(status: Int64): Option<Series> {
        let code = status / 100
        series.get(code)
    }
}
```


## When the current data is not enough to complete the business requirement

When the current data is not enough to complete the business requirement you can execute `perform MVCBreakingCommand(...)` to leave the current
business thread stack and reach the bottom of the stack immediately.
This perform is handled by the mvc framework, but there is no resume.
There is no need to worry about unreleased resources in the business logic: the runtime executes the finally blocks appearing in the whole thread
stack in reverse order of function calls.
status is the HTTP status code desired for this response, data is the data desired to be returned, and Data is `fountain::f_data.Data`.
Instances of all basic types, strings, Duration and DateTime, as well as instances of all classes decorated with
`fountain::f_data.macros.DataAssist`, can call the `toData()` function to convert themselves into a `Data` instance.
```cj
public class MVCBreakingCommand <: BreakingCommand {
    public MVCBreakingCommand(data: Data, public let status: HttpStatus)
    public init(status: HttpStatus)
    public init(data: Data)
    public init()

    public static func new<T>(data: T): MVCBreakingCommand where T <: ToData 
    public static func new<T>(data: T, status: HttpStatus): MVCBreakingCommand where T <: ToData 
}
```
The generic base class without a status, `BreakingCommand`, is defined in `fountain::f_data.base`; business code/frameworks may extend it to express
the semantics of "leave the current stack"; `MVCBreakingCommand` adds the `status` on top of it, and the mvc framework is responsible for turning it
into an HTTP response.


## WebSocket

A class decorated with `@WSEndPoint` is registered as a bean automatically and upgrades requests of "`GET` + `Upgrade: websocket`" into WebSocket
connections (responding `101 Switching Protocols`).

### Options of `@WSEndPoint`

```cj
@WSEndPoint['/ws/echo', subProtocols: ['chat'], origins: ['example.com'], userFunc: {req => HttpHeaders()}]
public class EchoEndPoint {
    // Only public instance member functions decorated with @OnWS* or @WSPing may be declared, and their names must be unique in the current class
}
```

- `'.....'`: the URL path; it must be given, must be the first thing in attr, and must be of string type
- `subProtocols: [....]`
- `origins: [....]`
- `userFunc: ...`: any correct closure, or the identifier of a function visible in the current scope of this macro; the function type is `(HttpRequest) -> HttpHeaders`

The type decorated with this macro must be a class. In the decorated class, **only and exactly** the functions decorated with an annotation starting
with `@OnWS*` and the functions decorated with `@WSPing` are public instance member functions, and their names must be unique in the current class.

### Annotation list

| Annotation | Target | Description |
|---|---|---|
| `@OnWSOpen` | Instance function | The connection is established. To write to the client actively, declare the WebSocket parameter and keep this WebSocket instance (`WSMeta` provides several static write functions as helpers) |
| `@OnWSText` | Instance function | A text frame is received |
| `@OnWSBinary` | Instance function | A binary frame is received |
| `@OnWSClose` | Instance function | The connection is closed |
| `@OnWSPing` / `@OnWSPong` | Instance function | A ping frame / pong frame is received |
| `@WSPing(duration!: String = '30s', mediaType!: String = '')` | Instance function | The server actively sends pings at the given period |
| `@WSTextFrame` / `@WSBinaryFrame` | Function parameter | Inject the frame data into that parameter |

### Metadata and argument extraction

`fountain::f_mvc.WSMeta<T>` describes the handler functions of the endpoint (`openMeta`/`closeMeta`/`textMeta`/`binaryMeta`/`pingMeta`/`pongMeta`/`pingFunc`)
and provides argument extraction helpers: `extractOpenArg`, `extractCloseArg`, `extractTextArg`, `extractBinaryArg`, `extractPingArg`, `extractPongArg`
(each also has a "with default value" overload).

The frame type `WSCloseFrame` represents a close frame; the exception class is `WSException`.

### Minimal example

```cj
import fountain::f_mvc.*
import fountain::f_mvc.macros.*

// Only upgrades; no @OnWS* handler is declared (legal: equivalent to an empty meta, useful for verifying handshake routing)
@WSEndPoint['/ws/smoke']
public class SmokeWSEndPoint {}
```

## FileDownload 


### Import
```cj
import fountain::f_mvc.FileDownload
```

### API
```cj
public class FileDownload {
    /**
     * multi: whether several files are downloaded
     * contentType: the ContentType response header, application/octet-stream by default. When several files are downloaded this value is the Content-Type of the first file
     */
    public FileDownload(private let multi!: Bool = false,
        private let contentType!: String = "application/octet-stream") 
    /**
     * When there is no file to download, call only this function.
     */
    public func noContent(): Unit 
    /**
     * Write one file to the http output stream; when a single file whose content comes from a disk file is downloaded, call this function
     */
    public func write(file: File): Unit 
    /**
     * Write one InputStream to the http output stream; when a single file whose content comes from an InputStream is downloaded, call this function.
     * @param filename: the file name of the download
     * @param input: the input stream
     * @param length: the length of the input stream, -1 by default, meaning an unknown length
     */
    public func write(filename: String, input: InputStream, length!: Int64 = -1) 
    /**
     * Write one byte array to the http output stream; when several files or a particularly large file are downloaded, call this function.
     * @param bytes: the byte array
     */
    public func write(bytes: Array<Byte>): Unit 
    /**
     * Be sure to call the other functions inside the argument of this function
     */
    public func exec(fn: (FileDownload) -> Unit): Unit 
    /**
     * Create a file download object; when several files are downloaded, call this function to indicate that the download starts.
     * If only one particularly large file is downloaded, call this function to indicate that the download starts.
     * This function is called at most once per http access.
     * After calling this function, do not call write(file: File): Unit or write(filename: String, input: InputStream, length!: Int64 = -1): Unit
     * @param filename: the file name of the download
     * @param length: the file length, -1 by default, meaning an unknown length
     */
    public func start(filename: String, length!: Int64 = -1): FileDownload 
    /**
     * Metadata of the next file to download; call this function when writing the second and later files, or before writing the content of the next file.
     * @param filename: the file name of the download
     * @param contentType: the Content-Type of the file to download
     * @param length: the length of the file to download, -1 by default, meaning an unknown length
     */
    public func next(filename: String, contentType: String, length!: Int64 = -1): Unit 
    /**
     * Call this function when all files have been downloaded. This function is called only once.
     * If write(file: File): Unit and write(filename: String, input: InputStream, length!: Int64 = -1): Unit have already been called, this
     * function does not have to be called; they call it automatically.
     */
    public func end() 
}
```

### FileDownloadMeta 
Used as the return type of a controller function
multi says whether this download downloads several files; it is false by default

contentType is the ContentType response header of the first downloaded file; it is application/octet-stream by default.
When several files are downloaded, contentType becomes the Content-Type of the Content-Disposition of the response body, while the Content-Type
response header is multipart/x-mixed-replace; boundary=${boundary}

exec becomes the exec function argument of the FileDownload
```cj
public struct FileDownloadMeta {
    public FileDownloadMeta(
        let multi!: Bool = false,
        let contentType!: String = "application/octet-stream",
        let exec!: (FileDownload) -> Unit
    ){}
}
```

#### Convenience functions
```cj
public func download(data: File): Unit 

public func download(data: InputStream, filename: String, length!: Int64 = -1): Unit 

public func download(data: Array<Byte>, filename: String): Unit 

public func download<C>(data: C): Unit where C <: Iterable<(InputStream, String)> 

public func download(data: Array<File>): Unit
```
