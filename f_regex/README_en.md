# f_regex

## STDX dependency

Configure the environment variable: `export CANGJIE_STDX_DYNAMIC_PATH=/path/to/dynamic_stdx`

Regular expression extensions, regex caching and a regex DSL. You can also use the same-named APIs of this module through the `fountain::fountain.regex` package.

## Regular expression extensions

```cj
public interface ExtendRegex {
    /**Regular expression for integers*/
    static prop INTEGER: Regex
    /**Regular expression for decimals*/
    static prop DECIMAL: Regex
    /**Regular expression for real numbers*/
    static prop REAL_NUMBER: Regex
    /**Regular expression for e-mail addresses*/
    static prop EMAIL: Regex
    /**Regular expression for Duration strings*/
    static prop DURATION: Regex
    /**Regular expression for identifiers*/
    static prop IDENTIFIER: Regex
    /**Regular expression for BASE64*/
    static prop BASE64: Regex
    /**Convert a string containing wildcards into a regular expression*/
    static func wildcard(wildcard: String): Regex
    /**Replace the first substring found in input, starting the search at index*/
    func doReplace(input: String, replacement!: String, index!: Int64): String
    /**Replace all substrings after index*/
    func doReplaceAll(input: String, replacement!: String, index!: Int64): String
    /**Replace all substrings after index; the replacement is the return value of the callback, and None means do not replace*/
    func doReplaceAll(input: String, replacement!: (MatchData) -> ?String, index!: Int64): String
}
```

## String extension

```cj
/**
 * String extends this interface to initialize the current string as a regular expression
 * If solid is true, the regular expression lives for the whole process lifetime; otherwise it is cached in
 * fountain::f_cache.HeapCache, which caches at most 10000 regular expressions with a lifetime of one day
 */
public interface RegexFromString {
    func regex(flags!: Array<RegexFlag>, solid!: Bool): Regex
}
```

## Regex DSL

`RegexBuilder` strings common regex fragments into a readable builder form (immutable; every call returns a new builder):

```cj
public class RegexBuilder <: ToString & Equatable<RegexBuilder> {
    public func build(flags!: Array<RegexFlag> = [], solid!: Bool = false): Regex
    // Character classes: digit / notDigit / whitespace / wordChar / alpha / lowerAlpha / upperAlpha / boundary / decimal ...
    // Quantifiers: zeroOrOne / zeroOrMore / oneOrMore / greedy / notGreedy / startRange(min) / endRange(max) / range(min, max)
    // Groups: group(part) / group(dir, part) / notCapture / lookAhead / notLookAhead / lookBehind / notLookBehind
    // Character sets: builder[parts], builder[notIn: true, parts]
    // Assertions: start / end / any
    public func text(part: ToString): RegexBuilder
    public func oneOf<T>(parts: Iterable<T>): RegexBuilder where T <: ToString
}
```

Companion types: `SearchDirection` (group direction), `RegexReplacement` (the `$n` replacement template), `RegexBuilderException`.

```cj
import fountain::f_regex.*

let re = RegexBuilder()
    .start
    .oneOf(['a', 'b'])
    .digit.oneOrMore
    .end
    .build()
re.matches('a123')  // true
```

## Notes

- Instances from `regex(flags:, solid: true)` live for the whole process (compiled on every access to the static prop), while `solid: false` goes through the `HeapCache` (limit 10000, lifetime one day; the cache entry may become invalid once the `Regex` object is collected).
- The `index` of `doReplace`/`doReplaceAll` is a **byte index** (`String[index..]`), so multi-byte characters such as Chinese must be converted by the caller.
- Every prop/func of `RegexBuilder` returns a new instance, so it can be safely forked and reused.
