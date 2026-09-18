#!/usr/bin/env bash
# Hit every endpoint as each role and report what happened. Run after ./dev.sh.
# This is an authorisation test as much as a liveness test: the FAIL cases
# (a teacher reaching an admin route, a student reaching alerts) matter more
# than the passes.
set -uo pipefail
API=${API:-http://localhost:3001}
PASS=0; FAIL=0
CK_ADMIN=/tmp/ck_admin.txt; CK_TEACHER=/tmp/ck_teacher.txt
CK_STUDENT=/tmp/ck_student.txt; CK_NONE=/tmp/ck_none.txt
: > "$CK_NONE"

login() { # login <cookiejar> <email> <password>
  curl -s -X POST "$API/auth/login" -H 'content-type: application/json' \
    -c "$1" -d "{\"email\":\"$2\",\"password\":\"$3\"}" -o /dev/null -w '%{http_code}'
}

check() { # check <name> <expected_status> <cookiejar> <method> <path> [body]
  local name="$1" want="$2" jar="$3" method="$4" path="$5" body="${6:-}"
  local got
  if [ -n "$body" ]; then
    got=$(curl -s -o /tmp/smoke_body.txt -w '%{http_code}' -b "$jar" -X "$method" \
          -H 'content-type: application/json' -d "$body" "$API$path")
  else
    got=$(curl -s -o /tmp/smoke_body.txt -w '%{http_code}' -b "$jar" -X "$method" "$API$path")
  fi
  if [ "$got" = "$want" ]; then
    printf '  \033[32mok\033[0m   %-52s %s\n' "$name" "$got"; PASS=$((PASS+1))
  else
    printf '  \033[31mFAIL\033[0m %-52s got %s want %s\n' "$name" "$got" "$want"
    head -c 150 /tmp/smoke_body.txt; echo; FAIL=$((FAIL+1))
  fi
}

PW=${DEMO_PASSWORD:-demo school passphrase}
echo "== signing in =="
echo "  admin   $(login $CK_ADMIN   sofia.andreou@demo.school "$PW")"
echo "  teacher $(login $CK_TEACHER elena.papadaki@demo.school "$PW")"
echo "  student $(login $CK_STUDENT student@demo.school "$PW")"

echo "== public =="
check "health"                  200 "$CK_NONE" GET /health
check "setup/needed"            200 "$CK_NONE" GET /setup/needed

echo "== unauthenticated must be refused =="
check "groups without session"  401 "$CK_NONE" GET /groups
check "attention without session" 401 "$CK_NONE" GET /attention
check "users without session"   401 "$CK_NONE" GET /users

echo "== teacher =="
check "me"                      200 "$CK_TEACHER" GET /me
check "groups"                  200 "$CK_TEACHER" GET /groups
check "todo"                    200 "$CK_TEACHER" GET /todo
check "attention"               200 "$CK_TEACHER" GET /attention

echo "== teacher must NOT reach admin =="
check "users (403)"             403 "$CK_TEACHER" GET /users
check "invites (403)"           403 "$CK_TEACHER" POST /invites '{"email":"x@y.test"}'

echo "== admin =="
check "users"                   200 "$CK_ADMIN" GET /users
check "invites list"            200 "$CK_ADMIN" GET /invites

echo
echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
