#!/bin/bash

<<'COMMENT'
Solana 验证者节点分析工具 v2.0
功能：查找并分析所有验证者节点的网络状态和部署位置
作者：Claude
更新：2024-01
COMMENT

# 颜色定义
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'

# 图标定义
INFO_ICON="ℹ️"
NODE_ICON="📡"
CHECK_ICON="✅"
CLOUD_ICON="☁️"
WARNING_ICON="⚠️"
DC_ICON="🏢"
NETWORK_ICON="🌐"
LATENCY_ICON="⚡"

# 定义阈值（单位：ms）
LATENCY_THRESHOLD=10  # 默认寻找延迟10ms以内的节点

# 临时文件和日志
TEMP_DIR="/tmp/solana_analyzer"
LOG_FILE="${TEMP_DIR}/analysis.log"
CACHE_DIR="${TEMP_DIR}/cache"

# 创建必要的目录
mkdir -p "${TEMP_DIR}" "${CACHE_DIR}"

# 定义主流公有云服务商
declare -A CLOUD_PROVIDERS=(
    # 全球主流
    ["AWS"]="https://ip-ranges.amazonaws.com/ip-ranges.json"
    ["Azure"]="https://download.microsoft.com/download/7/1/D/71D86715-5596-4529-9B13-DA13A5DE5B63/ServiceTags_Public_20231127.json"
    ["GCP"]="https://www.gstatic.com/ipranges/cloud.json"
    ["Oracle"]="https://docs.oracle.com/en-us/iaas/tools/public_ip_ranges.json"
    ["IBM"]="https://cloud.ibm.com/cloud-ip-ranges"
    
    # 中国区域
    ["Alibaba"]="https://raw.githubusercontent.com/alibaba/alibaba-cloud-ip-ranges/main/ip-ranges.json"
    ["Tencent"]="https://ip-ranges.tencentcloud.com/ip-ranges.json"
    ["Huawei"]="https://ip-ranges.huaweicloud.com/ip-ranges.json"
    ["Baidu"]="https://cloud.baidu.com/doc/BCC/s/5jwvyaqhb"
    ["JD"]="https://docs.jdcloud.com/cn/common-declaration/public-ip-ranges"
    ["Kingsoft"]="https://www.ksyun.com/doc/product/4/1993"
    ["QingCloud"]="https://docs.qingcloud.com/product/network/ip_ranges"
    ["UCloud"]="https://docs.ucloud.cn/network/vpc/limit"
    
    # 其他区域主流
    ["DigitalOcean"]="https://digitalocean.com/geo/google.csv"
    ["Vultr"]="https://api.vultr.com/v2/regions"
    ["Linode"]="https://geoip.linode.com/"
    ["OVH"]="https://ip-ranges.ovh.net/ip-ranges.json"
    ["Hetzner"]="https://docs.hetzner.com/cloud/general/locations"
    ["Scaleway"]="https://www.scaleway.com/en/docs/compute/instances/reference-content/ip-ranges"
    ["Rackspace"]="https://docs.rackspace.com/docs/public-ip-ranges"
    
    # 区域性云服务
    ["Naver"]="https://api.ncloud.com/v2/regions"
    ["NTTCom"]="https://ecl.ntt.com/ip-ranges"
    ["SBCloud"]="https://www.sb.a.clouddn.com/ranges"
    ["Kamatera"]="https://console.kamatera.com/ips"
    ["CloudSigma"]="https://www.cloudsigma.com/ip-ranges"
    
    # 专注特定领域的云服务
    ["Akamai"]="https://ip-ranges.akamai.com/"
    ["Fastly"]="https://api.fastly.com/public-ip-list"
    ["Cloudflare"]="https://www.cloudflare.com/ips/"
    ["StackPath"]="https://stackpath.com/ip-blocks"
    ["Leaseweb"]="https://www.leaseweb.com/network/ip-ranges"
    ["Anexia"]="https://www.anexia-it.com/blog/en/network/ip-ranges"
    
    # 新兴云服务商
    ["UpCloud"]="https://upcloud.com/network/ip-ranges"
    ["Wasabi"]="https://wasabi.com/ip-ranges"
    ["Backblaze"]="https://www.backblaze.com/ip-ranges"
    ["Render"]="https://render.com/docs/ip-addresses"
    ["Fly.io"]="https://fly.io/docs/reference/public-ips"
    ["Heroku"]="https://devcenter.heroku.com/articles/dynos#ip-ranges"
    ["Platform.sh"]="https://docs.platform.sh/development/public-ips"
    ["DigitalRealty"]="https://www.digitalrealty.com/data-centers"
)

