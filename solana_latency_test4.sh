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

# API 配置
API_CONFIG_FILE="${REPORT_DIR}/api_keys.conf"

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

# 确保目录和文件权限正确
setup_directories() {
    # 创建所有必要的目录
    mkdir -p "${TEMP_DIR}" \
             "${REPORT_DIR}" \
             "${IP_DB_DIR}" \
             "${IP_DB_CACHE_DIR}" \
             "${ASN_DB_DIR}"
    
    # 设置目录权限
    chmod 755 "${TEMP_DIR}" \
             "${REPORT_DIR}" \
             "${IP_DB_DIR}" \
             "${IP_DB_CACHE_DIR}" \
             "${ASN_DB_DIR}"
    
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
ASN_DB_DIR="${REPORT_DIR}/asn_db"
ASN_DB_FILE="${ASN_DB_DIR}/asn.mmdb"
ASN_DB_VERSION_FILE="${ASN_DB_DIR}/version.txt"
IP_DB_DIR="${REPORT_DIR}/ip_db"
IP_DB_CACHE_DIR="${IP_DB_DIR}/cache"

# API 配置文件路径（如果还没有的话）
API_CONFIG_FILE="${REPORT_DIR}/api_keys.conf"


# 创建必要的目录
mkdir -p "${TEMP_DIR}" "${REPORT_DIR}"

# 更新进度显示函数
update_progress() {
    local current="$1"    # 当前处理的节点数
    local total="$2"      # 总节点数
    local ip="$3"         # 当前处理的IP
    local latency="$4"    # 延迟值
    local location="$5"   # 位置信息
    local provider="$6"   # 供应商信息
    
    # 保存进度到文件
    echo "${current}/${total}" > "${PROGRESS_FILE}"
    
    # 计算进度百分比和时间
    local progress=$((current * 100 / total))
    local elapsed_time=$(($(date +%s) - ${START_TIME}))
    local time_per_item=$((elapsed_time / (current > 0 ? current : 1)))
    local remaining_items=$((total - current))
    local eta=$((time_per_item * remaining_items))
    
    # 格式化延迟显示并设置颜色
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
    
    # 保存详细分析记录到日志
    printf "%s | %-15s | %-8s | %-15s | %-30s | %d/%d\n" \
        "$(date '+%H:%M:%S')" \
        "$ip" \
        "$latency_display" \
        "${provider:0:15}" \
        "${location:0:30}" \
        "$current" "$total" >> "${DETAILED_LOG}"
    
    # 每20行显示一次进度条和表头
    if [ $((current % 20)) -eq 1 ]; then
        # 打印总进度条
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
        printf "${WHITE}%-10s | %-17s | %-10s | %-18s | %-34s | %-15s${NC}\n" \
            "时间" "IP地址" "延迟" "供应商" "机房位置" "进度"
        printf "${WHITE}%s${NC}\n" "$(printf '=%.0s' {1..100})"
        
        # 在详细日志中也添加表头
        echo "----------------------------------------" >> "${DETAILED_LOG}"
        printf "%-10s | %-17s | %-10s | %-18s | %-34s | %-15s\n" \
            "时间" "IP地址" "延迟" "供应商" "机房位置" "进度" >> "${DETAILED_LOG}"
        echo "========================================" >> "${DETAILED_LOG}"
    fi
    
    # 显示当前行(交替使用不同颜色)
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

get_provider_from_asn() {
    local asn="$1"
    case "$asn" in
        # AWS - Amazon Web Services
        "16509"|"14618"|"38895"|"39111"|"7224"|"35994"|"10124"|"16509") echo "AWS" ;;

        # GCP - Google Cloud Platform
        "15169"|"396982"|"19527"|"43515"|"36040"|"36384"|"36385"|"41264"|"36492") echo "GCP" ;;

        # Azure - Microsoft Cloud
        "8075"|"8068"|"8069"|"8070"|"8071"|"8072"|"8073"|"8074"|"8075"|"8076"|"8077") echo "Azure" ;;

        # 中国云服务商
        "45102"|"45103"|"37963"|"45104"|"37963"|"45102"|"45104") echo "阿里云" ;;
        "45090"|"132203"|"132591"|"132203"|"45090") echo "腾讯云" ;;
        "55990"|"136907"|"136908"|"136909"|"136238"|"136237"|"136236") echo "华为云" ;;
        "63835"|"63512") echo "百度云" ;;
        "37963"|"37965"|"37937"|"37936") echo "阿里巴巴" ;;
        "7497"|"7586"|"7582"|"7583"|"7584") echo "CSTNET" ;;
        "4538"|"4537"|"4536"|"4535") echo "中国教育网" ;;

        # Cloudflare
        "13335"|"209242"|"395747"|"136620"|"394536"|"394556") echo "Cloudflare" ;;

        # DigitalOcean
        "14061"|"200130"|"202109"|"46652") echo "DigitalOcean" ;;

        # Vultr
        "20473"|"64515"|"397558"|"401886") echo "Vultr" ;;

        # Linode
        "63949"|"396998"|"398962"|"396982") echo "Linode" ;;

        # OVH
        "16276"|"394621"|"394622"|"35540"|"37989") echo "OVH" ;;

        # 中国运营商
        "4134"|"4809"|"4812"|"4813"|"4816"|"4835"|"17429"|"17430"|"17431") echo "中国电信" ;;
        "4837"|"9929"|"9808"|"58453"|"17621"|"17622"|"17623"|"17624") echo "中国联通" ;;
        "9808"|"9929"|"58453"|"56041"|"56042"|"56043"|"56044"|"56046") echo "中国移动" ;;
        "4847"|"4848"|"4849"|"4850") echo "中国铁通" ;;

        # 韩国运营商
        "45671"|"45673"|"45674"|"9318"|"9319") echo "韩国KT" ;;
        "4766"|"4768"|"38120"|"9286"|"9287") echo "韩国SK" ;;
        "3786"|"9644"|"9645"|"9647") echo "韩国LG" ;;

        # 日本运营商
        "2914"|"2516"|"2497"|"4713"|"23893") echo "NTT" ;;
        "17676"|"17677"|"17678"|"17506"|"17534") echo "SoftBank" ;;
        "4713"|"4725"|"7671"|"7672"|"7673") echo "OCN" ;;
        "7506"|"7522"|"7516"|"7515"|"7514") echo "GMO" ;;
        "2527"|"2518"|"2519"|"2520") echo "Sony" ;;
        "2510"|"2511"|"2512"|"2513") echo "KDDI" ;;

        # 数据中心和托管服务商
        "396356"|"396377") echo "Latitude.sh" ;;
        "24940"|"213230"|"213231") echo "Hetzner" ;;
        "60781"|"201200"|"201201") echo "LeaseWeb" ;;
        "12876"|"203476"|"209863") echo "Scaleway" ;;
        "29802"|"29803"|"29804") echo "HVC" ;;
        "133752"|"133753") echo "DediPath" ;;
        "63023"|"63024") echo "GTHost" ;;
        "53667"|"53668") echo "FranTech" ;;
        "40676"|"40677") echo "Psychz" ;;
        "25820"|"25821") echo "IT7" ;;
        "54825"|"54826") echo "Packet Host" ;;
        "62567"|"62568") echo "HostDare" ;;
        "46562"|"46563") echo "RackNation" ;;
        "35916"|"35917") echo "MultaCom" ;;
        "32097"|"32098") echo "WholeSale" ;;
        "32244"|"32245") echo "Liquid Web" ;;
        "32475"|"32476") echo "SingleHop" ;;
        "33387"|"33388") echo "DataShack" ;;
        "36352"|"36351") echo "ColoCrossing" ;;
        "55286"|"55287") echo "Server Room" ;;
        "40065"|"40066") echo "CNSERVERS" ;;

        # 全球网络服务商
        "174"|"7018"|"6389"|"5069"|"21928") echo "AT&T" ;;
        "3356"|"3549"|"3561"|"1785"|"1784") echo "Level3" ;;
        "6939"|"6940"|"6941"|"6942") echo "HE" ;;
        "3257"|"3258"|"3259"|"3260"|"3261") echo "GTT" ;;
        "9002"|"9003"|"9004"|"9005") echo "RETN" ;;
        "1299"|"1300"|"1301"|"1302") echo "Telia" ;;
        "6461"|"6462"|"6463"|"6464") echo "Zayo" ;;
        "6453"|"6454"|"6455"|"6456") echo "TATA" ;;
        "4826"|"4827"|"4828"|"4829") echo "VOCUS" ;;
        "4637"|"4638"|"4639"|"4640") echo "Telstra" ;;
        "7473"|"7474"|"7475"|"7476") echo "Singtel" ;;
        "2516"|"2517"|"2518"|"2519") echo "KDDI" ;;
        "4788"|"4789"|"4790"|"4791") echo "TMNet" ;;
        "4657"|"4658"|"4659"|"4660") echo "StarHub" ;;
        "9304"|"9305"|"9306"|"9307") echo "HGC" ;;
        
        # 新加坡数据中心
        "138997"|"138998") echo "EDGEUNO" ;;
        "133929"|"133930") echo "TWOWINPOWER" ;;
        "135377"|"135378") echo "UCLOUD" ;;
        "134548"|"134549") echo "NETWIN" ;;
        
        # 印度数据中心
        "45820"|"45821") echo "TTSL" ;;
        "55410"|"55411") echo "VIL" ;;
        "45609"|"45610") echo "Bharti" ;;
        "18101"|"18102") echo "Reliance" ;;

        # 如果没有匹配到，返回原始ASN
        *) echo "ASN-$asn" ;;
    esac
}
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

