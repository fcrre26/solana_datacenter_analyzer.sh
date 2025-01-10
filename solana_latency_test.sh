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

# 供应商识别函数
identify_provider() {
    local provider="$1"
    local location="$2"
    
    # 初始化返回值
    local cloud_provider=""
    local region_code=""
    local datacenter=""
    
    # 识别主要云服务商和数据中心
    case "$provider" in
        *"Amazon"*|*"AWS"*|*"AMAZON"*)
            cloud_provider="AWS"
            case "$location" in
                *"Tokyo"*|*"Japan"*)          region_code="ap-northeast-1"; datacenter="东京数据中心" ;;
                *"Singapore"*)                 region_code="ap-southeast-1"; datacenter="新加坡数据中心" ;;
                *"Hong Kong"*)                 region_code="ap-east-1"; datacenter="香港数据中心" ;;
                *"Seoul"*|*"Korea"*)          region_code="ap-northeast-2"; datacenter="首尔数据中心" ;;
                *"Sydney"*|*"Australia"*)     region_code="ap-southeast-2"; datacenter="悉尼数据中心" ;;
                *"Mumbai"*|*"India"*)         region_code="ap-south-1"; datacenter="孟买数据中心" ;;
                *) datacenter="$location" ;;
            esac
            ;;
            
        *"Google"*|*"GCP"*|*"GOOGLE"*)
            cloud_provider="Google Cloud"
            case "$location" in
                *"Tokyo"*|*"Japan"*)          region_code="asia-northeast1"; datacenter="东京-大森机房" ;;
                *"Singapore"*)                 region_code="asia-southeast1"; datacenter="新加坡机房" ;;
                *"Hong Kong"*)                 region_code="asia-east2"; datacenter="香港机房" ;;
                *"Seoul"*|*"Korea"*)          region_code="asia-northeast3"; datacenter="首尔机房" ;;
                *"Sydney"*|*"Australia"*)     region_code="australia-southeast1"; datacenter="悉尼机房" ;;
                *"Mumbai"*|*"India"*)         region_code="asia-south1"; datacenter="孟买机房" ;;
                *) datacenter="$location" ;;
            esac
            ;;
            
        *"Alibaba"*|*"Aliyun"*|*"阿里"*)
            cloud_provider="阿里云"
            case "$location" in
                *"Hangzhou"*|*"杭州"*)        region_code="cn-hangzhou"; datacenter="杭州可用区" ;;
                *"Shanghai"*|*"上海"*)        region_code="cn-shanghai"; datacenter="上海可用区" ;;
                *"Hong Kong"*|*"香港"*)       region_code="cn-hongkong"; datacenter="香港可用区" ;;
                *"Singapore"*|*"新加坡"*)     region_code="ap-southeast-1"; datacenter="新加坡可用区" ;;
                *"Tokyo"*|*"东京"*)           region_code="ap-northeast-1"; datacenter="东京可用区" ;;
                *) datacenter="$location" ;;
            esac
            ;;
            
        *"Azure"*|*"Microsoft"*)
            cloud_provider="Azure"
            case "$location" in
                *"Hong Kong"*|*"香港"*)       region_code="eastasia"; datacenter="香港数据中心" ;;
                *"Singapore"*|*"新加坡"*)     region_code="southeastasia"; datacenter="新加坡数据中心" ;;
                *"Tokyo"*|*"东京"*)           region_code="japaneast"; datacenter="东京数据中心" ;;
                *"Seoul"*|*"首尔"*)           region_code="koreacentral"; datacenter="首尔数据中心" ;;
                *) datacenter="$location" ;;
            esac
            ;;
            
        *"Tencent"*|*"腾讯"*)
            cloud_provider="腾讯云"
            case "$location" in
                *"Hong Kong"*|*"香港"*)       region_code="ap-hongkong"; datacenter="香港数据中心" ;;
                *"Shanghai"*|*"上海"*)        region_code="ap-shanghai"; datacenter="上海金融云" ;;
                *"Singapore"*|*"新加坡"*)     region_code="ap-singapore"; datacenter="新加坡数据中心" ;;
                *"Tokyo"*|*"东京"*)           region_code="ap-tokyo"; datacenter="东京数据中心" ;;
                *) datacenter="$location" ;;
            esac
            ;;
            
        # 其他主要供应商
        *"DigitalOcean"*)
            cloud_provider="DigitalOcean"
            case "$location" in
                *"Singapore"*)     region_code="sgp1"; datacenter="新加坡 SG1" ;;
                *"Bangalore"*)     region_code="blr1"; datacenter="班加罗尔 BLR1" ;;
                *) datacenter="$location" ;;
            esac
            ;;
            
        *"Vultr"*)
            cloud_provider="Vultr"
            case "$location" in
                *"Tokyo"*)         region_code="nrt"; datacenter="东京 NRT" ;;
                *"Singapore"*)     region_code="sgp"; datacenter="新加坡 SGP" ;;
                *"Seoul"*)         region_code="icn"; datacenter="首尔 ICN" ;;
                *) datacenter="$location" ;;
            esac
            ;;
            
        *"Linode"*|*"Akamai"*)
            cloud_provider="Linode"
            case "$location" in
                *"Tokyo"*)         region_code="ap-northeast"; datacenter="东京数据中心" ;;
                *"Singapore"*)     region_code="ap-south"; datacenter="新加坡数据中心" ;;
                *) datacenter="$location" ;;
            esac
            ;;
            
        # 如果都不匹配，保留原始信息
        *)
            cloud_provider="$provider"
            datacenter="$location"
            region_code="unknown"
            ;;
    esac
    
    echo "$cloud_provider|$region_code|$datacenter"
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
        local provider_info=$(identify_provider "$(echo "$ip_info" | jq -r '.org // .isp // "Unknown"')" "$(echo "$ip_info" | jq -r '.city // "Unknown"'), $(echo "$ip_info" | jq -r '.country_name // .country // "Unknown"')")
        
        local cloud_provider=$(echo "$provider_info" | cut -d'|' -f1)
        local region_code=$(echo "$provider_info" | cut -d'|' -f2)
        local datacenter=$(echo "$provider_info" | cut -d'|' -f3)
        
        update_progress "$current" "$total" "$ip" "$latency" "$datacenter" "$cloud_provider"
        
        echo "$ip|$cloud_provider|$datacenter|$latency|$region_code" >> "${RESULTS_FILE}"
        
    done < "${TEMP_DIR}/tmp_ips.txt"
    
    echo "----------------------------------------"
    generate_report
    
    if [ "$background" = "true" ]; then
        log "SUCCESS" "后台分析完成！报告已生成: ${LATEST_REPORT}"
    else
        log "SUCCESS" "分析完成！报告已生成: ${LATEST_REPORT}"
    fi
}

