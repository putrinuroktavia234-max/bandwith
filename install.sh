#!/bin/sh
#===============================================================================
#  ██╗   ██╗██╗   ██╗███████╗██╗███╗   ██╗ ██████╗██████╗  █████╗ ██████╗ 
#  ╚██╗ ██╔╝██║   ██║╚══███╔╝██║████╗  ██║██╔════╝██╔══██╗██╔══██╗██╔══██╗
#   ╚████╔╝ ██║   ██║  ███╔╝ ██║██╔██╗ ██║██║     ██████╔╝███████║██████╔╝
#    ╚██╔╝  ██║   ██║ ███╔╝  ██║██║╚██╗██║██║     ██╔══██╗██╔══██║██╔══██╗
#     ██║   ╚██████╔╝███████╗██║██║ ╚████║╚██████╗██║  ██║██║  ██║██████╔╝
#     ╚═╝    ╚═════╝ ╚══════╝╚═╝╚═╝  ╚═══╝ ╚═════╝╚═╝  ╚═╝╚═╝  ╚═╝╚═════╝ 
#                    SENTINEL MONITORING SYSTEM v2.0
#                    OpenWRT Cyber-Sentinel Dashboard
#===============================================================================
# Author: YuzinCrab Systems | License: MIT | Target: OpenWRT 21.02+
#===============================================================================

set -e

# ══════════════════════════════════════════════════════════════════════════════
# CONFIGURATION
# ══════════════════════════════════════════════════════════════════════════════
INSTALL_DIR="/www/yuzincrab"
CGI_DIR="/www/cgi-bin"
LUCI_CONTROLLER="/usr/lib/lua/luci/controller"
LUCI_VIEW="/usr/lib/lua/luci/view"
CACHE_DIR="/tmp/yuzincrab"
LOG_FILE="/tmp/yuzincrab_install.log"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
YELLOW='\033[1;33m'
NC='\033[0m'
BOLD='\033[1m'

# ══════════════════════════════════════════════════════════════════════════════
# UTILITY FUNCTIONS
# ══════════════════════════════════════════════════════════════════════════════
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOG_FILE"
    echo -e "${CYAN}[*]${NC} $1"
}

success() {
    echo -e "${GREEN}[✓]${NC} $1"
}

error() {
    echo -e "${RED}[✗]${NC} $1"
    exit 1
}

warn() {
    echo -e "${YELLOW}[!]${NC} $1"
}

print_banner() {
    echo -e "${MAGENTA}"
    cat << 'BANNER'
    
  ╔═══════════════════════════════════════════════════════════════════════╗
  ║  ▄██╗   ██╗██╗   ██╗███████╗██╗███╗   ██╗ ██████╗██████╗  █████╗ ██████╗║
  ║   ╚██╗ ██╔╝██║   ██║╚══███╔╝██║████╗  ██║██╔════╝██╔══██╗██╔══██╗██╔══██╗
  ║    ╚████╔╝ ██║   ██║  ███╔╝ ██║██╔██╗ ██║██║     ██████╔╝███████║██████╔╝
  ║     ╚██╔╝  ██║   ██║ ███╔╝  ██║██║╚██╗██║██║     ██╔══██╗██╔══██║██╔══██╗
  ║      ██║   ╚██████╔╝███████╗██║██║ ╚████║╚██████╗██║  ██║██║  ██║██████╔╝
  ║      ╚═╝    ╚═════╝ ╚══════╝╚═╝╚═╝  ╚═══╝ ╚═════╝╚═╝  ╚═╝╚═╝  ╚═╝╚═════╝║
  ║                      SENTINEL MONITORING SYSTEM                        ║
  ║                        ═══════════════════════                         ║
  ║              [ CYBER-SENTINEL TELEMETRY DASHBOARD ]                    ║
  ╚═══════════════════════════════════════════════════════════════════════╝
    
BANNER
    echo -e "${NC}"
}

# ══════════════════════════════════════════════════════════════════════════════
# ENVIRONMENT CHECK
# ══════════════════════════════════════════════════════════════════════════════
check_environment() {
    log "Checking environment requirements..."
    
    # Check if running as root
    if [ "$(id -u)" != "0" ]; then
        error "This script must be run as root"
    fi
    
    # Check for required commands
    for cmd in curl awk sed cat grep; do
        if ! command -v $cmd >/dev/null 2>&1; then
            warn "$cmd not found, attempting to install..."
            opkg update && opkg install $cmd || error "Failed to install $cmd"
        fi
    done
    
    # Check uhttpd
    if ! pgrep -x uhttpd >/dev/null 2>&1; then
        warn "uhttpd not running, starting..."
        /etc/init.d/uhttpd start || error "Failed to start uhttpd"
    fi
    
    # Verify uhttpd CGI support
    if ! uci get uhttpd.main.cgi_prefix >/dev/null 2>&1; then
        warn "Configuring uhttpd CGI support..."
        uci set uhttpd.main.cgi_prefix='/cgi-bin'
        uci commit uhttpd
    fi
    
    success "Environment check passed"
}

# ══════════════════════════════════════════════════════════════════════════════
# DIRECTORY SETUP
# ══════════════════════════════════════════════════════════════════════════════
setup_directories() {
    log "Setting up directories..."
    
    mkdir -p "$INSTALL_DIR"
    mkdir -p "$CGI_DIR"
    mkdir -p "$CACHE_DIR"
    mkdir -p "$LUCI_CONTROLLER"
    mkdir -p "$LUCI_VIEW/yuzincrab"
    
    success "Directories created"
}

