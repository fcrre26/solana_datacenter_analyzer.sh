#!/bin/bash

# Solana 验证者节点延迟分析工具
# 版本: v1.3.2
# 功能:
# 1. 分析所有验证者节点延迟（单线程/并发）
# 2. 测试指定IP的延迟
# 3. 生成详细的分析报告
# 4. 后台任务管理
# 5. 配置管理
# 设置严格模式
set -euo pipefail

REPORT_DIR="$HOME/solana_reports"                    # 报告主目录
LATEST_REPORT="${REPORT_DIR}/latest_report.txt"      # 最终分析报告
DETAILED_LOG="${REPORT_DIR}/detailed_analysis.log"   # 详细分析日志（格式化的）

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

# 在颜色定义之后添加
# 确保目录和文件权限正确
setup_directories() {
    mkdir -p "${TEMP_DIR}" "${REPORT_DIR}"
    chmod 755 "${TEMP_DIR}" "${REPORT_DIR}"
    
    # 确保日志文件存在且可写
    touch "${LOG_FILE}" "${BACKGROUND_LOG}"
    chmod 644 "${LOG_FILE}" "${BACKGROUND_LOG}"
}

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

# 修改 get_ip_info 函数
# 获取IP信息
get_ip_info() {
    local ip="$1"
    local max_retries=3
    local retry_count=0
    local provider
    local location
    
    # 清理字符串函数
    clean_string() {
        local str="${1:-}"
        [ -z "$str" ] && echo "Unknown" && return 0
        echo "$str" | tr -dc '[:print:]' | sed 's/["\]/\\&/g' | sed 's/[^a-zA-Z0-9.,_ -]//g' || echo "Unknown"
    }
    
    # 验证 JSON 响应
    validate_json() {
        local json="$1"
        if [ -z "$json" ]; then
            return 1
        fi
        if echo "$json" | jq -e . >/dev/null 2>&1; then
            return 0
        fi
        return 1
    }
    
    # 获取供应商信息
    get_provider_info() {
        local ip="$1"
        local info=""
        
        # 尝试 ip-api.com
        info=$(curl -s -m 3 "http://ip-api.com/json/${ip}?fields=status,message,country,countryCode,region,regionName,city,isp,org,as" 2>/dev/null)
        if validate_json "$info" && [ "$(echo "$info" | jq -r '.status // empty')" = "success" ]; then
            local as=$(echo "$info" | jq -r '.as // empty')
            local isp=$(echo "$info" | jq -r '.isp // empty')
            local org=$(echo "$info" | jq -r '.org // empty')
            
            if [ -n "$as" ] && [ "$as" != "null" ]; then
                echo "$as"
                return 0
            elif [ -n "$isp" ] && [ "$isp" != "null" ]; then
                echo "$isp"
                return 0
            elif [ -n "$org" ] && [ "$org" != "null" ]; then
                echo "$org"
                return 0
            fi
        fi
        
        # 尝试 ipinfo.io
        info=$(curl -s -m 3 "https://ipinfo.io/${ip}/json" 2>/dev/null)
        if validate_json "$info" && [ "$(echo "$info" | jq -r '.bogon // empty')" != "true" ]; then
            local asn=$(echo "$info" | jq -r '.asn // empty')
            local org=$(echo "$info" | jq -r '.org // empty')
            
            if [ -n "$asn" ] && [ "$asn" != "null" ]; then
                echo "$asn"
                return 0
            elif [ -n "$org" ] && [ "$org" != "null" ]; then
                echo "$org"
                return 0
            fi
        fi
        
        # 尝试 ipapi.co
        info=$(curl -s -m 3 "https://ipapi.co/${ip}/json/" 2>/dev/null)
        if validate_json "$info"; then
            local org=$(echo "$info" | jq -r '.org // empty')
            local asn=$(echo "$info" | jq -r '.asn // empty')
            
            if [ -n "$org" ] && [ "$org" != "null" ]; then
                echo "$org"
                return 0
            elif [ -n "$asn" ] && [ "$asn" != "null" ]; then
                echo "$asn"
                return 0
            fi
        fi
        
        echo "Unknown"
        return 0
    }
    
    # 获取位置信息
    get_location_info() {
        local ip="$1"
        local info=""
        
        # 尝试 ip-api.com
        info=$(curl -s -m 3 "http://ip-api.com/json/${ip}?fields=status,message,country,countryCode,region,regionName,city" 2>/dev/null)
        if validate_json "$info" && [ "$(echo "$info" | jq -r '.status // empty')" = "success" ]; then
            local city=$(echo "$info" | jq -r '.city // empty')
            local country=$(echo "$info" | jq -r '.country // empty')
            
            if [ -n "$city" ] && [ "$city" != "null" ] && [ -n "$country" ] && [ "$country" != "null" ]; then
                echo "${city}, ${country}"
                return 0
            elif [ -n "$city" ] && [ "$city" != "null" ]; then
                echo "$city"
                return 0
            elif [ -n "$country" ] && [ "$country" != "null" ]; then
                echo "$country"
                return 0
            fi
        fi
        
        # 尝试 ipinfo.io
        info=$(curl -s -m 3 "https://ipinfo.io/${ip}/json" 2>/dev/null)
        if validate_json "$info" && [ "$(echo "$info" | jq -r '.bogon // empty')" != "true" ]; then
            local city=$(echo "$info" | jq -r '.city // empty')
            local region=$(echo "$info" | jq -r '.region // empty')
            local country=$(echo "$info" | jq -r '.country // empty')
            
            if [ -n "$city" ] && [ "$city" != "null" ] && [ -n "$country" ] && [ "$country" != "null" ]; then
                echo "${city}, ${country}"
                return 0
            elif [ -n "$city" ] && [ "$city" != "null" ]; then
                echo "$city"
                return 0
            elif [ -n "$country" ] && [ "$country" != "null" ]; then
                echo "$country"
                return 0
            fi
        fi
        
        echo "Unknown"
        return 0
    }
    
    # 获取供应商信息
    provider=$(get_provider_info "$ip")
    provider=$(clean_string "${provider:-Unknown}")
    
    # 获取位置信息
    location=$(get_location_info "$ip")
    location=$(clean_string "${location:-Unknown}")
    
    # 返回结果
    printf '{"ip":"%s","org":"%s","location":"%s"}' \
          "$ip" \
          "${provider}" \
          "${location}"
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
    local provider="$1"   # 供应商名称
    local location="$2"   # 地理位置信息
    
    # 初始化返回值
    local cloud_provider=""
    local region_code=""
    local datacenter=""
    
    # AWS
    if [[ "$provider" =~ Amazon|AWS|AMAZON|EC2|AMAZONAWS ]]; then
        cloud_provider="AWS"
        case "$location" in
            # 亚太地区
            *"Tokyo"*|*"Japan"*)          region_code="ap-northeast-1"; datacenter="东京数据中心" ;;
            *"Seoul"*|*"Korea"*)          region_code="ap-northeast-2"; datacenter="首尔数据中心" ;;
            *"Osaka"*)                    region_code="ap-northeast-3"; datacenter="大阪数据中心" ;;
            *"Singapore"*)                region_code="ap-southeast-1"; datacenter="新加坡数据中心" ;;
            *"Sydney"*|*"Australia"*)     region_code="ap-southeast-2"; datacenter="悉尼数据中心" ;;
            *"Mumbai"*|*"India"*)         region_code="ap-south-1"; datacenter="孟买数据中心" ;;
            *"Hong Kong"*)                region_code="ap-east-1"; datacenter="香港数据中心" ;;
            *"Jakarta"*|*"Indonesia"*)    region_code="ap-southeast-3"; datacenter="雅加达数据中心" ;;
            
            # 美洲地区
            *"N. Virginia"*|*"Virginia"*) region_code="us-east-1"; datacenter="弗吉尼亚数据中心" ;;
            *"Ohio"*)                     region_code="us-east-2"; datacenter="俄亥俄数据中心" ;;
            *"N. California"*)            region_code="us-west-1"; datacenter="加利福尼亚数据中心" ;;
            *"Oregon"*)                   region_code="us-west-2"; datacenter="俄勒冈数据中心" ;;
            *"São Paulo"*|*"Brazil"*)     region_code="sa-east-1"; datacenter="圣保罗数据中心" ;;
            
            # 欧洲地区
            *"Ireland"*)                  region_code="eu-west-1"; datacenter="爱尔兰数据中心" ;;
            *"London"*|*"England"*)       region_code="eu-west-2"; datacenter="伦敦数据中心" ;;
            *"Paris"*|*"France"*)         region_code="eu-west-3"; datacenter="巴黎数据中心" ;;
            *"Frankfurt"*|*"Germany"*)    region_code="eu-central-1"; datacenter="法兰克福数据中心" ;;
            *"Stockholm"*|*"Sweden"*)     region_code="eu-north-1"; datacenter="斯德哥尔摩数据中心" ;;
            *"Milan"*|*"Italy"*)          region_code="eu-south-1"; datacenter="米兰数据中心" ;;
            
            # 中东和非洲
            *"Bahrain"*)                  region_code="me-south-1"; datacenter="巴林数据中心" ;;
            *"Cape Town"*|*"Africa"*)     region_code="af-south-1"; datacenter="开普敦数据中心" ;;
            
            # 默认情况
            *) datacenter="$location" ;;
        esac

            # Google Cloud
    elif [[ "$provider" =~ Google|GCP|GOOGLE ]]; then
        cloud_provider="Google Cloud"
        case "$location" in
            # 亚太地区
            *"Tokyo"*|*"Japan"*)          region_code="asia-northeast1"; datacenter="东京-大森机房" ;;
            *"Osaka"*)                    region_code="asia-northeast2"; datacenter="大阪机房" ;;
            *"Seoul"*|*"Korea"*)          region_code="asia-northeast3"; datacenter="首尔机房" ;;
            *"Hong Kong"*)                region_code="asia-east2"; datacenter="香港机房" ;;
            *"Taiwan"*)                   region_code="asia-east1"; datacenter="台湾机房" ;;
            *"Singapore"*)                region_code="asia-southeast1"; datacenter="新加坡机房" ;;
            *"Jakarta"*|*"Indonesia"*)    region_code="asia-southeast2"; datacenter="雅加达机房" ;;
            *"Sydney"*|*"Australia"*)     region_code="australia-southeast1"; datacenter="悉尼机房" ;;
            *"Melbourne"*)                region_code="australia-southeast2"; datacenter="墨尔本机房" ;;
            *"Mumbai"*|*"India"*)         region_code="asia-south1"; datacenter="孟买机房" ;;
            *"Delhi"*)                    region_code="asia-south2"; datacenter="德里机房" ;;
            
            # 美洲地区
            *"Iowa"*)                     region_code="us-central1"; datacenter="爱荷华机房" ;;
            *"South Carolina"*)           region_code="us-east1"; datacenter="南卡罗来纳机房" ;;
            *"N. Virginia"*)              region_code="us-east4"; datacenter="弗吉尼亚机房" ;;
            *"Oregon"*)                   region_code="us-west1"; datacenter="俄勒冈机房" ;;
            *"Los Angeles"*)              region_code="us-west2"; datacenter="洛杉矶机房" ;;
            *"Salt Lake City"*)           region_code="us-west3"; datacenter="盐湖城机房" ;;
            *"Las Vegas"*)                region_code="us-west4"; datacenter="拉斯维加斯机房" ;;
            *"São Paulo"*)                region_code="southamerica-east1"; datacenter="圣保罗机房" ;;
            *"Santiago"*)                 region_code="southamerica-west1"; datacenter="圣地亚哥机房" ;;
            
            # 欧洲地区
            *"Belgium"*)                  region_code="europe-west1"; datacenter="比利时机房" ;;
            *"London"*)                   region_code="europe-west2"; datacenter="伦敦机房" ;;
            *"Frankfurt"*)                region_code="europe-west3"; datacenter="法兰克福机房" ;;
            *"Netherlands"*)              region_code="europe-west4"; datacenter="荷兰机房" ;;
            *"Zürich"*)                   region_code="europe-west6"; datacenter="苏黎世机房" ;;
            *"Milan"*)                    region_code="europe-west8"; datacenter="米兰机房" ;;
            *"Paris"*)                    region_code="europe-west9"; datacenter="巴黎机房" ;;
            *"Warsaw"*)                   region_code="europe-central2"; datacenter="华沙机房" ;;
            *"Finland"*)                  region_code="europe-north1"; datacenter="芬兰机房" ;;
            
            # 默认情况
            *) datacenter="$location" ;;
        esac
        
    # 阿里云
    elif [[ "$provider" =~ Alibaba|Aliyun|阿里|ALIBABA ]]; then
        cloud_provider="阿里云"
        case "$location" in
            # 中国地区
            *"Hangzhou"*|*"杭州"*)        region_code="cn-hangzhou"; datacenter="杭州可用区" ;;
            *"Shanghai"*|*"上海"*)        region_code="cn-shanghai"; datacenter="上海可用区" ;;
            *"Beijing"*|*"北京"*)         region_code="cn-beijing"; datacenter="北京可用区" ;;
            *"Shenzhen"*|*"深圳"*)        region_code="cn-shenzhen"; datacenter="深圳可用区" ;;
            *"Heyuan"*|*"河源"*)          region_code="cn-heyuan"; datacenter="河源可用区" ;;
            *"Guangzhou"*|*"广州"*)       region_code="cn-guangzhou"; datacenter="广州可用区" ;;
            *"Chengdu"*|*"成都"*)         region_code="cn-chengdu"; datacenter="成都可用区" ;;
            *"Qingdao"*|*"青岛"*)         region_code="cn-qingdao"; datacenter="青岛可用区" ;;
            *"Hohhot"*|*"呼和浩特"*)      region_code="cn-huhehaote"; datacenter="呼和浩特可用区" ;;
            *"Ulanqab"*|*"乌兰察布"*)     region_code="cn-wulanchabu"; datacenter="乌兰察布可用区" ;;
            *"Zhangjiakou"*|*"张家口"*)   region_code="cn-zhangjiakou"; datacenter="张家口可用区" ;;
            
            # 中国香港及国际地区
            *"Hong Kong"*|*"香港"*)       region_code="cn-hongkong"; datacenter="香港可用区" ;;
            *"Singapore"*|*"新加坡"*)     region_code="ap-southeast-1"; datacenter="新加坡可用区" ;;
            *"Sydney"*|*"悉尼"*)          region_code="ap-southeast-2"; datacenter="悉尼可用区" ;;
            *"Kuala Lumpur"*|*"吉隆坡"*)  region_code="ap-southeast-3"; datacenter="吉隆坡可用区" ;;
            *"Jakarta"*|*"雅加达"*)       region_code="ap-southeast-5"; datacenter="雅加达可用区" ;;
            *"Mumbai"*|*"孟买"*)          region_code="ap-south-1";

                        datacenter="孟买可用区" ;;
            *"Tokyo"*|*"东京"*)           region_code="ap-northeast-1"; datacenter="东京可用区" ;;
            *"Seoul"*|*"首尔"*)           region_code="ap-northeast-2"; datacenter="首尔可用区" ;;
            
            # 默认情况
            *) datacenter="$location" ;;
        esac
        
    # 腾讯云
    elif [[ "$provider" =~ Tencent|TENCENT|腾讯|QCloud ]]; then
        cloud_provider="腾讯云"
        case "$location" in
            # 中国地区
            *"Beijing"*|*"北京"*)         region_code="ap-beijing"; datacenter="北京数据中心" ;;
            *"Shanghai"*|*"上海"*)        region_code="ap-shanghai"; datacenter="上海数据中心" ;;
            *"Guangzhou"*|*"广州"*)       region_code="ap-guangzhou"; datacenter="广州数据中心" ;;
            *"Chengdu"*|*"成都"*)         region_code="ap-chengdu"; datacenter="成都数据中心" ;;
            *"Chongqing"*|*"重庆"*)       region_code="ap-chongqing"; datacenter="重庆数据中心" ;;
            *"Nanjing"*|*"南京"*)         region_code="ap-nanjing"; datacenter="南京数据中心" ;;
            
            # 中国香港及国际地区
            *"Hong Kong"*|*"香港"*)       region_code="ap-hongkong"; datacenter="香港数据中心" ;;
            *"Singapore"*|*"新加坡"*)     region_code="ap-singapore"; datacenter="新加坡数据中心" ;;
            *"Bangkok"*|*"曼谷"*)         region_code="ap-bangkok"; datacenter="曼谷数据中心" ;;
            *"Mumbai"*|*"孟买"*)          region_code="ap-mumbai"; datacenter="孟买数据中心" ;;
            *"Seoul"*|*"首尔"*)           region_code="ap-seoul"; datacenter="首尔数据中心" ;;
            *"Tokyo"*|*"东京"*)           region_code="ap-tokyo"; datacenter="东京数据中心" ;;
            *"Silicon Valley"*)           region_code="na-siliconvalley"; datacenter="硅谷数据中心" ;;
            *"Virginia"*)                 region_code="na-ashburn"; datacenter="弗吉尼亚数据中心" ;;
            *"Toronto"*)                  region_code="na-toronto"; datacenter="多伦多数据中心" ;;
            *"Frankfurt"*|*"法兰克福"*)    region_code="eu-frankfurt"; datacenter="法兰克福数据中心" ;;
            
            # 默认情况
            *) datacenter="$location" ;;
        esac
        
    # Azure
    elif [[ "$provider" =~ Azure|Microsoft|AZURE|MICROSOFT ]]; then
        cloud_provider="Azure"
        case "$location" in
            # 亚太地区
            *"Hong Kong"*|*"香港"*)       region_code="eastasia"; datacenter="香港数据中心" ;;
            *"Singapore"*|*"新加坡"*)     region_code="southeastasia"; datacenter="新加坡数据中心" ;;
            *"Tokyo"*|*"东京"*)           region_code="japaneast"; datacenter="东京数据中心" ;;
            *"Osaka"*|*"大阪"*)           region_code="japanwest"; datacenter="大阪数据中心" ;;
            *"Seoul"*|*"首尔"*)           region_code="koreacentral"; datacenter="首尔数据中心" ;;
            *"Busan"*|*"釜山"*)           region_code="koreasouth"; datacenter="釜山数据中心" ;;
            
            # 默认情况
            *) datacenter="$location" ;;
        esac
        
    # Digital Ocean
    elif [[ "$provider" =~ DigitalOcean|DIGITALOCEAN ]]; then
        cloud_provider="DigitalOcean"
        case "$location" in
            *"New York"*)                 region_code="nyc1"; datacenter="纽约 NYC1" ;;
            *"Amsterdam"*)                region_code="ams1"; datacenter="阿姆斯特丹 AMS1" ;;
            *"San Francisco"*)            region_code="sfo1"; datacenter="旧金山 SFO1" ;;
            *"Singapore"*)                region_code="sgp1"; datacenter="新加坡 SGP1" ;;
            *"London"*)                   region_code="lon1"; datacenter="伦敦 LON1" ;;
            *"Frankfurt"*)                region_code="fra1"; datacenter="法兰克福 FRA1" ;;
            *"Toronto"*)                  region_code="tor1"; datacenter="多伦多 TOR1" ;;
            *"Bangalore"*)                region_code="blr1"; datacenter="班加罗尔 BLR1" ;;
            
            # 默认情况
            *) datacenter="$location" ;;
        esac

            # Vultr
    elif [[ "$provider" =~ Vultr|VULTR ]]; then
        cloud_provider="Vultr"
        case "$location" in
            *"Tokyo"*)                    region_code="nrt"; datacenter="东京 NRT" ;;
            *"Singapore"*)                region_code="sgp"; datacenter="新加坡 SGP" ;;
            *"Seoul"*)                    region_code="icn"; datacenter="首尔 ICN" ;;
            *"Delhi"*)                    region_code="del"; datacenter="德里 DEL" ;;
            *"Sydney"*)                   region_code="syd"; datacenter="悉尼 SYD" ;;
            *"Frankfurt"*)                region_code="fra"; datacenter="法兰克福 FRA" ;;
            *"Paris"*)                    region_code="cdg"; datacenter="巴黎 CDG" ;;
            *"Amsterdam"*)                region_code="ams"; datacenter="阿姆斯特丹 AMS" ;;
            *"London"*)                   region_code="lhr"; datacenter="伦敦 LHR" ;;
            *"New Jersey"*)               region_code="ewr"; datacenter="新泽西 EWR" ;;
            *"Chicago"*)                  region_code="ord"; datacenter="芝加哥 ORD" ;;
            *"Atlanta"*)                  region_code="atl"; datacenter="亚特兰大 ATL" ;;
            *"Miami"*)                    region_code="mia"; datacenter="迈阿密 MIA" ;;
            *"Dallas"*)                   region_code="dfw"; datacenter="达拉斯 DFW" ;;
            *"Silicon Valley"*)           region_code="sjo"; datacenter="硅谷 SJO" ;;
            *"Los Angeles"*)              region_code="lax"; datacenter="洛杉矶 LAX" ;;
            *"Seattle"*)                  region_code="sea"; datacenter="西雅图 SEA" ;;
            *"Mexico City"*)              region_code="mex"; datacenter="墨西哥城 MEX" ;;
            *"São Paulo"*)                region_code="sao"; datacenter="圣保罗 SAO" ;;
            *"Melbourne"*)                region_code="mel"; datacenter="墨尔本 MEL" ;;
            *"Warsaw"*)                   region_code="waw"; datacenter="华沙 WAW" ;;
            *"Stockholm"*)                region_code="sto"; datacenter="斯德哥尔摩 STO" ;;
            *"Johannesburg"*)             region_code="jnb"; datacenter="约翰内斯堡 JNB" ;;
            
            # 默认情况
            *) datacenter="$location" ;;
        esac
        
    # Linode/Akamai
    elif [[ "$provider" =~ Linode|LINODE|Akamai|AKAMAI ]]; then
        cloud_provider="Linode"
        case "$location" in
            *"Tokyo"*)                    region_code="ap-northeast"; datacenter="东京数据中心" ;;
            *"Singapore"*)                region_code="ap-south"; datacenter="新加坡数据中心" ;;
            *"Sydney"*)                   region_code="ap-southeast"; datacenter="悉尼数据中心" ;;
            *"Mumbai"*)                   region_code="ap-west"; datacenter="孟买数据中心" ;;
            *"Toronto"*)                  region_code="ca-central"; datacenter="多伦多数据中心" ;;
            *"Frankfurt"*)                region_code="eu-central"; datacenter="法兰克福数据中心" ;;
            *"London"*)                   region_code="eu-west"; datacenter="伦敦数据中心" ;;
            *"Newark"*)                   region_code="us-east"; datacenter="纽瓦克数据中心" ;;
            *"Atlanta"*)                  region_code="us-southeast"; datacenter="亚特兰大数据中心" ;;
            *"Dallas"*)                   region_code="us-central"; datacenter="达拉斯数据中心" ;;
            *"Los Angeles"*)              region_code="us-west"; datacenter="洛杉矶数据中心" ;;
            
            # 默认情况
            *) datacenter="$location" ;;
        esac
        
    # 如果都不匹配，使用原始信息
    else
        cloud_provider="$provider"
        datacenter="$location"
        region_code="unknown"
    fi
    
    # 返回结果，用 | 分隔三个值
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

