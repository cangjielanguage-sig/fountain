# f_base

**Note ⚠️**: this module registers signal handlers for kill 15 and CTRL+C. If no signal handler is registered and this module is not imported, the
process exit functions registered with atExit do not take effect.

## STDX dependency

Configure the environment variable: `export CANGJIE_STDX_DYNAMIC_PATH=/path/to/dynamic_stdx`

## Basic features

The basic module of the fountain project; importing this package blindly during development is recommended.

## Import

```cj
import fountain::f_base.*
```

## BaseException

BaseException is an open class. It adds a suppressed property, so suppressed exceptions can be attached to an exception instance.

## `Comparator<T>`

```cj
public class Comparator<T>
//Instantiate a comparator
Comparator<T>(public let comparator: (T, T) -> Ordering)

//Compare instances of a Comparable type
public static func compare<T>(left: T, right: T): Ordering where T <: Comparable<T>

//Convert a Comparable into a Comparator instance
public static func create<T>(): Comparator<T> where T <: Comparable<T>

//Compare two instances
public operator func ()(left: T, right: T): Ordering

//Reverse the comparator
public func reverse(): Comparator<T>

//Create a new Comparator with the argument; when the current Comparator returns EQ, the argument of this function performs the next comparison
public func then(comparator: (T, T) -> Ordering): Comparator<T>
public func then(comparator: Comparator<T>): Comparator<T>
//Create a new Comparator with the argument; when the current Comparator returns EQ, mapper converts the type T into O and comparator performs the next comparison
public func then<O>(mapper: (T) -> O, comparator: (O, O) -> Ordering): Comparator<T>
public func then<O>(mapper: (T) -> O, comparator: Comparator<O>): Comparator<T>

//The returned Comparator calls the argument of this function to convert the type and compares the conversion result
public static func comparing<O, T>(mapper: (O) -> T): Comparator<O> where T <: Comparable<T>
//The returned Comparator calls mapper to convert the type and comparator to compare
public static func comparing<O, T>(mapper: (O) -> T, comparator: (T, T) -> Ordering): Comparator<O>
public static func comparing<O>(mapper: (O) -> T, comparator: Comparator<T>): Comparator<O>
```


## `Equaler<T>`

```cj
public struct Equaler
Equaler(private let eq: (T, T) -> Bool)

//Compare whether the two arguments are equal
public static func equals<T>(left: T, right: T): Bool where T <: Equal<T>
//Create an Equaler instance for the generic argument
public static func create<T>(): Equaler<T> where T <: Equal<T>
//Use an instance of this type to compare whether the two arguments are equal
public operator func ()(left: T, right: T): Bool
//Create a new Equaler with the argument; when the current Equaler compares as EQ, mapper converts the type T into O and equal performs the next comparison
public func then(equal: (T, T) -> Bool): Equaler<T>
public func then(equal: Equaler<T>): Equaler<T>
//The returned Equaler instance calls mapper to convert the type and compares the conversion result
public static func equalling<O, T>(mapper: (O) -> T): Equaler<O> where T <: Equal<T>
//The returned Equaler instance calls mapper to convert the type and uses equal to compare the conversion result
public static func equalling<O, T>(mapper: (O) -> T, equal: (T, T) -> Bool): Equaler<O>
public static func equalling<O, T>(mapper: (O) -> T, equal: Equaler<T>): Equaler<O>

//The returned Equaler instance first runs the current Equaler and, if it returns true, calls mapper to convert the current generic type of the Equaler into a new type and uses the new type with equal to complete the comparison
public func then<O>(mapper: (T) -> O, equal: (O, O) -> Bool): Equaler<T>
public func then<O>(mapper: (T) -> O, equal: Equaler<O>): Equaler<T>
```

## Console

```cj
public struct Console {
    //Write the argument to the standard output stream without a newline
    public static func write<T>(v: T): Unit where T <: ToString
    //Write the argument to the standard output stream followed by a newline
    public static func writeln<T>(v: T): Unit where T <: ToString
    //Write the result of executing the argument to the standard output stream without a newline
    public static func write<T>(fn: () -> T): Unit where T <: ToString
    //Write the result of executing the argument to the standard output stream followed by a newline
    public static func writeln<T>(fn: () -> T): Unit where T <: ToString
    //Write a blank line to the standard output stream
    public static func writeln(): Unit
    //Read one character from the standard input stream without blocking
    public static func read(): ?Rune
    //Read a string from the standard input stream until the argument is met; the argument is not included in the return value
    public static func readUntil(r: Rune): ?String
    //For every character read from the standard input stream, call the argument, until it returns true; returns every character read, excluding the one that returned true
    public static func readUntil(predicate: (Rune) -> Bool): ?String
    //Same as ConsoleReader.readln()
    public static func readln(): ?String 
    //Same as ConsoleReader.readToEnd()
    public static func readToEnd(): ?String 
    //Read one line from the standard input stream until a newline is met; returns the string without the newline converted to T
    public static func readlnValue<T>(): ?T where T <: Parsable 
}
```


