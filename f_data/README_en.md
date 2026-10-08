# f_data


## STDX dependency

Configure the environment variable: `export CANGJIE_STDX_DYNAMIC_PATH=/path/to/dynamic_stdx`


## Basic features

- Copying of the public member variables and public member properties of data objects
- The value of a public member with a given name can be obtained at any time
- A public member with a given name can be assigned at any time
- Instances of different classes can be copied into each other
- Instances of any class can be copied to and from JSON


## The `@DataAssist` attributes

- equal makes the decorated class implement the Equatable interface
- hash makes the decorated class implement the Hashable interface
- tostring makes the decorated class implement the ToString interface
- compare makes the decorated class implement the Comparable interface (`@DataAssist[compare]`)
- props adds public instance member properties for the non-public instance member variables of the decorated class (**only a `var` field gets a setter; a `let` only generates an immutable property**)
- fields generates the field description required by `DataFields<T>` and automatically registers the type with `DataTypeRegistry`
  (decoding an unregistered type across modules fails; generic classes are not registered)
- Attribute names are case insensitive and may be written in any case; there is also the companion annotation `@DataExclude[prop|hash|equal|compare|tostring|field]`
  to exclude a member from the corresponding capability
  ```cj
  //Assume the class
  @DataAssist[props]
  public class A {
      private var a: String = ''
      private let b: Int64 = 0
  }
  //The macro above expands to
  /*
  public class A {
      private var a_: String = ''
      private let b_: Int64 = 0
      public mut prop a: String {
          get {
              a_
          }
          value(value){
            a_ = value
          }
      }
      public prop b: Int64 {
          get {
              b_
          }
          value(value){
              b_ = value
          }
      }
  }
   */
  ```
- fields implements the copying between instances and between a class instance and JSON for the decorated class

```cj
import fountain::f_data.*
/**Everything below this line just demonstrates instance copying and conversion between a class instance and json***************/
//A class decorated with the @DataAssist[fields] macro can do all of the above
@DataAssist[equal hash tostring props fields]
public open class TestData1 {
    private var a: Int64 = 1
    private var b: String = 'asfd'
    private var c: Bool = true
    private var d: Float64 = 3.1415926
}
@DataAssist[equal hash tostring props fields]
public class TestData2 <: TestData1 {
    private var e: DateTime = DateTime.now()
    private var f: Array<Int64> = [1, 2, 3, 4, 5]
    private var g: ArrayList<String> = ArrayList<String>(['a','b','c','d','e'])
    private var m1: HashMap<String, Int64> = HashMap<String, Int64>([('a', 1),('b',2),('c',3)])
    private var m2: HashMap<String, DataAny> = {=>
        let map = HashMap<String, DataAny>()
        map.addData('a', 1)
        map.addData('b', true)
        map.addData('c', 'asdf')
        map
    }()
}

@DataAssist[equal hash tostring props fields]
public class TestData3 {
    private var a: Int64 = 0
    private var b: ?String = ''
    private var c: Bool = false
    private var d: Float64 = 0.0
    private var e: ?DateTime = None<DateTime>
    private var f: Array<Int64> = []
    private var g: ArrayList<String> = ArrayList<String>()
    private var m1: HashMap<String, Int64> = HashMap<String, Int64>()
    private var m2: HashMap<String, DataAny> = HashMap<String, DataAny>()
}
//The populate, tryFromData, toJson, fromJson and similar calls below work because they are all decorated with @DataAssist[props fields]
private let _ = {=>
    try{
        var data2 = TestData2()
        var data3 = DataObject<TestData3>.populate(data2).getOrThrow()
        //Ignore validation:
        // data3 = DataObject<TestData3>.populate(data2, flag: DEFAULT_DATA_FLAG | IGNORE_VALIDATION).getOrThrow()
        //Ignore validation failures:
        // data3 = DataObject<TestData3>.populate(data2, flag: DEFAULT_DATA_FLAG | IGNORE_NOT_MATCHED_VALIDATION).getOrThrow()
        println('AAAAAAAAAAAAAAAAAAAAAAAAAAAAA ${data2}')
        println('BBBBBBBBBBBBBBBBBBBBBBBBBBBBB ${data3}')
        let dobj = DataObject<TestData2>(data2)
        let json = JsonValue.tryFromData(dobj)
        println('CCCCCCCCCCCCCCCCCCCCCCCCCCCCC ${json}')
        let data = json.toData()
        data3 = DataObject<TestData3>.populate(data2).getOrThrow()
        println('DDDDDDDDDDDDDDDDDDDDDDDDDDDDD ${data3}')
        data2.b=''
        data2 = DataObject<TestData2>.populate(data3).getOrThrow()
        println('EEEEEEEEEEEEEEEEEEEEEEEEEEEEE ${data2} ${data2.b}')
        let map = HashMap<String, Int64>()
        map['0'] = 0
        map['1'] = 1
        map['2'] = 2
        let data4 = map.toData()
        println('FFFFFFFFFFFFFFFFFFFFFFFFFFFFF ${JsonValue.tryFromData(data4)}')
        let s = toJson(data2)//Convert a Cangjie object into a JSON string
        let d = fromJson<TestData2>(s)//Convert a JSON string into a Cangjie class object
        println('GGGGGGGGGGGGGGGGGGGGGGGGGGGGG ${s}')
        println('HHHHHHHHHHHHHHHHHHHHHHHHHHHHH ${d.toData()}')
    }catch(e: Exception){
        e.printStackTrace()
        throw e
    }
}()
```


