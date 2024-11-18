```
  _____                    __         .__
_/ ____\____  __ __  _____/  |______  |__| ____
\   __\/  _ \|  |  \/    \   __\__  \ |  |/    \
 |  | (  <_> )  |  /   |  \  |  / __ \|  |   |  \
 |__|  \____/|____/|___|  /__| (____  /__|___|  /
                        \/          \/        \/
```

# fountain

## 介绍
一个用于服务器应用开发的综合工具库。
- 零配置文件
- 环境变量和命令行参数配置
- 约定优于配置
- 深刻利用仓颉语言特性
- 只需要开发动态链接库，fboot负责加载、初始化并运行。

### 版本管理
待功能完备后将按以下流程跟随仓颉版本，功能完备以前一直跟随最新的开发版。
- 每月仓颉开发版对应一个`dev/${DEV_CANGJIE_VERSION}`
- 每次发仓颉beta版，将对应的开发版转为`beta/${BETA_CANGJIE_VERSION}`，删除对应的开发版
- 功能完备后的长期支持版作为master分支
  - 此后master分支跟随最新的长期支持版
  - 每次仓颉升级LTS
    - 从对应的beta版建分支`lts/${LTS_CANGJIE_VERSION}`
    - 删除对应beta版
    - lts版本完成测试合并到master，创建版本`release-${main}.${sub}.${bug}.${CANGJIE_VERSION}`
      - main：有新功能
      - sub：功能变更
      - bug：修改BUG
      - CANGJIE_VERSION：取当前仓颉长期支持版前两位，比如当前仓颉长期支持版是1.0.x，CANGJIE_VERSION就是1_0。


### 加载本项目的动态链接库
- 如果仅仅是开发使用，可以使用cjpm run当前依赖fountain的项目，就自动加载了。
- 如果是在Linux服务器环境运行，
  - 将fountain动态链接库所在的路径加入环境变量`export fountainPath=/path/of/fountain_dynamic_libs`。
  - 最好将本项目编译的动态链接库都加入环境变量`export LD_LIBRARY_PATH=$fountainPath:$LD_LIBRARY_PATH`。

### fboot
- 把fboot加入PATH环境变量
  1. fboot build：执行`cjpm build`构建当前目录，加载编译得到的动态链接库，把@Pointcut插入正确的函数。如果当前目录没有cjpm.toml，会抛出异常。
  2. fboot build -p /path/of/project：把工作目录切换到指定路径，然后执行跟上一条一样的工作。
  3. fboot run：
     - 首先加载环境变量$fountainPath。
     - 按字符顺序加载当前目录的动态链接库，加载完成当前目录的动态链接库再按照字符顺序加载子目录里的动态链接库，直到递归加载完当前目录和它的子目录里的全部动态链接库。
     - 然后并执行`f_app.App`，完成应用初始化。f_app.App实现了f_launcher.Launcher。
     - 如果找不到f_app.App，就执行找到的第一个`f_launcher.Launcher`实现。
     - 如果找不到就执行第一个找到的顶级声明函数`public func launch(args: Array<String>): Unit`。
     - 如果找不到就执行第一个找到的顶级声明函数`public func launch(): Unit`。
     - 如果找不到就只加载动态链接库，需要确保动态链接库初始化时就能够完成程序引导。
  4. fboot run -p /path/of/dylibs：把工作目录切换到指定路径，然后执行第三条。
  5. fboot run package_name.LauncherImpl，类型需要实现f_launcher.Launcher接口。加载当前目录的动态链接库并调用指定类型名完成初始化。
  6. fboot run package_name.LauncherImpl -p /path/of/dylibs：把工作目录切换到指定路径，然后执行第五条。

### 功能
- 空集合
- 比较器Comparator Equaler

- UUID
- 常用设计模式
  - 工厂模式
  - 策略模式
  - 发布订阅模式
  - 观察者模式
- 路径匹配PathPattern
- TreeTransformer
- crc16
- murmur_hash
- DiffieHellman密钥交换协议
- CaseFormat 命名风格的字符串转换
- 文本模板，插值串在编译期就确定了，有时候需要运行期才能确定的文本模板
- 各种常用异常
- 标准库的扩展
  - 针对Iterator的扩展
- 对象池
- 堆缓存
- 正则表达式DSL
- 简化属性复制的工具
- 优先级队列
- 标准库未提供的集合
- 支持大端序小端序的字节数组扩展（可以把各种数值类型按指定端序从字节数组读写）
- 功能更丰富的JSON
- CRON定时器
- ORM
- IOC
- AOP
- MVC
- 网络流水线
- 权限控制
- 负载均衡策略 
  - 随机
  - 优先级
  - 轮转法
- id生成器
  - 雪花算法改
- 配置类型
- jwt
- 日志
- 流程引擎
- 功能更丰富的json
- 并发
  - 限流策略
    - 滑动时间窗口
    - 令牌桶
    - 漏桶
    - 任意时刻最大并发数
  - 布隆过滤器
  - ConcurrentHashSet
  - SyncPriorityQueue
  - 原子类型扩展
- 集合
  - LinkedHashMap
  - 判定值是否存在的Map扩展
  - TreeSet
  - PriorityQueue
- TextTemplate
- 随机数
  - 随机字符串
  - 范围随机数