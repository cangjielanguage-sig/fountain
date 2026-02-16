# IOC
`fountain::f_bean`是一个IOC框架。
- 可能用bean的名称获取bean
- 使用bean的类型和bean的全部有继承关系的类型，以及bean实现的接口获取bean
- 使用修饰bean的类型的注解，以及父类型的注解获取bean
---
```cj
import fountain::f_bean.*
import fountain::f_bean.macros.*

//IOC 功能只能管理类的实例，相关的宏和注解只能修饰类或类的成员
@Bean
@BeanMeta[//这些都是@BeanMeta的默认值，当都是默认值，可以不必使用@BeanMeta修饰受IOC管理的类
          name: '', //bean的名字，默认是类型全限定名后面加bean的序号
          scope: BeanScope.singleton, //BeanScope有两个值，singleton和prototype，singleton是单例bean，全进程生命周期只有一个单例，prototype表示每次获取这个bean都是新实例
          lazy: true,//对于singleton的bean，lazy是true表示首次尝试获取bean的时候才初始化，false是bean注册到IOC即完成初始化；对于prototype的bean，lazy不生效
          primary: false,//primary是true的排在同类型bean的最前面，然后再按照order的顺序排序
          order: 0,//order表示同类型bean的排序顺序
          condition: NoneBeanCondition.instance//bean初始化条件，只有满足指定条件的bean才会实例化，不满足的会从IOC移除，更详细的内容后面会详细解释
          ]//@BeanMeta必须跟@Bean搭配使用，单独使用无效
public class ClassName{}

/*
 * @Bean的属性是被它修饰的泛型类的泛型实参，可以用|分隔表示多组泛型实参类型
 * 下面的代码表示被修饰的类实例化GenericClass<String, Duration>和GenericClass<Int64, String>
 */
@Bean[String, Duration|Int64, String]
public class GenericClass<T, E>{
    private let bean = lookup<ClassName>()//lookup函数会查找被IOC 管理的BEAN，并返回找到的第一个bean
}

```

## lookup函数
IOC框架有一系列名字lookup开头的函数，用来获取受管理的bean。
首先导入包`fountain::f_bean.*`
```cj
import fountain::f_bean.*
```

### 获取单个bean
#### `lookup<T>(): T`
获取第一个指定泛型实参的bean，如果没找到会抛出异常

#### `lookup<T>(name: String): T`
获取指定类型且名称是name的bean，如果没找到会抛出异常

#### `lookup<T>(cond: StringCond): T`
获取指定类型且名称符合cond指定条件的第一个bean，如果没找到会抛出异常

### 获取bean类型的Option
#### `lookupOption<T>(): ?T`
获取第一个指定泛型实参的bean，如果没找到返回`None<T>`

#### `lookupOption<T>(name: String): ?T`
获取指定类型且名称是name的bean，如果没找到返回`None<T>`

#### `lookupOption<T>(cond: StringCond): ?T`
获取指定类型且名称符合cond指定条件的第一个bean，如果没找到会抛出异常

### 获取bean的`ArrayList<T>`
#### `lookupList<T>(): ArrayList<T>`
获取类型是指定泛型实参的所有bean

#### `lookupList<T>(cond: StringCond): ArrayList<T>`
获取类型是指定泛型实参且名称符合指定条件的全部bean

### 获取bean的`HashSet<T>`
#### `lookupHashSet<T>(): HashSet<T> where T <: Hashable & Equatable<T>`
获取类型是指定泛型实参的全部bean

#### `lookupHashSet<T>(cond: StringCond): HashSet<T> where T <: Hashable & Equatable<T>`
获取类型是指定泛型实参且名称符合指定条件的全部bean

### 获取bean的`TreeSet<T>`
#### `lookupTreeSet<T>(): HashSet<T> where T <: Comparable<T>`
获取类型是指定泛型实参的全部bean

#### `lookupTreeSet<T>(cond: StringCond): HashSet<T> where T <: Comparable<T>`
获取类型是指定泛型实参且名称符合指定条件的全部bean

### 获取bean的HashMap`<String, T>`
#### `lookupHashMap<T>(): HashMap<String, T>`
获取类型是指定泛型实参的全部bean，返回的HashMap用bean的名称作为KEY