# 初始化 API 配置文件
init_api_config() {
    if [ ! -f "${API_CONFIG_FILE}" ]; then
        cat > "${API_CONFIG_FILE}" <<EOF
# API Keys Configuration
IPINFO_API_KEY=""
EOF
    fi
    
    # 加载配置
    source "${API_CONFIG_FILE}"
}

# API key 管理菜单
manage_api_keys() {
    while true; do
        clear
        echo -e "${GREEN}API Key 管理${NC}"
        echo "==================="
        echo -e "当前 API Key 状态："
        
        # 检查 IPINFO API key
        if [ -n "${IPINFO_API_KEY}" ]; then
            echo -e "IPInfo API Key: ${GREEN}已配置${NC}"
        else
            echo -e "IPInfo API Key: ${RED}未配置${NC}"
        fi
        
        echo
        echo -e "1. 设置 IPInfo API Key"
        echo -e "2. 测试 API Key"
        echo -e "3. 清除 API Key"
        echo -e "0. 返回上级菜单"
        echo
        echo -ne "请选择 [0-3]: "
        read -r choice
        
        case $choice in
            1)  echo -ne "\n请输入 IPInfo API Key: "
                read -r api_key
                if [ -n "$api_key" ]; then
                    # 测试 API key 是否有效
                    local test_response=$(curl -s -m 5 \
                        -H "Authorization: Bearer $api_key" \
                        "https://ipinfo.io/8.8.8.8/json")
                    
                    if echo "$test_response" | jq -e . >/dev/null 2>&1; then
                        # 更新配置文件
                        sed -i "s/IPINFO_API_KEY=.*/IPINFO_API_KEY=\"$api_key\"/" "${API_CONFIG_FILE}"
                        source "${API_CONFIG_FILE}"
                        log "SUCCESS" "API Key 设置成功！"
                    else
                        log "ERROR" "无效的 API Key"
                    fi
                else
                    log "ERROR" "API Key 不能为空"
                fi
                ;;
                
            2)  if [ -n "${IPINFO_API_KEY}" ]; then
                    echo -e "\n正在测试 API Key..."
                    local test_response=$(curl -s -m 5 \
                        -H "Authorization: Bearer ${IPINFO_API_KEY}" \
                        "https://ipinfo.io/8.8.8.8/json")
                    
                    if echo "$test_response" | jq -e . >/dev/null 2>&1; then
                        # 获取配额信息
                        local quota=$(curl -s -m 5 \
                            -H "Authorization: Bearer ${IPINFO_API_KEY}" \
                            "https://ipinfo.io/api/stats")
                        
                        echo -e "\nAPI Key 状态: ${GREEN}有效${NC}"
                        
                        if [ -n "$quota" ] && echo "$quota" | jq -e . >/dev/null 2>&1; then
                            echo "配额信息："
                            echo "$quota" | jq -r '
                                "  总请求次数: \(.total_requests // "未知")",
                                "  剩余请求次数: \(.requests_remaining // "未知")",
                                "  重置时间: \(.reset_date // "未知")"
                            '
                        else
                            echo "无法获取配额信息"
                        fi
                    else
                        echo -e "\nAPI Key 状态: ${RED}无效${NC}"
                    fi
                else
                    log "ERROR" "未配置 API Key"
                fi
                ;;
                
            3)  if [ -n "${IPINFO_API_KEY}" ]; then
                    echo -ne "\n确定要清除 API Key 吗？[y/N] "
                    read -r confirm
                    if [[ "$confirm" =~ ^[Yy]$ ]]; then
                        sed -i "s/IPINFO_API_KEY=.*/IPINFO_API_KEY=\"\"/" "${API_CONFIG_FILE}"
                        IPINFO_API_KEY=""
                        log "SUCCESS" "API Key 已清除"
                    fi
                else
                    log "WARN" "当前未配置 API Key"
                fi
                ;;
                
            0)  break ;;
            *)  log "ERROR" "无效选择" ;;
        esac
        
        read -rp "按回车键继续..."
    done
}