# 更新进度显示函数
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
    
    # 保存格式化的分析记录
    printf "%s | %-15s | %-8s | %-15s | %-30s | %d/%d\n" \
        "$(date '+%H:%M:%S')" \
        "$ip" \
        "$latency_display" \
        "${provider:0:15}" \
        "${location:0:30}" \
        "$current" "$total" >> "${DETAILED_LOG}"
    
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
        
        # 在详细日志中也添加表头
        echo "----------------------------------------" >> "${DETAILED_LOG}"
        printf "%-10s | %-15s | %-8s | %-15s | %-30s | %-15s\n" \
            "时间" "IP地址" "延迟" "供应商" "机房位置" "进度" >> "${DETAILED_LOG}"
        echo "========================================" >> "${DETAILED_LOG}"
    fi
    
    # 显示当前行
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

# 生成报告
generate_report() {
    log "INFO" "正在生成最终报告..."
    
    local temp_report="${TEMP_DIR}/temp_report.txt"
    
    # 基础统计数据计算
    local total_nodes=$(wc -l < "${RESULTS_FILE}")
    local valid_nodes=$(awk -F'|' '$4!=999 { count++ } END { print count }' "${RESULTS_FILE}")
    local avg_latency=$(awk -F'|' '$4!=999 { sum+=$4; count++ } END { if(count>0) printf "%.3f", sum/count }' "${RESULTS_FILE}")
    
    # 获取最大供应商及其节点数
    local max_provider_info=$(awk -F'|' '{
        provider=$2
        count[provider]++
    } 
    END {
        max_count = 0
        max_provider = ""
        for (p in count) {
            if (count[p] > max_count) {
                max_count = count[p]
                max_provider = p
            }
        }
        printf "%s|%d", max_provider, max_count
    }' "${RESULTS_FILE}")
    
    local max_provider=$(echo "$max_provider_info" | cut -d'|' -f1)
    local max_provider_count=$(echo "$max_provider_info" | cut -d'|' -f2)
    
    # 获取该供应商最多的机房及其节点数
    local max_dc_info=$(awk -F'|' -v provider="$max_provider" '{
        if ($2 == provider) {
            dc=$3
            count[dc]++
            regions[dc]=$5
            latencies[dc]+=$4
            if ($4 != "999") valid[dc]++
        }
    } 
    END {
        max_count = 0
        max_dc = ""
        max_region = ""
        for (dc in count) {
            if (count[dc] > max_count) {
                max_count = count[dc]
                max_dc = dc
                max_region = regions[dc]
            }
        }
        avg_latency = (valid[max_dc] > 0) ? latencies[max_dc]/valid[max_dc] : 999
        printf "%s|%d|%s|%.2f", max_dc, max_count, max_region, avg_latency
    }' "${RESULTS_FILE}")
    
    local max_dc=$(echo "$max_dc_info" | cut -d'|' -f1)
    local max_dc_count=$(echo "$max_dc_info" | cut -d'|' -f2)
    local max_dc_region=$(echo "$max_dc_info" | cut -d'|' -f3)
    local max_dc_latency=$(echo "$max_dc_info" | cut -d'|' -f4)
    
    {
        echo -e "${CYAN}================================================================${NC}"
        echo -e "${GREEN}                Solana 验证者节点分布分析报告${NC}"
        echo -e "${CYAN}================================================================${NC}\n"
        
        # 1. 供应商分布统计
        echo -e "${WHITE}【供应商分布统计】${NC}"
        echo -e "${CYAN}----------------------------------------------------------------${NC}"
        echo -e "主导供应商: ${GREEN}${max_provider}${NC}"
        echo -e "节点数量: ${GREEN}${max_provider_count}${NC} (占比: ${GREEN}$(printf "%.1f" $((max_provider_count * 100 / total_nodes)))%${NC})"
        echo -e "\n供应商排名 (Top 10):"
        echo -e "${CYAN}----------------------------------------------------------------${NC}"
        printf "%-25s %-10s %-15s %-15s %-12s\n" "供应商" "节点数" "占比" "平均延迟" "可用率"
        echo -e "${CYAN}----------------------------------------------------------------${NC}"
        
        awk -F'|' 'BEGIN {OFS="|"}
        {
            provider=$2
            latency=$4
            total[provider]++
            if (latency != "999") {
                valid[provider]++
                sum[provider]+=latency
            }
        }
        END {
            for (p in total) {
                if (valid[p] > 0) {
                    printf "%-25s %-10d %-15.1f%% %-15.2f %-12.1f%%\n",
                        substr(p,1,25),
                        total[p],
                        total[p]*100/NR,
                        sum[p]/valid[p],
                        valid[p]*100/total[p]
                }
            }
        }' "${RESULTS_FILE}" | sort -t' ' -k2 -nr | head -10
        
        # 2. 机房分布统计
        echo -e "\n${WHITE}【机房分布统计】${NC}"
        echo -e "${CYAN}----------------------------------------------------------------${NC}"
        echo -e "主要机房: ${GREEN}${max_dc}${NC}"
        echo -e "所属供应商: ${GREEN}${max_provider}${NC}"
        echo -e "区域: ${GREEN}${max_dc_region}${NC}"
        echo -e "节点数量: ${GREEN}${max_dc_count}${NC} (占比: ${GREEN}$(printf "%.1f" $((max_dc_count * 100 / max_provider_count)))%${NC})"
        echo -e "平均延迟: ${GREEN}${max_dc_latency}ms${NC}"
        
        echo -e "\n机房排名 (Top 10):"
        echo -e "${CYAN}----------------------------------------------------------------${NC}"
        printf "%-30s %-10s %-15s %-15s %-12s\n" "机房位置" "节点数" "占比" "平均延迟" "区域"
        echo -e "${CYAN}----------------------------------------------------------------${NC}"
        
        awk -F'|' 'BEGIN {OFS="|"}
        {
            dc=$3
            provider=$2
            latency=$4
            region=$5
            total[dc]++
            regions[dc]=region
            providers[dc]=provider
            if (latency != "999") {
                valid[dc]++
                sum[dc]+=latency
            }
        }
        END {
            for (d in total) {
                if (valid[d] > 0) {
                    printf "%-30s %-10d %-15.1f%% %-15.2f %-12s\n",
                        substr(d,1,30),
                        total[d],
                        total[d]*100/NR,
                        sum[d]/valid[d],
                        regions[d]
                }
            }
        }' "${RESULTS_FILE}" | sort -t' ' -k2 -nr | head -10
        
        # 3. 部署建议
        echo -e "\n${WHITE}【最优部署建议】${NC}"
        echo -e "${CYAN}----------------------------------------------------------------${NC}"
        echo -e "${GREEN}1. 推荐部署方案：${NC}"
        echo -e "   主要部署点："
        echo -e "   - 供应商: ${GREEN}${max_provider}${NC}"
        echo -e "   - 机房: ${GREEN}${max_dc}${NC}"
        echo -e "   - 区域: ${GREEN}${max_dc_region}${NC}"
        echo -e "   - 平均延迟: ${GREEN}${max_dc_latency}ms${NC}"
        
        # 获取备选部署点（不同供应商的低延迟节点）
        echo -e "\n   备选部署点："
        awk -F'|' -v main_provider="$max_provider" '$2!=main_provider && $4!=999 {
            dc=$3
            provider=$2
            latency=$4
            region=$5
            count[dc]++
            providers[dc]=provider
            regions[dc]=region
            if (latency < min[dc] || min[dc] == "") min[dc]=latency
            sum[dc]+=latency
        }
        END {
            for (d in count) {
                if (count[d] >= 3 && sum[d]/count[d] < 100) {
                    printf "   - %s\n     供应商: %s\n     区域: %s\n     平均延迟: %.2fms\n     节点数: %d\n\n",
                        d,
                        providers[d],
                        regions[d],
                        sum[d]/count[d],
                        count[d]
                }
            }
        }' "${RESULTS_FILE}" | sort -t':' -k2 -n | head -3
        
        echo -e "${YELLOW}2. 部署策略建议：${NC}"
        echo "   - 主要节点部署在 ${max_provider} 的 ${max_dc}"
        echo "   - 建议选择2-3个备选机房作为容灾节点"
        echo "   - 优先选择节点数量多、延迟低的机房"
        echo "   - 建议跨供应商部署以提高可用性"
        echo "   - 定期进行延迟测试和性能监控"
        
    } | tee "$temp_report"
    
    # 保存无颜色版本
    sed 's/\x1b\[[0-9;]*m//g' "$temp_report" > "${LATEST_REPORT}"
    rm -f "$temp_report"
    
    log "SUCCESS" "最终报告已生成并保存至: ${LATEST_REPORT}"
}

