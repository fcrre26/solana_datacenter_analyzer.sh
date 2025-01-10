#!/bin/bash

# 设置环境变量
SOLANA_INSTALL_DIR="/root/.local/share/solana/install"
export PATH="$SOLANA_INSTALL_DIR/active_release/bin:$PATH"

# 启用严格模式
set -eo pipefail

# 颜色定义
GREEN='\033[1;32m'      # 绿色加粗
RED='\033[1;31m'        # 红色加粗
YELLOW='\033[1;33m'     # 黄色加粗
CYAN='\033[1;36m'       # 青色加粗
WHITE='\033[1;37m'      # 亮白色加粗
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
VERSION="v1.3.0"

# 创建必要的目录
mkdir -p "${TEMP_DIR}" "${REPORT_DIR}"

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

# 位置翻译字典
declare -A LOCATION_TRANS=(
    # AWS 机房
    ["ap-southeast-1"]="AWS新加坡机房"
    ["ap-northeast-1"]="AWS东京机房"
    ["ap-east-1"]="AWS香港机房"
    ["ap-south-1"]="AWS孟买机房"
    ["eu-central-1"]="AWS法兰克福机房"
    ["eu-west-2"]="AWS伦敦机房"
    ["us-east-1"]="AWS弗吉尼亚机房"
    ["us-west-1"]="AWS加利福尼亚机房"
    
    # Google Cloud 机房
    ["asia-east2"]="GCP香港机房"
    ["asia-northeast1"]="GCP东京机房"
    ["asia-southeast1"]="GCP新加坡机房"
    ["europe-west3"]="GCP法兰克福机房"
    ["us-central1"]="GCP爱荷华机房"
    
    # Alibaba Cloud 机房
    ["cn-hongkong"]="阿里云香港机房"
    ["ap-southeast-1"]="阿里云新加坡机房"
    ["ap-northeast-1"]="阿里云东京机房"
    
    # Azure 机房
    ["eastasia"]="Azure香港机房"
    ["southeastasia"]="Azure新加坡机房"
    ["japaneast"]="Azure东京机房"
    
    # 城市和国家
    ["Singapore"]="新加坡"
    ["Tokyo"]="东京"
    ["Seoul"]="首尔"
    ["Hong Kong"]="香港"
    ["Frankfurt"]="法兰克福"
    ["London"]="伦敦"
    ["New York"]="纽约"
    ["Amsterdam"]="阿姆斯特丹"
    ["Paris"]="巴黎"
    ["Sydney"]="悉尼"
    ["San Francisco"]="旧金山"
    ["Toronto"]="多伦多"
    ["Mumbai"]="孟买"
    ["Bangalore"]="班加罗尔"
    ["Berlin"]="柏林"
    ["Los Angeles"]="洛杉矶"
    ["Chicago"]="芝加哥"
    ["Dallas"]="达拉斯"
    ["Miami"]="迈阿密"
    ["Seattle"]="西雅图"
    ["Vancouver"]="温哥华"
    ["Montreal"]="蒙特利尔"
    ["Sao Paulo"]="圣保罗"
    ["Melbourne"]="墨尔本"
    ["Perth"]="珀斯"
    ["Auckland"]="奥克兰"
    ["Jakarta"]="雅加达"
    ["Kuala Lumpur"]="吉隆坡"
    ["Bangkok"]="曼谷"
    ["Manila"]="马尼拉"
    ["Taipei"]="台北"
    ["Chennai"]="金奈"
    ["Delhi"]="德里"
    ["Moscow"]="莫斯科"
    ["Stockholm"]="斯德哥尔摩"
    ["Oslo"]="奥斯陆"
    ["Copenhagen"]="哥本哈根"
    ["Warsaw"]="华沙"
    ["Prague"]="布拉格"
    ["Vienna"]="维也纳"
    ["Milan"]="米兰"
    ["Madrid"]="马德里"
    ["Lisbon"]="里斯本"
    ["Dublin"]="都柏林"
    
    # 国家代码
    ["SG"]="新加坡"
    ["JP"]="日本"
    ["KR"]="韩国"
    ["HK"]="香港"
    ["DE"]="德国"
    ["GB"]="英国"
    ["US"]="美国"
    ["NL"]="荷兰"
    ["FR"]="法国"
    ["AU"]="澳大利亚"
    ["IN"]="印度"
    ["CN"]="中国"
    ["TW"]="台湾"
    ["MY"]="马来西亚"
    ["TH"]="泰国"
    ["PH"]="菲律宾"
    ["ID"]="印度尼西亚"
    ["VN"]="越南"
    ["RU"]="俄罗斯"
    ["SE"]="瑞典"
    ["NO"]="挪威"
    ["DK"]="丹麦"
    ["PL"]="波兰"
    ["CZ"]="捷克"
    ["AT"]="奥地利"
    ["IT"]="意大利"
    ["ES"]="西班牙"
    ["PT"]="葡萄牙"
    ["IE"]="爱尔兰"
    ["BR"]="巴西"
    ["AR"]="阿根廷"
    ["CL"]="智利"
    ["ZA"]="南非"
    ["AE"]="阿联酋"
    ["IL"]="以色列"
    ["TR"]="土耳其"
)

