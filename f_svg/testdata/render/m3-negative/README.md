M3 负向 fixture 目录（占位）。

用于放置损坏 / 超限输入：
- 非 gzip、截断 gzip、CRC 损坏；
- 坏 CRC / 截断 IDAT / 缺 IEND / 非法 IHDR 的 PNG；
- 超限 base64、超大 tile、超深引用链。

负向用例以内存字节构造为主，只有需要真实文件时才落盘于此。
