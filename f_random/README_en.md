# f_random

`f_random` extends `std.random.Random` of the Cangjie standard library and `stdx.crypto.crypto.SecureRandom` of stdx with ranged random
numbers, random number stream iterators and similar capabilities, and additionally provides the thread-local random source
`ThreadLocalRandom`, reservoir sampling `randomReservoir` and the random string generator `RandomString`.

- Package: `fountain::f_random`
- Dependencies: `fountain::f_base` (it uses the `StringGenerator` and `ThreadLocal` there)
- You may also import the root package `fountain::fountain.random`, which exports the same-named APIs of this module through `public import fountain::f_random.*`

## Contents

- [STDX dependency](#stdx-dependency)
- [Adding the dependency](#adding-the-dependency)
- [Quick start](#quick-start)
- [Random number extensions](#random-number-extensions)
- [Random number iterators](#random-number-iterators)
- [Reservoir algorithm](#reservoir-algorithm)
- [Random strings](#random-strings)
- [ThreadLocalRandom](#threadlocalrandom)
- [Notes and known behavior](#notes-and-known-behavior)


## STDX dependency

Configure the environment variable: `export CANGJIE_STDX_DYNAMIC_PATH=/path/to/dynamic_stdx`

Windows PowerShell: `$env:CANGJIE_STDX_DYNAMIC_PATH = "path\to\dynamic_stdx"`

This variable is referenced by the `bin-dependencies.path-option` of every target in `cjpm.toml`; if it is not set, the stdx dynamic libraries cannot be found at link time.


## Adding the dependency

```toml
[dependencies]
  "fountain::f_random" = {path = "../f_random"}
```

This module `public import`s `Random` and `SecureRandom` as well, so a single import brings in both the standard library types and the extensions of this module:

```cj
import fountain::f_random.*
// or: import fountain::fountain.random.*
```

Note: the extension methods (such as `nextInt64(min, max, closed:)`) become visible only after this module is imported.


## Quick start

```cj
import fountain::f_random.*

main() {
    let rand = Random()

    // A random integer in a range; when closed is true the upper bound is included: [1, 100]
    let dice = rand.nextInt64(1, 100, closed: true)
    // A floating point number in the range [0.0, 1.0)
    let ratio = rand.nextFloat64(0.0, 1.0)

    // Random number stream: an infinite iterator producing a new random number on every next()
    let stream = rand.randomInt64(0, 10)
    let next = stream.next() ?? 0

    // Random strings; ThreadLocalRandom is used by default, and threads do not interfere with each other
    let rs = RandomString()
    println(rs.randomLettersNumbers(16))
    println(rs.randomLowerHex(8))

    // Reservoir sampling: take a given number of elements at random with a single pass over the data source
    let sample = randomReservoir<Int64>(3, [1, 2, 3, 4, 5, 6, 7, 8])
}
```

`SecureRandom` is used in exactly the same way; when cryptographic strength is needed, replace `Random()` with `SecureRandom()` or `ThreadLocalRandom.current`.


## Random number extensions

This module uses `extend Random <: ExtendRandom<Random>` and `extend SecureRandom <: ExtendRandom<SecureRandom>` to implement the two interfaces
below on the `Random` and `SecureRandom` classes, so no wrapper is needed and they can be called directly.

```cj
//Both std.random.Random and stdx.crypto.crypto.SecureRandom are extended with this interface
public interface ExtendRandom<R> where R <: ExtendRandom<R> {
    func nextFloat64(): Float64
    func nextFloat32(): Float32
    /**
     * Returns a random number in the range from min to max; closed says whether max is included
     */
    func nextFloat64(min: Float64, max: Float64, closed!: Bool): Float64
    /**
     * Returns a random number in the range from min to max; closed says whether max is included
     */
    func nextFloat32(min: Float32, max: Float32, closed!: Bool): Float32
    /**
     * Returns a random number in the range from min to max; closed says whether max is included
     */
    func nextInt64(min: Int64, max: Int64, closed!: Bool): Int64
    /**
     * Returns a random number in the range from min to max; closed says whether max is included
     */
    func nextUInt64(min: UInt64, max: UInt64, closed!: Bool): UInt64
    /**
     * Returns a random number in the range from min to max; closed says whether max is included
     */
    func nextInt32(min: Int32, max: Int32, closed!: Bool): Int32
    /**
     * Returns a random number in the range from min to max; closed says whether max is included
     */
    func nextUInt32(min: UInt32, max: UInt32, closed!: Bool): UInt32
}
```

In the **implementation**, every method of `ExtendRandom` gives `closed` the default value `false`, so a call such as `rand.nextInt64(1, 100)` is legal.
The actual semantics of `closed` are described in [Notes and known behavior](#notes-and-known-behavior).

```cj

//Both std.random.Random and stdx.crypto.crypto.SecureRandom are extended with this interface
public interface BaseRandom<R> where R <: BaseRandom<R> {
    /**
     * Get a random number of type Bool; throws when it fails
     * Return value Bool - a random number of type Bool
     */
    func nextBool(): Bool

    /**
     * Get a random number of type UInt8; throws when it fails
     * Return value UInt8 - a random number of type UInt8
     */
    func nextUInt8(): UInt8

    /**
     * Get a random number of type UInt16; throws when it fails
     * Return value UInt16 - a random number of type UInt16
     */
    func nextUInt16(): UInt16

    /**
     * Get a random number of type UInt32; throws when it fails
     * Return value UInt32 - a random number of type UInt32
     */
    func nextUInt32(): UInt32

    /**
     * Get a random number of type UInt64; throws when it fails
     * Return value UInt64 - a random number of type UInt64
     */
    func nextUInt64(): UInt64

    /**
     * Get a random number of type Int8; throws when it fails
     * Return value Int8 - a random number of type Int8
     */
    func nextInt8(): Int8

    /**
     * Get a random number of type Int16; throws when it fails
     * Return value Int16 - a random number of type Int16
     */
    func nextInt16(): Int16

    /**
     * Get a random number of type Int32; throws when it fails
     * Return value Int32 - a random number of type Int32
     */
    func nextInt32(): Int32

    /**
     * Get a random number of type Int64; throws when it fails
     * Return value Int64 - a random number of type Int64
     */
    func nextInt64(): Int64

    /**
     * Get a random number of type UInt8 in the range [0, max); throws when it fails
     * Parameter max - the maximum of the range; max <= 0 throws an illegal argument exception
     * Return value UInt8 - a random number of type UInt8
     */
    func nextUInt8(max: UInt8): UInt8

    /**
     * Get a random number of type UInt16 in the range [0, max); throws when it fails
     * Parameter max - the maximum of the range; max <= 0 throws an illegal argument exception
     * Return value UInt16 - a random number of type UInt16
     */
    func nextUInt16(max: UInt16): UInt16

    /**
     * Get a random number of type UInt32 in the range [0, max); throws when it fails
     * Parameter max - the maximum of the range; max <= 0 throws an illegal argument exception
     * Return value UInt32 - a random number of type UInt32
     */
    func nextUInt32(max: UInt32): UInt32

    /**
     * Get a random number of type UInt64 in the range [0, max); throws when it fails
     * Parameter max - the maximum of the range; max <= 0 throws an illegal argument exception
     * Return value UInt64 - a random number of type UInt64
     */
    func nextUInt64(max: UInt64): UInt64

    /**
     * Get a random number of type Int8 in the range [0, max); throws when it fails
     * Parameter max - the maximum of the range; max <= 0 throws an illegal argument exception
     * Return value Int8 - a random number of type Int8
     */
    func nextInt8(max: Int8): Int8

    /**
     * Get a random number of type Int16 in the range [0, max); throws when it fails
     * Parameter max - the maximum of the range; max <= 0 throws an illegal argument exception
     * Return value Int16 - a random number of type Int16
     */
    func nextInt16(max: Int16): Int16

    /**
     * Get a random number of type Int32 in the range [0, max); throws when it fails
     * Parameter max - the maximum of the range; max <= 0 throws an illegal argument exception
     * Return value Int32 - a random number of type Int32
     */
    func nextInt32(max: Int32): Int32

    /**
     * Get a random number of type Int64 in the range [0, max); throws when it fails
     * Parameter max - the maximum of the range; max <= 0 throws an illegal argument exception
     * Return value Int64 - a random number of type Int64
     */
    func nextInt64(max: Int64): Int64

    /**
     * Get a random number of type Float16 in the range 0.0 to 1.0; throws when it fails
     * Return value Float16 - a random number of type Float16
     */
    func nextFloat16(): Float16

    /**
     * Get a random number of type Float32 in the range 0.0 to 1.0; throws when it fails
     * Return value Float32 - a random number of type Float32
     */
    func nextFloat32(): Float32

    /**
     * Get a random number of type Float64 in the range 0.0 to 1.0; throws when it fails
     * Return value Float64 - a random number of type Float64
     */
    func nextFloat64(): Float64

    /**
     * Get a random number of type Float16 following a Gaussian distribution with mean 0.0 and standard deviation 1.0; throws when it fails
     * Return value Float16 - a random number of type Float16
     */
    func nextGaussianFloat16(mean!: Float16, sigma!: Float16): Float16

    /**
     * Get a random number of type Float32 following a Gaussian distribution with mean 0.0 and standard deviation 1.0;
     * throws when it fails
     * Return value Float32 - a random number of type Float32
     */
    func nextGaussianFloat32(mean!: Float32, sigma!: Float32): Float32

    /**
     * Get a random number of type Float64 following a Gaussian distribution with mean 0.0 and standard deviation 1.0;
     * throws when it fails
     * Return value Float64 - a random number of type Float64
     */
    func nextGaussianFloat64(mean!: Float64, sigma!: Float64): Float64

    func randomInt64(min: Int64, max: Int64, closed!: Bool): Iterator<Int64>
    func randomUInt64(min: UInt64, max: UInt64, closed!: Bool): Iterator<UInt64>
    func randomInt32(min: Int32, max: Int32, closed!: Bool): Iterator<Int32>
    func randomUInt32(min: UInt32, max: UInt32, closed!: Bool): Iterator<UInt32>
    func nextBytes(length: Int64): Array<Byte> {
        Array<UInt8>(length) {_ => nextUInt8()}
    }
    /**
     * Generate random numbers that replace every element of the argument array
     * Parameter array - pass an array
     * Return value Array<UInt8> - returns the replaced Array
     */
    func nextUInt8s(array: Array<UInt8>): Array<UInt8> {
        for (i in 0..array.size) {
            array[i] = nextUInt8()
        }
        array
    }

    /**
     * Get Gaussian Float16 random numbers
     * Return value Float16 - returns a Gaussian random number of type Float16
     */
    func randomGaussianFloat16Stream(mean!: Float16, sigma!: Float16): Iterator<Float16>

    /**
     * Get Gaussian Float32 random numbers
     * Return value Float32 - returns a Gaussian random number of type Float32
     */
    func randomGaussianFloat32Stream(mean!: Float32, sigma!: Float32): Iterator<Float32>

    /**
     * Get Gaussian Float64 random numbers
     * Return value Float64 - returns a Gaussian random number of type Float64
     */
    func randomGaussianFloat64Stream(mean!: Float64, sigma!: Float64): Iterator<Float64>
}
```

Most of the capabilities declared in `BaseRandom` come from the methods `Random`/`SecureRandom` already have; this module unifies them onto the
interface through `extend` and only provides the additional members listed in the next section.


## Random number iterators

`RandomIterator.cj` extends `Random` and `SecureRandom` with the following members, turning "one random number at a time" into "a stream of random numbers":

```cj
// The extension on Random has prop current: Random and the one on SecureRandom has prop current: SecureRandom; both return themselves
public prop current: Random
public prop current: SecureRandom

// Infinite iterators producing one random number in [min, max) or [min, max] on every next()
public func randomInt64(min: Int64, max: Int64, closed!: Bool = false): Iterator<Int64>
public func randomUInt64(min: UInt64, max: UInt64, closed!: Bool = false): Iterator<UInt64>
public func randomInt32(min: Int32, max: Int32, closed!: Bool = false): Iterator<Int32>
public func randomUInt32(min: UInt32, max: UInt32, closed!: Bool = false): Iterator<UInt32>

// Gaussian random number streams; mean defaults to 0.0 and sigma to 1.0
public func randomGaussianFloat16Stream(mean!: Float16 = 0.0, sigma!: Float16 = 1.0): Iterator<Float16>
public func randomGaussianFloat32Stream(mean!: Float32 = 0.0, sigma!: Float32 = 1.0): Iterator<Float32>
public func randomGaussianFloat64Stream(mean!: Float64 = 0.0, sigma!: Float64 = 1.0): Iterator<Float64>
```

Notes:

- The `next()` of these iterators always returns `Some`, that is, they are **infinite iterators**, so you must control how many numbers to take yourself.
- The concrete iterator classes (`RangeRandomInt64Iterator`, `RandomGaussianFloat64Iterator`, etc.) are package-visible only and cannot be
  instantiated from outside; get them through the factory methods above.


## Reservoir algorithm

```cj
public func randomReservoir<T>(count: Int64, source: Iterable<T>, priv!: Bool = false): ArrayList<T>
```

Takes `count` elements at random from `source` with a single pass over the data source, without knowing the total number of elements in advance;
well suited to sampling streaming or very large data sources.

- `priv` is the initialization argument of the internal `SecureRandom`; every call creates a new `SecureRandom`.
- The size of the return value is `min(count, number of elements in the data source)`, so it is smaller than `count` when `source` has too few elements.
- When `count <= 0` and the data source is not empty, an illegal argument exception is thrown; see [Notes and known behavior](#notes-and-known-behavior).

```cj
let sample = randomReservoir<Int64>(2, [1, 2, 3, 4, 6])
```


## Random strings

```cj
/*
   The conversion from Rune to UInt32 uses UInt32(e), where e is an expression of type Rune; the result of UInt32(e)
   is the integer value of type UInt32 corresponding to the Unicode scalar value of e.
   The conversion from an integer type to Rune uses Rune(num), where num may be of any integer type, and only when
   the value of num falls in [0x0000, 0xD7FF] or [0xE000, 0x10FFFF] (that is, a Unicode scalar value) does it return
   the character represented by the corresponding Unicode scalar value; otherwise it is a compile error (when the
   value of num can be determined at compile time) or a runtime exception.
 */
public class RandomString{
    public RandomString(private let rand!: SecureRandom = ThreadLocalRandom.current)
    public init(priv: Bool)
    /**Returns a string of count ASCII characters*/
    public func randomAscii(count: Int64): String
    /**
     * The length of the random string is a random value from min to max; characters are taken at random from all ASCII characters
     */
    public func randomAscii(min: Int64, max: Int64): String 
    /**
     * Take count characters at random from source
     */
    public func random(count: Int64, source: String): String 
    /**
     * Take count characters at random from source
     */
    public func random(count: Int64, source: Array<Rune>): String 
    /**
     * The length of the random string is a random value from min to max; characters are taken at random from source
     */
    public func random(min: Int64, max: Int64, source: String): String 
    /**
     * Take count characters at random from the lower-case English letters
     */
    public func randomLowerLetters(count: Int64): String 
    /**
     * The length of the random string is a random value from min to max; characters are taken at random from the lower-case English letters
     */
    public func randomLowerLetters(min: Int64, max: Int64): String 
    /**
     * Take count characters at random from the upper-case English letters
     */
    public func randomUpperLetters(count: Int64): String 
    /**
     * The length of the random string is a random value from min to max; characters are taken at random from the upper-case English letters
     */
    public func randomUpperLetters(min: Int64, max: Int64): String 
    /**
     * Take count characters at random from the English letters
     */
    public func randomAllLetters(count: Int64): String 
    /**
     * The length of the random string is a random value from min to max; characters are taken at random from the English letters
     */
    public func randomAllLetters(min: Int64, max: Int64): String 
    /**
     * Take count characters at random from the digits
     */
    public func randomNumbers(count: Int64): String 
    /**
     * The length of the random string is a random value from min to max; characters are taken at random from the digits
     */
    public func randomNumbers(min: Int64, max: Int64): String 
    /**
     * Take count characters at random from the lower-case hexadecimal characters (0-9a-f)
     */
    public func randomLowerHex(count: Int64): String
    /**
     * The length of the random string is a random value from min to max; characters are taken at random from the lower-case hexadecimal characters
     */
    public func randomLowerHex(min: Int64, max: Int64): String
    /**
     * Take count characters at random from the upper-case hexadecimal characters (0-9A-F)
     */
    public func randomUpperHex(count: Int64): String
    /**
     * The length of the random string is a random value from min to max; characters are taken at random from the upper-case hexadecimal characters
     */
    public func randomUpperHex(min: Int64, max: Int64): String
    /**
     * Take count characters at random from the lower-case English letters and digits
     */
    public func randomLowerLettersNumbers(count: Int64): String 
    /**
     * The length of the random string is a random value from min to max; characters are taken at random from the lower-case English letters and digits
     */
    public func randomLowerLettersNumbers(min: Int64, max: Int64): String 
    /**
     * Take count characters at random from the upper-case English letters and digits
     */
    public func randomUpperLettersNumbers(count: Int64): String 
    /**
     * The length of the random string is a random value from min to max; characters are taken at random from the upper-case English letters and digits
     */
    public func randomUpperLettersNumbers(min: Int64, max: Int64): String 
    /**
     * Take count characters at random from the English letters and digits
     */
    public func randomLettersNumbers(count: Int64): String 
    /**
     * The length of the random string is a random value from min to max; characters are taken at random from the English letters and digits
     */
    public func randomLettersNumbers(min: Int64, max: Int64): String 
    /**
     * Build a string from count characters taken at random from all keyboard-printable characters
     */
    public func randomPrintableAsciis(count: Int64): String
    /**
     * The length of the random string is a random value from min to max; characters are taken at random from all keyboard-printable characters
     */
    public func randomPrintableAsciis(min: Int64, max: Int64): String 
    /**
     * Build a string from count characters taken at random from all UNICODE characters
     */
    public func randomAllChars(count: Int64): String 
    /**The length of the random string is a random value from min to max; characters are taken at random from all UNICODE characters*/
    public func randomAllChars(min: Int64, max: Int64): String 
}
```

### Character sets

| Method | Source of characters |
| --- | --- |
| `randomAscii` | `U+0000`–`U+007F` (0–127, including non-printable control characters) |
| `randomLowerLetters` | `a`–`z` |
| `randomUpperLetters` | `A`–`Z` |
| `randomAllLetters` | `A`–`Z` + `a`–`z` |
| `randomNumbers` | `0`–`9` |
| `randomLowerHex` | `0`–`9` + `a`–`f` |
| `randomUpperHex` | `0`–`9` + `A`–`F` |
| `randomLowerLettersNumbers` | `a`–`z` + `0`–`9` |
| `randomUpperLettersNumbers` | `A`–`Z` + `0`–`9` |
| `randomLettersNumbers` | `A`–`Z` + `a`–`z` + `0`–`9` |
| `randomPrintableAsciis` | Letters and digits + `` `~!@#$%^&*()-_=+[{]}\\|'";:/?.>,< `` |
| `randomAllChars` | All Unicode scalars: `[0x0000, 0xD7FF]` ∪ `[0xE000, 0x10FFFF]` |
| `random(count, source)` | The string or `Array<Rune>` given by the caller |

Notes:

- The overloads without min/max generate `count` characters; the overloads with min/max first draw a length and then generate the characters.
  The length ranges are inconsistent: `randomAscii(min, max)` and `random(min, max, source)` use `closed: true`, so the length falls in
  `[min, max]`, while the other overloads produce a length in `[min, max)`.
- `randomAscii` converts the result of `nextUInt32(128)` into a Rune and therefore includes control characters; for printable characters only, use `randomPrintableAsciis`.
- `randomAllChars` avoids the UTF-16 surrogate range `0xD800`–`0xDFFF`, because that range is not a legal Unicode scalar value.
- The method names called internally by the three min/max overloads do not match their comments, and the results differ from the expected character
  sets; see [Notes and known behavior](#notes-and-known-behavior).


## ThreadLocalRandom

```cj
/**
 * Returns a separate SecureRandom instance for each thread; the returned SecureRandom is created with the default priv
 */
public class ThreadLocalRandom {
    private init()
    @Frozen
    public static prop current: SecureRandom 
}
```

- The first time a thread accesses `current` a `SecureRandom` (with the default `priv`) is created, and that instance is reused afterwards,
  so you do not have to handle cross-thread locking or reuse yourself.
- The constructor is private; this class exists only to obtain `current`.
- The no-argument constructor of `RandomString()` uses `ThreadLocalRandom.current` as the random source by default, so a default `RandomString` instance is thread safe.


## Notes and known behavior

The following items are places where the current implementation differs from intuition/the comments; the documentation records the actual
behavior of the code, and **the code itself has not been changed**.

1. **The floating point `closed` is not "include the upper bound"**: the implementation is `nextFloat64() * (max - min + (closed ? 1 : 0)) + min`.
   With `closed: true` the return value falls in `[min, max + 1.0)`, that is, it may exceed `max`; with `closed: false` it falls in `[min, max)`.
   If a floating point number that never exceeds the upper bound is needed, clamp it yourself.
2. **The integer versions convert to floating point first and then round**: `nextInt64`/`nextUInt64` go through `Float64` and
   `nextInt32`/`nextUInt32` through `Float32`, and the result is rounded with `floor`; `closed: false` gives `[min, max)` and `closed: true`
   gives `[min, max]`. When the range exceeds what a floating point number can represent exactly (for example near `Int64.Max`) there is
   precision loss and possibly overflow.
3. **The range arguments are not validated**: the methods of `ExtendRandom` do not check `min <= max`; passing them the other way round does not
   report an error and simply produces a result of the reversed range.
4. **Three min/max overloads of `RandomString` call the wrong methods**:
   - `randomAllLetters(min, max)` calls `randomLowerLetters` internally, so it only produces lower-case letters;
   - `randomUpperLettersNumbers(min, max)` calls `randomLowerLettersNumbers` internally, producing lower-case letters + digits;
   - `randomLettersNumbers(min, max)` also calls `randomLowerLettersNumbers` internally, producing lower-case letters + digits.

   When the corresponding character set is needed, compute the length yourself and call the `(count)` overload, for example to get a
   string of 8–16 "upper and lower case letters + digits":

   ```cj
   let rs = RandomString()
   let len = ThreadLocalRandom.current.nextInt64(8, 16, closed: true)
   let s = rs.randomLettersNumbers(len)
   ```

5. **The length ranges of `RandomString` are not uniform**: only `randomAscii(min, max)` and `random(min, max, source)` use `closed: true`; the
   length of the other `(min, max)` overloads is `[min, max)`.
6. **Boundaries of `randomReservoir`**:
   - When `count <= 0` and the data source is not empty, `nextInt64(0)` throws an illegal argument exception;
   - The size of the return value is `min(count, number of elements in the data source)` and is not always equal to `count`;
   - The replacement index is taken from `[0, i)` (`i` being the index of the current element), whereas the classic algorithm R requires
     `[0, i]`; the missing `j == i` branch means the sampling result is not strictly uniform.