# 定义区域信息
declare -A CLOUD_REGIONS=(
    # AWS 区域
    ["aws-us-east-1"]="US East (N. Virginia)"
    ["aws-us-east-2"]="US East (Ohio)"
    ["aws-us-west-1"]="US West (N. California)"
    ["aws-us-west-2"]="US West (Oregon)"
    ["aws-af-south-1"]="Africa (Cape Town)"
    ["aws-ap-east-1"]="Asia Pacific (Hong Kong)"
    ["aws-ap-south-1"]="Asia Pacific (Mumbai)"
    
    # Azure 区域
    ["azure-eastus"]="East US"
    ["azure-eastus2"]="East US 2"
    ["azure-westus"]="West US"
    ["azure-westus2"]="West US 2"
    
    # Google Cloud 区域
    ["gcp-us-east1"]="South Carolina"
    ["gcp-us-east4"]="Northern Virginia"
    ["gcp-us-west1"]="Oregon"
    
    # 阿里云区域
    ["alibaba-cn-hangzhou"]="华东 1 (杭州)"
    ["alibaba-cn-shanghai"]="华东 2 (上海)"
    ["alibaba-cn-beijing"]="华北 2 (北京)"
    
    # 腾讯云区域
    ["tencent-ap-beijing"]="华北地区(北京)"
    ["tencent-ap-shanghai"]="华东地区(上海)"
    ["tencent-ap-guangzhou"]="华南地区(广州)"
)

# 日志函数
log() {
    local level=$1
    shift
    local message="$*"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo -e "${timestamp} [${level}] ${message}" >> "${LOG_FILE}"
    
    case "$level" in
        "INFO")  echo -e "${BLUE}${INFO_ICON} ${message}${NC}" ;;
        "ERROR") echo -e "${RED}${WARNING_ICON} ${message}${NC}" ;;
        "SUCCESS") echo -e "${GREEN}${CHECK_ICON} ${message}${NC}" ;;
        *) echo -e "${message}" ;;
    esac
}