## Data validation

```cj
package fountain::f_data.validation
public abstract class Validator {
    /**messageIfNotMatch is the message returned when the data does not match*/
    public const Validator(public let messageIfNotMatch!: String = '') {}
    /**Validate whether the data follows the rule*/
    public func validate(value: ?String): Bool
    /**Returns true only when both Validators are satisfied*/
    public const operator func &(right: Validator): Validator 
    /**Returns true when either Validator is satisfied*/
    public const operator func |(right: Validator): Validator 
    /**Returns true when the Validator is not satisfied*/
    public const operator func !(): Validator
    /**
     * Description of the behavior of the current validator
     */
    public prop description: String
}
/**
 * messageIfNotMatch is the message returned when the data does not match
 * A validator combining several & | ! is passed as the constructor argument of this validator
 */
@Annotation[target: [MemberVariable, MemberProperty, Parameter]]
public class CombinedValidator <: Validator {
    public const CombinedValidator(messageIfNotMatch: String, public let validator: Validator)
}
```

### The annotations below are all subclasses of `fountain::f_data.base.Validator` (the annotations themselves are defined in the `fountain::f_data.validation` package)
#### @IsNotEmpty 
The data must be non-empty

#### @IsNotBlank
The data must be non-empty and must not consist of whitespace characters

#### @StringSize
```cj
/**
 * messageIfNotMatch is the message returned when the data does not match
 * min minimum string length
 * max maximum string length
 */
@StringSize[messageIfNotMatch: 'not match message', min: 0, max: 10]
```

#### @IsInteger
The data must be an integer

#### @IsDecimal
The data must be a real number, including integers and decimals

#### @IsEmail
The data must be an e-mail address

#### IsChineseCellPhone
The data must be a Chinese cell phone number

#### IsIntegerRange
```cj
/**
 * Validate whether the data is an integer within the given range
 * min: minimum integer
 * max: maximum integer
 * minInclusive: whether the data may be the minimum
 * maxInclusive: whether the data may be the maximum
 */
@IsIntegerRange[messageIfNotMatch: 'not match message', 
                min: 0, max: 1000, minInclusive: true, maxInclusive: false]
```

#### @IsBool
The data must be true or false

#### IsDateTime
```cj
/**
 * format The data must follow the given format
 */
@IsDateTime[messageIfNotMatch: 'not match message', format: 'yyyy-MM-dd HH:mm:ss']
```

#### IsDuration
The data must be a Duration string

#### IsIntegers
```cj
/**
 * seperator The separator of the data; split the data by seperator and every part must be an integer
 */
@IsIntegers[messageIfNotMatch: 'not match message', separator: ',']
```

#### @DoesMatchRegex
```cj
/**
 * regex The data must match the given regular expression
 */
@DoesMatchRegex[messageIfNotMatch: 'not match message', regex: '<REGEXP>']
```


## Data conversion

In some cases the default conversion cannot be completed, for example converting a string-formatted time into the `std.time.DateTime` type.
```cj
/**
 * T is the target type of the conversion
 */
public abstract class DataConverter<T> {
    public const init(){}
    /**
     * @param data The data to convert
     */
    public func convert(data: Data, flag!: DataConversionFlag): ?T 
}
/**
 * Abstract time converter; some implementations cannot necessarily determine the time format immediately, so an abstract class
 * is provided for such cases to implement
 */
public open class AbstractDateTimeConverter <: DataConverter<DateTime> {
    public const init(){}
    protected func doConvert(data: Data, flag: DataConversionFlag, format: String)
}
public class DateTimeConverter <: AbstractDateTimeConverter {
    /**
     * @param format Convert the data of the convert function into a DateTime in this format
     */
    public const DateTimeConverter(private let format: String){}
    /**
     * Convert data into a string, then convert the string into a DateTime according to format
     */
    public func convert(data: Data, flag!: DataConversionFlag = DEFAULT_DATA_FLAG): ?DateTime 
}
```


## JSON SCHEMA

