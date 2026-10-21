#!/usr/bin/env bash
# 极简断言库：纯 bash 实现，不依赖 bats / shunit2
# 用法：source test/lib.sh; assert_eq "期望" "实际" "描述"

TEST_PASS=0
TEST_FAIL=0
TEST_CASE="${TEST_CASE:-未命名}"

test_case() {
  TEST_CASE="$1"
  printf '\n  \033[1m%s\033[0m\n' "$1"
}

assert_eq() {
  local expected="$1" actual="$2" msg="${3:-值相等}"
  if [[ "$expected" == "$actual" ]]; then
    TEST_PASS=$((TEST_PASS + 1))
    printf '    \033[32m✔\033[0m %s\n' "$msg"
  else
    TEST_FAIL=$((TEST_FAIL + 1))
    printf '    \033[31m✘\033[0m %s\n' "$msg"
    printf '        期望: %s\n' "$expected"
    printf '        实际: %s\n' "$actual"
  fi
}

assert_contains() {
  local haystack="$1" needle="$2" msg="${3:-包含子串}"
  if [[ "$haystack" == *"$needle"* ]]; then
    TEST_PASS=$((TEST_PASS + 1))
    printf '    \033[32m✔\033[0m %s\n' "$msg"
  else
    TEST_FAIL=$((TEST_FAIL + 1))
    printf '    \033[31m✘\033[0m %s\n' "$msg"
    printf '        期望包含: %s\n' "$needle"
    printf '        实际: %s\n' "$haystack"
  fi
}

assert_status() {
  local expected="$1" actual="$2" msg="${3:-退出码}"
  assert_eq "$expected" "$actual" "$msg (期望码 $expected / 实际码 $actual)"
}

assert_true()  { if [[ "$1" == "0" ]]; then assert_eq 0 0 "${2:-为真}"; else assert_eq 0 1 "${2:-为真}"; fi; }
assert_false() { if [[ "$1" == "0" ]]; then assert_eq 0 1 "${2:-为假}"; else assert_eq 0 0 "${2:-为假}"; fi; }

# 以【退出码】断言：直接把命令作为参数传入。
# 布尔型函数（返回 0/1 退出码而非打印值）必须用这两个，否则会误判。
assert_succeeds() { local m="${2:-命令应以 0 退出}"; if "$@" >/dev/null 2>&1; then assert_eq 0 0 "$m"; else assert_eq 0 1 "$m"; fi; }
assert_fails()    { local m="${2:-命令应以非 0 退出}"; if "$@" >/dev/null 2>&1; then assert_eq 0 1 "$m"; else assert_eq 0 0 "$m"; fi; }

test_summary() {
  printf '\n  ────────────────────────────────\n'
  if [[ $TEST_FAIL -eq 0 ]]; then
    printf '  \033[32m全部通过\033[0m：%d 项断言\n' "$TEST_PASS"
    return 0
  fi
  printf '  \033[31m失败 %d 项\033[0m（通过 %d 项）\n' "$TEST_FAIL" "$TEST_PASS"
  return 1
}