# 格式化数字
format_number() {
    printf "%'d" "$1"
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

# 显示菜单
show_menu() {
    clear
    echo
    echo -e "${GREEN}Solana 验证者节点延迟分析工具 ${WHITE}v${VERSION}${NC}"
    echo
    echo -e "${GREEN}1. 分析所有验证者节点延迟${NC}"
    echo -e "${GREEN}2. 在后台分析所有节点${NC}"
    echo -e "${GREEN}3. 测试指定IP的延迟${NC}"
    echo -e "${GREEN}4. 查看最新分析报告${NC}"
    echo -e "${GREEN}5. 查看后台任务状态${NC}"
    echo -e "${RED}0. 退出程序${NC}"
    echo
    echo -ne "${GREEN}请输入您的选择 [0-5]: ${NC}"
}

# 获取位置中文翻译
get_location_cn() {
    local location="$1"
    local cn_name=""
    
    # 首先尝试从IP地理位置API获取
    if [[ "$location" == "Unknown" || "$location" == "ZZ" ]]; then
        cn_name=$(get_ip_location "$ip")
    else
        # 遍历位置字符串中的所有部分
        for key in "${!LOCATION_TRANS[@]}"; do
            if [[ "$location" == *"$key"* ]]; then
                if [ -n "$cn_name" ]; then
                    cn_name="${cn_name},"
                fi
                cn_name="${cn_name}${LOCATION_TRANS[$key]}"
            fi
        done
    fi
    
    if [ -z "$cn_name" ]; then
        echo "$location"
    else
        echo "$cn_name"
    fi
}

# 更新进度显示
update_progress() {
    local current="$1"
    local total="$2"
    local ip="$3"
    local latency="$4"
    local location="$5"
    
    local progress=$((current * 100 / total))
    
    # 根据延迟值设置颜色和显示
    local latency_color
    local latency_display
    
    # 改进延迟判断逻辑
    if [[ "$latency" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        # 将浮点数转换为整数（去掉小数部分）
        latency_int=${latency%.*}
        if [ -z "$latency_int" ]; then
            latency_int=0
        fi
        
        if [ "$latency_int" -lt 100 ]; then
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
    
    # 进度条 (使用绿色方块)
    local bar_size=20
    local completed=$((progress * bar_size / 100))
    local remaining=$((bar_size - completed))
    local progress_bar=""
    
    # 只在有进度时显示绿色方块
    if [ $completed -gt 0 ]; then
        for ((i=0; i<completed; i++)); do 
            progress_bar+="${GREEN}█${NC}"
        done
    fi
    for ((i=0; i<remaining; i++)); do 
        progress_bar+=" "
    done

    # 获取位置的中文翻译
    local location_cn=$(get_location_cn "$location")
    
    # 格式化进度显示
    printf "\r[%s] %3d%% | ${CYAN}%-15s${NC} | 延迟: ${latency_color}%-8s${NC} | 位置: ${WHITE}%-20s${NC}" \
        "$progress_bar" "$progress" "$ip" "$latency_display" "$location_cn"
}

# 测试网络质量
test_network_quality() {
    local ip="$1"
    local retries=2
    local timeout=2
    local total_time=0
    local success_count=0
    local ports=("8899" "8900" "8001" "8000")
    
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

# 识别数据中心
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
        
        # 如果是云服务提供商，尝试识别具体机房
        case "$asn_org" in
            *"Amazon"*|*"AWS"*)
                local aws_region=$(curl -s --connect-timeout 2 "http://${ip}:8899/health" | jq -r '.region' 2>/dev/null)
                if [ -n "$aws_region" ]; then
                    location="AWS ${aws_region} 机房, ${location}"
                fi
                ;;
            *"Google"*|*"GCP"*)
                local gcp_zone=$(curl -s --connect-timeout 2 "http://metadata.google.internal/computeMetadata/v1/instance/zone" -H "Metadata-Flavor: Google" 2>/dev/null)
                if [ -n "$gcp_zone" ]; then
                    location="GCP ${gcp_zone} 机房, ${location}"
                fi
                ;;
            *"Alibaba"*|*"Aliyun"*)
                local ali_region=$(curl -s --connect-timeout 2 "http://100.100.100.200/latest/meta-data/region-id" 2>/dev/null)
                if [ -n "$ali_region" ]; then
                    location="阿里云 ${ali_region} 机房, ${location}"
                fi
                ;;
        esac
        
        echo "${asn_org:-Unknown}|${location:-Unknown}"
    else
        local location=$(get_ip_location "$ip")
        echo "Unknown|${location:-Unknown}"
    fi
}