```cj
package fountain::f_data.json:

public interface ToJsonSchema {
    static func toJsonSchema<T>(): String where T <: ObjectData<T>
}

extend JsonObject <: ToJsonSchema

public sealed abstract class JsonSchema {
    public const init(){}
}

@Annotation[target: [MemberVariable, MemberProperty]]
public class JsonBoolSchema <: JsonSchema {
    public const JsonBoolSchema(
        public let default!: ?Bool = None,
        public let title!: ?String = None,
        public let description!: ?String = None){}
}

@Annotation[target: [MemberVariable, MemberProperty]]
public class JsonIntSchema <: JsonSchema {
    public const JsonIntSchema(
        public let minimum!: ?Int64 = None,
        public let maximum!: ?Int64 = None,
        public let multipleOf!: ?Int64 = None,
        public let exclusiveMinimum!: Bool = false,
        public let exclusiveMaximum!: Bool = false,
        public let default!: ?Int64 = None,
        public let enumeration!: ?String = None,
        public let title!: ?String = None,
        public let description!: ?String = None){}
}

@Annotation[target: [MemberVariable, MemberProperty]]
public class JsonFloatSchema <: JsonSchema {
    public const JsonFloatSchema(
        public let minimum!: ?Float64 = None,
        public let maximum!: ?Float64 = None,
        public let multipleOf!: ?Float64 = None,
        public let exclusiveMinimum!: Bool = false,
        public let exclusiveMaximum!: Bool = false,
        public let default!: ?Float64 = None,
        public let enumeration!: ?String = None,
        public let title!: ?String = None,
        public let description!: ?String = None){}
}
@Annotation[target: [MemberVariable, MemberProperty]]
public class JsonStringSchema <: JsonSchema {
    public const JsonStringSchema(
        public let minLength!: ?Int64 = None,
        public let maxLength!: ?Int64 = None,
        public let pattern!: ?String = None,
        public let format!: ?String = None,
        public let enumeration!: ?String = None,
        public let default!: ?String = None,
        public let title!: ?String = None,
        public let description!: ?String = None){}
}
@Annotation[target: [MemberVariable, MemberProperty]]
public class JsonArraySchema <: JsonSchema {
    public const JsonArraySchema(
        public let items!: ?JsonSchema = None,
        public let minItems!: ?Int64 = None,
        public let maxItems!: ?Int64 = None,
        public let uniqueItems!: ?Bool = None,
        public let title!: ?String = None,
        public let description!: ?String = None){}
}
@Annotation[target: [MemberVariable, MemberProperty]]
public class JsonObjectSchema <: JsonSchema {
    public const JsonObjectSchema(
        public let required!: ?String = None,
        public let additionalProperties!: ?Bool = None,
        public let title!: ?String = None,
        public let description!: ?String = None){}
}
```


## JSONPath queries

## Overview

`fountain::f_data.path` provides querying based on RFC 9535 (JSONPath), supporting the selection of nodes from a `fountain::f_data.base.Data`
tree by path expression.

```cj
import fountain::f_data.base.*
import fountain::f_data.path.*

let data: Data = buildMyData()
let path = DataPath.cache("$.store.books[?(@.price > 9)].title")
for (title in path.get(data)) {
    println(title)  // Print all matching book titles
}
```

---

## Core API: `DataPath`

`DataPath` is the only entry point for compiling and evaluating paths. It is declared as `abstract sealed class DataPath <: DataPathNode`, and
instances are obtained through two static factory methods:

### `DataPath.cache(path: String): DataPath`
Compiles the path string, caching the result temporarily in a `HeapCache` (`maxLife: Duration.day`, `maxSize: 10000`); suited to dynamic or
user-supplied paths.

### `DataPath.solid(path: String): DataPath`
Compiles the path string, caching the result permanently (`ConcurrentHashMap`); suited to fixed paths that do not change within the process.

### `DataPath.get(data: Data): Iterator<Data>`
Evaluates against the `Data` tree and returns an iterator over all matching nodes. Usage:

```cj
let matches = path.get(someData)
for (m in matches) {
    // Handle the matching Data node
}
```

---

## Path syntax reference

### Identifiers

| Syntax | Description | Example |
|------|------|------|
| `$` | Root node | `$.name` |
| `@` | Current node (only inside a filter) | `@.age > 25` |

### Child segments

| Syntax | Description | Example |
|------|------|------|
| `.name` | Dot name | `$.store.name` |
| `.*` | Wildcard for all child members | `$.store.*` |
| `['name']` | Bracket name | `$['store']['name']` |
| `[*]` | Bracket wildcard | `$[*]` |
| `[N]` | Array index (a non-negative integer) | `$.books[0]` |
| `[A,B,C]` | Multiple indices | `$.books[0,2]` |
| `['a','b']` | Multiple names | `$.store['name','owner']` |
| `[start:end:step]` | Slice | `$.books[0:5:2]` |
| `[:N]` / `[N:]` / `[:]` | Default start/end | `$.books[:3]` |
| `[-N:]` | From the Nth from the end to the end | `$.books[-1:]` |

