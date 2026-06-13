"""
CLBOSS Status Parser
Complete parser for clboss-status output from Core Lightning
Provides structured classes to safely and efficiently access data.
"""

import json
from typing import Dict, List, Optional, Any, Union
from dataclasses import dataclass
from enum import Enum


class ConnectionStatus(Enum):
    """Possible connection states"""
    ONLINE = "online"
    OFFLINE = "offline"
    UNKNOWN = "unknown"


class SwapperStatus(Enum):
    """Swapper status states"""
    IDLE = "idle"
    RUNNING = "running"
    ERROR = "error"
    UNKNOWN = "unknown"


class MonitorStatus(Enum):
    """Monitoring status states"""
    NOTICE = "notice"
    WARNING = "warning"
    ERROR = "error"
    UNKNOWN = "unknown"


@dataclass
class ChannelCandidate:
    """Channel candidate"""
    id: str
    onlineness: int

    @classmethod
    def from_dict(cls, data: Dict) -> 'ChannelCandidate':
        return cls(
            id=data.get('id', ''),
            onlineness=data.get('onlineness', 0)
        )


@dataclass
class VersionInfo:
    """Version information"""
    version: str
    git_commit_hash: str
    git_describe: str

    @classmethod
    def from_dict(cls, data: Dict) -> 'VersionInfo':
        return cls(
            version=data.get('version', 'unknown'),
            git_commit_hash=data.get('git_commit_hash', ''),
            git_describe=data.get('git_describe', '')
        )


@dataclass
class InternetStatus:
    """Internet connection status"""
    connection: ConnectionStatus
    checking_connectivity: bool

    @classmethod
    def from_dict(cls, data: Dict) -> 'InternetStatus':
        conn_str = data.get('connection', 'unknown').lower()
        connection = ConnectionStatus(conn_str) if conn_str in [e.value for e in ConnectionStatus] else ConnectionStatus.UNKNOWN
        return cls(
            connection=connection,
            checking_connectivity=data.get('checking_connectivity', False)
        )


@dataclass
class LNFeeEntry:
    """Fee entry for a peer"""
    median_base: int
    median_proportional: int
    multiplier: float
    final_base: int
    final_proportional: int

    @classmethod
    def from_dict(cls, data: Dict) -> 'LNFeeEntry':
        return cls(
            median_base=data.get('median_base', 0),
            median_proportional=data.get('median_proportional', 0),
            multiplier=data.get('multiplier', 0.0),
            final_base=data.get('final_base', 0),
            final_proportional=data.get('final_proportional', 0)
        )


@dataclass
class UptimeStats:
    """Uptime statistics"""
    past_3_days: float
    past_2_weeks: float
    past_1_month: float

    @classmethod
    def from_dict(cls, data: Dict) -> 'UptimeStats':
        return cls(
            past_3_days=data.get('past_3_days', 0.0),
            past_2_weeks=data.get('past_2_weeks', 0.0),
            past_1_month=data.get('past_1_month', 0.0)
        )


@dataclass
class SwapperStatusInfo:
    """Swapper status information"""
    status: SwapperStatus
    message: str

    @classmethod
    def from_dict(cls, data: Dict) -> 'SwapperStatusInfo':
        status_str = data.get('status', 'unknown').lower()
        status = SwapperStatus(status_str) if status_str in [e.value for e in SwapperStatus] else SwapperStatus.UNKNOWN
        return cls(
            status=status,
            message=data.get('message', '')
        )


@dataclass
class OffchainEarningsEntry:
    """Off-chain earnings entry for a peer"""
    in_earnings: int
    in_forwarded: int
    in_expenditures: int
    in_rebalanced: int
    out_earnings: int
    out_forwarded: int
    out_expenditures: int
    out_rebalanced: int

    @classmethod
    def from_dict(cls, data: Dict) -> 'OffchainEarningsEntry':
        return cls(
            in_earnings=data.get('in_earnings', 0),
            in_forwarded=data.get('in_forwarded', 0),
            in_expenditures=data.get('in_expenditures', 0),
            in_rebalanced=data.get('in_rebalanced', 0),
            out_earnings=data.get('out_earnings', 0),
            out_forwarded=data.get('out_forwarded', 0),
            out_expenditures=data.get('out_expenditures', 0),
            out_rebalanced=data.get('out_rebalanced', 0)
        )