## Empty collections

```cj
//The following are the ways to instantiate the various empty collections
EmptyArray<T>.instance()
EmptySet<T>.instance()//EmptySet<T> <: Set where T <: Equatable<T>
EmptyIterator<T>.instance()//EmptyIterator<T> <: Iterator<T>
EmptyIterable<T>.instance()//EmptyIterable<T> <:Iterable<T>
EmptyMap<K, V>.instance()//EmptyMap<K, V> <: Map<K, V> where K <: Equatable<K>
EmptyEquatableCollection<K>.instance()//EmptyEquatableCollection<K> <: EquatableCollection<K> where K <: Equatable<K>
EmptyCollection<T>.instance()//EmptyCollection<T> <: Collection<T>
EmptyList<T>.instance()//EmptyList<T> <: List<T>
```


## Extending Iterator
```cj
//Every next() of the returned Iterator creates a new thread and returns a ?Future<?T>,
func async(): Iterator<Future<?T>>
//Compare every element of the iterator with the argument and return the minimum element of the iterator
func min(cmp: (T, T) -> Ordering): ?T
//Compare every element of the iterator with the argument and return the maximum element of the iterator
func max(cmp: (T, T) -> Ordering): ?T
//exactly: true means every element of the iterator must be of type R to be returned; exactly: false means every element of the iterator must be a subtype of R to be returned; other elements are ignored
func filterType<R>(exactly!: Bool): Iterator<R>
//If every element of the iterator is an Iterable<R>, convert the current element into an Iterator<R>; if the iterator element is not of type Iterable<R>, an exception is thrown when toThrow is true and EmptyIterator<T> is returned when toThrow is false
func flatten<R>(toThrow!: Bool): Iterator<R>
//Call collector with every element of the iterator to fill the iterator elements into collection
func collect<C>(collection: C, collector: (T, C) -> Unit): C where C <: Collection<T>
//Convert the iterator into an Array<T>
func toArray(): Array<T>
//Convert the iterator into an ArrayList<T>
func toArrayList(): ArrayList<T>
//Use every element of the iterator as the argument of key and the K returned by key as the KEY of a HashMap; fill the iterator elements into the HashMap
func collect<K>(key: (T) -> K): HashMap<K, T> where K <: Hashable & Equatable<K>
//Use every element of the iterator as the argument of key and the K returned by key as the KEY of a HashMap; the HashMap filled with the iterator elements
public func groupBy<K>(key: (T) -> K): HashMap<K, ArrayList<T>> where K <: Hashable & Equatable<K>
//The returned instance has a peek function; calling peek returns the current, not yet iterated value, consumes nothing and does not affect the execution of next().
public func peekable(): PeekableIterator<T>
```

## PeekableIterator
```cj
public class PeekableIterator<T> <: Iterator<T> & Resource {
    public PeekableIterator(private let itr: Iterator<T>){}

    public func next(): Option<T> 
    public func peek(): ?T 

    /** Close the underlying iterator (if it implements the Resource interface) */
    public func close(): Unit 

    public func isClosed(): Bool 
}
public interface Peekable<T>{
    func peekable(): PeekableIterator<T>
}
extend<T> Iterator<T> <: Peekable<T> 
```

## Extending Option

```cj
//Instantiate the current Option as an iterator with only one element; the return value on the first call of next depends on whether the Option is Some or None
func iterator(): Iterator<T>
//If the Option is Some, call fn with the value contained in the Some and the return value of fn is the return value of call, otherwise call returns None
func call<R>(fn: (T) -> R): ?R
//If the Option is Some, call fn with the value contained in the Some and right as the arguments and the return value of fn is the return value of call, otherwise call returns None
func call<A, R>(right: A, fn: (T, A) -> R): ?R

//fn and the current Option are used as the arguments to initialize an OptionCaller
func caller<R>(fn: (T) -> R): OptionCaller<T, R>
//fn, right and the current Option are used as the arguments to initialize an OptionCaller
func caller<A, R>(right: A, fn: (T, A) -> R): OptionCaller<T, R>
//If the current Option is Some(x: U), convert it into Result.Ok(x); if it is Some but the type is not U, return None; if it is None, return NoResult
func toResult<U, E>(): ?Result<U, E>
//If the current Option is Some, call fn to convert it into U and instantiate a Result with the return value, otherwise return None
func toResult<U, E>(fn: (T) -> U): ?Result<U, E>
//If the current Option is Some, call fn to convert it into ?U; if it returns Some(x), instantiate Result<U, E>.Ok(x) with the value of the Some, otherwise return None; if it is None, return NoResult
func toResult<U, E>(fn: (T) -> ?U): ?Result<U, E>
//If the current Option is Some(x: U), return Result<U, E>.Ok(x); if it is Some but the value is not of type U, an exception is thrown; otherwise return Result<U, E>.NoResult
func toResult<U, E>(fn: () -> Exception): Result<U, E>
//Wrap the current Option as Result.Ok(this)
func wrapResult<E>(): Result<?T, E>
```