# 检查 API key
check_api_key() {
    if [ -z "${IPINFO_API_KEY}" ]; then
        log "WARN" "未配置 IPInfo API Key，将使用有限的 IP 信息源"
        read -rp "是否现在配置 API Key？[y/N] " confirm
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            manage_api_keys
        fi
    fi
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
    local deps=("curl" "nc" "whois" "awk" "sort" "jq" "bc" "geoiplookup" "wget" "unzip" "mmdblookup")
    local missing=()
    local geoip_needed=false
    local mmdb_needed=false

    # 检查所有依赖
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &>/dev/null; then
            case "$dep" in
                "geoiplookup")
                    geoip_needed=true
                    ;;
                "mmdblookup")
                    mmdb_needed=true
                    ;;
                *)
                    missing+=("$dep")
                    ;;
            esac
        fi
    done

    # 如果有缺失的依赖
    if [ ${#missing[@]} -ne 0 ] || [ "$geoip_needed" = true ] || [ "$mmdb_needed" = true ]; then
        local install_list=("${missing[@]}")
        [ "$geoip_needed" = true ] && install_list+=("geoip-bin" "geoip-database")
        [ "$mmdb_needed" = true ] && install_list+=("libmaxminddb0" "libmaxminddb-dev" "mmdb-bin")
        
        log "INFO" "正在安装必要工具: ${install_list[*]}"
        
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

        # 添加 MaxMind PPA 以获取最新版本
        if [ "$mmdb_needed" = true ]; then
            if ! grep -q "ppa:maxmind/ppa" /etc/apt/sources.list.d/*; then
                if ! add-apt-repository -y ppa:maxmind/ppa; then
                    log "WARN" "添加 MaxMind PPA 失败，使用默认源"
                fi
            fi
        fi
        
        if ! apt-get update -qq; then
            log "ERROR" "更新软件源失败"
            return 1
        fi
        
        if ! apt-get install -y -qq "${install_list[@]}"; then
            log "ERROR" "工具安装失败"
            return 1
        fi
        
        # 验证安装
        local verify_failed=false
        if [ "$geoip_needed" = true ] && ! command -v geoiplookup &>/dev/null; then
            log "ERROR" "GeoIP 工具安装失败"
            verify_failed=true
        fi
        
        if [ "$mmdb_needed" = true ] && ! command -v mmdblookup &>/dev/null; then
            log "ERROR" "MaxMind DB 工具安装失败"
            verify_failed=true
        fi
        
        if [ "$verify_failed" = true ]; then
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
# IP 数据库管理
IP_DB_DIR="${REPORT_DIR}/ip_db"
IP_DB_FILE="${IP_DB_DIR}/ip_ranges.db"
IP_DB_VERSION_FILE="${IP_DB_DIR}/version.txt"
IP_DB_LAST_UPDATE="${IP_DB_DIR}/last_update"
IP_DB_CACHE_DIR="${IP_DB_DIR}/cache"

# 初始化 IP 数据库目录
init_ip_db() {
    mkdir -p "${IP_DB_DIR}" "${IP_DB_CACHE_DIR}"
    touch "${IP_DB_LAST_UPDATE}"
    
    # 如果配置文件不存在，创建默认配置
    if [ ! -f "${IP_DB_DIR}/config.conf" ]; then
        cat > "${IP_DB_DIR}/config.conf" <<EOF
# API Keys Configuration
MAXMIND_LICENSE_KEY=""
IPINFO_TOKEN=""
IP2LOCATION_TOKEN=""
# Update Intervals (in seconds)
CLOUD_UPDATE_INTERVAL=604800  # 7 days
GEODB_UPDATE_INTERVAL=2592000 # 30 days
BGP_UPDATE_INTERVAL=86400     # 1 day
EOF
    fi
    
    # 加载配置
    source "${IP_DB_DIR}/config.conf"
}

# 更新 IP 数据库
update_ip_database() {
    log "INFO" "正在更新 IP 数据库..."
    local temp_dir="${TEMP_DIR}/ip_db_update"
    mkdir -p "$temp_dir"

    # 1. 主要云服务商
    {
        # AWS
        log "INFO" "更新 AWS IP 范围..."
        if curl -s "https://ip-ranges.amazonaws.com/ip-ranges.json" -o "${temp_dir}/aws.json"; then
            jq -r '.prefixes[] | select(.service=="EC2" or .service=="AMAZON") | .ip_prefix' "${temp_dir}/aws.json" > "${temp_dir}/aws_ranges.txt"
        fi
        
        # Azure
        log "INFO" "更新 Azure IP 范围..."
        if curl -s "https://download.microsoft.com/download/7/1/D/71D86715-5596-4529-9B13-DA13A5DE5B63/ServiceTags_Public.json" -o "${temp_dir}/azure.json"; then
            jq -r '.values[] | select(.name=="AzureCloud") | .properties.addressPrefixes[]' "${temp_dir}/azure.json" > "${temp_dir}/azure_ranges.txt"
        fi
        
        # Google Cloud
        log "INFO" "更新 Google Cloud IP 范围..."
        if curl -s "https://www.gstatic.com/ipranges/cloud.json" -o "${temp_dir}/gcp.json"; then
            jq -r '.prefixes[] | select(.ipv4Prefix!=null) | .ipv4Prefix' "${temp_dir}/gcp.json" > "${temp_dir}/gcp_ranges.txt"
        fi
        
        # Oracle Cloud
        log "INFO" "更新 Oracle Cloud IP 范围..."
        if curl -s "https://docs.oracle.com/en-us/iaas/tools/public_ip_ranges.json" -o "${temp_dir}/oracle.json"; then
            jq -r '.regions[].cidrs[].cidr' "${temp_dir}/oracle.json" > "${temp_dir}/oracle_ranges.txt"
        fi
    } &

    # 2. 亚太区云服务商
    {
        # 阿里云
        log "INFO" "更新阿里云 IP 范围..."
        if curl -s "https://raw.githubusercontent.com/alibaba/alibaba-cloud-sdk-go/master/services/ecs/ip_ranges.json" -o "${temp_dir}/alicloud.json"; then
            jq -r '.[] | .IpAddress[]' "${temp_dir}/alicloud.json" > "${temp_dir}/alicloud_ranges.txt"
        fi
        
        # 腾讯云 (使用公开的 BGP 数据)
        log "INFO" "更新腾讯云 IP 范围..."
        curl -s "https://bgp.he.net/AS45090" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+' > "${temp_dir}/tencent_ranges.txt"
        
        # 华为云
        log "INFO" "更新华为云 IP 范围..."
        curl -s "https://bgp.he.net/AS55990" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+' > "${temp_dir}/huawei_ranges.txt"
    } &

    # 3. 欧美主要服务商
    {
        # DigitalOcean
        log "INFO" "更新 DigitalOcean IP 范围..."
        if curl -s "https://digitalocean.com/geo/google.csv" -o "${temp_dir}/do.csv"; then
            awk -F',' '{print $1}' "${temp_dir}/do.csv" > "${temp_dir}/do_ranges.txt"
        fi
        
        # Vultr
        log "INFO" "更新 Vultr IP 范围..."
        curl -s "https://bgp.he.net/AS20473" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+' > "${temp_dir}/vultr_ranges.txt"
        
        # Linode
        log "INFO" "更新 Linode IP 范围..."
        curl -s "https://bgp.he.net/AS63949" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+' > "${temp_dir}/linode_ranges.txt"
        
        # OVH
        log "INFO" "更新 OVH IP 范围..."
        curl -s "https://bgp.he.net/AS16276" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+' > "${temp_dir}/ovh_ranges.txt"
        
        # Hetzner
        log "INFO" "更新 Hetzner IP 范围..."
        curl -s "https://bgp.he.net/AS24940" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+' > "${temp_dir}/hetzner_ranges.txt"
    } &

    # 4. CDN 和边缘服务商
    {
        # Cloudflare
        log "INFO" "更新 Cloudflare IP 范围..."
        if curl -s "https://api.cloudflare.com/client/v4/ips" -o "${temp_dir}/cloudflare.json"; then
            jq -r '.result.ipv4_cidrs[]' "${temp_dir}/cloudflare.json" > "${temp_dir}/cloudflare_ranges.txt"
        fi
        
        # Fastly
        log "INFO" "更新 Fastly IP 范围..."
        if curl -s "https://api.fastly.com/public-ip-list" -o "${temp_dir}/fastly.json"; then
            jq -r '.addresses[]' "${temp_dir}/fastly.json" > "${temp_dir}/fastly_ranges.txt"
        fi
    } &

    # 等待所有后台任务完成
    wait

    # 合并所有数据
    {
        echo "# IP 范围数据库"
        echo "# 更新时间: $(date '+%Y-%m-%d %H:%M:%S')"
        echo

        # 处理每个服务商的数据
        process_provider_ranges "AWS" "aws_ranges.txt" "${temp_dir}"
        process_provider_ranges "AZURE" "azure_ranges.txt" "${temp_dir}"
        process_provider_ranges "GCP" "gcp_ranges.txt" "${temp_dir}"
        process_provider_ranges "ORACLE" "oracle_ranges.txt" "${temp_dir}"
        process_provider_ranges "ALICLOUD" "alicloud_ranges.txt" "${temp_dir}"
        process_provider_ranges "TENCENT" "tencent_ranges.txt" "${temp_dir}"
        process_provider_ranges "HUAWEI" "huawei_ranges.txt" "${temp_dir}"
        process_provider_ranges "DO" "do_ranges.txt" "${temp_dir}"
        process_provider_ranges "VULTR" "vultr_ranges.txt" "${temp_dir}"
        process_provider_ranges "LINODE" "linode_ranges.txt" "${temp_dir}"
        process_provider_ranges "OVH" "ovh_ranges.txt" "${temp_dir}"
        process_provider_ranges "HETZNER" "hetzner_ranges.txt" "${temp_dir}"
        process_provider_ranges "CLOUDFLARE" "cloudflare_ranges.txt" "${temp_dir}"
        process_provider_ranges "FASTLY" "fastly_ranges.txt" "${temp_dir}"
    } > "$IP_DB_FILE"

    # 更新时间戳
    date +%s > "${IP_DB_LAST_UPDATE}"
    
    # 清理临时文件
    rm -rf "$temp_dir"
    
    log "SUCCESS" "IP 数据库更新完成"
}
# 处理服务商 IP 范围
process_provider_ranges() {
    local provider="$1"
    local file="$2"
    local dir="$3"
    
    if [ -f "${dir}/${file}" ]; then
        echo "# ${provider}"
        while read -r range; do
            echo "${provider}|${range}"
        done < "${dir}/${file}"
        echo
    fi
}

# 检查 IP 是否在范围内
check_ip_in_range() {
    local ip="$1"
    local range="$2"
    
    # 将 IP 地址转换为数字
    local IFS='.'
    read -r -a ip_parts <<< "$ip"
    local ip_num=$(( (${ip_parts[0]} << 24) + (${ip_parts[1]} << 16) + (${ip_parts[2]} << 8) + ${ip_parts[3]} ))
    
    # 处理 CIDR 范围
    local network="${range%/*}"
    local bits="${range#*/}"
    read -r -a net_parts <<< "$network"
    local net_num=$(( (${net_parts[0]} << 24) + (${net_parts[1]} << 16) + (${net_parts[2]} << 8) + ${net_parts[3]} ))
    
    local mask=$(( 0xFFFFFFFF << (32 - bits) ))
    local net_low=$(( net_num & mask ))
    local net_high=$(( net_low | ~mask & 0xFFFFFFFF ))
    
    # 检查 IP 是否在范围内
    if (( ip_num >= net_low && ip_num <= net_high )); then
        return 0
    fi
    return 1
}