# 显示菜单函数
show_menu() {
    clear
    echo
    echo -e "${GREEN}Solana 验证者节点延迟分析工具 ${WHITE}v${VERSION}${NC}"
    echo
    echo -e "${GREEN}1. 分析所有验证者节点延迟 (单线程)${NC}"
    echo -e "${GREEN}2. 并发分析所有节点 (推荐)${NC}"
    echo -e "${GREEN}3. 测试指定IP的延迟${NC}"
    echo -e "${GREEN}4. 查看最新分析报告${NC}"
    echo -e "${GREEN}5. 后台任务管理${NC}"
    echo -e "${GREEN}6. 配置设置${NC}"
    echo -e "${RED}0. 退出程序${NC}"
    echo
    echo -ne "${GREEN}请输入您的选择 [0-6]: ${NC}"
}

# 后台任务管理菜单
show_background_menu() {
    while true; do
        clear
        echo -e "${GREEN}后台任务管理${NC}"
        echo "==================="
        echo -e "${GREEN}1. 启动后台并发分析${NC}"
        echo -e "${GREEN}2. 实时监控后台任务${NC}"
        echo -e "${GREEN}3. 停止后台任务${NC}"
        echo -e "${GREEN}4. 查看后台任务状态${NC}"
        echo -e "${GREEN}5. 查看最新报告${NC}"
        echo -e "${RED}0. 返回主菜单${NC}"
        echo
        echo -ne "${GREEN}请选择 [0-5]: ${NC}"
        read -r choice

        case $choice in
            1)  if [ -f "${BACKGROUND_LOG}" ]; then
                    log "ERROR" "已有后台任务在运行"
                else
                    log "INFO" "启动后台分析任务..."
                    nohup bash "$0" background > "${BACKGROUND_LOG}" 2>&1 &
                    local pid=$!
                    echo $pid > "${TEMP_DIR}/background.pid"
                    sleep 2
                    
                    if kill -0 $pid 2>/dev/null; then
                        log "SUCCESS" "后台任务已启动，进程ID: $pid"
                    else
                        log "ERROR" "后台任务启动失败"
                        rm -f "${TEMP_DIR}/background.pid" "${BACKGROUND_LOG}"
                    fi
                fi
                read -rp "按回车键继续..."
                ;;
                
            2)  if [ -f "${BACKGROUND_LOG}" ]; then
                    echo -e "\n${GREEN}正在监控后台任务 (按 Ctrl+C 退出监控)${NC}"
                    echo -e "${GREEN}===================${NC}"
                    
                    trap 'echo -e "\n${GREEN}已退出监控模式${NC}"; return 0' INT
                    
                    tail -f "${BACKGROUND_LOG}" | while read -r line; do
                        if [[ $line == *"["*"]"* ]] || [[ $line == *"|"* ]] || [[ $line == "====="* ]]; then
                            echo -e "$line"
                        fi
                    done
                    
                    trap - INT
                else
                    log "WARN" "没有运行中的后台任务"
                    read -rp "按回车键继续..."
                fi
                ;;
                
            3)  if [ -f "${TEMP_DIR}/background.pid" ]; then
                    local pid=$(cat "${TEMP_DIR}/background.pid")
                    if kill -0 "$pid" 2>/dev/null; then
                        kill "$pid"
                        rm -f "${TEMP_DIR}/background.pid" "${BACKGROUND_LOG}"
                        log "SUCCESS" "后台任务已停止"
                    else
                        log "WARN" "后台任务已不存在"
                        rm -f "${TEMP_DIR}/background.pid" "${BACKGROUND_LOG}"
                    fi
                else
                    log "WARN" "没有运行中的后台任务"
                fi
                read -rp "按回车键继续..."
                ;;
                
            4)  if [ -f "${TEMP_DIR}/background.pid" ]; then
                    local pid=$(cat "${TEMP_DIR}/background.pid")
                    if kill -0 $pid 2>/dev/null; then
                        log "INFO" "后台任务正在运行 (PID: $pid)"
                        if [ -f "${PROGRESS_FILE}" ]; then
                            local progress=$(cat "${PROGRESS_FILE}")
                            log "INFO" "当前进度: $progress"
                        fi
                    else
                        log "WARN" "后台任务已结束"
                        rm -f "${TEMP_DIR}/background.pid"
                    fi
                else
                    log "INFO" "没有运行中的后台任务"
                fi
                read -rp "按回车键继续..."
                ;;
                
            5)  if [ -f "${LATEST_REPORT}" ]; then
                    clear
                    cat "${LATEST_REPORT}"
                else
                    log "ERROR" "未找到分析报告"
                fi
                read -rp "按回车键继续..."
                ;;
                
            0)  break 
                ;;
                
            *)  log "ERROR" "无效选择"
                sleep 1
                ;;
        esac
    done
}

