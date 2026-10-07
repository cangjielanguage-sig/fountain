# f_http


## STDX dependency

Configure the environment variable: `export CANGJIE_STDX_DYNAMIC_PATH=/path/to/dynamic_stdx`

### Configuration
```bash
#Half the size of the multipart buffer; 2048 bytes by default
export http_halfBufferSize=2048
#Temporary storage path of uploaded files; this example is the default path
export http_uploadDir=/tmp/fountain/upload
```

### `MediaType`
```cj
/**
 * Parent type of all data formats
 * Custom data formats can be implemented by extending this class
 */
public abstract class MediaType <: ToString & Hashable & Equatable<MediaType> {
    /**
     * @param mediaType Name of the format type
     */
    public MediaType(public let mediaType: String) 
    public open func toString(): String 
    public open func hashCode(): Int64 
    /**
     * Get a new MediaType instance by format name.
     * Some data formats have different charset definitions, for example text formats; others have different
     * parameters, for example multipart/form-data has a boundary.
     * This function is therefore needed to create a new MediaType based on the current instance
     */
    public func make(mediaType: String): MediaType
    public open operator func ==(other: MediaType): Bool 
    /**
     * The generic constraint is fountain::f_data.DataFields<T>; this function converts the argument into a byte array.
     * The usual way is to call data.toData() to get a fountain::f_data.Data instance, then call fromData(data: Data)
     * of this class to convert it into a byte array
     */
    public func fromDataFields<T>(data: T): Array<Byte> where T <: DataFields<T> 
    /**
     * Data can be obtained from a Data instance, converted into the data format represented by MediaType, and finally
     * converted into a byte array.
     * For example JsonValue.tryFromData(data) can convert a Data instance into a JsonValue.
     */
    public open func fromData(data: Data): Array<Byte>
    /**
     * Usually this converts a byte array into the data format represented by MediaType, and then into a Data instance
     * For example, first convert the byte array into a byte string according to the charset specified by the current
     * MediaType, and finally call JsonValue.fromStr(jsonStr).toData() to convert the json string into a Data instance
     */
    public open func toData(data: Array<Byte>): Data
    /**
     * Read bytes from an InputStream and convert them into Data
     */
    public open func toData(input: InputStream): Data 
    /**
     * Convert a string into the data format represented by MediaType, and then into a Data instance
     */
    public open func toData(data: String): Data 
    /**
     * Call T.fromData(data) on a Data instance to convert it into the generic type
     */
    public func toDataFields<T>(data: Data): T where T <: DataFields<T> {
        (T.fromData(data) as T).getOrThrow{MediaTypeException(data.toString())}
    }
    public func toDataFields<T>(data: Array<Byte>): T where T <: DataFields<T> {
        toDataFields<T>(toData(data))
    }
    public func toDataFields<T>(input: InputStream): T where T <: DataFields<T> {
        toDataFields<T>(toData(input))
    }
    public func toDataFields<T>(data: String): T where T <: DataFields<T> {
        toDataFields<T>(toData(data))
    }
}
```

### `MediaTypes`
```cj
/**
 * This class keeps all concrete MediaType implementations
 */
public class MediaTypes {
    /**
     * Register a MediaType instance
     */
    public static func register(mediaType: MediaType): Unit
    /**
     * Get a MediaType by mediaType name; an exception is thrown if the data format named by the argument has not been registered with MediaTypes
     */
    public static func parse(mediaType: String): MediaType 
    /**
     * Get a MediaType by mediaType name; returns None<MediaType> if the data format named by the argument has not been registered with MediaTypes
     */
    public static func tryParse(mediaType: String): ?MediaType 
}
```

### `MultipartFileBuilder`
```cj
/**
 * Builder of a multipart/form-data part, corresponding to one Content-Disposition and its data
 */
public class MultipartFileBuilder {
    /**
     * Name of this part
     */
    public func name(name: String): This 
    /**
     * Value of this part
     */
    public func value(content: Array<Byte>): This 
    /**
     * Value of this part; the argument is converted into a UTF8 byte array
     */
    public func value<T>(content: T): This where T <: ToString 
    /**
     * This part is a file
     */
    public func file(file: File): This 
    /**
     * This part comes from an InputStream, and the other arguments build the Content-Disposition.
     * @param fileName File name
     * @param content Data input stream
     * @param size Size of this part
     * @param creationDate Creation time of this part
     * @param modificationDate Last modification time of this part
     */
    public func file(fileName: String, content: InputStream, size!: Int64 = -1, 
                     creationDate!: ?DateTime = None<DateTime>, modificationDate!: ?DateTime = None<DateTime>): This
    /**
     * Build a MultipartFile instance and use the internal data of this class to build MultipartFormData,
     */
    public func build(): MultipartFormData 
}
```

