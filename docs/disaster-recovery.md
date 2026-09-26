# Disaster recovery

How to recover a Bastion node after data loss, and how to move it to a new host.
Read this **before** you need it.

## 1. What is irreplaceable, and what is disposable

| Path | Contains | If lost |
|---|---|---|
| `stack-bitcoin/data/cln/hsm_secret` | The CLN wallet seed. | **Total loss.** On-chain funds cannot be swept and channels cannot be closed. Without a backup there is no recovery. |
| `stack-bitcoin/data/cln/lightningd.sqlite3` | Channel state, payments, the node database. | At best, every channel is force-closed. If a stale copy is restored while a peer has newer state, the peer can claim a penalty and **the funds are stolen**. |
| `/mnt/backup_cln/lightningd.sqlite3` | The live replica. CLN writes every database transaction here as well (`wallet=` in `cln_config`); inside the container the drive is `/backup_usb`. | Your primary source for restoring the database. Keep the drive healthy. |
| `stack-bitcoin/data/cln/emergency.recover` | CLN's Static Channel Backup (SCB). | Lets peers help you force-close after a full database loss. `bastion-daemon.sh` mirrors it to `$BACKUP_DEST/emergency.recover.live` on every change and keeps 30 daily snapshots in `$BACKUP_DEST/history/`. |
| `stack-bitcoin/data/teos/` | The watchtower's tower key (only if you run `teosd`). | The tower gets a new identity and clients must re-register. No funds are lost. |
| `bastion.conf` + `secrets/` | Generated config and secrets (git-ignored). | `./bastion` regenerates them, but you have to re-enter the WireGuard host and port, the node alias and any tokens. Back them up. |
| `stack-ai/data/` | CCR login, CodeDeck identity and pairings. | Log in and pair again. No funds are lost. |
| `bastion-tor-data` volume | Tor's `DataDirectory`. | **Disposable.** It is recreated on the next start. |
| `stack-bitcoin/data/cln/.../gossip_store` | The gossip graph. | **Disposable.** It rebuilds from the network. |

**The `.onion` is stable.** CLN uses `statictor:` (`stack-bitcoin/config/cln_config`),
so the hidden-service key is derived from `hsm_secret`, not from Tor's data
directory or `bind-addr`. A rebuild or a host move keeps the **same** `.onion`,
so there is nothing to re-announce and no inbound connections are lost.

## 2. Back up now, and on a schedule

With the node stopped cleanly (`./bastion stop bitcoin`; `bitcoind` gets its
full 5-minute grace period):

```bash
tar -czf bastion-backup-$(date +%F).tgz \
    stack-bitcoin/data/cln \
    stack-bitcoin/data/teos \
    bastion.conf secrets/
```

Store the archive off the host, encrypted. The backup drive already holds a
live database replica (written by CLN) and the SCB (written by the daemon). This
archive is the point-in-time complement, and unless you made another copy it is
the only backup of `hsm_secret`.

## 3. Restore on the same host

1. `./bastion down`, then check that `./bastion ps` shows `lightningd` and
   `bitcoind` as absent.
2. Restore the tree:
   ```bash
   tar -xzf bastion-backup-<date>.tgz
   ```
   Use the **newest** `lightningd.sqlite3` you have. The replica on the backup
   drive is usually newer than an archive. **Never** restore a database older
   than the one the node last ran with: a peer with newer channel state can
   broadcast a penalty and take the channel balance.
3. `chown` the restored `data/` back to the host user if needed.
4. `./bastion up`.
5. Work through the [verification checklist](#5-verification-checklist).

## 4. Move to a new host

1. On the new host, install Docker Engine with the Compose plugin, then
   `git clone --recurse-submodules` this repository at the same commit.
2. Copy `stack-bitcoin/data/cln`, `stack-bitcoin/data/teos`, `bastion.conf` and
   `secrets/` from the old host, stopped cleanly (see §2). **Stop the old node
   for good before you start the new one.**
3. Mount the backup drive at `BACKUP_DEST`, then `./bastion up`. Networks and
   the `bastion-tor-data` volume are recreated empty; that is expected.
4. The node comes back on the **same `.onion`**. `trustedcoin` re-syncs block
   headers (a few minutes). Peers reconnect on their own, or when you
   `lightning-cli connect` them.
5. Keep the old host's `data/` copy until the new host has run stably for a few
   days, then decommission it.

## 5. Verification checklist

```bash
./bastion exec lightningd -- lightning-cli getinfo
```
- `id` is unchanged, and `address` shows the **same `.onion`** as before.
- `blockheight` is advancing (trustedcoin has synced).

```bash
./bastion exec lightningd -- lightning-cli listpeerchannels   # channels present, expected states
./bastion exec lightningd -- lightning-cli listfunds          # on-chain + channel balances match
./bastion exec lightningd -- lightning-cli listpeers          # peers reconnecting / connected
```
- RTL loads at `http://<host>:3000`. The rune in `stack-bitcoin/data/rtl/access.rune`
  belongs to this node and survives a restore.
- If you run `teosd`, `./bastion logs teosd` shows the tower registered its
  onion.

## 6. Never

- **Never** roll `lightningd.sqlite3` back to a copy older than the one the node
  last used (penalty and theft risk).
- **Never** run two copies of the same `hsm_secret` and database against the
  network at once, for example old host and new host both up. That is the
  classic way to get penalised.
- **Never** run `docker volume prune` or `docker system prune --volumes` on this
  host. CLN's state is in bind mounts under `data/`, but the habit will
  eventually hit a named volume that matters.
