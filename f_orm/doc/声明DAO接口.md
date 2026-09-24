## 声明DAO接口
使用本ORM的全部代码都在DAO接口函数，不必声明DAO接口的实现
**注意**：每个DAO接口函数必须最多只能执行一条SQL。

```cj
import fountain::f_orm.*
import fountain::f_orm.macros.*

//下面这样就声明了一个名为UserDAO的DAO接口
@DAO//这个宏不可省略，这个宏会把它修饰的接口扩展到SqlExecutor，
    //同一个包可以导入多个DAO接口，这些接口的函数最好不要构成重载，否则可能导致函数重定义或者导致令人费解的状况
public interface UserDAO <: RootDAO {//必须是RootDAO的子接口
    /**
     * arg 函数是RootDAO的成员，这个函数会把它的实参填充到SQL参数列表，并返回字符串'?'作为SQL参数占位符
     * executor是RootDAO的属性，它的类型是SqlExecutor，SqlExecutor是ORM的核心，主要功能都在这个类
     */
    func register(username: String, password: String): Int64 {
        executor.setSql('''
            insert into user_info(
                        username,
                        password)
                 values(${arg(username)}, 
                        ${arg(password)}) 
            returning id'''//这是postgres 语法
        ).insert//执行insert，返回的是刚插入记录的主键
    }
    func changePassword(username: String, password: String): Int64 {
        executor.setSql('''
            update user_info
               set "password" = ${arg(password)}
             where username = ${arg(username)}'''
        ).update//执行update sql，返回的是修改的行数
    }
    func findUser(id: Int64): UserPO {
        executor.setSql('''
            select * 
              from user_info
             where id = ${arg(id)}'''
        ).first<UserPO>().getOrThrow()//返回查询结果的第一行记录
    }
    func findUserToMap(id: Int64): Map<String, Any> {
        executor.setSql('''
            select * 
              from user_info
             where id = ${arg(id)}'''
        ).firstToMap()//把第一行查询结果映射为一个HashMap，KEY是列名或列别名
    }
    func listUsers(): Pagination<UserPO> {
        //从FROM的泛型实参是得到表名，page的泛型实参是将查询结果映射到的类型
        executor.FROM<UserPO>()
        .WHERE{//WHERE函数会把尾闭包内的每一次meet函数调用结果拼到SQL内，并且会裁剪掉开头和结尾的and 和or
            //meet是RootDAO的成员函数，第二个参数会成为SQL的一部分，尾闭包返回的字符串会添加到SQL参数列表，
            //meet函数会把'?'拼到SQL参数相应的位置作为SQL参数占位符
            meet(username.size > 0, ' username like '){'%${username}%'}
            meet(password.size > 0, 'and "password" like '){'%${password}%'}
        }
        .page<UserPO>(10, page: 1)//返回映射类型UserPO对应的表的分页查询结果，本次查询一页10行，返回第一页
    }
    func deleteUser(id: Int64): Int64 {
        executor.setSql('''
            delete 
              from user_info
             where id = ${arg(id)} 
        '''
        ).delete//执行delete，返回的是删除的行数
    }

}
```
