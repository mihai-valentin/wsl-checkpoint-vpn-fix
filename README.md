# wsl-checkpoint-vpn-fix

**Get WSL 2 networking back while the Check Point Endpoint Security VPN is connected in hub (full-tunnel) mode, without changing the VPN's configuration.**

As soon as the VPN connects, WSL loses all connectivity: `curl`, `apt`, `git`, `pip` and `ping` all time out, while Windows itself keeps working. This repository explains why, and ships a small PowerShell script that removes the routes that cause it, plus an optional scheduled task that does this automatically every time the VPN connects.

Your WSL traffic still goes through the VPN. The fix only repairs the private link between Windows and the WSL virtual machine.

> Unofficial. Not affiliated with Check Point Software Technologies or Microsoft.

## The problem

With the VPN connected, Windows works normally: the browser, PowerShell and Windows apps all reach the internet through the VPN. Inside WSL, nothing can connect anywhere:

```console
$ ping -c 2 8.8.8.8
2 packets transmitted, 0 received, 100% packet loss, time 1032ms

$ curl -sS https://www.google.com
curl: (28) Failed to connect to www.google.com port 443 after 9964 ms: Connection timed out

$ nslookup example.com 8.8.8.8
;; communications error to 8.8.8.8#53: timed out
```

- `apt`, `git clone`, `pip`, `npm` and anything else that opens a connection hang, then time out.
- **Names still resolve.** `getent hosts example.com` returns an address, because WSL's DNS tunneling answers through Windows. So it is not a DNS problem, even though it looks like one at first.
- **Disconnecting the VPN brings everything back immediately.** Reconnecting breaks it again.
- **Switching WSL between NAT and mirrored networking mode does not help.** Both break, for different reasons (see [Why it happens](#why-it-happens)).

It is easy to take this for a DNS or MTU problem, and most advice online goes that way. Neither is the cause here: see [What does not help](#what-does-not-help). If you have turned DNS tunneling off (`dnsTunneling=false`), name lookups may fail as well; that combination was not tested.

## Does this apply to you?

It does if all of these are true:

- You use **WSL 2** on Windows.
- You use the Check Point **Endpoint Security VPN** client (it installs a *Check Point Virtual Network Adapter For Endpoint VPN Client*), not Capsule VPN.
- Your VPN runs in **hub mode**: all traffic, including internet traffic, goes through the VPN.
- WSL works with the VPN disconnected and stops working the moment it connects.

To confirm, keep WSL running in NAT mode (see [step 1](#1-switch-wsl-to-nat-mode-with-dns-tunneling)), connect the VPN, and run the fix script in preview mode from the repository root. Preview mode needs no admin rights and changes nothing:

```powershell
powershell -ExecutionPolicy Bypass -File .\src\Fix-WslCheckPointRoutes.ps1 -WhatIf
```

If you are affected, it lists the routes it would remove, for example:

```
What if: Performing the operation "Remove route" on target "172.23.160.0/21 on 'Ethernet 2'".
What if: Performing the operation "Remove route" on target "172.23.168.0/21 on 'Ethernet 2'".
What if: Performing the operation "Remove route" on target "172.23.160.1/32 on 'Ethernet 2'".
What if: Performing the operation "Remove route" on target "172.23.175.255/32 on 'Ethernet 2'".
```

If it reports `No Check Point routes overlap the WSL subnet`, your problem is something else.

## Why it happens

### In NAT mode (the WSL default)

WSL 2 runs in a small virtual machine. In NAT mode, Windows and the VM talk over a private virtual network, the `vEthernet (WSL)` adapter, on a random subnet such as `172.23.160.0/20`. Windows forwards the VM's traffic to the internet and sends the replies back over that subnet.

In hub mode the Check Point client routes *everything* through the tunnel, and unless the gateway turns on `exclude_local_networks_in_hub_mode` (it is off by default), that includes the networks your PC is directly attached to. The client treats the WSL subnet as one of them. When the VPN connects, it:

1. adds two routes, each half the size of the WSL subnet (two `/21`s for a `/20`), pointing at the VPN adapter, and
2. adds host routes on the VPN adapter for the Windows end of the WSL link (`172.23.160.1/32`) and for the subnet's broadcast address, with a better metric than the originals.

Windows always picks the most specific route, and a `/21` beats the WSL `/20`. Replies meant for WSL go into the tunnel and vanish. WSL's own packets still leave, but nothing comes back, so every connection times out.

You can see this in the client log, `C:\Program Files (x86)\CheckPoint\Endpoint Connect\trac.log`. Routes are written in hex as `<destination, mask, next hop, interface index, metric>`. With made-up values (WSL subnet `172.23.160.0/20`, Office Mode next hop `10.0.0.25`) it looks like this; the comments on the right are added here:

```
[vna_rtm]  <ac17a800, fffff800, 0a000019, 13, 1>     # 172.23.168.0/21 -> VPN adapter
[vna_rtm] vnartm_perform_route_op: ADDED
[vna_rtm]  <ac17a000, fffff800, 0a000019, 13, 1>     # 172.23.160.0/21 -> VPN adapter
[vna_rtm] vnartm_perform_route_op: ADDED
[vna_rtm]  <ac17a001, ffffffff, 0a000019, 13, 1>     # 172.23.160.1/32 -> VPN adapter
[vna_rtm] vnartm_perform_route_op: ADDED
```

To check the two settings behind it:

```powershell
Select-String -Path "${env:ProgramFiles(x86)}\CheckPoint\Endpoint Connect\trac.log" `
    -Pattern 'neo_route_all_traffic_through_gateway return value', 'exclude_local_networks_in_hub_mode return value' |
    Select-Object -Last 2
```

`neo_route_all_traffic_through_gateway return value true` means hub mode. `exclude_local_networks_in_hub_mode return value false` means local networks are pulled into the tunnel.

### In mirrored mode

`networkingMode=mirrored` does not help, and it cannot be fixed from the outside. In mirrored mode WSL gets its own copy of the Check Point adapter, with the same Office Mode address and the same routes, so its routing is correct. But packets it sends into that adapter never get an answer: in testing, WSL sent hundreds of packets through it and received only ARP replies. The client log shows the adapter running with "traps", catching traffic from Windows' own network stack; mirrored-mode WSL hands it frames through the Hyper-V switch instead, and they are dropped. The same problem is reported in [microsoft/WSL#13426](https://github.com/microsoft/WSL/issues/13426).

## The fix

### 1. Switch WSL to NAT mode with DNS tunneling

Edit `%UserProfile%\.wslconfig` (create it if it does not exist):

```ini
[wsl2]
networkingMode=nat
dnsTunneling=true
```

Restart WSL: run `wsl --shutdown` in PowerShell, wait about 8 seconds, then open your distro again. If Docker Desktop is running, it keeps the WSL VM alive, and `wsl --shutdown` stops its engine too; Docker Desktop restarts it.

Inside WSL, `wslinfo --networking-mode` should now print `nat`. DNS tunneling (the default on current WSL) resolves names through Windows, which keeps working under the VPN.

### 2. Remove the routes after the VPN connects

Connect the VPN. Then, in an **elevated** PowerShell at the repository root, run:

```powershell
powershell -ExecutionPolicy Bypass -File .\src\Fix-WslCheckPointRoutes.ps1 -RecheckSeconds 30
```

The script:

- finds the current WSL subnet on its own (it changes every time WSL restarts),
- removes only the Check Point routes that lie inside that subnet,
- restores the host route for the Windows end of the WSL link if it is missing, and
- 30 seconds later, checks whether the client added any routes back and removes them again. In testing it never did during a session.

A successful run ends with a line like:

```
Windows routes the WSL subnet via 'vEthernet (WSL (Hyper-V firewall))' (172.23.160.0/20).
```

Test from WSL with `curl -sI https://example.com` rather than `ping`: some VPN gateways block ICMP, and Windows blocks ping to the WSL gateway address even without a VPN.

The change lasts until the VPN disconnects. The client adds the routes again on every connect, so the script has to run after every connect. Step 3 automates that.

### 3. Optional: run it automatically

In an elevated PowerShell at the repository root:

```powershell
powershell -ExecutionPolicy Bypass -File .\src\Register-WslCheckPointFixTask.ps1
```

This copies the fix script to `C:\ProgramData\WslCheckPointFix`, a folder only administrators can modify, and registers a scheduled task named **WSL Check Point route fix**. The task runs as SYSTEM whenever Windows reports a newly connected network (event 10000 in `Microsoft-Windows-NetworkProfile/Operational`). That includes the VPN connecting, and reconnecting after sleep. It waits up to 60 seconds for the client to add its routes, removes them, and checks again 30 seconds later. On ordinary network changes it finds nothing to do and exits.

The task's log is `C:\ProgramData\WslCheckPointFix\fix.log`, which you can read without admin rights. If you update the fix script, run the installer again to copy the new version.

To remove the task and its folder:

```powershell
powershell -ExecutionPolicy Bypass -File .\src\Register-WslCheckPointFixTask.ps1 -Uninstall
```

## If you can change the Check Point configuration

The clean fix is on the gateway: set `exclude_local_networks_in_hub_mode` to `true` or `client_decide` in `$FWDIR/conf/trac_client_1.ttm` and install policy. With `client_decide`, users get a checkbox under **Site Properties > Settings > "Do not route traffic for local network to the Security Gateway"**. See Check Point's [Excluding Local Networks from Hub Mode](https://sc1.checkpoint.com/documents/RemoteAccessClients_forWindows_AdminGuide/Content/Topics-RA-VPN-for-Win/Excluding-Local-Networks-from-Hub-Mode.htm).

Two caveats:

- Check Point's documentation does not say whether virtual adapters such as `vEthernet (WSL)` count as local networks. The client log shows it handling the WSL subnet exactly like a physical LAN, so it most likely applies, but this is untested.
- If the corporate network behind the VPN uses the same address range as your home LAN, excluding local networks makes those corporate addresses unreachable.

## Limitations

- **WSL restarting while the VPN is connected.** No network event fires, so the scheduled task does not run. The client computes its routes when it connects, so a WSL subnet created afterwards is probably left alone, but this is untested. If WSL has no connectivity in that situation, run the fix script once by hand.
- **Your home LAN stays unreachable while the VPN is connected.** Hub mode sends it through the tunnel as well. This fix only touches the WSL subnet.
- **Only the Check Point Endpoint Security VPN client is detected**, by the description of its virtual adapter. Another VPN client that splits local subnets the same way would need that match changed.

## What does not help

- **Mirrored mode**, as explained above.
- **The `resolv.conf` workaround** from Microsoft's WSL troubleshooting page. With DNS tunneling, name resolution keeps working under the VPN; it is the connections that fail.
- **Lowering the MTU.** Even small packets get no reply. In NAT mode, WSL already picked an MTU below the VPN adapter's 1350 in testing.
- **Adding routes inside WSL.** The broken routes are on the Windows side.

## Security notes

- Internet traffic from WSL still goes through the VPN tunnel. The script never adds routes to other networks. It only removes Check Point routes that lie entirely inside the WSL subnet, a network that exists only inside your PC.
- Route changes go to the active route table only, and disappear when the VPN disconnects or Windows restarts.
- The scheduled task runs as SYSTEM, so its copy of the script lives in a folder only administrators and SYSTEM can modify.
- If your organisation has rules about changing routes set by the VPN client, check them before using this.
- The scripts are short. Read them before running them.

## Tested with

- Windows 11 25H2 (build 26200), WSL 2.6.3, Ubuntu 22.04
- Check Point Endpoint Security VPN client, build 98.61 (2022), gateway in hub mode with Office Mode
- Windows PowerShell 5.1

## Tests

The route-matching logic has dependency-free tests. They need no admin rights and no VPN:

```powershell
powershell -ExecutionPolicy Bypass -File .\tests\Test-FixWslCheckPointRoutes.ps1
```

## References

- [microsoft/WSL#13426](https://github.com/microsoft/WSL/issues/13426): Check Point VPN and WSL 2 in mirrored mode
- [microsoft/WSL#4246](https://github.com/microsoft/WSL/issues/4246): Checkpoint VPN breaks WSL 2 network connectivity
- [Accessing network applications with WSL](https://learn.microsoft.com/en-us/windows/wsl/networking): NAT, mirrored mode and DNS tunneling
- [Troubleshooting WSL](https://learn.microsoft.com/en-us/windows/wsl/troubleshooting): the VPN sections
- [Check Point: Excluding Local Networks from Hub Mode](https://sc1.checkpoint.com/documents/RemoteAccessClients_forWindows_AdminGuide/Content/Topics-RA-VPN-for-Win/Excluding-Local-Networks-from-Hub-Mode.htm)
- [Check Point: Remote Access Modes](https://sc1.checkpoint.com/documents/RemoteAccessClients_forWindows_AdminGuide/Content/Topics-RA-VPN-for-Win/Remote-Access-Modes.htm): what hub mode is
- [sakai135/wsl-vpnkit](https://github.com/sakai135/wsl-vpnkit): a different approach that sends WSL traffic through a Windows process (not tested with this setup)

## License

[MIT](LICENSE)
