<!-- Keep this short. Why the change matters is more useful than what it does. -->

## What and why

## Checks

- [ ] `tests\Test-FixWslCheckPointRoutes.ps1` passes
- [ ] `.\src\Fix-WslCheckPointRoutes.ps1 -WhatIf` still runs without admin rights
- [ ] Added test cases, if this changes which routes get removed
- [ ] `.ps1` files are still ASCII-only
- [ ] Nothing from my own network is in the diff: no gateway, hostnames, usernames or employer name

## If this touches the fix itself

CI can't run it: it needs Windows, WSL and a connected Check Point VPN in hub
mode. Which setup did you test on?

- Windows:
- WSL:
- Check Point client:
- [ ] Not applicable
