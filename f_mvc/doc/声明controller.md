## 声明controller
```cj
import fountain::f_mvc.*
import fountain::f_mvc.macros.*

//@Controller宏除了将controller公共实例函数函数注册到mvc，还会执行IOC @Bean宏展开，同时支持属性宏和非属性宏。
//@Controller属性宏的属性可以作为@Bean宏的属性
//如果需要为controller函数织入切面，可以使用@WeavedController修饰controller类
//@WeavedController除了拥有@Controller的完整功能，还会执行切点宏@Pointcut展开，织入规则由切面开发者自己定义
@Controller
public class HelloworldController {
    //只有被Mapping结尾的注解修饰的公共实例函数才会注册到MVC
    //path 是http请求路径
    //produces 是响应体格式
    //consumes 是请求体格式
    @GetMapping[path:"/helloworld", produces:'text/plain', consumes:'application/x-www-form-urlencoded']
    public func helloworld(): String {
        return "helloworld"
    }
}
```

### controller函数注解
此类注解名称都是Mapping结尾，并且都有一样的初始化参数，初始化参数定义如下：
- path 请求路径，支持{}包含的路径参数，比如/api/user/{id}这个路径就定义了一个名为id的路径参数
- produces 响应体格式，可以用|分割多个响应体格式，默认是application/json
- consumes 请求体格式，可以用|分割多个请求体格式，默认是application/json
- params 表单参数符合本参数指定的规则可用本函数处理相应的http访问
- headers 请求头符合本参数指定的规则可用本函数处理相应的http访问

#### params和headers的规则定义
- rule1 & rule2 左右两个规则需要都满足，整个规则才满足
- rule1 | rule2 左右两个规则满足一个，整个规则就能满足
- !rule 对右面的规则取反
- (rules) 将规则包含起来，通常用它改变& | ! 规则的计算顺序
- contains('a', 'b', 'c',...) 表示表单参数或请求头名称需要包含括号内指定的参数名或请求头名
- subset('a', 'b', 'c',...)表示表单参数或请求头名是括号内指定字符串的子集
- eg. 对于表单参数，a.contains('1', '2') & (b.subset('s', 'd') | 'orderTime' | goodsId) 这个规则表示当前访问的表单参数a的值需要同时包含'1'和'2'，而且要么表单参数b的值必须是('s', 'd')的子集，要么表单参数包含参数名orderTime，要么包含表单参数名goodsId
- eg. 对于请求头也适用一样的规则 

#### Mapping的声明
只能修饰controller类的公共实例函数，修饰其它函数无效
- `@GetMapping` 请求方法GET
- `@PostMapping` 请求方法POST
- `@PutMapping` 请求方法PUT
- `@DeleteMapping` 请求方法DELETE
- `@PatchMapping` 请求方法PATCH
