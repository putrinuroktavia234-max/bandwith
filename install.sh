#!/bin/sh
# ============================================================
# OpenWRT Bandwidth Monitor - One-Click Installation Script
# Version: 1.0.0
# Author: Network Engineer Assistant
# Compatible: OpenWRT 19.07+
# ============================================================

echo "╔════════════════════════════════════════════════════════════╗"
echo "║     OpenWRT Bandwidth Monitor - Installation Script       ║"
echo "║     Real-Time Network Monitoring Dashboard                ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Function to print status
print_status() {
    echo -e "${CYAN}[*]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[✓]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[!]${NC} $1"
}

print_error() {
    echo -e "${RED}[✗]${NC} $1"
}

# Check if running as root
if [ "$(id -u)" != "0" ]; then
    print_error "This script must be run as root"
    exit 1
fi

print_status "Starting installation..."

# ============================================================
# Step 1: Create directories
# ============================================================
print_status "Creating directories..."

mkdir -p /www/bandwidth
mkdir -p /www/cgi-bin
mkdir -p /usr/lib/lua/luci/controller

print_success "Directories created"

# ============================================================
# Step 2: Create CGI API Script - bandwidth_api.sh
# ============================================================
print_status "Creating CGI API script..."

cat > /www/cgi-bin/bandwidth_api.sh << 'BANDWIDTH_API_EOF'
#!/bin/sh

# Set content type
echo "Content-Type: application/json"
echo "Access-Control-Allow-Origin: *"
echo ""

# Get query string parameter
ACTION="${QUERY_STRING#action=}"

case "$ACTION" in
    "bandwidth")
        # Get network interface statistics from /proc/net/dev
        # Default to br-lan or eth0
        IFACE="br-lan"
        [ ! -d "/sys/class/net/$IFACE" ] && IFACE="eth0"
        
        RX_BYTES=$(cat /sys/class/net/$IFACE/statistics/rx_bytes 2>/dev/null || echo 0)
        TX_BYTES=$(cat /sys/class/net/$IFACE/statistics/tx_bytes 2>/dev/null || echo 0)
        
        # Get WAN interface for external traffic
        WAN_IFACE=$(uci get network.wan.ifname 2>/dev/null || echo "eth1")
        WAN_RX=$(cat /sys/class/net/$WAN_IFACE/statistics/rx_bytes 2>/dev/null || echo 0)
        WAN_TX=$(cat /sys/class/net/$WAN_IFACE/statistics/tx_bytes 2>/dev/null || echo 0)
        
        cat << EOF
{
    "status": "success",
    "timestamp": $(date +%s),
    "interface": "$IFACE",
    "wan_interface": "$WAN_IFACE",
    "rx_bytes": $RX_BYTES,
    "tx_bytes": $TX_BYTES,
    "wan_rx_bytes": $WAN_RX,
    "wan_tx_bytes": $WAN_TX
}
EOF
        ;;
        
    "devices")
        # Get connected devices from DHCP leases
        echo "{"
        echo "  \"status\": \"success\","
        echo "  \"devices\": ["
        
        FIRST=1
        if [ -f /tmp/dhcp.leases ]; then
            while read -r EXPIRE MAC IP HOSTNAME CLIENTID; do
                [ -z "$MAC" ] && continue
                [ "$FIRST" -eq 0 ] && echo ","
                FIRST=0
                
                # Determine device type based on MAC prefix
                MAC_PREFIX=$(echo "$MAC" | cut -d: -f1-3 | tr 'a-f' 'A-F')
                DEVICE_TYPE="other"
                
                case "$MAC_PREFIX" in
                    "00:1A:2B"|"F0:18:98"|"A4:83:E7") DEVICE_TYPE="laptop" ;;
                    "00:1E:C2"|"F8:1E:DF"|"AC:BC:32") DEVICE_TYPE="phone" ;;
                    "00:26:BB"|"7C:D1:C3"|"A8:51:5B") DEVICE_TYPE="tablet" ;;
                    "00:1D:7E"|"CC:2D:8C"|"78:BD:BC") DEVICE_TYPE="tv" ;;
                esac
                
                LEASE_TIME=$((EXPIRE - $(date +%s)))
                [ $LEASE_TIME -lt 0 ] && LEASE_TIME=0
                HOURS=$((LEASE_TIME / 3600))
                MINUTES=$(((LEASE_TIME % 3600) / 60))
                SECONDS=$((LEASE_TIME % 60))
                LEASE_FMT=$(printf "%02d:%02d:%02d" $HOURS $MINUTES $SECONDS)
                
                cat << DEVICE_EOF
    {
      "mac": "$MAC",
      "ip": "$IP",
      "hostname": "${HOSTNAME:-Unknown}",
      "leaseTime": "$LEASE_FMT",
      "type": "$DEVICE_TYPE"
    }
