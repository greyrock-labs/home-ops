# Running commands on the ICX switches over SSH

## Workflow for a new or reset ICX

1. Todd pastes the switch's base config from the console.
2. Give him one console block that does only the addressing and access: static route,
   DHCP client off, static `ve 1` address, DNS, `write memory`, then
   `copy tftp flash <laptop ip> todd.pub ssh-pub-key-file` (key file in
   `/private/tftpboot` on his laptop). The `jumbo` reload, if needed, comes after.
3. Everything else is done directly over SSH, without him pasting output.

Check that nothing else holds the target address before assigning it: no ping reply is
not proof. A UniFi switch that kept `.12` once answered SSH in place of the ICX, which
showed up as two different host keys (ED25519 from the UniFi switch, ECDSA from the ICX).
List the UniFi device IPs from the UDM API (`stat/device`) while the UDM is still in
place. After moving a conflicting device, ping the gateway and APs from the ICX to
refresh their ARP entries.

After a firmware upgrade the switch updates its PoE firmware (`show logging | include PoE`
shows the progress). Send it nothing but read-only commands until then, and do not reload
it even once the log says the update is done: Todd gives the go-ahead for that reload.

A command Todd rejects may already have reached the switch. After a rejection, read the
affected config back before assuming nothing changed.

## How to run commands

A command given on the `ssh` command line returns nothing. Pipe the commands into an
interactive session with a forced TTY instead:

```sh
printf 'enable\nskip-page-display\nshow running-config\nexit\nexit\n' | command ssh -tt -o BatchMode=yes -o ConnectTimeout=5 10.1.0.12 2>&1 | tr -d '\r'
```

- `-tt` is required; without a TTY the CLI prints nothing.
- End every piped block with `exit` lines back out of the session, and wrap it in
  `timeout`. Without them the session stays open, and anything chained after it never runs.
- `command ssh` skips the Ghostty `ssh` wrapper, which tries to install terminfo on the
  switch.
- Login is by Todd's key from the agent; the username does not matter. `BatchMode=yes`
  makes a key failure exit instead of hanging on a password prompt.
- The session opens at `>`. `enable` needs no password, and `skip-page-display` only
  works after it.
- Config changes work the same way (`configure terminal` ... `end`, `write memory`).
- To confirm everything is saved, diff `show running-config` against
  `show configuration`; only the header line should differ.

## MikroTik CRS309s

Todd gives the switch its bridge, address, route and his key on `admin` in Winbox, from a
reset with no default config. After that, RouterOS runs a command passed on the `ssh`
line and returns its output; no TTY is needed:

```sh
command ssh -o BatchMode=yes admin@10.1.0.10 '/system resource print; /export'
```

Apply a backup by writing it as a `.rsc` (`set` on objects the first step created, `add`
for the rest), copying it with `scp -O`, and running `/import file-name=<file>`. Then diff
`/export` against the backup, and remove the `.rsc` from the switch. Changes persist as
they are made; there is no save step.