# 测试单个IP
test_single_ip() {
    local ip="$1"
    
    echo -e "\n${GREEN}测试 IP: ${CYAN}$ip${NC}"
    echo -e "${GREEN}===================${NC}"
    
    local latency=$(test_network_quality "$ip")
    local ip_info=$(get_ip_info "$ip")
    local provider_info=$(identify_provider "$(echo "$ip_info" | jq -r '.org // .isp // "Unknown"')" "$(echo "$ip_info" | jq -r '.city // "Unknown"'), $(echo "$ip_info" | jq -r '.country_name // .country // "Unknown"')")
    
    local cloud_provider=$(echo "$provider_info" | cut -d'|' -f1)
    local region_code=$(echo "$provider_info" | cut -d'|' -f2)
    local datacenter=$(echo "$provider_info" | cut -d'|' -f3)
    
    # 显示结果
    if [[ "$latency" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        if [ "$(echo "$latency > 100" | bc -l)" -eq 1 ]; then
            echo -e "延迟: ${YELLOW}${latency}ms${NC}"
        else
            echo -e "延迟: ${GREEN}${latency}ms${NC}"
        fi
    else
        echo -e "延迟: ${RED}超时${NC}"
    fi
    
    echo -e "供应商: ${WHITE}${cloud_provider}${NC}"
    echo -e "数据中心: ${WHITE}${datacenter}${NC}"
    echo -e "区域代码: ${WHITE}${region_code}${NC}"
    echo -e "${GREEN}===================${NC}"
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
# 启动后台分析任务
start_background_analysis() {
    if [ -f "${TEMP_DIR}/background.pid" ]; then
        if kill -0 "$(cat "${TEMP_DIR}/background.pid")" 2>/dev/null; then
            log "ERROR" "已有后台任务在运行"
            return 1
        else
            rm -f "${TEMP_DIR}/background.pid"
        fi
    fi

    log "INFO" "启动后台分析任务..."
    
    # 获取脚本的完整路径
    SCRIPT_PATH=$(readlink -f "$0")
    
    # 确保目录存在
    mkdir -p "${TEMP_DIR}"
    mkdir -p "$(dirname "${BACKGROUND_LOG}")"
    
    # 记录开始时间
    date +%s > "${TEMP_DIR}/start_time"
    
    # 使用 nohup 启动后台进程
    nohup bash "${SCRIPT_PATH}" background > "${BACKGROUND_LOG}" 2>&1 &
    local pid=$!
    
    # 等待确保进程启动
    sleep 2
    
    if kill -0 $pid 2>/dev/null; then
        echo $pid > "${TEMP_DIR}/background.pid"
        chmod 644 "${TEMP_DIR}/background.pid"
        log "SUCCESS" "后台任务已启动，进程ID: $pid"
        log "INFO" "可以使用选项 2 监控任务进度"
        return 0
    else
        log "ERROR" "后台任务启动失败"
        rm -f "${TEMP_DIR}/background.pid" "${BACKGROUND_LOG}"
        return 1
    fi
}

# 监控后台任务进度
monitor_background_progress() {
    if [ ! -f "${BACKGROUND_LOG}" ]; then
        log "WARN" "没有运行中的后台任务"
        return 1
    fi
    
    clear
    echo -e "\n${GREEN}正在监控后台任务 (按 Ctrl+C 退出监控)${NC}"
    echo -e "${GREEN}===================${NC}\n"
    
    # 使用 trap 捕获 Ctrl+C
    trap 'echo -e "\n${GREEN}退出监控${NC}"; return 0' INT
    
    tail -f "${BACKGROUND_LOG}"
    
    # 重置 trap
    trap - INT
}

# 停止后台任务
stop_background_task() {
    if [ ! -f "${TEMP_DIR}/background.pid" ]; then
        log "WARN" "没有运行中的后台任务"
        return 1
    fi
    
    local pid=$(cat "${TEMP_DIR}/background.pid")
    if kill -0 "$pid" 2>/dev/null; then
        kill "$pid"
        sleep 1
        
        # 确保进程已经停止
        if kill -0 "$pid" 2>/dev/null; then
            kill -9 "$pid"
        fi
        
        rm -f "${TEMP_DIR}/background.pid" "${BACKGROUND_LOG}"
        log "SUCCESS" "后台任务已停止"
        return 0
    else
        log "WARN" "后台任务已不存在"
        rm -f "${TEMP_DIR}/background.pid" "${BACKGROUND_LOG}"
        return 1
    fi
}

# 查看后台任务状态
check_background_status() {
    if [ ! -f "${TEMP_DIR}/background.pid" ]; then
        log "INFO" "没有运行中的后台任务"
        return 1
    fi
    
    local pid=$(cat "${TEMP_DIR}/background.pid")
    if kill -0 "$pid" 2>/dev/null; then
        log "INFO" "后台任务正在运行 (PID: $pid)"
        
        if [ -f "${PROGRESS_FILE}" ]; then
            local progress=$(cat "${PROGRESS_FILE}")
            log "INFO" "当前进度: $progress"
        fi
        
        if [ -f "${TEMP_DIR}/start_time" ]; then
            local start_time=$(cat "${TEMP_DIR}/start_time")
            local current_time=$(date +%s)
            local runtime=$((current_time - start_time))
            log "INFO" "运行时间: $((runtime / 3600))小时$((runtime % 3600 / 60))分钟$((runtime % 60))秒"
        fi
        
        if [ -f "${BACKGROUND_LOG}" ]; then
            echo -e "\n最新日志:"
            tail -n 5 "${BACKGROUND_LOG}"
        fi
        return 0
    else
        log "WARN" "后台任务已结束"
        rm -f "${TEMP_DIR}/background.pid"
        return 1
    fi
}

# 查看最新分析报告
view_latest_report() {
    if [ -f "${LATEST_REPORT}" ]; then
        clear
        cat "${LATEST_REPORT}"
        return 0
    else
        log "ERROR" "未找到分析报告"
        return 1
    fi
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
            1)  start_background_analysis ;;
            2)  monitor_background_progress ;;
            3)  stop_background_task ;;
            4)  check_background_status ;;
            5)  view_latest_report ;;
            0)  break ;;
            *)  log "ERROR" "无效选择"
                sleep 1
                ;;
        esac
        
        [ "$choice" != "2" ] && read -rp "按回车键继续..."
    done
}