## OptionCaller

```cj
public class OptionCaller<T, R> {
    public OptionCaller(
        private let option: ?T,
        private let someCallee: (T) -> R,
        private var noneCallee!: ?() -> R = None<() -> R>
    ) {}
    //Modify noneCallee
    public func none(callee: () -> R) 
    //If option is Some, execute someCallee, otherwise execute noneCallee; if noneCallee is None, return None
    public func call(): ?R 
    //Same as call
    public operator func ()(): ?R 
}
```

## Result<T, E>

```cj
public enum Result<T, E> {
    | Ok
    | Ok(T)
    | Err
    | Err(E)
    | NoResult
    //Whether the current Result is Ok
    public prop isOk: Bool 
    //Whether the current Result is Err
    public prop isErr: Bool 
    //Whether the current Result is NoResult
    public prop isNoResult: Bool 
    //Whether the current Result contains an error value; only true for Err(E)
    public prop withE: Bool
    //Whether the current Result contains a correct value; only true for Ok(T)
    public prop withValue: Bool 
    //Returns Some(T) for Ok(T) and None<T> otherwise
    public func result(): ?T 
    //Returns Some(E) for Err(E) and None<E> otherwise
    public func err(): ?E 
    //Convert the current Result into Result<U, E>; when the current Result is Ok(T) the argument f is executed,
    public func mapValue<U>(f: (T) -> Result<U, E>): Result<U, E> 
    /**
     * Convert the current Result into Result<U, E>; when the current Result is Err(E) the argument f is executed,
     * when the current Result is Ok(x: U) it returns Ok(x), and other Ok values return Ok
     * otherwise the same enum value is returned
     */
    public func mapError<U>(f: (E) -> Result<U, E>): Result<U, E> 
    //Ignore the data and the error information and return only Ok, Err or NoResult
    public func ignore(): Result<T, E> 
    //When the current Result is Ok(x), execute predicate and return the current Result if it returns true, otherwise return NoResult
    public func filterValue(predicate: (T) -> Bool): Result<T, E> 
    //When the current Result is Err(x), execute predicate and return the current Result if it returns true, otherwise return NoResult
    public func filterError(predicate: (E) -> Bool): Result<T, E> 
    //Return the current Result when its isOk returns true, otherwise return NoResult
    public func filterOk(): Result<T, E> 
    //Return the current Result when its isErr returns true, otherwise return NoResult
    public func filterErr(): Result<T, E>
    //Return the current Result when it is Err(E), otherwise return NoResult
    public func filterWithE(): Result<T, E>
    //Return the current Result when it is Ok(T), otherwise return NoResult
    public func filterWithValue(): Result<T, E>
    //If the current Result is Ok(x: Result<U, E>) return x, otherwise return it unchanged
    public func flatten<U>(): Result<U, E> 
    //If the current Result is Ok(x: U), return Ok(x); if it is Ok(x) but x is not of type U, return Ok; otherwise return it unchanged
    public func transpose<U>(): ?Result<U, E> 
    //If the current Result is Ok(x), return x, otherwise return default
    public func orDefault(default: T): T 
    //If the current Result is Ok(x), return x, otherwise return the return value of fn
    public func orElse(fn: () -> T): T 
    //If the current Result is Ok(x), return x, otherwise return the return value of fn
    public func orElse(fn: () -> ?T): ?T 
}
```

## Extending ThreadLocal

```cj
//If the current ThreadLocal has a value, return the current value; otherwise call fn, store the return value of fn into the current ThreadLocal and return the value just stored
func getOrCompute(fn: () -> T): T
//Clear the value of the current ThreadLocal
func remove(): Unit
```


## HashBuilder

