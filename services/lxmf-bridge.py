import os
import sys
import time
import json
import signal

import RNS
import LXMF
import requests
from stem.control import Controller
from stem.connection import authenticate_safecookie

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from clboss_parser import CLBOSSStatus, extract_msat_value

# Configuration
BASE_DIR = os.path.dirname(os.path.abspath(__file__))
BASTION_DIR = os.path.join(BASE_DIR, "../")
BASTION_CONFIG = os.path.join(BASTION_DIR, "bastion.conf")
STORAGE_PATH = os.path.join(BASTION_DIR, "venv/rns_data")
IDENTITY_FILE = os.path.join(STORAGE_PATH, "my_identity.rs")
TOR_COOKIE_PATH = os.path.join(BASTION_DIR, "stack-bitcoin/data/tor/control_auth_cookie")

# Get environment variables from bastion.conf
with open(BASTION_CONFIG, "r") as f:
    for line in f:
        if "=" in line and not line.strip().startswith("#"):
            name, value = line.strip().split("=", 1)
            os.environ[name] = value

# Whitelist allowed identity from bastion.conf (hex string without 0x prefix)
ALLOWED_IDENTITY = os.getenv("LXMF_ALLOWED_IDENTITY", "").strip()

# Runtime constants
RNS_LOG_LEVEL = 6
TOR_CONTROL_HOST = "127.0.0.1"
TOR_CONTROL_PORT = 9051
TOR_SOCKS_PROXY = "socks5h://127.0.0.1:9050"
TARGET_IP = "10.0.0.1"
RETICULUM_PORT = 4242
RNS_IDENTITY_DISPLAY_NAME = "Bastion Bridge"
MEMPOOL_API_URL = "https://mempool.space/api/v1/lightning/nodes/{}"
MEMPOOL_NODE_URL = "https://mempool.space/es/lightning/node/{}"
ONION_KEY_TYPE = "ED25519-V3"

# Persistent requests session for repeated Tor SOCKS usage
TOR_REQUESTS_SESSION = requests.Session()
TOR_REQUESTS_SESSION.proxies.update({
    'http': TOR_SOCKS_PROXY,
    'https': TOR_SOCKS_PROXY,
})
TOR_REQUESTS_SESSION.headers.update({'User-Agent': 'Mozilla/5.0'})

# Use this to debug the packet lifecycle
RNS.loglevel = RNS_LOG_LEVEL 

# Globales para limpieza
tor_controller = None
current_service_id = None
is_shutting_down = False

def cleanup_service():
    """Delete the ephemeral hidden service on exit to avoid orphaned services in Tor."""
    global tor_controller, current_service_id

    if tor_controller and current_service_id:
        print(f"\n[*] Cleaning up Tor hidden service with ID: {current_service_id}")
        try:
            # Delete by .onion address (service_id) to ensure we target the correct one
            tor_controller.remove_ephemeral_hidden_service(current_service_id)
            print("[+] Hidden service removed successfully.")
        except Exception as e:
            print(f"[!] Failed to remove hidden service: {e}")
    else:
        print("\n[*] No active Tor hidden service to clean up.")

def signal_handler(sig, frame):
    """Capture signals like SIGTERM or SIGINT"""
    global is_shutting_down

    if not is_shutting_down:
        is_shutting_down = True

        print(f"\n[!] SIGTERM received. Initiating graceful shutdown...")
        cleanup_service()

    # Call RNS signal handlers to ensure proper shutdown of the router and related threads
    if router:
        router.sigterm_handler(sig, frame)

def setup_onion():
    """
    Configures a PERSISTENT Hidden Service for Reticulum.
    The .onion address remains the same by loading/saving the private key locally.
    """
    global tor_controller, current_service_id

    control_port = TOR_CONTROL_PORT
    control_host = TOR_CONTROL_HOST
    
    # Target configuration
    target_ip = TARGET_IP
    reticulum_port = RETICULUM_PORT
    target_address = f"{target_ip}:{reticulum_port}"
    
    # Local path to store your key (outside Docker)
    key_file_path = os.path.join(STORAGE_PATH, "onion_v3_key")

    try:
        tor_controller = Controller.from_port(address=control_host, port=control_port)

        # 1. Authenticate
        if os.path.exists(TOR_COOKIE_PATH):
            authenticate_safecookie(tor_controller, TOR_COOKIE_PATH)
            tor_controller._post_authentication()
            # controller.authenticate()  # Using default method which should work if Tor is configured properly
            print("[*] Authenticated to Tor control port successfully.")
        else:
            print(f"[!] Cookie not found at {TOR_COOKIE_PATH}")
            return None

        # 2. Persistence Logic: Load existing key or prepare to create a new one
        key_type = "NEW"
        key_content = ONION_KEY_TYPE # Current standard for v3 addresses

        if os.path.exists(key_file_path):
            with open(key_file_path, "r") as f:
                key_content = f.read().strip()
                key_type = "ED25519-V3"
            print("[*] Loading existing persistent key...")

        # 3. Create/Restore the Hidden Service
        # Even if it says 'ephemeral', providing the key makes it persistent.
        print("[*] Establishing Hidden Service identity...")
        response = tor_controller.create_ephemeral_hidden_service(
            {reticulum_port: target_address},
            key_type = key_type,
            key_content = key_content,
            await_publication = True
        )

        # 4. Save the key if it was generated for the first time
        if key_type == "NEW":
            with open(key_file_path, "w") as f:
                f.write(response.private_key)
            print(f"[*] New persistent key saved to {key_file_path}")

        onion_address = f"{response.service_id}.onion"
        current_service_id = response.service_id
        print(f"[+] Node reachable at: {onion_address}:{reticulum_port} -> {target_address}")

        return onion_address

    except Exception as e:
        print(f"[!] Failed to establish persistent Onion: {e}")
        return None

