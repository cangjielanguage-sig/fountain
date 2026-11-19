# Design

## Context

类成员的 JIT 调用 = 宏生成的 `PredefinedFunction`：`paramTypes[0]=14`，闭包内 `args[0] as C` 后直调。这条路不依赖反射，因此不受「接口方法是抽象声明」的限制。注册器只负责把描述符塞进注册表，前端按名字查方法。

## 决策

### D1 接口绑定由 `@JitBind` 生成，反射只做诊断

`InterfaceTypeInfo.getInstanceFunction(name)` 能取到声明，但 `apply` 抛 `Cannot invoke abstract function`（实测）。所以注册接口时**只接受**宏登记的方法；没有登记就报「接口必须用 @JitBind」——不给一条会在运行期必炸的回退路径。

### D2 父成员在**注册期**并入子描述符

- 类：沿 `cls.superClass` 链，先子后父、按名字去重（子类覆盖）；方法用「父类 `@JitBind` 登记」或父类反射 `FunctionInfo`（具体方法可 apply，子实例可上转）；字段**追加到子描述符尾部并重新编号**——字段表允许同 index 多个访问器，靠 `accepts` 区分，所以父子各自的编号互不冲突。
- 接口：父接口名来自宏的 `superTypes`，注册时按名查已注册的父描述符并复制方法；父接口必须先注册。

### D3 14 的判定 = 类祖先 ∪ 接口谓词

`isInstanceOfClass` 只走 `superClass`。接口实现关系在反射里拿不到（`ClassTypeInfo.interfaces` 不存在，实测），因此由宏登记谓词 `{ o => o is I }`，`CallMarshal` 先查类链、再查接口谓词。

### D4 返回类型：`InterfaceTypeInfo` 按 14

`localTypeOf` 末尾从「只认 ClassTypeInfo」扩为「ClassTypeInfo / InterfaceTypeInfo 都按 14」；`v as T` 对接口是合法转换，无需额外适配。

### D5 `ClassDescriptor` 增加 `isInterface`

前端只在诊断里用（「接口不能构造」「接口无字段」），成员解析与类同表。默认 `false`，既有手工注册不受影响。

## 风险

| 风险 | 影响 | 缓解 |
| --- | --- | --- |
| 父类字段重编号导致既有 index 变化 | 已注册类的字段 index 改变 | 仅在**子类**描述符内追加，父类描述符编号不变；子类新增字段排在继承字段之后 |
| 接口谓词与类名冲突 | 判定歧义 | 注册期拒绝同名接口/类（既有 `DuplicateClass`） |
| 父接口未注册 | 方法缺失 | 注册期诊断并拒绝，不做静默降级 |
