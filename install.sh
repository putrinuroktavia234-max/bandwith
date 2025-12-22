#!/bin/sh
# ================================
# OpenWrt Bandwidth Monitor v3.0
# Enhanced with Charts & Speedometer
# ================================

echo "========================================"
echo "  OpenWrt Bandwidth Monitor v3.0"
echo "========================================"

if [ "$(id -u)" != "0" ]; then
   echo "Error: Jalankan sebagai root"
   exit 1
fi

echo "[1/7] Installing dependencies..."
opkg update >/dev/null 2>&1
opkg install vnstat coreutils-stat >/dev/null 2>&1

echo "[2/7] Creating directories..."
mkdir -p /www/with/cgi-bin
mkdir -p /www/with/css
mkdir -p /www/with/js
mkdir -p /var/bandwidth
mkdir -p /var/bandwidth/history

echo "[3/7] Creating enhanced API script..."
cat > /www/with/cgi-bin/api.cgi << 'APISCRIPT'
#!/bin/sh
echo "Content-Type: application/json"
echo "Access-Control-Allow-Origin: *"
echo ""

QUERY_STRING="${QUERY_STRING:-}"
ACTION=$(echo "$QUERY_STRING" | sed 's/.*action=\([^&]*\).*/\1/')

get_bandwidth() {
    IFACE="br-lan"
    [ ! -d "/sys/class/net/$IFACE" ] && IFACE="eth0"
    
    RX1=$(cat /sys/class/net/$IFACE/statistics/rx_bytes 2>/dev/null || echo 0)
    TX1=$(cat /sys/class/net/$IFACE/statistics/tx_bytes 2>/dev/null || echo 0)
    sleep 1
    RX2=$(cat /sys/class/net/$IFACE/statistics/rx_bytes 2>/dev/null || echo 0)
    TX2=$(cat /sys/class/net/$IFACE/statistics/tx_bytes 2>/dev/null || echo 0)
    
    RX_SPEED=$((RX2 - RX1))
    TX_SPEED=$((TX2 - TX1))
    
    RX_MBPS=$(awk "BEGIN {printf \"%.2f\", $RX_SPEED * 8 / 1000000}")
    TX_MBPS=$(awk "BEGIN {printf \"%.2f\", $TX_SPEED * 8 / 1000000}")
    
    # Save to history
    NOW=$(date +%s)
    echo "$NOW,$RX_MBPS,$TX_MBPS" >> /var/bandwidth/history/realtime.csv
    tail -60 /var/bandwidth/history/realtime.csv > /var/bandwidth/history/realtime.tmp
    mv /var/bandwidth/history/realtime.tmp /var/bandwidth/history/realtime.csv
    
    echo "{\"download_speed\":\"$RX_MBPS\",\"upload_speed\":\"$TX_MBPS\",\"download_bytes\":\"$RX2\",\"upload_bytes\":\"$TX2\",\"timestamp\":\"$NOW\"}"
}

get_history() {
    echo "{\"history\":["
    FIRST=1
    cat /var/bandwidth/history/realtime.csv 2>/dev/null | tail -30 | while read LINE; do
        TS=$(echo "$LINE" | cut -d',' -f1)
        DL=$(echo "$LINE" | cut -d',' -f2)
        UL=$(echo "$LINE" | cut -d',' -f3)
        [ "$FIRST" -eq 0 ] && echo ","
        FIRST=0
        echo "{\"time\":$TS,\"download\":$DL,\"upload\":$UL}"
    done
    echo "]}"
}

get_usage() {
    IFACE="br-lan"
    [ ! -d "/sys/class/net/$IFACE" ] && IFACE="eth0"
    
    RX_TOTAL=$(cat /sys/class/net/$IFACE/statistics/rx_bytes 2>/dev/null || echo 0)
    TX_TOTAL=$(cat /sys/class/net/$IFACE/statistics/tx_bytes 2>/dev/null || echo 0)
    
    TODAY=$(date +%Y%m%d)
    MONTH=$(date +%Y%m)
    
    DAILY_FILE="/var/bandwidth/daily_$TODAY.txt"
    if [ ! -f "$DAILY_FILE" ]; then
        echo "$RX_TOTAL,$TX_TOTAL" > "$DAILY_FILE"
    fi
    
    DAILY_START=$(cat "$DAILY_FILE" 2>/dev/null)
    DAILY_RX_START=$(echo "$DAILY_START" | cut -d',' -f1)
    DAILY_TX_START=$(echo "$DAILY_START" | cut -d',' -f2)
    
    DAILY_RX=$((RX_TOTAL - DAILY_RX_START))
    DAILY_TX=$((TX_TOTAL - DAILY_TX_START))
    [ $DAILY_RX -lt 0 ] && DAILY_RX=0
    [ $DAILY_TX -lt 0 ] && DAILY_TX=0
    
    QUOTA_DAILY=$(grep "quota_daily" /var/bandwidth/config.txt 2>/dev/null | cut -d'=' -f2)
    QUOTA_MONTHLY=$(grep "quota_monthly" /var/bandwidth/config.txt 2>/dev/null | cut -d'=' -f2)
    [ -z "$QUOTA_DAILY" ] && QUOTA_DAILY=5368709120
    [ -z "$QUOTA_MONTHLY" ] && QUOTA_MONTHLY=107374182400
    
    echo "{\"daily\":{\"download\":$DAILY_RX,\"upload\":$DAILY_TX,\"total\":$((DAILY_RX+DAILY_TX))},\"monthly\":{\"download\":$RX_TOTAL,\"upload\":$TX_TOTAL,\"total\":$((RX_TOTAL+TX_TOTAL))},\"quota\":{\"daily\":$QUOTA_DAILY,\"monthly\":$QUOTA_MONTHLY}}"
}