@dataclass
class OnchainFeeRate:
    """On-chain fee rates"""
    hi_to_lo: int
    init_mid: int
    lo_to_hi: int
    last_feerate_perkw: int
    judgment: str

    @classmethod
    def from_dict(cls, data: Dict) -> 'OnchainFeeRate':
        return cls(
            hi_to_lo=data.get('hi_to_lo', 0),
            init_mid=data.get('init_mid', 0),
            lo_to_hi=data.get('lo_to_hi', 0),
            last_feerate_perkw=data.get('last_feerate_perkw', 0),
            judgment=data.get('judgment', '')
        )


@dataclass
class PeerMetrics:
    """Peer metrics"""
    age: float
    age_human: str
    seconds_per_attempt: float
    success_per_attempt: Optional[float]
    success_per_day: float
    connect_rate: float
    in_fee_msat_per_day: float
    out_fee_msat_per_day: float

    @classmethod
    def from_dict(cls, data: Dict) -> 'PeerMetrics':
        return cls(
            age=data.get('age', 0.0),
            age_human=data.get('age_human', ''),
            seconds_per_attempt=data.get('seconds_per_attempt', 0.0),
            success_per_attempt=data.get('success_per_attempt'),
            success_per_day=data.get('success_per_day', 0.0),
            connect_rate=data.get('connect_rate', 0.0),
            in_fee_msat_per_day=data.get('in_fee_msat_per_day', 0.0),
            out_fee_msat_per_day=data.get('out_fee_msat_per_day', 0.0)
        )


@dataclass
class MonitorFundsStatus:
    """On-chain funds monitoring status"""
    status: MonitorStatus
    now: float
    now_human: str
    disable_until: int
    disable_until_human: str
    comment: str

    @classmethod
    def from_dict(cls, data: Dict) -> 'MonitorFundsStatus':
        status_str = data.get('status', 'unknown').lower()
        status = MonitorStatus(status_str) if status_str in [e.value for e in MonitorStatus] else MonitorStatus.UNKNOWN
        return cls(
            status=status,
            now=data.get('now', 0.0),
            now_human=data.get('now_human', ''),
            disable_until=data.get('disable_until', 0),
            disable_until_human=data.get('disable_until_human', ''),
            comment=data.get('comment', '')
        )


@dataclass
class SwapTransaction:
    """Swap transaction"""
    time: float
    time_human: str
    amount_sent: str
    amount_received: str
    amount_lost: str
    provider: str

    @classmethod
    def from_dict(cls, data: Dict) -> 'SwapTransaction':
        return cls(
            time=data.get('time', 0.0),
            time_human=data.get('time_human', ''),
            amount_sent=data.get('amount_sent', '0msat'),
            amount_received=data.get('amount_received', '0msat'),
            amount_lost=data.get('amount_lost', '0msat'),
            provider=data.get('provider', '')
        )


@dataclass
class SwapReport:
    """Swaps report"""
    swaps: List[SwapTransaction]
    total_amount_sent: str
    total_amount_received: str
    loss: str
    percent_loss: float

    @classmethod
    def from_dict(cls, data: Dict) -> 'SwapReport':
        swaps = [SwapTransaction.from_dict(s) for s in data.get('swaps', [])]
        return cls(
            swaps=swaps,
            total_amount_sent=data.get('total_amount_sent', '0msat'),
            total_amount_received=data.get('total_amount_received', '0msat'),
            loss=data.get('loss', '0msat'),
            percent_loss=data.get('percent_loss', 0.0)
        )


