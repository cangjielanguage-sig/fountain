https://www.rfc-editor.org/rfc/rfc9535.txt

学习这个文档，然后研究`./f_data`。
尤其是`./f_data/src/path/**/*.cj`，这是一个类似jsonpath的库，目的不是操作JSON，而是用jsonpath的思想操作`fountain::f_data.DataFields<T>`的实例。
基于这个文档对`./f_data/src/path/**/*.cj` 查漏补缺，完善它的功能，修改它的BUG，为它添加测试用例。
全过程只修改`./f_data/src/path`这个路径的代码，其它的代码不要动。