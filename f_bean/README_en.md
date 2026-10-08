# IOC
`fountain::f_bean` is an IOC framework.
- Beans can be fetched by name
- Beans can be fetched by the bean type, by all types that have an inheritance relation with the bean, and by the interfaces the bean implements
- Beans can be fetched by annotations decorating the bean type, and by the annotations of parent types
---
```cj
import fountain::f_bean.*
import fountain::f_bean.macros.*

//The IOC feature can only manage instances of classes; the related macros and annotations may only decorate classes or class members
@Bean
@BeanMeta[//These are all default values of @BeanMeta; when they are all defaults, a class managed by the IOC does not need to be decorated with @BeanMeta
          name: '', //The name of the bean; by default the fully qualified type name followed by the bean ordinal
          scope: BeanScope.singleton, //BeanScope has two values, singleton and prototype: singleton is a singleton bean with only one instance in the whole process lifetime, prototype means every fetch of this bean is a new instance
          lazy: true,//For a singleton bean, lazy being true means it is initialized only when the bean is first fetched, false means it is initialized as soon as the bean is registered with the IOC; for a prototype bean, lazy has no effect
          primary: false,//beans with primary true come first among beans of the same type, and then they are sorted by order
          order: 0,//order gives the sort order of beans of the same type
          condition: NoneBeanCondition.instance//The bean initialization condition; only beans satisfying the given condition are instantiated, and those that do not are removed from the IOC; this is explained in detail later
          ]//@BeanMeta must be used together with @Bean; used alone it has no effect
public class ClassName{}

/*
 * The arguments of @Bean are the generic arguments of the generic class it decorates; several groups of generic argument types
 * may be separated by |
 * The code below means the decorated class instantiates GenericClass<String, Duration> and GenericClass<Int64, String>
 */
@Bean[String, Duration|Int64, String]
public class GenericClass<T, E>{
    private let bean = lookup<ClassName>()//The lookup function searches the BEANs managed by the IOC and returns the first bean found
}

```

## The lookup functions

The IOC framework has a family of functions whose names start with lookup, used to fetch managed beans.
First import the package `fountain::f_bean.*`
```cj
import fountain::f_bean.*
```

### Parameter style (two-layer convention)

This API has two layers, and **the condition parameters are written differently**, so write them according to the layer you are calling:

| Layer | Condition/name/label | Type argument | How defaults are carried | Call example |
|---|---|---|---|---|
| Upper layer `lookup*` (the sections below in this file) | **positional parameter** | positional (generic argument) | a same-named 0-argument overload | `lookupList<MyBean>(myCond)` ✓; `lookupList<MyBean>(cond: myCond)` ✗ |
| Lower layer `BeanFactory.instance`'s `getFirst`/`getList`/`getMap`/`iterator`/`getFirstTuple`/`getAllTuples` | **named parameter** `cond!` | **positional parameter** `beanType` | parameter default values | `getList<MyBean>(TypeInfo.of<MyBean>(), cond: myCond)` ✓; `getList<MyBean>(TypeInfo.of<MyBean>(), myCond)` ✗; `getList<MyBean>(beanType: ti, cond: myCond)` ✗ |

```cj
let all = lookupList<MyBean>()                      // Upper layer: positional parameter
let named = lookupList<MyBean>(Exactly('beanName')) // Upper layer: positional parameter
// Lower layer: beanType is positional and cond is a named parameter
let low = BeanFactory.instance.getList<MyBean>(TypeInfo.of<MyBean>(), cond: Exactly('beanName'))
```

**Convention for new APIs**: use the **upper-layer style** uniformly —— condition parameters are positional, and default values are carried by the same-named 0-argument overload.

### Fetching a single bean
#### `lookup<T>(): T`
Fetch the first bean of the given generic argument; an exception is thrown when none is found

#### `lookup<T>(name: String): T`
Fetch the bean of the given type whose name is name; an exception is thrown when none is found

#### `lookup<T>(cond: StringCond): T`
Fetch the first bean of the given type whose name satisfies the condition given by cond; an exception is thrown when none is found

### Fetching an Option of a bean type
#### `lookupOption<T>(): ?T`
Fetch the first bean of the given generic argument; returns `None<T>` when none is found

#### `lookupOption<T>(name: String): ?T`
Fetch the bean of the given type whose name is name; returns `None<T>` when none is found