```cj
/* This class is generally used only as a local variable and does not escape
   Cangjie already supports escape analysis and stack allocation of class instances
   According to the simple performance test in HashBuilder_test.
   The argument of every append function takes part in the hash computation as much as possible; an argument implementing Hashable calls its
   hashCode() and uses that hash value in the hash formula
 */
public class HashBuilder <: Hashable 

/**
 * Called once, the instance of this class returns to its initial state
 */
public func build(): Int64
/**
 * Simply calls build()
 */
public func hashCode(): Int64

@OverflowWrapping
public func append(arg: Int64): This
public func append<T>(arg: T): This where T <: Hashable
//Traverse every element of the argument and call append for each element
public func append<T, I>(args: I): This where T <: Hashable, I <: Iterable<T>
//Traverse the range and call append for every value in it
public func append<T>(args: Range<T>): This where T <: Hashable & Countable<T> & Comparable<T> & Equatable<T>
//Call the toString() function of the argument and use that string with append
public func append(arg: StringGenerator): This
/**
 * Traverse the argument: if the key and the value implement Hashable, call append with their hash values,
 * if they implement ToString, call toString() first and then append, and if they implement neither, call append with '_'.
 */
public func append<K, V>(value: ConcurrentHashMap<K, V>): This where K <: Hashable & Equatable<K>
/**
 * If value implements Hashable, call append with the hash value of the argument,
 * if value implements ToString, call append with the toString() result of the argument
 */
public func append(value: Any): This
/**
 * If the argument extends Hashable, call append with the hash value of the argument.
 * Otherwise traverse the argument: for every key and value, call append with their hash values if they implement Hashable,
 * and call append with the toString() result if they implement ToString
 */
private func append<K, V>(value: Map<K, V>): This where K <: Equatable<K>
```


## Help

```cj
//convert returns the first value that is neither None (for Array<?T> only isSome is checked) nor empty (for Array<?String>/Array<C> empty strings/empty collections are also filtered out)
//Help.convert<T>([a, b, c])
//Help.convert<T>([list])
public static func convert<T>(options: Array<?T>): ?T
public static func convert<T>(options: Array<?String>): String
public static func convert<T, C>(collections: Array<C>): ?C where C <: Collection<T>
public static func convert(strings: Array<String>): String
```


## OS

```cj
//Operating system
public enum OS <: Equatable<OS> & ToString & Hashable {
    | Linux
    | Windows
    | macOS
    | HarmonyOS
    | OpenHarmony
    | Android
    | iOS
    public operator func ==(other: OS): Bool
    public prop isWindows: Bool
    public prop isLinux: Bool
    public prop isMacOS: Bool
    public prop isHarmonyOS: Bool
    public prop isOpenHarmony: Bool
    public prop isAndroid: Bool
    public prop isiOS: Bool
    public func toString(): String
    public static func valueOf(value: String): OS
    public func hashCode(): Int64
    //Return the instance of the current operating system (note: the HarmonyOS branch is currently commented out, so an ohos environment actually returns OpenHarmony)
    public static prop current: OS
    //Return the newline character of the current operating system
    public prop nextLine: String
}
```


## Top-level function resource

```cj
//A replacement for try-with-resource; the argument of fn is res, and the difference is that this function returns the return value of fn.
public func resource<R, T>(res: R, fn: (R) -> T): T where R <: Resource
```


## `ResourceManager<R> where R <: Resource`

```cj
/**
 * The constructor takes a closure returning a Resource implementation (**called only once**; the instance is held by this class);
 * call executes fn and closes the instance when fn ends —— therefore **the second call of the same ResourceManager gets an already
 * closed resource**; when "a new instance every time" is needed, use the top-level function `resource(res, fn)`.
 */
public struct ResourceManager<R> where R <: Resource {
    public init(new: () -> R)
    public func call<T>(fn: (R) -> T): T 
}
```


## Single-value iteration

```cj
//An iterable object initialized with one value
public class SingleIterable<T> <: Iterable<T>
public class SingleIterator<T> <: Iterator<T>
```


## StringGenerator

