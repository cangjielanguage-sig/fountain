- 数据对象的公共成员变量和公共成员属性的复制
- 可以随时获取指定名称的公共成员的值
- 可以随时为指定名称的公共成员赋值
- 可以在不同的类实例之间互相复制
- 可以为任意类的实例和JSON之间互相复制

## `@DataAssist` 属性
- equal 为被修饰的类实现Equatable接口
- hash 为被修饰的类实现Hashable接口
- tostring 为被修饰的类实现ToString接口
- props 把被修饰的类的非公共实例成员变量添加公共实例成员属性
  ```cj
  //假设存在类
  @DataAssist[props]
  public class A {
      private var a: String = ''
      private let b: Int64 = 0
  }
  //上面的宏展开结果为
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
- fields 为被修饰的类实现实例间和类实例与JSON之间的互相复制

```cj
import fountain.f_data.*
/**这一行往下单纯只是为了演示实例复制和类实例与json互相转换的功能*******************/
//@DataAssist[fields]宏修饰的类即可做到以上这些
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
//下面的populate、tryFromData、toJson fromJson等函数调用能够执行是因为它们都被@DataAssist[props fields] 修饰
private let _ = {=>
    try{
        var data2 = TestData2()
        var data3 = DataObject<TestData3>.populate(data2).getOrThrow()
        //忽略验证：
        // data3 = DataObject<TestData3>.populate(data2, flag: DEFAULT_DATA_FLAG | IGNORE_VALIDATION).getOrThrow()
        //忽略验证失败：
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
        let s = toJson(data2)//把仓颉对象转成JSON串
        let d = fromJson<TestData2>(s)//把JSON串转成仓颉类对象
        println('GGGGGGGGGGGGGGGGGGGGGGGGGGGGG ${s}')
        println('HHHHHHHHHHHHHHHHHHHHHHHHHHHHH ${d.toData()}')
    }catch(e: Exception){
        e.printStackTrace()
        throw e
    }
}()
```

## 数据验证
```cj
package fountain::f_data.validation
public abstract class Validator {
    /**messageIfNotMatch是数据不符合时返回的消息*/
    public const Validator(public let messageIfNotMatch!: String = '') {}
    /**验证数据是否符合规则*/
    public func validate(value: ?String): Bool
    /**两个Validator 都满足才返回true*/
    public const operator func &(right: Validator): Validator 
    /**两个Validator 任意一个满足就返回true*/
    public const operator func |(right: Validator): Validator 
    /**Validator 不满足时返回true*/
    public const operator func !(): Validator
    /**
     * 对当前验证器的行为描述
     */
    public prop description: String
}
/**
 * messageIfNotMatch是数据不符合时返回的消息
 * 将多个& | ! 组合起来的验证器作为此验证器的初始化参数
 */
@Annotation[target: [MemberVariable, MemberProperty, Parameter]]
public class CombinedValidator <: Validator {
    public const CombinedValidator(messageIfNotMatch: String, public let validator: Validator)
}
```

### 以下注解都是`fountain::f_data.validation.Validator`的子类
#### @IsNotEmpty 
数据必须非空

#### @IsNotBlank
数据必须非空且不能是空白字符

#### @StringSize
```cj
/**
 * messageIfNotMatch是数据不符合时返回的消息
 * min 字符串长度最小值
 * max 字符串长度最大值
 */
@StringSize[messageIfNotMatch: 'not match message', min: 0, max: 10]
```

#### @IsInteger
数据必须是整数

#### @IsDecimal
数据必须是实数，包括整数和小数

#### @IsEmail
数据必须是电邮

#### IsChineseCellPhone
数据必须是中国手机号

#### IsIntegerRange
```cj
/**
 * 验证数据是否是整数且在指定范围
 * min: 整数最小值
 * max: 整数最大值
 * minInclusive: 数据是否可以是最小值
 * maxInclusive: 数据是否可以是最大值
 */
@IsIntegerRange[messageIfNotMatch: 'not match message', 
                min: 0, max: 1000, minInclusive: true, maxInclusive: false]
```

#### @IsBool
数据必须是true或false

#### IsDateTime
```cj
/**
 * format 数据必须满足指定格式
 */
@IsDateTime[messageIfNotMatch: 'not match message', format: 'yyyy-MM-dd HH:mm:ss']
```

#### IsDuration
数据必须是Duration字符串

#### IsIntegers
```cj
/**
 * seperator 数据的分割符，用seperator分割数据且分割每一部分都必须是整数
 */
@IsIntegers[messageIfNotMatch: 'not match message', separator: ',']
```

#### @DoesMatchRegex
```cj
/**
 * regex 数据必须符合指定的正则表达式
 */
@DoesMatchRegex[messageIfNotMatch: 'not match message', regex: '<REGEXP>']
```

## 数据转换
有些情况无法完成默认转换，比较把字符串格式的时间转成`std.time.DateTime`类型。
```cj
/**
 * T是转换的目标类型
 */
public abstract class DataConverter<T> {
    public const init(){}
    /**
     * @param data 待转换的数据
     */
    public func convert(data: Data, flag!: DataConversionFlag): ?T 
}
public class DateTimeConverter <: DataConverter<DateTime> {
    /**
     * @param format 把convert函数的data按照这个格式转成DateTime
     */
    public const DateTimeConverter(private let format: String){}
    /**
     * 把data转成字符串，再把字符串串按照format转成DateTime
     */
    public func convert(data: Data, flag!: DataConversionFlag = DEFAULT_DATA_FLAG): ?DateTime 
}

``