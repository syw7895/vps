#!/usr/bin/env bash
# 运行全部测试
cd "$(dirname "$0")" || exit 1
rc=0
for t in test_*.sh; do
  printf '\n### %s\n' "$t"
  bash "$t" || rc=1
done
if ((rc == 0)); then printf '\n全部通过\n'; else printf '\n有失败的测试\n'; fi
exit "$rc"