#### `lookupOption<T>(cond: StringCond): ?T`
Fetch the first bean of the given type whose name satisfies the condition given by cond; returns `None<T>` when none is found

### Fetching an `ArrayList<T>` of beans
#### `lookupList<T>(): ArrayList<T>`
Fetch all beans of the given generic argument type

#### `lookupList<T>(cond: StringCond): ArrayList<T>`
Fetch all beans of the given generic argument type whose names satisfy the given condition

### Fetching a `HashSet<T>` of beans
#### `lookupHashSet<T>(): HashSet<T> where T <: Hashable & Equatable<T>`
Fetch all beans of the given generic argument type

#### `lookupHashSet<T>(cond: StringCond): HashSet<T> where T <: Hashable & Equatable<T>`
Fetch all beans of the given generic argument type whose names satisfy the given condition

### Fetching a `TreeSet<T>` of beans
#### `lookupTreeSet<T>(): TreeSet<T> where T <: Comparable<T>`
Fetch all beans of the given generic argument type

#### `lookupTreeSet<T>(cond: StringCond): TreeSet<T> where T <: Comparable<T>`
Fetch all beans of the given generic argument type whose names satisfy the given condition

### Fetching a HashMap`<String, T>` of beans
#### `lookupHashMap<T>(): HashMap<String, T>`
Fetch all beans of the given generic argument type; the returned HashMap uses the bean names as KEYs

#### `lookupHashMap<T>(cond: StringCond): HashMap<String, T>`
Fetch all beans of the given generic argument type whose names satisfy cond; the returned HashMap uses the bean names as KEYs

### Fetching a `HashMap<L, T>` of beans
#### `lookupLabels<L, T>(): HashMap<L, T> where L <: Hashable & Equatable<L>, T <: BeanLabel<L>`
Fetch all beans of the given generic argument type; the generic argument must implement the interface `BeanLabel<L>`.

#### `lookupLabels<L, T>(cond: StringCond): HashMap<L, T> where L <: Hashable & Equatable<L>, T <: BeanLabel<L>`
Fetch all beans of the given generic argument type whose names satisfy cond.

#### `BeanLabel<L>`
```cj
public interface BeanLabel<L> where L <: Hashable & Equatable<L> {
    prop label: L
}
```

### Fetching weighted beans as `TreeMap<W, T>`
#### `lookupWeights<W, T>(): TreeMap<W, T> where W <: Comparable<W> & Addable<W>, T <: BeanWeight<W>`
Fetch all beans of the given generic argument type; the generic argument must implement the interface `BeanWeight<W>`

#### `lookupWeights<W, T>(cond: StringCond): TreeMap<W, T> where W <: Comparable<W> & Addable<W>, T <: BeanWeight<W>`
Fetch all beans of the given generic argument type; the generic argument must implement the interface `BeanWeight<W>`

#### `BeanWeight<W>`
```cj
public interface BeanWeight<W> where W <: Comparable<W> & Addable<W> {
    prop weight: W
}
```

### Fetching beans by annotation

Matching scope: the types decorated with the annotation `A`, plus the annotations on **their parent classes, implemented interfaces and meta-annotation chain** (that is, every node expanded from the registration-time type queue).
`T` is the filter condition on the bean type and **must be a class** (`where T <: Object`; in Cangjie an interface is not a subtype of `Object`).
The order is the same as other queries (the `primary` of `@BeanMeta` first, then by `order`, then by name).

#### `lookupByAnnotation<T, A>(): T`
Fetch the first bean satisfying the condition; an exception is thrown when none is found

#### `lookupByAnnotation<T, A>(cond: StringCond): T`
Fetch the first bean satisfying the condition whose bean name also satisfies `cond`; an exception is thrown when none is found

#### `lookupOptionByAnnotation<T, A>(): ?T`
Fetch the first bean satisfying the condition; returns `None<T>` when none is found

#### `lookupOptionByAnnotation<T, A>(cond: StringCond): ?T`
Fetch the first bean satisfying the condition whose bean name also satisfies `cond`; returns `None<T>` when none is found

#### `lookupListByAnnotation<T, A>(): ArrayList<T>`
Fetch all beans satisfying the condition

#### `lookupListByAnnotation<T, A>(cond: StringCond): ArrayList<T>`
Fetch all beans satisfying the condition whose bean names also satisfy `cond`

