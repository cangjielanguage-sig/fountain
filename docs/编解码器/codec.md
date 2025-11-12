```
 0 1 2 3 4 5 6 7
|-|-|-|-|-|-|-|-|
|-  i-|s|-  l  -|
|-  f-| -  l  - |
|-  s-| -  l  - |
|-  b-| -  v  - |
|- bi |i|s|- l -|
|-  r-|i|s|- l -|
|-  d-|s|-  l  -|
|-  t-|s|-  l  -|
|-  l-|-   ll  -|
|-  m-|-   ml  -|
|-  o-|-   ol  -|
i: s是符号位，1表示负数，0表示非负数。l取值是1到8，取值范围是[Int64.Min, UInt64.Max]，负数会先取位反再输出，正数小端序输出，值如果是0后五位是00000，没有后续字节。
f: l全0表示NaN，全1表示Inf，取值只有1 2 4 8，先f.toBits()再按照无符号整数输出，0值后四位是0001，后面不再输出字节。
s: l表示字符串长度的字节数，后面紧跟着表示长度的小端序字节序列，后面是UTF8字节
b: v取值只有0或1，分别表示false/true。
bi: 值在i范围内的按i类型输出，由于字节数位只有3，字节数如果是8则溢出为0，i位是1；否则i位是0，l是bi.toBytes()的长度的字节数（如果是正数就是bi.toBytes()[1 .. ].size），紧跟着长度字节序列，然后是bi.toBytes()（如果是正数就是bi.toBytes()[1 ..]）。如果bi值是0，后五位是10001，后面紧跟一个值是0的字节。
r: 为避免损失精度，不转成基本类型。获得r.value，按照BigInt输出。后面跟着精度和标度。详细格式如下：
|-  r-|i|s|- l -|
|-preci-|-scale-|
| bytes of preci|
| bytes of scale|
preci是精度字节数，scale是标度字节数，bytes of preci是精度值的字节序列，bytes of scale是标度值的字节序列
d: BigInt(d.toSeconds()) * BigInt(10**9) + BigInt((d - Duration.second * d.toSeconds()))，再按照BigInt输出，如果d是负的先取相反数再操作。
t: t - DateTime.Epoch再按照d的格式输出。
l: ll是集合长度的字节数，紧跟着长度的字节序列，然后按照各种数据格式输出
m: ml是map长度的字节数，紧跟着长度的字节序列，然后按照遍历顺序和各种数据格式输出
o: ol是object fields数量的字节数，紧跟着fields数的字节序列，然后按照DataObject<T>(object).fields()的名称murmur_hash128比较顺序输出Data。反序列化就是按照murmur_hash128查找对应的field
```
| 类型（t）           | 编号 |
| ------------------- | ---- |
| 字符串(s)           | 1    |
| Bool(b)             | 2    |
| 整数(i)             | 3    |
| 浮点数(f)           | 4    |
| BigInt(bi)          | 5    |
| Decimal(r)          | 6    |
| Duration(d)         | 7    |
| DateTime(t)         | 8    |
| list\|array\|set(l) | 10   |
| map(m)              | 12   |
| object(o)           | 14   |