def get_node_alias(node_id: str) -> str:
    """Fetch node alias from mempool.space API over Tor SOCKS proxy."""
    try:
        url = MEMPOOL_API_URL.format(node_id)
        response = TOR_REQUESTS_SESSION.get(url, timeout=10)
        response.raise_for_status()
        data = response.json()
        alias = data.get('alias', node_id[:14])
        return alias if alias else node_id[:14]
    except (requests.RequestException, json.JSONDecodeError, Exception):
        # Return truncated node_id if API call fails
        return node_id[:14]

def get_mempool_link(node_id: str) -> str:
    """Generate mempool.space link for a node"""
    return MEMPOOL_NODE_URL.format(node_id)

def init_lxmf():
    global router, identity, delivery_identity
    RNS.Reticulum(configdir=STORAGE_PATH)

    if os.path.exists(IDENTITY_FILE):
        identity = RNS.Identity.from_file(IDENTITY_FILE)
    else:
        identity = RNS.Identity()
        identity.to_file(IDENTITY_FILE)
    
    router = LXMF.LXMRouter(identity, storagepath=STORAGE_PATH)
    
    # Registration
    delivery_identity = router.register_delivery_identity(identity, display_name="Bastion Bridge")
    router.announce(delivery_identity.hash)
    router.enable_propagation()

    # Correct callback registration
    router.register_delivery_callback(received_message)
    
    print(f"--- LXMF NODE INITIALIZED ---")
    print(f"Identity: {identity.hash.hex()}")
    print(f"Storage: {STORAGE_PATH}")
    print(f"Delivery Identity: {delivery_identity.hash.hex()}")
    return router, identity, delivery_identity

