![LICENSE](https://img.shields.io/badge/License-ApacheV2.0-orange.svg?style=flat-square&logo=opensourceinitiative&logoSize=14)
![stars](https://gitcode.com/Cangjie-SIG/fountain/star/badge.svg?style=flat-square&logoSize=14)
![star](https://gitcode.com/Cangjie-SIG/fountain/star/2025top.svg)
```
  _____                    __         .__
_/ ____\____  __ __  _____/  |______  |__| ____
\   __\/  _ \|  |  \/    \   __\__  \ |  |/    \
 |  | (  <_> )  |  /   |  \  |  / __ \|  |   |  \
 |__|  \____/|____/|___|  /__| (____  /__|___|  /
                        \/          \/        \/
```

![fountain](.assets/README/fountain.jpg)

# fountain

## 介绍

## Stargazers over time
![Stargazers over time](https://gitcode.com/Cangjie-SIG/fountain/starcharts.svg?variant=adaptive)

## STDX依赖
配置环境变量：`export CANGJIE_STDX_DYNAMIC_PATH=/path/to/dynamic_stdx`

### `fountain::fboot`
依赖fountain的应用项目启动程序，应用项目只需要编译为动态链接库，fboot会调用`fountain::f_app`完成应用启动。

**详情请见：**<https://pkg.cangjie-lang.cn/package/fountain::fboot/1.3.0/readme>

#### 安装
```bash
cjpm install "fountain::fboot"="a.b.c" --root /path/to/install # 把a.b.c换成具体的版本号
export PATH=$PATH:/path/to/install/bin
export LD_LIBRARY_PATH=$LD_LIBRARY_PATH:/path/to/install/libs/fboot
```
#### 启动
```bash
fboot run --dylibPattern=<REGEX_OF_PROJECT_DYLIB_FILENAMES> # 具体查看项目的fdemo模块的boot.sh脚本
```
#### 创建项目与添加依赖
安装`fboot`之后，可以执行`fboot workspace`将当前目录初始化为仓颉workspace项目，详细见`fboot`文档。
项目需要的任何模块都在项目根目录的cjpm.toml添加。以`f_base`为例：
```toml
[dependencies]
"fountain::f_base" = "a.b.c" # 把a.b.c换成具体的版本号
```

## 各模块详细文档
### `fountain::f_app`
应用进程管理模块，可以用本模块加载使用fountain开发的应用项目动态链接库。
也可以使用`fountain::fountain.app`包使用本模块的同名API。

**详情请见：**<https://pkg.cangjie-lang.cn/package/fountain::f_app/1.3.0/readme>

### `fountain::f_aspect`
AOP
也可以使用`fountain::fountain.aspect`包使用本模块的同名API。

**详情请见：**<https://pkg.cangjie-lang.cn/package/fountain::f_aspect/1.3.0/readme>

### `fountain::f_base`
一些Iterator扩展，enum OS, 不需要使用unsafe就能获得字符串原始字节数组的字符串扩展, 不需要使用unsafe就能得到ArrayList原始数组的ArrayList扩展, extend Option, extend Array, extend Range, extend Number, extend String, extend ThreadLocal, HashBuilder, StringGenerator，etc.
也可以使用`fountain::fountain.base`包使用本模块的同名API。

**详情请见：**<https://pkg.cangjie-lang.cn/package/fountain::f_base/1.3.0/readme>

### `fountain::f_bean`
IOC
也可以使用`fountain::fountain.base`包使用本模块的同名API。

**详情请见：**<https://pkg.cangjie-lang.cn/package/fountain::f_bean/1.3.0/readme>

### `fountain::f_cache`
堆缓存
也可以使用`fountain::fountain.cache`包使用本模块的同名API。

**详情请见：**<https://pkg.cangjie-lang.cn/package/fountain::f_cache/1.3.0/readme>

### `fountain::f_cmd`
命令行工具
也可以使用`fountain::fountain.cmd`包使用本模块的同名API。

**详情请见：**<https://pkg.cangjie-lang.cn/package/fountain::f_cmd/1.3.0/readme>

### `fountain::f_codec`
编解码器

**详情请见：**<https://pkg.cangjie-lang.cn/package/fountain::f_codec/1.3.0/readme>

### `fountain::f_collection`
标准库尚不支持的集合以及一些标准库集合扩展
也可以使用`fountain::fountain.collection`包使用本模块的同名API。

**详情请见：**<https://pkg.cangjie-lang.cn/package/fountain::f_collection/1.3.0/readme>

### `fountain::f_concurrent`
负载均衡、限流算法、标准库尚不支持的并发集合和标准库并发集合扩展
也可以使用`fountain::fountain.concurrent`包使用本模块的同名API。

**详情请见：**<https://pkg.cangjie-lang.cn/package/fountain::f_concurrent/1.3.0/readme>

### `fountain::f_config`
配置模块
也可以使用`fountain::fountain.config`包使用本模块的同名API。

**详情请见：**<https://pkg.cangjie-lang.cn/package/fountain::f_config/1.3.0/readme>

### `fountain::f_crypto`
加密模块
也可以使用`fountain::fountain.crypto`包使用本模块的同名API。

**详情请见：**<https://pkg.cangjie-lang.cn/package/fountain::f_crypto/1.3.0/readme>

### `fountain::f_data`
数据复制模块，可以实现任意类实例之间同名公共成员变量、公共成员属性之间的复制。
可以随时得到指定名称的公共成员变量或属性的的值。
有各种数据验证注解，这些注解可以修饰公共成员变量或属性，也可以修饰函数参数，实现了复制时数据验证，MVC传参时也可以验证controller函数实参。
也可以使用`fountain::fountain.data`包使用本模块的同名API。

**详情请见：**<https://pkg.cangjie-lang.cn/package/fountain::f_data/1.3.0/readme>

### `fountain::f_exception`
异常模块
也可以使用`fountain::fountain.exception`包使用本模块的同名API。

**详情请见：**<https://pkg.cangjie-lang.cn/package/fountain::f_exception/1.3.0/readme>

### `fountain::f_http`
HTTP，目前实现了HTTP数据格式MediaType的定义和json、multipart/form-data的实现。
也可以使用`fountain::fountain.http`包使用本模块的同名API。

**详情请见：**<https://pkg.cangjie-lang.cn/package/fountain::f_http/1.3.0/readme>

### `fountain::f_httpclient`
HTTP客户端
也可以使用`fountain::fountain.httpclient`包使用本模块的同名API。

**详情请见：**<https://pkg.cangjie-lang.cn/package/fountain::f_httpclient/1.3.0/readme>

### `fountain::f_io`
IO
也可以使用`fountain::fountain.io`包使用本模块的同名API。

**详情请见：**<https://pkg.cangjie-lang.cn/package/fountain::f_io/1.3.0/readme>

### `fountain::f_jwt`
JWT
也可以使用`fountain::fountain.jwt`包使用本模块的同名API。

**详情请见：**<https://pkg.cangjie-lang.cn/package/fountain::f_jwt/1.3.0/readme>

### `fountain::f_log`
日志
也可以使用`fountain::fountain.log`包使用本模块的同名API。

**详情请见：**<https://pkg.cangjie-lang.cn/package/fountain::f_log/1.3.0/readme>

### `fountain::f_macros`
宏工具API
也可以使用`fountain::fountain.macros`包使用本模块的同名API。

**详情请见：**<https://pkg.cangjie-lang.cn/package/fountain::f_macros/1.3.0/readme>

### `fountain::f_mockdb`
mock database
也可以使用`fountain::fountain.mockdb`包使用本模块的同名API。

**详情请见：**<https://pkg.cangjie-lang.cn/package/fountain::f_mockdb/1.3.0/readme>

### `fountain::f_mvc`
MVC
也可以使用`fountain::fountain.mvc`包使用本模块的同名API。

**详情请见：**<https://pkg.cangjie-lang.cn/package/fountain::f_mvc/1.3.0/readme>

### `fountain::f_net`
事件驱动的网络通讯模块
也可以使用`fountain::fountain.net`包使用本模块的同名API。

**详情请见：**<https://pkg.cangjie-lang.cn/package/fountain::f_net/1.3.0/readme>

### `fountain::f_orm`
ORM
也可以使用`fountain::fountain.orm`包使用本模块的同名API。

**详情请见：**<https://pkg.cangjie-lang.cn/package/fountain::f_orm/1.3.0/readme>

### `fountain::f_pool`
一个池的实现，提供了对象池、数组池、ArrayList池
也可以使用`fountain::fountain.pool`包使用本模块的同名API。

**详情请见：**<https://pkg.cangjie-lang.cn/package/fountain::f_pool/1.3.0/readme>

### `fountain::f_process`
进展扩展模块
也可以使用`fountain::fountain.process`包使用本模块的同名API。

**详情请见：**<https://pkg.cangjie-lang.cn/package/fountain::f_process/1.3.0/readme>

### `fountain::f_protocol`
一个网络通讯协议实现

**详情请见：**<https://pkg.cangjie-lang.cn/package/fountain::f_protocol/1.3.0/readme>

### `fountain::f_random`
随机数扩展, ThreadLocalRandom, 蓄水池算法, 随机字符串
也可以使用`fountain::fountain.random`包使用本模块的同名API。

**详情请见：**<https://pkg.cangjie-lang.cn/package/fountain::f_random/1.3.0/readme>

### `fountain::f_regex`
正则表达式扩展、正则缓存、正则DSL
也可以使用`fountain::fountain.regex`包使用本模块的同名API。

**详情请见：**<https://pkg.cangjie-lang.cn/package/fountain::f_regex/1.3.0/readme>

### `fountain::f_rx`
反应式编程API
也可以使用`fountain::fountain.rx`包使用本模块的同名API。

**详情请见：**<https://pkg.cangjie-lang.cn/package/fountain::f_rx/1.3.0/readme>

### `fountain::f_security`
配合MVC使用的安全模块
也可以使用`fountain::fountain.security`包使用本模块的同名API。

**详情请见：**<https://pkg.cangjie-lang.cn/package/fountain::f_security/1.3.0/readme>

### `fountain::f_ticktock`
CRON定时器模块
也可以使用`fountain::fountain.ticktock`包使用本模块的同名API。

**详情请见：**<https://pkg.cangjie-lang.cn/package/fountain::f_ticktock/1.3.0/readme>

### `fountain::f_time`
标准库的时间API扩展
也可以使用`fountain::fountain.time`包使用本模块的同名API。

**详情请见：**<https://pkg.cangjie-lang.cn/package/fountain::f_time/1.3.0/readme>

### `fountain::f_util`
crc16/密钥交换协议/命名风格转换/常用设计模式/geohash/snowflake/UUID/murmur_hash/路径匹配/文本模板/树结构转换
也可以使用`fountain::fountain.util`包使用本模块的同名API。

**详情请见：**<https://pkg.cangjie-lang.cn/package/fountain::f_util/1.3.0/readme>

### `fountain::f_version`
应用与fountain的版本信息和应用BANNER
也可以使用`fountain::fountain.version`包使用本模块的同名API。

**详情请见：**<https://pkg.cangjie-lang.cn/package/fountain::f_version/1.3.0/readme>

### `fountain::f_egraph`
事件驱动的流程库

**详情请见：**<https://pkg.cangjie-lang.cn/package/fountain::f_egraph/1.3.0/readme>

### `fountain::f_llm`
基于`fountain::f_egraph`的大模型开发库

**详情请见：**<https://pkg.cangjie-lang.cn/package/fountain::f_llm/1.3.0/readme>

### `fountain::f_store`
基于`fountain::f_collection.ConcurrentSkipListMap`和`fountain::f_io.SegmentedLog`的LSM-TREE键值存储。
确保增删改查每一个操作都是原子的。还支持KEY前缀遍历的迭代器。

**详情请见：**<https://pkg.cangjie-lang.cn/package/fountain::f_store/1.3.0/readme>

### `fountain::fleet`
基于`fountain::f_store`、`fountain::f_codec`、`fountain::f_net`、`fountain::f_protocol`的数据同步服务。
可以用于服务注册、配置中心、元数据注册等。

**详情请见：**<https://pkg.cangjie-lang.cn/package/fountain::fleet/1.3.0/readme>

### `fountain::f_rpc`
RPC实现，服务自注册与发现，实现负载均衡、服务节点权重、心跳保活等

**详情请见：**<https://pkg.cangjie-lang.cn/package/fountain::f_rpc/1.3.0/readme>