#### `lookupMapByAnnotation<T, A>(): HashMap<String, T>`
Fetch all beans satisfying the condition; the returned HashMap uses the bean names as KEYs

#### `lookupMapByAnnotation<T, A>(cond: StringCond): HashMap<String, T>`
Fetch all beans satisfying the condition whose bean names also satisfy `cond`; the returned HashMap uses the bean names as KEYs

#### Restricting only by annotation, without restricting the bean type

The sections above use `T` to filter the bean type; to query by annotation only (without looking at the type) use the group below —— it is semantically equivalent to `T = Object` (the type of every bean is a class), but the type argument does not have to be written, and the returned elements are `Object`:

#### `lookupByAnnotationOnly<A>(): Object`
Fetch the first bean satisfying the condition; an exception is thrown when none is found

#### `lookupByAnnotationOnly<A>(cond: StringCond): Object`
Fetch the first bean satisfying the condition whose bean name also satisfies `cond`; an exception is thrown when none is found

#### `lookupOptionByAnnotationOnly<A>(): ?Object`
Fetch the first bean satisfying the condition; returns `None<Object>` when none is found

#### `lookupOptionByAnnotationOnly<A>(cond: StringCond): ?Object`
Fetch the first bean satisfying the condition whose bean name also satisfies `cond`; returns `None<Object>` when none is found

#### `lookupListByAnnotationOnly<A>(): ArrayList<Object>`
Fetch all beans satisfying the condition

#### `lookupListByAnnotationOnly<A>(cond: StringCond): ArrayList<Object>`
Fetch all beans satisfying the condition whose bean names also satisfy `cond`

#### `lookupMapByAnnotationOnly<A>(): HashMap<String, Object>`
Fetch all beans satisfying the condition; the returned HashMap uses the bean names as KEYs

#### `lookupMapByAnnotationOnly<A>(cond: StringCond): HashMap<String, Object>`
Fetch all beans satisfying the condition whose bean names also satisfy `cond`; the returned HashMap uses the bean names as KEYs

#### Lower-layer counterparts (annotation-only version, `BeanFactory.instance`)
`getFirstByAnnotationOnly<A>(cond!: StringCond = IgnoreCond): ?Object`, `getListByAnnotationOnly<A>(…): ArrayList<Object>`, `getMapByAnnotationOnly<A>(…): HashMap<String, Object>` (all `where A <: Annotation`).

#### Lower-layer counterparts (`BeanFactory.instance`)
`getFirstByAnnotation<T, A>(cond!: StringCond = IgnoreCond): ?T`, `getListByAnnotation<T, A>(cond!: StringCond = IgnoreCond): ArrayList<T>`, `getMapByAnnotation<T, A>(cond!: StringCond = IgnoreCond): HashMap<String, T>` (all `where T <: Object, A <: Annotation`). The semantics match the `lookup*` above, except that when nothing is found they return `None`/an empty collection instead of throwing; `cond` is a **named parameter** by the lower-layer convention (see "Parameter style (two-layer convention)" above).

### StringCond
```cj
/**
 * Returns true when the string satisfies the given condition
 */
public enum StringCond <: Equatable<StringCond> & Equatable<String> & ToString {
    /**
     * Ignore this condition
     */
    | IgnoreCond
    /**
     * The string passed to on equals the given string
     */
    | Exactly(String)
    /**
     * The string passed to on starts with the given string
     */
    | Prefix(String)
    /**
     * The string passed to on ends with the given string
     */
    | Suffix(String)
    /**
     * The string passed to on matches the wildcard rule
     */
    | Wildcard(String)
    /**
     * The string passed to on matches the given regular expression
     */
    | Regexp(String)
    /**
     * The constructor argument is a substring of the string passed to on
     */
    | Contains(String)
    /**
     * The string passed to on is a substring of the constructor argument
     */
    | In(String)

    public func toString(): String
    /**
     * Check whether the argument satisfies the matching rule represented by the current enum value
     */
    public func on(s: String): Bool

    public prop ignored: Bool

    public operator func ==(right: StringCond): Bool

    public operator func ==(right: String): Bool
}
```

