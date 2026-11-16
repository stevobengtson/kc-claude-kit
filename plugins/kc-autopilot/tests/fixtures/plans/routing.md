# Saved replies

## Goal
Agents can save a reply and reuse it.

## Acceptance criteria
1. A saved reply appears in the picker after saving.
2. Picking a saved reply inserts its text at the cursor.

## Work units
### U1: Saved reply storage
- Depends on: none
- Covers: AC1
- Routing: workers=best; personas=4-5; security=staff
Model, migration and API for saved replies.

### U2: Picker UI
- Depends on: U1
- Covers: AC2
- Routing: workers=sonnet
The picker in the composer.

## Out of scope
- Sharing replies between users.
