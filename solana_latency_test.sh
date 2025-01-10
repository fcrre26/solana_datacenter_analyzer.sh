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
VERSION="v1.3.1"

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

# 检查系统要求
check_system_requirements() {
    # 检查 fuser 命令是否可用
    if ! command -v fuser >/dev/null 2>&1; then
        log "INFO" "正在安装 psmisc..."
        apt-get update -qq && apt-get install -y -qq psmisc || {
            log "ERROR" "psmisc 安装失败"
            return 1
        }
    fi
    return 0
}

# 检查依赖
check_dependencies() {
    local deps=("curl" "nc" "whois" "awk" "sort" "jq" "geoip-bin")
    local missing=()

    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &>/dev/null; then
            missing+=("$dep")
        fi
    done

    if [ ${#missing[@]} -ne 0 ]; then
        log "INFO" "正在安装必要工具: ${missing[*]}"
        
        # 等待 apt 锁释放
        local max_attempts=30  # 最多等待5分钟
        local attempt=1
        
        while fuser /var/lib/dpkg/lock >/dev/null 2>&1 || \
              fuser /var/lib/apt/lists/lock >/dev/null 2>&1 || \
              fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do
            
            if [ $attempt -gt $max_attempts ]; then
                log "ERROR" "等待 apt 锁超时，请稍后再试"
                return 1
            fi
            
            log "WARN" "系统正在进行更新，等待中... (${attempt}/${max_attempts})"
            sleep 10
            ((attempt++))
        done
        
        # 尝试安装依赖
        if ! apt-get update -qq; then
            log "ERROR" "更新软件源失败"
            return 1
        fi
        
        if ! apt-get install -y -qq "${missing[@]}"; then
            log "ERROR" "工具安装失败"
            return 1
        fi
        
        # 安装 GeoIP 数据库
        if ! apt-get install -y -qq geoip-database; then
            log "ERROR" "GeoIP 数据库安装失败"
            return 1
        fi
        
        # 尝试安装额外的 GeoIP 数据库，但允许失败
        apt-get install -y -qq geoip-database-extra || log "WARN" "额外的 GeoIP 数据库安装失败，继续使用基本数据库"
        
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
        
        curl -L "$DOWNLOAD_URL" | tar jxf - -C "$SOLANA_INSTALL_DIR" || {
            log "ERROR" "Solana CLI 下载失败"
            return 1
        }
        
        rm -rf "$SOLANA_INSTALL_DIR/active_release"
        ln -s "$SOLANA_INSTALL_DIR/solana-release" "$SOLANA_INSTALL_DIR/active_release"
        
        export PATH="$SOLANA_INSTALL_DIR/active_release/bin:$PATH"
        
        solana config set --url https://api.mainnet-beta.solana.com || {
            log "ERROR" "Solana CLI 配置失败"
            return 1
        }
        
        log "SUCCESS" "Solana CLI 安装成功"
    else
        log "INFO" "Solana CLI 已安装"
    fi
    return 0
}

# 扩展机房位置字典
declare -A DATACENTER_INFO=(
    # AWS 机房
    ["ap-southeast-1"]="AWS新加坡 SG-Central-1"
    ["ap-southeast-2"]="AWS悉尼 SYD-Central-1"
    ["ap-northeast-1"]="AWS东京 TYO-Central-1"
    ["ap-northeast-2"]="AWS首尔 SEL-Central-1"
    ["ap-northeast-3"]="AWS大阪 OSA-Central-1"
    ["ap-east-1"]="AWS香港 HKG-Central-1"
    ["ap-south-1"]="AWS孟买 BOM-Central-1"
    ["ap-south-2"]="AWS海得拉巴 HYD-Central-1"
    ["eu-central-1"]="AWS法兰克福 FRA-Central-1"
    ["eu-central-2"]="AWS苏黎世 ZRH-Central-1"
    ["eu-west-1"]="AWS爱尔兰 DUB-Central-1"
    ["eu-west-2"]="AWS伦敦 LON-Central-1"
    ["eu-west-3"]="AWS巴黎 PAR-Central-1"
    ["eu-north-1"]="AWS斯德哥尔摩 STO-Central-1"
    ["eu-south-1"]="AWS米兰 MIL-Central-1"
    ["eu-south-2"]="AWS马德里 MAD-Central-1"
    ["us-east-1"]="AWS弗吉尼亚 IAD-Central-1"
    ["us-east-2"]="AWS俄亥俄 CMH-Central-1"
    ["us-west-1"]="AWS加利福尼亚 SFO-Central-1"
    ["us-west-2"]="AWS俄勒冈 PDX-Central-1"
    
    # Google Cloud 机房
    ["asia-east1"]="GCP台湾彰化 CHT-Central"
    ["asia-east2"]="GCP香港 HKG-Central"
    ["asia-northeast1"]="GCP东京 TYO-Central"
    ["asia-northeast2"]="GCP大阪 OSA-Central"
    ["asia-northeast3"]="GCP首尔 SEL-Central"
    ["asia-southeast1"]="GCP新加坡 SIN-Central"
    ["asia-southeast2"]="GCP雅加达 JKT-Central"
    ["asia-south1"]="GCP孟买 BOM-Central"
    ["asia-south2"]="GCP德里 DEL-Central"
    ["europe-west1"]="GCP比利时 BRU-Central"
    ["europe-west2"]="GCP伦敦 LON-Central"
    ["europe-west3"]="GCP法兰克福 FRA-Central"
    ["europe-west4"]="GCP荷兰 AMS-Central"
    ["europe-west6"]="GCP苏黎世 ZRH-Central"
    
    # 阿里云机房
    ["cn-hangzhou"]="阿里云杭州 HGH-可用区F"
    ["cn-shanghai"]="阿里云上海 SHA-可用区B"
    ["cn-beijing"]="阿里云北京 PEK-可用区H"
    ["cn-shenzhen"]="阿里云深圳 SZX-可用区D"
    ["cn-hongkong"]="阿里云香港 HKG-可用区C"
    ["cn-singapore"]="阿里云新加坡 SIN-可用区A"
    ["cn-tokyo"]="阿里云东京 TYO-可用区A"
    ["cn-sydney"]="阿里云悉尼 SYD-可用区A"
    ["cn-frankfurt"]="阿里云法兰克福 FRA-可用区A"
    ["cn-london"]="阿里云伦敦 LON-可用区A"
    
    # Azure 机房
    ["eastasia"]="Azure香港 HKG-Zone1"
    ["southeastasia"]="Azure新加坡 SIN-Zone1"
    ["japaneast"]="Azure东京 TYO-Zone1"
    ["japanwest"]="Azure大阪 OSA-Zone1"
    ["koreacentral"]="Azure首尔 SEL-Zone1"
    ["australiaeast"]="Azure悉尼 SYD-Zone1"
    ["australiasoutheast"]="Azure墨尔本 MEL-Zone1"
    ["centralindia"]="Azure浦那 PNQ-Zone1"
    ["westeurope"]="Azure阿姆斯特丹 AMS-Zone1"
    ["northeurope"]="Azure都柏林 DUB-Zone1"
    
    # 腾讯云机房
    ["ap-beijing"]="腾讯云北京 BJ-金融云"
    ["ap-shanghai"]="腾讯云上海 SH-金融云"
    ["ap-guangzhou"]="腾讯云广州 GZ-金融云"
    ["ap-hongkong"]="腾讯云香港 HK-金融云"
    ["ap-singapore"]="腾讯云新加坡 SG-金融云"
    ["ap-seoul"]="腾讯云首尔 SEL-金融云"
    ["ap-tokyo"]="腾讯云东京 TYO-金融云"
    ["eu-frankfurt"]="腾讯云法兰克福 FRA-金融云"
    ["na-siliconvalley"]="腾讯云硅谷 SV-金融云"
    ["na-ashburn"]="腾讯云弗吉尼亚 IAD-金融云"
)

# IP 地理位置查询函数
get_ip_location() {
    local ip="$1"
    local location=""
    
    # 方法1: 使用 ipinfo.io API
    location=$(curl -s "https://ipinfo.io/${ip}/json" | jq -r '.city + ", " + .region + ", " + .country' 2>/dev/null)
    
    # 如果 ipinfo.io 失败，尝试方法2: 使用 ip-api.com
    if [ -z "$location" ] || [ "$location" = "null, null, null" ]; then
        location=$(curl -s "http://ip-api.com/json/${ip}" | jq -r '.city + ", " + .regionName + ", " + .country' 2>/dev/null)
    fi
    
    # 如果还是失败，尝试方法3: 使用 GeoIP 数据库
    if [ -z "$location" ] || [ "$location" = "null, null, null" ]; then
        if command -v geoiplookup >/dev/null 2>&1; then
            location=$(geoiplookup "$ip" | grep "GeoIP City" | cut -d':' -f2- | xargs)
        fi
    fi
    
    echo "${location:-Unknown}"
}

# 增强的数据中心识别函数
identify_datacenter() {
    local ip="$1"
    local asn_info
    asn_info=$(whois -h whois.cymru.com " -v $ip" 2>/dev/null)
    
    if [ $? -eq 0 ]; then
        local asn_org
        asn_org=$(echo "$asn_info" | tail -n1 | awk -F'|' '{print $6}' | xargs)
        local asn_num
        asn_num=$(echo "$asn_info" | tail -n1 | awk -F'|' '{print $1}' | xargs)
        
        # 获取详细的地理位置信息
        local location=$(get_ip_location "$ip")
        local datacenter_location=""
        
        # 尝试识别具体机房
        case "$asn_org" in
            *"Amazon"*|*"AWS"*)
                local aws_region=$(curl -s --connect-timeout 2 "http://${ip}:8899/health" | jq -r '.region' 2>/dev/null)
                if [ -n "$aws_region" ] && [ -n "${DATACENTER_INFO[$aws_region]}" ]; then
                    datacenter_location="${DATACENTER_INFO[$aws_region]}"
                else
                    for region in "${!DATACENTER_INFO[@]}"; do
                        if [[ $region == "ap-"* ]] && [[ $location == *"${region#ap-}"* ]]; then
                            datacenter_location="${DATACENTER_INFO[$region]}"
                            break
                        fi
                    done
                fi
                ;;
            *"Google"*|*"GCP"*)
                local gcp_zone=$(curl -s --connect-timeout 2 "http://metadata.google.internal/computeMetadata/v1/instance/zone" -H "Metadata-Flavor: Google" 2>/dev/null)
                if [ -n "$gcp_zone" ] && [ -n "${DATACENTER_INFO[$gcp_zone]}" ]; then
                    datacenter_location="${DATACENTER_INFO[$gcp_zone]}"
                else
                    for region in "${!DATACENTER_INFO[@]}"; do
                        if [[ $region == "asia-"* ]] && [[ $location == *"${region#asia-}"* ]]; then
                            datacenter_location="${DATACENTER_INFO[$region]}"
                            break
                        fi
                    done
                fi
                ;;
            *"Alibaba"*|*"Aliyun"*)
                local ali_region=$(curl -s --connect-timeout 2 "http://100.100.100.200/latest/meta-data/region-id" 2>/dev/null)
                if [ -n "$ali_region" ] && [ -n "${DATACENTER_INFO[$ali_region]}" ]; then
                    datacenter_location="${DATACENTER_INFO[$ali_region]}"
                else
                    for region in "${!DATACENTER_INFO[@]}"; do
                        if [[ $region == "cn-"* ]] && [[ $location == *"${region#cn-}"* ]]; then
                            datacenter_location="${DATACENTER_INFO[$region]}"
                            break
                        fi
                    done
                fi
                ;;
        esac
        
        if [ -z "$datacenter_location" ]; then
            datacenter_location="$location"
        fi
        
        echo "${asn_org:-Unknown}|${datacenter_location:-Unknown}"
    else
        local location=$(get_ip_location "$ip")
        echo "Unknown|${location:-Unknown}"
    fi
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
        local avg_latency=$((total_time / success_count))
        echo "$avg_latency"
        return 0
    fi
    
    if command -v curl >/dev/null 2>&1; then
        local curl_start=$(date +%s%N)
        if curl -s -o /dev/null -w '%{time_total}\n' --connect-timeout 2 "http://$ip:8899" 2>/dev/null; then
            local curl_end=$(date +%s%N)
            local curl_duration=$(( (curl_end - curl_start) / 1000000 ))
            echo "$curl_duration"
            return 0
        fi
    fi
    
    echo "999"
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
    local time_per_item=$((elapsed_time / current))
    local remaining_items=$((total - current))
    local eta=$((time_per_item * remaining_items))
    
    # 每20行显示一次进度条和表头
    if [ $((current % 20)) -eq 1 ]; then
        # 打印总进度（在顶部）
        printf "\n[" 
        printf "${GREEN}█%.0s${NC}" $(seq 1 $((progress * 40 / 100)))
        printf "${WHITE}░%.0s${NC}" $(seq 1 $((40 - progress * 40 / 100)))
        printf "] ${GREEN}%3d%%${NC} | 已测试: ${GREEN}%d${NC}/${WHITE}%d${NC} | 预计剩余: ${WHITE}%dm%ds${NC}\n\n" \
            "$progress" "$current" "$total" \
            $((eta / 60)) $((eta % 60))
        
        # 只在每页开始时显示表头
        printf "${WHITE}%-10s | %-15s | %-8s | %-15s | %-30s | %-15s${NC}\n" \
            "时间" "IP地址" "延迟" "供应商" "机房位置" "进度"
        printf "${WHITE}%s${NC}\n" "$(printf '=%.0s' {1..100})"
    fi
    
    # 延迟颜色处理
    local latency_color
    local latency_display
    if [[ "$latency" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        latency_int=${latency%.*}
        if [ -z "$latency_int" ] || [ "$latency_int" -lt 100 ]; then
            latency_color=$GREEN
            latency_display="${latency}ms"
        else
            latency_color=$YELLOW
            latency_display="${latency}ms"
        fi
    else
        latency_color=$RED
        latency_display="超时"
    fi
    
    # 格式化供应商显示
    local provider_display
    case "$provider" in
        *"Amazon"*|*"AWS"*)
            provider_display="${CYAN}AWS${NC}"
            ;;
        *"Google"*|*"GCP"*)
            provider_display="${YELLOW}GCP${NC}"
            ;;
        *"Alibaba"*|*"Aliyun"*)
            provider_display="${RED}阿里云${NC}"
            ;;
        *"Microsoft"*|*"Azure"*)
            provider_display="${BLUE}Azure${NC}"
            ;;
        *"Tencent"*)
            provider_display="${GREEN}腾讯云${NC}"
            ;;
        *)
            provider_display="${WHITE}${provider}${NC}"
            ;;
    esac
    
    # 打印当前测试结果（交替颜色）
    if [ $((current % 2)) -eq 0 ]; then
        printf "${GREEN}%s | ${CYAN}%-15s${NC} | ${latency_color}%-8s${NC} | %-15s | ${WHITE}%-30s${NC} | ${GREEN}%d/%d${NC}\n" \
            "$(date '+%H:%M:%S')" \
            "$ip" \
            "$latency_display" \
            "$provider_display" \
            "$location" \
            "$current" "$total"
    else
        printf "${WHITE}%s | ${CYAN}%-15s${NC} | ${latency_color}%-8s${NC} | %-15s | ${WHITE}%-30s${NC} | ${GREEN}%d/%d${NC}\n" \
            "$(date '+%H:%M:%S')" \
            "$ip" \
            "$latency_display" \
            "$provider_display" \
            "$location" \
            "$current" "$total"
    fi
}


