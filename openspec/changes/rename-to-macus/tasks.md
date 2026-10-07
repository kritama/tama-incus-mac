## 1. Package and commands

- [x] 1.1 Rename the SwiftPM package/module/source/test paths and replace both entrypoints with a minimal macus executable and unified library dispatch; update client/log names and new remote default.
- [x] 1.2 Share daemon/client state resolution with MACUS_STATE_DIR and legacy TIM_STATE_DIR fallback; preserve default path and persisted identifiers, and add command/state compatibility regressions.

## 2. Delivery and documentation

- [x] 2.1 Install and verify one entitled macus executable, rename the launchd template and acceptance runner, and update isolated installer safety tests.
- [x] 2.2 Update current documentation and project context/instructions with command mapping, state compatibility and launchd transition; retain historical evidence and valid repository links.

## 3. Validation

- [x] 3.1 Run Integration/scripts/check.sh and strict OpenSpec validation, inspect the final diff and run CodeRabbit when available; record results separately from hardware acceptance.

- [x] 3.2 Address Greptile capability stream capture and the failing CI HTTP fixture race; demonstrate failing regressions before fixes and pass canonical checks plus repeated regression runs.
- [x] 3.3 Isolate canonical Swift test scheduling from unrelated subprocess startup, permit early disconnects only in deadline fixtures, and rerun all canonical checks without loosening timing assertions.
