#!/bin/bash

# 颜色定义
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'

# 标识符定义
INFO="[INFO]"
WARN="[WARN]"
ERROR="[ERROR]"
SUCCESS="[OK]"

# 临时目录和文件
TEMP_DIR="/tmp/solana_dc_finder"
LOG_FILE="${TEMP_DIR}/dc_finder.log"
RESULTS_FILE="${TEMP_DIR}/validator_locations.txt"
mkdir -p "${TEMP_DIR}"

# 日志函数
log() {
    local level=$1
    shift
    local message="$*"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo -e "${timestamp} [${level}] ${message}" >> "${LOG_FILE}"
    
    case "$level" in
        "INFO")  echo -e "${BLUE}${INFO} ${message}${NC}" ;;
        "ERROR") echo -e "${RED}${ERROR} ${message}${NC}" ;;
        "SUCCESS") echo -e "${GREEN}${SUCCESS} ${message}${NC}" ;;
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

# 安装 Solana CLI
install_solana_cli() {
    if ! command -v solana &>/dev/null; then
        log "INFO" "Solana CLI 未安装,开始安装..."
        
        # 下载并安装 Solana CLI
        sh -c "$(curl -sSfL https://release.solana.com/stable/install)"
        
        # 添加到 PATH
        export PATH="/root/.local/share/solana/install/active_release/bin:$PATH"
        
        # 验证安装
        if ! command -v solana &>/dev/null; then
            log "ERROR" "Solana CLI 安装失败"
            return 1
        fi
        
        log "SUCCESS" "Solana CLI 安装成功"
        
        # 配置 RPC 节点
        solana config set --url https://api.mainnet-beta.solana.com
    else
        log "INFO" "Solana CLI 已安装"
    fi
    return 0
}

# 进度条显示
show_progress() {
    local current=$1
    local total=$2
    local width=50
    local percentage=$((current * 100 / total))
    local completed=$((width * current / total))
    local remaining=$((width - completed))
    
    printf "\r[%s%s] %d%%" \
        "$(printf '#%.0s' $(seq 1 $completed))" \
        "$(printf ' %.0s' $(seq 1 $remaining))" \
        "$percentage"
}

