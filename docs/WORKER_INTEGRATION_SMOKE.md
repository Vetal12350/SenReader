# Universal Worker integration smoke test

SenReader is a Flutter Android app. Owner-authorized GitHub Issues can be processed by the single worker in the separate Codex-Control-Center repository.

For this docs-only smoke test, the worker should propose one PR targeting SenReader `main`. The result requires PR review; no automatic merge is permitted. Trusted orchestration handles PR creation. APK builds run in GitHub Actions. Do not claim that tests or APK builds passed until their results have been verified.

Safety note: this task must not change source adapters, Flutter code, credentials, signing keys, workflows, or production/VPS or FunPay operations. Only this document may be created; no other files may be modified.

If the worker is not running, the Issue remains queued until a safe, owner-authorized worker starts. A previous waiting heartbeat or held worker lock does not verify that the worker is currently running or that this smoke test has completed.
