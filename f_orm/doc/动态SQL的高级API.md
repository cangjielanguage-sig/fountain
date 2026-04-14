## 动态SQL的高级API
```cj
//SqlExecutor扩展了这个接口
public interface SqlPartial <: RootDAO {
    /**
     * 将泛型类型T作为映射类型，用映射的表名构造insert into values前的部分。
     * @param ignoreColumns 忽略的列名，遍历映射类型所有的公共成员，得到它们对应的列名，忽略本参数指定的那些
     */
    func INTO<T>(ignoreColumns!: Array<String>): IntoClause<T> where T <: QueryMappersInit<T>
    /**
     * 将泛型类型T作为映射类型，用映射的表名构造insert into。
     * @param values，遍历泛型类型的实例所有公共成员，得到它们的值作为insert into values的值
     * @param ignoreColumns 忽略的列名，遍历映射类型的所有公共成员，得到它们对应的列名，忽略本参数指定的那些
     * @return 返回的是刚插入的ID
     */
    func INTO<T>(values: T, ignoreColumns!: Array<String>): Int64 where T <: QueryMappersInit<T> & ObjectData<T>
    /**
     * 将泛型类型T作为映射类型，用映射的表名构造update
     */
    func UPDATE<T>(): UpdateClause<T> where T <: QueryMappersInit<T>
    /**
     * map的key可以是列名或T的公共实例成员名，values必须包含主键键值对
     */
    func UPDATE<T>(values: Map<String, Any>): Int64 where T <: QueryMappersInit<T>
    /**
     * map的key可以是列名或T的公共实例成员名，id是要修改的表的主键值
     */
    func UPDATE<T, ID>(values: Map<String, Any>, id: ID): Int64 where T <: QueryMappersInit<T>
    /**
     * 将泛型类型T作为映射类型，用映射的表名构造update。
     * @param values 要更新的数据
     * @param ignoredColumns 忽略的列
     * @param includingColumns 要更新的列
     * @param dirty 只更新values内修改过的那些列。被@QueryMappersGenerator修饰的类，修改它们的公共实例属性时内部会记录修改过的属性。本函数会把这些属性名对应的列名作为includingColumns递归调用自身。
     * @return 更新的行数。这个函数会使用主键更新数据，返回的值要么是0，要么是1.
     * ignoredColumns includingColumns dirty，每次调用最多只能传其中一个，或者都不传，都不传时会更新T所有公共实例属性对应的列
     */
    func UPDATE<T>(values: T, ignoredColumns!: HashSet<String>, includingColumns!: HashSet<String>, dirty!: Bool): Int64 where T <: QueryMappersInit<T> & ObjectData<T>
    /**
     * 将泛型类型T作为映射类型，用映射的表名构造update。
     * @param values 要更新的数据
     * @param ignoredColumns 忽略的列
     * @param includingColumns 要更新的列
     * @return 更新的行数。这个函数会使用主键更新数据，返回的值要么是0，要么是1.
     * ignoredColumns includingColumns，每次调用最多只能传其中一个，或者都不传，都不传时会更新T所有公共实例属性对应的列
     */
    func UPDATE<T>(values: T, ignoredColumns!: Array<String>, includingColumns!: Array<String>): Int64 where T <: QueryMappersInit<T> & ObjectData<T>
    /**
     * 用泛型类型T构造delete from 或select ... from 
     */
    func FROM<T>(): FromClause<T> where T <: QueryMappersInit<T>
    /**
     * 分页查询
     * @param sql 基于此sql添加分页子句
     * @param size 每页返回的行数
     * @param page 返回第page页，page从1开始
     * @return 分页数据
     */
    func page<R>(sql: String, size: Int64, page!: Int64): Pagination<R> where R <: QueryMappersInit<R> & DataFields<R>
    /**
     * 分页查询，返回列索引是0的数据
     * @param sql 基于此sql添加分页子句
     * @param size 每页返回的行数
     * @param page 返回第page页，page从1开始
     * @return 分页数据
     */
    func singlePage<R>(sql: String, size: Int64, page!: Int64): Pagination<R> where R <: DataFields<R>
    /**
     * 分页查询，返回列索引是0的数据
     * @param sql 基于此sql添加分页子句
     * @param column 返回列索引是column的数据
     * @param size 每页返回的行数
     * @param page 返回第page页，page从1开始
     * @return 分页数据
     */
    func singlePage<R>(sql: String, column: Int64, size: Int64, page!: Int64 = 1): Pagination<R> where R <: DataFields<R>
    /**
     * 返回sql中列索引是0的第一行数据
     */
    func singleFirst<T>(sql: String): ?T
    /**
     * 返回sql中列索引是column的第一行数据
     */
    func singleFirst<T>(sql: String, column: Int64): ?T
    /**
     * 返回sql中列索名是column的第一行数据
     */
    func singleFirst<T>(sql: String, column: String): ?T
    /**
     * 返回sql查询结果，并使用mappers映射为泛型类型T，如果没查到数据返回None<T>
     */
    func first<T>(sql: String, mappers: QueryMappers<T>): Option<T> 
    /**
     * 返回sql查询结果，泛型类型T是数据映射类型，如果没有查到数据返回None<T>
     */
    func first<T>(sql: String): Option<T> where T <: QueryMappersInit<T> 
    /**
     * 将刚构造的SQL添加到当前的SqlExecutor
     */
    public func setSql(sql: String, clearArgsAfterExec!: Bool = true): SqlExecutor
    /**
     * 将刚构造的SQL添加到当前的SqlExecutor
     */
    public operator func ()(sql: String): SqlExecutor
}
```
```cj
abstract sealed class TableClause<T> <: ToString where T <: QueryMappersInit<T>{...}

public abstract class ExceptInsertClause<T> <: TableClause<T> where T <: QueryMappersInit<T> {
    /**
     * 内联接
     */
    public func INNER_JOIN<T>(AS!: String = '', ON!: String = ''): This where T <: QueryMappersInit<T> 
    /**
     * 左外联接
     */
    public func LEFT_JOIN<T>(AS!: String = '', ON!: String = ''): This where T <: QueryMappersInit<T> 
    /**
     * 右外联接
     */
    public func RIGHT_JOIN<T>(AS!: String = '', ON!: String = ''): This where T <: QueryMappersInit<T> 
    /**
     * 全联接
     */
    public func FULL_JOIN<T>(AS!: String = '', ON!: String = ''): This where T <: QueryMappersInit<T> 
    /**
     * 闭包用来构造SQL逻辑表达式
     */
    public func WHERE(condition: () -> Unit): This 
    /**
     * condition是WHERE后面的逻辑表达式
     */
    public func WHERE(condition: String): This 
    public func AND(condition: () -> Unit): This 
    public func AND(condition: String): This 
    public func OR(condition: () -> Unit): This 
    public func OR(condition: String): This 
    public func NOT(condition: () -> Unit): This 
    public func NOT(condition: String): This 
    /**
     * 用()包含构造的逻辑SQL片段
     */
    public func PAREN(condition: () -> Unit): This 
    /**
     * 用()包含condition
     */
    public func PAREN(condition: String): This 
    /**
     * 用()包含condition构造的SQL片段，在(前面添加op
     */
    public func PAREN(op: CondRelOp, condition: () -> Unit): This 
    /**
     * 用()包含condition，在(前面添加op
     */
    public func PAREN(op: CondRelOp, condition: String): This 
    /**
     * 添加order by 子句
     */
    public func ORDER_BY(orderBy: () -> String): This 
    /**
     * 添加分页子句，会按照SqlExecutor包含的驱动名找到对应的数据库SQL方言
     */
    public func LIMIT(size: Int64, offset!: Int64 = 0): This 
}
```
```cj
public class FromClause<T> <: ExceptInsertClause<T> where T <: QueryMappersInit<T> {
    /**
     * 基于此对象的数据构造DELETE SQL
     */
    public func DELETE(): Int64 
    public func DELETE(sql: String): Int64 

    public func GROUP_BY(groupBy: () -> String): This 
    public func HAVING(condition: () -> Unit): This 
    public func HAVING(condition: String): This 
    public func HAVING(arg: Map<String, Any>, condition: () -> String): This 
    public func HAVING<T>(arg: T, condition: () -> String): This where T <: ObjectData<T> 
    /**
     * 按主键查询
     */
    public func findById(id: Int64): ?T 
    /**
     * 按主键查询
     */
    public func findById(id: UInt64): ?T 
    /**
     * 按主键查询
     */
    public func findById(id: String): ?T 
    /**
     * 按主键删除
     */
    public func deleteById(id: Int64): ?T 
    /**
     * 按主键删除
     */
    public func deleteById(id: UInt64): ?T 
    /**
     * 按主键删除
     */
    public func deleteById(id: String): ?T 
    
    public func first<T>(): ?T where T <: QueryMappersInit<T> 
    public func first<T>(columns: String): ?T where T <: QueryMappersInit<T> 
    public func singleFirst<T>(column: String): ?T 
    public func list<T>(): ArrayList<T> where T <: QueryMappersInit<T> 
    public func list<T>(columns: String): ArrayList<T> where T <: QueryMappersInit<T> 
    public func singleList<T>(): ArrayList<T> 
    public func singleList<T>(column: String): ArrayList<T> 

    public func count(): Int64 
    public func singlePage<R>(size: Int64, page!: Int64 = 1): Pagination<R> where R <: DataFields<R> 

    public func singlePage<R>(column: String, size: Int64, page!: Int64 = 1): Pagination<R> where R <: DataFields<R> 
    
    public func page<R>(size: Int64, page!: Int64 = 1): Pagination<R> where R <: QueryMappersInit<R> & DataFields<R> 
    public func page<R>(columns: String, size: Int64, page!: Int64 = 1): Pagination<R> where R <: QueryMappersInit<R> & DataFields<R> 
}
```
```cj
public class UpdateClause<T> <: ExceptInsertClause<T> where T <: QueryMappersInit<T> {
    public func SET(set: () -> String): This 
    public func SET(arg: Map<String, Any>, condition: () -> String): This 
    public func SET<T>(arg: T, condition: () -> String): This where T <: ObjectData<T> 
    public func execute(): Int64 
    /**
     * 按主键更新
     */
    public func byId(id: Int64): Int64 
    /**
     * 按主键更新
     */
    public func byId(id: UInt64): Int64 
    /**
     * 按主键更新
     */
    public func byId(id: String): Int64 
}
```
```cj
public class IntoClause<T> <: TableClause<T> where T <: QueryMappersInit<T> {
    /**
     * 构造INSERT INTO的VALUES子句，value的每个公共实例属性和公共实例变量是VALUES子句的实参，每个实例成员对应一个?作为SQL参数占位符
     */
    public func VALUES<D>(value: D): This where D <: ObjectData<D> 
    /**
     * 构造INSERT SQL的SELECT ${selectColumns}
     */
    public func SELECT<T>(selectColumns: String): This where T <: QueryMappersInit<T> 
    /**
     * 构造INSERT SQL的SELECT 子句
     * @param selectColumns SELECT子句的查询列
     * @param fromClause SELECT 的from where group by order by 和分页子句的闭包
     */
    public func SELECT<T>(selectColumns: String, fromClause: (FromClause<T>) -> Unit): This where T <: QueryMappersInit<T> 
    /**
     * 构造ON DUPLICATE KEY UPDATE ...
     */
    public func ON_DUPLICATE_KEY_UPDATE(columns: ()-> String): This 
    /**
     * 构造ON CONFLICT columns DO UPDATE SET ...
     */
    public func ON_CONFLICT(columns: Array<String>, DO_UPDATE_SET!: () -> String): This 
    /**
     * 执行insert into，返回刚插入的主键
     */
    public func execute(): Int64
}
```
### 分页类型`Pagination<T>`
```cj
/**
 * 分页对象
 *
 * @param <T> 泛型，数据映射类型
 * @param page 当前页码
 * @param size 每页大小
 * @param pages 总页数
 * @param rows 总记录数
 * @param list 数据列表
 */
public class Pagination<T> <: ObjectData<Pagination<T>> where T <: DataFields<T> {
    public let pages: Int64
    public Pagination(
        public let page!: Int64,
        public let size!: Int64,
        public let rows!: Int64,
        public let list!: ArrayList<T>
    ) 
    public init(page!: Int64, size!: Int64, rows!: Int64, list!: () -> ArrayList<T>)
    public init(page!: Int64, size!: Int64, rows!: Int64, list!: (Int64, Int64) -> ArrayList<T>)
    public func toData(): Data 
    public static func tryFromData(data: Data, flag: DataConversionFlag): Any 
    public static func dataFields(): ObjectFields 
}
```