# 获取验证者信息
get_validators() {
    log "INFO" "正在获取验证者信息..."
    
    local validators
    validators=$(solana gossip 2>/dev/null)
    if [ $? -ne 0 ]; then
        log "ERROR" "无法获取验证者信息"
        return 1
    fi
    
    local ips
    ips=$(echo "$validators" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | sort -u)
    if [ -z "$ips" ]; then
        log "ERROR" "未找到验证者IP地址"
        return 1
    fi
    
    echo "$ips"
    return 0
}

# 单线程分析验证者节点
analyze_validators() {
    local background="${1:-false}"
    BACKGROUND_MODE="$background"
    
    log "INFO" "开始分析验证者节点分布"
    
    local validator_ips
    validator_ips=$(get_validators) || {
        log "ERROR" "获取验证者信息失败"
        return 1
    }
    
    : > "${RESULTS_FILE}"
    echo "$validator_ips" > "${TEMP_DIR}/tmp_ips.txt"
    
    local total=$(wc -l < "${TEMP_DIR}/tmp_ips.txt")
    local current=0
    
    # 记录开始时间
    START_TIME=$(date +%s)
    
    log "INFO" "找到 ${total} 个验证者节点"
    echo "----------------------------------------"
    
    while read -r ip; do
        ((current++))
        
        # 测试网络延迟
        local latency=$(test_network_quality "$ip")
        
        # 获取数据中心信息
        local dc_info=$(identify_datacenter "$ip")
        local provider=$(echo "$dc_info" | cut -d'|' -f1)
        local location=$(echo "$dc_info" | cut -d'|' -f2)
        
        update_progress "$current" "$total" "$ip" "$latency" "$location" "$provider"
        
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

# 并发分析验证者节点
analyze_validators_parallel() {
    local background="${1:-false}"
    BACKGROUND_MODE="$background"
    local max_jobs=${MAX_CONCURRENT_JOBS:-10}
    
    log "INFO" "开始并发分析验证者节点分布"
    
    local validator_ips
    validator_ips=$(get_validators) || {
        log "ERROR" "获取验证者信息失败"
        return 1
    }
    
    : > "${RESULTS_FILE}"
    echo "$validator_ips" > "${TEMP_DIR}/tmp_ips.txt"
    
    local total=$(wc -l < "${TEMP_DIR}/tmp_ips.txt")
    local current=0
    
    # 记录开始时间
    START_TIME=$(date +%s)
    
    log "INFO" "找到 ${total} 个验证者节点"
    echo "----------------------------------------"
    
    # 创建临时结果目录
    local tmp_result_dir="${TEMP_DIR}/results"
    mkdir -p "$tmp_result_dir"
    rm -f "${tmp_result_dir}"/*  # 清理旧的结果文件
    
    # 创建信号量
    local sem_file="${TEMP_DIR}/semaphore"
    mkfifo "$sem_file"
    exec 3<>"$sem_file"
    rm "$sem_file"
    
    # 初始化信号量
    for ((i=1; i<=max_jobs; i++)); do
        printf "%s\n" "$i" >&3
    done
    
    # 定义结果处理函数
    process_results() {
        local result_file="$1"
        local ip="$2"
        local current="$3"
        
        # 读取结果文件的内容
        local latency provider location
        read -r latency provider location < "$result_file"
        
        # 更新显示
        update_progress "$current" "$total" "$ip" "$latency" "$location" "$provider"
        
        # 将结果写入最终结果文件
        echo "$ip|$provider|$location|$latency" >> "${RESULTS_FILE}"
        
        # 清理临时结果文件
        rm -f "$result_file"
    }

        # 并发测试主循环
    while read -r ip; do
        read -u 3 token  # 获取信号量
        ((current++))
        
        {
            local result_file="${tmp_result_dir}/${current}.result"
            
            # 在后台执行测试，并将结果写入临时文件
            local latency=$(test_network_quality "$ip")
            local dc_info=$(identify_datacenter "$ip")
            local provider=$(echo "$dc_info" | cut -d'|' -f1)
            local location=$(echo "$dc_info" | cut -d'|' -f2)
            
            # 将结果写入临时文件
            echo "$latency $provider $location" > "$result_file"
            
            # 处理结果
            process_results "$result_file" "$ip" "$current"
            
            # 释放信号量
            printf "%s\n" "$token" >&3
            
        } &
        
    done < "${TEMP_DIR}/tmp_ips.txt"
    
    # 等待所有后台任务完成
    wait
    
    # 关闭信号量
    exec 3>&-
    
    # 清理临时文件
    rm -rf "$tmp_result_dir"
    
    echo "----------------------------------------"
    generate_report
    
    if [ "$background" = "true" ]; then
        log "SUCCESS" "后台并发分析完成！报告已生成: ${LATEST_REPORT}"
    else
        log "SUCCESS" "并发分析完成！报告已生成: ${LATEST_REPORT}"
    fi
}

# 生成分析报告
generate_report() {
    log "INFO" "正在生成报告..."
    
    local total_nodes=$(wc -l < "${RESULTS_FILE}")
    local avg_latency=$(awk -F'|' '$4!=999 { sum+=$4; count++ } END { print sum/count }' "${RESULTS_FILE}")
    local min_latency=$(sort -t'|' -k4 -n "${RESULTS_FILE}" | head -1 | cut -d'|' -f4)
    local max_latency=$(sort -t'|' -k4 -n "${RESULTS_FILE}" | grep -v "999" | tail -1 | cut -d'|' -f4)
    
    {
        echo -e "${GREEN}# Solana 验证者节点延迟分析报告${NC}"
        echo "生成时间: $(date '+%Y-%m-%d %H:%M:%S')"
        echo "总节点数: ${total_nodes}"
        echo "平均延迟: ${avg_latency}ms"
        echo "最低延迟: ${min_latency}ms"
        echo "最高延迟: ${max_latency}ms"
        echo
        
        echo -e "${GREEN}## 延迟统计 (Top 20)${NC}"
        echo "| IP地址          | 位置                  | 延迟(ms)   | 供应商               |"
        echo "|-----------------|----------------------|------------|---------------------|"
        
        local line_num=0
        sort -t'|' -k4 -n "${RESULTS_FILE}" | head -20 | while IFS='|' read -r ip provider location latency; do
            ((line_num++))
            if [ "$latency" != "999" ]; then
                if [ $((line_num % 2)) -eq 0 ]; then
                    printf "${GREEN}| %-15s | %-20s | %-10s | %-20s |${NC}\n" \
                        "$ip" "$location" "$latency" "$provider"
                else
                    printf "${WHITE}| %-15s | %-20s | %-10s | %-20s |${NC}\n" \
                        "$ip" "$location" "$latency" "$provider"
                fi
            fi
        done
        
        echo
        echo -e "${GREEN}## 供应商分布${NC}"
        echo "| 供应商               | 节点数量    | 平均延迟(ms)    |"
        echo "|---------------------|------------|-----------------|"
        
        awk -F'|' '$4!=999 {
            count[$2]++
            latency_sum[$2]+=$4
        }
        END {
            for (provider in count) {
                printf "| %-20s | %-10d | %-15.2f |\n", 
                    provider, 
                    count[provider], 
                    latency_sum[provider]/count[provider]
            }
        }' "${RESULTS_FILE}" | sort -t'|' -k3 -n

                echo
        echo -e "${GREEN}## 机房分布${NC}"
        echo "| 机房位置              | 节点数量    | 平均延迟(ms)    |"
        echo "|---------------------|------------|-----------------|"
        
        awk -F'|' '$4!=999 {
            count[$3]++
            latency_sum[$3]+=$4
        }
        END {
            for (location in count) {
                printf "| %-20s | %-10d | %-15.2f |\n", 
                    location, 
                    count[location], 
                    latency_sum[location]/count[location]
            }
        }' "${RESULTS_FILE}" | sort -t'|' -k3 -n
        
    } > "${LATEST_REPORT}"
    
    log "SUCCESS" "报告已生成: ${LATEST_REPORT}"
}

# 显示菜单
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
        echo -e "1. 启动后台并发分析"
        echo -e "2. 查看后台任务状态"
        echo -e "3. 停止后台任务"
        echo -e "0. 返回主菜单"
        echo
        echo -ne "请选择 [0-3]: "
        read -r choice

        case $choice in
            1)  if [ -f "${BACKGROUND_LOG}" ]; then
                    log "ERROR" "已有后台任务在运行"
                else
                    nohup bash "$0" background > "${BACKGROUND_LOG}" 2>&1 &
                    log "SUCCESS" "后台任务已启动，进程ID: $!"
                    echo $! > "${TEMP_DIR}/background.pid"
                fi
                read -rp "按回车键继续..."
                ;;
            2)  check_background_task
                read -rp "按回车键继续..."
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
            0)  break ;;
            *)  log "ERROR" "无效选择"
                sleep 1
                ;;
        esac
    done
}

# 测试单个IP
test_single_ip() {
    local ip="$1"
    
    echo -e "\n${GREEN}测试 IP: ${CYAN}$ip${NC}"
    echo -e "${GREEN}===================${NC}"
    
    local latency=$(test_network_quality "$ip")
    local dc_info=$(identify_datacenter "$ip")
    local provider=$(echo "$dc_info" | cut -d'|' -f1)
    local location=$(echo "$dc_info" | cut -d'|' -f2)
    
    # 根据延迟值设置颜色
    local latency_color
    if [[ "$latency" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        latency_int=${latency%.*}
        if [ -z "$latency_int" ] || [ "$latency_int" -lt 100 ]; then
            latency_color=$GREEN
        else
            latency_color=$YELLOW
        fi
    else
        latency_color=$RED
        latency="超时"
    fi
    
    echo -e "延迟: ${latency_color}${latency}ms${NC}"
    echo -e "供应商: ${provider}"
    echo -e "机房位置: ${WHITE}${location}${NC}"
    echo -e "${GREEN}===================${NC}"
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
