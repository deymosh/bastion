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
# Time to wait before retrying a migration for the same peer (1 hour)
RETRY_TIMEOUT = 3600

def get_address_type(addrstr: str):
    if ".onion" in addrstr:
        return "tor"
    if addrstr and addrstr[0].isdigit():
        return "ipv4"
    if addrstr and addrstr.startswith("["):
        return "ipv6"
    return "unknown"

def onion_pid(peer: dict, source: str = "unknown"):
    global failed_migrations

    peer_id = peer["id"]
    now = time.time()

    # Check if we already tried and failed recently to avoid the loop
    if peer_id in failed_migrations:
        if now - failed_migrations[peer_id] < RETRY_TIMEOUT:
            plugin.log(f"Skipping {peer_id}: cooling-off period ({source})")
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
        return False

    onion_addrs = [a for a in nodes[0]["addresses"] if "tor" in a["type"]]

    if not onion_addrs:
        plugin.log(f"No Tor address found for {peer_id} ({source})")
        return False

    # Pick the first onion address found
    addr = onion_addrs[0]
    target = f"{peer_id}@{addr['address']}:{addr['port']}"
    original_target = f"{peer_id}@{current_addr}"

    plugin.log(f"Migrating {peer_id} to Tor: {target} ({source})")
    success = False

    # Record the failure timestamp before attempting migration to prevent loops if it fails again
    failed_migrations[peer_id] = now

    try:
        # 1. Force disconnect from clearnet
        plugin.rpc.disconnect(peer_id, force=True)
        plugin.log(f"Disconnected {peer_id} from clearnet ({source})")

        # 2. Reconnect via Tor
        result = plugin.rpc.connect(target)
        plugin.log(f"Attempted to connect {peer_id} via Tor ({source})")

        # 3. Verify if the connection is now via Tor
        if result.get("id") == peer_id and get_address_type(result["address"]["address"]) == "tor":
            success = True
            
            # If successful, remove from failed list
            failed_migrations.pop(peer_id, None)
            plugin.log(f"Migrated {peer_id} to Tor! ({source})")

    except RpcError as e:
        plugin.log(f"RPC error during migration of {peer_id} to Tor: {e.error} ({source})")
        success = False

    if not success:
        plugin.log(f"Failed to migrate {peer_id} to Tor! ({source})")

        try:
            plugin.rpc.connect(original_target)  # Attempt to reconnect to original address
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
        peer_id = peer["id"]

        is_cooling_off = peer_id in failed_migrations and time.time() - failed_migrations[peer_id] < RETRY_TIMEOUT

        if not is_onion and is_cooling_off:
            plugin.log(f"Clearnet peer {peer_id} detected, skipping due to cooling-off period (method)")
        elif not is_onion:
            plugin.log(f"Clearnet peer {peer_id} detected, evaluating Tor migration (method)")
            t = threading.Thread(target=onion_pid, args=(peer, "method"))
            t.start()
        else:
            plugin.log(f"Darknet peer {peer_id} detected (method)")

    return {"status": "Migration triggered", "peers_processed": len(peers)}

@plugin.hook("peer_connected")
def on_peer_connected(peer, plugin: Plugin, **kwargs):
    # Detect address type from the connection
    addr_val = peer.get('netaddr', [peer.get('addr', 'unknown')])[0]
    is_onion = get_address_type(addr_val) == "tor"
    peer_id = peer["id"]

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
    plugin.log("Darknet plugin initialized")

if __name__ == "__main__":
    plugin.run()