> **Note**: `[-1]` as an index is disabled; use the slice syntax `[-1:]`.

### Descendant segments

| Syntax | Description | Example |
|------|------|------|
| `..name` | Recursively find a name | `$..title` |
| `..*` | Recursive wildcard | `$..*` |
| `..['name']` | Recursive bracket name | `$..['title']` |
| `..[N]` | Recursive index | `$..[0]` |
| `..[s:e]` | Recursive slice | `$..[0:1]` |
| `..[?(expr)]` | Recursive filter | `$..[?(@.price > 0)]` |

> **Note**: the bare `$..` (with no selector) is disabled; `..` must be followed by a selector.

### Path-level functions

| Function | Description | Example |
|------|------|------|
| `min()` | Minimum of the array | `$.min()` |
| `max()` | Maximum of the array | `$.max()` |
| `avg()` | Average of the array | `$.avg()` |
| `length()` | Length of the array | `$.length()` |
| `count()` | Number of nodes | `$.count()` |
| `value()` | Value of the first node | `$.value()` |

---

## Filter expression syntax

### Comparison operators

| Operator | Description | Example |
|--------|------|------|
| `==` | Equal | `@.name == 'Alice'` |
| `!=` | Not equal | `@.age != 30` |
| `<` | Less than | `@.age < 30` |
| `<=` | Less than or equal | `@.age <= 30` |
| `>` | Greater than | `@.age > 30` |
| `>=` | Greater than or equal | `@.age >= 30` |
| `@.x == @.y` | Comparison between paths | `@.price == $.defaultPrice` |

Supported types: `String`, `Int64`, `Float64`, `Bool`, `null`.

### Logical operators

| Operator | Description | Example |
|--------|------|------|
| `&&` | Logical and | `@.age > 25 && @.age < 35` |
| `\|\|` | Logical or | `@.age == 25 \|\| @.age == 35` |
| `!` | Logical not | `!(@.age == 25)` |
| `(...)` | Grouping | `(@.age > 25 && @.age < 35)` |

### Existence tests

| Syntax | Description | Example |
|------|------|------|
| `?(@.name)` | The field exists | `$[?(@.name)]` |
| `?(!(@.name))` | The field does not exist | `$[?(!(@.name))]` |

### Literals

| Type | Syntax | Example |
|------|------|------|
| String | `'...'` or `"..."` | `@.name == 'Alice'` |
| Integer | `123` | `@.age == 30` |
| Floating point | `3.14` | `@.price < 10.99` |
| Boolean | `true` / `false` | `@.active == true` |
| null | `null` | `@.name == null` |

### Function extensions

| Function | Description | Syntax | Example |
|------|------|------|------|
| `match(path, regex)` | Full-string regex match | `match(@.name, "A.*")` | `$[?(match(@.name, 'A.*'))]` |
| `search(path, regex)` | Regex search for a substring | `search(@.name, "lice")` | `$[?(search(@.name, 'lice'))]` |
| `count(path)` | Node count comparison | `count(@.*) > 2` | `$[?(count(@.*) == 3)]` |
| `value(path)` | First node value comparison | `value(@.name) == "Alice"` | `$[?(value(@.name) == 'Alice')]` |
| `length(path)` | Length comparison | `length(@.name) > 3` | `$[?(length(@.name) > 5)]` |
| `count(match(...))` | Nested count | `count(match(@.name, 'A')) > 0` | `$[?(count(match(@.name, 'Alice')) > 0)]` |
| `value(search(...))` | Nested value | `value(search(...)) == "X"` | — |
| `match(path, @.path)` | Dynamic regex path | `match(@.name, @.pattern)` | `$[?(match(@.name, @.pattern))]` |
| `match(match(...))` | Deep nested match | Any depth | `$[?(match(match(@.name, 'A.*'), 'Alice'))]` |
| `count(match(search(...)))` | 3 levels of nesting | Any depth | `$[?(count(match(search(@.name, 'lice'), 'Alice')) > 0)]` |
| `match(...match(...)...)` | 30-level stress test | Depth 30 verified | `testArbitraryDepthNesting` |

---

### Formal verification of deep nesting

Support for deeply nested function expressions is based on **inductive verification** rather than exhaustive testing.

#### The induction framework

**Base case (depth = 1):** `match(@.name, 'Alice')` — the standard `MatchFilter`, verified as correct by `testFilterMatch`.

**Inductive step:** assuming the compiler handles an expression of `depth = k` correctly, `depth = k+1` must be correct too. The reasons are as follows:

The compiler handles function expressions by **structural recursion**. The implementation of the core function `compileSubFilter`:

```
compileSubFilter(tokens: Tokens): String {
    let inner = parseFilterTokens(tokens, solid)  // Recursive parsing
    let expr = parseExpr(inner)                    // Parse into an AST
    let filter = compileFilter(expr)               // Compile into a DataFilter
    let idx = subFilters.size
    subFilters.add(filter)
    idx.toString()
}
```

This function has **no depth parameter, no recursion counter, no maximum depth limit**. Every call is atomic —— the compiler neither knows nor cares
which nesting level this is. When an outer function (such as `count()` or `match()`) detects that an argument is a function call, it calls
`compileSubFilter`, and the result is referenced through `subFilters[idx]`.

**Recursive invariance:** no matter how many levels are nested, the call structure of `compileSubFilter` is exactly the same; the only difference is
the call stack depth. The recursion of the compiler has no hidden limit —— the number of levels is bounded only by the Cangjie runtime stack depth.

#### The runtime execution chain

```
count(match(search(@.name, 'lice'), 'Alice')):
  CountFilterResult.check(data)
    └─ Iterate over the child nodes child of data
       └─ FnMatchFilter.check(child)
          └─ Iterate over the child nodes grandchild of child
             └─ SearchFilter.check(grandchild)
                └─ Check whether @.name contains 'lice'
             └─ Take the matching value → regex.matches("Alice") → true
          └─ Return true
       └─ count++
    └─ count > 0 → true/false
```

Every time an outer function calls `filter.check(child)`, that `DataFilter` may itself be a function wrapping an inner filter. The length of the call
chain equals the nesting depth —— there is no artificial limit.

#### Verification method

`testArbitraryDepthNesting` builds expressions with a recursive generator:

```
depth=1: match(@.name, 'Alice')
depth=2: match(match(@.name, 'Alice'), 'Alice')
depth=n: match(...match(@.name, 'Alice')..., 'Alice')
```

The test verifies the compilation and execution correctness of depths 2..15, plus a **stress test at depth 30**. Since the compiler has no depth
counter, if depth 15 is correct then depth 30 is structurally completely equivalent —— the generated call chain is merely the same pattern, longer.
This matches the spirit of mathematical induction: the base case is verified, the inductive step is verified, and the conclusion holds for any `n`.

---

### Custom extensions

| Operator | Description | Example |
|--------|------|------|
| `=~ /regex/` | Regex match | `@.name =~ /A.*/` |
| `in [...]` | Set membership | `@.age in [25, 35]` |
| `nin [...]` | Not a member | `@.age nin [25, 35]` |
| `anyof [...]` | Intersection > 0 | `@.age anyof [25, 35]` |
| `subsetof [...]` | Subset | `@.age subsetof [20, 25, 30]` |
| `nooneof [...]` | Intersection = 0 | `@.age nooneof [40, 50]` |
| `size N` | Length match | `@.name size 5` |

### Array/object structural equality

| Syntax | Description | Example |
|------|------|------|
| `@.* == [v1, v2]` | Array literal comparison | `@.* == [1, 2, 3]` |
| `@ == {"k": v}` | Object literal comparison | `@ == {"name": "Alice", "age": 30}` |

---

## Data types (`fountain::f_data.base`)

| Type | Description | Key usage |
|------|------|---------|
| `Data` | Root interface of all data values | The operand of path queries |
| `DataReal(data: Decimal)` | Numeric value | `DataReal(42)`, `DataReal("3.14")` |
| `DataString(data: String)` | String | `DataString("hello")` |
| `DataBool` | Boolean | `DataBool.TRUE`, `DataBool.FALSE` |
| `DataNone` | Null value | `DataNone.INSTANCE` |
| `DataList` | Ordered list | `add<T>(item)`, `iterator()` |
| `DataDict` | Key-value mapping | `add(key, value)`, `iterator()` |
| `DataDateTime` | Date and time | — |
| `DataDuration` | Time interval | — |

The `NamedData` interface provides `get(name: String): ?Data` and `operator [](name: String): Data`; the `.name` path selector relies on this interface.

---

## Exceptions

| Exception | Description |
|------|------|
| `DataException` | Path syntax errors, filter parse failures, I-JSON range violations, rejected negative indices, and so on |

All exceptions inherit from `fountain::f_base.BaseException`.

---

## RFC 9535 feature support table

### Identifiers

| Syntax | RFC | Implementation | Test |
|------|-----|------|------|
| `$` root node | §2.1 | `RootPathNode` | `testRootPath` |
| `@` current node (inside a filter) | §2.1 | `CurrentPathNode` | filter tests |

### Child segments

