## 仓颉项目/模块目录结构
```
module_dir
`--src
    `-- directory_0
        |-- directory_1
        |    |-- a.cj
        |    `-- b.cj
        `-- c.cj
    `-- module.cj

```
## 构建命令
- **cjpm init --type=dynamic** - 将当前文件夹初始化为一个动态链接库模块，当前文件夹必须是空的
- **cjpm clean** - 当前文件夹是一个仓颉模块，清空这个模块的编译结果
- **cjpm build** - 当前文件夹是一个仓颉模块，构建当前模块
- **cjpm test**
    - **cjpm test -i src/pkg** - 当前文件夹是一个仓颉模块，执行指定文件夹下的单元测试用例
    - **cjpm test -i --filter=<value>** - 执行符合过滤规则的单元测试用例
        - --filter <value> 用于过滤测试的子集，value 的形式如下所示：
        - --filter=* 匹配所有测试类
        - --filter=*.* 匹配所有测试类的所有测试用例（结果和*相同）
        - --filter=*.*Test,*.*case* 匹配所有测试类中以 Test 结尾的用例，或者所有测试类中名字中带有 case 的测试用例
        - --filter=MyTest*.*Test,*.*case*,-*.*myTest 匹配所有 MyTest 开头测试类中以 Test 结尾的用例，或者名字中带有 case 的用例，或者名字中不带有 myTest 的测试用例