#!/usr/bin/env python3
"""把 SessionCloseEntry 的 .mq5 源码机械转换成可用 g++ 编译的 C++（配合 mql_shim.h）。

只做语法层面的等价改写，不改任何逻辑：
  - 去掉 #property / #include <Trade\\Trade.mqh> / input group
  - input 变量改为普通全局变量（测试代码需要给它们赋值）
  - 字符串字面量包成 string("...")（C++ 不能直接把两个字面量相加）
  - 动态数组  T name[]  ->  DynArr<T> name
  - 为所有函数生成前置声明（MQL5 允许先用后定义）
用法：mq5_to_cpp.py 输入.mq5 输出.cpp
"""
import re
import sys

src = open(sys.argv[1], encoding="utf-8-sig").read().split("\n")
out = []
protos = []
STR = re.compile(r'"(?:[^"\\]|\\.)*"')

i = 0
while i < len(src):
    line = src[i]
    stripped = line.strip()
    if stripped.startswith("#property") or stripped.startswith("#include") or stripped.startswith("input group"):
        out.append("// " + line)
        i += 1
        continue
    code, sep, comment = line.partition("//")
    # 注意：源码的字符串里没有 "//"，所以可以安全地按 // 切分注释
    if code.startswith("input "):
        code = code[len("input "):]
    code = re.sub(r"\b(string|int)\s+&(\w+)\[\]", r"DynArr<\1> &\2", code)
    code = re.sub(r"^(\s*)(string|int)\s+(\w+)\[\];", r"\1DynArr<\2> \3;", code)
    code = STR.sub(lambda m: "string(" + m.group(0) + ")", code)
    line2 = code + sep + comment
    # 函数定义：顶格开始、不是预处理/结构/枚举/全局变量，签名可能跨多行，下一行是 "  {"
    if re.match(r"^[A-Za-z_]", code) and "(" in code and not code.rstrip().endswith(";") \
            and not re.match(r"^(struct|enum|class)\b", code):
        sig = [code.rstrip()]
        j = i
        while ")" not in sig[-1] or sig[-1].count("(") > sig[-1].count(")") + sum(s.count(")") - s.count("(") for s in sig[:-1]):
            j += 1
            nxt = src[j].partition("//")[0]
            nxt = re.sub(r"\b(string|int)\s+&(\w+)\[\]", r"DynArr<\1> &\2", nxt)
            sig.append(nxt.rstrip())
        if j + 1 < len(src) and src[j + 1].strip() == "{":
            protos.append(" ".join(s.strip() for s in sig) + ";")
    out.append(line2)
    i += 1

text = "\n".join(out)
marker = "//==================== 全局变量 ===================="
assert marker in text
text = text.replace(marker, "// ---- 自动生成的函数前置声明 ----\n" + "\n".join(protos) + "\n\n" + marker, 1)
open(sys.argv[2], "w", encoding="utf-8").write('#include "mql_shim.h"\n' + text)
print(f"{sys.argv[1]}: {len(src)} lines, {len(protos)} function prototypes")
