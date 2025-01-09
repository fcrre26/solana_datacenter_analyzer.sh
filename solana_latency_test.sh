# 修改脚本开头的参数处理部分

# 启用严格模式
set -euo pipefail

# 处理命令行参数
if [ "${1:-}" = "--background-task" ]; then
    # 后台任务模式
    analyze_validators
    generate_report "${LATEST_REPORT}"
    backup_data
    exit 0
fi

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
LOCK_FILE="/tmp/solana_dc_finder.lock"
BACKUP_DIR="${REPORT_DIR}/backups"
BACKUP_FILE="${BACKUP_DIR}/latest_analysis.bak"
VERSION="v1.2.5"

# 创建必要的目录
mkdir -p "${TEMP_DIR}" "${REPORT_DIR}" "${BACKUP_DIR}"

# 格式化数字
format_number() {
    printf "%'d" $1
}

# 日志函数
log() {
    local level=$1
    shift
    local message="$*"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local line_info=""
    
    if [ "$level" = "ERROR" ]; then
        line_info=" (行号: ${BASH_LINENO[0]})"
    fi
    
    echo -e "${timestamp} [${level}]${line_info} ${message}" >> "${LOG_FILE}"
    
    case "$level" in
        "INFO")    echo -e "${BLUE}${INFO} ${message}${NC}" ;;
        "ERROR")   echo -e "${RED}${ERROR} ${message}${line_info}${NC}" ;;
        "SUCCESS") echo -e "${GREEN}${SUCCESS} ${message}${NC}" ;;
        "WARN")    echo -e "${YELLOW}${WARN} ${message}${NC}" ;;
        *) echo -e "${message}" ;;
    esac
}

# 清理函数
cleanup() {
    rm -f "$LOCK_FILE"
    log "INFO" "清理完成"
}

# 备份函数
backup_data() {
    if [ -f "${RESULTS_FILE}" ]; then
        cp "${RESULTS_FILE}" "${BACKUP_FILE}"
        log "INFO" "数据已备份到 ${BACKUP_FILE}"
    fi
}

# 恢复函数
restore_data() {
    if [ -f "${BACKUP_FILE}" ]; then
        cp "${BACKUP_FILE}" "${RESULTS_FILE}"
        log "INFO" "已从备份恢复数据"
        return 0
    fi
    return 1
}

# 检查依赖
check_dependencies() {
    local deps=("curl" "jq" "whois" "bc" "ping" "nohup")
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
        
        sh -c "$(curl -sSfL https://release.solana.com/stable/install)"
        export PATH="/root/.local/share/solana/install/active_release/bin:$PATH"
        
        if ! command -v solana &>/dev/null; then
            log "ERROR" "Solana CLI 安装失败"
            return 1
        fi
        
        log "SUCCESS" "Solana CLI 安装成功"
        solana config set --url https://api.mainnet-beta.solana.com
    else
        log "INFO" "Solana CLI 已安装"
    fi
    return 0
}

# 检查后台任务状态
check_background_task() {
    if [ -f "$LOCK_FILE" ]; then
        local pid=$(pgrep -f "solana_dc_finder.*--background-task" 2>/dev/null)
        if [ -n "$pid" ]; then
            echo "后台分析正在运行 (PID: $pid)"
            echo "最近的日志内容:"
            tail -n 10 "${BACKGROUND_LOG}"
        else
            echo "发现锁文件但进程不存在，可能是异常退出"
            echo "建议清理锁文件: rm -f ${LOCK_FILE}"
        fi
    else
        echo "没有正在运行的后台分析任务"
    fi
}

# 进度条显示
show_progress() {
    local current=$1
    local total=$2
    local width=50
    local percentage=$((current * 100 / total))
    local completed=$((width * current / total))
    
    # 清除当前行
    printf "\r"
    # 显示百分比和进度条
    printf "进度: [%-${width}s] %3d%%" "$(printf '#%.0s' $(seq 1 $completed))" "$percentage"
    # 强制输出
    printf "\e[0K"
}

