#!/bin/bash

# 设置严格模式
set -euo pipefail

# 设置环境变量
SOLANA_INSTALL_DIR="/root/.local/share/solana/install"
export PATH="$SOLANA_INSTALL_DIR/active_release/bin:$PATH"

# 颜色定义
GREEN='\033[1;32m'      # 绿色加粗
RED='\033[1;31m'        # 红色加粗
YELLOW='\033[1;33m'     # 黄色加粗
CYAN='\033[1;36m'       # 青色加粗
BLUE='\033[1;34m'       # 蓝色加粗
WHITE='\033[1;37m'      # 亮白色加粗
GRAY='\033[0;37m'       # 灰色
NC='\033[0m'            # 重置颜色

# 标识符定义
INFO="[INFO]"
WARN="[WARN]"
ERROR="[ERROR]"
SUCCESS="[OK]"

# 目录和文件配置
TEMP_DIR="/tmp/solana_dc_finder"
LOG_FILE="${TEMP_DIR}/dc_finder.log"
RESULTS_FILE="${TEMP_DIR}/validator_locations.txt"
REPORT_DIR="$HOME/solana_reports"
LATEST_REPORT="${REPORT_DIR}/latest_report.txt"
BACKGROUND_LOG="${REPORT_DIR}/background.log"
LOCK_FILE="/tmp/solana_dc_finder.lock"
PROGRESS_FILE="${TEMP_DIR}/progress.txt"
CONFIG_FILE="${REPORT_DIR}/config.conf"
VERSION="v1.3.2"

# 创建必要的目录
mkdir -p "${TEMP_DIR}" "${REPORT_DIR}"

# 错误处理函数
handle_error() {
    local exit_code=$?
    local line_number=$1
    local error_message=$2
    
    log "ERROR" "在第 ${line_number} 行发生错误: ${error_message}"
    log "ERROR" "退出码: ${exit_code}"
    
    # 保存当前状态用于恢复
    if [ -f "${PROGRESS_FILE}" ]; then
        cp "${PROGRESS_FILE}" "${TEMP_DIR}/last_progress"
    fi
    
    cleanup
    exit 1
}

# 使用新的错误处理
trap 'handle_error ${LINENO} "${BASH_COMMAND}"' ERR

# 清理函数
cleanup() {
    rm -f "$LOCK_FILE"
    rm -f "${TEMP_DIR}/completed_tests"
    rm -rf "${TEMP_DIR}/results"
}

# 创建默认配置文件
create_default_config() {
    cat > "${CONFIG_FILE}" <<EOF
# Solana DC Finder 配置文件
MAX_CONCURRENT_JOBS=10
TIMEOUT_SECONDS=2
RETRIES=2
TEST_PORTS=("8899" "8900" "8001" "8000")
ENABLE_BACKGROUND_MODE=true
LOG_LEVEL=INFO
EOF
}

# 加载配置
load_config() {
    if [ ! -f "${CONFIG_FILE}" ]; then
        create_default_config
    fi
    source "${CONFIG_FILE}"
}

# 日志函数
log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    echo -e "${timestamp} [${level}] ${message}" >> "${LOG_FILE}"
    
    if [ "${BACKGROUND_MODE:-false}" = "false" ]; then
        case "$level" in
            "INFO")    echo -e "${GREEN}${INFO} ${message}${NC}" ;;
            "ERROR")   echo -e "${RED}${ERROR} ${message}${NC}" ;;
            "SUCCESS") echo -e "${GREEN}${SUCCESS} ${message}${NC}" ;;
            "WARN")    echo -e "${YELLOW}${WARN} ${message}${NC}" ;;
            *) echo -e "${message}" ;;
        esac
    fi
}