#### `lookupHashMap<T>(cond: StringCond): HashMap<String, T>`
获取类型是指定泛型实参且名称符合cond条件的全部bean，返回的HashMap用bean的名称作为KEY

### 获取bean的`HashMap<L, T>`
#### `lookupLables<L, T>(): HashMap<L, T> where L <: Hashable & Equatable<L>, T <: BeanLabel<L>`
获取类型是指定泛型实参的全部bean，泛型实参需要实现接口`BeanLabel<L>`。

#### `lookupLables<L, T>(cond: StringCond): HashMap<L, T> where L <: Hashable & Equatable<L>, T <: BeanLabel<L>`
获取类型是指定泛型实参且名称符合cond条件的全部bean。

#### `BeanLabel<L>`
```cj
public interface BeanLabel<L> where L <: Hashable & Equatable<L> {
    prop label: L
}
```

### 获取带权重的bean `TreeMap<W, T>`
#### `lookupWeights<W, T>(): TreeMap<W, T> where W <: ComparableW> & Addable<W>, T <: BeanWeight<W>`
获取类型是指定泛型实参的全部bean，泛型实参需要实现接口`BeanWeight<W>`

#### `lookupWeights<W, T>(cond: StringCond): TreeMap<W, T> where W <: Comparable<W> & Addable<W>, T <: BeanWeight<W>`
获取类型是指定泛型实参的全部bean, 泛型实参需要实现接口`BeanWeight<W>`

#### `BeanWeight<W>`
```cj
public interface BeanWeight<W> where W <: Comparable<W> & Addable<W> {
    prop weight: W
}
```

### StringCond
```cj
/**
 * 字符串满足指定条件返回true
 */
public enum StringCond <: Equatable<StringCond> & Equatable<String> & ToString {
    /**
     * 忽略本条件
     */
    | IgnoreCond
    /**
     * 传入on的字符串等于指定字符串
     */
    | Exactly(String)
    /**
     * 传入on的字符串以指定字符串开头
     */
    | Prefix(String)
    /**
     * 传入on的字符串以指定字符串结尾
     */
    | Suffix(String)
    /**
     * 传入on的字符串符合通配规则
     */
    | Wildcard(String)
    /**
     * 传入on的字符串符合指定正则表达式
     */
    | Regexp(String)
    /**
     * 构造器参数是传入on的字符串的子串
     */
    | Contains(String)
    /**
     * 传入on的字符串是构造器参数的子串
     */
    | In(String)

    public func toString(): String
    /**
     * 检查参数是否符合当前枚举值表示的匹配规则
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
 * bean初始化条件，满足条件的bean才初始化，否则将被从BeanFactory删除
 * 可以使用& | !操作符组合多个BeanCondition
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
 * 默认的bean初始化条件，初始化BeanMeta时的占位。永远返回true。
 */
public class NoneBeanCondition <: BeanCondition
```

#### AndCond
```cj
/**
 * 两个bean初始化条件都是true时本条件才是true。
 */
public class AndCond <: BeanCondition
```

#### OrCond
```cj
/**
 * 两个bean初始化条件有一个是true本条件就是true，首先执行left。
 */
public class OrCond <: BeanCondition
```

#### NotCond
```cj
/**
 * 将指定初始化条件取反
 */
public class NotCond <: BeanCondition
```

#### ConfCond
```cj
/**
 * 配置项满足条件时on返回true
 */
public enum ConfCond <: BeanCondition {
    /**
     * 忽略配置条件
     */
    | IgnoreConf
    /**
     * 存在配置项时返回true
     */
    | Exists(String)
    /**
     * 不存在配置项时返回true
     */
    | NotExists(String)
    /**
     * 存在配置项且配置项的值满足StringCond，如果StringCond.IgnoreCond相当于Exists(String)
     */
    | Value(String, StringCond)
    /**
     * 执行本条件的函数
     */
    public func on(_: BeanFactory): Bool
    public func toString(): String
}
```

