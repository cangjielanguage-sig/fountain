# f_config

Application configuration module: **it does not depend on any configuration file**; configuration items come from environment variables, command line
arguments, in-process registration (`Config.set`) and sensitive configuration embedded at compile time (`@EmbedSensitive`).

Besides reading and writing configuration, this module also provides `DateTimeConfConverter`: it uses the value of a configuration item as a time format.

## Contents

1. [STDX dependency](#1-stdx-dependency)
2. [Configuration sources and priority](#2-configuration-sources-and-priority)
3. [Config API](#3-config-api)
4. [Configuration refresh refresher](#4-configuration-refresh-refresher)
5. [Sensitive configuration and SM4 encryption](#5-sensitive-configuration-and-sm4-encryption)
6. [The @EmbedSensitive macro](#6-the-embedsensitive-macro)
7. [Configurable time converter](#7-configurable-time-converter)
8. [Known issues](#8-known-issues)

Module dependencies: `fountain::f_data` (`DataParsable`).

---

## 1. STDX dependency

This module depends on `stdx.crypto.crypto` (SM4) and `stdx.encoding.hex` (parsing the hexadecimal strings of the key/IV), which are already
pulled in through `${CANGJIE_STDX_DYNAMIC_PATH}` in `cjpm.toml`; configure the environment variable before use:

```bash
export CANGJIE_STDX_DYNAMIC_PATH=/path/to/dynamic_stdx
```

---

## 2. Configuration sources and priority

### 2.1 Command line arguments

Command line arguments override environment variables of the same name, and there are only four legal forms:

```
--argName=argValue
--argName            # Equivalent to --argName=true
-argName argVal
-argName             # Equivalent to -argName true
```

* `--argName=argValue`: the key is the left side of `=` and the value the right side; both sides are `trimAscii`ed;
* `-argName argVal`: if the next argument starts with `-`, it is not treated as the value, and the value of this configuration item is `true`;
* The single-hyphen form does not support `=` assignment; `-argName=argValue` is taken as the configuration item name as a whole;
* Arguments that do not start with `-` are ignored.
* `env.getCommandLine()[0]` (the path of the program itself) does not take part in parsing.

### 2.2 Naming style

This tool does not rewrite the naming of environment variables and command line arguments: the environment variables of the Cangjie runtime itself use
camel case, and business configuration is recommended to use camel case as well.

### 2.3 Read priority

The lookup order of one `getString(key)` is as follows; the first hit wins:

| Order | Source | Description |
| --- | --- | --- |
| 1 | Environment variable / command line argument (`ARGS[key]`) | Loaded by `static init` at process startup; a command line argument of the same name overrides the environment variable |
| 2 | The same-named item with the global prefix (`ARGS[fountain_key]`) | See 2.4 |
| 3 | Sensitive value embedded at compile time (`sensitiveMap[key]`) | See sections 5 and 6; with SM4 configured this is ciphertext, decrypted on read |
| 4 | Sensitive value with the global prefix (`sensitiveMap[fountain_key]`) | See 2.4 |

Therefore **runtime configuration (environment variables/command line arguments) has higher priority than values embedded at compile time**.

### 2.4 The global prefix `fountain`

`Config` has a built-in global prefix `fountain`. For any configuration item read through `getString(key)`, when the original name misses, `fountain_${key}` is tried as well; in the results of `getAll` the `fountain_` is removed.

```bash
export myAppSecret='xxx'          # Config.getString('myAppSecret') hits
export fountain_myAppSecret='xxx' # Equivalent form
```

Matching rule of `getAll(prefix)`: when `prefix` is empty all configuration items are returned, otherwise the key must start with `${prefix}_` or `fountain_${prefix}_`.

### 2.5 In-process writes

`Config.set` can write/overwrite configuration items at runtime (values are always converted with `toString()`) and triggers matching refresh callbacks
by the "first segment of the configuration item name" (see section 4).

---

## 3. Config API

```cj
package fountain::f_config

public import std.convert.Parsable
public import fountain::f_data.DataParsable

/**
 * Does not depend on configuration files; all configuration comes from environment variables and command line arguments, and a
 * command line argument overrides an environment variable of the same name.
 * This tool does not modify the naming style of environment variables and command line arguments; the environment variables of
 * the Cangjie runtime all use camel case, and environment variables and command line arguments used for application
 * configuration are recommended to use the same style.
 * Command line arguments must follow these rules
 *   1. --argName=argValue
 *   2. --argName
 *      * equivalent to --argName=true
 *   3. -argName argVal
 *   4. -argName
 *      * equivalent to -argName true
 * Sensitive configuration information is encrypted with sm4; if no sm4 encryption parameter is given, the UTF8 byte array of
 * the sensitive configuration is embedded in the build output.
 * If an sm4 encryption parameter is given, the ciphertext of the sensitive configuration is embedded in the build output.
 * - sm4Operation The OperationMode of SM4
 * - sm4Padding The PaddingMode of SM4
 * - sm4Key The key
 * - sm4Iv The IV
 * - sm4Aad The AAD of the ciphertext padding
 * - sm4TagSize The TagSize of the ciphertext padding
 */
public class Config {
    public static const sm4Operation = 'sm4Operation'
    public static const sm4Padding = 'sm4Padding'
    public static const sm4Key = 'sm4Key'
    public static const sm4Iv = 'sm4Iv'
    public static const sm4Aad = 'sm4Aad'
    public static const sm4TagSize = 'sm4TagSize'

    /**
     * Register a refresh callback for changes of configuration items with the prefix prefix
     */
    public static func refresher(prefix: String, fn: () -> Unit): Unit
    /**
     * If ifAbsent is true, the value is added only when the configuration item does not exist yet, otherwise the new configuration overwrites the old one
     */
    public static func set<T>(tuples: Array<(String, T)>, ifAbsent!: Bool = false): Unit where T <: ToString
    /**
     * Get the configuration items with the same prefix
     */
    public static func getAll(prefix: String): Map<String, String>
    /**
     * Get all configuration items
     */
    public static func getAll(): Map<String, String>
    /**
     * Get the configuration item named key
     */
    public static func getString(key: String): ?String
    /**
     * Get the configuration item named key and use parser to convert the configuration value into the given type
     */
    public static func getValue<T>(key: String, parser: (String) -> ?T): ?T
    /**
     * Get the configuration item named key and convert the configuration value into the given type
     */
    public static func getValue<T>(key: String): ?T where T <: Parsable<T>
    /**
     * Get the configuration item named key and split the configuration value by delim into a string array
     */
    public static func getStringArray(key: String, delim!: String = ','): Array<String>
    /**
     * Get the configuration item named key, split the configuration value by delim into a string array, and use parser to convert each element into the given type
     */
    public static func getValues<T>(key: String, delim!: String = ',', parser!: (String) -> T): Array<T>
    /**
     * Get the configuration item named key, split the configuration value by delim into a string array, and convert each element into the given type
     */
    public static func getValues<T>(key: String, delim!: String = ','): Array<T> where T <: Parsable<T>
    /**
     * Get the configuration item named key and convert the configuration value into a DateTime in the given format
     */
    public static func getDateTime(key: String, format!: String = ''): ?DateTime
    /**
     * Get the configuration item named key, split the configuration value by delim into a string array, and convert it into a DateTime array in the given format
     */
    public static func getDateTimes(key: String, format!: String = '', delim!: String = ','): Array<DateTime>
    /**
     * Get the configuration item named key and convert the configuration value into the given type
     */
    public static func getData<T>(key: String): ?T where T <: DataParsable<T>
    /**
     * Get the configuration item named key, split the configuration value by delim into a string array, and convert the elements into the given type
     */
    public static func getDatas<T>(key: String, delim!: String = ','): Array<T> where T <: DataParsable<T>
    /**
     * Get the configuration item named key and convert it into a Duration
     */
    public static func getDuration(key: String): ?Duration
    /**
     * Get the configuration item named key, split the configuration value by delim into a string array, and convert the elements into Durations
     */
    public static func getDurations(key: String, delim!: String = ','): Array<Duration>
    /**
     * Get the buffer size of the configuration item named bufferKey
     */
    public static func bufferSize(bufferKey: String, default: Int64, debugging: Bool): Int64
    /**
     * Build an SM4 from the sm4 configuration items of section 5; returns None when sm4Key is missing and throws
     * IllegalArgumentException when an argument is illegal
     */
    public static func getSM4(): ?SM4
    /**
     * Register a sensitive configuration item; value is the UTF8 plaintext byte array or SM4 ciphertext, usually called by
     * the expansion of @EmbedSensitive
     */
    public static func registerSensitive(key: String, value: Array<Byte>): Unit
}
```

### 3.1 Behavior details

| Function | Description |
| --- | --- |
| `set` | When `ifAbsent` is `false` (the default) the old value is overwritten; when it is `true` the value is written only if the configuration item did not exist. After writing, the first segment of each configuration item name (the part before `_`) is collected as the prefix and matching refresh callbacks are triggered |
| `getAll(prefix)` | Returns a `HashMap` whose keys have the `fountain_` global prefix removed; a runtime configuration of the same name overrides a value embedded at compile time |
| `getAll()` | Equivalent to `getAll('')`; returns all configuration items (including decrypted sensitive configuration) |
| `getStringArray` | Splits by `delim`, discards empty fragments and `trimAscii`s every element; returns an empty array when the configuration item is absent |
| `getValue` / `getData` | Single-value reads going through `tryParse`; a parse failure returns `None` and does not throw; a missing configuration item also returns `None` |
| `getValues` / `getDatas` | Array reads going through `parse` (which throws on failure); returns an empty array when the configuration item is absent |
| `getDateTime` | A parse failure throws `TimeParseException`; a missing configuration item returns `None` |
| `getDateTimes` | A parse failure throws `TimeParseException`; a missing configuration item returns an empty array |
| `getDateTime` / `getDateTimes` | When `format` is empty `DateTime.parse(s)` is used, otherwise `DateTime.parse(s, format)`; an illegal `format` itself throws `IllegalArgumentException` |
| `bufferSize` | See the explanation below the table |
| `getSM4` | See section 5 |

Return value of `bufferSize(bufferKey, default, debugging)`:

| Condition | Return value |
| --- | --- |
| The configuration item is absent, or the value fails to parse | `default` |
| The value `x <= 0` | `default` |
| `debugging == true` and `x > 0` | `x` is returned as is (used literally while debugging) |
| `x` is a power of two | `x` |
| Otherwise | Rounded up to the power of two `s`; returns `s` when `s >= default`, otherwise `default` |

That is, in non-debug mode the return value is never smaller than `default` and is usually a power of two.

Example:

```cj
import fountain::f_config.*

Config.getValue<Int64>('threadCount')                      // None or Int64
Config.getValues<Int64>('ports')                           // ports=8080,9090 -> [8080, 9090]
Config.getDateTime('deadline', format: 'yyyy-MM-dd')       // In the given format
Config.bufferSize('ringBufferSize', 1024, false)           // Not smaller than 1024 and rounded up to a power of two
Config.set<Bool>([('mySwitch', true)], ifAbsent: true)     // Write only if it does not exist
Config.getAll('orm')                                       // All configuration items starting with orm_ / fountain_orm_
```

---

## 4. Configuration refresh refresher

Other modules can cache the parse results of their own configuration and register a refresh function through `Config.refresher`; when someone calls
`Config.set` and changes configuration belonging to that prefix, `Config` calls back into `fn`.

```cj
static init() {
    Config.refresher(confPrefix, LoggerFactory.refresh)
}
```

* `refresher(prefix, fn)` registers the callback under the key `${prefix}_`; registering the same prefix again overwrites the previous one;
* `set` matches with the "first segment of the configuration item name": configuration registered under the prefix `logger` looks like `logger_asyncWaitTimeout`, `fountain_logger_rootLevel`;
* In one `set` call each prefix triggers its callback at most once.

> The matching of the current implementation is flawed: `set` actually triggers no callback at all, see [8.1](#81-refresher-matching-is-broken-refresh-callbacks-are-never-triggered).

---

## 5. Sensitive configuration and SM4 encryption

Some configuration (database passwords, third-party keys) is inconvenient to expose in the runtime environment. Such configuration can be read at
**compile time** from the environment variables/command line arguments of the build machine, encrypted and embedded into the build output as a byte
array; at process startup the code expanded from the macro registers it into a separate `sensitiveMap`, and it is then read through the regular
interfaces such as `getString`.

* Without SM4 configured: the embedded value is the **UTF8 plaintext** byte array of the sensitive value;
* With SM4 configured: the **SM4 ciphertext** is embedded, together with the SM4 parameters for decryption at runtime;
* Runtime configuration (environment variables/command line arguments) has higher priority: if the same configuration item is also set in the runtime environment, the runtime value wins.

### 5.1 SM4 configuration items

`fboot randhex 32` can generate a hexadecimal string of the given length (32 hexadecimal characters = 16 bytes).

| Configuration item | Meaning | Default | Values / format |
| --- | --- | --- | --- |
| `sm4Operation` | Operation mode | `CBC` | `CBC` `CFB` `CTR` `GCM` `OFB`; `ECB` is insecure and explicitly unsupported, any other value throws `IllegalArgumentException` |
| `sm4Padding` | Padding mode | `PKCS7Padding` | `NoPadding` `PKCS7Padding`, any other value throws `IllegalArgumentException` |
| `sm4Key` | Key | None, must be configured | 16 bytes, given as a hexadecimal string of length 32; missing or of the wrong length throws `IllegalArgumentException` |
| `sm4Iv` | Initialization vector | None (required once `sm4Key` is configured) | Hexadecimal string; `CBC`/`OFB`/`CFB` require 16 bytes and `GCM` requires 12 bytes, otherwise `IllegalArgumentException` |
| `sm4Aad` | Additional authenticated data | Empty byte array | Hexadecimal string |
| `sm4TagSize` | Tag length of GCM | `16` | `Int64` string |

These configuration items also support the `fountain_` prefixed form (`fountain_sm4Key`, etc.). Their name constants are `Config.sm4Operation`, `Config.sm4Key` and so on, which can be referenced directly.

Command line argument example (compile time):

```bash
export paySecretKey='......'
export sm4Key=$(fboot randhex 32)   # 16-byte key
export sm4Iv=$(fboot randhex 32)    # IV for CBC; use fboot randhex 24 for GCM
```

### 5.2 Data structures and reading

```cj
public static func registerSensitive(key: String, value: Array<Byte>): Unit  // Write into sensitiveMap
public static func getSM4(): ?SM4                                            // None when sm4Key is missing
```

* `sensitiveMap` is a `ConcurrentHashMap<String, Array<Byte>>`, independent of `ARGS`, written only by registerSensitive;
* When `getString` / `getAll` read a sensitive value they call `getSM4()` to decrypt it and then restore the string as UTF8; without SM4 configured the plaintext bytes are used;
* Every decryption **constructs a new `SM4` instance** and reads all SM4 configuration items; when there is a lot of sensitive configuration or it is read often, caching the result yourself is recommended.

> Note: the SM4 parameters themselves (including the key) appear in the build output as a byte array. This mechanism raises the bar for "grepping the
> configuration straight out of the binary"; it is not a replacement for a key management service.

---

## 6. The @EmbedSensitive macro

```cj
macro package fountain::f_config.macros

public macro EmbedSensitive(input: Tokens): Tokens
```

Called at the **top level** of a source file; the arguments are the names of the configuration items whose compile-time values must be embedded in the
output (identifiers; commas are also accepted, the macro only takes `IDENTIFIER` / string literal tokens and ignores the rest):

```cj
import fountain::f_config.macros.*

@EmbedSensitive(paySecretKey pushToken)
```

The macro expands into an immediately executed anonymous closure that registers the sensitive values into `sensitiveMap`:

```cj
private let _ = {=>
    Config.registerSensitive('paySecretKey', [...ciphertext or plaintext bytes...])
    Config.registerSensitive('pushToken', [...])
    Config.registerSensitive('sm4Operation', ...)
    Config.registerSensitive('sm4Padding', ...)
    Config.registerSensitive('sm4Key', ...)
    Config.registerSensitive('sm4Iv', ...)
    Config.registerSensitive('sm4Aad', ...)
    Config.registerSensitive('sm4TagSize', ...)
}()
```

Embedding rules:

1. **Names whose value cannot be obtained at compile time are ignored** (if the build machine has no corresponding environment variable/command line argument, nothing is registered);
2. When `sm4Key` is configured at compile time the SM4 ciphertext is written, otherwise the UTF8 plaintext byte array is written;
3. Only when "at least one sensitive value was registered" and "`sm4Key` is non-empty" are the SM4 operation / padding / key / iv / aad / tagSize written as well, for decryption at runtime; the SM4 parameters themselves are written as plaintext bytes;
4. When the same name is registered repeatedly the last registration wins;
5. Reading at runtime follows [the priority of 2.3](#23-read-priority): environment variable/command line argument > embedded value.

`f_orm` is an example of a wrapper around this macro: `f_orm/src/ProtectedMacros/EmbedSensitive.cj` generates the ORM connection string, user name and
password keys and forwards them to `@EmbedSensitive`, finally triggered as `@ORMEmbedSensitive()` in `f_orm/src/base/imports.cj`.

---

## 7. Configurable time converter

Uses the value of a configuration item as the parse format of a `DateTime`: a subclass of `fountain::f_data.AbstractDateTimeConverter`, which may be
applied to member properties, member variables and parameters.

```cj
package fountain::f_config

import fountain::f_data.*

@Annotation[target: [MemberProperty, MemberVariable, Parameter]]
public class DateTimeConfConverter <: AbstractDateTimeConverter {
    public const DateTimeConfConverter(private let conf: String, private let default!: String = 'yyyy-MM-dd HH:mm:ss'){}
    public func convert(data: Data, flag!: DataConversionFlag = DEFAULT_DATA_FLAG): ?DateTime
}
```

* `conf`: the name of the configuration item holding the time format, read according to [2.3](#23-read-priority) (with `fountain_` prefix fallback);
* `default`: the format used when that configuration item does not exist, `'yyyy-MM-dd HH:mm:ss'` by default.

```cj
@DateTimeConfConverter[myDateFormat]
private var createdAt: DateTime = DateTime.now()

// export myDateFormat='yyyy/MM/dd'
```

---

## 8. Known issues

### 8.1 refresher matching is broken; refresh callbacks are never triggered

`refresher` registers the callback under the key `${prefix}_` (with a trailing underscore), while the prefix collected by `Config.set` is the fragment of the
configuration item name **before** the first `_`:

```cj
REFRESHER['${prefix}_'] = fn                    // For example 'logger_'
...
if (let Some(x) <- name.indexOf('_')) {
    set.add(name[0..x])                         // 'logger_asyncWaitTimeout' -> 'logger' (without the underscore)
...
for (k in set where k.startsWith(prefix) || k.startsWith('${Config.prefix}_${prefix}')) {
```

In Cangjie `a..b` is a half-open interval, so `k` is always `'logger'`, `'logger'.startsWith('logger_')` is always `false`, and the second condition
`'fountain_logger_'` is even less likely to match. The result is that **a `set` writing configuration triggers no refresh callback at all** (it looks like
`name[0..x]` should be `name[0..=x]`).

Impact: `LoggerFactory.refresh` of `f_log` is never called again after registration; `ORMConfig.refresh{...}` of `f_orm` only gets one execution when it is
called in `static init`, and a later `set` of configuration at runtime is likewise not noticed.

### 8.2 SM4 exception messages still carry another module name

When `sm4Key` / `sm4Iv` is illegal, the `IllegalArgumentException` message is `"orm config item ${Config.sm4Key} ..."`, which comes from the implementation of
f_orm and has nothing to do with the configuration item names of this module; it is leftover wording.

### 8.3 Other implementation details

* `getAll` strips the prefix with `String.replace('fountain_', '')`, which replaces **every** matching fragment in the string, so a key containing the
  substring again in the middle loses it as well;
* All three branches of `SM4Conf.getBytes` return `Some`, so its `else` branch (the exception message for "no configuration item") is unreachable, and a
  missing configuration finally fails at the length check of key/iv;
* The prefix-stripping behavior of `getAll` is the same for `ARGS` and `sensitiveMap`; when the two have the same name, `ARGS` (runtime configuration) wins.