| Syntax | RFC | Implementation | Test |
|------|-----|------|------|
| `.name` dot name | §2.2 | `SubPathNode` | `testSubPath` |
| `.*` dot wildcard | §2.2 | `AnySubPathNode` | `testWildcard` |
| `['name']` bracket name | §2.4 | `SubPathNode` | `testMultiSubPath` |
| `[*]` bracket wildcard | §2.4 | `AnySubPathNode` | `testWildcard` |
| `[0]` index | §2.4 | `IndexPathNode` | `testIndex` |
| `[0,2]` multiple indices | §2.4 | `MultiIndexPathNode` | `testMultiIndex` |
| `['a','b']` multiple names | §2.4 | `MultiSubPathNode` | `testMultiSubPath` |
| `[start:end]` slice | §2.4 | `RangePathNode` | `testRange` |
| `[start:end:step]` slice with step | §2.4 | `RangePathNode` | `testRangeWithStep` |
| `[:5]` default start | §2.4 | `RangePathNode(UNSET,5,1)` | `testSliceDefaultStart` |
| `[3:]` default end | §2.4 | `RangePathNode(3,UNSET,1)` | `testSliceDefaultEnd` |
| `[:]` defaults for both | §2.4 | `RangePathNode(UNSET,UNSET,1)` | `testSliceDefaultAll` |
| `[::-1]` negative step default | §2.4 | `RangePathNode(UNSET,UNSET,-1)` | `testSliceReverse` |
| `[0:3:0]` step = 0 | §2.4 | Empty result | `testSliceStepZero` |
| `[5:10]` empty range | §2.4 | Empty result (no error) | `testRangeEmptyStartBeyondEnd` |

### Descendant segments

| Syntax | RFC | Implementation | Test |
|------|-----|------|------|
| `..*` recursive wildcard | §2.3 | Consumes MUL automatically | `testRecursiveDescendStar` |
| `..name` recursive name | §2.3 | IDENTIFIER + RANGEOP | `testRecursiveDescendSubPath` |
| `..['name']` recursive bracket | §2.3 | RANGEOP+DOT→LSQUARE | `testRecursiveBracketName` |

### Filter selector

| Syntax | RFC | Implementation | Test |
|------|-----|------|------|
| `?<expr>` | §2.4 | `DataFilterPathNode` | all filter tests |

### Comparison operators

| Operator | RFC | Implementation | Test |
|--------|-----|------|------|
| `==` | §3.1 | `EqFilter` | `testFilterEqString` |
| `!=` | §3.1 | `NotEqFilter` | `testFilterNotEq` |
| `<` | §3.1 | `CmpFilter(LT,false)` | `testFilterLessThan` |
| `<=` | §3.1 | `CmpFilter(LT,true)` | `testFilterLessThanOrEqual` |
| `>` | §3.1 | `CmpFilter(GT,false)` | `testFilterGreaterThan` |
| `>=` | §3.1 | `CmpFilter(GT,true)` | `testFilterGreaterThanOrEqual` |
| `@.x == @.y` path comparison | §3.1 | `EqPathFilter` | `testPathEq` |

### Logical operators

| Operator | RFC | Implementation | Test |
|--------|-----|------|------|
| `&&` | §3.1 | `AndFilter` | `testFilterAnd` |
| `\|\|` | §3.1 | `OrFilter` | `testFilterOr` |
| `!` | §3.1 | `NotFilter` | `testFilterNot` |
| `(...)` grouping | §3.1 | `ParenExpr` | `testFilterNot` |

### Literals

| Type | RFC | Implementation | Test |
|------|-----|------|------|
| String `'...'` / `"..."` | §5 | Quote stripping | `testFilterEqString` |
| Integer `25` | §5 | `Int64.parse` | `testFilterEqInt` |
| Floating point `3.14` | §5 | `Float64.parse` | `testFilterEqFloat` |
| `true` / `false` | §5 | `Bool` | `testFilterEqBool` |
| `null` | §5 | `NullFilter` + `DataNone` | `testFilterNullEq` |

### Existence tests

| Syntax | RFC | Implementation | Test |
|------|-----|------|------|
| `?(@.name)` | §3.3 | `ExistsFilter` | `testFilterExists` |
| `?(!(@.name))` | §3.3 | `NotFilter(ExistsFilter)` | `testFilterNotExists` |

### Function extensions