### BeanCondition
```cj
/**
 * The bean initialization condition: only beans satisfying the condition are initialized, otherwise they are removed
 * from the BeanFactory
 * Several BeanConditions may be combined with the & | ! operators
 */
public interface BeanCondition <: ToString {
    func on(factory: BeanFactory): Bool
    operator const func &(right: BeanCondition): BeanCondition 
    operator const func |(right: BeanCondition): BeanCondition 
    operator const func !(): BeanCondition 
}

#### NoneBeanCondition
```cj
/**
 * The default bean initialization condition, a placeholder when initializing BeanMeta. Always returns true.
 */
public class NoneBeanCondition <: BeanCondition
```

#### AndCond
```cj
/**
 * This condition is true only when both bean initialization conditions are true.
 */
public class AndCond <: BeanCondition
```

#### OrCond
```cj
/**
 * This condition is true when either of the two bean initialization conditions is true; left is evaluated first.
 */
public class OrCond <: BeanCondition
```

#### NotCond
```cj
/**
 * Negates the given initialization condition
 */
public class NotCond <: BeanCondition
```

#### ConfCond
```cj
/**
 * on returns true when the configuration item satisfies the condition
 */
public enum ConfCond <: BeanCondition {
    /**
     * Ignore the configuration condition
     */
    | IgnoreConf
    /**
     * Returns true when the configuration item exists
     */
    | Exists(String)
    /**
     * Returns true when the configuration item does not exist
     */
    | NotExists(String)
    /**
     * Exists when the configuration item exists and its value satisfies StringCond; StringCond.IgnoreCond is equivalent to Exists(String)
     */
    | Value(String, StringCond)
    /**
     * Executes the function of this condition
     */
    public func on(_: BeanFactory): Bool
    public func toString(): String
}
```

#### BeanDef
```cj
/**
 * beanType is a fully qualified type name; on returns true when the given type has a bean definition
 */
public class BeanDef <: BeanCondition {
    /**
     * When other already registered beans satisfy all of these conditions, the bean using BeanType as its initialization
     * condition will be initialized
     * @param beanType A registered bean type satisfies the given condition
     * @param beanName A registered bean name satisfies the given condition
     * @param scope The BeanScope of a registered bean satisfies the given BeanScope; if this argument is None, any BeanScope satisfies it
     * @param count When the number of beans satisfying the other three conditions satisfies the condition given by this argument, the current BeanDef is judged true
     */
    public const BeanDef(
        public let beanType!: BeanDefType = IgnoreType,
        public let beanName!: StringCond = IgnoreCond,
        public let scope!: ?BeanScope = None,
        public let count!: BeanDefCount = AtLeastOne
    ) {}
    public func toString(): String
    public func on(factory: BeanFactory): Bool
}
```

##### BeanDefType
```cj
/**
 * Uses the bean type as the condition; the constructor argument of this enum is the fully qualified name of the corresponding type
 */
public enum BeanDefType <: ToString {
    /**
     * Do not check the bean type; any type is true
     */
    | IgnoreType
    /**
     * The type of the bean definition must be the given type
     */
    | Current(String)
    /**
     * The type of the bean definition is the given type or a descendant type of it
     */
    | CurrentOrSubOf(String)
    /**
     * The type of the bean definition must be a descendant type of the given type
     */
    | SubOfOnly(String)
    /**
     * The type of the bean definition must be the given type or an ancestor type of it
     */
    | CurrentOrSuperOf(String)
    /**
     * The type of the bean definition must be an ancestor type of the given type
     */
    | SuperOfOnly(String)
    public func toString(): String
    public func on(beanType: TypeInfo): Bool
}
```

##### BeanDefCount
```cj
/**
 * True when there are the given number of bean definitions
 */
public enum BeanDefCount <: ToString {
    /**
     * No bean definition
     */
    | Zero
    /**
     * Exactly one bean definition
     */
    | OnlyOne
    /**
     * At least one bean definition
     */
    | AtLeastOne
    /**
     * More than one bean definition
     */
    | MoreThanOne

    public func toString(): String
}
```

### FactoryBean
```cj
/**
 * When a class decorated with @Bean implements the FactoryBean interface, the object returned by the get function of
 * this interface is the real bean, and the implementation class of this interface is the factory of that bean
 */