DEVICE_EOF
            done < /tmp/dhcp.leases
        fi
        
        echo ""
        echo "  ]"
        echo "}"
        ;;
        
    "uptime")
        # Get system uptime
        UPTIME_SEC=$(cat /proc/uptime | cut -d. -f1)
        DAYS=$((UPTIME_SEC / 86400))
        HOURS=$(((UPTIME_SEC % 86400) / 3600))
        MINUTES=$(((UPTIME_SEC % 3600) / 60))
        SECONDS=$((UPTIME_SEC % 60))
        
        # Get load average
        LOAD=$(cat /proc/loadavg | cut -d' ' -f1-3)
        
        # Get memory info
        MEM_TOTAL=$(grep MemTotal /proc/meminfo | awk '{print $2}')
        MEM_FREE=$(grep MemFree /proc/meminfo | awk '{print $2}')
        MEM_USED=$((MEM_TOTAL - MEM_FREE))
        MEM_PERCENT=$((MEM_USED * 100 / MEM_TOTAL))
        
        cat << EOF
{
    "status": "success",
    "uptime_seconds": $UPTIME_SEC,
    "uptime_formatted": "${DAYS}d ${HOURS}h ${MINUTES}m ${SECONDS}s",
    "load_average": "$LOAD",
    "memory": {
        "total_kb": $MEM_TOTAL,
        "used_kb": $MEM_USED,
        "free_kb": $MEM_FREE,
        "percent_used": $MEM_PERCENT
    }
}
EOF
        ;;
        
    "interfaces")
        # List all network interfaces with stats
        echo "{"
        echo "  \"status\": \"success\","
        echo "  \"interfaces\": ["
        
        FIRST=1
        for IFACE in /sys/class/net/*; do
            IFACE_NAME=$(basename "$IFACE")
            [ "$IFACE_NAME" = "lo" ] && continue
            
            [ "$FIRST" -eq 0 ] && echo ","
            FIRST=0
            
            RX=$(cat "$IFACE/statistics/rx_bytes" 2>/dev/null || echo 0)
            TX=$(cat "$IFACE/statistics/tx_bytes" 2>/dev/null || echo 0)
            STATE=$(cat "$IFACE/operstate" 2>/dev/null || echo "unknown")
            MAC=$(cat "$IFACE/address" 2>/dev/null || echo "00:00:00:00:00:00")
            
            cat << IFACE_EOF
    {
      "name": "$IFACE_NAME",
      "mac": "$MAC",
      "state": "$STATE",
      "rx_bytes": $RX,
      "tx_bytes": $TX
    }
IFACE_EOF
        done
        
        echo ""
        echo "  ]"
        echo "}"
        ;;
        
    *)
        # Default: return all stats
        echo "{"
        echo "  \"status\": \"error\","
        echo "  \"message\": \"Invalid action. Use: bandwidth, devices, uptime, interfaces\""
        echo "}"
        ;;
esac
BANDWIDTH_API_EOF

chmod +x /www/cgi-bin/bandwidth_api.sh
print_success "CGI API script created"

# ============================================================
# Step 3: Create main HTML Dashboard
# ============================================================
print_status "Creating HTML dashboard..."

cat > /www/bandwidth/index.html << 'HTML_EOF'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Bandwidth Monitor - OpenWRT</title>
    <script src="https://cdn.tailwindcss.com"></script>
    <script src="https://cdn.jsdelivr.net/npm/chart.js"></script>
    <style>
        :root {
            --bg-primary: #0a0f1a;
            --bg-secondary: #111827;
            --bg-glass: rgba(17, 24, 39, 0.7);
            --border-color: rgba(55, 65, 81, 0.5);
            --accent-cyan: #22d3ee;
            --accent-green: #22c55e;
            --accent-red: #ef4444;
            --accent-yellow: #eab308;
            --text-primary: #f9fafb;
            --text-secondary: #9ca3af;
        }
        
        body {
            background: var(--bg-primary);
            color: var(--text-primary);
            font-family: 'Inter', -apple-system, BlinkMacSystemFont, sans-serif;
        }
        
        .glass-card {
            background: var(--bg-glass);
            backdrop-filter: blur(20px);
            -webkit-backdrop-filter: blur(20px);
            border: 1px solid var(--border-color);
            border-radius: 1rem;
        }
        
        .gradient-text {
            background: linear-gradient(135deg, var(--accent-cyan), #3b82f6);
            -webkit-background-clip: text;
            -webkit-text-fill-color: transparent;
            background-clip: text;
        }
        
        .glow-cyan { box-shadow: 0 0 30px rgba(34, 211, 238, 0.3); }
        .glow-green { box-shadow: 0 0 30px rgba(34, 197, 94, 0.3); }
        
        .pulse-live::after {
            content: '';
            position: absolute;
            width: 8px;
            height: 8px;
            background: var(--accent-green);
            border-radius: 50%;
            animation: pulse-ring 1.5s ease-out infinite;
        }
        
        @keyframes pulse-ring {
            0% { box-shadow: 0 0 0 0 rgba(34, 197, 94, 0.7); }
            70% { box-shadow: 0 0 0 10px rgba(34, 197, 94, 0); }
            100% { box-shadow: 0 0 0 0 rgba(34, 197, 94, 0); }
        }
        
        .gauge-container { position: relative; }
        
        .device-item {
            transition: all 0.2s ease;
        }
        .device-item:hover {
            transform: translateX(4px);
            background: rgba(55, 65, 81, 0.5);
        }
        
        ::-webkit-scrollbar { width: 6px; }
        ::-webkit-scrollbar-track { background: var(--bg-secondary); border-radius: 3px; }
        ::-webkit-scrollbar-thumb { background: var(--accent-cyan); border-radius: 3px; opacity: 0.5; }
    </style>
</head>
<body class="min-h-screen p-4 md:p-6">
    <div class="max-w-7xl mx-auto space-y-6">
        <!-- Header -->
        <div class="flex flex-col md:flex-row md:items-center md:justify-between gap-4">
            <div>
                <h1 class="text-2xl md:text-3xl font-bold gradient-text">Bandwidth Monitor</h1>
                <p class="text-gray-400 mt-1">Real-time network statistics</p>
            </div>
            <div class="flex items-center gap-2 px-4 py-2 rounded-full bg-green-500/20 border border-green-500/30 self-start">
                <span class="w-2 h-2 rounded-full bg-green-500 animate-pulse"></span>
                <span class="text-sm font-medium text-green-400">Live</span>
            </div>
        </div>
        
        <!-- Speedometers -->
        <div class="grid grid-cols-1 md:grid-cols-2 gap-6">
            <div class="glass-card p-6">
                <div class="flex items-center gap-2 mb-4">
                    <svg class="w-5 h-5 text-cyan-400" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                        <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M19 14l-7 7m0 0l-7-7m7 7V3"/>
                    </svg>
                    <span class="font-medium">Download Speed</span>
                </div>
                <div class="gauge-container">
                    <canvas id="downloadGauge" width="300" height="180"></canvas>
                    <div class="absolute inset-0 flex flex-col items-center justify-end pb-4">
                        <span id="downloadValue" class="text-3xl font-bold text-cyan-400">0.00</span>
                        <span class="text-sm text-gray-400">Mbps</span>
                    </div>
                </div>
            </div>
            <div class="glass-card p-6">
                <div class="flex items-center gap-2 mb-4">
                    <svg class="w-5 h-5 text-green-400" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                        <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M5 10l7-7m0 0l7 7m-7-7v18"/>
                    </svg>
                    <span class="font-medium">Upload Speed</span>
                </div>
                <div class="gauge-container">
                    <canvas id="uploadGauge" width="300" height="180"></canvas>
                    <div class="absolute inset-0 flex flex-col items-center justify-end pb-4">
                        <span id="uploadValue" class="text-3xl font-bold text-green-400">0.00</span>
                        <span class="text-sm text-gray-400">Mbps</span>
                    </div>
                </div>
            </div>
        </div>
        
        <!-- Stats Grid -->
        <div class="grid grid-cols-2 md:grid-cols-4 gap-4">
            <div class="glass-card p-4 md:p-6 hover:glow-cyan transition-all">
                <div class="flex items-start justify-between">
                    <div class="p-2 md:p-3 rounded-xl bg-cyan-500/20">
                        <svg class="w-5 h-5 md:w-6 md:h-6 text-cyan-400" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M19 14l-7 7m0 0l-7-7m7 7V3"/>
                        </svg>
                    </div>
                </div>
                <div class="mt-3 md:mt-4">
                    <p class="text-xs md:text-sm text-gray-400">Total Downloaded</p>
                    <p id="totalDownload" class="text-lg md:text-2xl font-bold mt-1">0 GB</p>
                    <p class="text-xs text-gray-500 mt-1">This session</p>
                </div>
            </div>
            <div class="glass-card p-4 md:p-6 hover:glow-green transition-all">
                <div class="flex items-start justify-between">
                    <div class="p-2 md:p-3 rounded-xl bg-green-500/20">
                        <svg class="w-5 h-5 md:w-6 md:h-6 text-green-400" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M5 10l7-7m0 0l7 7m-7-7v18"/>
                        </svg>
                    </div>
                </div>
                <div class="mt-3 md:mt-4">
                    <p class="text-xs md:text-sm text-gray-400">Total Uploaded</p>
                    <p id="totalUpload" class="text-lg md:text-2xl font-bold mt-1">0 GB</p>
                    <p class="text-xs text-gray-500 mt-1">This session</p>
                </div>
            </div>
            <div class="glass-card p-4 md:p-6 hover:glow-cyan transition-all">
                <div class="flex items-start justify-between">
                    <div class="p-2 md:p-3 rounded-xl bg-yellow-500/20">
                        <svg class="w-5 h-5 md:w-6 md:h-6 text-yellow-400" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M8.111 16.404a5.5 5.5 0 017.778 0M12 20h.01m-7.08-7.071c3.904-3.905 10.236-3.905 14.141 0M1.394 9.393c5.857-5.857 15.355-5.857 21.213 0"/>
                        </svg>
                    </div>
                </div>
                <div class="mt-3 md:mt-4">
                    <p class="text-xs md:text-sm text-gray-400">Connected Devices</p>
                    <p id="deviceCount" class="text-lg md:text-2xl font-bold mt-1">0</p>
                    <p class="text-xs text-gray-500 mt-1">Active now</p>
                </div>
            </div>
            <div class="glass-card p-4 md:p-6 hover:glow-cyan transition-all">
                <div class="flex items-start justify-between">
                    <div class="p-2 md:p-3 rounded-xl bg-cyan-500/20">
                        <svg class="w-5 h-5 md:w-6 md:h-6 text-cyan-400" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 8v4l3 3m6-3a9 9 0 11-18 0 9 9 0 0118 0z"/>
                        </svg>
                    </div>
                </div>
                <div class="mt-3 md:mt-4">
                    <p class="text-xs md:text-sm text-gray-400">Router Uptime</p>
                    <p id="uptime" class="text-lg md:text-2xl font-bold mt-1">0d 0h 0m</p>
                    <p class="text-xs text-gray-500 mt-1">Since last restart</p>
                </div>
            </div>
        </div>
        
        <!-- Live Chart -->
        <div class="glass-card p-6">
            <div class="flex flex-col md:flex-row md:items-center md:justify-between mb-6 gap-4">
                <h3 class="text-lg font-semibold">Traffic History (Real-Time)</h3>
                <div class="flex items-center gap-4">
                    <div class="flex items-center gap-2">
                        <span class="w-3 h-3 rounded-full bg-cyan-400"></span>
                        <span class="text-sm text-gray-400">Download</span>
                    </div>
                    <div class="flex items-center gap-2">
                        <span class="w-3 h-3 rounded-full bg-green-400"></span>
                        <span class="text-sm text-gray-400">Upload</span>
                    </div>
                </div>
            </div>
            <div class="h-64">
                <canvas id="trafficChart"></canvas>
            </div>
        </div>
        
        <!-- Bottom Grid -->
        <div class="grid grid-cols-1 lg:grid-cols-2 gap-6">
            <!-- Device List -->
            <div class="glass-card p-6">
                <div class="flex items-center justify-between mb-6">
                    <h3 class="text-lg font-semibold">Connected Devices</h3>
                    <span id="onlineCount" class="px-3 py-1 rounded-full bg-cyan-500/20 text-cyan-400 text-sm font-medium">0 Online</span>
                </div>
                <div id="deviceList" class="space-y-3 max-h-80 overflow-y-auto pr-2">
                    <p class="text-gray-400 text-center py-4">Loading devices...</p>
                </div>
            </div>
            
            <!-- ISP Info -->
            <div class="glass-card p-6">
                <div class="flex items-center gap-3 mb-6">
                    <div class="p-3 rounded-xl bg-cyan-500/20">
                        <svg class="w-6 h-6 text-cyan-400" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M3.055 11H5a2 2 0 012 2v1a2 2 0 002 2 2 2 0 012 2v2.945M8 3.935V5.5A2.5 2.5 0 0010.5 8h.5a2 2 0 012 2 2 2 0 104 0 2 2 0 012-2h1.064M15 20.488V18a2 2 0 012-2h3.064M21 12a9 9 0 11-18 0 9 9 0 0118 0z"/>
                        </svg>
                    </div>
                    <div>
                        <h3 class="text-lg font-semibold">ISP & Network Info</h3>
                        <p class="text-sm text-gray-400">Connection details</p>
                    </div>
                </div>
                <div id="ispInfo" class="space-y-4">
                    <p class="text-gray-400 text-center py-4">Loading ISP info...</p>
                </div>
            </div>
        </div>
        
        <!-- Footer -->
        <div class="text-center py-4 text-sm text-gray-500">
            <p>OpenWRT Bandwidth Monitor v1.0.0 | Powered by Shell CGI</p>
        </div>
    </div>
    
    <script>
        // ============================================================
        // Configuration
        // ============================================================
        const API_BASE = '/cgi-bin/bandwidth_api.sh';
        const UPDATE_INTERVAL = 1000; // 1 second
        const MAX_DATA_POINTS = 60;
        
        // ============================================================
        // State
        // ============================================================
        let prevRxBytes = 0;
        let prevTxBytes = 0;
        let totalRxBytes = 0;
        let totalTxBytes = 0;
        let trafficData = [];
        let trafficChart = null;
        
        // ============================================================
        // Utility Functions
        // ============================================================
        function formatBytes(bytes) {
            if (bytes === 0) return '0 B';
            const k = 1024;
            const sizes = ['B', 'KB', 'MB', 'GB', 'TB'];
            const i = Math.floor(Math.log(bytes) / Math.log(k));
            return parseFloat((bytes / Math.pow(k, i)).toFixed(2)) + ' ' + sizes[i];
        }
        
        function bytesToMbps(bytes) {
            return (bytes * 8 / 1000000).toFixed(2);
        }
        
        // ============================================================
        // Gauge Drawing
        // ============================================================
        function drawGauge(canvasId, value, maxValue, color) {
            const canvas = document.getElementById(canvasId);
            const ctx = canvas.getContext('2d');
            const width = canvas.width;
            const height = canvas.height;
            const centerX = width / 2;
            const centerY = height - 10;
            const radius = Math.min(width, height) - 30;
            
            ctx.clearRect(0, 0, width, height);
            
            // Background arc
            ctx.beginPath();
            ctx.arc(centerX, centerY, radius, Math.PI, 0, false);
            ctx.strokeStyle = 'rgba(55, 65, 81, 0.5)';
            ctx.lineWidth = 15;
            ctx.lineCap = 'round';
            ctx.stroke();
            
            // Value arc
            const percentage = Math.min(value / maxValue, 1);
            const endAngle = Math.PI + (percentage * Math.PI);
            
            ctx.beginPath();
            ctx.arc(centerX, centerY, radius, Math.PI, endAngle, false);
            ctx.strokeStyle = color;
            ctx.lineWidth = 15;
            ctx.lineCap = 'round';
            ctx.shadowColor = color;
            ctx.shadowBlur = 15;
            ctx.stroke();
            ctx.shadowBlur = 0;
            
            // Tick marks
            for (let i = 0; i <= 4; i++) {
                const angle = Math.PI + (i / 4) * Math.PI;
                const innerRadius = radius - 25;
                const outerRadius = radius - 18;
                
                ctx.beginPath();
                ctx.moveTo(
                    centerX + Math.cos(angle) * innerRadius,
                    centerY + Math.sin(angle) * innerRadius
                );
                ctx.lineTo(
                    centerX + Math.cos(angle) * outerRadius,
                    centerY + Math.sin(angle) * outerRadius
                );
                ctx.strokeStyle = '#6b7280';
                ctx.lineWidth = 2;
                ctx.stroke();
            }
            
            // Needle
            const needleAngle = Math.PI + (percentage * Math.PI);
            const needleLength = radius - 30;
            
            ctx.beginPath();
            ctx.moveTo(centerX, centerY);
            ctx.lineTo(
                centerX + Math.cos(needleAngle) * needleLength,
                centerY + Math.sin(needleAngle) * needleLength
            );
            ctx.strokeStyle = '#f9fafb';
            ctx.lineWidth = 3;
            ctx.lineCap = 'round';
            ctx.stroke();
            
            // Center dot
            ctx.beginPath();
            ctx.arc(centerX, centerY, 8, 0, Math.PI * 2);
            ctx.fillStyle = '#f9fafb';
            ctx.fill();
        }
        
        // ============================================================
        // Chart Initialization
        // ============================================================
        function initChart() {
            const ctx = document.getElementById('trafficChart').getContext('2d');
            trafficChart = new Chart(ctx, {
                type: 'line',
                data: {
                    labels: [],
                    datasets: [
                        {
                            label: 'Download',
                            data: [],
                            borderColor: '#22d3ee',
                            backgroundColor: 'rgba(34, 211, 238, 0.1)',
                            fill: true,
                            tension: 0.4,
                            pointRadius: 0,
                            borderWidth: 2
                        },
                        {
                            label: 'Upload',
                            data: [],
                            borderColor: '#22c55e',
                            backgroundColor: 'rgba(34, 197, 94, 0.1)',
                            fill: true,
                            tension: 0.4,
                            pointRadius: 0,
                            borderWidth: 2
                        }
                    ]
                },
                options: {
                    responsive: true,
                    maintainAspectRatio: false,
                    plugins: {
                        legend: { display: false },
                        tooltip: {
                            mode: 'index',
                            intersect: false,
                            backgroundColor: 'rgba(17, 24, 39, 0.9)',
                            titleColor: '#f9fafb',
                            bodyColor: '#9ca3af',
                            borderColor: 'rgba(55, 65, 81, 0.5)',
                            borderWidth: 1
                        }
                    },
                    scales: {
                        x: {
                            grid: { color: 'rgba(55, 65, 81, 0.3)', drawBorder: false },
                            ticks: { color: '#9ca3af', maxTicksLimit: 10 }
                        },
                        y: {
                            grid: { color: 'rgba(55, 65, 81, 0.3)', drawBorder: false },
                            ticks: { color: '#9ca3af', callback: (v) => v + ' Mbps' },
                            beginAtZero: true
                        }
                    },
                    interaction: {
                        mode: 'nearest',
                        axis: 'x',
                        intersect: false
                    }
                }
            });
        }
        
        // ============================================================
        // API Calls
        // ============================================================
        async function fetchBandwidth() {
            try {
                const response = await fetch(API_BASE + '?action=bandwidth');
                const data = await response.json();
                
                if (data.status === 'success') {
                    const rxBytes = data.wan_rx_bytes || data.rx_bytes;
                    const txBytes = data.wan_tx_bytes || data.tx_bytes;
                    
                    if (prevRxBytes > 0) {
                        const rxDiff = rxBytes - prevRxBytes;
                        const txDiff = txBytes - prevTxBytes;
                        
                        const downloadMbps = parseFloat(bytesToMbps(rxDiff));
                        const uploadMbps = parseFloat(bytesToMbps(txDiff));
                        
                        totalRxBytes += rxDiff;
                        totalTxBytes += txDiff;
                        
                        // Update gauges
                        drawGauge('downloadGauge', downloadMbps, 100, '#22d3ee');
                        drawGauge('uploadGauge', uploadMbps, 50, '#22c55e');
                        
                        document.getElementById('downloadValue').textContent = downloadMbps.toFixed(2);
                        document.getElementById('uploadValue').textContent = uploadMbps.toFixed(2);
                        
                        // Update totals
                        document.getElementById('totalDownload').textContent = formatBytes(totalRxBytes);
                        document.getElementById('totalUpload').textContent = formatBytes(totalTxBytes);
                        
                        // Update chart
                        const now = new Date().toLocaleTimeString('en-US', { hour12: false });
                        trafficChart.data.labels.push(now);
                        trafficChart.data.datasets[0].data.push(downloadMbps);
                        trafficChart.data.datasets[1].data.push(uploadMbps);
                        
                        if (trafficChart.data.labels.length > MAX_DATA_POINTS) {
                            trafficChart.data.labels.shift();
                            trafficChart.data.datasets[0].data.shift();
                            trafficChart.data.datasets[1].data.shift();
                        }
                        
                        trafficChart.update('none');
                    }
                    
                    prevRxBytes = rxBytes;
                    prevTxBytes = txBytes;
                }
            } catch (error) {
                console.error('Failed to fetch bandwidth:', error);
            }
        }
        
        async function fetchDevices() {
            try {
                const response = await fetch(API_BASE + '?action=devices');
                const data = await response.json();
                
                if (data.status === 'success') {
                    const deviceList = document.getElementById('deviceList');
                    const deviceCount = document.getElementById('deviceCount');
                    const onlineCount = document.getElementById('onlineCount');
                    
                    deviceCount.textContent = data.devices.length;
                    onlineCount.textContent = data.devices.length + ' Online';
                    
                    if (data.devices.length === 0) {
                        deviceList.innerHTML = '<p class="text-gray-400 text-center py-4">No devices connected</p>';
                        return;
                    }
                    
                    deviceList.innerHTML = data.devices.map(device => {
                        const icon = getDeviceIcon(device.type);
                        return `
                            <div class="device-item flex items-center gap-4 p-4 rounded-xl bg-gray-800/50">
                                <div class="p-2 rounded-lg bg-gray-700">
                                    ${icon}
                                </div>
                                <div class="flex-1 min-w-0">
                                    <p class="font-medium truncate">${device.hostname}</p>
                                    <p class="text-sm text-gray-400">${device.ip} • ${device.mac}</p>
                                </div>
                                <div class="text-right">
                                    <span class="inline-flex items-center gap-1.5 text-xs text-green-400">
                                        <span class="w-1.5 h-1.5 rounded-full bg-green-400 animate-pulse"></span>
                                        Online
                                    </span>
                                    <p class="text-xs text-gray-500 mt-1">${device.leaseTime}</p>
                                </div>
                            </div>
                        `;
                    }).join('');
                }
            } catch (error) {
                console.error('Failed to fetch devices:', error);
            }
        }
        
        async function fetchUptime() {
            try {
                const response = await fetch(API_BASE + '?action=uptime');
                const data = await response.json();
                
                if (data.status === 'success') {
                    document.getElementById('uptime').textContent = data.uptime_formatted;
                }
            } catch (error) {
                console.error('Failed to fetch uptime:', error);
            }
        }
        
        async function fetchISPInfo() {
            try {
                const response = await fetch('https://ipapi.co/json/');
                const data = await response.json();
                
                const ispInfo = document.getElementById('ispInfo');
                ispInfo.innerHTML = `
                    <div class="flex items-center justify-between p-3 rounded-xl bg-gray-800/50">
                        <div class="flex items-center gap-3">
                            <svg class="w-4 h-4 text-gray-400" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                                <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M5 12h14M5 12a2 2 0 01-2-2V6a2 2 0 012-2h14a2 2 0 012 2v4a2 2 0 01-2 2M5 12a2 2 0 00-2 2v4a2 2 0 002 2h14a2 2 0 002-2v-4a2 2 0 00-2-2m-2-4h.01M17 16h.01"/>
                            </svg>
                            <span class="text-sm text-gray-400">Public IP</span>
                        </div>
                        <span class="font-mono text-sm font-medium">${data.ip || 'N/A'}</span>
                    </div>
                    <div class="flex items-center justify-between p-3 rounded-xl bg-gray-800/50">
                        <div class="flex items-center gap-3">
                            <svg class="w-4 h-4 text-gray-400" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                                <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M21 12a9 9 0 01-9 9m9-9a9 9 0 00-9-9m9 9H3m9 9a9 9 0 01-9-9m9 9c1.657 0 3-4.03 3-9s-1.343-9-3-9m0 18c-1.657 0-3-4.03-3-9s1.343-9 3-9m-9 9a9 9 0 019-9"/>
                            </svg>
                            <span class="text-sm text-gray-400">ISP</span>
                        </div>
                        <span class="text-sm font-medium">${data.org || 'N/A'}</span>
                    </div>
                    <div class="flex items-center justify-between p-3 rounded-xl bg-gray-800/50">
                        <div class="flex items-center gap-3">
                            <svg class="w-4 h-4 text-gray-400" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                                <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M17.657 16.657L13.414 20.9a1.998 1.998 0 01-2.827 0l-4.244-4.243a8 8 0 1111.314 0z"/>
                                <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M15 11a3 3 0 11-6 0 3 3 0 016 0z"/>
                            </svg>
                            <span class="text-sm text-gray-400">Location</span>
                        </div>
                        <span class="text-sm font-medium">${data.city || 'N/A'}, ${data.region || ''}, ${data.country_name || 'N/A'}</span>
                    </div>
                    <div class="flex items-center justify-between p-3 rounded-xl bg-gray-800/50">
                        <div class="flex items-center gap-3">
                            <svg class="w-4 h-4 text-gray-400" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                                <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M9 12l2 2 4-4m5.618-4.016A11.955 11.955 0 0112 2.944a11.955 11.955 0 01-8.618 3.04A12.02 12.02 0 003 9c0 5.591 3.824 10.29 9 11.622 5.176-1.332 9-6.03 9-11.622 0-1.042-.133-2.052-.382-3.016z"/>
                            </svg>
                            <span class="text-sm text-gray-400">ASN</span>
                        </div>
                        <span class="text-sm font-medium">${data.asn || 'N/A'}</span>
                    </div>
                `;
            } catch (error) {
                console.error('Failed to fetch ISP info:', error);
                document.getElementById('ispInfo').innerHTML = '<p class="text-gray-400 text-center py-4">Failed to load ISP info</p>';
            }
        }
        
        function getDeviceIcon(type) {
            const icons = {
                laptop: '<svg class="w-5 h-5 text-cyan-400" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M9.75 17L9 20l-1 1h8l-1-1-.75-3M3 13h18M5 17h14a2 2 0 002-2V5a2 2 0 00-2-2H5a2 2 0 00-2 2v10a2 2 0 002 2z"/></svg>',
                phone: '<svg class="w-5 h-5 text-cyan-400" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 18h.01M8 21h8a2 2 0 002-2V5a2 2 0 00-2-2H8a2 2 0 00-2 2v14a2 2 0 002 2z"/></svg>',
                tablet: '<svg class="w-5 h-5 text-cyan-400" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 18h.01M7 21h10a2 2 0 002-2V5a2 2 0 00-2-2H7a2 2 0 00-2 2v14a2 2 0 002 2z"/></svg>',
                tv: '<svg class="w-5 h-5 text-cyan-400" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M9.75 17L9 20l-1 1h8l-1-1-.75-3M3 13h18M5 17h14a2 2 0 002-2V5a2 2 0 00-2-2H5a2 2 0 00-2 2v10a2 2 0 002 2z"/></svg>',
                other: '<svg class="w-5 h-5 text-cyan-400" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M8.111 16.404a5.5 5.5 0 017.778 0M12 20h.01m-7.08-7.071c3.904-3.905 10.236-3.905 14.141 0M1.394 9.393c5.857-5.857 15.355-5.857 21.213 0"/></svg>'
            };
            return icons[type] || icons.other;
        }
        
        // ============================================================
        // Initialize
        // ============================================================
        document.addEventListener('DOMContentLoaded', () => {
            initChart();
            
            // Initial draws
            drawGauge('downloadGauge', 0, 100, '#22d3ee');
            drawGauge('uploadGauge', 0, 50, '#22c55e');
            
            // Fetch initial data
            fetchBandwidth();
            fetchDevices();
            fetchUptime();
            fetchISPInfo();
            
            // Set up intervals
            setInterval(fetchBandwidth, UPDATE_INTERVAL);
            setInterval(fetchDevices, 10000);
            setInterval(fetchUptime, 60000);
        });
    </script>
</body>
</html>
HTML_EOF

print_success "HTML dashboard created"

# ============================================================
# Step 4: Create LuCI Controller
# ============================================================
print_status "Creating LuCI controller..."

cat > /usr/lib/lua/luci/controller/bandwidth.lua << 'LUA_EOF'
module("luci.controller.bandwidth", package.seeall)

function index()
    entry({"admin", "status", "bandwidth"}, template("bandwidth/monitor"), _("Bandwidth Monitor"), 90)
end
LUA_EOF

# Create LuCI template directory and file
mkdir -p /usr/lib/lua/luci/view/bandwidth

cat > /usr/lib/lua/luci/view/bandwidth/monitor.htm << 'TEMPLATE_EOF'
<%+header%>

<div style="margin: -20px; height: calc(100vh - 100px);">
    <iframe 
        src="/bandwidth/" 
        style="width: 100%; height: 100%; border: none;"
        frameborder="0"
    ></iframe>
</div>

<%+footer%>
TEMPLATE_EOF

print_success "LuCI controller created"

# ============================================================
# Step 5: Configure uhttpd
# ============================================================
print_status "Configuring uhttpd..."

# Add CGI handler if not exists
if ! grep -q "bandwidth_api" /etc/config/uhttpd 2>/dev/null; then
    uci add_list uhttpd.main.cgi_prefix='/cgi-bin' 2>/dev/null || true
fi

# Set CGI script handler
uci set uhttpd.main.interpreter='.sh=/bin/sh' 2>/dev/null || true
uci commit uhttpd 2>/dev/null || true

print_success "uhttpd configured"

# ============================================================
# Step 6: Set permissions
# ============================================================
print_status "Setting permissions..."

chmod 755 /www/bandwidth
chmod 644 /www/bandwidth/index.html
chmod 755 /www/cgi-bin
chmod 755 /www/cgi-bin/bandwidth_api.sh
chmod 644 /usr/lib/lua/luci/controller/bandwidth.lua
chmod 644 /usr/lib/lua/luci/view/bandwidth/monitor.htm

print_success "Permissions set"

# ============================================================
# Step 7: Restart services
# ============================================================
print_status "Restarting services..."

/etc/init.d/uhttpd restart
rm -rf /tmp/luci-indexcache /tmp/luci-modulecache 2>/dev/null

print_success "Services restarted"

# ============================================================
# Installation Complete
# ============================================================
echo ""
echo "╔════════════════════════════════════════════════════════════╗"
echo "║              Installation Complete!                        ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""
echo -e "${GREEN}Access your Bandwidth Monitor:${NC}"
echo ""
echo -e "  Direct URL:  ${CYAN}http://192.168.1.1/bandwidth/${NC}"
echo -e "  LuCI Menu:   ${CYAN}Status > Bandwidth Monitor${NC}"
echo ""
echo -e "${YELLOW}Files installed:${NC}"
echo "  /www/bandwidth/index.html"
echo "  /www/cgi-bin/bandwidth_api.sh"
echo "  /usr/lib/lua/luci/controller/bandwidth.lua"
echo "  /usr/lib/lua/luci/view/bandwidth/monitor.htm"
echo ""
echo -e "${GREEN}Enjoy your new Bandwidth Monitor!${NC}"
