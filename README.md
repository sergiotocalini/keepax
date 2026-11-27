<p align="center">
  <img src="assets/logo.svg" alt="keepax – Keepalived / VRRP monitoring for Zabbix" width="500">
</p>

# keepax

Zabbix Agent: Keepalived monitoring.

`keepax` is a small ksh script plus a Zabbix template. Together they watch the local
[keepalived](https://www.keepalived.org/) daemon and every VRRP instance it runs:

- **Process check**: is keepalived running at all? This uses the native `proc.num[keepalived]`, so it works even when the script fails.
- **VRRP auto-discovery**: every `vrrp_instance` is discovered automatically.
- **VRRP state**: `MASTER` / `BACKUP` / `FAULT` for each instance, with triggers on every transition.
- **Service uptime**: shows when the daemon was restarted.

The data comes from keepalived itself. The script sends `SIGUSR1` (data dump) and
`SIGUSR2` (stats dump) and parses `/tmp/keepalived.data` and `/tmp/keepalived.stats`.
It caches the result for `CACHE_TTL` minutes.

## Requirements

- Zabbix agent (`zabbix-agent2` or `zabbix-agent`) on the keepalived host
- Zabbix server **7.4** (`zbx7.4_template_app_keepalived.yaml`).
  A legacy Zabbix 3.4 XML export (`zbx3.4_template_app_keepalived.xml`) is kept for older servers.
- Linux with `ksh`, `procps` (`pkill`) and `sudo`. `deploy.sh` installs missing packages itself.

## Installation

On the monitored host:

```sh
git clone https://github.com/michalsarna/keepax.git
cd keepax
sudo ./deploy.sh
```

`deploy.sh` does the following:

1. Installs missing dependencies (`ksh`, `procps`, `sudo`) with apt, dnf, yum or zypper.
2. Detects the agent (`zabbix-agent2` first, then `zabbix-agent`) and its include directory.
3. Detects the keepalived pid file (`/run/keepalived.pid` or `/var/run/keepalived.pid`).
4. Installs the files:

   | Source                      | Destination                                                         |
   |-----------------------------|---------------------------------------------------------------------|
   | `keepax/keepax.sh`          | `/etc/zabbix/scripts/agentd/keepax/keepax.sh`                       |
   | *(generated)*               | `/etc/zabbix/scripts/agentd/keepax/keepax.conf` (`.conf.new` if one already exists) |
   | `keepax/zabbix_agentd.conf` | `/etc/zabbix/zabbix_agent2.d/keepax.conf` or `/etc/zabbix/zabbix_agentd.d/keepax.conf` |
   | *(generated)*               | `/etc/sudoers.d/zabbix-keepax` (validated with `visudo -c`)         |

5. Creates the cache directory, owned by the `zabbix` user.
6. Warns about common blockers: keepalived with `PrivateTmp=yes` (the dumps are not visible) and an agent with `NoNewPrivileges=yes` (`sudo` cannot work).
7. Restarts the agent and runs a self-test as `zabbix`: version, uptime, discovered VRRP instances and their state.

Options:

```text
-c DIR    cache directory           (default: /etc/zabbix/scripts/agentd/keepax/tmp)
-t MIN    cache TTL in minutes      (default: 5)
-p FILE   keepalived pid file       (default: auto)
-a NAME   agent: zabbix-agent2 | zabbix-agent (default: auto)
-u USER   zabbix agent user         (default: zabbix)
-d DIR    install prefix            (default: /etc/zabbix/scripts/agentd/keepax)
-n        do not restart the agent
-N        do not install missing packages
-U        uninstall
```

The generated sudoers rule allows only exact command lines, with no wildcards. It therefore also works with `sudo-rs`:

```sudoers
Cmnd_Alias KEEPAX = /usr/bin/pkill -USR1 -F /run/keepalived.pid, /usr/bin/pkill -USR2 -F /run/keepalived.pid, /usr/bin/cat /tmp/keepalived.data, /usr/bin/cat /tmp/keepalived.stats
zabbix ALL=(root) NOPASSWD: KEEPAX
```

Then import `zbx7.4_template_app_keepalived.yaml` in the Zabbix frontend
(*Data collection → Templates → Import*) and link **Template App Keepalived** to the host.

Quick check from the Zabbix server/proxy:

```sh
zabbix_get -s <host> -k 'proc.num[keepalived]'
zabbix_get -s <host> -k 'keepax.discovery[vrrp, NAME, list]'
zabbix_get -s <host> -k 'keepax[vrrp, data, "VI_1", "State"]'
```

## UserParameters

| Key                                         | Description                                   |
|---------------------------------------------|-----------------------------------------------|
| `keepax[service, uptime]`                   | keepalived uptime in seconds                  |
| `keepax.discovery[vrrp, NAME, list]`        | LLD of VRRP instances (`{#NAME}`)             |
| `keepax[vrrp, data, <instance>, <attr>]`    | attribute from the data dump, e.g. `State`    |
| `keepax[vrrp, stats, <instance>, <attr>]`   | attribute from the stats dump                 |
| `keepax.version`                            | script version                                |

## Template: Template App Keepalived

### Items

| Name                                              | Key                                              | Interval |
|---------------------------------------------------|--------------------------------------------------|----------|
| [Keepalived] Service: Process count               | `proc.num[keepalived]` (native agent item)       | 30s      |
| [Keepalived] Service: Uptime                      | `keepax[service, uptime]`                        | 10m      |
| [Keepalived] VRRP Instance "{#NAME}": State (LLD) | `keepax[vrrp, data, "{#NAME}", "State"]`         | 1m       |

The VRRP data is refreshed at most once every `CACHE_TTL` minutes (default 5),
so a state change can show up with that much delay.

### Triggers

| Name                                                        | Severity    | Expression (simplified)                         |
|-------------------------------------------------------------|-------------|-------------------------------------------------|
| Keepalived: Process is not running                          | High        | `last(proc.num[keepalived])=0`                  |
| Keepalived: Service has just been restarted                 | Information | `change(uptime)<0`                             |
| Keepalived: VRRP Instance "{#NAME}" changed state from BACKUP to MASTER | Average | `find(State,,"like","MASTER")=1 and find(State,#2,"like","BACKUP")=1` |
| Keepalived: VRRP Instance "{#NAME}" changed state from MASTER to BACKUP | Average | `find(State,,"like","BACKUP")=1 and find(State,#2,"like","MASTER")=1` |
| Keepalived: VRRP Instance "{#NAME}" is in FAULT state       | High        | `find(State,,"like","FAULT")=1`                 |
| Keepalived: VRRP Instance "{#NAME}" was MASTER but keepalived is not running | Disaster | `find(State,,"like","MASTER")=1 and last(proc.num[keepalived])=0` |

The transition triggers fire only on a real `BACKUP ↔ MASTER` flip between two
consecutive values, not when an instance first appears after a keepalived restart.
They are events: they fire on the poll that sees the new state and resolve on the next poll. They can also be closed manually.
The VRRP transition/FAULT triggers and the restart trigger **depend on "Process is not running"**,
so a dead daemon doesn't also raise a pile of state alerts.

If keepalived stops, `keepax.sh` keeps returning the **last known** VRRP data from its cache
instead of `0`. The State item then still shows the state the node had before the daemon
stopped. On a node that was MASTER this raises the **Disaster** trigger "was MASTER but
keepalived is not running" (alongside the High "Process is not running"). That is the moment
to check that a BACKUP node really took over the VIP. Once keepalived is back, the cache
refreshes on the next poll.

## Changelog

### 1.1.0
- `deploy_zabbix.sh` replaced by `deploy.sh`. It handles dependencies, agent detection, the cache dir, sudoers, restart and a self-test.
- `sudo` is used only for `pkill -USR1/-USR2 -F <pid file>` and `cat` of the two dump files. `mv` and `ps` no longer need root. `PID_FILE` is configurable in `keepax.conf`.
- One `awk` pass per query instead of chained `sed | grep | awk | awk` pipelines. There are no forks at all while the cache is fresh, apart from `stat` and `awk`.
- After signalling keepalived, the script waits (up to 2s) for a **fresh** dump instead of caching the previous one.
- Exact VRRP instance matching: `VI_1` no longer picks up `VI_10`. Data from other dump sections (e.g. sync groups) is no longer mixed into an instance.
- Keeps serving the last known VRRP data when keepalived is down.
- Empty discovery returns `"data":[]` instead of a bogus `{#NAME}="0"` entry.
- `ps` uses `etimes=` (no header). The help text is cleaned up.
- Runs under both `ksh` and `bash`.
- Config is the first existing file of `$KEEPAX_CONF`, `<script dir>/keepax.conf`, `/etc/zabbix/keepax.conf`.
- `sudo -n`: fails immediately instead of hanging on a password prompt.
- `data` / `stats` return one value (the first match), as a Zabbix item expects.

### 1.0.0
- Initial version.

## License

See [LICENSE](LICENSE).
