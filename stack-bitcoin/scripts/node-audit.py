import subprocess
import json

# ANSI Color Codes
GREEN = "\033[92m"
RED = "\033[91m"
CYAN = "\033[96m"
YELLOW = "\033[93m"
BOLD = "\033[1m"
RESET = "\033[0m"

def fetch_bkpr_data():
    """Fetches accounting data from Core Lightning inside Docker."""
    try:
        cmd = ["docker", "exec", "clightning", "lightning-cli", "bkpr-listaccountevents"]
        process = subprocess.run(cmd, capture_output=True, text=True, check=True)
        return json.loads(process.stdout)
    except Exception as e:
        print(f"{RED}Error: Could not communicate with CLN container. {e}{RESET}")
        return None

def run_audit():
    data = fetch_bkpr_data()

    if not data or 'events' not in data:
        print(f"{RED}Error: No event data available.{RESET}")
        return

    income_msat = 0
    expense_msat = 0
    
    for event in data['events']:
        fees = event.get('fees_msat', 0)
        if not isinstance(fees, (int, float)) or fees == 0:
            continue

        # 1. Routing Income (Fees from others) - filtered by 'credit_msat' > 0 to avoid double counting
        if event.get('tag') == 'routed' and event.get('credit_msat', 0) > 0:
            income_msat += fees
        
        # 2. Rebalance Expenses (Fees paid by us)
        if event.get('is_rebalance') is True:
            expense_msat += fees

    # Calculations
    net_msat = income_msat - expense_msat
    net_sats = net_msat / 1000
    
    efficiency = (income_msat / expense_msat) if expense_msat > 0 else 0
    margin = (net_msat / income_msat * 100) if income_msat > 0 else 0

    # Color logic for NET PROFIT
    status_color = GREEN if net_sats > 0 else RED

    # Bastion Output
    print("\n" + f"{CYAN}═{RESET}"*55)
    print(f"{BOLD}{CYAN}             BASTION NODE AUDIT REPORT{RESET}")
    print(f"{CYAN}═{RESET}"*55)
    print(f"{'Total Routing Income:':<30} {GREEN}{income_msat:>18,.0f} msat{RESET}")
    print(f"{'Total Rebalance Cost:':<30} {RED}{expense_msat:>18,.0f} msat{RESET}")
    print(f"{CYAN}─{RESET}"*55)
    print(f"{BOLD}{'NET PROFIT:':<30} {status_color}{net_sats:>18,.3f} sats{RESET}")
    print(f"{'PROFIT MARGIN:':<30} {status_color}{margin:>17.2f}%{RESET}")
    print(f"{'EFFICIENCY RATIO:':<30} {YELLOW}{efficiency:>17.2f}x{RESET}")
    print(f"{CYAN}═{RESET}"*55)

    if net_sats > 0:
        print(f" STATUS: {GREEN}{BOLD}PROFITABLE ✅{RESET} | Everything looks good!")
    else:
        print(f" STATUS: {RED}{BOLD}LOSS ❌{RESET} | Currently running at a loss.")

    print(f"{CYAN}═{RESET}"*55 + "\n")

if __name__ == "__main__":
    run_audit()