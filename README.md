# ResolvGuard — Intelligent DNS Monitoring & Failover for Asuswrt-Merlin

## v0.1.9

**Your DNS provider can be online and still return the wrong answer. ResolvGuard helps you catch that.**

ResolvGuard is a lightweight SSH add-on for ASUS routers running **Asuswrt-Merlin**. It monitors your existing **Strict DNS-over-TLS (DoT)** resolvers, checks the DNS answers they actually return, and can automatically work around unhealthy upstream resolvers while preserving your preferred DNS configuration.

It works with Merlin's existing **DNSMasq → Stubby → encrypted DoT** setup. You keep your router's built-in DNS services and manage ResolvGuard from a simple SSH menu.

## Features

- **DNS answer-aware monitoring.** Check more than whether a resolver responds. Validate DNS response codes, answer counts, and expected record data for queries such as A, AAAA, and TXT.
- **Individual resolver health checks.** Identify which of your configured encrypted DNS endpoints are behaving correctly and which are failing your checks.
- **Automatic DNS failover.** Optionally remove confirmed unhealthy upstream resolvers from the active WAN DNS pool while continuing to use healthy resolvers.
- **Automatic failback.** Restore preferred upstream resolvers after they recover and consistently pass their health checks.
- **Monitoring Only mode.** Keep an eye on DNS health without automatically changing your router's DNS settings.
- **Interactive DNS inspector.** Look up hostnames against available resolvers and turn useful results into health checks.
- **Flexible DNS checks.** Start with a simple default check or customize domains, record types, expected replies, and answer data.
- **Scheduled checks and logging.** Run health checks in the background using Merlin's built-in scheduler, and inspect recent results from the menu.
- **Safe DNS changes and recovery.** Confirm failures before switching, verify changes, and provide maintenance options to restore your preferred DNS configuration.
- **Built-in updates and uninstall.** Check for newer versions, update the main script without replacing your settings, or remove ResolvGuard from its SSH menu.

## Requirements

Before installing, you'll need:

- An ASUS router running **Asuswrt-Merlin**.
- **DNS Privacy Protocol: DNS-over-TLS (DoT), with DNS-over-TLS Profile: Strict**, and at least one properly configured authenticated DoT server.
- **SSH access** to the router.
- **JFFS custom scripts and configs enabled** for scheduled monitoring and startup integration.
- **Entware**, which supplies the `bind-dig` package used for DNS response inspection. The installer offers to install `bind-dig` if it is missing.
- A working internet connection and `curl` for downloading and updating the script.

**Tip:** Set up and confirm your preferred DNS-over-TLS servers in the ASUS web interface before installing ResolvGuard. Those servers are the configuration ResolvGuard can monitor and restore.

## Installation

### 1. Connect to your router

Enable SSH under **Administration → System** in the ASUS web interface, then connect using your preferred SSH client.

### 2. Install ResolvGuard

Copy and paste the following command into your SSH session:

```sh
curl -fL --retry 3 "https://github.com/ExtremeFiretop/ResolvGuard/releases/latest/download/ResolvGuard-install.sh" -o "/tmp/ResolvGuard.sh" && chmod +x "/tmp/ResolvGuard.sh" && sh /tmp/ResolvGuard.sh install
```

The `install` command verifies router prerequisites and checks for the Entware `bind-dig` package. If it is missing, ResolvGuard asks permission before installing it. Installation then initializes any missing configuration files and publishes the main script to `/jffs/addons/ResolvGuard.d/resolvguard.sh` **only after preparation succeeds**. Existing configuration files are preserved.

If installation cannot complete, the main script is not left behind as a misleading installed copy. The temporary download is removed when the command finishes. After a successful fresh installation, **Quick Setup opens automatically** to configure protection. If you cancel, the regular menu opens and Quick Setup remains selectable until onboarding is finished.

A normal launch of an uninitialized script also runs the same installation checks, then opens Quick Setup once. Later launches of an installed but incompletely configured script show the regular menu with Quick Setup available to resume. To install explicitly from an existing script at its final location, run:

```sh
sh /jffs/addons/ResolvGuard.d/resolvguard.sh install
```

### 3. Complete Quick Setup

Installation checks for `dig` first and offers to install the required Entware `bind-dig` package with your confirmation. Quick Setup checks again if needed. If Entware itself is missing, install Entware through `amtm` first.

Quick Setup guides you through:

1. **Preferred DNS:** Review your current Strict DoT resolvers and save them as your preferred DNS configuration.
2. **Resolver options:** Review available alternative resolver groups and optionally add backup DNS providers.
3. **Health checks:** Use the default check or create checks that match the DNS responses you expect.
4. **Protection:** Choose scheduled monitoring without WAN changes, or explicitly authorize automatic DNS failover.