def received_message(message: LXMF.LXMessage):
    global router, identity, delivery_identity

    peer_id = message.source_hash.hex()[:8]
    print(f"\n[!] Message received from {peer_id}")

    if message.source_hash.hex() != ALLOWED_IDENTITY:
        print(f"[!] Unauthorized peer: {peer_id}")
        return  # Ignore messages from unrecognized nodes

    # IMPORTANT: To reply, the destination MUST be the hash of who sent the message
    # and the type must be a response so RNS accepts it as such.
    sender_hash = message.source_hash
    title = "Reply"

    # 1. Define the destination (the original sender)
    destination = RNS.Destination(
        RNS.Identity.recall(sender_hash),
        RNS.Destination.OUT, 
        RNS.Destination.SINGLE, 
        "lxmf", 
        "delivery"
    )

    # Command logic
    content = message.content.decode('utf-8').lower().strip()
    
    if content == "clboss-status":
        try:
            output = os.popen("docker exec lightningd lightning-cli clboss-status").read()
            clboss = CLBOSSStatus(output)
            
            title = "⚡ CLBoss Report"
            
            # Build mobile-optimized response
            response = "\n⚡ CLN STATUS ⚡\n\n"
            
            # Node status
            online_status = "🟢 ONLINE" if clboss.is_online() else "🔴 OFFLINE"
            response += f"{online_status} {clboss.version_info.version}\n"
            response += "─" * 20 + "\n\n"
            
            # Uptime
            response += "⏱️  UPTIME\n"
            response += f"  3d: {clboss.uptime.past_3_days*100:.1f}%\n"
            response += f"  2w: {clboss.uptime.past_2_weeks*100:.1f}%\n"
            response += f"  1m: {clboss.uptime.past_1_month*100:.1f}%\n\n"
            
            # Peers and channels
            response += "👥 PEERS & CHANNELS\n"
            response += f"📊 Total channels: {clboss.get_peer_count()}\n"
            response += f"🔗 Channel candidates: {clboss.get_channel_candidates_count()}\n"

            best_candidates = clboss.get_best_channel_candidates(3)
            if best_candidates:
                response += "\n🏆 Top 3 Candidates:\n"
                for i, cand in enumerate(best_candidates, 1):
                    online_pct = cand.onlineness / 24
                    emoji = "🥇" if i == 1 else "🥈" if i == 2 else "🥉"
                    alias = get_node_alias(cand.id)
                    link = get_mempool_link(cand.id)

                    # Only show link if no alias was found (fallback to truncated ID)
                    if alias == cand.id[:14]:
                        response += f"{emoji} {online_pct:.0%}\n"
                        response += f"{link}\n"
                    else:
                        response += f"{emoji} {online_pct:.0%} {alias}\n"
            response += "\n"
            
            # Earnings
            response += "💰 EARNINGS\n"
            total_earnings = clboss.get_total_earnings()
            if total_earnings:
                in_sats = total_earnings.in_earnings / 1000
                routed_sats = total_earnings.in_forwarded / 1000
                routed_btc = routed_sats / 100_000_000
                response += f"📈 Routed: {routed_btc:>7,.8f} btc\n"
                response += f"💸 Earned Fees: {in_sats:>7,.0f} sat\n"

            # On-chain fees
            response += "⛓️ On-chain Fees: " + clboss.onchain_feerate.judgment + "\n\n"

            # Swap stats
            swap_stats = clboss.get_swap_stats()
            response += f"🔄 SWAPS ACTIVITY (#{swap_stats['total_swaps']})\n"
            response += f"📉 Loss: {swap_stats['percent_loss']}\n"
            swapped_sats = extract_msat_value(swap_stats['total_sent']) / 1000
            swapped_btc = swapped_sats / 100_000_000
            response += f"📊 Swapped: {swapped_btc:>7,.8f} btc\n"
            total_loss_msat = extract_msat_value(swap_stats['total_loss'])
            loss_sats = total_loss_msat / 1000
            response += f"💸 Sats Loss: {loss_sats:,.0f} sat\n"

        except Exception as e:
            title = "Error"
            response = f"Failed to parse status: {str(e)}"
    elif content == "ping":
        title = "Pong"
        response = "Pong from Bastion!"
    elif content == "cln-logs":
        try:
            # Fetches the last 20 lines from the lightningd container logs
            title = "📜 CLN Last Logs"
            logs_output = os.popen("docker logs --tail 20 lightningd 2>&1").read()
            
            if not logs_output.strip():
                response = "No logs found or container is silent."
            else:
                # We wrap the logs in a code-like format for better readability in Columba
                response = f"Last 20 lines:\n\n{logs_output}"
        except Exception as e:
            title = "Error"
            response = f"Failed to fetch logs: {str(e)}"

    elif content == "rns-info":
        try:
            title = "🌐 Reticulum & LXMF Status"
            
            # Extracting stats from the router instance
            msgs_stored = len(router.propagation_entries)
            peers_count = len(router.peers)
            
            # Calculate uptime if the node is running as a propagation node
            if router.propagation_node_start_time:
                uptime_seconds = time.time() - router.propagation_node_start_time
                uptime_str = RNS.prettytime(uptime_seconds)
            else:
                uptime_str = "N/A"

            response = (
                f"⏱ Uptime: {uptime_str}\n"
                f"👥 Connected Peers: {peers_count}\n"
                f"📦 Messages in Store: {msgs_stored}\n"
                f"🔑 Identity: {identity.hash.hex()[:16]}..."
            )
        except Exception as e:
            title = "Error"
            response = f"Failed to fetch RNS stats: {str(e)}"

    elif content == "help":
        title = "📖 Available Commands"
        response = (
            "Bastion Bridge Commands:\n\n"
            "• clboss-status: Full node optimization report\n"
            "• cln-logs: View last 20 log entries from CLN\n"
            "• rns-info: Status of the LXMF Propagation Node\n"
            "• ping: Quick connectivity test"
        )

    else:
        title = "Error"
        response = f"Command not recognized."

    # 3. Build the message
    time.sleep(1)  # Ensure we reply after any potential ordering issues
    reply_message = LXMF.LXMessage(
        destination, 
        delivery_identity,
        response,
        title=title,
        desired_method=LXMF.LXMessage.DIRECT
    )
    
    # 4. Force send
    # Here's the trick: Sometimes we need to ensure the router 
    # has the path to the destination before sending.
    router.handle_outbound(reply_message)
    print(f"[*] Response processed and sent to {message.source_hash.hex()[:8]}")

if __name__ == "__main__":
    setup_onion()
    router: LXMF.LXMRouter
    router, node_identity, delivery_identity = init_lxmf()

    # Register the signals at startup
    signal.signal(signal.SIGTERM, signal_handler)
    time.sleep(60)

    # Keepalive loop
    while True:
        # Re-announce delivery identity every hour to ensure it stays active in the network
        router.announce(delivery_identity.hash)
        router.announce_propagation_node()
        time.sleep(3600)
