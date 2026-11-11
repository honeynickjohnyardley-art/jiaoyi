#!/usr/bin/env bash
# 在 Linux 上运行 SessionCloseEntry 的离线模拟测试（非 MetaEditor 编译，非券商模拟账户）。
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build
python3 mq5_to_cpp.py ../baseline_v1.18/SessionCloseEntry.mq5 build/ea_v118.cpp
python3 mq5_to_cpp.py ../v1.19/SessionCloseEntry_v119.mq5 build/ea_v119.cpp
g++ -std=c++17 -O1 -I. -Wall -Wno-unused -DEA='"build/ea_v118.cpp"' -o build/test_v118 scenarios.cpp
g++ -std=c++17 -O1 -I. -Wall -Wno-unused -DEA='"build/ea_v119.cpp"' -DV119 -o build/test_v119 scenarios.cpp
./build/test_v118 > build/out_v118.txt
rc=0
./build/test_v119 > build/out_v119.txt || rc=$?
grep '^REG ' build/out_v118.txt > build/reg_v118.txt
grep '^REG ' build/out_v119.txt > build/reg_v119.txt
echo "===== 旧功能回归：v1.18 与 v1.19 结果指纹对比 ====="
if diff build/reg_v118.txt build/reg_v119.txt > build/reg_diff.txt; then
  echo "一致：$(wc -l < build/reg_v118.txt) 个回归场景全部相同"
else
  echo "存在差异："; cat build/reg_diff.txt; rc=1
fi
echo "===== v1.19 新功能 ====="
grep -E '^(PASS|FAIL|SUMMARY)' build/out_v119.txt
exit $rc
