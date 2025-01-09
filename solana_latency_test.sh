#!/bin/bash

# 启用严格模式
set -euo pipefail

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
VERSION="v1.2.3"

# 创建必要的目录
mkdir -p "${TEMP_DIR}" "${REPORT_DIR}" "${BACKUP_DIR}"

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

# 生成报告
generate_report() {
    local report_file=$1
    local total_nodes=$(wc -l < "${RESULTS_FILE}")
    
    {
        echo "# Solana 验证者节点分布报告"
        echo "生成时间: $(date '+%Y-%m-%d %H:%M:%S')"
        echo "分析节点总数: ${total_nodes}"
        echo
        
        echo "## 数据中心分布 (Top 10)"
        echo "| 数据中心 | 节点数量 | 占比 |"
        echo "|----------|----------|------|"
        
        awk -F'|' -v total="$total_nodes" '
            {dc[$2]++}
            END {
                for (d in dc) {
                    percentage = dc[d] / total * 100
                    printf "| %-30s | %4d | %.1f%% |\n", d, dc[d], percentage
                }
            }
        ' "${RESULTS_FILE}" | sort -rn -k4 | head -10
        
        echo
        echo "## 地理分布 (Top 10)"
        echo "| 地区 | 节点数量 | 占比 |"
        echo "|------|----------|------|"
        
        awk -F'|' -v total="$total_nodes" '
            {loc[$3]++}
            END {
                for (l in loc) {
                    percentage = loc[l] / total * 100
                    printf "| %-30s | %4d | %.1f%% |\n", l, loc[l], percentage
                }
            }
        ' "${RESULTS_FILE}" | sort -rn -k4 | head -10
        
        echo
        echo "## 网络质量统计"
        echo "- 最低延迟: $(awk -F'|' '$4!="timeout" {print $4}' "${RESULTS_FILE}" | sort -n | head -1) ms"
        echo "- 最高延迟: $(awk -F'|' '$4!="timeout" {print $4}' "${RESULTS_FILE}" | sort -n | tail -1) ms"
        echo "- 平均延迟: $(awk -F'|' '$4!="timeout" {sum+=$4; count++} END {printf "%.2f", sum/count}' "${RESULTS_FILE}") ms"
        echo "- 超时比例: $(awk -F'|' '$4=="timeout" {count++} END {printf "%.1f%%", count/NR*100}' "${RESULTS_FILE}")"
        
        # 添加延迟分布统计
        echo
        echo "## 延迟分布"
        echo "| 延迟范围 | 节点数量 | 占比 |"
        echo "|----------|----------|------|"
        
        awk -F'|' -v total="$total_nodes" '
            $4!="timeout" {
                if ($4 < 50) range["<50ms"]++
                else if ($4 < 100) range["50-100ms"]++
                else if ($4 < 200) range["100-200ms"]++
                else if ($4 < 300) range["200-300ms"]++
                else range[">300ms"]++
            }
            END {
                for (r in range) {
                    percentage = range[r] / total * 100
                    printf "| %-10s | %8d | %5.1f%% |\n", r, range[r], percentage
                }
            }
        ' "${RESULTS_FILE}" | sort -t'|' -k1

                echo
        echo "## 部署建议"
        echo "1. 优选部署区域："
        
        # 获取最佳部署区域
        local best_regions=$(awk -F'|' '
            $4!="timeout" {
                loc[$3] += 1
                latency[$3] += $4
                if (!min_latency[$3] || $4 < min_latency[$3]) min_latency[$3] = $4
            }
            END {
                for (l in loc) {
                    avg = latency[l] / loc[l]
                    printf "%s|%d|%.2f|%.2f\n", l, loc[l], avg, min_latency[l]
                }
            }
        ' "${RESULTS_FILE}" | sort -t'|' -k3n | head -3)
        
        echo "   - 主要区域：$(echo "$best_regions" | head -1 | cut -d'|' -f1)"
        echo "   - 备选区域：$(echo "$best_regions" | tail -n +2 | cut -d'|' -f1 | tr '\n' '、')"
        
        echo
        echo "2. 推荐数据中心："
        local best_dcs=$(awk -F'|' '
            $4!="timeout" {
                dc[$2] += 1
                if (!min_latency[$2] || $4 < min_latency[$2]) min_latency[$2] = $4
            }
            END {
                for (d in dc) {
                    printf "%s|%d|%.2f\n", d, dc[d], min_latency[d]
                }
            }
        ' "${RESULTS_FILE}" | sort -t'|' -k3n | head -3)
        
        while IFS='|' read -r dc count latency; do
            echo "   - $dc"
        done <<< "$best_dcs"
        
        echo
        echo "3. 网络要求："
        echo "   - 建议选择延迟<50ms的区域"
        echo "   - 确保带宽≥1Gbps"
        echo "   - 建议配置冗余网络链路"
        
        echo
        echo "4. 高可用性建议："
        echo "   - 主节点：部署在最优延迟区域"
        echo "   - 备份节点：部署在次优区域"
        echo "   - 建议采用多区域部署策略"
        
        echo
        echo "## 风险提示"
        echo "1. 集中度风险："
        local max_dc_percentage=$(awk -F'|' -v total="$total_nodes" '
            {dc[$2]++}
            END {
                max_p = 0
                for (d in dc) {
                    p = dc[d] / total * 100
                    if (p > max_p) max_p = p
                }
                printf "%.1f", max_p
            }
        ' "${RESULTS_FILE}")
        
        echo "   - 最大数据中心占比 ${max_dc_percentage}%"
        echo "   - 建议考虑地理分散部署"
        
        echo
        echo "2. 网络风险："
        echo "   - $(awk -F'|' '$4=="timeout" {count++} END {printf "%.1f%%", count/NR*100}' "${RESULTS_FILE}")的节点存在连接性问题"
        echo "   - 建议避免部署在高延迟区域"
        
        echo
        echo "3. 成本考虑："
        echo "   - 主流云服务商成本较高，可考虑其他性价比方案"
        echo "   - 建议预留 50% 带宽余量"
        
        echo
        echo "## 监控建议"
        echo "1. 关键指标："
        echo "   - 网络延迟"
        echo "   - 投票性能"
        echo "   - 系统资源使用率"
        echo "   - 节点同步状态"
        
        echo
        echo "2. 告警阈值："
        echo "   - 延迟 > 100ms"
        echo "   - 丢包率 > 1%"
        echo "   - CPU 使用率 > 80%"
        echo "   - 内存使用率 > 85%"
        
        echo
        echo "---"
        echo "报告生成时间: $(date '+%Y-%m-%d %H:%M:%S')"
        echo "分析工具版本: ${VERSION}"
        
    } > "$report_file"
    
    log "SUCCESS" "报告已生成: $report_file"
}

# 后台运行分析
run_background_analysis() {
    if [ -f "$LOCK_FILE" ]; then
        log "ERROR" "已有分析任务在运行中"
        return 1
    fi
    
    touch "$LOCK_FILE"
    log "INFO" "开始后台分析任务..."
    
    (
        echo "开始后台分析 - $(date)" > "${BACKGROUND_LOG}"
        analyze_validators >> "${BACKGROUND_LOG}" 2>&1
        
        local timestamp=$(date +%Y%m%d_%H%M%S)
        local report_file="${REPORT_DIR}/report_${timestamp}.txt"
        generate_report "${report_file}"
        
        ln -sf "${report_file}" "${LATEST_REPORT}"
        backup_data
        
        echo "分析完成 - $(date)" >> "${BACKGROUND_LOG}"
        rm -f "$LOCK_FILE"
    ) &

    local pid=$!
    log "SUCCESS" "后台分析任务已启动 (PID: $pid)"
    echo -e "\n您可以通过以下方式查看进度："
    echo "1. 使用命令: tail -f ${BACKGROUND_LOG}"
    echo "2. 在主菜单选择'3'进入报告管理"
    echo "3. 在报告管理中选择'5'查看任务状态"
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
    generate_report "${LATEST_REPORT}"
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
        echo "0. 退出"
        echo "=================================="
        echo -ne "请选择操作 [0-4]: "
        
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
            0) log "INFO" "感谢使用！"
               exit 0 ;;
            *) log "ERROR" "无效选择，请重试"
               sleep 1 ;;
        esac
    done
}

# 启动程序
main