### ``
```cj
public class MultipartFormData {
    /**
     * Boundary of the current multipart/form-data
     */
    public let boundary = 'FountainBoundary${RandomString().randomLettersNumbers(32)}'
    /**
     * Create a new part builder
     */
    public func newPart(): MultipartFileBuilder 
    /**
     * Convert the data into a byte sequence and write it to the argument output
     */
    public func encode(output: OutputStream): Unit
    /**
     * Returns a MultipartFileInputStream
     */ 
    public func input(): InputStream 
}
```

### `MultipartFileInputStream`
```cj
/**
 * Read multipart/form-data data from an instance of this class
 */
public class MultipartFileInputStream <: InputStream {
    public func read(buf: Array<Byte>): Int64
}
```

### Implemented data formats
- text/plain
- application/json
- multipart/form-data


### Other public types

- Media type implementations: `PlainTextMediaType`, `JsonMediaType` (`src/TextMediaType.cj`), `MultipartMediaType` (`src/MultipartMediaType.cj`).
- multipart parsing: `MultipartFormDataParser`, `DataMultiparts`, `DataMultipartTuples`, `DataMultipartList` (`src/MultipartFormDataParser.cj`).
- Header construction: `ContentDisposition`, `ContentDispositionType`, `ContentDispositionBuilder`.
- Time formats: `rfc1123`, `parseRfc1123` (`src/rfc.cj`).
- Configuration: `HttpConfig` (`src/HttpConfig.cj`).

## Security

```cj
/**
 * The Any type of the enum can in practice only handle String, ToString, InputStream, Array<Byte> and
 * f_data.ToData; other types are ignored and the reasonPhrase of HttpStatus is used as the response body instead.
 * OK: the current user's login state is valid and the privileges are correct.
 * SessionNotFound: the login state of the current user was not found; the user may not be logged in, or the login state may have expired.
 * InvalidSession: the login state of the current user was found, but the login information passed in this request is invalid.
 * SessionError: an error occurred while checking the login state of the current user; it may be an internal server error.
 * PrivilegeError: an error occurred while checking the privileges of the current user; it may be an internal server error.
 * NoPrivilege: the current user has no privilege to access the resource.
 * Constructors without an HttpStatus argument mean the response status code is 200
 */
public enum AuthStatus {
    | OK
    | SessionNotFound(HttpStatus, Any)
    | SessionNotFound(Any)
    | InvalidSession(HttpStatus, Any)
    | InvalidSession(Any)
    | SessionError(HttpStatus, Any)
    | SessionError(Any)
    | PrivilegeError(HttpStatus, Any)
    | PrivilegeError(Any)
    | NoPrivilege(HttpStatus, Any)
    | NoPrivilege(Any)

    public prop isOK: Bool {
        get(){
            match(this){
                case OK => true
                case _ => false
            }
        }
    }
}
/**
 * An implementation class of this interface decorated with fountain.bean.macros.@Bean can perform login state and privilege checks.
 * In an application project, if both the login state and the privileges must be checked, be sure to implement them in one class so that
 * one call checks both.
 */
public interface AuthHandler {
    /**
     * Check the login state and privileges of the current user
     * @param ctx Current request context
     * @param args Parameters of the function handling the current request
     * @return The check result of the current user's login state and privileges
     */
    func check(param: AuthParam): AuthStatus
}
/**
 * ctx: current request context
 * path: controller mapping path of the current request; not the requested path, but the path defined by the controller function
 * args: parameters of the current request
 * ignoreAuth: whether to skip the login check
 * ignorePrivilege: whether to skip the privilege check
 */
public struct AuthParam {
    public AuthParam(
        public let ctx: HttpContext,
        public let path: String,
        public let args: ArrayList<Any>,
        public let ignoreAuth: Bool,
        public let ignorePrivilege: Bool
    ){}
}
/**
 * Login check
 */
public interface UserSessionHandler <: AuthHandler {}
/**
 * Privilege check
 */
public interface PrivilegeHandler <: AuthHandler {}
```
