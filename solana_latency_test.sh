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

# 目录和文件配置
TEMP_DIR="/tmp/solana_dc_finder"
LOG_FILE="${TEMP_DIR}/dc_finder.log"
RESULTS_FILE="${TEMP_DIR}/validator_locations.txt"
REPORT_DIR="$HOME/solana_reports"
LATEST_REPORT="${REPORT_DIR}/latest_report.txt"
BACKGROUND_LOG="${REPORT_DIR}/background.log"

# 创建必要的目录
mkdir -p "${TEMP_DIR}" "${REPORT_DIR}"

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
    
    local validators=$(solana gossip 2>/dev/null)
    if [ $? -ne 0 ]; then
        log "ERROR" "无法通过 solana gossip 获取验证者信息"
        return 1
    fi
    
    local ips=$(echo "$validators" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | sort -u)
    if [ -z "$ips" ]; then
        log "ERROR" "未找到有效的验证者IP地址"
        return 1
    fi
    
    echo "$ips"
    return 0
}

# 后台运行分析
run_background_analysis() {
    mkdir -p "${REPORT_DIR}"
    
    # 启动后台分析
    (
        echo "开始后台分析 - $(date)" > "${BACKGROUND_LOG}"
        analyze_validators >> "${BACKGROUND_LOG}" 2>&1
        
        # 保存报告
        local timestamp=$(date +%Y%m%d_%H%M%S)
        local report_file="${REPORT_DIR}/report_${timestamp}.txt"
        generate_report > "${report_file}"
        
        # 更新最新报告链接
        ln -sf "${report_file}" "${LATEST_REPORT}"
        
        echo "分析完成 - $(date)" >> "${BACKGROUND_LOG}"
    ) &
    
    echo "后台分析任务已启动 (PID: $!)"
    echo "可以通过以下命令查看进度："
    echo "tail -f ${BACKGROUND_LOG}"
}

# 报告管理
manage_reports() {
    while true; do
        echo -e "\n${BLUE}报告管理${NC}"
        echo "=================================="
        echo "1. 查看最新报告"
        echo "2. 列出所有报告"
        echo "3. 查看指定报告"
        echo "4. 删除旧报告"
        echo "5. 查看后台任务状态"
        echo "0. 返回主菜单"
        echo "=================================="
        
        read -p "请选择操作 [0-5]: " report_choice
        case $report_choice in
            1) if [ -f "${LATEST_REPORT}" ]; then
                   clear
                   cat "${LATEST_REPORT}"
                   read -p "按回车键继续..."
               else
                   log "ERROR" "没有找到最新报告"
                   sleep 2
               fi ;;
            2) echo -e "\n可用报告列表："
               ls -lh "${REPORT_DIR}"/report_*.txt 2>/dev/null | \
                   awk '{print NR". " $9 " (" $5 ")" }'
               read -p "按回车键继续..." ;;
            3) ls -1 "${REPORT_DIR}"/report_*.txt 2>/dev/null | \
                   awk '{print NR". " $0}'
               read -p "请输入报告编号: " report_num
               local report_file=$(ls -1 "${REPORT_DIR}"/report_*.txt 2>/dev/null | \
                   sed -n "${report_num}p")
               if [ -f "${report_file}" ]; then
                   clear
                   cat "${report_file}"
                   read -p "按回车键继续..."
               else
                   log "ERROR" "无效的报告编号"
                   sleep 2
               fi ;;
            4) find "${REPORT_DIR}" -name "report_*.txt" -mtime +7 -delete
               log "SUCCESS" "已删除7天前的报告"
               sleep 2 ;;
            5) if pgrep -f "analyze_validators" > /dev/null; then
                   echo "后台分析正在运行"
                   tail -n 10 "${BACKGROUND_LOG}"
               else
                   echo "没有正在运行的后台分析任务"
               fi
               read -p "按回车键继续..." ;;
            0) return ;;
            *) log "ERROR" "无效选择"
               sleep 1 ;;
        esac
    done
}

# 分析验证者节点
analyze_validators() {
    log "INFO" "开始分析验证者节点分布"
    
    local validator_ips=$(get_validators)
    if [ $? -ne 0 ]; then
        return 1
    fi
    
    > "${RESULTS_FILE}"
    
    local total=$(echo "$validator_ips" | wc -l)
    local current=0
    
    log "INFO" "找到 ${total} 个唯一的验证者节点"
    echo -e "\n${YELLOW}正在分析节点位置信息...${NC}"
    
    echo "$validator_ips" | while read -r ip; do
        ((current++))
        show_progress $current $total
        
        local dc_info=$(identify_datacenter "$ip")
        local dc_name=$(echo "$dc_info" | cut -d'|' -f1)
        local dc_location=$(echo "$dc_info" | cut -d'|' -f2)
        
        local network_stats=$(test_network_quality "$ip")
        local latency=$(echo "$network_stats" | cut -d'|' -f2)
        
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

# 显示主菜单
show_menu() {
    echo -e "\n${BLUE}Solana 验证者节点位置分析工具${NC}"
    echo "=================================="
    echo "1. 开始分析验证者节点分布"
    echo "2. 在后台运行分析"
    echo "3. 报告管理"
    echo "4. 测试指定IP的数据中心位置"
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
            2) run_background_analysis ;;
            3) manage_reports ;;
            4) read -p "请输入要测试的IP地址: " test_ip
               if [[ $test_ip =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                   dc_info=$(identify_datacenter "$test_ip")
                   echo -e "\n数据中心信息: $dc_info"
               else
                   log "ERROR" "无效的IP地址"
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