```cj
//Has richer functionality than the StringBuilder of the standard library
public class StringGenerator <: ToString

public init() {}
public init(s: String)
//The current size of the StringGenerator
public prop size: Int64
//Reset the current StringGenerator
public func reset(): This
public func clear(): This
//Append the argument to the StringGenerator
public func append<T>(content: T): This where T <: ToString
//Append the argument to the StringGenerator, then append the given newline character
public func appendln<T>(content: T, nextLine!: String = OS.current.nextLine): This where T <: ToString
//Append the argument to the StringGenerator and then append a Unix-style newline character
public func appendUnixNewLine<T>(content: T): This where T <: ToString
//Append the given newline character to the StringGenerator
public func append(nextLine!: String = OS.current.nextLine): This
//Append a Unix-style newline character to the StringGenerator
public func appendUnixNewLine(): This
//Append a UTF8 byte array to the StringGenerator
public func appendFromUtf8(utf8: Array<Byte>): This
//Convert a byte array into a string with the given charset and append it to the StringGenerator
public func appendFromBytes(bytes: Array<Byte>, charset!: Charset = Charsets.UTF8): This
//Convert content into a string and search for the substring starting at fromIndex of the StringGenerator; return the index of the first substring found, or None when it is not found
public func indexOf<T>(content: T, fromIndex!: Int64 = 0): ?Int64 where T <: ToString
//Convert content into a string and search for the substring starting at fromIndex of the StringGenerator; return the index of the last substring found, or None when it is not found
public func lastIndexOf<T>(content: T, fromIndex!: Int64 = 0): ?Int64 where T <: ToString
//Convert content into a string and check whether the current StringGenerator contains this string
public func contains<T>(content: T): Bool where T <: ToString
//Check whether the current StringGenerator starts with the argument
public func startsWith(content: String): Bool
//Check whether the current StringGenerator ends with the argument
public func endsWith(content: String): Bool
//Take the substring from start to end out of the StringGenerator; start is included and end is not
public func substring(start: Int64, end: Int64): String
//Convert content into a string and delete the first substring found starting at fromIndex
public func removeFirst<T>(content: T, fromIndex!: Int64 = 0): This where T <: ToString
//Convert content into a string and delete the last substring found starting at fromIndex
public func removeLast<T>(content: T, fromIndex!: Int64 = 0): This where T <: ToString
//Convert content into a string and delete all substrings from fromIndex to toIndex
public func remove<T>(content: T, fromIndex!: Int64 = 0, toIndex!: Int64 = size): This where T <: ToString
//Convert sub into a string and insert it at index at
public func insert<T>(sub: T, at!: Int64): This where T <: ToString
//Convert old and new into strings and replace all old with new from fromIndex to toIndex
public func replace<O, T>(old: O, new: T, fromIndex!: Int64 = 0, toIndex!: Int64 = size): This where O <: ToString, T <: ToString
//Convert new into a string and replace the content from fromIndex to toIndex with this string
public func replace<T>(new: T, fromIndex!: Int64 = 0, toIndex!: Int64 = size): This where T <: ToString
//Convert old and new into strings and replace the first old found from fromIndex to toIndex with new
public func replaceFirst<O, T>(old: O, new: T, fromIndex!: Int64 = 0, toIndex!: Int64 = size): This where O <: ToString, T <: ToString
//Convert old and new into strings and replace the last old found from fromIndex to toIndex with new
public func replaceLast<O, T>(old: O, new: T, fromIndex!: Int64 = 0, toIndex!: Int64 = size): This where O <: ToString, T <: ToString
//Reverse the StringGenerator by character
public func reverse(): This
//Return the constructed string
public func toString(): String
//Return the raw byte array of the StringGenerator
public func unsafeBytes(): Array<Byte>
```

## Getting the raw byte array of a string

```cj
public interface UnsafeBytes {
    func unsafeBytes(): Array<Byte>
}
extend String <: UnsafeBytes{...}
```


## Getting the raw array of an ArrayList

```cj
import std.collection.ArrayList

public interface UnsafeData<T> {
    func unsafeData(): Array<T>
}

extend<T> ArrayList<T> <: UnsafeData<T>{...}
```

## Getting a zero value

```cj
//No need for the unsafe keyword
public func unsafeZeroValue<T>(): T
```


## Zero Timer

```cj
public import std.sync.Timer

public let ZERO_TIMER: Timer = unsafe { zeroValue<Timer>() }
```


## Overflow rejection policies

```cj
public interface OverSizePolicy<T> {
    /**
       o is the new value to be added,
       fn is the function to execute after applying the policy, for example when new values can be added again after the policy, fn can contain that logic
     */
    func reject(o: T, fn: () -> Unit): Unit
}
/**Throws an exception*/
public class AbortOverSizePolicy<T> <: OverSizePolicy<T>
/**Discards the current value*/
public class DiscardOverSizePolicy<T> <: OverSizePolicy<T>
/**Discards some value*/
public class RemoveSomeOnePolicy<T> <: OverSizePolicy<T>
/**Runs on the calling thread*/
public class CallerRunsOverSizePolicy<T> <: OverSizePolicy<T>
/**Blocks until the timeout; if woken before the timeout and recovered returns true, apply policy*/
public class BlockingOverSizePolicy<T> <: OverSizePolicy<T> {
    public BlockingOverSizePolicy(
        private let recovered: (T) -> Bool,
        private let timeout!: Duration = Duration.Max,
        private let policy!: OverSizePolicy<T> = DiscardOverSizePolicy<T>()
    ) {}
    /**Blocks until the timeout; if woken before the timeout and recovered returns true, apply policy*/
    public func reject(o: T, fn: () -> Unit): Unit
    public func notifyAll(): Unit
    public func notify(): Unit
}
```


## Basic operator interfaces