# 获取位置中文翻译
get_location_cn() {
    local location="$1"
    local cn_name=""
    
    # 首先尝试从IP地理位置API获取
    if [[ "$location" == "Unknown" || "$location" == "ZZ" ]]; then
        cn_name=$(get_ip_location "$ip")
    else
        # 遍历位置字符串中的所有部分
        for key in "${!LOCATION_TRANS[@]}"; do
            if [[ "$location" == *"$key"* ]]; then
                if [ -n "$cn_name" ]; then
                    cn_name="${cn_name},"
                fi
                cn_name="${cn_name}${LOCATION_TRANS[$key]}"
            fi
        done
    fi
    
    if [ -z "$cn_name" ]; then
        echo "$location"
    else
        echo "$cn_name"
    fi
}

# 更新进度显示
update_progress() {
    local current="$1"
    local total="$2"
    local ip="$3"
    local latency="$4"
    local location="$5"
    
    local progress=$((current * 100 / total))
    
    # 根据延迟值设置颜色和显示
    local latency_color
    local latency_display
    
    # 改进延迟判断逻辑
    if [[ "$latency" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        # 将浮点数转换为整数（去掉小数部分）
        latency_int=${latency%.*}
        if [ -z "$latency_int" ]; then
            latency_int=0
        fi
        
        if [ "$latency_int" -lt 100 ]; then
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
    
    # 进度条 (使用绿色方块)
    local bar_size=20
    local completed=$((progress * bar_size / 100))
    local remaining=$((bar_size - completed))
    local progress_bar=""
    
    # 只在有进度时显示绿色方块
    if [ $completed -gt 0 ]; then
        for ((i=0; i<completed; i++)); do 
            progress_bar+="${GREEN}█${NC}"
        done
    fi
    for ((i=0; i<remaining; i++)); do 
        progress_bar+=" "
    done

    # 获取位置的中文翻译
    local location_cn=$(get_location_cn "$location")
    
    # 格式化进度显示
    printf "\r[%s] %3d%% | ${CYAN}%-15s${NC} | 延迟: ${latency_color}%-8s${NC} | 位置: ${WHITE}%-20s${NC}" \
        "$progress_bar" "$progress" "$ip" "$latency_display" "$location_cn"
}

# 测试网络质量
test_network_quality() {
    local ip="$1"
    local retries=2
    local timeout=2
    local total_time=0
    local success_count=0
    local ports=("8899" "8900" "8001" "8000")
    
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

# 识别数据中心
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
        
        # 如果是云服务提供商，尝试识别具体机房
        case "$asn_org" in
            *"Amazon"*|*"AWS"*)
                local aws_region=$(curl -s --connect-timeout 2 "http://${ip}:8899/health" | jq -r '.region' 2>/dev/null)
                if [ -n "$aws_region" ]; then
                    location="AWS ${aws_region} 机房, ${location}"
                fi
                ;;
            *"Google"*|*"GCP"*)
                local gcp_zone=$(curl -s --connect-timeout 2 "http://metadata.google.internal/computeMetadata/v1/instance/zone" -H "Metadata-Flavor: Google" 2>/dev/null)
                if [ -n "$gcp_zone" ]; then
                    location="GCP ${gcp_zone} 机房, ${location}"
                fi
                ;;
            *"Alibaba"*|*"Aliyun"*)
                local ali_region=$(curl -s --connect-timeout 2 "http://100.100.100.200/latest/meta-data/region-id" 2>/dev/null)
                if [ -n "$ali_region" ]; then
                    location="阿里云 ${ali_region} 机房, ${location}"
                fi
                ;;
        esac
        
        echo "${asn_org:-Unknown}|${location:-Unknown}"
    else
        local location=$(get_ip_location "$ip")
        echo "Unknown|${location:-Unknown}"
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