**ResolvGuard does not start automatically changing WAN DNS just because you installed it.** Automatic failover requires your approval.

**Onboarding completion:** Once the wizard finishes, ResolvGuard saves a small `state/quick-setup-complete` record. This is independent of the installation marker and does not authorize DNS changes. Upgrading an earlier installation without that record may show Quick Setup once; existing DNS settings are preserved, and you can manage them from the normal menu.

## Using ResolvGuard

To open the SSH menu at any time:

```sh
sh /jffs/addons/ResolvGuard.d/resolvguard.sh
```

The main menu includes:

| Menu option | What it does |
| --- | --- |
| **Quick Setup (Complete Initial Setup)** | Appears only before onboarding completes, to resume cancelled first-time setup. After successful setup it disappears. |
| **Automatic DNS Failover** | Enable or disable automatic switching with the required confirmations. |
| **View Status** | See the current DNS pool, monitoring mode, and protection status. |
| **Check DNS Health Now** | Run a manual, read-only health check. |
| **Inspect Live DNS** | Examine DNS answers and optionally save a health check. |
| **Advanced Options** | Manage DNS settings, monitoring, policy approval, updates, dependency setup, recovery, and uninstall. |

After initial setup, change all DNS checks, pools, backup resolvers, policy approval and monitoring choices through their dedicated menu options. Quick Setup does **not** reappear on the main menu, but you can deliberately rerun the wizard at any time with the `quick-setup` CLI command. The add-on records onboarding separately from installation; automatic failover still requires explicit approval.

Press **`e`** to leave a menu or exit ResolvGuard.

### Monitoring Only or Automatic Failover?

**Monitoring Only** is a good way to get started. ResolvGuard checks your DNS providers on a schedule and records the results, but does not automatically modify the WAN DNS settings.

**Automatic Failover** adds the ability to respond to confirmed resolver failures. With your approval and the necessary safety checks, ResolvGuard can temporarily exclude an unhealthy preferred resolver while keeping healthy endpoints in service. Once the failed resolver recovers, it can return to the preferred pool.

ResolvGuard changes the router's **upstream DNS resolver pool** when authorized. Health-check hostnames are used to assess resolver behavior; they are not routed through separate DNS servers on a per-domain basis.

### Working with DNS health checks

You can use **Inspect Live DNS** to explore the results returned by your resolvers and save selected observations as checks.

For example, a health check can specify:

| Field | Example |
| --- | --- |
| Hostname | `example.com` |
| Record type | `A` |
| Expected response | `NOERROR` |
| Expected answer count | `ANY` |
| Expected data | `-` (no specific value required) |

Checks can also validate other supported record types, expected response codes, and specific answer data. This is especially useful when an application depends on a particular DNS response rather than simple resolver reachability.

## Useful SSH commands

You can perform common tasks without opening the menu:

```sh
sh /jffs/addons/ResolvGuard.d/resolvguard.sh status                # Show DNS and protection status
sh /jffs/addons/ResolvGuard.d/resolvguard.sh check                 # Run a DNS health check now
sh /jffs/addons/ResolvGuard.d/resolvguard.sh probe example.com A   # Inspect an A-record response
sh /jffs/addons/ResolvGuard.d/resolvguard.sh schedule status       # Show scheduled monitoring status
sh /jffs/addons/ResolvGuard.d/resolvguard.sh schedule enable       # Enable scheduled monitoring
sh /jffs/addons/ResolvGuard.d/resolvguard.sh schedule logs         # View recent monitoring results
sh /jffs/addons/ResolvGuard.d/resolvguard.sh schedule disable      # Disable scheduled monitoring
sh /jffs/addons/ResolvGuard.d/resolvguard.sh install               # Verify or complete installation
sh /jffs/addons/ResolvGuard.d/resolvguard.sh quick-setup           # Resume setup or explicitly rerun the wizard
sh /jffs/addons/ResolvGuard.d/resolvguard.sh help                  # Show all available commands
```

Use **Advanced Options → Monitoring, Diagnostics & Logs** for monitoring details and logs through the menu.

## Checking for updates

ResolvGuard has its updater built into the main script. From the SSH menu, open:

**Advanced Options → Maintenance & Recovery → Check for Updates**

Or use SSH:

```sh
sh /jffs/addons/ResolvGuard.d/resolvguard.sh amtmupdate status   # Check GitHub for a newer version (no installation)
sh /jffs/addons/ResolvGuard.d/resolvguard.sh amtmupdate          # Install an available update (AMTM invocation)
```

