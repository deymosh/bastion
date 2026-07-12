#!/usr/bin/env -S uv run --script

# /// script
# requires-python = ">=3.9.2"
# dependencies = [
#    "pyln-client>=24.11"
# ]
# ///

from pyln.client import Plugin, RpcError
import threading
import time

plugin = Plugin()

# Global dictionary to track failed migrations and avoid infinite loops
# Structure: { peer_id: timestamp_of_failure }
failed_migrations = {}
migrations_lock = threading.Lock()
# Time to wait before retrying a migration for the same peer (1 hour)
RETRY_TIMEOUT = 3600
# If True, disallow clearnet connections (forced by plugin option)
DISALLOW_CLEARNET = False

def get_address_type(addrstr: str):
    if ".onion" in addrstr:
        return "tor"
    if addrstr and addrstr[0].isdigit():
        return "ipv4"
    if addrstr and addrstr.startswith("["):
        return "ipv6"
    return "unknown"


def disconnect_if_clearnet_disallowed(peer_id: str, current_addr: str, source: str = "unknown") -> bool:
    """If clearnet is disallowed and the peer appears to be clearnet (or address unknown),
    disconnect the peer and return True. Otherwise return False.
    """
    global DISALLOW_CLEARNET

    if not DISALLOW_CLEARNET:
        return False

    # If we can detect it's Tor, nothing to do
    if current_addr and get_address_type(current_addr) == "tor":
        return False

    try:
        plugin.rpc.disconnect(peer_id, force=True)
        plugin.log(f"Disconnected {peer_id} because clearnet is disallowed ({source})")
    except RpcError as e:
        plugin.log(f"Failed to disconnect {peer_id}: {e.error} ({source})")

    return True

def onion_pid(peer: dict, source: str = "unknown"):
    """Attempt to migrate a peer connection to Tor.

    This function will:
    - Check whether the peer is already connected via Tor and return True immediately if so.
    - Look up Tor (.onion) addresses in gossip (`listnodes`) and, if found, disconnect
      the current clearnet connection and attempt to connect to the Tor address.
    - Update `failed_migrations` to avoid tight retry loops.

    Returns:
      True if the peer was successfully migrated and is connected via Tor.
      False if migration did not succeed (or was not possible). Side effects include
      disconnection/connection RPCs and logging. The function respects the
      `DISALLOW_CLEARNET` option: when set, peers without Tor addresses are disconnected.
    """
    global failed_migrations
    global RETRY_TIMEOUT, DISALLOW_CLEARNET, migrations_lock

    peer_id = peer["id"]
    now = time.time()

    # Check if we already tried and failed recently to avoid the loop
    with migrations_lock:
        if peer_id in failed_migrations:
            if now - failed_migrations[peer_id] < RETRY_TIMEOUT:
                plugin.log(f"Skipping {peer_id}: cooling-off period ({source}), retry_timeout={RETRY_TIMEOUT}")
                return False

    # Verify if already on Tor
    current_addr = ""
    if "netaddr" in peer and peer["netaddr"]:
        current_addr = peer["netaddr"][0]
    elif "addr" in peer:
        current_addr = peer["addr"]

    if get_address_type(current_addr) == "tor":
        plugin.log(f"{peer_id} is already connected via Tor ({source})")
        return True

    # Search in gossip
    try:
        nodes = plugin.rpc.listnodes(peer_id)["nodes"]
    except RpcError:
        return False

    if not nodes or "addresses" not in nodes[0]:
        plugin.log(f"No address information found for {peer_id} ({source})")
        # If clearnet is disallowed and we don't have onion addresses, disconnect
        disconnect_if_clearnet_disallowed(peer_id, current_addr, source)
        return False

    onion_addrs = [a for a in nodes[0]["addresses"] if "tor" in a["type"]]

    if not onion_addrs:
        plugin.log(f"No Tor address found for {peer_id} ({source})")
        # If clearnet is disallowed, drop the connection
        disconnect_if_clearnet_disallowed(peer_id, current_addr, source)
        return False

    # Pick the first onion address found
    addr = onion_addrs[0]
    target = f"{peer_id}@{addr['address']}:{addr['port']}"
    original_target = f"{peer_id}@{current_addr}"

    plugin.log(f"Migrating {peer_id} to Tor: {target} ({source})")
    success = False

    # Record the failure timestamp before attempting migration to prevent loops if it fails again
    with migrations_lock:
        failed_migrations[peer_id] = now

    try:
        # 1. Force disconnect from clearnet
        plugin.rpc.disconnect(peer_id, force=True)
        plugin.log(f"Disconnected {peer_id} from clearnet ({source})")

        # 2. Reconnect via Tor
        result = plugin.rpc.connect(target)
        plugin.log(f"Attempted to connect {peer_id} via Tor ({source})")

        # 3. Verify if the connection is now via Tor
        address_info = result.get("address", {})
        address_str = address_info.get("address", "")

        if result.get("id") == peer_id and get_address_type(address_str) == "tor":
            success = True
            # If successful, remove from failed list
            with migrations_lock:
                failed_migrations.pop(peer_id, None)
            plugin.log(f"Migrated {peer_id} to Tor! ({source})")

    except RpcError as e:
        plugin.log(f"RPC error during migration of {peer_id} to Tor: {e.error} ({source})")
        success = False

    if not success:
        plugin.log(f"Failed to migrate {peer_id} to Tor! ({source})")
        # If clearnet is disallowed do not reconnect; otherwise attempt reconnect to original_target
        if DISALLOW_CLEARNET:
            plugin.log(f"Not reconnecting {peer_id} to clearnet because clearnet is disallowed ({source})")
        else:
            try:
                plugin.rpc.connect(original_target)  # Attempt to reconnect to original address
                plugin.log(f"Reconnected {peer_id} to original address after Tor failure ({source})")
            except RpcError as e:
                plugin.log(f"Failed to reconnect {peer_id} to original address after migration failure: {e.error} ({source})")

    return success