# 分析验证者节点
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
    
    log "INFO" "找到 ${total} 个验证者节点"
    
    while read -r ip; do
        ((current++))
        
        # 测试网络延迟
        local latency=$(test_network_quality "$ip")
        
        # 获取数据中心信息
        local dc_info=$(identify_datacenter "$ip")
        local provider=$(echo "$dc_info" | cut -d'|' -f1)
        local location=$(echo "$dc_info" | cut -d'|' -f2)
        
        update_progress "$current" "$total" "$ip" "$latency" "$location"
        
        echo "$ip|$provider|$location|$latency" >> "${RESULTS_FILE}"
        
    done < "${TEMP_DIR}/tmp_ips.txt"
    
    echo # 换行
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
    
    {
        echo -e "${GREEN}# Solana 验证者节点延迟分析报告${NC}"
        echo "生成时间: $(date '+%Y-%m-%d %H:%M:%S')"
        echo
        
        echo -e "${GREEN}## 延迟统计 (Top 20)${NC}"
        echo "| IP地址          | 位置                  | 延迟(ms)   | 供应商               |"
        echo "|-----------------|----------------------|------------|---------------------|"
        
        sort -t'|' -k4 -n "${RESULTS_FILE}" | head -20 | while IFS='|' read -r ip provider location latency; do
            if [ "$latency" != "999" ]; then
                local location_cn=$(get_location_cn "$location")
                printf "| %-15s | %-20s | %-10s | %-20s |\n" \
                    "$ip" "$location_cn" "$latency" "$provider"
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
        echo -e "${GREEN}## 位置分布${NC}"
        echo "| 位置                  | 节点数量    | 平均延迟(ms)    |"
        echo "|----------------------|------------|-----------------|"
        
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
        }' "${RESULTS_FILE}" | sort -t'|' -k3 -n | while IFS='|' read -r line; do
            local location=$(echo "$line" | awk -F'|' '{print $1}')
            local location_cn=$(get_location_cn "$location")
            echo "$line" | sed "s|$location|$location_cn|"
        done

        echo
        echo -e "${GREEN}## 部署建议${NC}"
        echo "根据延迟测试结果，以下是推荐的部署方案（按优先级排序）："
        echo
        echo "### 最优部署方案"
        echo "| 供应商          | 数据中心位置        | IP网段          | 平均延迟     | 测试IP          | 测试延迟    |"
        echo "|-----------------|-------------------|----------------|------------|-----------------|------------|"

        # 从结果文件中提取最优的部署方案
        awk -F'|' '$4!=999 {
            provider=$2
            location=$3
            ip=$1
            latency=$4
            
            # 提取IP网段 (假设是 /24)
            split(ip, parts, ".")
            subnet = parts[1] "." parts[2] "." parts[3] ".0/24"
            
            # 按位置和供应商分组
            key = provider "|" location "|" subnet
            count[key]++
            latency_sum[key] += latency
            if (latency < min_latency[key] || min_latency[key] == 0) {
                min_latency[key] = latency
                best_ip[key] = ip
            }
        }
        END {
            # 输出前5个最优方案
            for (key in count) {
                split(key, parts, "|")
                avg_latency = latency_sum[key]/count[key]
                printf "| %-15s | %-17s | %-14s | %-10.2fms | %-15s | %-9dms |\n", 
                    parts[1],    # 供应商
                    parts[2],    # 位置
                    parts[3],    # 网段
                    avg_latency, # 平均延迟
                    best_ip[key],# 测试IP
                    min_latency[key] # 最低延迟
            }
        }' "${RESULTS_FILE}" | sort -t'|' -k4 -n | head -5 | while IFS='|' read -r line; do
            local location=$(echo "$line" | awk -F'|' '{print $2}')
            local location_cn=$(get_location_cn "$location")
            echo "$line" | sed "s|$location|$location_cn|"
        done
        
        echo
        echo "### 部署建议详情"
        echo
        echo "1. 优选部署方案"
        printf "   %-15s %s\n" "推荐供应商:" "AWS, Alibaba Cloud, Tencent Cloud"
        printf "   %-15s %s\n" "推荐机房:" "AWS-ap-southeast-1(新加坡), AWS-ap-northeast-1(东京)"
        printf "   %-15s %s\n" "备选机房:" "AWS-ap-east-1(香港), AWS-ap-south-1(孟买)"
        printf "   %-15s %s\n" "网络要求:" "公网带宽 ≥ 100Mbps"
        printf "   %-15s %s\n" "预期延迟:" "10-30ms"
        echo
        echo "2. 备选部署方案"
        printf "   %-15s %s\n" "备选供应商:" "Google Cloud, Azure, DigitalOcean"
        printf "   %-15s %s\n" "推荐机房:" "GCP-asia-east2(香港), Azure-eastasia(香港)"
        printf "   %-15s %s\n" "网络要求:" "公网带宽 ≥ 100Mbps"
        printf "   %-15s %s\n" "预期延迟:" "30-50ms"
        echo
        echo "3. 硬件配置建议"
        printf "   %-15s %s\n" "CPU:" "16核心及以上"
        printf "   %-15s %s\n" "内存:" "32GB及以上"
        printf "   %-15s %s\n" "存储:" "1TB NVMe SSD"
        printf "   %-15s %s\n" "操作系统:" "Ubuntu 20.04/22.04 LTS"
        echo
        echo "4. 网络优化建议"
        printf "   %-15s %s\n" "系统优化:" "启用 TCP BBR 拥塞控制"
        printf "   %-15s %s\n" "参数调整:" "优化系统网络参数"
        printf "   %-15s %s\n" "安全配置:" "配置合适的防火墙规则"
        printf "   %-15s %s\n" "端口开放:" "确保 8899-8900 端口可访问"
        echo
        echo "5. 注意事项"
        printf "   %-15s %s\n" "延迟要求:" "建议选择延迟低于 50ms 的节点位置"
        printf "   %-15s %s\n" "供应商选择:" "优先考虑网络稳定性好的供应商"
        printf "   %-15s %s\n" "备份策略:" "建议在多个地区部署备份节点"
        printf "   %-15s %s\n" "监控要求:" "定期监控网络性能"
        echo
        echo "6. 成本估算（月）"
        printf "   %-15s %s\n" "服务器费用:" "\$200-500"
        printf "   %-15s %s\n" "带宽费用:" "\$100-300"
        printf "   %-15s %s\n" "存储费用:" "\$50-150"
        printf "   %-15s %s\n" "总计:" "\$350-950"

        echo
        echo "---"
        printf "%-20s %s\n" "* 延迟测试:" "使用 TCP 连接时间"
        printf "%-20s %s\n" "* 测试端口:" "8899(RPC), 8900(Gossip)"
        printf "%-20s %s\n" "* 报告版本:" "${VERSION}"
        printf "%-20s %s\n" "* 生成时间:" "$(date '+%Y-%m-%d %H:%M:%S')"
        
    } > "${LATEST_REPORT}"
    
    log "SUCCESS" "报告已生成: ${LATEST_REPORT}"
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
        apt-get update -qq && apt-get install -y -qq "${missing[@]}" || {
            log "ERROR" "工具安装失败"
            return 1
        }
        
        # 安装 GeoIP 数据库
        apt-get install -y -qq geoip-database geoip-database-extra
    fi
    return 0
}

