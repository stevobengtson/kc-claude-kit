DECISION: ACCEPT
RISK: high
SURFACES: payments

## Summary
Orders over the limit are charged twice on retry.

## Scope
Make order payment retries idempotent so a retried charge never duplicates.

## Acceptance criteria
1. A retried payment for the same order creates one charge.
2. The order page shows a single payment line.
3. A failed retry leaves the order unpaid.

## Out of scope
- Refund flows.

## Ticket
https://example.atlassian.net/browse/ABC-2
