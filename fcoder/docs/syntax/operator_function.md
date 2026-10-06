## 操作符函数
操作符函数	        函数签名                                                          示例
`[]` （索引取值）	`operator func [](index1: T1, index2: T2, ...): R`	             `current[index1, index2, ...]`
`[]` （索引赋值）	`operator func [](index1: T1, index2: T2, ..., value!: TN): R`   `current[index1, index2, ...] = value`
`()`               `operator func ()(param1: T1, param2: T2, ...): R`               `current(param1, param2, ...)`
`!`                `operator func !(): R`	                                        `!current`
`**`               `operator func **(other: T): R`                                  `current ** other`
`*`                `operator func *(other: T): R`                                   `current * other`
`/`                `operator func /(other: T): R`                                   `current / other`
`%`	               `operator func %(other: T): R`                                   `current % other`
`+`                `operator func +(other: T): R`                                   `current + other`
`-`                `operator func -(other: T): R`                                   `current - other`
`<<`               `operator func <<(other: T): R`                                  `current << other`
`>>`               `operator func >>(other: T): R`                                  `current >> other`
`<`                `operator func <(other: T): R`                                   `current < other`
`<=`               `operator func <=(other: T): R`                                  `current <= other`
`>`                `operator func >(other: T): R`                                   `current > other`
`>=`               `operator func >=(other: T): R`                                  `current >= other`
`==`	           `operator func ==(other: T): R`                                  `current == other`
`!=`               `operator func !=(other: T): R`                                  `current != other`
`&`                `operator func &(other: T): R`                                   `current & other`
`^`                `operator func ^(other: T): R`                                   `current ^ other`
`|`                `operator func |(other: T): R`                                   `current | other`
⚠️ **重要**：索引赋值操作符函数的最后一个参数必须是命名参数，且参数名只能是value！
