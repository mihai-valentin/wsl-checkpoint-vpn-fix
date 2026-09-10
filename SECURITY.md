# Security Policy

## Reporting a vulnerability

Please report security issues privately through
[GitHub Security Advisories](https://github.com/mihai-valentin/wsl-checkpoint-vpn-fix/security/advisories/new)
rather than opening a public issue.

Expect an initial response within a week. This is a solo-maintained side
project: there is no bounty, and no SLA beyond a genuine effort to fix real
problems quickly.

## What this software does, so you can judge the risk

You are asked to run these scripts **as administrator**, and the optional
scheduled task runs **as SYSTEM**. This is everything they do:

- **`src/Fix-WslCheckPointRoutes.ps1`** reads the network adapters and the IPv4
  route table. It then removes routes on the Check Point virtual adapter that
  lie inside the WSL vEthernet subnet, and may add back one host route on the
  WSL adapter. Changes go to the active route table only; nothing is
  persistent. With `-LogFile` it appends to that file.
- **`src/Register-WslCheckPointFixTask.ps1`** creates
  `C:\ProgramData\WslCheckPointFix`, copies the fix script into it, removes
  inherited permissions so only SYSTEM and Administrators can write there
  (Users can read), and registers a scheduled task that runs the copy as SYSTEM
  on NetworkProfile event 10000. `-Uninstall` removes both.
- **Both are run with `-ExecutionPolicy Bypass`**, as the README shows. That
  applies only to the one PowerShell process it is passed to.
- **No network calls, no telemetry, nothing downloaded.**

## The parts worth scrutinising

If you're auditing this, these are where a problem would most plausibly live:

- **Which routes get removed.** Only routes whose prefix lies entirely inside
  the WSL subnet should match. A bug here could remove a route the VPN needs,
  sending that traffic around the tunnel. The matching is covered by `tests/`;
  reports of a wrongly matched route are very welcome.
- **The SYSTEM task runs a script file.** If a standard user could modify
  `C:\ProgramData\WslCheckPointFix\Fix-WslCheckPointRoutes.ps1`, that would be
  privilege escalation. The installer strips inherited permissions for exactly
  this reason. Please report any way around it.
- **The task fires on every newly connected network**, not only the VPN. Each
  run is read-only unless it finds Check Point routes inside the WSL subnet.
- **Adapters are recognised by name.** The WSL adapter is matched as
  `vEthernet (WSL*` and the VPN adapter by the description
  `Check Point Virtual Network Adapter*`. Another adapter carrying those names
  would be treated as one of them.

## Not vulnerabilities

- **Behaviour of the Check Point client or of WSL itself.** This project works
  around them; it can't change them.
- **Your organisation's VPN policy.** The fix doesn't take traffic out of the
  tunnel, but if your organisation forbids changing routes the VPN client
  created, that is a policy question, not a security bug.