```cj
public interface Negativable<T> where T <: Negativable<T> {
    operator func -(): T
}

public interface Addable<T> where T <: Addable<T> {
    operator func +(right: T): T
}

public interface Subable<T> where T <: Subable<T> {
    operator func -(right: T): T
}

public interface Mulable<T> where T <: Mulable<T> {
    operator func *(right: T): T
}

public interface Divable<T> where T <: Divable<T> {
    operator func /(right: T): T
}

public interface Modable<T> where T <: Modable<T> {
    operator func %(right: T): T
}

public interface Expable<T> where T <: Expable<T> {
    operator func **(right: T): T
}

public interface Cmpable<T> where T <: Cmpable<T> {
    operator func >(right: T): Bool
    operator func <(right: T): Bool
    operator func >=(right: T): Bool
    operator func <=(right: T): Bool
}

public interface Eqable<T> where T <: Eqable<T> {
    operator func ==(right: T): Bool
    operator func !=(right: T): Bool
}

public interface BitAndable<T> where T <: BitAndable<T> {
    operator func &(right: T): T
}

public interface BitOrable<T> where T <: BitOrable<T> {
    operator func |(right: T): T
}

public interface BitXorable<T> where T <: BitXorable<T> {
    operator func ^(right: T): T
}

public interface BitNotable<T> where T <: BitNotable<T> {
    operator func !(): T
}

public interface LeftShiftable<T> where T <: LeftShiftable<T> {
    operator func <<(right: T): T
}

public interface RightShiftable<T> where T <: RightShiftable<T> {
    operator func >>(right: T): T
}
```


## `FutureTask<T>`
1. When a parent task ends it can decide whether to end its child tasks
2. It supports InheritedTaskLocal, similar to ThreadLocal but with inheritance: if the current FutureTask has no value, it is taken from the parent task
```cj
public sealed abstract class AbstractFutureTask <: Hashable & Equatable<AbstractFutureTask>{
    public func hashCode(): Int64 
    public operator func ==(other: AbstractFutureTask): Bool 
    //Create a new InheritedTaskLocal
    public func newLocal<T>(): InheritedTaskLocal<T> 
}
public class FutureTask<T> <: AbstractFutureTask {
    //Create a new FutureTask
    //shutdownSubOnFinish: whether to end the child tasks when the current FutureTask ends
    //fn: the task function
    public init(shutdownSubOnFinish: Bool, fn: () -> T)
    //Create a new FutureTask; in this case shutdownSubOnFinish is true
    public init(fn: () -> T)
    //Return the FutureTask corresponding to the current thread ID; this function is only valid when called inside a FutureTask, otherwise it throws
    public static func current(): FutureTask<T> 
    //Return the result after the current FutureTask has finished, that is, the return value of the constructor argument fn
    public func get(): T 
    //Return the result after the current FutureTask has finished, that is, the return value of the constructor argument fn; if the task has not finished within timeout when this function is called, an exception is thrown
    public func get(timeout: Duration): T
    //Return the result after the current FutureTask has finished, that is, the return value of the constructor argument fn; returns None if the task has not finished when this function is called
    public func tryGet(): ?T 
    //End the current FutureTask, and decide according to shutdownSubOnFinish whether to end the child tasks
    public func shutdown(): Unit 
    //End all child tasks of the current FutureTask.
    public static func shutdownCurrentSubThreads(): Unit 
}
public sealed abstract class AbstractInheritedTaskLocal <: Hashable & Equatable<AbstractInheritedTaskLocal> {
    AbstractInheritedTaskLocal(let task: AbstractFutureTask)
    public func hashCode(): Int64 
    public operator func ==(other: AbstractInheritedTaskLocal): Bool 
}
//A ThreadLocal that can be inherited from the parent thread; when the InheritedTaskLocal of the current FutureTask has no value it is looked up in the parent FutureTask
//When the task of the FutureTask initialization ends, the corresponding InheritedTaskLocal is removed
public class InheritedTaskLocal<T> <: AbstractInheritedTaskLocal {
    init(task: AbstractFutureTask)
    public func set(value: T): Unit 

    public func get(): ?T 

    public func remove(): Unit 
    public func getOrSet(value: T): T 
    public func getOrCompute(fn: () -> T): T 
}
```

## Supplement: public symbols not expanded item by item in this README (the source code is authoritative)

- **std re-exports**: `public import std.collection.* / MathExtension / reflect.* / regex.* / time.*` (`src/public_std_imports.cj`)
  and `TypeInfo` / `BigInt` / `Decimal` / `DateTime` (`src/TypeInfos.cj`) ⇒ `import fountain::f_base.*` also brings in these std symbols.
- **`Options<T, R>`** (`src/Options.cj`): `isEmptyOrBlank` / `isNotEmptyOrZero` / `convert` / `convertOrThrow` and so on.
- **Operator extensions of Option** (`src/ExtendOption.cj`): `+ - * / % ** & | ^ ! << >>` (two sets of overloads, for `?(T)` and `T`),
  `OptionComparable`, `noneOrder!: NoneOrder`.
- **`ExtendArray`**: `grow(size, new!)`, `expand`, `operator *(repeat)`, `GrownArrayNewValue<T>`.
- **`ExtendNumber`**: the interface family `Number` / `Integer` / `SignedInteger` / `UnsignedInteger` / `Float`,
  plus `isOdd` / `isEven` / `numberOfLeadingZeros` / `flip` / `toUInt` / `toInt` / `to` for `Int8..UInt64`.