# 测试网络质量
test_network_quality() {
    local ip=$1
    local count=5
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

# 识别数据中心
identify_datacenter() {
    local ip=$1
    local dc_info=""
    local location=""
    
    # 使用 ASN 查询
    local asn_info=$(whois -h whois.cymru.com " -v $ip" 2>/dev/null)
    if [ $? -eq 0 ]; then
        local asn_org=$(echo "$asn_info" | tail -n1 | awk -F'|' '{print $6}' | xargs)
        [ -n "$asn_org" ] && dc_info="$asn_org"
    fi
    
    # 使用 whois 查询位置信息
    local whois_info=$(whois "$ip" 2>/dev/null)
    if [ $? -eq 0 ]; then
        local country=$(echo "$whois_info" | grep -i "country:" | head -1 | cut -d':' -f2 | xargs)
        local city=$(echo "$whois_info" | grep -i "city:" | head -1 | cut -d':' -f2 | xargs)
        [ -n "$city" ] && location="$city"
        [ -n "$country" ] && location="${location:+$location, }$country"
    fi
    
    echo "${dc_info:-Unknown}|${location:-Unknown}"
}

# 获取验证者信息
get_validators() {
    log "INFO" "正在获取验证者信息..."
    
    # 尝试使用 solana gossip
    local validators=$(solana gossip 2>/dev/null)
    if [ $? -ne 0 ]; then
        log "ERROR" "无法通过 solana gossip 获取验证者信息"
        return 1
    fi
    
    # 提取IP地址
    local ips=$(echo "$validators" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | sort -u)
    if [ -z "$ips" ]; then
        log "ERROR" "未找到有效的验证者IP地址"
        return 1
    fi
    
    echo "$ips"
    return 0
}

# 分析验证者节点
analyze_validators() {
    log "INFO" "开始分析验证者节点分布"
    
    # 获取验证者列表
    local validator_ips=$(get_validators)
    if [ $? -ne 0 ]; then
        return 1
    fi
    
    # 清空结果文件
    > "${RESULTS_FILE}"
    
    # 计算总数
    local total=$(echo "$validator_ips" | wc -l)
    local current=0
    
    log "INFO" "找到 ${total} 个唯一的验证者节点"
    echo -e "\n${YELLOW}正在分析节点位置信息...${NC}"
    
    echo "$validator_ips" | while read -r ip; do
        ((current++))
        show_progress $current $total
        
        # 获取数据中心信息
        local dc_info=$(identify_datacenter "$ip")
        local dc_name=$(echo "$dc_info" | cut -d'|' -f1)
        local dc_location=$(echo "$dc_info" | cut -d'|' -f2)
        
        # 测试网络质量
        local network_stats=$(test_network_quality "$ip")
        local latency=$(echo "$network_stats" | cut -d'|' -f2)
        
        # 保存结果
        echo "$ip|$dc_name|$dc_location|$latency" >> "${RESULTS_FILE}"
    done
    
    echo -e "\n"
    log "SUCCESS" "分析完成"
    generate_report
}

# 生成报告
generate_report() {
    echo -e "\n${BLUE}=== Solana 验证者节点分布报告 ===${NC}"
    echo "分析时间: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "------------------------------------------------"
    
    # 数据中心分布统计
    echo -e "\n${YELLOW}数据中心分布${NC}"
    echo "------------------------------------------------"
    awk -F'|' '{print $2}' "${RESULTS_FILE}" | sort | uniq -c | sort -rn | head -10 | while read count dc; do
        printf "%-40s : %3d 个节点\n" "$dc" "$count"
    done
    
    # 最优部署位置
    echo -e "\n${GREEN}最优部署位置 (按延迟排序)${NC}"
    echo "------------------------------------------------"
    printf "%-15s %-30s %-30s %-10s\n" "IP地址" "数据中心" "位置" "延迟(ms)"
    echo "------------------------------------------------"
    
    sort -t'|' -k4 -n "${RESULTS_FILE}" | head -10 | while IFS='|' read -r ip dc location latency; do
        if [ "$latency" != "timeout" ]; then
            printf "%-15s %-30s %-30s %-10.2f\n" "$ip" "$dc" "$location" "$latency"
        fi
    done
    
    # 部署建议
    echo -e "\n${BLUE}部署建议${NC}"
    echo "------------------------------------------------"
    
    # 找出最集中的数据中心
    local top_dc=$(awk -F'|' '{print $2}' "${RESULTS_FILE}" | sort | uniq -c | sort -rn | head -1)
    local dc_name=$(echo "$top_dc" | awk '{$1=""; print $0}' | xargs)
    local dc_count=$(echo "$top_dc" | awk '{print $1}')
    
    echo "1. 主要验证者集群："
    echo "   - 数据中心: $dc_name"
    echo "   - 验证者数量: $dc_count"
    
    # 该数据中心的最佳节点
    local best_node=$(grep "$dc_name" "${RESULTS_FILE}" | sort -t'|' -k4 -n | head -1)
    local best_ip=$(echo "$best_node" | cut -d'|' -f1)
    local best_latency=$(echo "$best_node" | cut -d'|' -f4)
    
    echo -e "\n2. 推荐部署位置："
    echo "   - 优选数据中心: $dc_name"
    echo "   - 参考节点: $best_ip"
    echo "   - 预期延迟: ${best_latency}ms"
    
    echo -e "\n3. 部署建议："
    echo "   - 建议优先在 $dc_name 寻找机位"
    echo "   - 确保与参考节点 $best_ip 在同一网段"
    echo "   - 建议部署前进行多次延迟测试"
    echo "   - 考虑在次优数据中心部署备份节点"
}

# 显示菜单
show_menu() {
    echo -e "\n${BLUE}Solana 验证者节点位置分析工具${NC}"
    echo "=================================="
    echo "1. 分析验证者节点分布"
    echo "2. 测试指定IP的数据中心位置"
    echo "3. 查看最近的分析报告"
    echo "4. 导出分析结果"
    echo "0. 退出"
    echo "=================================="
    echo -ne "请选择操作 [0-4]: "
}

# 主函数
main() {
    # 检查root权限
    if [ "$EUID" -ne 0 ]; then 
        log "ERROR" "请使用root权限运行此脚本"
        exit 1
    }
    
    # 检查并安装基础依赖
    check_dependencies || exit 1
    
    # 安装 Solana CLI
    install_solana_cli || exit 1
    
    while true; do
        show_menu
        read choice
        
        case $choice in
            1) analyze_validators ;;
            2) read -p "请输入要测试的IP地址: " test_ip
               if [[ $test_ip =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                   dc_info=$(identify_datacenter "$test_ip")
                   echo -e "\n数据中心信息: $dc_info"
               else
                   log "ERROR" "无效的IP地址"
               fi
               read -p "按回车键继续..." ;;
            3) if [ -f "${RESULTS_FILE}" ]; then
                   generate_report
               else
                   log "ERROR" "没有找到分析报告"
               fi
               read -p "按回车键继续..." ;;
            4) if [ -f "${RESULTS_FILE}" ]; then
                   local output_file="solana_validators_$(date +%Y%m%d_%H%M%S).txt"
                   cp "${RESULTS_FILE}" "./${output_file}"
                   log "SUCCESS" "分析结果已导出到: ${output_file}"
               else
                   log "ERROR" "没有找到分析结果"
               fi
               read -p "按回车键继续..." ;;
            0) log "INFO" "感谢使用！"
               exit 0 ;;
            *) log "ERROR" "无效选择，请重试"
               sleep 1 ;;
        esac
    done
}

# 启动程序
main
