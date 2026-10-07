# f_exception

A library of semantic exception names: all of them hang under `f_base.BaseException`, for modules to throw and catch.

```cj
public import fountain::f_base.BaseException

// Every exception class follows the same template:
public class XXXException <: BaseException {
    public init()
    public init(message: String)
    public init(caused: Exception)
    public init(message: String, caused: Exception)
}
```

You can also use the same-named APIs of this module through the `fountain::fountain.exception` package.

## Exception list

| Type | Purpose |
|---|---|
| `DuplicateInstanceException` | Duplicate instance/singleton |
| `IllegalAccessException` | Illegal access (uninitialized, unauthorized use) |
| `IllegalArgException` | Illegal argument (**not** std's `IllegalArgumentException`) |
| `IllegalSizeException` | Illegal length/size |
| `IllegalStateException` | The object state does not allow the operation |
| `NoSuchElementException` | No element available |
| `NotConsideredException` | A branch not considered logically |
| `NotInstantiatedException` | Not yet instantiated/initialized |
| `NotSupportedTypeException` | Unsupported type |
| `NumberFormatException` | Invalid number format |
| `OutOfBoundsException` | Out of bounds (**not** std's `IndexOutOfBoundsException`) |
| `StatusException` | Wrong state (machine) |
| `TypeCastException` | Type cast failed |
| `TypeNotMatchException` | Type mismatch |
| `UnexpectedTokenException` | Unexpected token (lexing/parsing/protocol parsing) |
| `UnreachableException` | Unreachable branch (most commonly the `match` fallback) |
| `UnreadableException` | Not readable |
| `UnsupportedAccessException` | Unsupported access mode |
| `UnsupportedOperatorException` | Unsupported operator |
| `UnwritableException` | Not writable |

## Usage example

```cj
import fountain::f_exception.*

func parsePort(s: String): Int64 {
    if (s.isEmpty()) {
        throw IllegalArgException('illegal port: ${s}')
    }
    Int64.parse(s)
}

let ex = IllegalStateException('cleanup failed')
ex.addSuppressed(UnreadableException('cannot read tmp file'))  // BaseException supports suppressed exceptions
ex.printStackTrace(stdOutWriter())
```

## Notes

- All exceptions have only the 4 constructors and **no extra fields**: when context (index, key name) is needed, it can only go into `message`, or you can subclass to add fields (the `UnknownKeyException` of `f_pool` is an example that adds a `key` field).
- `IllegalArgException`/`OutOfBoundsException`/`NumberFormatException` and other exceptions with the same names as std ones are **not the same types**; catching by the std exception names will not catch the exceptions of this module.
