```
 0 1 2 3 4 5 6 7
|-|-|-|-|-|-|-|-|
|-  i  -|s|- l -|
|-  f  -| - l - |
|-  s  -| - l - |
|-  b  -| - v - |
|- bi  -|s|- l -|
|-  r  -|s|- l -|
|-  d  -|s|- l -|
|-  t  -|s|- l -|
|-  l  -|-  ll -|
|-  m  -|-  ml -|
|-  o  -|-  ol -|
n: 只有一字节，0
i: s是符号位，1表示负数，0表示非负数。l取值是1到8，由于只有三位，l是8时溢出为0。取值范围是[Int64.Min, UInt64.Max]，负数会先取位反再输出，正数小端序输出，值如果是0后四位是0001，后面紧跟一个值是0的字节。
f: l全0表示NaN，全1表示Inf，0001表示0.0，没有后续字节。其它取值只有2 4 8，先f.toBits()再按照无符号整数输出。
s: l表示字符串长度的字节数，后面紧跟着表示长度的小端序字节序列，后面是UTF8字节。空串只有一字节00010000，后续没有字节。
b: v取值只有0或1，分别表示false/true。只有一字节00100000和00100001，没有后续字节。
bi1: 如果bi在i的取值区间，则按照i输出。编号也是i。
bi2: 超过i取值区间的，l是bi.toBytes()的长度的字节数（如果是正数就是bi.toBytes()[1 .. ].size），紧跟着长度字节序列，然后是bi.toBytes()（如果是正数就是bi.toBytes()[1 ..]）。
r1|r2: 为避免损失精度，不转成基本类型。获得r.value，严格按照bi输出。后面跟着精度和标度。详细格式如下：
|-  r  -|s|- l -|
| bytes of value|
|- sc-|- bytes -|
|- of scale    -|
sc是标度字节数，占三比特，bytes of scale是标度值的字节序列，scale<=0x1f的sc值是0，bytes of scale独占一字节。r.value在i取值区间的， l和bytes of value采用bi1，编号是r1；超过这个区间的采用bi2，编号是r2。对于r值是0，scale>0的，s+l是0000，没有bytes of value，scale照前述输出。对于scale是0的，不论r值，一律作为bi1输出。
d1|d2: BigInt(d.toSeconds()) * BigInt(10**9) + BigInt((d - Duration.second * d.toSeconds()).toNanoseconds())，再严格按照bi1|bi2输出。
t1|t2: t - DateTime.Epoch再按照d1|d2的格式输出。
l: ll是集合长度的字节数，紧跟着长度的字节序列，然后按照各种数据格式输出
m: ml是map长度的字节数，紧跟着长度的字节序列，然后按照遍历顺序和各种数据格式输出
o: ol是object fields数量的字节数，紧跟着fields数的字节序列，然后按照DataObject<T>(object).fields()的名称murmur_hash128比较顺序输出Data。反序列化就是按照murmur_hash128查找对应的field
```
| 类型（t）           | 编号\|二进制        |
| ------------------- | ------------------- |
| None(n)             | 0\|0000             |
| 字符串(s)           | 1\|0001             |
| Bool(b)             | 2\|0010             |
| 整数(i)             | 3\|0011             |
| 浮点数(f)           | 4\|0100             |
| BigInt(bi1)         | 5\|0101（保留编号） |
| BigInt(bi2)         | 6\|0110             |
| Decimal(r1)         | 7\|0111             |
| Decimal(r2)         | 8\|1000             |
| Duration(d1)        | 9\|1001             |
| Duration(d2)        | 10\|1010            |
| DateTime(t1)        | 11\|1011            |
| DateTime(t2)        | 12\|1100            |
| list\|array\|set(l) | 13\|1101            |
| map(m)              | 14\|1110            |
| object(o)           | 15\|1111            |