# 测试网络质量
test_network_quality() {
    local ip=$1
    local count=5
    local interval=0.2
    local timeout=1
    local retries=3
    
    for ((i=1; i<=retries; i++)); do
        local result=$(ping -c $count -i $interval -W $timeout "$ip" 2>/dev/null)
        if [ $? -eq 0 ]; then
            local stats=$(echo "$result" | tail -1)
            local min=$(echo "$stats" | awk -F'/' '{print $4}')
            local avg=$(echo "$stats" | awk -F'/' '{print $5}')
            local max=$(echo "$stats" | awk -F'/' '{print $6}')
            local loss=$(echo "$result" | grep -oP '\d+(?=% packet loss)')
            
            if [[ "$min" =~ ^[0-9]+(\.[0-9]+)?$ ]] && \
               [[ "$avg" =~ ^[0-9]+(\.[0-9]+)?$ ]] && \
               [[ "$max" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
                echo "$min|$avg|$max|$loss"
                return 0
            fi
        fi
        sleep 1
    done
    
    log "WARN" "无法测试 IP ${ip} 的网络质量"
    echo "timeout|timeout|timeout|100"
    return 1
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
    if [ -f "$LOCK_FILE" ]; then
        log "ERROR" "已有分析任务在运行中"
        return 1
    fi
    
    touch "$LOCK_FILE"
    log "INFO" "开始后台分析任务..."
    
    # 使用 nohup 运行后台任务
    nohup bash -c '
        echo "开始后台分析 - $(date)" > "'${BACKGROUND_LOG}'"
        
        # 设置工作目录和环境变量
        export PATH="/root/.local/share/solana/install/active_release/bin:$PATH"
        cd "$(dirname "'${LOCK_FILE}'")"
        
        # 运行分析
        "'$(dirname "$0")"'/'"$(basename "$0")"' --background-task >> "'${BACKGROUND_LOG}'" 2>&1
        
        echo "分析完成 - $(date)" >> "'${BACKGROUND_LOG}'"
        rm -f "'${LOCK_FILE}'"
    ' > /dev/null 2>&1 &

    local pid=$!
    log "SUCCESS" "后台分析任务已启动 (PID: $pid)"
    echo -e "\n您可以通过以下方式查看进度："
    echo "1. 使用命令: tail -f ${BACKGROUND_LOG}"
    echo "2. 在主菜单选择'3'进入报告管理"
    echo "3. 在报告管理中选择'5'查看任务状态"
    echo "4. 使用命令: ps aux | grep solana_dc_finder"
    echo -e "\n按回车键返回主菜单..."
    read
}

# 分析验证者节点
analyze_validators() {
    log "INFO" "开始分析验证者节点分布"
    
    local validator_ips=$(get_validators)
    if [ $? -ne 0 ]; then
        return 1
    fi
    
    > "${RESULTS_FILE}"
    
    # 将IP列表保存到临时文件
    local tmp_ips_file="${TEMP_DIR}/tmp_ips.txt"
    echo "$validator_ips" > "$tmp_ips_file"
    
    local total=$(wc -l < "$tmp_ips_file")
    local current=0
    
    log "INFO" "找到 ${total} 个唯一的验证者节点"
    echo -e "\n${YELLOW}正在分析节点位置信息...${NC}"
    
    while read -r ip; do
        ((current++))
        show_progress $current $total
        
        local dc_info=$(identify_datacenter "$ip")
        local dc_name=$(echo "$dc_info" | cut -d'|' -f1)
        local dc_location=$(echo "$dc_info" | cut -d'|' -f2)
        
        local network_stats=$(test_network_quality "$ip")
        local latency=$(echo "$network_stats" | cut -d'|' -f2)
        
        echo "$ip|$dc_name|$dc_location|$latency" >> "${RESULTS_FILE}"
    done < "$tmp_ips_file"
    
    rm -f "$tmp_ips_file"
    
    echo -e "\n"
    log "SUCCESS" "分析完成"
    generate_report "${LATEST_REPORT}"
}

# 管理报告
manage_reports() {
    while true; do
        clear
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
            5) check_background_task
               read -p "按回车键继续..." ;;
            0) return ;;
            *) log "ERROR" "无效选择"
               sleep 1 ;;
        esac
    done
}

# 主函数
main() {
    # 检查root权限
    if [ "$EUID" -ne 0 ]; then 
        log "ERROR" "请使用root权限运行此脚本"
        exit 1
    fi
    
    # 添加信号处理
    trap 'echo -e "\n${RED}程序被中断${NC}"; cleanup; exit 1' INT TERM
    trap cleanup EXIT
    
    # 检查是否已在运行
    if [ -f "$LOCK_FILE" ]; then
        log "ERROR" "程序已在运行中"
        exit 1
    fi
    
    # 检查并安装基础依赖
    check_dependencies || exit 1
    
    # 安装 Solana CLI
    install_solana_cli || exit 1
    
    while true; do
        clear
        echo -e "\n${BLUE}Solana 验证者节点位置分析工具 ${VERSION}${NC}"
        echo "=================================="
        echo "1. 开始分析验证者节点分布"
        echo "2. 在后台运行分析"
        echo "3. 报告管理"
        echo "4. 测试指定IP的数据中心位置"
        echo "5. 查看后台任务状态"
        echo "0. 退出"
        echo "=================================="
        echo -ne "请选择操作 [0-5]: "
        
        read choice
        case $choice in
            1) analyze_validators ;;
            2) run_background_analysis ;;
            3) manage_reports ;;
            4) read -p "请输入要测试的IP地址: " test_ip
               if [[ $test_ip =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                   dc_info=$(identify_datacenter "$test_ip")
                   echo -e "\n数据中心信息: $dc_info"
                   network_stats=$(test_network_quality "$test_ip")
                   echo "网络延迟: $(echo "$network_stats" | cut -d'|' -f2) ms"
               else
                   log "ERROR" "无效的IP地址"
               fi
               read -p "按回车键继续..." ;;
            5) check_background_task
               read -p "按回车键继续..." ;;
            0) log "INFO" "感谢使用！"
               exit 0 ;;
            *) log "ERROR" "无效选择，请重试"
               sleep 1 ;;
        esac
    done
}

# 启动程序
main "$@"