**For AMTM integration:** `amtmupdate check` is a *capability probe*, **not** a GitHub version check. AMTM calls it to determine whether the installed add-on supports updating; it quietly returns exit status `0` for a completed installation, or a nonzero status otherwise. The probe performs no download, configuration changes, or update.

```sh
sh /jffs/addons/ResolvGuard.d/resolvguard.sh amtmupdate check    # AMTM support probe; inspect the exit status
```

When an update is available, the updater downloads the script over HTTPS, validates it, and replaces **only `resolvguard.sh`**. Your DNS checks, provider settings, saved preferred configuration, and recovery state are kept in place.

### Release integrity and branches

Official GitHub Releases include `ResolvGuard-install.sh`, `ResolvGuard-update.sh`, and `MD5SUMS` (matching MerlinAU). The workflow verifies `MD5SUMS` when building the release. The tracked `main/resolvguard.sh` and downloadable release assets are stamped `SCRIPT_BRANCH="master"`; the `dev` branch retains `SCRIPT_BRANCH="dev"` for development updates. The built-in updater downloads scripts over HTTPS and validates script identity, version, branch, syntax, and replacement integrity without fetching or requiring a checksum manifest. MD5 is provided for release file checks, not as a security/authenticity guarantee.

## Uninstallation

You can uninstall ResolvGuard through:

**Advanced Options → Maintenance & Recovery → Uninstall ResolvGuard**

Or use:

```sh
sh /jffs/addons/ResolvGuard.d/resolvguard.sh uninstall
```

ResolvGuard checks that your preferred DNS configuration is safely restored or already active before removing its own files, scheduled job, and startup integration. If DNS recovery needs attention, it will stop the removal rather than risk leaving your router in an uncertain DNS state.

## Troubleshooting

### Quick Setup can't find Strict DNS-over-TLS

Check your router's **WAN → Internet Connection → DNS Privacy Protocol** settings. Make sure **Strict** is selected and your authenticated DNS servers are working before running Quick Setup again.

### DNS health checks can't run

Verify that Entware is available and `dig` is installed:

```sh
/opt/bin/dig -v
```

Then run a manual check to view the result:

```sh
sh /jffs/addons/ResolvGuard.d/resolvguard.sh check
```

### Scheduled monitoring isn't running

Check the schedule status and recent logs:

```sh
sh /jffs/addons/ResolvGuard.d/resolvguard.sh schedule status
sh /jffs/addons/ResolvGuard.d/resolvguard.sh schedule logs
```

Also confirm that JFFS custom scripts are enabled and the router has completed startup and time synchronization.

### Automatic failover isn't switching

Open **View Status** and review your DNS health results. Automatic switching requires explicit approval, confirmed failures, and an acceptable destination resolver pool. Monitoring Only deliberately leaves the router's WAN DNS unchanged.

### ResolvGuard reports a recovery or DNS-operation hold

Use **Advanced Options → Maintenance & Recovery → Restore Enrolled Preferred WAN DNS** to restore the preferred DNS configuration. Avoid forcing changes or manually deleting lock and recovery files while an operation is in progress.

**Important:** Files such as `/tmp/resolv.dnsmasq`, `/tmp/resolv.conf`, and `/tmp/resolv.dnsmasq.sdn*` belong to ASUS firmware. They are not ResolvGuard files and should not be removed as part of add-on maintenance.

## License, project and trademarks

ResolvGuard is free and open-source software released under the **[GNU General Public License v3.0](LICENSE)**, with [additional GPLv3 Section 7 terms](ADDITIONAL_TERMS.md) for applicable material.

Official project: **[ExtremeFiretop/ResolvGuard](https://github.com/ExtremeFiretop/ResolvGuard)**  
Project creator: **[@ExtremeFiretop](https://github.com/ExtremeFiretop)**

**ResolvGuard™** identifies the official project. Forking and modifying the GPL-licensed code are permitted; independently maintained forks must not misrepresent themselves as official releases. See the [trademark policy](TRADEMARKS.md).

## Feedback and contributions

Have an idea, found a bug, or encountered unusual DNS-provider behavior? Feedback and contributions are welcome through the project's [GitHub Issues](https://github.com/ExtremeFiretop/ResolvGuard/issues) and the Asuswrt-Merlin community.

When reporting a problem, include the router model, firmware version, what you were doing, and any relevant **sanitized** diagnostic output. Please remove private hostnames, IP addresses, and other sensitive information before posting logs.

**Use at your own discretion.** Changes to router-wide DNS affect network connectivity. Review your DNS settings and start with Monitoring Only if you're new to ResolvGuard.