class CLBOSSStatus:
    """
    Main parser for CLBOSS Status
    Provides structured access to all status data
    """

    def __init__(self, json_data: Union[str, Dict]):
        """
        Initialize parser with JSON data
        
        Args:
            json_data: JSON as string or dictionary
            
        Raises:
            ValueError: If JSON is invalid
        """
        if isinstance(json_data, str):
            try:
                self.raw_data = json.loads(json_data)
            except json.JSONDecodeError as e:
                raise ValueError(f"Invalid JSON: {e}")
        else:
            self.raw_data = json_data

        self._parse_all()

    def _parse_all(self) -> None:
        """Parse all status data"""
        # Basic information
        self.version_info = VersionInfo.from_dict(self.raw_data.get('info', {}))
        self.internet = InternetStatus.from_dict(self.raw_data.get('internet', {}))
        self.uptime = UptimeStats.from_dict(self.raw_data.get('my_uptime', {}))

        # Channel candidates
        self.channel_candidates = [
            ChannelCandidate.from_dict(c) for c in self.raw_data.get('channel_candidates', [])
        ]

        # Fees and swappers
        self.lnfee = {
            peer_id: LNFeeEntry.from_dict(fee_data)
            for peer_id, fee_data in self.raw_data.get('lnfee', {}).items()
        }

        self.incoming_capacity_swapper = SwapperStatusInfo.from_dict(
            self.raw_data.get('incoming_capacity_swapper', {})
        )
        self.needs_onchain_funds_swapper = SwapperStatusInfo.from_dict(
            self.raw_data.get('needs_onchain_funds_swapper', {})
        )

        # Off-chain earnings
        self.offchain_earnings = {
            peer_id: OffchainEarningsEntry.from_dict(earnings_data)
            for peer_id, earnings_data in self.raw_data.get('offchain_earnings_tracker', {}).items()
        }

        # On-chain fee metrics
        self.onchain_feerate = OnchainFeeRate.from_dict(self.raw_data.get('onchain_feerate', {}))

        # Peer metrics
        self.peer_metrics = {
            peer_id: PeerMetrics.from_dict(metrics_data)
            for peer_id, metrics_data in self.raw_data.get('peer_metrics', {}).items()
        }

        # Funds monitoring
        self.monitor_funds = MonitorFundsStatus.from_dict(
            self.raw_data.get('should_monitor_onchain_funds', {})
        )

        # Swaps report
        self.swap_report = SwapReport.from_dict(self.raw_data.get('swap_report', {}))

        # Unmanaged peers
        self.unmanaged_peers = self.raw_data.get('unmanaged', {}).copy()

        # Peer complaints
        self.peer_complaints = self.raw_data.get('peer_complaints', {}).copy()
        self.closed_peer_complaints = self.raw_data.get('closed_peer_complaints', {}).copy()

        # Price theory
        self.price_theory_investigating = self.raw_data.get('price_theory_investigating', {}).copy()

        # Swap manager
        self.swap_manager = self.raw_data.get('swap_manager', [])

    # ==================== UTILITY METHODS ====================

    def is_online(self) -> bool:
        """Returns whether the node is connected to internet"""
        return self.internet.connection == ConnectionStatus.ONLINE

    def get_channel_candidates_count(self) -> int:
        """Returns the number of channel candidates"""
        return len(self.channel_candidates)

    def get_best_channel_candidates(self, top_n: int = 5) -> List[ChannelCandidate]:
        """Returns the N best channel candidates sorted by onlineness"""
        sorted_candidates = sorted(self.channel_candidates, key=lambda c: c.onlineness, reverse=True)
        return sorted_candidates[:top_n]

    def get_peer_count(self) -> int:
        """Returns the total number of peers"""
        return len(self.peer_metrics)

    def get_active_peers(self) -> List[str]:
        """Returns list of active peers (with metrics)"""
        return list(self.peer_metrics.keys())

    def get_peer_metrics(self, peer_id: str) -> Optional[PeerMetrics]:
        """Gets the metrics for a specific peer"""
        return self.peer_metrics.get(peer_id)

    def get_peer_earnings(self, peer_id: str) -> Optional[OffchainEarningsEntry]:
        """Gets the earnings for a specific peer"""
        return self.offchain_earnings.get(peer_id)

    def get_peer_lnfee(self, peer_id: str) -> Optional[LNFeeEntry]:
        """Gets the Lightning Network fees for a specific peer"""
        return self.lnfee.get(peer_id)

    def get_total_earnings(self) -> Optional[OffchainEarningsEntry]:
        """Gets the total earnings"""
        return self.offchain_earnings.get('total')

    def get_unmanaged_peers_list(self) -> List[str]:
        """Returns list of unmanaged peers"""
        return list(self.unmanaged_peers.keys())

    def is_peer_unmanaged(self, peer_id: str) -> bool:
        """Checks if a peer is unmanaged"""
        return peer_id in self.unmanaged_peers

    def get_high_fee_peers(self, threshold: int = 1000) -> List[tuple[str, LNFeeEntry]]:
        """Returns peers with fees above the threshold"""
        return [
            (peer_id, fee_entry)
            for peer_id, fee_entry in self.lnfee.items()
            if fee_entry.final_proportional > threshold
        ]

    def get_low_uptime_periods(self) -> Dict[str, float]:
        """Returns periods with low uptime (< 0.99)"""
        result = {}
        if self.uptime.past_3_days < 0.99:
            result['past_3_days'] = self.uptime.past_3_days
        if self.uptime.past_2_weeks < 0.99:
            result['past_2_weeks'] = self.uptime.past_2_weeks
        if self.uptime.past_1_month < 0.99:
            result['past_1_month'] = self.uptime.past_1_month
        return result

    def get_swap_history(self, limit: int = 10) -> List[SwapTransaction]:
        """Returns limited swap history"""
        return self.swap_report.swaps[:limit]

    def get_swap_stats(self) -> Dict[str, Any]:
        """Returns swap statistics"""
        return {
            'total_swaps': len(self.swap_report.swaps),
            'total_sent': self.swap_report.total_amount_sent,
            'total_received': self.swap_report.total_amount_received,
            'total_loss': self.swap_report.loss,
            'percent_loss': f"{self.swap_report.percent_loss:.2f}%"
        }

    def get_peer_status_summary(self) -> Dict[str, Any]:
        """Returns a summary of peers status"""
        total_peers = self.get_peer_count()
        unmanaged = len(self.get_unmanaged_peers_list())
        managed = total_peers - unmanaged

        return {
            'total_peers': total_peers,
            'managed_peers': managed,
            'unmanaged_peers': unmanaged,
            'peer_list': self.get_active_peers()
        }

    def to_dict(self) -> Dict:
        """Converts the current state to dictionary"""
        return self.raw_data

    def to_json(self, indent: int = 2) -> str:
        """Converts the current state to JSON"""
        return json.dumps(self.raw_data, indent=indent)

    def __repr__(self) -> str:
        return (
            f"CLBOSSStatus(version={self.version_info.version}, "
            f"peers={self.get_peer_count()}, "
            f"online={self.is_online()})"
        )


