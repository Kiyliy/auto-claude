Check whether this teammate has completed all assigned tasks and verified its work.

Completion check:
1. All required features implemented?
2. Any missing edge cases or error handling?
3. Any remaining TODOs or placeholder code?

Verification check:
4. Did it run tests or verification commands to confirm correctness?
5. Did it check output (code runs, files exist, format correct)?
6. For code changes: did it run lint / build / test?

Not complete or not verified → `{"ok": false, "reason": "specific description"}`
Complete and verified → `{"ok": true}`