# 初始化数据库和缓存目录
init_databases() {
    log "INFO" "正在更新 ASN 数据库..."
    
    # 创建必要的目录
    mkdir -p "${ASN_DB_DIR}"
    
    # 使用 MaxMind Lite 数据库（免费版本）
    local mmdb_url="https://raw.githubusercontent.com/P3TERX/GeoLite.mmdb/download/GeoLite2-ASN.mmdb"
    local temp_db="${ASN_DB_DIR}/temp.mmdb"
    
    if curl -sSL "$mmdb_url" -o "$temp_db"; then
        mv "$temp_db" "${ASN_DB_FILE}"
        log "SUCCESS" "ASN 数据库更新成功"
        return 0
    fi
    
    # 如果上述方法失败，使用简化的 ASN 数据
    log "INFO" "使用内置 ASN 数据..."
    cat > "${ASN_DB_FILE}" <<EOF
{
    "aws": ["16509", "14618", "38895"],
    "gcp": ["15169", "396982"],
    "azure": ["8075", "8068", "8069"],
    "alibaba": ["45102", "45103", "37963"],
    "tencent": ["45090", "132203"],
    "huawei": ["55990", "136907"]
}
EOF
    
    if [ -f "${ASN_DB_FILE}" ]; then
        log "SUCCESS" "使用内置 ASN 数据库"
        return 0
    fi
    
    log "WARN" "ASN 数据库初始化失败，将使用基础识别方式"
    return 1

    # 2. 初始化变量
    local provider="Unknown"
    local location="Unknown Location"
    local asn=""
    local org=""
    local response=""

    # 3. ASN 数据库查询
    if [ -f "${ASN_DB_FILE}" ]; then
        if command -v mmdblookup >/dev/null 2>&1; then
            asn=$(mmdblookup --file "${ASN_DB_FILE}" --ip "$ip" autonomous_system_number 2>/dev/null | grep -oP '"\K[^"]+' | head -1)
            org=$(mmdblookup --file "${ASN_DB_FILE}" --ip "$ip" autonomous_system_organization 2>/dev/null | grep -oP '"\K[^"]+' | head -1)
            if [ -n "$org" ]; then
                provider="$org"
            fi
        fi
    fi

    # 如果 ASN 查询失败，尝试备用方案：whois ASN 查询
    if [ "$provider" = "Unknown" ]; then
        local asn_info
        asn_info=$(whois -h whois.radb.net -- "-i origin $(whois "$ip" | grep -i "^origin:" | awk '{print $2}')" 2>/dev/null)
        if [ -n "$asn_info" ]; then
            local temp_provider=$(echo "$asn_info" | grep -i "^as-name:" | head -1 | awk '{print $2}')
            [ -n "$temp_provider" ] && provider="$temp_provider"
        fi
    fi

    # 4. IPInfo API 查询
    if [ -n "${IPINFO_API_KEY}" ] && { [ "$provider" = "Unknown" ] || [ "$location" = "Unknown Location" ]; }; then
        response=$(curl -s -m 5 -H "Authorization: Bearer ${IPINFO_API_KEY}" "https://ipinfo.io/${ip}/json")
        if [ $? -eq 0 ] && [ -n "$response" ] && echo "$response" | jq -e . >/dev/null 2>&1; then
            [ "$provider" = "Unknown" ] && provider=$(echo "$response" | jq -r '.org // .asn // "Unknown"')
            if [ "$location" = "Unknown Location" ]; then
                local city=$(echo "$response" | jq -r '.city // empty')
                local region=$(echo "$response" | jq -r '.region // empty')
                local country=$(echo "$response" | jq -r '.country // empty')
                if [ -n "$city" ] && [ -n "$country" ]; then
                    location="${city}${region:+, $region}, ${country}"
                fi
            fi
        fi
    fi

    # 5. IP-API 查询（如果上面失败）
    if [ "$provider" = "Unknown" ] || [ "$location" = "Unknown Location" ]; then
        response=$(curl -s -m 5 "http://ip-api.com/json/${ip}")
        if [ $? -eq 0 ] && [ -n "$response" ] && echo "$response" | jq -e . >/dev/null 2>&1; then
            [ "$provider" = "Unknown" ] && provider=$(echo "$response" | jq -r '.isp // .org // "Unknown"')
            if [ "$location" = "Unknown Location" ]; then
                local city=$(echo "$response" | jq -r '.city // empty')
                local region=$(echo "$response" | jq -r '.regionName // empty')
                local country=$(echo "$response" | jq -r '.country // empty')
                if [ -n "$city" ] && [ -n "$country" ]; then
                    location="${city}${region:+, $region}, ${country}"
                fi
            fi
        fi
    fi

    # 6. whois 查询（如果还是失败）
    if [ "$provider" = "Unknown" ] || [ "$location" = "Unknown Location" ]; then
        local whois_info
        whois_info=$(whois "$ip" 2>/dev/null)
        if [ $? -eq 0 ] && [ -n "$whois_info" ]; then
            if [ "$provider" = "Unknown" ]; then
                local temp_provider=$(echo "$whois_info" | grep -iE "^(Organization|OrgName|netname|descr):" | head -1 | cut -d: -f2- | xargs)
                [ -n "$temp_provider" ] && provider="$temp_provider"
            fi
            if [ "$location" = "Unknown Location" ]; then
                local country=$(echo "$whois_info" | grep -iE "^(country):" | head -1 | cut -d: -f2- | xargs)
                local city=$(echo "$whois_info" | grep -iE "^(city):" | head -1 | cut -d: -f2- | xargs)
                [ -n "$city" ] && [ -n "$country" ] && location="${city}, ${country}"
            fi
        fi
    fi

    # 7. 标准化供应商名称
    if [ -n "$provider" ] && [ "$provider" != "Unknown" ]; then
        case "${provider,,}" in
            *"amazon"*|*"aws"*|*"ec2"*)
                provider="Amazon AWS" ;;
            *"alibaba"*|*"aliyun"*|*"alicloud"*)
                provider="Alibaba Cloud" ;;
            *"google"*|*"gcp"*)
                provider="Google Cloud" ;;
            *"azure"*|*"microsoft"*)
                provider="Microsoft Azure" ;;
            *"digitalocean"*|*"digital ocean"*)
                provider="DigitalOcean" ;;
            *"ovh"*)
                provider="OVH" ;;
            *"hetzner"*)
                provider="Hetzner" ;;
            *"vultr"*)
                provider="Vultr" ;;
            *"linode"*)
                provider="Linode" ;;
            *"tencent"*)
                provider="Tencent Cloud" ;;
            *"huawei"*)
                provider="Huawei Cloud" ;;
        esac
    fi

    # 8. 构建并缓存结果
    local result="{\"provider\":\"${provider}\",\"location\":\"${location}\"}"
    echo "$result" | tee "$cache_file"
    
    return 0
}

# ASN 数据库更新函数
update_asn_database() {
    log "INFO" "正在更新 ASN 数据库..."
    local temp_dir=$(mktemp -d)
    local success=false

    # 确保目录存在
    mkdir -p "${ASN_DB_DIR}"

    # 1. 首选: MaxMind GeoLite2 数据库
    if [ -n "${MAXMIND_LICENSE_KEY}" ]; then
        log "INFO" "尝试使用 MaxMind 数据库..."
        local db_url="https://download.maxmind.com/app/geoip_download?edition_id=GeoLite2-ASN&license_key=${MAXMIND_LICENSE_KEY}&suffix=tar.gz"
        if curl -s -f "$db_url" -o "${temp_dir}/asn.tar.gz"; then
            if tar xzf "${temp_dir}/asn.tar.gz" -C "${temp_dir}"; then
                if find "${temp_dir}" -name "*.mmdb" -exec cp {} "${ASN_DB_FILE}" \; ; then
                    success=true
                    log "SUCCESS" "MaxMind ASN 数据库更新成功"
                fi
            fi
        else
            log "WARN" "MaxMind 数据库下载失败，尝试备用源"
        fi
    fi

    # 2. 备选: IP2Location Lite 数据库
    if [ "$success" = false ]; then
        log "INFO" "尝试使用 IP2Location 数据源..."
        if wget -q --timeout=30 "https://download.ip2location.com/lite/IP2LOCATION-LITE-ASN.BIN.ZIP" -O "${temp_dir}/asn.zip"; then
            if unzip -q "${temp_dir}/asn.zip" -d "${temp_dir}"; then
                if mv "${temp_dir}/IP2LOCATION-LITE-ASN.BIN" "${ASN_DB_FILE}"; then
                    success=true
                    log "SUCCESS" "IP2Location ASN 数据库更新成功"
                fi
            fi
        else
            log "WARN" "IP2Location 数据库下载失败"
        fi
    fi

    # 3. 最后备选: 本地缓存
    if [ "$success" = false ] && [ -f "${ASN_DB_FILE}" ]; then
        log "WARN" "使用现有的本地数据库缓存"
        success=true
    fi

    # 清理临时文件
    rm -rf "${temp_dir}"

    if [ "$success" = false ]; then
        log "ERROR" "ASN 数据库更新失败，所有数据源均不可用"
        return 1
    fi

    # 更新版本信息
    date +%s > "${ASN_DB_VERSION_FILE}"
    chmod 644 "${ASN_DB_FILE}" "${ASN_DB_VERSION_FILE}"
    
    return 0
}