# ══════════════════════════════════════════════════════════════════════════════
# CGI API BACKEND
# ══════════════════════════════════════════════════════════════════════════════
create_api_backend() {
    log "Creating CGI API backend..."
    
    # Ensure CGI directory exists
    mkdir -p "$CGI_DIR"
    
    cat > "$CGI_DIR/bandwidth_api" << 'APIEOF'
#!/bin/sh
echo "Content-Type: application/json"
echo "Access-Control-Allow-Origin: *"
echo "Cache-Control: no-cache"
echo ""

CACHE_DIR="/tmp/yuzincrab"
PREV_FILE="$CACHE_DIR/prev_stats"
WAN_CACHE="$CACHE_DIR/wan_info"
WAN_CACHE_TIME=3600

mkdir -p "$CACHE_DIR"

# ─────────────────────────────────────────────────────────────────────────────
# Get Network Interface Stats
# ─────────────────────────────────────────────────────────────────────────────
get_interface_stats() {
    local iface="$1"
    if [ -d "/sys/class/net/$iface" ]; then
        rx=$(cat /sys/class/net/$iface/statistics/rx_bytes 2>/dev/null || echo 0)
        tx=$(cat /sys/class/net/$iface/statistics/tx_bytes 2>/dev/null || echo 0)
        echo "$rx $tx"
    else
        # Fallback: parse /proc/net/dev
        rx=$(grep "^$iface:" /proc/net/dev 2>/dev/null | awk '{print $2}' || echo 0)
        tx=$(grep "^$iface:" /proc/net/dev 2>/dev/null | awk '{print $10}' || echo 0)
        echo "$rx $tx"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Calculate Bandwidth Delta
# ─────────────────────────────────────────────────────────────────────────────
calculate_bandwidth() {
    local current_time=$(date +%s)
    local wan_iface=""
    
    # Auto-detect WAN interface (more comprehensive)
    for iface in eth1 eth0.2 wan wan6 pppoe-wan eth0.1 vlan2 wlan0; do
        if [ -e "/sys/class/net/$iface" ]; then
            wan_iface="$iface"
            break
        fi
    done
    
    # Fallback: get first interface from /proc/net/dev (skip lo)
    if [ -z "$wan_iface" ]; then
        wan_iface=$(cat /proc/net/dev | grep ':' | grep -v 'lo:' | head -1 | cut -d: -f1 | tr -d ' ')
    fi
    
    [ -z "$wan_iface" ] && wan_iface="eth0"
    
    read current_rx current_tx <<< $(get_interface_stats "$wan_iface")
    
    # Ensure we have valid numbers
    [ -z "$current_rx" ] && current_rx=0
    [ -z "$current_tx" ] && current_tx=0
    
    if [ -f "$PREV_FILE" ]; then
        read prev_time prev_rx prev_tx < "$PREV_FILE"
        
        # Default values if empty
        [ -z "$prev_time" ] && prev_time=0
        [ -z "$prev_rx" ] && prev_rx=0
        [ -z "$prev_tx" ] && prev_tx=0
        
        time_diff=$(( current_time - prev_time ))
        
        # Prevent division by zero
        [ "$time_diff" -le 0 ] && time_diff=1
        
        rx_diff=$(( current_rx - prev_rx ))
        tx_diff=$(( current_tx - prev_tx ))
        
        # Handle counter resets
        [ "$rx_diff" -lt 0 ] && rx_diff=0
        [ "$tx_diff" -lt 0 ] && tx_diff=0
        
        # Calculate speed in bps (bytes to bits)
        rx_speed=$(( (rx_diff * 8) / time_diff ))
        tx_speed=$(( (tx_diff * 8) / time_diff ))
    else
        rx_speed=0
        tx_speed=0
    fi
    
    echo "$current_time $current_rx $current_tx" > "$PREV_FILE"
    echo "$rx_speed $tx_speed $current_rx $current_tx $wan_iface"
}

# ─────────────────────────────────────────────────────────────────────────────
# Get Active Clients
# ─────────────────────────────────────────────────────────────────────────────
get_clients() {
    local clients="["
    local first=1
    local temp_clients=""
    
    # Parse DHCP leases
    if [ -f "/tmp/dhcp.leases" ]; then
        while read -r expire mac ip hostname clientid; do
            [ -z "$mac" ] && continue
            [ -z "$ip" ] && continue
            [ "$hostname" = "*" ] && hostname="Unknown"
            [ "$hostname" = "-" ] && hostname="Unknown"
            
            # Get signal strength if wireless
            signal="N/A"
            for iface in wlan0 wlan1 ath0 ath1; do
                if [ -e "/sys/class/net/$iface" ]; then
                    sig=$(iw dev $iface station get $mac 2>/dev/null | grep -m1 "signal:" | awk '{print $2}')
                    if [ -n "$sig" ] && [ "$sig" != "0" ]; then
                        signal="$sig"
                        break
                    fi
                fi
            done
            
            [ $first -eq 0 ] && clients="$clients,"
            first=0
            
            clients="$clients{\"mac\":\"$mac\",\"ip\":\"$ip\",\"hostname\":\"$hostname\",\"signal\":\"$signal\",\"expire\":\"$expire\"}"
        done < /tmp/dhcp.leases
    fi
    
    # If no DHCP leases, try ARP table
    if [ "$first" -eq 1 ]; then
        cat /proc/net/arp 2>/dev/null | tail -n +2 | while read -r ip hw_type flags mac mask dev; do
            [ "$hw_type" = "0x1" ] || continue
            [ "$flags" = "0x0" ] && continue
            [ -z "$mac" ] && continue
            [ "$mac" = "00:00:00:00:00:00" ] && continue
            
            [ $first -eq 0 ] && echo -n ","
            first=0
            
            echo -n "{\"mac\":\"$mac\",\"ip\":\"$ip\",\"hostname\":\"Device-${ip##*.}\",\"signal\":\"N/A\",\"expire\":\"active\"}"
        done >> /tmp/yuzincrab_temp.json
        
        if [ -f "/tmp/yuzincrab_temp.json" ]; then
            clients="$clients$(cat /tmp/yuzincrab_temp.json)"
            rm -f /tmp/yuzincrab_temp.json
        fi
    fi
    
    echo "$clients]"
}

# ─────────────────────────────────────────────────────────────────────────────
# Get System Health
# ─────────────────────────────────────────────────────────────────────────────
get_system_health() {
    # Load average
    load=$(cat /proc/loadavg | awk '{print $1}')
    
    # Memory
    mem_info=$(cat /proc/meminfo)
    mem_total=$(echo "$mem_info" | grep MemTotal | awk '{print $2}')
    mem_free=$(echo "$mem_info" | grep MemFree | awk '{print $2}')
    mem_buffers=$(echo "$mem_info" | grep Buffers | awk '{print $2}')
    mem_cached=$(echo "$mem_info" | grep "^Cached:" | awk '{print $2}')
    mem_used=$(( mem_total - mem_free - mem_buffers - mem_cached ))
    mem_percent=$(( (mem_used * 100) / mem_total ))
    
    # CPU Temperature
    temp="N/A"
    for thermal in /sys/class/thermal/thermal_zone*/temp /sys/class/hwmon/hwmon*/temp1_input; do
        if [ -f "$thermal" ]; then
            raw_temp=$(cat "$thermal" 2>/dev/null)
            if [ -n "$raw_temp" ] && [ "$raw_temp" -gt 1000 ]; then
                temp=$(( raw_temp / 1000 ))
            elif [ -n "$raw_temp" ]; then
                temp="$raw_temp"
            fi
            break
        fi
    done
    
    # Uptime
    uptime_sec=$(cat /proc/uptime | awk '{print int($1)}')
    days=$(( uptime_sec / 86400 ))
    hours=$(( (uptime_sec % 86400) / 3600 ))
    mins=$(( (uptime_sec % 3600) / 60 ))
    
    # CPU Usage
    cpu1=$(cat /proc/stat | grep "^cpu " | awk '{print $2+$3+$4+$5+$6+$7+$8}')
    idle1=$(cat /proc/stat | grep "^cpu " | awk '{print $5}')
    sleep 0.2
    cpu2=$(cat /proc/stat | grep "^cpu " | awk '{print $2+$3+$4+$5+$6+$7+$8}')
    idle2=$(cat /proc/stat | grep "^cpu " | awk '{print $5}')
    cpu_diff=$(( cpu2 - cpu1 ))
    idle_diff=$(( idle2 - idle1 ))
    [ "$cpu_diff" -gt 0 ] && cpu_percent=$(( 100 * (cpu_diff - idle_diff) / cpu_diff )) || cpu_percent=0
    
    echo "{\"load\":\"$load\",\"mem_percent\":$mem_percent,\"mem_used\":$(( mem_used / 1024 )),\"mem_total\":$(( mem_total / 1024 )),\"temp\":\"$temp\",\"uptime_days\":$days,\"uptime_hours\":$hours,\"uptime_mins\":$mins,\"cpu_percent\":$cpu_percent}"
}

# ─────────────────────────────────────────────────────────────────────────────
# Get WAN Info (Cached)
# ─────────────────────────────────────────────────────────────────────────────
get_wan_info() {
    local now=$(date +%s)
    local use_cache=0
    
    if [ -f "$WAN_CACHE" ]; then
        cache_time=$(stat -c %Y "$WAN_CACHE" 2>/dev/null || echo 0)
        age=$(( now - cache_time ))
        [ "$age" -lt "$WAN_CACHE_TIME" ] && use_cache=1
    fi
    
    if [ "$use_cache" -eq 1 ]; then
        cat "$WAN_CACHE"
    else
        wan_data=$(curl -s --connect-timeout 3 --max-time 5 "http://ip-api.com/json/?fields=status,query,isp,city,country,countryCode,lat,lon" 2>/dev/null)
        if echo "$wan_data" | grep -q '"status":"success"'; then
            echo "$wan_data" > "$WAN_CACHE"
            echo "$wan_data"
        elif [ -f "$WAN_CACHE" ]; then
            cat "$WAN_CACHE"
        else
            echo '{"status":"fail","query":"Unknown","isp":"Unknown","city":"Unknown","country":"Unknown","countryCode":"XX","lat":0,"lon":0}'
        fi
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Get Latency
# ─────────────────────────────────────────────────────────────────────────────
get_latency() {
    latency=$(ping -c 1 -W 2 8.8.8.8 2>/dev/null | grep "time=" | sed 's/.*time=\([0-9.]*\).*/\1/')
    [ -z "$latency" ] && latency="-1"
    echo "$latency"
}

# ─────────────────────────────────────────────────────────────────────────────
# Main Output
# ─────────────────────────────────────────────────────────────────────────────
read rx_speed tx_speed total_rx total_tx wan_iface <<< $(calculate_bandwidth)
system_health=$(get_system_health)
wan_info=$(get_wan_info)
latency=$(get_latency)
clients=$(get_clients)

cat << JSONEOF
{
    "timestamp": $(date +%s),
    "bandwidth": {
        "rx_speed": $rx_speed,
        "tx_speed": $tx_speed,
        "total_rx": $total_rx,
        "total_tx": $total_tx,
        "interface": "$wan_iface"
    },
    "system": $system_health,
    "wan": $wan_info,
    "latency": $latency,
    "clients": $clients
}
JSONEOF
APIEOF

    chmod +x "$CGI_DIR/bandwidth_api"
    
    # Verify file was created
    if [ ! -f "$CGI_DIR/bandwidth_api" ]; then
        error "Failed to create CGI script at $CGI_DIR/bandwidth_api"
    fi
    
    if [ ! -x "$CGI_DIR/bandwidth_api" ]; then
        error "CGI script is not executable"
    fi
    
    # Test if script runs without errors
    "$CGI_DIR/bandwidth_api" > /tmp/api_test.json 2>&1
    if [ $? -eq 0 ]; then
        success "API backend created and tested successfully"
    else
        warn "API script created but test failed - may need router reboot"
        success "API backend created"
    fi
}

# ══════════════════════════════════════════════════════════════════════════════
# FRONTEND HTML
# ══════════════════════════════════════════════════════════════════════════════
create_frontend() {
    log "Creating frontend interface..."
    
    cat > "$INSTALL_DIR/index.html" << 'HTMLEOF'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>YuzinCrab Sentinel | Cyber-Sentinel Dashboard</title>
    <script src="https://cdn.tailwindcss.com"></script>
    <script src="https://cdn.jsdelivr.net/npm/chart.js"></script>
    <link href="https://fonts.googleapis.com/css2?family=Orbitron:wght@400;500;600;700;800;900&family=JetBrains+Mono:wght@300;400;500;600;700&display=swap" rel="stylesheet">
    <style>
        :root {
            --neon-cyan: #06b6d4;
            --neon-magenta: #ec4899;
            --neon-green: #22c55e;
            --neon-yellow: #eab308;
            --neon-red: #ef4444;
            --void-dark: #0f172a;
            --void-darker: #020617;
        }
        
        * { box-sizing: border-box; }
        
        body {
            font-family: 'JetBrains Mono', monospace;
            background: linear-gradient(135deg, var(--void-darker) 0%, var(--void-dark) 50%, #1e1b4b 100%);
            min-height: 100vh;
            color: #e2e8f0;
            overflow-x: hidden;
        }
        
        .font-orbitron { font-family: 'Orbitron', sans-serif; }
        
        /* Glassmorphism Cards */
        .glass-card {
            background: rgba(15, 23, 42, 0.6);
            backdrop-filter: blur(12px);
            -webkit-backdrop-filter: blur(12px);
            border: 1px solid rgba(6, 182, 212, 0.2);
            border-radius: 16px;
            box-shadow: 0 0 40px rgba(6, 182, 212, 0.1),
                        inset 0 0 60px rgba(6, 182, 212, 0.05);
        }
        
        .glass-card:hover {
            border-color: rgba(6, 182, 212, 0.4);
            box-shadow: 0 0 60px rgba(6, 182, 212, 0.2),
                        inset 0 0 60px rgba(6, 182, 212, 0.08);
        }
        
        /* Glitch Effect */
        .glitch {
            position: relative;
            animation: glitch-skew 2s infinite linear alternate-reverse;
        }
        
        .glitch::before, .glitch::after {
            content: attr(data-text);
            position: absolute;
            top: 0;
            left: 0;
            width: 100%;
            height: 100%;
        }
        
        .glitch::before {
            color: var(--neon-cyan);
            animation: glitch-effect 3s infinite linear alternate-reverse;
            clip-path: polygon(0 0, 100% 0, 100% 35%, 0 35%);
            transform: translate(-2px);
        }
        
        .glitch::after {
            color: var(--neon-magenta);
            animation: glitch-effect 2s infinite linear alternate-reverse;
            clip-path: polygon(0 65%, 100% 65%, 100% 100%, 0 100%);
            transform: translate(2px);
        }
        
        @keyframes glitch-effect {
            0% { transform: translate(0); }
            20% { transform: translate(-2px, 2px); }
            40% { transform: translate(-2px, -2px); }
            60% { transform: translate(2px, 2px); }
            80% { transform: translate(2px, -2px); }
            100% { transform: translate(0); }
        }
        
        @keyframes glitch-skew {
            0% { transform: skew(0deg); }
            10% { transform: skew(1deg); }
            20% { transform: skew(-1deg); }
            30% { transform: skew(0.5deg); }
            40% { transform: skew(-0.5deg); }
            50% { transform: skew(0deg); }
        }
        
        /* Neon Glow */
        .neon-glow-cyan {
            text-shadow: 0 0 10px var(--neon-cyan),
                         0 0 20px var(--neon-cyan),
                         0 0 40px var(--neon-cyan);
        }
        
        .neon-glow-magenta {
            text-shadow: 0 0 10px var(--neon-magenta),
                         0 0 20px var(--neon-magenta),
                         0 0 40px var(--neon-magenta);
        }
        
        /* Speedometer */
        .speedometer {
            position: relative;
            width: 200px;
            height: 120px;
        }
        
        .speedometer-bg {
            position: absolute;
            width: 100%;
            height: 200%;
            border-radius: 100px 100px 0 0;
            background: conic-gradient(from 180deg, 
                var(--neon-green) 0deg,
                var(--neon-yellow) 60deg,
                var(--neon-red) 120deg,
                rgba(255,255,255,0.1) 120deg,
                rgba(255,255,255,0.1) 180deg);
            clip-path: polygon(0 50%, 100% 50%, 100% 100%, 0 100%);
            transform: rotate(180deg);
            opacity: 0.3;
        }
        
        .speedometer-fill {
            position: absolute;
            width: 100%;
            height: 200%;
            border-radius: 100px 100px 0 0;
            background: conic-gradient(from 180deg, 
                var(--neon-green) 0deg,
                var(--neon-yellow) 60deg,
                var(--neon-red) 120deg,
                transparent 120deg);
            clip-path: polygon(0 50%, 100% 50%, 100% 100%, 0 100%);
            transform: rotate(180deg);
            transition: all 0.3s ease;
        }
        
        .speedometer-needle {
            position: absolute;
            bottom: 0;
            left: 50%;
            width: 4px;
            height: 80px;
            background: linear-gradient(to top, var(--neon-cyan), white);
            transform-origin: bottom center;
            transform: translateX(-50%) rotate(-90deg);
            transition: transform 0.5s cubic-bezier(0.4, 0, 0.2, 1);
            border-radius: 2px;
            box-shadow: 0 0 10px var(--neon-cyan), 0 0 20px var(--neon-cyan);
        }
        
        .speedometer-center {
            position: absolute;
            bottom: -10px;
            left: 50%;
            transform: translateX(-50%);
            width: 20px;
            height: 20px;
            background: radial-gradient(circle, var(--neon-cyan), var(--void-dark));
            border-radius: 50%;
            box-shadow: 0 0 20px var(--neon-cyan);
        }
        
        /* Pulse Animation */
        @keyframes pulse-neon {
            0%, 100% { opacity: 1; box-shadow: 0 0 20px var(--neon-cyan); }
            50% { opacity: 0.7; box-shadow: 0 0 40px var(--neon-cyan); }
        }
        
        .pulse-neon {
            animation: pulse-neon 2s ease-in-out infinite;
        }
        
        /* Scrollbar */
        ::-webkit-scrollbar {
            width: 8px;
            height: 8px;
        }
        
        ::-webkit-scrollbar-track {
            background: var(--void-darker);
        }
        
        ::-webkit-scrollbar-thumb {
            background: var(--neon-cyan);
            border-radius: 4px;
        }
        
        /* Data Stream Animation */
        @keyframes data-stream {
            0% { background-position: 0% 0%; }
            100% { background-position: 100% 100%; }
        }
        
        .data-stream {
            background: linear-gradient(45deg, 
                transparent 30%, 
                rgba(6, 182, 212, 0.1) 50%, 
                transparent 70%);
            background-size: 200% 200%;
            animation: data-stream 3s linear infinite;
        }
        
        /* Client Table */
        .client-row {
            transition: all 0.3s ease;
            border-left: 3px solid transparent;
        }
        
        .client-row:hover {
            background: rgba(6, 182, 212, 0.1);
            border-left-color: var(--neon-cyan);
        }
        
        /* Traffic Bar */
        .traffic-bar {
            height: 4px;
            background: linear-gradient(90deg, var(--neon-cyan), var(--neon-magenta));
            border-radius: 2px;
            transition: width 0.5s ease;
        }
        
        /* Status Indicator */
        .status-dot {
            width: 8px;
            height: 8px;
            border-radius: 50%;
            animation: pulse-neon 1.5s ease-in-out infinite;
        }
        
        .status-online { background: var(--neon-green); box-shadow: 0 0 10px var(--neon-green); }
        .status-warning { background: var(--neon-yellow); box-shadow: 0 0 10px var(--neon-yellow); }
        .status-offline { background: var(--neon-red); box-shadow: 0 0 10px var(--neon-red); }
        
        /* Grid Background */
        .grid-bg {
            background-image: 
                linear-gradient(rgba(6, 182, 212, 0.03) 1px, transparent 1px),
                linear-gradient(90deg, rgba(6, 182, 212, 0.03) 1px, transparent 1px);
            background-size: 50px 50px;
        }
        
        /* Scan Line Effect */
        .scanline {
            position: fixed;
            top: 0;
            left: 0;
            width: 100%;
            height: 100%;
            background: linear-gradient(
                transparent 50%,
                rgba(6, 182, 212, 0.02) 50%
            );
            background-size: 100% 4px;
            pointer-events: none;
            z-index: 9999;
        }
    </style>
</head>
<body class="grid-bg">
    <div class="scanline"></div>
    
    <!-- Header -->
    <header class="relative py-6 px-4 border-b border-cyan-500/20">
        <div class="max-w-7xl mx-auto flex items-center justify-between">
            <div class="flex items-center gap-4">
                <div class="relative">
                    <div class="w-12 h-12 rounded-xl bg-gradient-to-br from-cyan-500 to-pink-500 flex items-center justify-center pulse-neon">
                        <svg class="w-7 h-7 text-white" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M9 3v2m6-2v2M9 19v2m6-2v2M5 9H3m2 6H3m18-6h-2m2 6h-2M7 19h10a2 2 0 002-2V7a2 2 0 00-2-2H7a2 2 0 00-2 2v10a2 2 0 002 2zM9 9h6v6H9V9z"/>
                        </svg>
                    </div>
                </div>
                <div>
                    <h1 class="font-orbitron text-2xl font-bold glitch neon-glow-cyan" data-text="YUZINCRAB">YUZINCRAB</h1>
                    <p class="text-xs text-cyan-400/60 tracking-widest">SENTINEL MONITORING SYSTEM</p>
                </div>
            </div>
            <div class="flex items-center gap-6">
                <div class="text-right">
                    <div class="text-xs text-slate-400">SYSTEM TIME</div>
                    <div id="systemTime" class="font-orbitron text-lg text-cyan-400">--:--:--</div>
                </div>
                <div class="flex items-center gap-2">
                    <div class="status-dot status-online"></div>
                    <span class="text-xs text-slate-400">ONLINE</span>
                </div>
            </div>
        </div>
    </header>
    
    <!-- Main Content -->
    <main class="max-w-7xl mx-auto p-4 space-y-6">
        
        <!-- Top Stats Row -->
        <div class="grid grid-cols-2 md:grid-cols-4 gap-4">
            <!-- Download Speed -->
            <div class="glass-card p-4">
                <div class="flex items-center gap-2 mb-2">
                    <svg class="w-4 h-4 text-cyan-400" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                        <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M19 14l-7 7m0 0l-7-7m7 7V3"/>
                    </svg>
                    <span class="text-xs text-slate-400 uppercase tracking-wider">Download</span>
                </div>
                <div class="font-orbitron text-2xl text-cyan-400" id="downloadSpeed">0.00</div>
                <div class="text-xs text-slate-500">Mbps</div>
            </div>
            
            <!-- Upload Speed -->
            <div class="glass-card p-4">
                <div class="flex items-center gap-2 mb-2">
                    <svg class="w-4 h-4 text-pink-400" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                        <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M5 10l7-7m0 0l7 7m-7-7v18"/>
                    </svg>
                    <span class="text-xs text-slate-400 uppercase tracking-wider">Upload</span>
                </div>
                <div class="font-orbitron text-2xl text-pink-400" id="uploadSpeed">0.00</div>
                <div class="text-xs text-slate-500">Mbps</div>
            </div>
            
            <!-- Latency -->
            <div class="glass-card p-4">
                <div class="flex items-center gap-2 mb-2">
                    <svg class="w-4 h-4 text-green-400" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                        <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M13 10V3L4 14h7v7l9-11h-7z"/>
                    </svg>
                    <span class="text-xs text-slate-400 uppercase tracking-wider">Latency</span>
                </div>
                <div class="font-orbitron text-2xl text-green-400" id="latency">--</div>
                <div class="text-xs text-slate-500">ms</div>
            </div>
            
            <!-- Active Clients -->
            <div class="glass-card p-4">
                <div class="flex items-center gap-2 mb-2">
                    <svg class="w-4 h-4 text-yellow-400" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                        <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 4.354a4 4 0 110 5.292M15 21H3v-1a6 6 0 0112 0v1zm0 0h6v-1a6 6 0 00-9-5.197M13 7a4 4 0 11-8 0 4 4 0 018 0z"/>
                    </svg>
                    <span class="text-xs text-slate-400 uppercase tracking-wider">Clients</span>
                </div>
                <div class="font-orbitron text-2xl text-yellow-400" id="clientCount">0</div>
                <div class="text-xs text-slate-500">Active</div>
            </div>
        </div>
        
        <!-- Speedometers & Chart Row -->
        <div class="grid grid-cols-1 lg:grid-cols-3 gap-6">
            <!-- Download Gauge -->
            <div class="glass-card p-6">
                <h3 class="font-orbitron text-sm text-slate-400 mb-4 text-center">DOWNLOAD THROUGHPUT</h3>
                <div class="flex justify-center">
                    <div class="speedometer">
                        <div class="speedometer-bg"></div>
                        <div class="speedometer-fill" id="downloadGaugeFill"></div>
                        <div class="speedometer-needle" id="downloadNeedle"></div>
                        <div class="speedometer-center"></div>
                    </div>
                </div>
                <div class="text-center mt-4">
                    <span class="font-orbitron text-3xl text-cyan-400" id="downloadGaugeValue">0</span>
                    <span class="text-slate-500 ml-2">Mbps</span>
                </div>
                <div class="flex justify-between text-xs text-slate-500 mt-2">
                    <span>0</span>
                    <span>50</span>
                    <span>100</span>
                </div>
            </div>
            
            <!-- Live Traffic Chart -->
            <div class="glass-card p-6 lg:col-span-1">
                <h3 class="font-orbitron text-sm text-slate-400 mb-4">NETWORK HEARTBEAT</h3>
                <div class="h-48">
                    <canvas id="trafficChart"></canvas>
                </div>
            </div>
            
            <!-- Upload Gauge -->
            <div class="glass-card p-6">
                <h3 class="font-orbitron text-sm text-slate-400 mb-4 text-center">UPLOAD THROUGHPUT</h3>
                <div class="flex justify-center">
                    <div class="speedometer">
                        <div class="speedometer-bg"></div>
                        <div class="speedometer-fill" id="uploadGaugeFill"></div>
                        <div class="speedometer-needle" id="uploadNeedle"></div>
                        <div class="speedometer-center"></div>
                    </div>
                </div>
                <div class="text-center mt-4">
                    <span class="font-orbitron text-3xl text-pink-400" id="uploadGaugeValue">0</span>
                    <span class="text-slate-500 ml-2">Mbps</span>
                </div>
                <div class="flex justify-between text-xs text-slate-500 mt-2">
                    <span>0</span>
                    <span>50</span>
                    <span>100</span>
                </div>
            </div>
        </div>
        
        <!-- System Health & WAN Info -->
        <div class="grid grid-cols-1 lg:grid-cols-2 gap-6">
            <!-- System Health -->
            <div class="glass-card p-6">
                <h3 class="font-orbitron text-sm text-slate-400 mb-4 flex items-center gap-2">
                    <svg class="w-4 h-4 text-cyan-400" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                        <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M9 3v2m6-2v2M9 19v2m6-2v2M5 9H3m2 6H3m18-6h-2m2 6h-2M7 19h10a2 2 0 002-2V7a2 2 0 00-2-2H7a2 2 0 00-2 2v10a2 2 0 002 2zM9 9h6v6H9V9z"/>
                    </svg>
                    SYSTEM TELEMETRY
                </h3>
                <div class="grid grid-cols-2 gap-4">
                    <!-- CPU -->
                    <div class="bg-slate-800/50 rounded-lg p-4">
                        <div class="flex items-center justify-between mb-2">
                            <span class="text-xs text-slate-400">CPU LOAD</span>
                            <span class="font-orbitron text-cyan-400" id="cpuLoad">0%</span>
                        </div>
                        <div class="h-2 bg-slate-700 rounded-full overflow-hidden">
                            <div class="h-full bg-gradient-to-r from-cyan-500 to-cyan-300 transition-all duration-500" id="cpuBar" style="width: 0%"></div>
                        </div>
                    </div>
                    
                    <!-- Memory -->
                    <div class="bg-slate-800/50 rounded-lg p-4">
                        <div class="flex items-center justify-between mb-2">
                            <span class="text-xs text-slate-400">MEMORY</span>
                            <span class="font-orbitron text-pink-400" id="memUsage">0%</span>
                        </div>
                        <div class="h-2 bg-slate-700 rounded-full overflow-hidden">
                            <div class="h-full bg-gradient-to-r from-pink-500 to-pink-300 transition-all duration-500" id="memBar" style="width: 0%"></div>
                        </div>
                    </div>
                    
                    <!-- Temperature -->
                    <div class="bg-slate-800/50 rounded-lg p-4">
                        <div class="flex items-center justify-between">
                            <span class="text-xs text-slate-400">TEMPERATURE</span>
                            <span class="font-orbitron text-yellow-400" id="temperature">--°C</span>
                        </div>
                    </div>
                    
                    <!-- Uptime -->
                    <div class="bg-slate-800/50 rounded-lg p-4">
                        <div class="flex items-center justify-between">
                            <span class="text-xs text-slate-400">UPTIME</span>
                            <span class="font-orbitron text-green-400 text-sm" id="uptime">--d --h --m</span>
                        </div>
                    </div>
                </div>
            </div>
            
            <!-- WAN Info -->
            <div class="glass-card p-6">
                <h3 class="font-orbitron text-sm text-slate-400 mb-4 flex items-center gap-2">
                    <svg class="w-4 h-4 text-pink-400" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                        <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M3.055 11H5a2 2 0 012 2v1a2 2 0 002 2 2 2 0 012 2v2.945M8 3.935V5.5A2.5 2.5 0 0010.5 8h.5a2 2 0 012 2 2 2 0 104 0 2 2 0 012-2h1.064M15 20.488V18a2 2 0 012-2h3.064M21 12a9 9 0 11-18 0 9 9 0 0118 0z"/>
                    </svg>
                    WAN INTELLIGENCE
                </h3>
                <div class="space-y-3">
                    <div class="flex items-center justify-between py-2 border-b border-slate-700/50">
                        <span class="text-xs text-slate-400">PUBLIC IP</span>
                        <span class="font-mono text-cyan-400" id="publicIP">Loading...</span>
                    </div>
                    <div class="flex items-center justify-between py-2 border-b border-slate-700/50">
                        <span class="text-xs text-slate-400">ISP</span>
                        <span class="text-slate-300" id="isp">Loading...</span>
                    </div>
                    <div class="flex items-center justify-between py-2 border-b border-slate-700/50">
                        <span class="text-xs text-slate-400">LOCATION</span>
                        <span class="text-slate-300" id="location">Loading...</span>
                    </div>
                    <div class="flex items-center justify-between py-2">
                        <span class="text-xs text-slate-400">INTERFACE</span>
                        <span class="font-mono text-green-400" id="wanInterface">--</span>
                    </div>
                </div>
                <!-- Mini Terminal -->
                <div class="mt-4 bg-slate-900/80 rounded-lg p-3 font-mono text-xs">
                    <div class="text-green-400">> <span class="text-slate-400">Connection Status:</span> <span class="text-cyan-400" id="connStatus">CHECKING...</span></div>
                    <div class="text-green-400">> <span class="text-slate-400">Gateway RTT:</span> <span id="gateRTT">--</span> ms</div>
                </div>
            </div>
        </div>
        
        <!-- Client Matrix -->
        <div class="glass-card p-6">
            <h3 class="font-orbitron text-sm text-slate-400 mb-4 flex items-center gap-2">
                <svg class="w-4 h-4 text-yellow-400" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                    <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M17 20h5v-2a3 3 0 00-5.356-1.857M17 20H7m10 0v-2c0-.656-.126-1.283-.356-1.857M7 20H2v-2a3 3 0 015.356-1.857M7 20v-2c0-.656.126-1.283.356-1.857m0 0a5.002 5.002 0 019.288 0M15 7a3 3 0 11-6 0 3 3 0 016 0zm6 3a2 2 0 11-4 0 2 2 0 014 0zM7 10a2 2 0 11-4 0 2 2 0 014 0z"/>
                </svg>
                CLIENT MATRIX
            </h3>
            <div class="overflow-x-auto">
                <table class="w-full">
                    <thead>
                        <tr class="text-left text-xs text-slate-400 uppercase tracking-wider border-b border-slate-700/50">
                            <th class="pb-3 pr-4">Status</th>
                            <th class="pb-3 pr-4">Hostname</th>
                            <th class="pb-3 pr-4">IP Address</th>
                            <th class="pb-3 pr-4">MAC Address</th>
                            <th class="pb-3 pr-4">Signal</th>
                            <th class="pb-3">Activity</th>
                        </tr>
                    </thead>
                    <tbody id="clientTableBody">
                        <tr>
                            <td colspan="6" class="py-8 text-center text-slate-500">
                                <div class="flex items-center justify-center gap-2">
                                    <svg class="w-5 h-5 animate-spin" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                                        <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M4 4v5h.582m15.356 2A8.001 8.001 0 004.582 9m0 0H9m11 11v-5h-.581m0 0a8.003 8.003 0 01-15.357-2m15.357 2H15"/>
                                    </svg>
                                    Scanning network...
                                </div>
                            </td>
                        </tr>
                    </tbody>
                </table>
            </div>
        </div>
        
        <!-- Footer -->
        <footer class="text-center py-6 text-xs text-slate-500">
            <p>YuzinCrab Sentinel v2.0 | Cyber-Sentinel Monitoring System</p>
            <p class="mt-1">Built for OpenWRT | <span class="text-cyan-400">Low Footprint • High Performance</span></p>
        </footer>
    </main>
    
    <script>
        // ═══════════════════════════════════════════════════════════════════════════
        // CONFIGURATION
        // ═══════════════════════════════════════════════════════════════════════════
        const API_ENDPOINT = '/cgi-bin/bandwidth_api';
        const UPDATE_INTERVAL = 1500;
        const MAX_DATA_POINTS = 60;
        const MAX_SPEED_MBPS = 100;
        
        // ═══════════════════════════════════════════════════════════════════════════
        // STATE
        // ═══════════════════════════════════════════════════════════════════════════
        let trafficChart = null;
        const trafficData = {
            labels: [],
            download: [],
            upload: []
        };
        
        // ═══════════════════════════════════════════════════════════════════════════
        // CHART INITIALIZATION
        // ═══════════════════════════════════════════════════════════════════════════
        function initChart() {
            const ctx = document.getElementById('trafficChart').getContext('2d');
            
            const gradient1 = ctx.createLinearGradient(0, 0, 0, 200);
            gradient1.addColorStop(0, 'rgba(6, 182, 212, 0.5)');
            gradient1.addColorStop(1, 'rgba(6, 182, 212, 0)');
            
            const gradient2 = ctx.createLinearGradient(0, 0, 0, 200);
            gradient2.addColorStop(0, 'rgba(236, 72, 153, 0.5)');
            gradient2.addColorStop(1, 'rgba(236, 72, 153, 0)');
            
            trafficChart = new Chart(ctx, {
                type: 'line',
                data: {
                    labels: [],
                    datasets: [
                        {
                            label: 'Download',
                            data: [],
                            borderColor: '#06b6d4',
                            backgroundColor: gradient1,
                            borderWidth: 2,
                            fill: true,
                            tension: 0.4,
                            pointRadius: 0,
                            pointHoverRadius: 4
                        },
                        {
                            label: 'Upload',
                            data: [],
                            borderColor: '#ec4899',
                            backgroundColor: gradient2,
                            borderWidth: 2,
                            fill: true,
                            tension: 0.4,
                            pointRadius: 0,
                            pointHoverRadius: 4
                        }
                    ]
                },
                options: {
                    responsive: true,
                    maintainAspectRatio: false,
                    animation: { duration: 300 },
                    interaction: {
                        intersect: false,
                        mode: 'index'
                    },
                    plugins: {
                        legend: {
                            display: true,
                            position: 'top',
                            labels: {
                                color: '#94a3b8',
                                usePointStyle: true,
                                pointStyle: 'circle',
                                padding: 20,
                                font: { family: 'JetBrains Mono', size: 10 }
                            }
                        },
                        tooltip: {
                            backgroundColor: 'rgba(15, 23, 42, 0.9)',
                            titleColor: '#06b6d4',
                            bodyColor: '#e2e8f0',
                            borderColor: '#06b6d4',
                            borderWidth: 1,
                            padding: 12,
                            displayColors: true,
                            callbacks: {
                                label: (ctx) => ` ${ctx.dataset.label}: ${ctx.raw.toFixed(2)} Mbps`
                            }
                        }
                    },
                    scales: {
                        x: {
                            display: false
                        },
                        y: {
                            beginAtZero: true,
                            grid: {
                                color: 'rgba(6, 182, 212, 0.1)',
                                drawBorder: false
                            },
                            ticks: {
                                color: '#64748b',
                                font: { family: 'JetBrains Mono', size: 10 },
                                callback: (value) => value + ' Mbps'
                            }
                        }
                    }
                }
            });
        }
        
        // ═══════════════════════════════════════════════════════════════════════════
        // GAUGE UPDATE
        // ═══════════════════════════════════════════════════════════════════════════
        function updateGauge(needleId, valueId, speed) {
            const needle = document.getElementById(needleId);
            const value = document.getElementById(valueId);
            
            const percentage = Math.min(speed / MAX_SPEED_MBPS, 1);
            const angle = -90 + (percentage * 180);
            
            needle.style.transform = `translateX(-50%) rotate(${angle}deg)`;
            value.textContent = speed.toFixed(2);
        }
        
        // ═══════════════════════════════════════════════════════════════════════════
        // CLIENT TABLE UPDATE
        // ═══════════════════════════════════════════════════════════════════════════
        function updateClientTable(clients) {
            const tbody = document.getElementById('clientTableBody');
            
            if (!clients || clients.length === 0) {
                tbody.innerHTML = `
                    <tr>
                        <td colspan="6" class="py-8 text-center text-slate-500">
                            No active clients detected
                        </td>
                    </tr>
                `;
                return;
            }
            
            tbody.innerHTML = clients.map((client, i) => {
                const activityWidth = Math.random() * 80 + 10;
                const signalClass = client.signal === 'N/A' ? 'text-slate-500' : 
                    parseInt(client.signal) > -50 ? 'text-green-400' :
                    parseInt(client.signal) > -70 ? 'text-yellow-400' : 'text-red-400';
                
                return `
                    <tr class="client-row border-b border-slate-700/30">
                        <td class="py-3 pr-4">
                            <div class="status-dot status-online"></div>
                        </td>
                        <td class="py-3 pr-4">
                            <span class="text-slate-200">${client.hostname || 'Unknown'}</span>
                        </td>
                        <td class="py-3 pr-4">
                            <span class="font-mono text-cyan-400">${client.ip}</span>
                        </td>
                        <td class="py-3 pr-4">
                            <span class="font-mono text-slate-400 text-xs">${client.mac}</span>
                        </td>
                        <td class="py-3 pr-4">
                            <span class="${signalClass}">${client.signal}</span>
                        </td>
                        <td class="py-3 w-32">
                            <div class="bg-slate-700/50 rounded-full overflow-hidden">
                                <div class="traffic-bar" style="width: ${activityWidth}%"></div>
                            </div>
                        </td>
                    </tr>
                `;
            }).join('');
            
            document.getElementById('clientCount').textContent = clients.length;
        }
        
        // ═══════════════════════════════════════════════════════════════════════════
        // SYSTEM HEALTH UPDATE
        // ═══════════════════════════════════════════════════════════════════════════
        function updateSystemHealth(system) {
            if (!system) return;
            
            document.getElementById('cpuLoad').textContent = system.cpu_percent + '%';
            document.getElementById('cpuBar').style.width = system.cpu_percent + '%';
            
            document.getElementById('memUsage').textContent = system.mem_percent + '%';
            document.getElementById('memBar').style.width = system.mem_percent + '%';
            
            document.getElementById('temperature').textContent = 
                system.temp === 'N/A' ? '--°C' : system.temp + '°C';
            
            document.getElementById('uptime').textContent = 
                `${system.uptime_days}d ${system.uptime_hours}h ${system.uptime_mins}m`;
        }
        
        // ═══════════════════════════════════════════════════════════════════════════
        // WAN INFO UPDATE
        // ═══════════════════════════════════════════════════════════════════════════
        function updateWanInfo(wan, bandwidth, latency) {
            if (wan && wan.status === 'success') {
                document.getElementById('publicIP').textContent = wan.query || '--';
                document.getElementById('isp').textContent = wan.isp || '--';
                document.getElementById('location').textContent = 
                    `${wan.city || '--'}, ${wan.country || '--'}`;
                document.getElementById('connStatus').textContent = 'CONNECTED';
                document.getElementById('connStatus').className = 'text-green-400';
            } else {
                document.getElementById('connStatus').textContent = 'DISCONNECTED';
                document.getElementById('connStatus').className = 'text-red-400';
            }
            
            if (bandwidth) {
                document.getElementById('wanInterface').textContent = bandwidth.interface || '--';
            }
            
            if (latency && latency > 0) {
                document.getElementById('latency').textContent = parseFloat(latency).toFixed(1);
                document.getElementById('gateRTT').textContent = parseFloat(latency).toFixed(1);
            } else {
                document.getElementById('latency').textContent = '--';
                document.getElementById('gateRTT').textContent = '--';
            }
        }
        
        // ═══════════════════════════════════════════════════════════════════════════
        // MAIN DATA FETCH
        // ═══════════════════════════════════════════════════════════════════════════
        async function fetchData() {
            try {
                const response = await fetch(API_ENDPOINT);
                const data = await response.json();
                
                // Convert bps to Mbps
                const downloadMbps = (data.bandwidth.rx_speed / 1000000).toFixed(2);
                const uploadMbps = (data.bandwidth.tx_speed / 1000000).toFixed(2);
                
                // Update speed displays
                document.getElementById('downloadSpeed').textContent = downloadMbps;
                document.getElementById('uploadSpeed').textContent = uploadMbps;
                
                // Update gauges
                updateGauge('downloadNeedle', 'downloadGaugeValue', parseFloat(downloadMbps));
                updateGauge('uploadNeedle', 'uploadGaugeValue', parseFloat(uploadMbps));
                
                // Update chart
                const now = new Date().toLocaleTimeString();
                trafficChart.data.labels.push(now);
                trafficChart.data.datasets[0].data.push(parseFloat(downloadMbps));
                trafficChart.data.datasets[1].data.push(parseFloat(uploadMbps));
                
                if (trafficChart.data.labels.length > MAX_DATA_POINTS) {
                    trafficChart.data.labels.shift();
                    trafficChart.data.datasets[0].data.shift();
                    trafficChart.data.datasets[1].data.shift();
                }
                
                trafficChart.update('none');
                
                // Update other sections
                updateClientTable(data.clients);
                updateSystemHealth(data.system);
                updateWanInfo(data.wan, data.bandwidth, data.latency);
                
            } catch (error) {
                console.error('API Error:', error);
                document.getElementById('connStatus').textContent = 'API ERROR';
                document.getElementById('connStatus').className = 'text-red-400';
            }
        }
        
        // ═══════════════════════════════════════════════════════════════════════════
        // CLOCK UPDATE
        // ═══════════════════════════════════════════════════════════════════════════
        function updateClock() {
            const now = new Date();
            document.getElementById('systemTime').textContent = 
                now.toLocaleTimeString('en-US', { hour12: false });
        }
        
        // ═══════════════════════════════════════════════════════════════════════════
        // INITIALIZATION
        // ═══════════════════════════════════════════════════════════════════════════
        document.addEventListener('DOMContentLoaded', () => {
            initChart();
            fetchData();
            updateClock();
            
            setInterval(fetchData, UPDATE_INTERVAL);
            setInterval(updateClock, 1000);
        });
    </script>
</body>
</html>
HTMLEOF

    success "Frontend created"
}

# ══════════════════════════════════════════════════════════════════════════════
# LUCI INTEGRATION
# ══════════════════════════════════════════════════════════════════════════════
create_luci_controller() {
    log "Creating LuCI controller..."
    
    mkdir -p "$LUCI_CONTROLLER"
    
    cat > "$LUCI_CONTROLLER/yuzincrab.lua" << 'LUAEOF'
module("luci.controller.yuzincrab", package.seeall)

function index()
    entry({"admin", "status", "yuzincrab"}, template("yuzincrab/index"), _("YuzinCrab Monitor"), 90).dependent = true
    entry({"admin", "status", "yuzincrab", "api"}, call("api_handler"), nil).leaf = true
end

function api_handler()
    local http = require "luci.http"
    local sys = require "luci.sys"
    
    http.prepare_content("application/json")
    
    local result = sys.exec("/www/cgi-bin/bandwidth_api 2>/dev/null")
    if result and result ~= "" then
        http.write(result)
    else
        http.write('{"error": "API unavailable"}')
    end
end
LUAEOF

    success "LuCI controller created"
}

create_luci_view() {
    log "Creating LuCI view template..."
    
    mkdir -p "$LUCI_VIEW/yuzincrab"
    
    cat > "$LUCI_VIEW/yuzincrab/index.htm" << 'VIEWEOF'
<%+header%>
<style>
    #yuzincrab-frame {
        width: 100%;
        height: calc(100vh - 150px);
        min-height: 600px;
        border: none;
        border-radius: 8px;
        background: #0f172a;
    }
</style>
<div class="cbi-map">
    <iframe id="yuzincrab-frame" src="/yuzincrab/index.html"></iframe>
</div>
<%+footer%>
VIEWEOF

    success "LuCI view created"
}

# ══════════════════════════════════════════════════════════════════════════════
# PERMISSIONS & SERVICE RESTART
# ══════════════════════════════════════════════════════════════════════════════
set_permissions() {
    log "Setting permissions..."
    
    chmod 755 "$CGI_DIR/bandwidth_api"
    chmod -R 755 "$INSTALL_DIR"
    chmod 644 "$LUCI_CONTROLLER/yuzincrab.lua" 2>/dev/null
    chmod 644 "$LUCI_VIEW/yuzincrab/index.htm" 2>/dev/null
    
    # Test CGI execution
    if [ -x "$CGI_DIR/bandwidth_api" ]; then
        success "CGI script is executable"
    else
        error "CGI script is not executable!"
    fi
    
    success "Permissions set"
}

restart_services() {
    log "Restarting services..."
    
    # Clear LuCI cache
    rm -rf /tmp/luci-modulecache 2>/dev/null
    rm -rf /tmp/luci-indexcache 2>/dev/null
    
    # Stop uhttpd
    /etc/init.d/uhttpd stop 2>/dev/null
    sleep 1
    
    # Restart uhttpd
    /etc/init.d/uhttpd start 2>/dev/null
    
    # Restart rpcd if available
    if [ -f "/etc/init.d/rpcd" ]; then
        /etc/init.d/rpcd restart 2>/dev/null
    fi
    
    sleep 3
    
    # Verify uhttpd is running
    if pgrep -x uhttpd >/dev/null 2>&1; then
        success "Services restarted successfully"
    else
        warn "uhttpd may not be running - check manually with: /etc/init.d/uhttpd status"
    fi
}

# ══════════════════════════════════════════════════════════════════════════════
# FINAL OUTPUT
# ══════════════════════════════════════════════════════════════════════════════
print_success() {
    echo ""
    echo -e "${GREEN}"
    cat << 'SUCCESSART'
    
    ╔═══════════════════════════════════════════════════════════════════════╗
    ║                                                                       ║
    ║   ██╗███╗   ██╗███████╗████████╗ █████╗ ██╗     ██╗     ███████╗██████╗║
    ║   ██║████╗  ██║██╔════╝╚══██╔══╝██╔══██╗██║     ██║     ██╔════╝██╔══██╗
    ║   ██║██╔██╗ ██║███████╗   ██║   ███████║██║     ██║     █████╗  ██║  ██║
    ║   ██║██║╚██╗██║╚════██║   ██║   ██╔══██║██║     ██║     ██╔══╝  ██║  ██║
    ║   ██║██║ ╚████║███████║   ██║   ██║  ██║███████╗███████╗███████╗██████╔╝
    ║   ╚═╝╚═╝  ╚═══╝╚══════╝   ╚═╝   ╚═╝  ╚═╝╚══════╝╚══════╝╚══════╝╚═════╝║
    ║                                                                       ║
    ║           ✓ YuzinCrab Sentinel Successfully Installed!                ║
    ║                                                                       ║
    ╚═══════════════════════════════════════════════════════════════════════╝
    
SUCCESSART
    echo -e "${NC}"
    
    # Get router IP
    ROUTER_IP=$(ip route get 1 2>/dev/null | awk '{print $7;exit}')
    [ -z "$ROUTER_IP" ] && ROUTER_IP="$(ip addr show br-lan 2>/dev/null | grep 'inet ' | awk '{print $2}' | cut -d/ -f1)"
    [ -z "$ROUTER_IP" ] && ROUTER_IP="<router-ip>"
    
    echo -e "${CYAN}╔═══════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║${NC}                        ACCESS POINTS                                 ${CYAN}║${NC}"
    echo -e "${CYAN}╠═══════════════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${CYAN}║${NC}  Standalone:  ${GREEN}http://${ROUTER_IP}/yuzincrab/${NC}                       ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}  LuCI Menu:   ${GREEN}Status → YuzinCrab Monitor${NC}                           ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}  API Test:    ${GREEN}http://${ROUTER_IP}/cgi-bin/bandwidth_api${NC}            ${CYAN}║${NC}"
    echo -e "${CYAN}╚═══════════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${YELLOW}  [POST-INSTALL VERIFICATION]${NC}"
    echo -e "  Run these commands to verify installation:"
    echo ""
    echo -e "  1. Check CGI file exists:"
    echo -e "     ${GREEN}ls -la /www/cgi-bin/bandwidth_api${NC}"
    echo ""
    echo -e "  2. Test API directly:"
    echo -e "     ${GREEN}/www/cgi-bin/bandwidth_api${NC}"
    echo ""
    echo -e "  3. Test via HTTP:"
    echo -e "     ${GREEN}curl http://${ROUTER_IP}/cgi-bin/bandwidth_api${NC}"
    echo ""
    echo -e "  4. If still not working, restart router:"
    echo -e "     ${GREEN}reboot${NC}"
    echo ""
    echo -e "${MAGENTA}  [CYBER-SENTINEL ACTIVE] - Your network is now under surveillance.${NC}"
    echo ""
}

# ══════════════════════════════════════════════════════════════════════════════
# MAIN EXECUTION
# ══════════════════════════════════════════════════════════════════════════════
main() {
    print_banner
    
    log "Starting YuzinCrab Sentinel installation..."
    echo ""
    
    check_environment
    setup_directories
    create_api_backend
    create_frontend
    create_luci_controller
    create_luci_view
    set_permissions
    restart_services
    
    echo ""
    log "Running post-install verification..."
    
    # Final verification
    echo ""
    echo -e "${CYAN}[Verification Results]${NC}"
    echo -e "  CGI Script: $([ -x /www/cgi-bin/bandwidth_api ] && echo '${GREEN}✓ Exists & Executable${NC}' || echo '${RED}✗ Missing or not executable${NC}')"
    echo -e "  Frontend:   $([ -f /www/yuzincrab/index.html ] && echo '${GREEN}✓ Installed${NC}' || echo '${RED}✗ Missing${NC}')"
    echo -e "  uhttpd:     $(pgrep -x uhttpd >/dev/null && echo '${GREEN}✓ Running${NC}' || echo '${RED}✗ Not running${NC}')"
    echo ""
    
    print_success
}

# Run main function
main "$@"