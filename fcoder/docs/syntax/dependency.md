## 依赖
在模块或项目的cjpm.tom `[dependencies]`按以下方式添加依赖
```toml
[dependencies]
  "orgname::module_name" = "x.y.z" # = 左面是依赖的标识，右面是依赖的版本号；::左面是依赖的模块所属组织，::右面是依赖的模块
  "org2::mod2" = {path = "/path/of/dependency/on/local/machine"}
  "org3::mod3" = {git = "https://domain.name/path/of.git"}
```