- **String / Range / Rune extensions**: `stringJoin<T[,C]>`, `String.trimAsciiBlanks` / `replaceFirst` / `replaceLast`,
  `Range<T>.toString()`, `Rune ± integer`, `Rune * Int64: String`.
- **`Arch`**: `Arch.current` / `isX86_64` / `isAarch64` (platform detection on a par with OS).
- **Chained `Result` API**: `filter()` → `ResultFilter`, `mapper()` → `ResultMapper`.
- **`BaseException`**: 4 constructors + `addSuppressed` + `prop suppressed: ArrayList<Exception>`; the top-level `printStackTrace(exception, output)`.
- **`Bucket<K, V> <: Map<K, V> & Iterable<(K, V)>`**, `EmptyMap <: Bucket`, `EmptyMapEntryView`.
- **Reflection utilities**: `TypeInfos`, `TypeMemberInfos`, `SubTypeOf` (`src/TypeInfos.cj`).
- **Signals and natives**: constants such as `SIGIOT` / `SIGSEGV` and `Signal` / `SignalHandlerFunc` (`src/signal.cj`),
  `nextPowerOf2`, `toHex` / `fromHex`, `MEM_PAGE_SIZE` / `nullptr` / `mcopy`, `WorkerStrategy`,
  `BaseCommand<R, T>`, `OverSizeException`, `UnsafeBytes.unsafeUtf8`.
- **Macro package**: `@nameof` / `@nameValueOf` of `fountain::f_base.macros` (a separate `import fountain::f_base.macros.*` is needed).
- `src/Comparator_test.cj` is published with the package because of `include=["src"]` (the test file is not separated from the source).

## End-of-process signal handlers
This module ensures that the SIGTERM and SIGINT signal handlers are registered only after all the dynamic libraries of an application project using
fountain have been loaded, and clears the previously registered handlers of those two signals.
If an application project module needs to do some cleanup before the process ends it should call the following function:
```cj
ExitCallbacks.atExit(priority){...}
```
The function declarations are as follows:
```cj
public struct ExitCallbacks {
    //Register the signal handlers: this function resets the previously registered SIGTERM and SIGINT signals,
    //then registers new handlers for those two signals; the handlers call the functions registered with ExitCallbacks.atExit,
    //then call exit(0) to terminate the process, and the signal handler finally returns false
    //A module that needs to do cleanup before the process exits must call ExitCallbacks.atExit or std.env.atExit
    //If the developer uses "fountain::f_app"="1.3.0" or later in the project, this function does not have to be called, because the f_app module calls it automatically
    public static func toExitGracefully(): Unit
    //The callback functions run in ascending order of priority; callbacks with the same priority run in registration order
    public static func atExit(priority: UInt16, atexit: () -> Unit): Unit
}
```

## Registering signal handlers
Valid on POSIX platforms; **Windows only has an empty implementation** (macOS / OpenHarmony use the real implementation).
It has the same meaning as std.runtime.registerSignalHandler(signal: Signal, handler: (Int32) -> Bool)
```cj
//Register a new signal handler without clearing the other handlers of the same signal
public func registerSignalHandler(signals: Array<Signal>, handler: () -> Bool): Unit{}
public func registerSignalHandler(signals: Array<Signal>, handler: (Int32) -> Bool): Unit {}
public func registerSignalHandler(signal: Signal, handler: () -> Bool): Unit {}

// Clear the other handlers of the same signal before registering
public func resetAndRegisterSignalHandler(signals: Array<Signal>, handler: () -> Bool): Unit{}
public func resetAndRegisterSignalHandler(signals: Array<Signal>, handler: (Int32) -> Bool): Unit {}
public func resetAndRegisterSignalHandler(signal: Signal, handler: () -> Bool): Unit {}
```

---

## Other public API

The declarations below are not expanded above; they are grouped by module level and by type (members declared in `extend` blocks are listed under the extended type). See the corresponding files under `src/` for the full semantics.