get_ip_info() {
    local ip="$1"
    local cache_file="${IP_DB_CACHE_DIR}/${ip}"
    
    # 1. 检查缓存
    if [ -f "$cache_file" ] && [ $(($(date +%s) - $(stat -c %Y "$cache_file"))) -lt 86400 ]; then
        cat "$cache_file"
        return 0
    fi

    # 2. 初始化变量
    local provider="Unknown"
    local location="Unknown Location"
    local asn=""
    local org=""
    local response=""

    # 3. ASN 数据库查询
    if [ -f "${ASN_DB_FILE}" ]; then
        if command -v mmdblookup >/dev/null 2>&1; then
            asn=$(mmdblookup --file "${ASN_DB_FILE}" --ip "$ip" autonomous_system_number 2>/dev/null | grep -oP '"\K[^"]+' | head -1)
            org=$(mmdblookup --file "${ASN_DB_FILE}" --ip "$ip" autonomous_system_organization 2>/dev/null | grep -oP '"\K[^"]+' | head -1)
            if [ -n "$org" ]; then
                provider="$org"
            fi
        fi
    fi

    # 如果 ASN 查询失败，尝试备用方案：whois ASN 查询
    if [ "$provider" = "Unknown" ]; then
        local asn_info
        asn_info=$(whois -h whois.radb.net -- "-i origin $(whois "$ip" | grep -i "^origin:" | awk '{print $2}')" 2>/dev/null)
        if [ -n "$asn_info" ]; then
            local temp_provider=$(echo "$asn_info" | grep -i "^as-name:" | head -1 | awk '{print $2}')
            [ -n "$temp_provider" ] && provider="$temp_provider"
        fi
    fi

    # 4. IPInfo API 查询
    if [ -n "${IPINFO_API_KEY}" ] && { [ "$provider" = "Unknown" ] || [ "$location" = "Unknown Location" ]; }; then
        response=$(curl -s -m 5 -H "Authorization: Bearer ${IPINFO_API_KEY}" "https://ipinfo.io/${ip}/json")
        if [ $? -eq 0 ] && [ -n "$response" ] && echo "$response" | jq -e . >/dev/null 2>&1; then
            [ "$provider" = "Unknown" ] && provider=$(echo "$response" | jq -r '.org // .asn // "Unknown"')
            if [ "$location" = "Unknown Location" ]; then
                local city=$(echo "$response" | jq -r '.city // empty')
                local region=$(echo "$response" | jq -r '.region // empty')
                local country=$(echo "$response" | jq -r '.country // empty')
                if [ -n "$city" ] && [ -n "$country" ]; then
                    location="${city}${region:+, $region}, ${country}"
                fi
            fi
        fi
    fi

    # 5. IP-API 查询（如果上面失败）
    if [ "$provider" = "Unknown" ] || [ "$location" = "Unknown Location" ]; then
        response=$(curl -s -m 5 "http://ip-api.com/json/${ip}")
        if [ $? -eq 0 ] && [ -n "$response" ] && echo "$response" | jq -e . >/dev/null 2>&1; then
            [ "$provider" = "Unknown" ] && provider=$(echo "$response" | jq -r '.isp // .org // "Unknown"')
            if [ "$location" = "Unknown Location" ]; then
                local city=$(echo "$response" | jq -r '.city // empty')
                local region=$(echo "$response" | jq -r '.regionName // empty')
                local country=$(echo "$response" | jq -r '.country // empty')
                if [ -n "$city" ] && [ -n "$country" ]; then
                    location="${city}${region:+, $region}, ${country}"
                fi
            fi
        fi
    fi

    # 6. whois 查询（如果还是失败）
    if [ "$provider" = "Unknown" ] || [ "$location" = "Unknown Location" ]; then
        local whois_info
        whois_info=$(whois "$ip" 2>/dev/null)
        if [ $? -eq 0 ] && [ -n "$whois_info" ]; then
            if [ "$provider" = "Unknown" ]; then
                local temp_provider=$(echo "$whois_info" | grep -iE "^(Organization|OrgName|netname|descr):" | head -1 | cut -d: -f2- | xargs)
                [ -n "$temp_provider" ] && provider="$temp_provider"
            fi
            if [ "$location" = "Unknown Location" ]; then
                local country=$(echo "$whois_info" | grep -iE "^(country):" | head -1 | cut -d: -f2- | xargs)
                local city=$(echo "$whois_info" | grep -iE "^(city):" | head -1 | cut -d: -f2- | xargs)
                [ -n "$city" ] && [ -n "$country" ] && location="${city}, ${country}"
            fi
        fi
    fi

    # 7. 标准化供应商名称
    if [ -n "$provider" ] && [ "$provider" != "Unknown" ]; then
        case "${provider,,}" in
            *"amazon"*|*"aws"*|*"ec2"*)
                provider="Amazon AWS" ;;
            *"alibaba"*|*"aliyun"*|*"alicloud"*)
                provider="Alibaba Cloud" ;;
            *"google"*|*"gcp"*)
                provider="Google Cloud" ;;
            *"azure"*|*"microsoft"*)
                provider="Microsoft Azure" ;;
            *"digitalocean"*|*"digital ocean"*)
                provider="DigitalOcean" ;;
            *"ovh"*)
                provider="OVH" ;;
            *"hetzner"*)
                provider="Hetzner" ;;
            *"vultr"*)
                provider="Vultr" ;;
            *"linode"*)
                provider="Linode" ;;
            *"tencent"*)
                provider="Tencent Cloud" ;;
            *"huawei"*)
                provider="Huawei Cloud" ;;
        esac
    fi

    # 8. 构建并缓存结果
    local result="{\"provider\":\"${provider}\",\"location\":\"${location}\"}"
    echo "$result" | tee "$cache_file"
    
    return 0
}


# 初始化数据库
init_ip_db

