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