# 检查依赖
check_dependencies() {
    local deps=("curl" "nc" "whois" "awk" "sort" "jq" "bc")
    local missing=()

    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &>/dev/null; then
            missing+=("$dep")
        fi
    done

    if [ ${#missing[@]} -ne 0 ]; then
        log "INFO" "正在安装必要工具: ${missing[*]}"
        
        # 等待 apt 锁释放
        local max_attempts=30
        local attempt=1
        
        while fuser /var/lib/dpkg/lock >/dev/null 2>&1 || \
              fuser /var/lib/apt/lists/lock >/dev/null 2>&1 || \
              fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do
            
            if [ $attempt -gt $max_attempts ]; then
                log "ERROR" "等待 apt 锁超时"
                return 1
            fi
            
            log "WARN" "系统正在进行更新，等待中... (${attempt}/${max_attempts})"
            sleep 10
            ((attempt++))
        done
        
        if ! apt-get update -qq; then
            log "ERROR" "更新软件源失败"
            return 1
        fi
        
        if ! apt-get install -y -qq "${missing[@]}"; then
            log "ERROR" "工具安装失败"
            return 1
        fi
        
        log "SUCCESS" "工具安装完成"
    fi
    return 0
}

# 安装 Solana CLI
install_solana_cli() {
    if ! command -v solana &>/dev/null; then
        log "INFO" "Solana CLI 未安装,开始安装..."
        
        mkdir -p "$SOLANA_INSTALL_DIR"
        
        local VERSION="v1.18.15"
        local DOWNLOAD_URL="https://release.solana.com/$VERSION/solana-release-x86_64-unknown-linux-gnu.tar.bz2"
        
        if ! curl -L "$DOWNLOAD_URL" | tar jxf - -C "$SOLANA_INSTALL_DIR"; then
            log "ERROR" "Solana CLI 下载失败"
            return 1
        fi
        
        rm -rf "$SOLANA_INSTALL_DIR/active_release"
        ln -s "$SOLANA_INSTALL_DIR/solana-release" "$SOLANA_INSTALL_DIR/active_release"
        
        export PATH="$SOLANA_INSTALL_DIR/active_release/bin:$PATH"
        
        if ! solana config set --url https://api.mainnet-beta.solana.com; then
            log "ERROR" "Solana CLI 配置失败"
            return 1
        fi
        
        log "SUCCESS" "Solana CLI 安装成功"
    else
        log "INFO" "Solana CLI 已安装"
    fi
    return 0
}

# 获取IP信息
get_ip_info() {
    local ip="$1"
    local max_retries=3
    local retry_count=0
    local info=""
    
    while [ $retry_count -lt $max_retries ]; do
        # 尝试 ipapi.co
        info=$(curl -s --max-time 3 "https://ipapi.co/${ip}/json/")
        if [ -n "$info" ] && [ "$(echo "$info" | jq -r '.error // empty')" = "" ]; then
            echo "$info"
            return 0
        fi
        
        # 尝试 ip-api.com
        info=$(curl -s --max-time 3 "http://ip-api.com/json/${ip}")
        if [ -n "$info" ] && [ "$(echo "$info" | jq -r '.status')" = "success" ]; then
            echo "$info"
            return 0
        fi
        
        # 尝试 ipinfo.io
        info=$(curl -s --max-time 3 "https://ipinfo.io/${ip}/json")
        if [ -n "$info" ] && [ "$(echo "$info" | jq -r '.bogon // empty')" != "true" ]; then
            echo "$info"
            return 0
        fi
        
        ((retry_count++))
        [ $retry_count -lt $max_retries ] && sleep 1
    done
    
    echo "{\"ip\":\"$ip\",\"error\":\"All APIs failed\",\"org\":\"Unknown\",\"city\":\"Unknown\"}"
    return 1
}

# 测试网络质量
test_network_quality() {
    local ip="$1"
    local retries=${RETRIES:-2}
    local timeout=${TIMEOUT_SECONDS:-2}
    local total_time=0
    local success_count=0
    local ports=("${TEST_PORTS[@]:-8899 8900 8001 8000}")
    
    for ((i=1; i<=retries; i++)); do
        for port in "${ports[@]}"; do
            local start_time=$(date +%s%N)
            if timeout $timeout nc -zv "$ip" "$port" >/dev/null 2>&1; then
                local end_time=$(date +%s%N)
                local duration=$(( (end_time - start_time) / 1000000 ))
                total_time=$((total_time + duration))
                ((success_count++))
                break
            fi
        done
    done
    
    if [ $success_count -gt 0 ]; then
        printf "%.3f" "$(echo "scale=3; $total_time / $success_count" | bc -l)"
        return 0
    fi
    
    echo "999"
    return 0
}

# 获取验证者信息
get_validators() {
    log "INFO" "正在获取验证者信息..."
    
    local validators
    validators=$(solana gossip 2>/dev/null) || {
        log "ERROR" "无法获取验证者信息"
        return 1
    }
    
    local ips
    ips=$(echo "$validators" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | sort -u) || {
        log "ERROR" "未找到验证者IP地址"
        return 1
    }
    
    echo "$ips"
    return 0
}

# 更新进度显示
update_progress() {
    local current="$1"
    local total="$2"
    local ip="$3"
    local latency="$4"
    local location="$5"
    local provider="$6"
    
    # 保存进度
    echo "${current}/${total}" > "${PROGRESS_FILE}"
    
    local progress=$((current * 100 / total))
    local elapsed_time=$(($(date +%s) - ${START_TIME}))
    local time_per_item=$((elapsed_time / (current > 0 ? current : 1)))
    local remaining_items=$((total - current))
    local eta=$((time_per_item * remaining_items))
    
    # 每20行显示一次进度条和表头
    if [ $((current % 20)) -eq 1 ]; then
        # 打印总进度
        printf "\n["
        for ((i=0; i<40; i++)); do
            if [ $i -lt $((progress * 40 / 100)) ]; then
                printf "${GREEN}█${NC}"
            else
                printf "█"
            fi
        done
        printf "] ${GREEN}%3d%%${NC} | 已测试: ${GREEN}%d${NC}/${WHITE}%d${NC} | 预计剩余: ${WHITE}%dm%ds${NC}\n\n" \
            "$progress" "$current" "$total" \
            $((eta / 60)) $((eta % 60))
        
        # 打印表头
        printf "${WHITE}%-10s | %-15s | %-8s | %-15s | %-30s | %-15s${NC}\n" \
            "时间" "IP地址" "延迟" "供应商" "机房位置" "进度"
        printf "${WHITE}%s${NC}\n" "$(printf '=%.0s' {1..100})"
    fi
    
    # 格式化延迟显示
    local latency_display
    local latency_color=$GREEN
    if [[ "$latency" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        if [ "$(echo "$latency > 100" | bc -l)" -eq 1 ]; then
            latency_color=$YELLOW
        fi
        latency_display="${latency}ms"
    else
        latency_color=$RED
        latency_display="超时"
    fi
    
    # 交替行颜色
    if [ $((current % 2)) -eq 0 ]; then
        printf "${GREEN}%-8s${NC} | ${CYAN}%-15s${NC} | ${latency_color}%-8s${NC} | %-15.15s | %-30.30s | ${GREEN}%d/%d${NC}\n" \
            "$(date '+%H:%M:%S')" \
            "$ip" \
            "$latency_display" \
            "${provider:0:15}" \
            "${location:0:30}" \
            "$current" "$total"
    else
        printf "${WHITE}%-8s${NC} | ${CYAN}%-15s${NC} | ${latency_color}%-8s${NC} | %-15.15s | %-30.30s | ${GREEN}%d/%d${NC}\n" \
            "$(date '+%H:%M:%S')" \
            "$ip" \
            "$latency_display" \
            "${provider:0:15}" \
            "${location:0:30}" \
            "$current" "$total"
    fi
}

# 分析验证者节点
analyze_validators() {
    local background="${1:-false}"
    BACKGROUND_MODE="$background"
    
    log "INFO" "开始分析验证者节点分布"
    
    if ! command -v solana >/dev/null 2>&1; then
        log "ERROR" "Solana CLI 未安装或未正确配置"
        return 1
    fi
    
    local validator_ips
    validator_ips=$(get_validators) || {
        log "ERROR" "获取验证者信息失败"
        return 1
    }
    
    : > "${RESULTS_FILE}"
    echo "$validator_ips" > "${TEMP_DIR}/tmp_ips.txt"
    
    local total=$(wc -l < "${TEMP_DIR}/tmp_ips.txt")
    local current=0
    
    START_TIME=$(date +%s)
    
    log "INFO" "找到 ${total} 个验证者节点"
    echo "----------------------------------------"
    
    while read -r ip; do
        ((current++))
        
        local latency=$(test_network_quality "$ip")
        local ip_info=$(get_ip_info "$ip")
        local provider=""
        local location=""
        
        # 解析 IP 信息
        if [ -n "$ip_info" ]; then
            if echo "$ip_info" | jq -e '.org' >/dev/null 2>&1; then
                provider=$(echo "$ip_info" | jq -r '.org')
            elif echo "$ip_info" | jq -e '.isp' >/dev/null 2>&1; then
                provider=$(echo "$ip_info" | jq -r '.isp')
            fi
            
            local city=$(echo "$ip_info" | jq -r '.city // empty')
            local region=$(echo "$ip_info" | jq -r '.region // empty')
            local country=$(echo "$ip_info" | jq -r '.country_name // .country // empty')
            
            location="${city:+$city}${region:+, $region}${country:+, $country}"
        fi
        
        update_progress "$current" "$total" "$ip" "$latency" "${location:-Unknown}" "${provider:-Unknown}"
        
        echo "$ip|$provider|$location|$latency" >> "${RESULTS_FILE}"
        
    done < "${TEMP_DIR}/tmp_ips.txt"
    
    echo "----------------------------------------"
    generate_report
    
    if [ "$background" = "true" ]; then
        log "SUCCESS" "后台分析完成！报告已生成: ${LATEST_REPORT}"
    else
        log "SUCCESS" "分析完成！报告已生成: ${LATEST_REPORT}"
    fi
}

# 生成报告
generate_report() {
    log "INFO" "正在生成报告..."
    
    local total_nodes=$(wc -l < "${RESULTS_FILE}")
    local avg_latency=$(awk -F'|' '$4!=999 { sum+=$4; count++ } END { if(count>0) printf "%.3f", sum/count }' "${RESULTS_FILE}")
    local min_latency=$(sort -t'|' -k4 -n "${RESULTS_FILE}" | head -1 | cut -d'|' -f4)
    local max_latency=$(sort -t'|' -k4 -n "${RESULTS_FILE}" | grep -v "999" | tail -1 | cut -d'|' -f4)
    
    {
        echo "# Solana 验证者节点延迟分析报告"
        echo "生成时间: $(date '+%Y-%m-%d %H:%M:%S')"
        echo "总节点数: ${total_nodes}"
        echo "平均延迟: ${avg_latency}ms"
        echo "最低延迟: ${min_latency}ms"
        echo "最高延迟: ${max_latency}ms"
        echo
        
        echo "## 延迟统计 (Top 20)"
        echo "| IP地址 | 位置 | 延迟(ms) | 供应商 |"
        echo "|--------|------|-----------|---------|"
        
        sort -t'|' -k4 -n "${RESULTS_FILE}" | head -20 | while IFS='|' read -r ip provider location latency; do
            if [ "$latency" != "999" ]; then
                printf "| %s | %s | %.3f | %s |\n" "$ip" "$location" "$latency" "$provider"
            fi
        done
        
        echo
        echo "## 供应商分布"
        echo "| 供应商 | 节点数量 | 平均延迟(ms) |"
        echo "|---------|-----------|--------------|"
        
        awk -F'|' '$4!=999 {
            count[$2]++
            latency_sum[$2]+=$4
        }
        END {
            for (provider in count) {
                printf "| %s | %d | %.3f |\n", 
                    provider, 
                    count[provider], 
                    latency_sum[provider]/count[provider]
            }
        }' "${RESULTS_FILE}" | sort -t'|' -k3 -n
        
    } > "${LATEST_REPORT}"
    
    log "SUCCESS" "报告已生成: ${LATEST_REPORT}"
}

# 主函数
main() {
    local cmd="${1:-}"
    
    if [ "$EUID" -ne 0 ]; then 
        log "ERROR" "请使用root权限运行此脚本"
        exit 1
    fi
    
    if [ "$cmd" = "background" ]; then
        analyze_validators_parallel true
        exit 0
    fi
    
    trap cleanup EXIT
    
    if [ -f "$LOCK_FILE" ]; then
        log "ERROR" "程序已在运行中"
        exit 1
    fi
    
    touch "$LOCK_FILE"
    
    check_dependencies || exit 1
    install_solana_cli || exit 1
    load_config
    
    analyze_validators false
}

# 启动程序
main "$@"


