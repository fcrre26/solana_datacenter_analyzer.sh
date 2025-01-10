#!/bin/bash

# 设置环境变量
SOLANA_INSTALL_DIR="/root/.local/share/solana/install"
export PATH="$SOLANA_INSTALL_DIR/active_release/bin:$PATH"

# 启用严格模式
set -eo pipefail

# 颜色定义
GREEN='\033[0;32m'      # 绿色
RED='\033[0;31m'        # 红色
YELLOW='\033[1;33m'     # 黄色
CYAN='\033[0;36m'       # 青色
WHITE='\033[1;37m'      # 亮白色
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
    clear  # 清屏，让显示更整洁
    echo -e "\n${GREEN}▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄${NC}"
    echo -e "${GREEN}█       Solana 验证者节点延迟分析工具       █${NC}"
    echo -e "${GREEN}█                ${WHITE}版本: ${VERSION}${GREEN}                █${NC}"
    echo -e "${GREEN}▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀${NC}"
    echo -e ""
    echo -e "${GREEN}╔════════════════ 功能菜单 ═══════════════╗${NC}"
    echo -e "${GREEN}║                                         ║${NC}"
    echo -e "${GREEN}║  ${WHITE}1${GREEN}. ${WHITE}分析所有验证者节点延迟             ${GREEN}║${NC}"
    echo -e "${GREEN}║  ${WHITE}2${GREEN}. ${WHITE}在后台分析所有节点                 ${GREEN}║${NC}"
    echo -e "${GREEN}║  ${WHITE}3${GREEN}. ${WHITE}测试指定IP的延迟                   ${GREEN}║${NC}"
    echo -e "${GREEN}║  ${WHITE}4${GREEN}. ${WHITE}查看最新分析报告                   ${GREEN}║${NC}"
    echo -e "${GREEN}║  ${WHITE}5${GREEN}. ${WHITE}查看后台任务状态                   ${GREEN}║${NC}"
    echo -e "${GREEN}║  ${RED}0${GREEN}. ${RED}退出程序                           ${GREEN}║${NC}"
    echo -e "${GREEN}║                                         ║${NC}"
    echo -e "${GREEN}╚═════════════════════════════════════════╝${NC}"
    echo -e ""
    echo -ne "${GREEN}请输入您的选择 ${WHITE}[0-5]${GREEN}: ${NC}"
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
        
        local whois_info
        whois_info=$(whois "$ip" 2>/dev/null)
        local country
        country=$(echo "$whois_info" | grep -i "country:" | head -1 | cut -d':' -f2 | xargs)
        local city
        city=$(echo "$whois_info" | grep -i "city:" | head -1 | cut -d':' -f2 | xargs)
        
        local location=""
        [ -n "$city" ] && location="$city"
        [ -n "$country" ] && location="${location:+$location, }$country"
        
        echo "${asn_org:-Unknown}|${location:-Unknown}"
    else
        echo "Unknown|Unknown"
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

