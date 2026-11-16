# Saved replies

## Goal
Agents can save a reply and reuse it.

## Acceptance criteria
1. A saved reply appears in the picker after saving.

## Work units
### U1: Storage
- Depends on: none
- Covers: AC1
- Routing: colour=red
Model.

### U2: Picker
- Depends on: U1
- Covers: AC1
- Routing: personas=5-3
The picker.

### U3: Search
- Depends on: U2
- Covers: AC1
- Routing: workers=gpt-4
Search.

### U4: Sharing
- Depends on: U3
- Covers: AC1
- Routing: security=nobody
Sharing.

## Out of scope
- Nothing.
