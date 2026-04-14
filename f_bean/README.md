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

- [lookup函数](doc/lookup函数.md)