| Function | RFC | Implementation | Test |
|------|-----|------|------|
| `length()` path level | §4.2 | `LengthPathNode` | `testFunctionLength` |
| `length()` filter comparison | §4.2 | `LengthCmpFilter` | `testFilterLengthGt` |
| `count()` path level | §4.3 | `CountPathNode` | `testFunctionCount` |
| `count()` filter comparison | §4.3 | `CountCmpFilter` | `testFilterCountEq` |
| `count(match(...))` nested | §4.3 | `CountFilterResult` | `testCountMatch` |
| `match()` | §4.4 | `MatchFilter` | `testFilterMatch` |
| `match()` path argument | §4.4 | `DeferredMatchFilter` | `testDeferredMatchField` |
| `search()` | §4.5 | `SearchFilter` | `testFilterSearch` |
| `search()` path argument | §4.5 | `DeferredSearchFilter` | `testDeferredSearchField` |
| `value()` path level | §4.6 | `ValuePathNode` | `testFunctionValue` |
| `value()` filter comparison | §4.6 | `ValueCmpFilter`/`ValueFilterResult` | `testFilterValueEq` |
| `match(match(...))` any depth | §2.4 | `FnMatchFilter` + `compileSubFilter` | `testArbitraryDepthNesting` |
| `match(search(...))` cross-type nesting | §2.4 | `FnMatchFilter`/`FnSearchFilter` | `testDeepNestedCountMatchSearch` |
| `count(match(search(...)))` 3 levels | §2.4 | `CountFilterResult` + `FnMatchFilter` | `testDeepNestedCountMatchSearch` |
| Depth 30 stress test | §2.4 | Inductive verification (no depth limit) | `testArbitraryDepthNesting` |

### Structural equality

| Syntax | Implementation | Test |
|------|------|------|
| `@.* == [1, 2, 3]` | `StructEqFilter` | `testFilterArrayEq` |
| `@ == {"a": 1}` | `ObjectEqFilter` | `testFilterObjectEq` |
| Object with a nested array value | `ObjectEqFilter` | `testFilterObjectEqNestedArray` |
| Object with a nested object value | `ObjectEqFilter` | `testFilterObjectEqNestedObject` |
| Object with bool/null values | `ObjectEqFilter` | `testFilterObjectEqBoolAndNull` |

### Custom extensions

| Syntax | Implementation | Test |
|------|------|------|
| `=~ /regex/` regex | `RegexFilter` | `testFilterRegex` |
| `in` set | `InFilter` | `testFilterIn` |
| `nin` not in set | `NinFilter` | `testFilterNin` |
| `in [null]` set containing null | `InFilter(hasNull)` | `testFilterInNull` |
| `anyof` | `AnyOfFilter` | `testFilterAnyOf` |
| `subsetof` | `SubSetOfFilter` | `testFilterSubSetOf` |
| `nooneof` | `NoOneOfFilter` | `testFilterNoOneOf` |
| `size` | `SizeFilter` | `testFilterSize` |

### Edge-case behavior

| Behavior | RFC | Implementation |
|------|-----|------|
| Duplicate nodes kept `$[0,0]` | §6.3 | Kept through a lazy flatMap chain |
| Empty nodelist → empty result | §6.1 | Default behavior |
| Type mismatch → false | §6.2 | `case _ => false` |
| `@` only valid inside a filter | §2.1 | Validated by `doCompile` |
| Structural mismatch → empty result | §6.1 | `case _ => OptionIterator<Data>()` |
| I-JSON number range | §6.5 | `validateIJSON()` |
| `..` must have a selector | §2.5.2 | Throws `DataException` |
| `[-1]` must use slice syntax | §2.3.3 | Throws `DataException` |
| Trailing `.` | §2.2 | Throws `DataException` |

---

## Features not yet supported

| Feature | RFC section | Description |
|------|--------|------|
| **Normalized paths** | §2.7 | `DataPath.get()` returns an `Iterator<Data>` without path metadata. A `NodeList` type + a `getWithPaths()` method + normalization logic for every node type would have to be added (an architectural change; not currently planned) |

---

## References

