# Contributing to wsl-checkpoint-vpn-fix

Thanks for considering it. This is a small fix for one specific problem, and it
asks people to run a script as administrator. The constraints below keep it
small enough to read before running.

## The one rule that shapes everything else

**The fix must never route traffic around the VPN.** It only removes Check
Point routes that lie entirely inside the WSL subnet, a network that exists only
inside the PC. Anything that sends WSL traffic out of the tunnel, or touches
routes outside that subnet, is out of scope, however convenient it would be.

## Design constraints

These are settled. Please open an issue before working against any of them:

- **PowerShell only**, working in both Windows PowerShell 5.1 (built into
  Windows) and PowerShell 7. No modules to install.
- **ASCII-only `.ps1` files.** Windows PowerShell 5.1 reads UTF-8 files without
  a BOM as ANSI, so a single curly quote can break a script.
- **Every change goes through `ShouldProcess`**, so `-WhatIf` stays a complete
  preview that needs no admin rights.
- **No persistent route changes.** The Check Point client adds its routes again
  on every connect anyway.
- **The scheduled task only runs a copy in an admin-only folder.** A task that
  runs as SYSTEM must never execute a file a standard user can edit.
- **Mirrored mode is out of scope.** The README explains why it can't be fixed
  from outside.
- **No network calls, no telemetry.**
- **Short enough to read.** People are asked to run this elevated, so they
  should be able to review all of it first.

## Getting set up

There is no build step. Clone the repository and run the tests from its root:

```powershell
powershell -ExecutionPolicy Bypass -File .\tests\Test-FixWslCheckPointRoutes.ps1
```

They cover the route matching and need neither admin rights nor a VPN.

## Before opening a PR

- The tests pass.
- Preview mode still works without admin rights:
  `powershell -ExecutionPolicy Bypass -File .\src\Fix-WslCheckPointRoutes.ps1 -WhatIf`
- If you changed which routes get removed, add test cases for it, including
  routes that must be kept.
- Your changes contain nothing from your own network (see below).

**The fix itself can't run in CI.** It needs Windows, WSL and a connected Check
Point VPN in hub mode. If your change touches it, say in the PR which setup you
tested on: Windows version, WSL version and Check Point client version.

## Keep your network details out

This project exists because of corporate VPNs, so issues and PRs are an easy
place to leak details about someone's employer. Before posting logs, route
tables or script output, replace:

- VPN gateway addresses and hostnames
- your Office Mode address and your home or office LAN addresses
- usernames, computer names, domain names and your employer's name

The WSL subnet (for example `172.23.160.0/20`) is random and safe to share.
Don't paste raw `trac.log` excerpts without reading them first: they contain
the gateway, the VPN site name and sometimes your username.

## Commits

Conventional commits: `feat:`, `fix:`, `docs:`, `test:`, `chore:`.

Explain *why* in the body. The comments in the scripts follow the same rule:
what the code does is visible, why it does it is not.

## Reporting a bug

Use the bug report form; its questions are the ones that narrow a problem down.
Three things worth ruling out first:

- WSL is in mirrored mode (`wslinfo --networking-mode` prints `mirrored`),
  which this fix doesn't support.
- The fix ran before the VPN finished connecting, so there was nothing to
  remove yet. Run it again, or use `-WaitSeconds`.
- The VPN is not in hub mode, so something else is breaking WSL.