get_clients() {
    echo "{\"clients\":["
    FIRST=1
    NOW=$(date +%s)
    
    cat /tmp/dhcp.leases 2>/dev/null | while read EXPIRE MAC IP HOSTNAME REST; do
        [ -z "$MAC" ] && continue
        [ "$FIRST" -eq 0 ] && echo ","
        FIRST=0
        
        # Calculate connection time from lease expiry (usually 12h lease = 43200s)
        LEASE_TIME=$((EXPIRE - NOW))
        CONNECTED_TIME=$((43200 - LEASE_TIME))
        [ $CONNECTED_TIME -lt 0 ] && CONNECTED_TIME=0
        
        SIGNAL=""
        TYPE="lan"
        for WDEV in $(ls /sys/class/ieee80211/*/device/net/ 2>/dev/null); do
            if iw dev $WDEV station dump 2>/dev/null | grep -qi "$MAC"; then
                TYPE="wifi"
                SIGNAL=$(iw dev $WDEV station get $MAC 2>/dev/null | grep "signal:" | awk '{print $2}')
                break
            fi
        done
        
        # Get per-device traffic from iptables if available
        USAGE_RX=0
        USAGE_TX=0
        
        [ -z "$HOSTNAME" ] && HOSTNAME="Unknown"
        echo "{\"mac\":\"$MAC\",\"ip\":\"$IP\",\"hostname\":\"$HOSTNAME\",\"type\":\"$TYPE\",\"signal\":\"$SIGNAL\",\"connected_time\":$CONNECTED_TIME,\"usage_rx\":$USAGE_RX,\"usage_tx\":$USAGE_TX}"
    done
    echo "]}"
}

get_system() {
    UPTIME=$(cat /proc/uptime | awk '{print int($1)}')
    LOAD=$(cat /proc/loadavg | awk '{print $1}')
    
    MEM_TOTAL=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    MEM_FREE=$(grep MemFree /proc/meminfo | awk '{print $2}')
    MEM_USED=$((MEM_TOTAL - MEM_FREE))
    
    ROUTER_NAME=$(grep "router_name" /var/bandwidth/config.txt 2>/dev/null | cut -d'=' -f2)
    OWNER_NAME=$(grep "owner_name" /var/bandwidth/config.txt 2>/dev/null | cut -d'=' -f2)
    [ -z "$ROUTER_NAME" ] && ROUTER_NAME="OpenWrt Router"
    [ -z "$OWNER_NAME" ] && OWNER_NAME="Admin"
    
    echo "{\"uptime\":$UPTIME,\"load\":\"$LOAD\",\"mem_total\":$MEM_TOTAL,\"mem_used\":$MEM_USED,\"router_name\":\"$ROUTER_NAME\",\"owner_name\":\"$OWNER_NAME\"}"
}

speedtest() {
    # Real speedtest using curl to measure actual internet speed
    DL_SPEED=0
    UL_SPEED=0
    PING=0
    
    # Test ping to Google DNS
    PING_RESULT=$(ping -c 3 8.8.8.8 2>/dev/null | tail -1 | awk -F'/' '{print $5}')
    [ -n "$PING_RESULT" ] && PING=$(printf "%.0f" "$PING_RESULT")
    
    # Download test - 1MB file from fast.com CDN
    DL_START=$(date +%s%3N)
    curl -o /dev/null -s --max-time 10 "http://speedtest.tele2.net/1MB.zip" 2>/dev/null
    DL_END=$(date +%s%3N)
    DL_TIME=$((DL_END - DL_START))
    [ $DL_TIME -gt 0 ] && DL_SPEED=$(awk "BEGIN {printf \"%.2f\", (1 * 8) / ($DL_TIME / 1000)}")
    
    # Upload test - Create 256KB temp file and upload
    dd if=/dev/zero of=/tmp/upload_test bs=256K count=1 2>/dev/null
    UL_START=$(date +%s%3N)
    curl -X POST -d @/tmp/upload_test -s --max-time 10 "http://speedtest.tele2.net/upload.php" 2>/dev/null
    UL_END=$(date +%s%3N)
    UL_TIME=$((UL_END - UL_START))
    [ $UL_TIME -gt 0 ] && UL_SPEED=$(awk "BEGIN {printf \"%.2f\", (0.25 * 8) / ($UL_TIME / 1000)}")
    rm -f /tmp/upload_test
    
    echo "{\"download\":$DL_SPEED,\"upload\":$UL_SPEED,\"ping\":$PING}"
}

save_config() {
    read -r POST_DATA
    touch /var/bandwidth/config.txt
    
    echo "$POST_DATA" | tr '&' '\n' | while read LINE; do
        KEY=$(echo "$LINE" | cut -d'=' -f1)
        VALUE=$(echo "$LINE" | cut -d'=' -f2- | sed 's/%20/ /g;s/+/ /g')
        sed -i "/^$KEY=/d" /var/bandwidth/config.txt
        echo "$KEY=$VALUE" >> /var/bandwidth/config.txt
    done
    
    echo "{\"status\":\"ok\"}"
}

case "$ACTION" in
    bandwidth) get_bandwidth ;;
    history) get_history ;;
    usage) get_usage ;;
    clients) get_clients ;;
    system) get_system ;;
    speedtest) speedtest ;;
    save_config) save_config ;;
    *) echo "{\"actions\":[\"bandwidth\",\"history\",\"usage\",\"clients\",\"system\",\"speedtest\",\"save_config\"]}" ;;
esac
APISCRIPT

chmod +x /www/with/cgi-bin/api.cgi

echo "[4/7] Creating enhanced HTML..."
cat > /www/with/index.html << 'HTMLFILE'
<!DOCTYPE html>
<html lang="id">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>OpenWrt Network Monitor</title>
<link rel="stylesheet" href="css/style.css">
<link rel="preconnect" href="https://fonts.googleapis.com">
<link href="https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700;800&display=swap" rel="stylesheet">
</head>
<body>
<div class="app">
  <header class="header">
    <div class="header-left">
      <div class="logo">
        <svg viewBox="0 0 50 50">
          <defs>
            <linearGradient id="lg" x1="0%" y1="0%" x2="100%" y2="100%">
              <stop offset="0%" stop-color="#3b82f6"/>
              <stop offset="100%" stop-color="#8b5cf6"/>
            </linearGradient>
          </defs>
          <circle cx="25" cy="25" r="23" fill="url(#lg)"/>
          <path d="M15 30 L25 20 L35 30" stroke="#fff" stroke-width="3" fill="none" stroke-linecap="round"/>
          <path d="M18 33 L25 26 L32 33" stroke="#fff" stroke-width="2.5" fill="none" stroke-linecap="round" opacity=".7"/>
          <circle cx="25" cy="38" r="2" fill="#fff"/>
        </svg>
      </div>
      <div class="header-info">
        <h1 id="routerName">OpenWrt Router</h1>
        <span id="ownerName">Admin</span>
      </div>
    </div>
    <div class="header-right">
      <div class="status online"><span class="pulse"></span>Online</div>
      <button class="btn-icon" onclick="openSettings()">
        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><circle cx="12" cy="12" r="3"/><path d="M12 1v2M12 21v2M4.22 4.22l1.42 1.42M18.36 18.36l1.42 1.42M1 12h2M21 12h2M4.22 19.78l1.42-1.42M18.36 5.64l1.42-1.42"/></svg>
      </button>
    </div>
  </header>

  <main class="dashboard">
    <!-- Speed Cards -->
    <section class="speed-section">
      <div class="speed-card download">
        <div class="speed-header">
          <div class="speed-icon download">
            <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M21 15v4a2 2 0 01-2 2H5a2 2 0 01-2-2v-4M7 10l5 5 5-5M12 15V3"/></svg>
          </div>
          <span class="speed-label">Download</span>
        </div>
        <div class="speed-display">
          <span class="speed-value" id="downloadSpeed">0.00</span>
          <span class="speed-unit">Mbps</span>
        </div>
        <div class="speed-bar">
          <div class="speed-bar-fill download" id="downloadBar"></div>
        </div>
      </div>
      <div class="speed-card upload">
        <div class="speed-header">
          <div class="speed-icon upload">
            <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M21 15v4a2 2 0 01-2 2H5a2 2 0 01-2-2v-4M17 8l-5-5-5 5M12 3v12"/></svg>
          </div>
          <span class="speed-label">Upload</span>
        </div>
        <div class="speed-display">
          <span class="speed-value" id="uploadSpeed">0.00</span>
          <span class="speed-unit">Mbps</span>
        </div>
        <div class="speed-bar">
          <div class="speed-bar-fill upload" id="uploadBar"></div>
        </div>
      </div>
    </section>

    <!-- Bandwidth Chart -->
    <section class="chart-section">
      <div class="section-header">
        <h2><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" class="section-icon"><path d="M3 3v18h18"/><path d="M18 17V9M13 17V5M8 17v-3"/></svg>Grafik Bandwidth Real-time</h2>
      </div>
      <div class="chart-container">
        <canvas id="bandwidthChart"></canvas>
      </div>
    </section>

    <!-- Usage Section -->
    <section class="usage-section">
      <div class="usage-card daily">
        <div class="usage-header">
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" class="usage-icon"><rect x="3" y="4" width="18" height="18" rx="2"/><path d="M16 2v4M8 2v4M3 10h18"/></svg>
          <h3>Pemakaian Hari Ini</h3>
        </div>
        <div class="usage-ring">
          <svg viewBox="0 0 100 100">
            <circle cx="50" cy="50" r="42" fill="none" stroke="#1e293b" stroke-width="8"/>
            <circle cx="50" cy="50" r="42" fill="none" stroke="url(#dailyGrad)" stroke-width="8" 
                    stroke-dasharray="264" stroke-dashoffset="264" stroke-linecap="round"
                    id="dailyRing" transform="rotate(-90 50 50)"/>
            <defs>
              <linearGradient id="dailyGrad" x1="0%" y1="0%" x2="100%" y2="0%">
                <stop offset="0%" stop-color="#3b82f6"/>
                <stop offset="100%" stop-color="#8b5cf6"/>
              </linearGradient>
            </defs>
          </svg>
          <div class="usage-ring-text">
            <span class="usage-ring-value" id="dailyPercent">0%</span>
          </div>
        </div>
        <div class="usage-stats">
          <div class="stat"><span class="stat-value" id="dailyTotal">0 MB</span><span class="stat-label">Total</span></div>
          <div class="stat"><span class="stat-value" id="dailyDownload">0 MB</span><span class="stat-label">Download</span></div>
          <div class="stat"><span class="stat-value" id="dailyUpload">0 MB</span><span class="stat-label">Upload</span></div>
        </div>
        <div class="quota-bar">
          <div class="quota-fill" id="dailyQuotaFill"></div>
        </div>
        <div class="quota-text"><span id="dailyRemaining">Sisa: 5 GB</span></div>
      </div>

      <div class="usage-card monthly">
        <div class="usage-header">
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" class="usage-icon"><rect x="3" y="4" width="18" height="18" rx="2"/><path d="M16 2v4M8 2v4M3 10h18M8 14h.01M12 14h.01M16 14h.01M8 18h.01M12 18h.01"/></svg>
          <h3>Pemakaian Bulan Ini</h3>
        </div>
        <div class="usage-ring">
          <svg viewBox="0 0 100 100">
            <circle cx="50" cy="50" r="42" fill="none" stroke="#1e293b" stroke-width="8"/>
            <circle cx="50" cy="50" r="42" fill="none" stroke="url(#monthlyGrad)" stroke-width="8" 
                    stroke-dasharray="264" stroke-dashoffset="264" stroke-linecap="round"
                    id="monthlyRing" transform="rotate(-90 50 50)"/>
            <defs>
              <linearGradient id="monthlyGrad" x1="0%" y1="0%" x2="100%" y2="0%">
                <stop offset="0%" stop-color="#22c55e"/>
                <stop offset="100%" stop-color="#3b82f6"/>
              </linearGradient>
            </defs>
          </svg>
          <div class="usage-ring-text">
            <span class="usage-ring-value" id="monthlyPercent">0%</span>
          </div>
        </div>
        <div class="usage-stats">
          <div class="stat"><span class="stat-value" id="monthlyTotal">0 GB</span><span class="stat-label">Total</span></div>
          <div class="stat"><span class="stat-value" id="monthlyDownload">0 GB</span><span class="stat-label">Download</span></div>
          <div class="stat"><span class="stat-value" id="monthlyUpload">0 GB</span><span class="stat-label">Upload</span></div>
        </div>
        <div class="quota-bar">
          <div class="quota-fill monthly" id="monthlyQuotaFill"></div>
        </div>
        <div class="quota-text"><span id="monthlyRemaining">Sisa: 100 GB</span></div>
      </div>
    </section>

    <!-- Devices Section -->
    <section class="devices-section">
      <div class="section-header">
        <h2><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" class="section-icon"><rect x="2" y="3" width="20" height="14" rx="2"/><path d="M8 21h8M12 17v4"/></svg>Perangkat Terhubung (<span id="deviceCount">0</span>)</h2>
      </div>
      <div class="devices-grid" id="devicesList"></div>
    </section>

    <!-- Speedtest Section -->
    <section class="speedtest-section">
      <div class="section-header">
        <h2><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" class="section-icon"><circle cx="12" cy="12" r="10"/><path d="M12 6v6l4 2"/></svg>Speedtest Internet</h2>
      </div>
      <div class="speedtest-container">
        <div class="speedometer">
          <svg viewBox="0 0 200 120">
            <defs>
              <linearGradient id="speedGrad" x1="0%" y1="0%" x2="100%" y2="0%">
                <stop offset="0%" stop-color="#22c55e"/>
                <stop offset="50%" stop-color="#3b82f6"/>
                <stop offset="100%" stop-color="#8b5cf6"/>
              </linearGradient>
            </defs>
            <path d="M 20 100 A 80 80 0 0 1 180 100" fill="none" stroke="#1e293b" stroke-width="12" stroke-linecap="round"/>
            <path d="M 20 100 A 80 80 0 0 1 180 100" fill="none" stroke="url(#speedGrad)" stroke-width="12" stroke-linecap="round"
                  stroke-dasharray="251" stroke-dashoffset="251" id="speedometerArc"/>
            <g id="speedometerNeedle" transform="rotate(-90, 100, 100)">
              <line x1="100" y1="100" x2="100" y2="35" stroke="#f1f5f9" stroke-width="3" stroke-linecap="round"/>
              <circle cx="100" cy="100" r="8" fill="#8b5cf6"/>
              <circle cx="100" cy="100" r="4" fill="#0f172a"/>
            </g>
            <text x="100" y="75" text-anchor="middle" fill="#f1f5f9" font-size="28" font-weight="700" id="speedValue">0</text>
            <text x="100" y="95" text-anchor="middle" fill="#94a3b8" font-size="12">Mbps</text>
          </svg>
        </div>
        <div class="speedtest-results">
          <div class="result">
            <div class="result-icon download"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M21 15v4a2 2 0 01-2 2H5a2 2 0 01-2-2v-4M7 10l5 5 5-5M12 15V3"/></svg></div>
            <div class="result-info">
              <span class="result-label">Download</span>
              <span class="result-value" id="testDownload">-- Mbps</span>
            </div>
          </div>
          <div class="result">
            <div class="result-icon upload"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M21 15v4a2 2 0 01-2 2H5a2 2 0 01-2-2v-4M17 8l-5-5-5 5M12 3v12"/></svg></div>
            <div class="result-info">
              <span class="result-label">Upload</span>
              <span class="result-value" id="testUpload">-- Mbps</span>
            </div>
          </div>
          <div class="result">
            <div class="result-icon ping"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><circle cx="12" cy="12" r="10"/><path d="M12 6v6l4 2"/></svg></div>
            <div class="result-info">
              <span class="result-label">Ping</span>
              <span class="result-value" id="testPing">-- ms</span>
            </div>
          </div>
        </div>
        <button class="btn-speedtest" id="btnSpeedtest" onclick="runSpeedtest()">
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><polygon points="5 3 19 12 5 21 5 3"/></svg>
          Mulai Speedtest
        </button>
      </div>
    </section>
  </main>

  <!-- Settings Modal -->
  <div class="modal" id="settingsModal">
    <div class="modal-backdrop" onclick="closeSettings()"></div>
    <div class="modal-content">
      <div class="modal-header">
        <h2>Pengaturan</h2>
        <button class="btn-close" onclick="closeSettings()">
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M18 6L6 18M6 6l12 12"/></svg>
        </button>
      </div>
      <form id="settingsForm">
        <div class="form-group">
          <label>Nama Router</label>
          <input type="text" name="router_name" id="inputRouterName" placeholder="OpenWrt Router">
        </div>
        <div class="form-group">
          <label>Nama Pemilik</label>
          <input type="text" name="owner_name" id="inputOwnerName" placeholder="Admin">
        </div>
        <div class="form-group">
          <label>Kuota Harian (GB)</label>
          <input type="number" name="quota_daily_gb" id="inputQuotaDaily" value="5">
        </div>
        <div class="form-group">
          <label>Kuota Bulanan (GB)</label>
          <input type="number" name="quota_monthly_gb" id="inputQuotaMonthly" value="100">
        </div>
        <button type="submit" class="btn-save">Simpan Pengaturan</button>
      </form>
    </div>
  </div>
</div>
<script src="js/app.js"></script>
</body>
</html>
HTMLFILE

echo "[5/7] Creating enhanced CSS..."
cat > /www/with/css/style.css << 'CSSFILE'
:root {
  --bg: #0f172a;
  --bg-card: #1e293b;
  --bg-hover: #334155;
  --text: #f1f5f9;
  --text-muted: #94a3b8;
  --primary: #3b82f6;
  --accent: #8b5cf6;
  --success: #22c55e;
  --warning: #f59e0b;
  --error: #ef4444;
  --border: #334155;
  --shadow: 0 10px 40px -10px rgba(0,0,0,0.5);
  --radius: 16px;
}

* { margin:0; padding:0; box-sizing:border-box; }

body {
  font-family: 'Inter', system-ui, sans-serif;
  background: var(--bg);
  color: var(--text);
  min-height: 100vh;
}

.app {
  max-width: 1400px;
  margin: 0 auto;
  padding: 1rem;
}

/* Header */
.header {
  display: flex;
  justify-content: space-between;
  align-items: center;
  padding: 1.25rem 1.5rem;
  background: var(--bg-card);
  border-radius: var(--radius);
  margin-bottom: 1.5rem;
  box-shadow: var(--shadow);
}

.header-left {
  display: flex;
  align-items: center;
  gap: 1rem;
}

.logo {
  width: 50px;
  height: 50px;
}

.logo svg {
  width: 100%;
  height: 100%;
}

.header-info h1 {
  font-size: 1.5rem;
  font-weight: 700;
  letter-spacing: -0.02em;
}

.header-info span {
  color: var(--text-muted);
  font-size: 0.875rem;
}

.header-right {
  display: flex;
  align-items: center;
  gap: 1rem;
}

.status {
  display: flex;
  align-items: center;
  gap: 0.5rem;
  padding: 0.5rem 1rem;
  background: rgba(34, 197, 94, 0.15);
  color: var(--success);
  border-radius: 100px;
  font-size: 0.8rem;
  font-weight: 600;
}

.status .pulse {
  width: 8px;
  height: 8px;
  background: var(--success);
  border-radius: 50%;
  animation: pulse 2s infinite;
}

@keyframes pulse {
  0%, 100% { opacity: 1; transform: scale(1); }
  50% { opacity: 0.5; transform: scale(1.2); }
}

.btn-icon {
  width: 44px;
  height: 44px;
  background: var(--bg);
  border: 1px solid var(--border);
  border-radius: 12px;
  cursor: pointer;
  display: flex;
  align-items: center;
  justify-content: center;
  transition: all 0.2s;
}

.btn-icon svg {
  width: 20px;
  height: 20px;
  color: var(--text-muted);
}

.btn-icon:hover {
  background: var(--primary);
  border-color: var(--primary);
}

.btn-icon:hover svg {
  color: var(--text);
}

/* Dashboard */
.dashboard {
  display: grid;
  gap: 1.5rem;
}

/* Speed Section */
.speed-section {
  display: grid;
  grid-template-columns: repeat(auto-fit, minmax(300px, 1fr));
  gap: 1rem;
}

.speed-card {
  background: var(--bg-card);
  border-radius: var(--radius);
  padding: 1.5rem;
  position: relative;
  overflow: hidden;
  box-shadow: var(--shadow);
}

.speed-card::before {
  content: '';
  position: absolute;
  top: 0;
  left: 0;
  right: 0;
  height: 4px;
}

.speed-card.download::before {
  background: linear-gradient(90deg, var(--primary), var(--accent));
}

.speed-card.upload::before {
  background: linear-gradient(90deg, var(--success), var(--primary));
}

.speed-header {
  display: flex;
  align-items: center;
  gap: 0.75rem;
  margin-bottom: 1rem;
}

.speed-icon {
  width: 48px;
  height: 48px;
  border-radius: 12px;
  display: flex;
  align-items: center;
  justify-content: center;
}

.speed-icon.download {
  background: linear-gradient(135deg, rgba(59, 130, 246, 0.2), rgba(139, 92, 246, 0.2));
}

.speed-icon.upload {
  background: linear-gradient(135deg, rgba(34, 197, 94, 0.2), rgba(59, 130, 246, 0.2));
}

.speed-icon svg {
  width: 24px;
  height: 24px;
}

.speed-icon.download svg { color: var(--primary); }
.speed-icon.upload svg { color: var(--success); }

.speed-label {
  color: var(--text-muted);
  font-size: 0.875rem;
  font-weight: 500;
}

.speed-display {
  display: flex;
  align-items: baseline;
  gap: 0.5rem;
  margin-bottom: 1rem;
}

.speed-value {
  font-size: 3rem;
  font-weight: 800;
  letter-spacing: -0.02em;
  line-height: 1;
}

.speed-unit {
  color: var(--text-muted);
  font-size: 1rem;
  font-weight: 500;
}

.speed-bar {
  height: 6px;
  background: var(--bg);
  border-radius: 3px;
  overflow: hidden;
}

.speed-bar-fill {
  height: 100%;
  border-radius: 3px;
  transition: width 0.5s ease;
  width: 0%;
}

.speed-bar-fill.download {
  background: linear-gradient(90deg, var(--primary), var(--accent));
}

.speed-bar-fill.upload {
  background: linear-gradient(90deg, var(--success), var(--primary));
}

/* Section Headers */
.section-header {
  display: flex;
  align-items: center;
  gap: 0.75rem;
  margin-bottom: 1rem;
}

.section-header h2 {
  font-size: 1rem;
  font-weight: 600;
  color: var(--text-muted);
  display: flex;
  align-items: center;
  gap: 0.5rem;
}

.section-icon {
  width: 20px;
  height: 20px;
}

/* Chart Section */
.chart-section {
  background: var(--bg-card);
  border-radius: var(--radius);
  padding: 1.5rem;
  box-shadow: var(--shadow);
}

.chart-container {
  height: 200px;
  position: relative;
}

#bandwidthChart {
  width: 100%;
  height: 100%;
}

/* Usage Section */
.usage-section {
  display: grid;
  grid-template-columns: repeat(auto-fit, minmax(320px, 1fr));
  gap: 1rem;
}

.usage-card {
  background: var(--bg-card);
  border-radius: var(--radius);
  padding: 1.5rem;
  box-shadow: var(--shadow);
  position: relative;
  overflow: hidden;
}

.usage-card::before {
  content: '';
  position: absolute;
  top: 0;
  left: 0;
  right: 0;
  height: 4px;
}

.usage-card.daily::before {
  background: linear-gradient(90deg, var(--primary), var(--accent));
}

.usage-card.monthly::before {
  background: linear-gradient(90deg, var(--success), var(--primary));
}

.usage-header {
  display: flex;
  align-items: center;
  gap: 0.75rem;
  margin-bottom: 1.5rem;
}

.usage-icon {
  width: 20px;
  height: 20px;
  color: var(--text-muted);
}

.usage-header h3 {
  font-size: 1rem;
  font-weight: 600;
  color: var(--text-muted);
}

.usage-ring {
  position: relative;
  width: 120px;
  height: 120px;
  margin: 0 auto 1.5rem;
}

.usage-ring svg {
  width: 100%;
  height: 100%;
}

.usage-ring-text {
  position: absolute;
  top: 50%;
  left: 50%;
  transform: translate(-50%, -50%);
  text-align: center;
}

.usage-ring-value {
  font-size: 1.5rem;
  font-weight: 700;
}

.usage-stats {
  display: grid;
  grid-template-columns: repeat(3, 1fr);
  gap: 1rem;
  margin-bottom: 1rem;
  text-align: center;
}

.stat-value {
  display: block;
  font-size: 1.125rem;
  font-weight: 700;
  margin-bottom: 0.25rem;
}

.stat-label {
  font-size: 0.75rem;
  color: var(--text-muted);
}

.quota-bar {
  height: 6px;
  background: var(--bg);
  border-radius: 3px;
  overflow: hidden;
  margin-bottom: 0.75rem;
}

.quota-fill {
  height: 100%;
  background: linear-gradient(90deg, var(--primary), var(--accent));
  border-radius: 3px;
  transition: width 0.5s ease;
  width: 0%;
}

.quota-fill.monthly {
  background: linear-gradient(90deg, var(--success), var(--primary));
}

.quota-text {
  font-size: 0.875rem;
  color: var(--text-muted);
}

/* Devices Section */
.devices-section {
  background: var(--bg-card);
  border-radius: var(--radius);
  padding: 1.5rem;
  box-shadow: var(--shadow);
}

.devices-grid {
  display: grid;
  gap: 0.75rem;
  max-height: 400px;
  overflow-y: auto;
}

.device-card {
  display: flex;
  align-items: center;
  gap: 1rem;
  padding: 1rem;
  background: var(--bg);
  border-radius: 12px;
  transition: all 0.2s;
}

.device-card:hover {
  background: var(--bg-hover);
  transform: translateX(4px);
}

.device-avatar {
  width: 48px;
  height: 48px;
  border-radius: 12px;
  display: flex;
  align-items: center;
  justify-content: center;
  font-size: 1.5rem;
}

.device-avatar.wifi {
  background: linear-gradient(135deg, rgba(139, 92, 246, 0.2), rgba(59, 130, 246, 0.2));
}

.device-avatar.lan {
  background: linear-gradient(135deg, rgba(59, 130, 246, 0.2), rgba(34, 197, 94, 0.2));
}

.device-info {
  flex: 1;
  min-width: 0;
}

.device-name {
  font-weight: 600;
  font-size: 0.9rem;
  margin-bottom: 0.25rem;
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}

.device-details {
  font-size: 0.75rem;
  color: var(--text-muted);
}

.device-meta {
  text-align: right;
}

.device-time {
  font-size: 0.75rem;
  color: var(--text-muted);
  display: flex;
  align-items: center;
  gap: 0.25rem;
  justify-content: flex-end;
  margin-bottom: 0.25rem;
}

.device-usage {
  font-size: 0.75rem;
  color: var(--primary);
  font-weight: 500;
}

.device-signal {
  display: flex;
  align-items: center;
  gap: 0.25rem;
  font-size: 0.75rem;
  color: var(--text-muted);
}

/* Speedtest Section */
.speedtest-section {
  background: var(--bg-card);
  border-radius: var(--radius);
  padding: 1.5rem;
  box-shadow: var(--shadow);
}

.speedtest-container {
  display: flex;
  flex-direction: column;
  align-items: center;
}

.speedometer {
  margin-bottom: 2rem;
}

.speedometer svg {
  width: 260px;
  height: 160px;
}

.speedtest-results {
  display: flex;
  gap: 2rem;
  margin-bottom: 1.5rem;
  flex-wrap: wrap;
  justify-content: center;
}

.result {
  display: flex;
  align-items: center;
  gap: 0.75rem;
  padding: 1rem 1.5rem;
  background: var(--bg);
  border-radius: 12px;
}

.result-icon {
  width: 40px;
  height: 40px;
  border-radius: 10px;
  display: flex;
  align-items: center;
  justify-content: center;
}

.result-icon svg {
  width: 20px;
  height: 20px;
}

.result-icon.download {
  background: rgba(59, 130, 246, 0.2);
  color: var(--primary);
}

.result-icon.upload {
  background: rgba(34, 197, 94, 0.2);
  color: var(--success);
}

.result-icon.ping {
  background: rgba(139, 92, 246, 0.2);
  color: var(--accent);
}

.result-label {
  display: block;
  font-size: 0.75rem;
  color: var(--text-muted);
  margin-bottom: 0.25rem;
}

.result-value {
  font-size: 1rem;
  font-weight: 700;
}

.btn-speedtest {
  display: flex;
  align-items: center;
  gap: 0.75rem;
  padding: 1rem 2.5rem;
  background: linear-gradient(135deg, var(--primary), var(--accent));
  color: white;
  border: none;
  border-radius: 100px;
  font-size: 1rem;
  font-weight: 600;
  cursor: pointer;
  transition: all 0.3s;
  box-shadow: 0 4px 20px rgba(59, 130, 246, 0.4);
}

.btn-speedtest svg {
  width: 20px;
  height: 20px;
}

.btn-speedtest:hover {
  transform: translateY(-2px);
  box-shadow: 0 8px 30px rgba(59, 130, 246, 0.5);
}

.btn-speedtest:disabled {
  opacity: 0.6;
  cursor: not-allowed;
  transform: none;
}

/* Modal */
.modal {
  display: none;
  position: fixed;
  inset: 0;
  z-index: 1000;
}

.modal.active {
  display: flex;
  align-items: center;
  justify-content: center;
}

.modal-backdrop {
  position: absolute;
  inset: 0;
  background: rgba(0, 0, 0, 0.7);
  backdrop-filter: blur(4px);
}

.modal-content {
  position: relative;
  background: var(--bg-card);
  border-radius: var(--radius);
  width: 90%;
  max-width: 400px;
  padding: 1.5rem;
  box-shadow: var(--shadow);
  animation: modalIn 0.3s ease;
}

@keyframes modalIn {
  from { opacity: 0; transform: scale(0.95) translateY(10px); }
  to { opacity: 1; transform: scale(1) translateY(0); }
}

.modal-header {
  display: flex;
  justify-content: space-between;
  align-items: center;
  margin-bottom: 1.5rem;
}

.modal-header h2 {
  font-size: 1.25rem;
  font-weight: 700;
}

.btn-close {
  width: 36px;
  height: 36px;
  background: var(--bg);
  border: none;
  border-radius: 8px;
  cursor: pointer;
  display: flex;
  align-items: center;
  justify-content: center;
}

.btn-close svg {
  width: 20px;
  height: 20px;
  color: var(--text-muted);
}

.btn-close:hover {
  background: var(--error);
}

.btn-close:hover svg {
  color: white;
}

.form-group {
  margin-bottom: 1rem;
}

.form-group label {
  display: block;
  font-size: 0.875rem;
  color: var(--text-muted);
  margin-bottom: 0.5rem;
}

.form-group input {
  width: 100%;
  padding: 0.875rem 1rem;
  background: var(--bg);
  border: 1px solid var(--border);
  border-radius: 10px;
  color: var(--text);
  font-size: 1rem;
  transition: all 0.2s;
}

.form-group input:focus {
  outline: none;
  border-color: var(--primary);
  box-shadow: 0 0 0 3px rgba(59, 130, 246, 0.2);
}

.btn-save {
  width: 100%;
  padding: 1rem;
  background: var(--primary);
  color: white;
  border: none;
  border-radius: 10px;
  font-size: 1rem;
  font-weight: 600;
  cursor: pointer;
  transition: all 0.2s;
  margin-top: 0.5rem;
}

.btn-save:hover {
  background: var(--accent);
}

/* Responsive */
@media (max-width: 768px) {
  .header {
    flex-direction: column;
    gap: 1rem;
    text-align: center;
  }
  
  .header-left {
    flex-direction: column;
  }
  
  .speed-value {
    font-size: 2.5rem;
  }
  
  .speedtest-results {
    flex-direction: column;
    gap: 0.75rem;
  }
  
  .result {
    width: 100%;
    justify-content: center;
  }
}
CSSFILE

echo "[6/7] Creating enhanced JavaScript..."
cat > /www/with/js/app.js << 'JSFILE'
const API = '/with/cgi-bin/api.cgi';

// Chart data
let chartData = [];
let chart = null;

function formatBytes(bytes, decimals = 2) {
    if (!bytes || bytes === 0) return '0 Bytes';
    const k = 1024;
    const sizes = ['Bytes', 'KB', 'MB', 'GB', 'TB'];
    const i = Math.floor(Math.log(bytes) / Math.log(k));
    return parseFloat((bytes / Math.pow(k, i)).toFixed(decimals)) + ' ' + sizes[i];
}

function formatTime(seconds) {
    if (!seconds || seconds <= 0) return 'Baru saja';
    const h = Math.floor(seconds / 3600);
    const m = Math.floor((seconds % 3600) / 60);
    if (h > 0) return h + 'j ' + m + 'm';
    if (m > 0) return m + ' menit';
    return Math.floor(seconds) + ' detik';
}

function updateRing(id, percent) {
    const ring = document.getElementById(id);
    if (ring) {
        const offset = 264 - (264 * Math.min(percent, 100) / 100);
        ring.style.strokeDashoffset = offset;
    }
}

function initChart() {
    const canvas = document.getElementById('bandwidthChart');
    if (!canvas) return;
    
    const ctx = canvas.getContext('2d');
    canvas.width = canvas.parentElement.offsetWidth;
    canvas.height = 200;
    
    chart = { ctx, canvas };
    drawChart();
}

function drawChart() {
    if (!chart || chartData.length === 0) return;
    
    const { ctx, canvas } = chart;
    const w = canvas.width;
    const h = canvas.height;
    const padding = 40;
    
    ctx.clearRect(0, 0, w, h);
    
    // Find max value
    const maxVal = Math.max(...chartData.map(d => Math.max(d.download, d.upload)), 10);
    
    // Draw grid
    ctx.strokeStyle = '#334155';
    ctx.lineWidth = 1;
    for (let i = 0; i <= 4; i++) {
        const y = padding + (h - padding * 2) * i / 4;
        ctx.beginPath();
        ctx.moveTo(padding, y);
        ctx.lineTo(w - padding, y);
        ctx.stroke();
        
        // Labels
        ctx.fillStyle = '#94a3b8';
        ctx.font = '10px Inter, sans-serif';
        ctx.fillText((maxVal * (4 - i) / 4).toFixed(1), 5, y + 3);
    }
    
    if (chartData.length < 2) return;
    
    const stepX = (w - padding * 2) / (chartData.length - 1);
    
    // Draw download area
    ctx.beginPath();
    ctx.moveTo(padding, h - padding);
    chartData.forEach((d, i) => {
        const x = padding + i * stepX;
        const y = h - padding - (d.download / maxVal) * (h - padding * 2);
        ctx.lineTo(x, y);
    });
    ctx.lineTo(padding + (chartData.length - 1) * stepX, h - padding);
    ctx.closePath();
    
    const gradDl = ctx.createLinearGradient(0, 0, 0, h);
    gradDl.addColorStop(0, 'rgba(59, 130, 246, 0.3)');
    gradDl.addColorStop(1, 'rgba(59, 130, 246, 0.05)');
    ctx.fillStyle = gradDl;
    ctx.fill();
    
    // Draw download line
    ctx.beginPath();
    chartData.forEach((d, i) => {
        const x = padding + i * stepX;
        const y = h - padding - (d.download / maxVal) * (h - padding * 2);
        if (i === 0) ctx.moveTo(x, y);
        else ctx.lineTo(x, y);
    });
    ctx.strokeStyle = '#3b82f6';
    ctx.lineWidth = 2;
    ctx.stroke();
    
    // Draw upload area
    ctx.beginPath();
    ctx.moveTo(padding, h - padding);
    chartData.forEach((d, i) => {
        const x = padding + i * stepX;
        const y = h - padding - (d.upload / maxVal) * (h - padding * 2);
        ctx.lineTo(x, y);
    });
    ctx.lineTo(padding + (chartData.length - 1) * stepX, h - padding);
    ctx.closePath();
    
    const gradUl = ctx.createLinearGradient(0, 0, 0, h);
    gradUl.addColorStop(0, 'rgba(34, 197, 94, 0.3)');
    gradUl.addColorStop(1, 'rgba(34, 197, 94, 0.05)');
    ctx.fillStyle = gradUl;
    ctx.fill();
    
    // Draw upload line
    ctx.beginPath();
    chartData.forEach((d, i) => {
        const x = padding + i * stepX;
        const y = h - padding - (d.upload / maxVal) * (h - padding * 2);
        if (i === 0) ctx.moveTo(x, y);
        else ctx.lineTo(x, y);
    });
    ctx.strokeStyle = '#22c55e';
    ctx.lineWidth = 2;
    ctx.stroke();
    
    // Legend
    ctx.fillStyle = '#3b82f6';
    ctx.fillRect(w - 150, 10, 12, 12);
    ctx.fillStyle = '#f1f5f9';
    ctx.fillText('Download', w - 130, 20);
    
    ctx.fillStyle = '#22c55e';
    ctx.fillRect(w - 150, 28, 12, 12);
    ctx.fillStyle = '#f1f5f9';
    ctx.fillText('Upload', w - 130, 38);
}

async function fetchBandwidth() {
    try {
        const res = await fetch(API + '?action=bandwidth');
        const data = await res.json();
        
        document.getElementById('downloadSpeed').textContent = data.download_speed;
        document.getElementById('uploadSpeed').textContent = data.upload_speed;
        
        const dlPercent = Math.min((parseFloat(data.download_speed) / 100) * 100, 100);
        const ulPercent = Math.min((parseFloat(data.upload_speed) / 100) * 100, 100);
        
        document.getElementById('downloadBar').style.width = dlPercent + '%';
        document.getElementById('uploadBar').style.width = ulPercent + '%';
        
        // Update chart data
        chartData.push({
            time: Date.now(),
            download: parseFloat(data.download_speed) || 0,
            upload: parseFloat(data.upload_speed) || 0
        });
        if (chartData.length > 30) chartData.shift();
        drawChart();
    } catch (e) {
        console.error('Bandwidth error:', e);
    }
}

async function fetchUsage() {
    try {
        const res = await fetch(API + '?action=usage');
        const data = await res.json();
        
        document.getElementById('dailyTotal').textContent = formatBytes(data.daily.total);
        document.getElementById('dailyDownload').textContent = formatBytes(data.daily.download);
        document.getElementById('dailyUpload').textContent = formatBytes(data.daily.upload);
        
        const dailyPercent = Math.min((data.daily.total / data.quota.daily) * 100, 100);
        document.getElementById('dailyPercent').textContent = dailyPercent.toFixed(1) + '%';
        document.getElementById('dailyQuotaFill').style.width = dailyPercent + '%';
        document.getElementById('dailyRemaining').textContent = 'Sisa: ' + formatBytes(Math.max(data.quota.daily - data.daily.total, 0));
        updateRing('dailyRing', dailyPercent);
        
        document.getElementById('monthlyTotal').textContent = formatBytes(data.monthly.total);
        document.getElementById('monthlyDownload').textContent = formatBytes(data.monthly.download);
        document.getElementById('monthlyUpload').textContent = formatBytes(data.monthly.upload);
        
        const monthlyPercent = Math.min((data.monthly.total / data.quota.monthly) * 100, 100);
        document.getElementById('monthlyPercent').textContent = monthlyPercent.toFixed(1) + '%';
        document.getElementById('monthlyQuotaFill').style.width = monthlyPercent + '%';
        document.getElementById('monthlyRemaining').textContent = 'Sisa: ' + formatBytes(Math.max(data.quota.monthly - data.monthly.total, 0));
        updateRing('monthlyRing', monthlyPercent);
    } catch (e) {
        console.error('Usage error:', e);
    }
}

async function fetchClients() {
    try {
        const res = await fetch(API + '?action=clients');
        const data = await res.json();
        
        const list = document.getElementById('devicesList');
        const count = document.getElementById('deviceCount');
        
        count.textContent = data.clients.length;
        list.innerHTML = '';
        
        data.clients.forEach(c => {
            const icon = c.type === 'wifi' ? '📶' : '🔌';
            const avatarClass = c.type === 'wifi' ? 'wifi' : 'lan';
            
            const html = `
                <div class="device-card">
                    <div class="device-avatar ${avatarClass}">${icon}</div>
                    <div class="device-info">
                        <div class="device-name">${c.hostname || 'Unknown'}</div>
                        <div class="device-details">${c.ip} • ${c.mac}</div>
                    </div>
                    <div class="device-meta">
                        <div class="device-time">⏱ ${formatTime(c.connected_time)}</div>
                        ${c.signal ? `<div class="device-signal">📶 ${c.signal} dBm</div>` : ''}
                    </div>
                </div>
            `;
            list.innerHTML += html;
        });
    } catch (e) {
        console.error('Clients error:', e);
    }
}

async function fetchSystemInfo() {
    try {
        const res = await fetch(API + '?action=system');
        const data = await res.json();
        
        document.getElementById('routerName').textContent = data.router_name;
        document.getElementById('ownerName').textContent = data.owner_name;
        document.getElementById('inputRouterName').value = data.router_name;
        document.getElementById('inputOwnerName').value = data.owner_name;
    } catch (e) {
        console.error('System info error:', e);
    }
}

function openSettings() {
    document.getElementById('settingsModal').classList.add('active');
}

function closeSettings() {
    document.getElementById('settingsModal').classList.remove('active');
}

document.getElementById('settingsForm').addEventListener('submit', async function(e) {
    e.preventDefault();
    
    const form = new FormData(this);
    const params = new URLSearchParams();
    
    for (let [key, value] of form) {
        if (key === 'quota_daily_gb') {
            params.append('quota_daily', value * 1073741824);
        } else if (key === 'quota_monthly_gb') {
            params.append('quota_monthly', value * 1073741824);
        } else {
            params.append(key, value);
        }
    }
    
    try {
        await fetch(API + '?action=save_config', {
            method: 'POST',
            body: params
        });
        closeSettings();
        fetchSystemInfo();
        alert('Pengaturan berhasil disimpan!');
    } catch (e) {
        alert('Gagal menyimpan pengaturan');
    }
});

// Enhanced Speedtest
let speedtestRunning = false;

async function runSpeedtest() {
    if (speedtestRunning) return;
    
    speedtestRunning = true;
    const btn = document.getElementById('btnSpeedtest');
    btn.disabled = true;
    btn.innerHTML = '<svg viewBox="0 0 24 24" class="spin" fill="none" stroke="currentColor" stroke-width="2"><path d="M21 12a9 9 0 11-18 0 9 9 0 0118 0z"/><path d="M9 12l2 2 4-4"/></svg>Testing...';
    
    // Reset values
    document.getElementById('testDownload').textContent = '-- Mbps';
    document.getElementById('testUpload').textContent = '-- Mbps';
    document.getElementById('testPing').textContent = '-- ms';
    updateSpeedometer(0);
    
    try {
        // Call real speedtest API
        const res = await fetch(API + '?action=speedtest');
        const data = await res.json();
        
        // Animate results
        await animateValue('testDownload', 0, data.download, ' Mbps');
        await animateValue('testUpload', 0, data.upload, ' Mbps');
        document.getElementById('testPing').textContent = data.ping + ' ms';
        
        updateSpeedometer(data.download);
        document.getElementById('speedValue').textContent = data.download.toFixed(2);
    } catch (e) {
        console.error('Speedtest error:', e);
        document.getElementById('testDownload').textContent = 'Error';
        document.getElementById('testUpload').textContent = 'Error';
    }
    
    btn.disabled = false;
    btn.innerHTML = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><polygon points="5 3 19 12 5 21 5 3"/></svg>Mulai Speedtest';
    speedtestRunning = false;
}

async function animateValue(id, start, end, suffix) {
    const el = document.getElementById(id);
    const duration = 1500;
    const startTime = performance.now();
    
    return new Promise(resolve => {
        function update(currentTime) {
            const elapsed = currentTime - startTime;
            const progress = Math.min(elapsed / duration, 1);
            const eased = 1 - Math.pow(1 - progress, 3);
            const current = start + (end - start) * eased;
            
            el.textContent = current.toFixed(2) + suffix;
            updateSpeedometer(current);
            
            if (progress < 1) {
                requestAnimationFrame(update);
            } else {
                resolve();
            }
        }
        requestAnimationFrame(update);
    });
}

function updateSpeedometer(speed) {
    const maxSpeed = 100;
    const percent = Math.min((speed / maxSpeed) * 100, 100);
    
    // Update arc
    const arc = document.getElementById('speedometerArc');
    if (arc) {
        const offset = 251 - (251 * percent / 100);
        arc.style.strokeDashoffset = offset;
    }
    
    // Update needle
    const needle = document.getElementById('speedometerNeedle');
    if (needle) {
        const angle = -90 + (percent * 1.8);
        needle.setAttribute('transform', 'rotate(' + angle + ', 100, 100)');
    }
    
    // Update value
    const val = document.getElementById('speedValue');
    if (val) {
        val.textContent = speed.toFixed(2);
    }
}

// Add spin animation
const style = document.createElement('style');
style.textContent = '@keyframes spin{from{transform:rotate(0)}to{transform:rotate(360deg)}}.spin{animation:spin 1s linear infinite;width:20px;height:20px}';
document.head.appendChild(style);

// Initialize
document.addEventListener('DOMContentLoaded', function() {
    fetchSystemInfo();
    fetchBandwidth();
    fetchUsage();
    fetchClients();
    initChart();
    
    setInterval(fetchBandwidth, 2000);
    setInterval(fetchUsage, 10000);
    setInterval(fetchClients, 30000);
    
    window.addEventListener('resize', function() {
        if (chart) {
            chart.canvas.width = chart.canvas.parentElement.offsetWidth;
            drawChart();
        }
    });
});
JSFILE

echo "[7/7] Configuring uhttpd..."
uci set uhttpd.main.cgi_prefix='/cgi-bin'
uci commit uhttpd
/etc/init.d/uhttpd restart

# Initialize vnstat
vnstat -u -i br-lan 2>/dev/null || true

echo ""
echo "========================================"
echo "  Installation Complete Mass Broo!"
echo "========================================"
echo ""
echo "  Akses dashboard di:"
echo "  http://192.168.1.1/with/"
echo ""
echo "========================================"