@plugin.method("darknet")
def darknet_method(plugin: Plugin, peer_id: str = None):
    """Force connection via Tor (Darknet) for all peers or a specific one."""
    try:
        peers = plugin.rpc.listpeers(peer_id)["peers"]
    except RpcError as e:
        return [f"Error fetching peers: {e.error}"]

    for peer in peers:
        addr_val = peer.get('netaddr', [peer.get('addr', 'unknown')])[0]
        is_onion = get_address_type(addr_val) == "tor"
        p_id = peer["id"]

        with migrations_lock:
            is_cooling_off = p_id in failed_migrations and time.time() - failed_migrations[p_id] < RETRY_TIMEOUT

        if not is_onion and is_cooling_off:
            plugin.log(f"Clearnet peer {p_id} detected, skipping due to cooling-off period (method)")
        elif not is_onion:
            plugin.log(f"Clearnet peer {p_id} detected, evaluating Tor migration (method)")
            t = threading.Thread(target=onion_pid, args=(peer, "method"))
            t.start()
        else:
            plugin.log(f"Darknet peer {p_id} detected (method)")

    return {"status": "Migration triggered", "peers_processed": len(peers)}

@plugin.hook("peer_connected")
def on_peer_connected(peer, plugin: Plugin, **kwargs):
    # Detect address type from the connection
    addr_val = peer.get('netaddr', [peer.get('addr', 'unknown')])[0]
    is_onion = get_address_type(addr_val) == "tor"
    peer_id = peer["id"]

    with migrations_lock:
        is_cooling_off = peer_id in failed_migrations and time.time() - failed_migrations[peer_id] < RETRY_TIMEOUT

    if not is_onion and is_cooling_off:
        plugin.log(f"Clearnet peer {peer_id} detected, skipping due to cooling-off period (hook)")
    elif not is_onion:
        plugin.log(f"Clearnet peer {peer_id} detected, evaluating Tor migration (hook)")
        t = threading.Thread(target=onion_pid, args=(peer, "hook"))
        t.start()
    else:
        plugin.log(f"Darknet peer {peer_id} detected (hook)")

    return {"result": "continue"}

@plugin.init()
def init(options: dict, configuration: dict, plugin: Plugin, **kwargs):
    global RETRY_TIMEOUT, DISALLOW_CLEARNET

    # Read and validate retry timeout option
    retry_opt = options.get("darknet-retry-timeout", None)
    if retry_opt is not None:
        try:
            RETRY_TIMEOUT = int(retry_opt)
        except (TypeError, ValueError):
            plugin.log(f"Invalid darknet-retry-timeout value: {retry_opt}, using default {RETRY_TIMEOUT}")

    # Read and normalize disallow-clearnet option
    disallow_opt = options.get("darknet-disallow-clearnet", False)
    if isinstance(disallow_opt, str):
        DISALLOW_CLEARNET = disallow_opt.lower() in ("1", "true", "yes", "on")
    else:
        DISALLOW_CLEARNET = bool(disallow_opt)

    if DISALLOW_CLEARNET:
        plugin.log("Clearnet connections are disallowed. All peers will be migrated to Tor if possible.")
    else:
        plugin.log("Clearnet connections are allowed. Peers will be migrated to Tor if possible.")

    plugin.log(f"Darknet plugin initialized (retry_timeout={RETRY_TIMEOUT}, disallow_clearnet={DISALLOW_CLEARNET})")

if __name__ == "__main__":
    plugin.add_option("darknet-disallow-clearnet", False, "Disallow clearnet connections and force Tor migration")
    plugin.add_option("darknet-retry-timeout", RETRY_TIMEOUT, "Time in seconds to wait before retrying a failed migration")

    plugin.run()