# 测试网络质量
test_network_quality() {
    local ip="$1"
    local total_latency=0
    local valid_tests=0
    local min_latency=999999
    
    # 对每个端口进行测试
    for port in "${TEST_PORTS[@]}"; do
        for ((i=1; i<=RETRIES; i++)); do
            # 使用 nc 进行更精确的延迟测试
            local start_time=$(date +%s%N)
            if timeout "$TIMEOUT_SECONDS" nc -zv "$ip" "$port" >/dev/null 2>&1; then
                local end_time=$(date +%s%N)
                local latency=$(( (end_time - start_time) / 1000000 ))
                
                # 更新最小延迟
                if [ "$latency" -lt "$min_latency" ]; then
                    min_latency=$latency
                fi
                
                ((valid_tests++))
                total_latency=$((total_latency + latency))
            fi
        done
    done
    
    # 计算平均延迟
    if [ "$valid_tests" -gt 0 ]; then
        echo "scale=2; $total_latency / $valid_tests" | bc
    else
        echo "999"
    fi
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
    local temp_file="${TEMP_DIR}/validators_temp.txt"
    local retry_count=3
    local success=false
    
    # 确保 Solana CLI 已安装且配置正确
    if ! command -v solana &>/dev/null; then
        log "ERROR" "Solana CLI 未安装"
        return 1
    fi  # <-- 添加了这个缺失的 fi

    # 检查 Solana 网络连接
    if ! solana cluster-version &>/dev/null; then
        log "ERROR" "无法连接到 Solana 网络，请检查网络连接"
        return 1
    fi
    
    # 尝试获取验证者列表
    for ((i=1; i<=retry_count; i++)); do
        log "INFO" "正在获取验证者列表 (尝试 $i/$retry_count)"
        
        # 使用超时命令避免卡死
        if timeout 30s solana gossip | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' > "$temp_file" 2>/dev/null; then
            if [ -s "$temp_file" ]; then
                local ip_count=$(wc -l < "$temp_file")
                if [ "$ip_count" -gt 0 ]; then
                    log "SUCCESS" "成功获取到 $ip_count 个验证者节点"
                    success=true
                    break
                fi
            fi
        fi
        
        log "WARN" "尝试 $i 失败，等待重试..."
        sleep 3
    done
    
    if [ "$success" = false ]; then
        log "ERROR" "无法获取验证者列表，请检查 Solana CLI 配置"
        log "INFO" "可以尝试运行: solana config set --url https://api.mainnet-beta.solana.com"
        return 1
    fi
    
    # 过滤和处理 IP 列表
    {
        # 去重并过滤私有IP
        sort -u "$temp_file" | \
        grep -v '^10\.' | \
        grep -v '^172\.\(1[6-9]\|2[0-9]\|3[0-1]\)\.' | \
        grep -v '^192\.168\.' | \
        grep -v '^127\.' | \
        grep -v '^0\.' | \
        grep -v '^169\.254\.' | \
        grep -v '^224\.' | \
        grep -v '^240\.' | \
        while IFS= read -r ip; do
            # 验证 IP 格式
            if [[ $ip =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                # 检查每个段是否在有效范围内
                local valid=true
                IFS='.' read -r -a octets <<< "$ip"
                for octet in "${octets[@]}"; do
                    if [ "$octet" -gt 255 ]; then
                        valid=false
                        break
                    fi
                done
                
                if [ "$valid" = true ]; then
                    echo "$ip"
                fi
            fi
        done
    } > "${temp_file}.filtered"
    
    # 检查过滤后的结果
    if [ ! -s "${temp_file}.filtered" ]; then
        log "ERROR" "过滤后没有有效的验证者IP"
        rm -f "$temp_file" "${temp_file}.filtered"
        return 1
    fi
    
    # 输出结果
    cat "${temp_file}.filtered"
    
    # 清理临时文件
    rm -f "$temp_file" "${temp_file}.filtered"
    } # <-- 添加了这个缺失的闭合大括号

# 生成分析报告
generate_report() {
    local temp_report="${TEMP_DIR}/temp_report.txt"
    local results_file="${RESULTS_FILE}"
    
    if [ ! -f "${results_file}" ]; then
        log "ERROR" "结果文件不存在，无法生成报告"
        return 1
    fi
    
    log "INFO" "正在生成分析报告..."
    
    # 统计供应商数据
    local provider_stats=$(awk -F'|' '
    NF == 4 && $4 ~ /^[0-9]+(\.[0-9]+)?$/ {
        provider[$2]++
        latency[$2]+=$4
        if($4 <= 300) available[$2]++
        total_nodes++
    } 
    END {
        for(p in provider) {
            avg_latency = latency[p]/provider[p]
            avail_rate = (available[p]/provider[p])*100
            share = (provider[p]/total_nodes)*100
            printf "%s|%d|%.1f|%.2f|%.1f\n", p, provider[p], share, avg_latency, avail_rate
        }
    }' "${results_file}" | sort -t'|' -k2,2nr)
    
    # 统计机房数据
    local location_stats=$(awk -F'|' '
    NF == 4 && $4 ~ /^[0-9]+(\.[0-9]+)?$/ {
        loc_key = $3"|"$2
        loc_count[loc_key]++
        latency[loc_key]+=$4
    } 
    END {
        for(lk in loc_count) {
            split(lk, arr, "|")
            location = arr[1]
            provider = arr[2]
            avg_latency = latency[lk]/loc_count[lk]
            printf "%s|%s|%d|%.2f\n", location, provider, loc_count[lk], avg_latency
        }
    }' "${results_file}" | sort -t'|' -k3,3nr)
    
    # 统计最近的20个节点
    local nearest_nodes=$(awk -F'|' '
    NF == 4 && $4 ~ /^[0-9]+(\.[0-9]+)?$/ {
        printf "%s|%s|%s|%.2f\n", $1, $2, $3, $4
    }' "${results_file}" | sort -t'|' -k4,4n | head -20)
    
    {
        echo "===================================================================================="
        echo "                         Solana 验证者节点分布分析报告"
        echo "===================================================================================="
        echo
        echo "【距离最近的验证者节点 (TOP 20)】"
        echo "------------------------------------------------------------------------------------"
        printf "%-18s | %-26s | %-32s | %15s\n" \
            "IP地址" "供应商" "数据中心" "延迟(ms)"
        echo "------------------------------------------------------------------------------------"
        
        echo "$nearest_nodes" | while IFS='|' read -r ip provider location latency; do
            printf "%-15s | %-20s | %-25s | %15.2f\n" \
                "$ip" "${provider:0:20}" "${location:0:25}" "$latency"
        done
        
        echo
        echo "【延迟分布分析】"
        echo "------------------------------------------------------------------------------------"
        echo "$nearest_nodes" | awk -F'|' '
        BEGIN {
            count=0
            total=0
            min=999999
            max=0
        }
        {
            latency=$4
            total+=latency
            count++
            if(latency < min) min=latency
            if(latency > max) max=latency
        }
        END {
            if(count > 0) {
                avg=total/count
                printf "最低延迟: %15.2f ms\n", min
                printf "最高延迟: %15.2f ms\n", max
                printf "平均延迟: %15.2f ms\n", avg
                printf "样本数量: %15d\n", count
            }
        }'
        
        echo
        echo "【供应商分布统计】"
        echo "----------------------------------------------------------------------------------------------"
        
        # 读取主导供应商信息
        local top_info=$(echo "$provider_stats" | head -n1)
        local top_provider=$(echo "$top_info" | cut -d'|' -f1)
        local top_count=$(echo "$top_info" | cut -d'|' -f2)
        local top_share=$(echo "$top_info" | cut -d'|' -f3)
        
        echo "主导供应商: ${top_provider}"
        echo "节点数量: ${top_count} (占比: ${top_share}%)"
        echo
        
        echo "供应商排名 (Top 20):"
        echo "----------------------------------------------------------------------------------------------"
        printf "%-28s | %8s | %18s | %25s | %15s\n" \
            "供应商" "节点数" "占比" "平均延迟" "可用率"
        echo "----------------------------------------------------------------------------------------------"
        
        echo "$provider_stats" | head -20 | while IFS='|' read -r provider count share latency avail; do
            printf "%-25s | %8d | %15.1f%% | %15.2f ms | %15.1f%%\n" \
                "${provider:0:25}" "$count" "$share" "$latency" "$avail"
        done
        
        echo
        echo "【机房分布统计】"
        echo "----------------------------------------------------------------------------------------------"
        echo "主要机房分布 (Top 20):"
        echo
        printf "%-38s | %-23s | %8s | %15s\n" \
            "机房" "供应商" "节点数" "平均延迟"
        echo "----------------------------------------------------------------------------------------------"
        
        echo "$location_stats" | head -20 | while IFS='|' read -r location provider count latency; do
            printf "%-35s | %-20s | %8d | %15.2f ms\n" \
                "${location:0:35}" "${provider:0:20}" "$count" "$latency"
        done
        
        echo
        echo "【最优部署建议】"
        echo
        printf "%-38s | %-20s | %13s | %15s\n" \
            "机房" "供应商" "节点数" "平均延迟"
        echo "----------------------------------------------------------------------------------------------"
        
        # 选择节点数量最多的前3个机房作为建议
        echo "$location_stats" | sort -t'|' -k3,3nr | head -3 | \
            while IFS='|' read -r location provider count latency; do
                printf "%-35s | %-20s | %8d | %15.2f ms\n" \
                    "${location:0:35}" "${provider:0:20}" "$count" "$latency"
            done
        
        echo
        echo "部署策略建议："
        echo "1. 选择节点数量较多的机房，这表明该位置已经过其他验证者验证"
        echo "2. 优先考虑平均延迟较低的机房"
        echo "3. 建议选择2-3个不同供应商的机房作为备选，提高可用性"
        echo "4. 定期进行延迟测试和性能监控"
        echo "5. 考虑成本因素，不同地区和供应商的价格差异较大"
        
    } > "$temp_report"

    # 保存无颜色版本的报告
    sed 's/\x1b\[[0-9;]*m//g' "$temp_report" > "${LATEST_REPORT}"
    
    # 显示报告
    cat "$temp_report"
    rm -f "$temp_report"
    
    log "SUCCESS" "分析报告已生成并保存至: ${LATEST_REPORT}"
    return 0
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

# 供应商统计菜单
# 供应商统计菜单
show_provider_stats_menu() {
    local log_file="/root/solana_reports/detailed_analysis.log"
    
    while true; do
        clear
        echo -e "${GREEN}供应商节点统计${NC}"
        echo "==================="
        
        if [ ! -f "$log_file" ] || [ ! -s "$log_file" ]; then
            echo -e "${YELLOW}提示: 未找到节点分析数据${NC}"
            echo -e "${YELLOW}请先运行选项2(并发分析所有节点)后再查看统计信息${NC}"
            echo "==================="
        else
            # 显示当前供应商统计概况
            echo -e "${CYAN}当前供应商列表:${NC}"
            echo -e "${WHITE}供应商          | 节点数量${NC}"
            echo "------------------------"
            
            awk '
            BEGIN {
                FS=" \\| "
            }
            
            # 获取总节点数
            /^[0-9]+\/[0-9]+$/ {
                split($NF, arr, "/")
                total_nodes = arr[2]
                next
            }
            
            # 跳过表头、分隔线和空行
            /^时间/ || /^=+/ || /^-+/ || /^$/ {
                next
            }
            
            # 处理数据行
            {
                provider = $4
                gsub(/^[ \t]+|[ \t]+$/, "", provider)
                if (provider != "") {
                    providers[provider]++
                }
            }
            
            END {
                # 创建排序数组
                n = 0
                for (p in providers) {
                    sorted[++n] = p
                }
                
                # 按节点数量降序排序
                for (i = 1; i <= n; i++) {
                    for (j = i + 1; j <= n; j++) {
                        if (providers[sorted[i]] < providers[sorted[j]]) {
                            temp = sorted[i]
                            sorted[i] = sorted[j]
                            sorted[j] = temp
                        }
                    }
                }
                
                # 输出所有供应商
                for (i = 1; i <= n; i++) {
                    printf "%-15s | %d\n", substr(sorted[i],1,15), providers[sorted[i]]
                }
                
                print "------------------------"
                printf "总计节点数: %d\n", total_nodes
            }
            ' "$log_file"
            
            echo "------------------------"
        fi
        
        echo
        echo -e "1. 查看指定供应商统计"
        echo -e "2. 查看热门供应商统计 (TOP 10)"
        echo -e "0. 返回主菜单"
        echo
        echo -ne "请选择 [0-2]: "
        read -r choice

        case $choice in
            1)  if [ ! -f "$log_file" ] || [ ! -s "$log_file" ]; then
                    log "ERROR" "请先运行选项2进行节点分析"
                else
                    echo -ne "\n请输入供应商名称(参考上方列表): "
                    read -r provider_name
                    if [ -n "$provider_name" ]; then
                        show_provider_stats "$provider_name" "$log_file"
                    else
                        log "ERROR" "供应商名称不能为空"
                    fi
                fi
                ;;
            2)  if [ ! -f "$log_file" ] || [ ! -s "$log_file" ]; then
                    log "ERROR" "请先运行选项2进行节点分析"
                else
                    show_top_providers "$log_file"
                fi
                ;;
            0)  break
                ;;
            *)  log "ERROR" "无效选择"
                ;;
        esac
        
        [ "$choice" != "0" ] && read -rp "按回车键继续..."
    done
}

# 显示指定供应商的统计信息
# 显示指定供应商统计
show_provider_stats() {
    local provider_name="$1"
    local log_file="/root/solana_reports/detailed_analysis.log"
    local report_file="${REPORT_DIR}/provider_stats_${provider_name// /_}.log"
    
    clear
    echo
    echo -e "${GREEN}Solana 验证者节点延迟分析工具 ${WHITE}v${VERSION}${NC}"
    echo
    echo -e "${GREEN}供应商: ${WHITE}${provider_name}${GREEN} 节点统计${NC}"
    echo -e "${GREEN}============================================${NC}"
    echo -e "${GREEN}数据中心位置      | 节点数量 | 平均延迟    | 最低延迟    | 最高延迟    | 占比(%)${NC}"
    echo -e "${GREEN}============================================${NC}"
    
    {
        echo "Solana 验证者节点延迟分析工具 v${VERSION}"
        echo
        echo "供应商: ${provider_name} 节点统计"
        echo "============================================"
        echo "数据中心位置      | 节点数量 | 平均延迟    | 最低延迟    | 最高延迟    | 占比(%)"
        echo "============================================"
    } > "$report_file"
    
    grep -v "^$\|^-\|^=\|^时间" "$log_file" | \
    awk -F' \\| ' -v provider="$provider_name" '
    BEGIN {
        GREEN="\033[0;32m"
        WHITE="\033[1;37m"
        YELLOW="\033[1;33m"
        RED="\033[0;31m"
        CYAN="\033[36m"
        NC="\033[0m"
    }
    
    function get_latency_color(latency) {
        if (latency <= 50) return GREEN
        else if (latency <= 100) return WHITE
        else if (latency <= 200) return YELLOW
        else return RED
    }
    
    {
        if ($4 ~ provider) {
            location = $5
            latency = $3
            gsub(/ms/, "", latency)
            gsub(/^[ \t]+|[ \t]+$/, "", location)
            
            split($6, progress, "/")
            total_nodes = progress[2]
            
            key = location
            count[key]++
            sum_latency[key] += latency
            if (!min_latency[key] || latency < min_latency[key]) 
                min_latency[key] = latency
            if (!max_latency[key] || latency > max_latency[key]) 
                max_latency[key] = latency
        }
    }
    
    END {
        n = 0
        total = 0
        for (loc in count) {
            locations[++n] = loc
            total += count[loc]
        }
        
        if (n == 0) {
            print "未找到该供应商的节点数据"
            exit
        }
        
        for (i = 1; i <= n; i++) {
            for (j = i + 1; j <= n; j++) {
                if (count[locations[i]] < count[locations[j]]) {
                    temp = locations[i]
                    locations[i] = locations[j]
                    locations[j] = temp
                }
            }
        }
        
        for (i = 1; i <= n; i++) {
            loc = locations[i]
            avg = sum_latency[loc] / count[loc]
            percentage = (count[loc] / total_nodes) * 100
            
            avg_color = get_latency_color(avg)
            min_color = get_latency_color(min_latency[loc])
            max_color = get_latency_color(max_latency[loc])
            location_color = (i % 2 == 0) ? WHITE : CYAN
            
            # 带颜色的输出到屏幕
            printf "%s%-15s%s | %s%8d%s | %s%10.2f%s | %s%10.2f%s | %s%10.2f%s | %s%6.2f%s\n",
                location_color, substr(loc,1,15), NC,
                WHITE, count[loc], NC,
                avg_color, avg, NC,
                min_color, min_latency[loc], NC,
                max_color, max_latency[loc], NC,
                WHITE, percentage, NC
            
            # 不带颜色的输出到文件
            printf "%-15s | %8d | %10.2f | %10.2f | %10.2f | %6.2f\n",
                substr(loc,1,15),
                count[loc],
                avg,
                min_latency[loc],
                max_latency[loc],
                percentage >> "'$report_file'"
        }
        
        footer = "------------------------------------------------------------------------------------------------\n总计: " total " 个节点"
        print footer
        print footer >> "'$report_file'"
    }
    '
    
    echo
    echo -e "${GREEN}[OK]${NC} 报告已保存至: ${WHITE}$report_file${NC}"
    echo
    echo -ne "${GREEN}按回车键继续...${NC}"
    read
}


# 显示热门供应商统计
# 显示热门供应商统计
show_top_providers() {
    local log_file="/root/solana_reports/detailed_analysis.log"
    local report_file="${REPORT_DIR}/top_providers_stats.log"
    
    clear
    echo
    echo -e "${GREEN}Solana 验证者节点延迟分析工具 ${WHITE}v${VERSION}${NC}"
    echo
    echo -e "${GREEN}热门供应商节点统计 (TOP 10)${NC}"
    echo -e "${GREEN}============================================${NC}"
    echo -e "${GREEN}供应商          | 数据中心位置      | 节点数量 | 平均延迟    | 最低延迟    | 最高延迟    | 占比(%)${NC}"
    echo -e "${GREEN}============================================${NC}"
    
    {
        echo "Solana 验证者节点延迟分析工具 v${VERSION}"
        echo
        echo "热门供应商节点统计 (TOP 10)"
        echo "============================================"
        echo "供应商          | 数据中心位置      | 节点数量 | 平均延迟    | 最低延迟    | 最高延迟    | 占比(%)"
        echo "============================================"
    } > "$report_file"
    
    grep -v "^$\|^-\|^=\|^时间" "$log_file" | \
    awk -F' \\| ' '
    BEGIN {
        GREEN="\033[0;32m"
        WHITE="\033[1;37m"
        YELLOW="\033[1;33m"
        RED="\033[0;31m"
        CYAN="\033[36m"
        NC="\033[0m"
    }
    
    function get_latency_color(latency) {
        if (latency <= 50) return GREEN
        else if (latency <= 100) return WHITE
        else if (latency <= 200) return YELLOW
        else return RED
    }
    
    {
        provider = $4
        location = $5
        latency = $3
        gsub(/ms/, "", latency)
        gsub(/^[ \t]+|[ \t]+$/, "", provider)
        gsub(/^[ \t]+|[ \t]+$/, "", location)
        
        split($6, progress, "/")
        total_nodes = progress[2]
        
        if (provider != "" && location != "") {
            key = provider "|" location
            count[key]++
            sum_latency[key] += latency
            if (!min_latency[key] || latency < min_latency[key]) 
                min_latency[key] = latency
            if (!max_latency[key] || latency > max_latency[key]) 
                max_latency[key] = latency
            providers[provider] += 1
        }
    }
    
    END {
        n = 0
        for (p in providers) {
            sorted_providers[++n] = p
        }
        
        for (i = 1; i <= n; i++) {
            for (j = i + 1; j <= n; j++) {
                if (providers[sorted_providers[i]] < providers[sorted_providers[j]]) {
                    temp = sorted_providers[i]
                    sorted_providers[i] = sorted_providers[j]
                    sorted_providers[j] = temp
                }
            }
        }
        
        for (i = 1; i <= (n < 10 ? n : 10); i++) {
            provider = sorted_providers[i]
            
            loc_count = 0
            for (key in count) {
                split(key, arr, "|")
                if (arr[1] == provider) {
                    locations[++loc_count] = key
                    loc_nodes[key] = count[key]
                }
            }
            
            for (x = 1; x <= loc_count; x++) {
                for (y = x + 1; y <= loc_count; y++) {
                    if (loc_nodes[locations[x]] < loc_nodes[locations[y]]) {
                        temp = locations[x]
                        locations[x] = locations[y]
                        locations[y] = temp
                    }
                }
            }
            
            for (x = 1; x <= loc_count; x++) {
                key = locations[x]
                split(key, arr, "|")
                avg = sum_latency[key] / count[key]
                percentage = (count[key] / total_nodes) * 100
                
                avg_color = get_latency_color(avg)
                min_color = get_latency_color(min_latency[key])
                max_color = get_latency_color(max_latency[key])
                location_color = (x % 2 == 0) ? WHITE : CYAN
                
                # 带颜色的输出到屏幕
                printf "%s%-15s%s | %s%-15s%s | %s%8d%s | %s%10.2f%s | %s%10.2f%s | %s%10.2f%s | %s%6.2f%s\n",
                    WHITE, substr(arr[1],1,15), NC,
                    location_color, substr(arr[2],1,15), NC,
                    WHITE, count[key], NC,
                    avg_color, avg, NC,
                    min_color, min_latency[key], NC,
                    max_color, max_latency[key], NC,
                    WHITE, percentage, NC
                
                # 不带颜色的输出到文件
                printf "%-15s | %-15s | %8d | %10.2f | %10.2f | %10.2f | %6.2f\n",
                    substr(arr[1],1,15),
                    substr(arr[2],1,15),
                    count[key],
                    avg,
                    min_latency[key],
                    max_latency[key],
                    percentage >> "'$report_file'"
            }
            if (i < (n < 10 ? n : 10)) {
                print "------------------------------------------------------------------------------------------------"
                print "------------------------------------------------------------------------------------------------" >> "'$report_file'"
            }
        }
    }
    '
    
    echo
    echo -e "${GREEN}[OK]${NC} 报告已保存至: ${WHITE}$report_file${NC}"
    echo
    echo -ne "${GREEN}按回车键继续...${NC}"
    read
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
    echo -e "${GREEN}7. API Key 管理${NC}"
    echo -e "${GREEN}8. 供应商节点统计${NC}"
    echo -e "${RED}0. 退出程序${NC}"
    echo
    echo -ne "${GREEN}请输入您的选择 [0-8]: ${NC}"
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

# 分析验证者节点
# 分析验证者节点
analyze_validators() {
    local background="${1:-false}"
    local parallel="${2:-false}"
    BACKGROUND_MODE="$background"
    
    log "INFO" "开始分析验证者节点分布"
    
    # 确保已安装jq
    if ! command -v jq &>/dev/null; then
        log "INFO" "正在安装jq..."
        apt-get update -qq && apt-get install -y jq || {
            log "ERROR" "jq安装失败"
            return 1
        }
    fi
    
    # 获取验证者列表
    local validator_ips
    validator_ips=$(solana gossip | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | sort -u) || {
        log "ERROR" "获取验证者信息失败"
        return 1
    }
    
    # 创建临时目录和文件
    mkdir -p "${TEMP_DIR}/results"
    : > "${RESULTS_FILE}"
    echo "$validator_ips" > "${TEMP_DIR}/tmp_ips.txt"
    
    local total=$(wc -l < "${TEMP_DIR}/tmp_ips.txt")
    START_TIME=$(date +%s)
    
    if [ "$parallel" = "true" ]; then
        log "INFO" "使用 ${MAX_CONCURRENT_JOBS:-10} 个并发任务"
        
        # 创建进度计数器
        echo "0" > "${TEMP_DIR}/counter"
        
        # 使用信号量控制并发
        local sem_file="${TEMP_DIR}/semaphore"
        mkfifo "$sem_file"
        exec 3<>"$sem_file"
        rm "$sem_file"
        
        # 初始化信号量
        for ((i=1; i<=${MAX_CONCURRENT_JOBS:-10}; i++)); do
            echo >&3
        done
        
        while IFS= read -r ip; do
            # 等待信号量
            read -u 3
            {
                # 测试IP
                latency=$(timeout "${TIMEOUT_SECONDS:-2}" ping -c 1 "$ip" 2>/dev/null | \
                         grep -oP 'time=\K[0-9.]+' || echo "999")
                
                # 获取IP信息并解析
                local ip_info=$(get_ip_info "$ip")
                local cloud_provider=$(echo "$ip_info" | jq -r '.provider // empty' 2>/dev/null || echo "Unknown")
                local datacenter=$(echo "$ip_info" | jq -r '.location // empty' 2>/dev/null || echo "Unknown")
                
                # 处理ASN信息
                if [[ "$cloud_provider" == "Unknown" ]]; then
                    local asn=$(echo "$ip_info" | jq -r '.asn // empty' 2>/dev/null)
                    if [ -n "$asn" ]; then
                        cloud_provider=$(get_provider_from_asn "$asn")
                    fi
                fi
                
                # 清理和格式化数据中心信息
                datacenter=$(echo "$datacenter" | sed 's/{"provider":"[^"]*","location":"//g' | sed 's/"[^"]*$//g')
                
                # 如果数据中心信息为空，使用供应商信息
                if [[ -z "$datacenter" || "$datacenter" == "null" || "$datacenter" == "Unknown" ]]; then
                    datacenter="$cloud_provider Datacenter"
                fi
                
                # 原子性写入结果
                {
                    flock -x 200
                    echo "${ip}|${cloud_provider}|${datacenter}|${latency}" >> "${RESULTS_FILE}"
                    local current=$(($(cat "${TEMP_DIR}/counter") + 1))
                    echo "$current" > "${TEMP_DIR}/counter"
                    
                    if [ "$BACKGROUND_MODE" = "false" ]; then
                        update_progress "$current" "$total" "$ip" "$latency" "$datacenter" "$cloud_provider"
                    fi
                } 200>"${TEMP_DIR}/lock"
                
                # 释放信号量
                echo >&3
            } &
        done < "${TEMP_DIR}/tmp_ips.txt"
        
        # 等待所有任务完成
        wait
        
        # 关闭信号量
        exec 3>&-
        
    else
        # 单线程处理
        local current=0
        while IFS= read -r ip; do
            ((current++))
            
            # 测试IP
            latency=$(timeout "${TIMEOUT_SECONDS:-2}" ping -c 1 "$ip" 2>/dev/null | \
                     grep -oP 'time=\K[0-9.]+' || echo "999")
            
            # 获取IP信息并解析
            local ip_info=$(get_ip_info "$ip")
            local cloud_provider=$(echo "$ip_info" | jq -r '.provider // empty' 2>/dev/null || echo "Unknown")
            local datacenter=$(echo "$ip_info" | jq -r '.location // empty' 2>/dev/null || echo "Unknown")
            
            # 处理ASN信息
            if [[ "$cloud_provider" == "Unknown" ]]; then
                local asn=$(echo "$ip_info" | jq -r '.asn // empty' 2>/dev/null)
                if [ -n "$asn" ]; then
                    cloud_provider=$(get_provider_from_asn "$asn")
                fi
            fi
            
            # 清理和格式化数据中心信息
            datacenter=$(echo "$datacenter" | sed 's/{"provider":"[^"]*","location":"//g' | sed 's/"[^"]*$//g')
            
            # 如果数据中心信息为空，使用供应商信息
            if [[ -z "$datacenter" || "$datacenter" == "null" || "$datacenter" == "Unknown" ]]; then
                datacenter="$cloud_provider Datacenter"
            fi
            
            # 写入结果
            echo "${ip}|${cloud_provider}|${datacenter}|${latency}" >> "${RESULTS_FILE}"
            
            if [ "$BACKGROUND_MODE" = "false" ]; then
                update_progress "$current" "$total" "$ip" "$latency" "$datacenter" "$cloud_provider"
            fi
            
        done < "${TEMP_DIR}/tmp_ips.txt"
    fi
    
    # 生成报告
    generate_report
    
    log "SUCCESS" "分析完成"
    return 0
}



        
# 并发处理函数
    process_ip() {
    local ip="$1"
    local result_file="$2"
    local counter_file="$3"
    
    # 使用临时文件存储结果，避免竞争条件
    local temp_result="${TEMP_DIR}/results/${ip}.tmp"
    
    # 获取延迟和IP信息
    local latency=$(test_network_quality "$ip")
    local provider_info=$(get_ip_info "$ip")
    
    # 提取 ASN 号码并获取供应商信息
    local asn=$(echo "$provider_info" | grep -oE '^AS[0-9]+' | grep -oE '[0-9]+')
    local cloud_provider
    if [ -n "$asn" ]; then
        cloud_provider=$(get_provider_from_asn "$asn")
    else
        # 如果没有 ASN，使用原始信息进行匹配
        cloud_provider=$(echo "$provider_info" | cut -d'|' -f1 | 
            sed -E 's/.*"([^"]+)".*/\1/' |           # 提取引号中的内容
            sed -E 's/^[0-9]+ //')                   # 删除开头的ASN号
    fi
    
    # 获取数据中心位置
    local datacenter=$(echo "$provider_info" | cut -d'|' -f3 | 
        sed -E 's/.*"([^"]+)".*/\1/' |           # 提取引号中的内容
        case "$datacenter" in
            *"Tokyo"*|*"Japan"*) echo "东京" ;;
            *"Singapore"*) echo "新加坡" ;;
            *"Seoul"*|*"Korea"*) echo "首尔" ;;
            *"Virginia"*|*"us-east"*) echo "弗吉尼亚" ;;
            *"Frankfurt"*|*"Germany"*) echo "法兰克福" ;;
            *"London"*|*"UK"*) echo "伦敦" ;;
            *"Sydney"*|*"Australia"*) echo "悉尼" ;;
            *"Mumbai"*|*"India"*) echo "孟买" ;;
            *"São Paulo"*|*"Brazil"*) echo "圣保罗" ;;
            *"Ireland"*) echo "爱尔兰" ;;
            *"Hong Kong"*) echo "香港" ;;
            *"Shanghai"*) echo "上海" ;;
            *"Beijing"*) echo "北京" ;;
            *"Guangzhou"*) echo "广州" ;;
            *"Shenzhen"*) echo "深圳" ;;
            *"Hangzhou"*) echo "杭州" ;;
            *"Osaka"*) echo "大阪" ;;
            *"Amsterdam"*) echo "阿姆斯特丹" ;;
            *"Paris"*) echo "巴黎" ;;
            *"Toronto"*) echo "多伦多" ;;
            *"Montreal"*) echo "蒙特利尔" ;;
            *"Dubai"*) echo "迪拜" ;;
            *"Jakarta"*) echo "雅加达" ;;
            *"Kuala Lumpur"*) echo "吉隆坡" ;;
            *"Bangkok"*) echo "曼谷" ;;
            *"Manila"*) echo "马尼拉" ;;
            *"Los Angeles"*|*"LA"*) echo "洛杉矶" ;;
            *"San Jose"*) echo "圣何塞" ;;
            *"Seattle"*) echo "西雅图" ;;
            *"Dallas"*) echo "达拉斯" ;;
            *"Chicago"*) echo "芝加哥" ;;
            *"New York"*|*"NYC"*) echo "纽约" ;;
            *"Washington"*|*"DC"*) echo "华盛顿" ;;
            *"Miami"*) echo "迈阿密" ;;
            *) echo "$datacenter" ;;
        esac)
    
    # 组合显示格式：供应商-机房
    local display_location="${cloud_provider}-${datacenter}"
    
    # 原子性写入结果
    echo "$ip|$cloud_provider|$datacenter|$latency" > "$temp_result"
    
    # 使用 flock 确保原子性写入主结果文件
    {
        flock -x 200
        cat "$temp_result" >> "$result_file"
        local current=$(cat "$counter_file")
        echo $((current + 1)) > "$counter_file"
    } 200>"${TEMP_DIR}/write.lock"
    
    # 清理临时文件
    rm -f "$temp_result"
    
    # 更新显示
    if [ "$background" = "false" ]; then
        {
            flock -x 201
            local current=$(cat "$counter_file")
            update_progress "$current" "$total" "$ip" "$latency" "$display_location" "$cloud_provider"
        } 201>"${TEMP_DIR}/display.lock"
    fi
}
        

# 主函数
main() {
    local cmd="${1:-}"
    
    if [ "$EUID" -ne 0 ]; then 
        log "ERROR" "请使用root权限运行此脚本"
        exit 1
    fi
    
    # 确保目录结构正确
    setup_directories
   
    # 设置目录
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

    # 初始化所有必要组件
    check_dependencies || exit 1
    install_solana_cli || exit 1
    load_config
    init_api_config
    init_databases || log "WARN" "数据库初始化失败，将使用备用方案"
    
    while true; do
        show_menu
        read -r choice
        
        case $choice in
            1)  check_api_key
                analyze_validators false false || {
                    log "ERROR" "分析失败"
                    read -rp "按回车键继续..."
                }
                ;;
            2)  check_api_key
                analyze_validators false true || {
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
            7)  manage_api_keys
                ;;
            8)  show_provider_stats_menu
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