# 更新进度显示
update_progress() {
    local current="$1"
    local total="$2"
    local ip="$3"
    local latency="$4"
    local location="$5"
    
    local progress=$((current * 100 / total))
    
    # 根据延迟值设置颜色
    local latency_color
    local latency_display
    if [ "$latency" = "999" ]; then
        latency_color=$RED
        latency_display="超时"
    elif [ "$latency" -lt 100 ]; then
        latency_color=$GREEN
        latency_display="${latency}ms"
    else
        latency_color=$YELLOW
        latency_display="${latency}ms"
    fi
    
    # 进度条
    local bar_size=20
    local completed=$((progress * bar_size / 100))
    local remaining=$((bar_size - completed))
    local progress_bar=""
    for ((i=0; i<completed; i++)); do progress_bar+="█"; done
    for ((i=0; i<remaining; i++)); do progress_bar+="░"; done
    
    # 格式化进度显示
    printf "\r${GREEN}[%s] %3d%%${NC} | ${CYAN}%-15s${NC} | 延迟: ${latency_color}%-8s${NC} | 位置: ${WHITE}%-20s${NC}" \
        "$progress_bar" "$progress" "$ip" "$latency_display" "${location:-Unknown}"
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
        echo "| IP地址 | 位置 | 延迟(ms) | 供应商 |"
        echo "|---------|------|-----------|---------|"
        
        sort -t'|' -k4 -n "${RESULTS_FILE}" | head -20 | while IFS='|' read -r ip provider location latency; do
            if [ "$latency" != "999" ]; then
                printf "| %s | %s | %s | %s |\n" "$ip" "${location:-Unknown}" "$latency" "${provider:-Unknown}"
            fi
        done
        
        echo
        echo -e "${GREEN}## 供应商分布${NC}"
        echo "| 供应商 | 节点数量 | 平均延迟(ms) |"
        echo "|---------|------------|--------------|"
        
        awk -F'|' '$4!=999 {
            count[$2]++
            latency_sum[$2]+=$4
        }
        END {
            for (provider in count) {
                printf "| %s | %d | %.2f |\n", 
                    provider, 
                    count[provider], 
                    latency_sum[provider]/count[provider]
            }
        }' "${RESULTS_FILE}" | sort -t'|' -k3 -n
        
        echo
        echo -e "${GREEN}## 位置分布${NC}"
        echo "| 位置 | 节点数量 | 平均延迟(ms) |"
        echo "|------|------------|--------------|"
        
        awk -F'|' '$4!=999 {
            count[$3]++
            latency_sum[$3]+=$4
        }
        END {
            for (location in count) {
                printf "| %s | %d | %.2f |\n", 
                    location, 
                    count[location], 
                    latency_sum[location]/count[location]
            }
        }' "${RESULTS_FILE}" | sort -t'|' -k3 -n

        echo
        echo -e "${GREEN}## 部署建议${NC}"
        echo "根据延迟测试结果，以下是推荐的部署方案（按优先级排序）："
        echo
        echo "### 最优部署方案"
        echo "| 供应商 | 数据中心位置 | IP网段 | 平均延迟 | 测试IP | 测试延迟 |"
        echo "|---------|--------------|--------|-----------|---------|----------|"
        
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
                printf "| %s | %s | %s | %.2fms | %s | %dms |\n", 
                    parts[1],    # 供应商
                    parts[2],    # 位置
                    parts[3],    # 网段
                    avg_latency, # 平均延迟
                    best_ip[key],# 测试IP
                    min_latency[key] # 最低延迟
            }
        }' "${RESULTS_FILE}" | sort -t'|' -k4 -n | head -5
        
        echo
        echo "### 部署建议详情"
        echo
        echo "1. 优选部署方案"
        echo "   - 推荐供应商: Tencent Cloud, AWS, Alibaba Cloud"
        echo "   - 推荐地区: Singapore, Tokyo, Seoul"
        echo "   - 网络要求: 公网带宽 ≥ 100Mbps"
        echo "   - 预期延迟: 10-30ms"
        echo
        echo "2. 备选部署方案"
        echo "   - 备选供应商: DigitalOcean, Google Cloud"
        echo "   - 备选地区: Hong Kong, Frankfurt"
        echo "   - 网络要求: 公网带宽 ≥ 100Mbps"
        echo "   - 预期延迟: 30-50ms"
        echo
        echo "3. 硬件配置建议"
        echo "   - CPU: 16核心及以上"
        echo "   - 内存: 32GB及以上"
        echo "   - 存储: 1TB NVMe SSD"
        echo "   - 操作系统: Ubuntu 20.04/22.04 LTS"
        echo
        echo "4. 网络优化建议"
        echo "   - 启用 TCP BBR 拥塞控制"
        echo "   - 优化系统网络参数"
        echo "   - 配置合适的防火墙规则"
        echo "   - 确保 8899-8900 端口可访问"
        echo
        echo "5. 注意事项"
        echo "   - 建议选择延迟低于 50ms 的节点位置"
        echo "   - 优先考虑网络稳定性好的供应商"
        echo "   - 建议在多个地区部署备份节点"
        echo "   - 定期监控网络性能"
        echo
        echo "6. 成本估算（月）"
        echo "   - 主流云服务商: $200-500"
        echo "   - 带宽费用: $100-300"
        echo "   - 存储费用: $50-150"
        echo "   - 总计: $350-950"

        echo
        echo "---"
        echo "* 延迟测试使用 TCP 连接时间"
        echo "* 测试端口: 8899(RPC), 8900(Gossip)"
        echo "* 报告版本: ${VERSION}"
        echo "* 生成时间: $(date '+%Y-%m-%d %H:%M:%S')"
        
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
    local deps=("curl" "nc" "whois" "awk" "sort")
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
    
    echo -e "\n${GREEN}╔════════════════ IP测试 ═════════════════╗${NC}"
    echo -e "${GREEN}║                                         ║${NC}"
    echo -e "${GREEN}║  ${WHITE}测试IP: ${CYAN}%-30s${GREEN}║${NC}" "$ip"
    
    local latency=$(test_network_quality "$ip")
    local dc_info=$(identify_datacenter "$ip")
    local provider=$(echo "$dc_info" | cut -d'|' -f1)
    local location=$(echo "$dc_info" | cut -d'|' -f2)
    
    # 根据延迟值设置颜色
    local latency_color
    if [ "$latency" = "999" ]; then
        latency_color=$RED
        latency="超时"
    elif [ "$latency" -lt 100 ]; then
        latency_color=$GREEN
    else
        latency_color=$YELLOW
    fi
    
    echo -e "${GREEN}║  ${WHITE}延迟: ${latency_color}%-30s${GREEN}║${NC}" "${latency}ms"
    echo -e "${GREEN}║  ${WHITE}位置: ${WHITE}%-30s${GREEN}║${NC}" "$location"
    echo -e "${GREEN}║  ${WHITE}供应商: ${CYAN}%-28s${GREEN}║${NC}" "$provider"
    echo -e "${GREEN}║                                         ║${NC}"
    echo -e "${GREEN}╚═════════════════════════════════════════╝${NC}"
}

# 检查后台任务状态
check_background_task() {
    if [ -f "${BACKGROUND_LOG}" ]; then
        echo -e "\n${GREEN}╔═══════════════ 任务状态 ════════════════╗${NC}"
        echo -e "${GREEN}║                                         ║${NC}"
        
        if grep -q "分析完成" "${BACKGROUND_LOG}"; then
            echo -e "${GREEN}║  ${WHITE}状态: ${GREEN}已完成                          ${GREEN}║${NC}"
        else
            echo -e "${GREEN}║  ${WHITE}状态: ${YELLOW}运行中                          ${GREEN}║${NC}"
        fi
        
        echo -e "${GREEN}║                                         ║${NC}"
        echo -e "${GREEN}║  ${WHITE}最新进度:                              ${GREEN}║${NC}"
        tail -n 5 "${BACKGROUND_LOG}" | while read -r line; do
            printf "${GREEN}║  ${WHITE}%-39s${GREEN}║${NC}\n" "$line"
        done
        
        echo -e "${GREEN}║                                         ║${NC}"
        echo -e "${GREEN}╚═════════════════════════════════════════╝${NC}"
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