# 检查依赖
check_dependencies() {
    local deps=("curl" "jq" "whois" "bc" "ping")
    local missing=()

    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &>/dev/null; then
            missing+=("$dep")
        fi
    done

    if [ ${#missing[@]} -ne 0 ]; then
        log "INFO" "正在安装必要工具: ${missing[*]}"
        apt-get update -qq && apt-get install -y -qq "${missing[@]}"
        if [ $? -ne 0 ]; then
            log "ERROR" "工具安装失败，请手动安装: ${missing[*]}"
            return 1
        fi
    fi
    return 0
}

# 获取数据中心信息
get_datacenter_info() {
    local ip=$1
    local info=""
    local location=""
    local provider=""
    local cache_file="${CACHE_DIR}/${ip}_info.cache"
    
    # 检查缓存
    if [ -f "$cache_file" ] && [ $(( $(date +%s) - $(stat -c %Y "$cache_file") )) -lt 86400 ]; then
        cat "$cache_file"
        return 0
    }

    # 1. 使用 ipinfo.io API
    local ipinfo=$(curl -s --max-time 3 "https://ipinfo.io/${ip}/json" 2>/dev/null)
    if [ $? -eq 0 ]; then
        local org=$(echo "$ipinfo" | jq -r '.org // empty')
        local city=$(echo "$ipinfo" | jq -r '.city // empty')
        local region=$(echo "$ipinfo" | jq -r '.region // empty')
        local country=$(echo "$ipinfo" | jq -r '.country // empty')
        
        [ -n "$org" ] && info="$org"
        [ -n "$city" ] && location="$city"
        [ -n "$country" ] && location="${location:+$location, }$country"
    fi

    # 2. 检查云服务商
    for provider_name in "${!CLOUD_PROVIDERS[@]}"; do
        if check_ip_in_range "$ip" "${CLOUD_PROVIDERS[$provider_name]}" "$provider_name"; then
            provider="$provider_name"
            break
        fi
    done

    # 3. ASN 查询
    if [ -z "$info" ]; then
        local asn_info=$(curl -s --max-time 3 "https://api.asn.cymru.com/v1/ip/$ip" 2>/dev/null)
        if [ $? -eq 0 ]; then
            local asn_org=$(echo "$asn_info" | cut -d'|' -f5 | xargs)
            [ -n "$asn_org" ] && info="$asn_org"
        fi
    fi

    # 4. whois 查询（作为后备）
    if [ -z "$info" ]; then
        local whois_info=$(whois "$ip" 2>/dev/null)
        local org=$(echo "$whois_info" | grep -E -i "OrgName|Organization|org-name|owner" | head -1 | cut -d':' -f2- | xargs)
        local netname=$(echo "$whois_info" | grep -E -i "NetName|network-name" | head -1 | cut -d':' -f2- | xargs)
        [ -n "$org" ] && info="$org"
        [ -n "$netname" ] && info="${info:+$info / }$netname"
    fi

    # 组合最终信息
    local final_info=""
    [ -n "$provider" ] && final_info="$provider"
    [ -n "$info" ] && final_info="${final_info:+$final_info - }$info"
    [ -n "$location" ] && final_info="${final_info:+$final_info (}${location}${final_info:+)}"

    # 缓存结果
    echo "$final_info" > "$cache_file"
    echo "$final_info"
}

# 执行ping测试
do_ping_test() {
    local ip=$1
    local count=10
    local interval=0.2
    local timeout=1
    local result=$(ping -c $count -i $interval -W $timeout "$ip" 2>/dev/null)
    
    if [ $? -eq 0 ]; then
        local stats=$(echo "$result" | tail -1)
        local min=$(echo "$stats" | awk -F'/' '{print $4}')
        local avg=$(echo "$stats" | awk -F'/' '{print $5}')
        local max=$(echo "$stats" | awk -F'/' '{print $6}')
        local loss=$(echo "$result" | grep -oP '\d+(?=% packet loss)')
        echo "$min|$avg|$max|$loss"
    else
        echo "timeout|timeout|timeout|100"
    fi
}

# 分析验证者节点
analyze_validators() {
    log "INFO" "开始分析验证者节点部署情况"
    
    # 表头
    printf "\n%s\n" "$(printf '=%.0s' {1..140})"
    printf "%-16s | %-20s | %-50s | %-45s\n" \
        "IP地址" "延迟(最小/平均/最大)" "数据中心/供应商" "位置信息"
    printf "%s\n" "$(printf '=%.0s' {1..140})"
    
    # 获取验证者列表
    local validators
    validators=$(solana gossip --url https://api.mainnet-beta.solana.com 2>/dev/null)
    if [ $? -ne 0 ]; then
        log "ERROR" "无法获取验证者节点信息"
        return 1
    fi

    # 统计变量
    local total=0
    local responsive=0
    local low_latency=0

    # 处理每个IP
    echo "$validators" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | sort -u | while read -r ip; do
        ((total++))
        
        # 显示进度
        printf "\r${YELLOW}正在分析: %d/${total}${NC}" "$total"
        
        # 获取ping结果
        local ping_stats=$(do_ping_test "$ip")
        local min_latency=$(echo "$ping_stats" | cut -d'|' -f1)
        local avg_latency=$(echo "$ping_stats" | cut -d'|' -f2)
        local max_latency=$(echo "$ping_stats" | cut -d'|' -f3)
        local packet_loss=$(echo "$ping_stats" | cut -d'|' -f4)
        
        # 获取数据中心信息
        local dc_info=$(get_datacenter_info "$ip")
        
        # 格式化延迟信息
        local latency_info
        if [ "$min_latency" != "timeout" ]; then
            ((responsive++))
            latency_info=$(printf "%.2f/%.2f/%.2f ms" "$min_latency" "$avg_latency" "$max_latency")
            if (( $(echo "$avg_latency < $LATENCY_THRESHOLD" | bc -l) )); then
                ((low_latency++))
                printf "${GREEN}"
            else
                printf "${YELLOW}"
            fi
        else
            latency_info="超时"
            printf "${RED}"
        fi
        
        # 打印结果
        printf "%-16s | %-20s | %-50s | %-45s${NC}\n" \
            "$ip" "$latency_info" "${dc_info:0:50}" "${location:0:45}"
        
        # 每10个节点显示分隔线
        if (( total % 10 == 0 )); then
            printf "%s\n" "$(printf '-%.0s' {1..140})"
        fi
    done

    # 打印统计信息
    printf "\n%s\n" "$(printf '=%.0s' {1..140})"
    log "SUCCESS" "分析完成！"
    echo -e "${BLUE}统计信息:${NC}"
    echo "总节点数: $total"
    echo "可响应节点: $responsive"
    echo "低延迟节点(< ${LATENCY_THRESHOLD}ms): $low_latency"
}

# 主函数
main() {
    # 检查root权限
    if [ "$EUID" -ne 0 ]; then 
        log "ERROR" "请使用root权限运行此脚本"
        exit 1
    fi
    
    # 检查依赖
    check_dependencies || exit 1
    
    # 安装 Solana CLI（如果需要）
    if ! command -v solana &>/dev/null; then
        log "INFO" "正在安装 Solana CLI..."
        sh -c "$(curl -sSfL https://release.solana.com/stable/install)"
        export PATH="/root/.local/share/solana/install/active_release/bin:$PATH"
    fi
    
    # 设置延迟阈值
    log "INFO" "当前延迟阈值为 ${LATENCY_THRESHOLD}ms"
    read -p "是否要修改延迟阈值？(y/n) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        read -p "请输入新的延迟阈值(ms): " new_threshold
        if [[ "$new_threshold" =~ ^[0-9]+$ ]]; then
            LATENCY_THRESHOLD=$new_threshold
            log "SUCCESS" "延迟阈值已更新为 ${LATENCY_THRESHOLD}ms"
        else
            log "ERROR" "输入无效，使用默认阈值 ${LATENCY_THRESHOLD}ms"
        fi
    fi
    
    # 执行分析
    analyze_validators
    
    # 清理临时文件（保留24小时内的缓存）
    find "${CACHE_DIR}" -type f -mtime +1 -delete 2>/dev/null
}

# 启动程序
main