# 配置菜单
show_config_menu() {
    while true; do
        clear
        echo -e "${GREEN}配置设置${NC}"
        echo "==================="
        echo -e "1. 修改并发数 (当前: ${MAX_CONCURRENT_JOBS:-10})"
        echo -e "2. 修改超时时间 (当前: ${TIMEOUT_SECONDS:-2}秒)"
        echo -e "3. 修改重试次数 (当前: ${RETRIES:-2}次)"
        echo -e "4. 修改测试端口 (当前: ${TEST_PORTS[*]:-8899 8900 8001 8000})"
        echo -e "5. 重置为默认配置"
        echo -e "0. 返回主菜单"
        echo
        echo -ne "请选择 [0-5]: "
        read -r choice

        case $choice in
            1)  echo -ne "请输入新的并发数 [1-200]: "
                read -r new_jobs
                if [[ "$new_jobs" =~ ^[1-9][0-9]*$ ]] && [ "$new_jobs" -ge 1 ] && [ "$new_jobs" -le 200 ]; then
                    sed -i "s/MAX_CONCURRENT_JOBS=.*/MAX_CONCURRENT_JOBS=$new_jobs/" "$CONFIG_FILE"
                    log "SUCCESS" "并发数已更新为: $new_jobs"
                else
                    log "ERROR" "无效的并发数，请输入1-200之间的数字"
                fi
                ;;
            2)  echo -ne "请输入新的超时时间 (秒) [1-10]: "
                read -r new_timeout
                if [[ "$new_timeout" =~ ^[1-9][0]?$ ]]; then
                    sed -i "s/TIMEOUT_SECONDS=.*/TIMEOUT_SECONDS=$new_timeout/" "$CONFIG_FILE"
                    log "SUCCESS" "超时时间已更新为: ${new_timeout}秒"
                else
                    log "ERROR" "无效的超时时间"
                fi
                ;;
            3)  echo -ne "请输入新的重试次数 [1-5]: "
                read -r new_retries
                if [[ "$new_retries" =~ ^[1-5]$ ]]; then
                    sed -i "s/RETRIES=.*/RETRIES=$new_retries/" "$CONFIG_FILE"
                    log "SUCCESS" "重试次数已更新为: $new_retries"
                else
                    log "ERROR" "无效的重试次数"
                fi
                ;;
            4)  echo -ne "请输入测试端口 (空格分隔): "
                read -r new_ports
                if [[ "$new_ports" =~ ^[0-9\ ]+$ ]]; then
                    sed -i "s/TEST_PORTS=.*/TEST_PORTS=(${new_ports})/" "$CONFIG_FILE"
                    log "SUCCESS" "测试端口已更新为: $new_ports"
                else
                    log "ERROR" "无效的端口格式"
                fi
                ;;
            5)  create_default_config
                log "SUCCESS" "配置已重置为默认值"
                ;;
            0)  break ;;
            *)  log "ERROR" "无效选择"
                ;;
        esac
        read -rp "按回车键继续..."
    done
    
    # 重新加载配置
    load_config
}
    
    # 重新加载配置
    load_config
}


# 主函数
main() {
    local cmd="${1:-}"
    
    if [ "$EUID" -ne 0 ]; then 
        log "ERROR" "请使用root权限运行此脚本"
        exit 1
    fi
    
    # 添加这一行
    setup_directories
    
    if [ "$cmd" = "background" ]; then
        BACKGROUND_MODE=true
        analyze_validators true true
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
            1)  analyze_validators false false || {
                    log "ERROR" "分析失败"
                    read -rp "按回车键继续..."
                }
                ;;
            2)  analyze_validators false true || {
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
        