- [RFC 9535: JSONPath: Query Expressions for JSON](https://www.rfc-editor.org/rfc/rfc9535)
- [RFC 9535 coverage list](doc/RFC9535_COVERAGE.md)


## Failing fast
`import fountain::f_data.BreakingCommand`
During the execution of server business logic, executing `BreakingCommand.new(value)` ends the current business immediately (failing fast),
`value` is the data returned to the client (`BreakingCommand` itself is defined in `src/base/BreakingCommand.cj`).

## Supplement: points not expanded item by item in this README (the source code is authoritative)

- **Conversion flags** (`src/base/global_objects.cj`, passed as the `flag!` argument of `toData` / `fromData` / `populate`):
  `DEFAULT`, `IGNORE_FIELD_NOT_FOUND`, `IGNORE_FIELD_TYPE_NOT_MATCH`, `IGNORE_NONE`, `IGNORE_VALIDATION`,
  `IGNORE_NOT_MATCHED_VALIDATION`, `DEEP`, `WRAPPING`, `THROWING`, `SATURATING_ON_INT_OVERFLOW`.
- **When validation takes effect**: a validator runs only when `MutableField.set` writes, and **only when the value is a `DataString`**;
  `ReadableField.validator` can be read; a failure throws `ValidationException`.
- **Exception family** (`src/exception/`): `DataException`, `DataParsableException`, `JsonException`, `ValidationException`.
- **Data object extension points**: `ObjectData<T>` / `DataFields<T>` / `ObjectFields` / `MutableField` / `ReadonlyField`;
  `DataObject<T>` provides several `populate` overloads, `set/get(name, flag)` and the public field `data`.
- **Additional annotations**: `@DataExclude[prop|hash|equal|compare|tostring|field]`, `@FieldAlias(name)`,
  `@DateTimeConverter(format)`; validator combinations `AndValidator` / `OrValidator` / `NotValidator` / `DummyValidator`,
  `CombinedValidator(validator)`.
- **Additional types**: `DataAny` (the neutral type used in the example), `DataUnit`, `DataTuples`, `DataInputStream`;
  the std types already extended with `DataFields` are in `src/base/NumberData.cj`, `DataString.cj`, `DataBool.cj`,
  `DataDuration.cj`, `DataDateTime.cj`, `CollectionData` / `MapData` / `ConcurrentMapData`, `DataInputStream`.
- **JSON conversion signatures**: `toJson<T>(d, flag!)` / `fromJson<T>(s, flag!): ?T` (`src/json/JsonConverter.cj`);
  `toJsonSchema<T>()` returns a `JsonObject` (not a `String`).
- **`DataPath.cache` depends on `f_cache.HeapCache` and `DataPath.solid` depends on `ConcurrentHashMap`**;
  the base class `DataPathNode` is an internal interface ⇒ **custom path nodes cannot be defined outside the package**.
- The 8 test files under `src/path/` are published with the package (`include = ["src","doc"]` in `cjpm.toml`).
- **Outdated document**: many "Missing" items in `doc/RFC9535_GAPS.md` are actually implemented (`count/value` comparison inside filters,
  I-JSON validation, object/array structural equality, `in [null]`); `doc/RFC9535_COVERAGE.md` and the source code are authoritative.

---

## Other public API

The declarations below are not expanded above; they are grouped by module level and by type (members declared in `extend` blocks are listed under the extended type). See the corresponding files under `src/` for the full semantics.

- Module level: `CollectionRawType` (interface), `DummyDataFields` (interface), `ExtendJsonValue` (interface), `public class IsBool <: Validator`, `public class IsChineseCellPhone <: Validator`, `public class IsDecimal <: Validator`, `public class IsDuration <: Validator`, `public class IsEmail <: Validator`, `public class IsInteger <: Validator`, `public class IsNotBlank <: Validator`, `public class IsNotEmpty <: Validator`, `JSON_NULL` (let), `public class JsonArray <: JsonValue & Collection<JsonValue>`, `public class JsonBool <: JsonValue`, `public class JsonDecimal <: JsonValue`, `public class JsonInt <: JsonValue`, `public enum JsonKind <: Equatable<JsonKind>`, `JsonNull` (class), `JsonString` (class), `JsonValue` (class), `MapRawType` (interface), `SimpleDataObject` (interface), `public static func isSimple(): Bool`, `public func next(): ?Data`, `public static func tryParse(s: String): ?Data`
- `DateTime`: `static func setCurrentThreadDateFormat(format: String)`, `static func setDefaultDateFormat(format: String)`
- `Duration`: `static func tryParse(s: String): ?Duration`
- `JsonArray`: `func addNull(): Unit`, `func getItem(index: Int64): JsonValue`, `func getItems(): ArrayList<JsonValue>`, `func isEmpty(): Bool`, `func remove(index: Int64): Unit`, `func removeIf(predicate: (JsonValue) -> Bool): Unit`, `func setItem(index: Int64, value: JsonValue): Unit`
- `JsonKind`: `prop isArray: Bool`, `prop isBool: Bool`, `prop isDecimal: Bool`, `prop isInt: Bool`, `prop isNull: Bool`, `prop isObject: Bool`, `prop isString: Bool`
- `JsonObject`: `func addNull(name: String): Unit`, `func contains(name: String): Bool`, `func getFields(): HashMap<String, JsonValue>`, `func isEmpty(): Bool`, `func remove(name: String): ?JsonValue`, `func removeIf(predicate: (String, JsonValue) -> Bool): Unit`
- `JsonValue`: `static func from(data: Data, flag: DataConversionFlag): JsonValue`, `prop kind: JsonKind`, `func write(output: OutputStream): Unit`
- `ObjectFields`: `func create(): Object`, `static func getObjectFields<T>(metas: () -> (Array<ReadableField>, ()->Object)): ObjectFields`, `func isEmpty()`, `func mutableField(name: String): ?MutableField`, `func mutableFields(): Iterator<MutableField>`, `func readableField(name: String): ?ReadableField`
- `String`: `static func tryParse(s: String): ?String`
- `JsonNull`: `static let instance = JsonNull()` (the singleton for JSON null; the module-level `JSON_NULL` is this value)
