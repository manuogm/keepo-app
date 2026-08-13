#!/usr/bin/env bash
# L2 verification: the ticket-ordering guarantee (keepo-local-first-plan.md,
# LH1) is fundamentally a CROSS-TRANSACTION property — next_ticket()'s
# `select ... for update` row lock only means anything when two sessions
# actually overlap in time. A single pgTAP test file is one transaction
# (BEGIN...ROLLBACK), so it structurally cannot exercise this; that's why
# this lives here as a real two-psql-session script instead of a pgTAP file.
#
# What this proves: session A starts first and holds next_ticket()'s row
# lock for a few seconds (standing in for a genuinely slow write — the
# exact LH1 scenario, "a write starting 3:04:00 and committing 3:04:04").
# Session B starts shortly after, while A is still mid-transaction, and
# calls next_ticket() for the SAME domain. If tickets were assigned by
# `now()` instead, B's call could easily get a value that makes it look
# like it happened "before" A's slow write once A finally commits — a
# client polling by timestamp could see B's row, treat that as proof it's
# already synced past A's write, and silently miss A's forever. With
# next_ticket()'s row lock, B physically CANNOT proceed until A's
# transaction ends, so B's ticket is always numerically after A's,
# regardless of wall-clock timing. Order of ticket issuance == order of
# commit, full stop.
#
# Usage: run against a local `supabase start` stack.
#   bash supabase/scripts/two_session_ticket_order.sh

set -euo pipefail

DOMAIN="99999999-9999-9999-9999-999999999999"
CONTAINER="supabase_db_keepo-app"
PSQL=(docker exec -i "$CONTAINER" psql -U postgres -d postgres -v ON_ERROR_STOP=1 -qtA)

echo "Resetting sync_tickets row for test domain ${DOMAIN}..."
"${PSQL[@]}" -c "delete from sync_tickets where domain_id = '${DOMAIN}';"

SESSION_A_OUT=$(mktemp)
SESSION_B_OUT=$(mktemp)
trap 'rm -f "$SESSION_A_OUT" "$SESSION_B_OUT"' EXIT

echo "Starting session A: acquires next_ticket(), holds the transaction open for 3s (simulating a slow write)..."
(
  "${PSQL[@]}" <<SQL
begin;
select 'A ticket=' || next_ticket('${DOMAIN}'::uuid) || ' at ' || clock_timestamp();
select pg_sleep(3);
commit;
select 'A committed at ' || clock_timestamp();
SQL
) > "$SESSION_A_OUT" &
SESSION_A_PID=$!

sleep 1
echo "Starting session B: calls next_ticket() for the SAME domain while A still holds the row lock..."
(
  "${PSQL[@]}" <<SQL
begin;
select 'B calling next_ticket at ' || clock_timestamp();
select 'B ticket=' || next_ticket('${DOMAIN}'::uuid) || ' at ' || clock_timestamp();
commit;
SQL
) > "$SESSION_B_OUT" &
SESSION_B_PID=$!

wait "$SESSION_A_PID"
wait "$SESSION_B_PID"

echo
echo "=== Session A ==="
cat "$SESSION_A_OUT"
echo
echo "=== Session B ==="
cat "$SESSION_B_OUT"

A_TICKET=$(grep -o 'A ticket=[0-9]*' "$SESSION_A_OUT" | grep -o '[0-9]*')
B_TICKET=$(grep -o 'B ticket=[0-9]*' "$SESSION_B_OUT" | grep -o '[0-9]*')
B_CALL_TIME=$(grep 'B calling next_ticket' "$SESSION_B_OUT")

echo
if [ "$A_TICKET" -lt "$B_TICKET" ]; then
  echo "PASS: A's ticket ($A_TICKET) < B's ticket ($B_TICKET) — order of ticket issuance matches order of commit,"
  echo "      even though B CALLED next_ticket() while A's slow write was still in flight:"
  echo "      $B_CALL_TIME"
else
  echo "FAIL: expected A's ticket < B's ticket. Got A=$A_TICKET B=$B_TICKET."
  exit 1
fi

echo "Cleaning up test domain..."
"${PSQL[@]}" -c "delete from sync_tickets where domain_id = '${DOMAIN}';"