# 主函数
main() {
    local cmd="${1:-}"
    
    if [ "$EUID" -ne 0 ]; then 
        log "ERROR" "请使用root权限运行此脚本"
        exit 1
    fi
    
    if [ "$cmd" = "background" ]; then
        analyze_validators true
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
    
    while true; do
        show_menu
        read -r choice
        
        case $choice in
            1)  analyze_validators false || {
                    log "ERROR" "分析失败"
                    read -rp "按回车键继续..."
                }
                ;;
            2)  analyze_validators_parallel false || {
                    log "ERROR" "并发分析失败"
                    read -rp "按回车键继续..."
                }
                ;;
            3)  echo -ne "\n${GREEN}请输入要测试的IP地址: ${NC}"
                read -r test_ip
                if [[ $test_ip =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                    test_single_ip "$test_ip"
                else
                    log "ERROR" "无效的IP地址"
                fi
                read -rp "按回车键继续..."
                ;;
            4)  if [ -f "${LATEST_REPORT}" ]; then
                    clear
                    cat "${LATEST_REPORT}"
                else
                    log "ERROR" "未找到分析报告"
                fi
                read -rp "按回车键继续..."
                ;;
            5)  show_background_menu
                ;;
            6)  show_config_menu
                ;;
            0)  log "INFO" "感谢使用！"
                exit 0
                ;;
            *)  log "ERROR" "无效选择"
                sleep 1
                ;;
        esac
    done
}

# 启动程序
main "$@"

    