- Module level: `ExtendAddableOption` (interface), `ExtendBigInt` (interface), `ExtendBitAndableOption` (interface), `ExtendBitNotableOption` (interface), `ExtendBitOrableOption` (interface), `ExtendBitXorableOption` (interface), `ExtendDecimal` (interface), `ExtendDivableOption` (interface), `ExtendExpableOption` (interface), `ExtendFloat16` (interface), `ExtendFloat32` (interface), `ExtendFloat64` (interface), `ExtendInt16` (interface), `ExtendInt32` (interface), `ExtendInt64` (interface), `ExtendInt8` (interface), `ExtendIterator` (interface), `ExtendLeftShiftableOption` (interface), `ExtendModableOption` (interface), `ExtendMulableOption` (interface), `ExtendRange` (interface), `ExtendRightShiftableOption` (interface), `ExtendRune` (interface), `ExtendString` (interface), `ExtendSubableOption` (interface), `ExtendThreadLocal` (interface), `ExtendUInt16` (interface), `ExtendUInt32` (interface), `ExtendUInt64` (interface), `ExtendUInt8` (interface), `Powerable` (interface), `public func resetSignalHandler(_: Array<Signal>): Unit{}`
- `BigInt`: `static prop one: BigInt`, `static prop oneHundred: BigInt`, `static prop ten: BigInt`, `static prop zero: BigInt`
- `Decimal`: `static prop E: Decimal`, `static prop PI: Decimal`, `static prop one: Decimal`, `static prop oneHundred: Decimal`, `static prop ten: Decimal`, `static prop zero: Decimal`
- `EmptyCollection`: `isEmpty` (func)
- `EmptyEquatableCollection`: `isEmpty` (func)
- `EmptyList`: `func add(_: T): Unit {}`, `func capacity(): Int64`, `func count(_: T): Int64`, `prop first: ?T`, `func isEmpty(): Bool`, `prop last: ?T`, `func removeIf(_: (T) -> Bool): Unit {}`, `func reserve(_: Int64): Unit {}`, `func sortBy(_: (T, T) -> Ordering, stable!: Bool): Unit {}`
- `EmptyMap`: `add` (func), `func addIfAbsent(_: K, _: V): ?V`, `clone` (func), `func entryView(k: K): MapEntryView<K, V>`, `isEmpty` (func), `keys` (func), `removeIf` (func), `values` (func)
- `EmptySet`: `add` (func), `clone` (func), `func isEmpty(): Bool`, `removeIf` (func), `retain` (func), `subsetOf` (func)
- `Float16`: `static prop BYTES: Int64`, `static prop E: Float16`, `PI` (prop)
- `Float32`: `static prop BYTES: Int64`, `static prop E: Float32`, `static prop PI: Float32`
- `Float64`: `static prop BYTES: Int64`, `static prop E: Float64`, `static prop PI: Float64`
- `Int16`: `static prop BYTES: Int64`
- `Int32`: `static prop BYTES: Int64`
- `Int64`: `static prop BYTES: Int64`
- `Int8`: `static prop BYTES: Int64`
- `NoneOrder`: `prop isGreatest: Bool`, `prop isLeast: Bool`
- `Options`: `isEmpty` (func), `static func isEmptyOrUnit(current: Option<T>): Bool`, `static func isEmptyOrZero(current: Option<T>): Bool`, `static func isEmptyOrZeroOrBlank(current: Option<T>): Bool`, `static func isNotEmpty(current: Option<T>): Bool`, `static func isNotEmptyOrBlank(current: Option<T>): Bool`, `static func isNotEmptyOrUnit(current: Option<T>): Bool`, `static func isNotEmptyOrZeroOrBlank(current: Option<T>): Bool`
- `ResultMapper`: `func error(f: (E) -> Result<U, E>): ResultMapper<T, U, E>`, `func map(): Result<U, E>`, `func ok(f: () -> Result<U, E>): ResultMapper<T, U, E>`
- `TypeInfo`: `func isSubtypeOf<S>(): Bool`
- `TypeInfos`: `static func getGenericTypes<T>(): Array<TypeInfo>`, `static func isInstanceOf<T>(instance: Any): Bool`, `static func withAnnotation<T, A>(funcName: String, argTypes: Array<TypeInfo>): Bool where A <: Annotation`
- `TypeMemberInfos`: `static func instanceFunction<T>(name: String, paramTypes: Array<TypeInfo>): ?InstanceFunctionInfo`, `static func instanceFunctions<T>(): Collection<InstanceFunctionInfo>`, `static func instanceProperties<T>(): Collection<InstancePropertyInfo>`, `static func instanceProperty<T>(name: String): ?InstancePropertyInfo`, `static func instanceVariable<T>(name: String): ?InstanceVariableInfo`, `static func instanceVariables<T>(): Collection<InstanceVariableInfo>`, `static func staticFunction<T>(name: String, paramTypes: Array<TypeInfo>): ?StaticFunctionInfo`, `static func staticFunctions<T>(): Collection<StaticFunctionInfo>`, `static func staticProperties<T>(): Collection<StaticPropertyInfo>`, `static func staticProperty<T>(name: String): ?StaticPropertyInfo`, `static func staticVariable<T>(name: String): ?StaticVariableInfo`, `static func staticVariables<T>(): Collection<StaticVariableInfo>`
- `UInt16`: `static prop BYTES: Int64`
- `UInt32`: `static prop BYTES: Int64`
- `UInt64`: `static prop BYTES: Int64`
- `UInt8`: `static prop BYTES: Int64`