# ==================== UTILITY FUNCTIONS ====================

def parse_clboss_status(json_data: Union[str, Dict]) -> CLBOSSStatus:
    """
    Helper function to parse CLBOSS status
    
    Args:
        json_data: JSON as string or dictionary
        
    Returns:
        CLBOSSStatus instance
        
    Raises:
        ValueError: If JSON is invalid
    """
    return CLBOSSStatus(json_data)


def extract_msat_value(msat_string: str) -> int:
    """
    Extract numeric value from millisatoshi string
    
    Args:
        msat_string: String formatted like "123456msat"
        
    Returns:
        Numeric value in msat
    """
    try:
        return int(msat_string.replace('msat', '').strip())
    except ValueError:
        return 0


def format_msat(msat_value: Union[int, str]) -> str:
    """
    Format millisatoshi value
    
    Args:
        msat_value: Value in millisatoshis as int or string
        
    Returns:
        Formatted string with "msat"
    """
    if isinstance(msat_value, str):
        msat_value = extract_msat_value(msat_value)
    return f"{msat_value:,}msat"


if __name__ == "__main__":
    # Usage example
    import sys

    if len(sys.argv) > 1:
        with open(sys.argv[1], 'r') as f:
            data = json.load(f)
    else:
        # Sample JSON for testing
        data = {
            "version": "v0.16.0",
            "info": {"version": "v0.16.0", "git_commit_hash": "test", "git_describe": "test"},
            "internet": {"connection": "online", "checking_connectivity": False},
            "my_uptime": {"past_3_days": 0.99, "past_2_weeks": 0.99, "past_1_month": 0.99}
        }

    try:
        status = parse_clboss_status(data)
        print(status)
        print(f"Online: {status.is_online()}")
        print(f"Peers: {status.get_peer_count()}")
    except ValueError as e:
        print(f"Error: {e}")