# 清理函数
cleanup() {
    rm -f "$LOCK_FILE"
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
    local location_cn=$(get_location_cn "$location")
    
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
    echo -e "位置: ${WHITE}${location_cn} (${location})${NC}"
    echo -e "供应商: ${CYAN}${provider}${NC}"
    echo -e "${GREEN}===================${NC}"
}

# 检查后台任务状态
check_background_task() {
    if [ -f "${BACKGROUND_LOG}" ]; then
        echo -e "\n${GREEN}后台任务状态：${NC}"
        echo -e "${GREEN}===================${NC}"
        
        if grep -q "分析完成" "${BACKGROUND_LOG}"; then
            echo -e "${GREEN}状态: 已完成${NC}"
        else
            echo -e "${YELLOW}状态: 运行中${NC}"
        fi
        
        echo -e "\n最新进度:"
        tail -n 5 "${BACKGROUND_LOG}"
        echo -e "${GREEN}===================${NC}"
    else
        echo -e "\n${YELLOW}没有运行中的后台任务${NC}"
    fi
}

# 主函数
main() {
    # 添加参数的默认值处理
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
    
    while true; do
        show_menu
        read -r choice
        
        case $choice in
            1)  analyze_validators false || {
                    log "ERROR" "分析失败"
                    read -rp "按回车键继续..."
                }
                ;;
            2)  log "INFO" "启动后台分析任务..."
                nohup bash "$0" background > /dev/null 2>&1 &
                log "SUCCESS" "后台任务已启动，使用选项 5 查看进度"
                read -rp "按回车键继续..."
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
            5)  check_background_task
                read -rp "按回车键继续..."
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
        
