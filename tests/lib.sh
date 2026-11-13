# Tiny test helpers, for tests/*.sh:
#   check "<name>" '<condition>'   -- eg: check "run: says hi" '[[ "$out" == hi ]]'
#   summary                        -- at the end: counts, & fails if any check did
PASS=0 FAIL=0
function check() {
  if eval "$2"; then
    echo -e "\e[1;32mPASSED\e[0m : $1"; PASS=$((PASS+1))
  else
    echo -e "\e[1;31mFAILED\e[0m : $1"; FAIL=$((FAIL+1))
    [[ -n "${out:-}" ]] && echo "         (last output: ${out:0:300})"
  fi
}
function summary() {
  echo "$PASS passed, $FAIL failed"
  [[ $FAIL == 0 ]]
}