#### BeanBef
```cj
/**
 * beanType是全限定类型名，指定类型有bean定义则on返回true
 */
public class BeanDef <: BeanCondition {
    /**
     * 当其它已注册的bean满足全部这些条件，用BeanType作为初始化条件的bean将会初始化
     * @param beanType 存在注册的bean类型满足指定条件
     * @param beanName 存在注册的bean名称满足指定条件
     * @param scope 存在注册的bean的BeanScope满足指定的BeanScope，如果本参数是None，表示任意BeanScope都满足
     * @param count 当满足其它三个条件的bean的数量满足本参数指定的条件时则当前BeanDef被判定为true
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
 * 以bean的类型作为条件，本枚举构造器实参是相应类型的全限定名
 */
public enum BeanDefType <: ToString {
    /**
     * 不判断bean类型，任意类型都是true
     */
    | IgnoreType
    /**
     * bean定义的类型必须是指定类型
     */
    | Current(String)
    /**
     * bean定义的类型是指定类型或指定类型的后代类型
     */
    | CurrentOrSubOf(String)
    /**
     * bean定义的类型必须是指定类型的后代类型
     */
    | SubOfOnly(String)
    /**
     * bean定义的类型必须是指定类型或指定类型的祖先类型
     */
    | CurrentOrSuperOf(String)
    /**
     * bean定义的类型必须是指定类型的祖先类型
     */
    | SuperOfOnly(String)
    public func toString(): String
    public func on(beanType: TypeInfo): Bool
}
```

##### BeanDefCount
```cj
/**
 * bean定义有指定数量时为true
 */
public enum BeanDefCount <: ToString {
    /**
     * 没有bean定义
     */
    | Zero
    /**
     * 只有一个bean定义
     */
    | OnlyOne
    /**
     * 至少有一个bean定义
     */
    | AtLeastOne
    /**
     * 多于一个bean定义
     */
    | MoreThanOne

    public func toString(): String
}
```

### FactoryBean
```cj
/**
 * 当被@Bean修饰的类实现了FactoryBean接口，表示调用本接口的get函数返回的对象才是真正的bean，本接口的实现类是这个bean的工厂
 */
public interface FactoryBean {
    /**
     * bean的类型
     */
    static prop typeInfo: TypeInfo
    /**
     * 本函数返回的是bean
     */
    func get(): Object
}
```

### Destroy
被`@Bean`修饰的类如果实现了本接口表示bean不再使用时需要调用`destroy()`函数释放资源或销毁数据。
BeanScope是prototype的bean，需要开发者主动调用，singleton bean由IOC框架调用。
```cj
public interface Destroy {
    func destroy(): Unit
}
```

### PostConstructor
被`@Bean`修饰的类如果实现了本接口表示bean实例化后，IOC框架需要调用`postConstruct()`完成最后的初始化。
```cj
public interface PostConstruct {
    func postConstruct(): Unit
}
```

### 宏
#### `@Bean`
IOC框架的基础API，所有受IOC管理的bean的类都需要由`@Bean`修饰。
如果bean使用无参构造函数初始化，可以不必使用后面提到的`@Constructor`

##### `@Constructor`
`@Constructor`修饰的构造函数或静态函数是bean的初始化函数。
它只能修饰`@Bean`修饰的类的构造函数或静态函数，否则使用本框架的应用项目会在编译期报错。

###### `@BeanParam(attr: Tokens, input: Tokens): Tokens`
`@BeanParam`只能修饰被`@Constructor`修饰的函数形参，否则使用本框架的应用项目会在编译期报错。
本宏的属性是表示StringCond枚举实例的Tokens。宏完全展开以后，bean名称满足attr所表示的条件的bean将作为对应的实参。

###### `@Value(attr: Tokens, input: Tokens): Tokens`
`@Value`只能修饰被`@Constructor`修饰的函数形参，否则使用本框架的应用项目会在编译期报错。
本宏的属性包含以下四部分
```cj
@Value[name: 'confItemKey', //name是配置项的KEY，如果配置项满足仓颉标识符规则，也可以使用字符串
           default: <defaultValue>,//default是配置不存在时使用的默认值
           dateFormat: 'yyyy-MM-dd',//dateFormat是参数类型是DateTime时需要将时间字符串解析为DateTime的格式
           delim: ','//delim是需要将配置项的值分割为多个值时使用的分割符
           ]paramName: ParamType
```

#### `@Configuration`
`@Configuration`修饰的类的所有被`@BeanInit`注解修饰的公共成员函数都是bean初始化函数，包括静态函数和实例函数。
但是`@Configuration`修饰的类不会被IOC框架管理

##### `@BeanInit`
```cj
@Annotation[target: [MemberFunction]]
public class BeanInit{
    public init(){}
}
```
