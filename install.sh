#!/bin/bash

###############################################################################
# OpenWRT Bandwidth Monitor Dashboard - Full Installation Script
# Developer: YuzinCrab
# Description: Real-time bandwidth monitoring with modern UI
###############################################################################

set -e

echo "============================================================"
echo "  OpenWRT Bandwidth Monitor Dashboard - Installation"
echo "  Developed by: YuzinCrab"
echo "============================================================"
echo ""

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
INSTALL_DIR="/www/bandwidth2"
LUCI_CONTROLLER_DIR="/usr/lib/lua/luci/controller"
LUCI_VIEW_DIR="/usr/lib/lua/luci/view"

echo -e "${BLUE}[INFO]${NC} Creating directories..."
mkdir -p "$INSTALL_DIR"
mkdir -p "$LUCI_CONTROLLER_DIR"
mkdir -p "$LUCI_VIEW_DIR"
mkdir -p /tmp/bandwidth-data

echo -e "${GREEN}[SUCCESS]${NC} Directories created"
echo ""
echo -e "${BLUE}[INFO]${NC} Installing HTML frontend..."
echo ""

###############################################################################
# HTML Frontend - Main Dashboard
###############################################################################

cat > "$INSTALL_DIR/index.html" << 'HTMLEOF'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Bandwidth Monitor - OpenWRT</title>
    <script src="https://cdn.tailwindcss.com"></script>
    <script src="https://cdn.jsdelivr.net/npm/chart.js@4.4.1/dist/chart.umd.min.js"></script>
    <style>
        @import url('https://fonts.googleapis.com/css2?family=Orbit
