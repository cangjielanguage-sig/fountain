# fountain实现思想与应用第四弹

##### ——orm

项目链接：https://gitcode.com/Cangjie-SIG/fountain

这是ORM的类图

![ORM](.assets/fountain%E5%AE%9E%E7%8E%B0%E6%80%9D%E6%83%B3%E4%B8%8E%E5%BA%94%E7%94%A8%E7%AC%AC04%E5%BC%B9%E2%80%94%E2%80%94ORM/ORM.jpg)

ORM的核心是SqlExecutor，所有增删改查、填充SQL参数都是这个类的API，而且各种高阶API也是它的扩展，数据库访问的接口也通过@DAO宏扩展到SqlExecutor。

SqlArgs是SqlExecutor是SQL参数集合按照调用添加参数的函数顺序添加到SqlArgs实例，每一个参数都被包装成SqlArg实例，访问数据库时遍历SqlArgs将参数添加到Statement。

类图中的RootDAO依赖的`Condition`结尾的类是SQL条件函数，MeetCondition执行每一个符合的条件、ChooseCondition执行第一个符合的条件，LoopCondition遍历Iterable实例。

SqlHead依赖的Clause类是SQL API的辅助工具，可以帮助开发者构造SQL。比如可以有以下API调用：

```cj
executor.From<MapperClass>().page<MapperClass>(10/*每页记录数*/, page: 1/*查询的页数*/)
```

分页查询时按照不同数据库的方言构造相应的分页查询SQL，构造的SQL会作为计数和分页查询的SQL子查询，避免有些查询SQL包含不能跟分页子句同时出现的SQL子句。比如postgres的计数SQL不能跟排序子句同时出现。

类图下面的QueryMappers和QueryMapper及它的子类是映射类型。每个映射类的成员被包装为QueryMapper实例，而QueryMappers是QueryMapper的集合。