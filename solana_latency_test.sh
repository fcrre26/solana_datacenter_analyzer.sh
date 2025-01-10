#!/bin/bash

# 设置环境变量
SOLANA_INSTALL_DIR="/root/.local/share/solana/install"
export PATH="$SOLANA_INSTALL_DIR/active_release/bin:$PATH"

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
            "INFO")    echo -e "${BLUE}${INFO} ${message}${NC}" ;;
            "ERROR")   echo -e "${RED}${ERROR} ${message}${NC}" ;;
            "SUCCESS") echo -e "${GREEN}${SUCCESS} ${message}${NC}" ;;
            "WARN")    echo -e "${YELLOW}${WARN} ${message}${NC}" ;;
            *) echo -e "${message}" ;;
        esac
    fi
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
    local progress_msg="[$current/$total] ${progress}% - 测试: $ip (延迟: ${latency}ms, 位置: $location)"
    
    if [ "${BACKGROUND_MODE:-false}" = "true" ]; then
        echo "$progress_msg" >> "${BACKGROUND_LOG}"
    else
        echo -ne "\r${BLUE}${progress_msg}${NC}"
    fi
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
        echo "# Solana 验证者节点延迟分析报告"
        echo "生成时间: $(date '+%Y-%m-%d %H:%M:%S')"
        echo
        
        echo "## 延迟统计 (Top 20)"
        echo "| IP地址 | 位置 | 延迟(ms) | 供应商 |"
        echo "|---------|------|-----------|---------|"
        
        sort -t'|' -k4 -n "${RESULTS_FILE}" | head -20 | while IFS='|' read -r ip provider location latency; do
            if [ "$latency" != "999" ]; then
                printf "| %s | %s | %s | %s |\n" "$ip" "${location:-Unknown}" "$latency" "${provider:-Unknown}"
            fi
        done
        
        echo
        echo "## 供应商分布"
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
        echo "## 位置分布"
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
        echo "---"
        echo "* 延迟测试使用 TCP 连接时间"
        echo "* 测试端口: 8899(RPC), 8900(Gossip)"
        echo "* 报告版本: ${VERSION}"
        
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
    
    echo -e "\n测试 IP: $ip"
    echo "===================="
    
    local latency=$(test_network_quality "$ip")
    local dc_info=$(identify_datacenter "$ip")
    local provider=$(echo "$dc_info" | cut -d'|' -f1)
    local location=$(echo "$dc_info" | cut -d'|' -f2)
    
    echo "延迟: ${latency}ms"
    echo "位置: $location"
    echo "供应商: $provider"
    echo "===================="
}

# 检查后台任务状态
check_background_task() {
    if [ -f "${BACKGROUND_LOG}" ]; then
        echo -e "\n${BLUE}后台任务状态：${NC}"
        echo "===================="
        tail -n 10 "${BACKGROUND_LOG}"
        echo "===================="
        
        if grep -q "分析完成" "${BACKGROUND_LOG}"; then
            echo -e "\n${GREEN}任务已完成！${NC}"
        else
            echo -e "\n${YELLOW}任务正在运行中...${NC}"
        fi
    else
        echo -e "\n${YELLOW}没有运行中的后台任务${NC}"
    fi
}

# 主菜单
show_menu() {
    echo -e "\n${BLUE}Solana 验证者节点延迟分析工具 ${VERSION}${NC}"
    echo "=================================="
    echo "1. 分析所有验证者节点延迟"
    echo "2. 在后台分析所有节点"
    echo "3. 测试指定IP的延迟"
    echo "4. 查看最新分析报告"
    echo "5. 查看后台任务状态"
    echo "0. 退出"
    echo "=================================="
    echo -ne "请选择操作 [0-5]: "
}

# 主函数
main() {
    if [ "$EUID" -ne 0 ]; then 
        log "ERROR" "请使用root权限运行此脚本"
        exit 1
    fi
    
    if [ "$1" = "background" ]; then
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
            3)  echo -ne "\n请输入要测试的IP地址: "
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