public interface FactoryBean {
    /**
     * The type of the bean
     */
    static prop typeInfo: TypeInfo
    /**
     * This function returns the bean
     */
    func get(): Object
}
```

### Destroy
If a class decorated with `@Bean` implements this interface, `destroy()` must be called to release resources or destroy data when the bean is no longer used.
For a bean whose BeanScope is prototype the developer must call it; for a singleton bean the IOC framework calls it.
```cj
public interface Destroy {
    func destroy(): Unit
}
```

### PostConstructor
If a class decorated with `@Bean` implements this interface, the IOC framework must call `postConstruct()` after the bean is instantiated to complete the final initialization.
```cj
public interface PostConstruct {
    func postConstruct(): Unit
}
```

### Macros
#### `@Bean`
The basic API of the IOC framework; the classes of all beans managed by the IOC must be decorated with `@Bean`.
If a bean is initialized with a no-argument constructor, the `@Constructor` mentioned below does not have to be used

##### `@Constructor`
The constructor or static function decorated with `@Constructor` is the initialization function of the bean.
It may only decorate a constructor or static function of a class decorated with `@Bean`, otherwise an application project using this framework fails at compile time.

###### `@BeanParam(attr: Tokens, input: Tokens): Tokens`
`@BeanParam` may only decorate function parameters of a function decorated with `@Constructor`, otherwise an application project using this framework fails at compile time.
The attribute of this macro is Tokens representing a StringCond enum instance. After the macro is fully expanded, the bean whose name satisfies the condition represented by attr is passed as the corresponding argument.

###### `@Value(attr: Tokens, input: Tokens): Tokens`
`@Value` may only decorate function parameters of a function decorated with `@Constructor`, otherwise an application project using this framework fails at compile time.
The attribute of this macro has the following four parts
```cj
@Value[name: 'confItemKey', //name is the KEY of the configuration item; if the configuration item satisfies the Cangjie identifier rules, a string may also be used
           default: <defaultValue>,//default is the value used when the configuration does not exist
           dateFormat: 'yyyy-MM-dd',//dateFormat is the format used to parse the time string into a DateTime when the parameter type is DateTime
           delim: ','//delim is the delimiter used when the value of the configuration item has to be split into several values
           ]paramName: ParamType
```

#### `@Configuration`
All public member functions decorated with the `@BeanInit` annotation in a class decorated with `@Configuration` are bean initialization functions, including static and instance functions.
However a class decorated with `@Configuration` is not managed by the IOC framework

##### `@BeanInit`
```cj
@Annotation[target: [MemberFunction]]
public class BeanInit{
    public init(){}
}
```

---

## Other public API

The declarations below are not expanded above; they are grouped by module level and by type (members declared in `extend` blocks are listed under the extended type). See the corresponding files under `src/` for the full semantics.

- Module level: `AndCond` (class), `BeanDef` (class), `BeanDefCount` (enum), `BeanDefType` (enum), `BeanException` (class), `BeanInitializer` (struct), `BeanManager` (class), `BeanScope` (class), `ConfCond` (enum), `Destroy` (interface), `FactoryBean` (interface), `NoneBeanCondition` (class), `NotCond` (class), `OrCond` (class), `PostConstruct` (interface), `PrototypeBeanScope` (class), `SingletonBeanScope` (class), `public func lookupLabel<L, T>(label: L): T where L <: Hashable & Equatable<L>, T <: BeanLabel<L>`, `public func lookupLabelOption<L, T>(label: L): ?T where L <: Hashable & Equatable<L>, T <: BeanLabel<L>`, `public func lookupOptionLable<L, T>(name: String, label: L): ?T where L <: Hashable & Equatable<L>, T <: BeanLabel<L>`, `setShouldInitBean` (func)
- `BeanDef`: `let beanName!: StringCond = IgnoreCond`, `let count!: BeanDefCount = AtLeastOne`
- `BeanFactory`: `func afterRegistered()`, `func get<T>(name: String): ?T`, `func register<T>(creator: () -> T): Unit where T <: Object`, `func registerByInstanceFunction<T>(fnName: String, creator: () -> T): Unit where T <: Object`, `func registerByStaticFunction<T>(fnName: String, creator: () -> T): Unit where T <: Object`
- `BeanInitializer`: `func initialize(): Unit`
- `BeanManager`: `func compare(manager: BeanManager)`, `let index = serialGen.fetchAdd(1)`, `let meta: BeanMeta`
- `BeanMeta`: `compare` (func)
- `BeanScope`: `prop isPrototype: Bool`, `prop isSingleton: Bool`, `typeInfo` (prop)
- `PrototypeBeanScope`: `prop typeInfo: TypeInfo`
- `SingletonBeanScope`: `prop typeInfo: TypeInfo`
