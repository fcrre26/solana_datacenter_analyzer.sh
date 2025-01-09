#!/bin/bash

<<'COMMENT'
Solana 验证者节点部署分析工具 v1.2
专注于寻找超低延迟(≤1ms)部署位置，精确到0.001ms

【运行环境要求】
- 操作系统: Ubuntu 20.04+ / Debian 11+
- CPU: 2核+
- 内存: 4GB+
- 硬盘: 20GB+ 可用空间
- 网络: 稳定的互联网连接，无带宽限制
- 权限: 需要 root 权限

【使用方法】
1. 确保系统满足上述要求
2. 添加执行权限: chmod +x solana_datacenter_analyzer.sh
3. 使用root运行: sudo ./solana_datacenter_analyzer.sh

【工作流程】
1. 分析当前 VPS 的网络环境
2. 扫描所有 Solana 验证者节点
3. 进行高精度延迟测试(精确到0.001ms)
4. 重点识别低延迟(≤1ms)的节点
5. 查找目标节点附近的可用数据中心
6. 提供具体的部署建议

【注意事项】
- 首次运行需要安装依赖工具，可能需要5-10分钟
- 分析过程可能持续10-30分钟，取决于网络状况
- 建议在不同时段多次运行，以获得更准确的结果
- 某些云服务商的信息可能因API限制无法获取
- 结果仅供参考，实际部署时还需考虑成本等因素

【输出结果】
- 超低延迟验证者节点列表（精确到0.001ms）
- 相关数据中心信息
- 网络路径分析
- 具体部署建议

【作者】
Created by: Claude
Version: 1.2
Last Updated: 2024-01-20

【使用许可】
MIT License
仅供学习研究使用，请勿用于商业用途
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

# 检查运行环境
check_environment() {
    echo -e "${BLUE}=== 正在检查运行环境 ===${NC}"
    local has_warning=false
    
    # 检查操作系统
    if ! grep -q "Ubuntu\|Debian" /etc/os-release; then
        echo -e "${WARNING_ICON} ${YELLOW}警告: 推荐使用 Ubuntu 20.04+ 或 Debian 11+${NC}"
        has_warning=true
    fi
    
    # 检查CPU核心数
    cpu_cores=$(nproc)
    if [ "$cpu_cores" -lt 2 ]; then
        echo -e "${WARNING_ICON} ${YELLOW}警告: CPU核心数小于推荐值(2核)${NC}"
        has_warning=true
    fi
    
    # 检查内存
    total_mem=$(free -m | awk '/^Mem:/{print $2}')
    if [ "$total_mem" -lt 4000 ]; then
        echo -e "${WARNING_ICON} ${YELLOW}警告: 内存小于推荐值(4GB)${NC}"
        has_warning=true
    fi
    
    # 检查磁盘空间
    free_space=$(df -m / | awk 'NR==2 {print $4}')
    if [ "$free_space" -lt 20000 ]; then
        echo -e "${WARNING_ICON} ${YELLOW}警告: 可用磁盘空间小于推荐值(20GB)${NC}"
        has_warning=true
    fi
    
    # 检查网络连接
    if ! ping -c 1 google.com >/dev/null 2>&1; then
        echo -e "${WARNING_ICON} ${YELLOW}警告: 网络连接可能不稳定${NC}"
        has_warning=true
    fi
    
    # 检查root权限
    if [ "$EUID" -ne 0 ]; then 
        echo -e "${RED}错误: 请使用root权限运行此脚本${NC}"
        exit 1
    fi

    # 如果有警告，询问用户是否继续
    if [ "$has_warning" = true ]; then
        echo -e "\n${YELLOW}检测到系统可能不满足推荐配置要求。${NC}"
        read -p "是否仍要继续？(y/n) " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            echo "已取消执行。"
            exit 1
        fi
    else
        echo -e "${GREEN}✓ 系统环境检查通过${NC}"
    fi
}

# 云服务提供商IP范围和数据中心信息
declare -A CLOUD_PROVIDERS=(
    # 主流云服务商
    ["AWS"]="https://ip-ranges.amazonaws.com/ip-ranges.json"
    ["Azure"]="https://download.microsoft.com/download/7/1/D/71D86715-5596-4529-9B13-DA13A5DE5B63/ServiceTags_Public_20231127.json"
    ["GCP"]="https://www.gstatic.com/ipranges/cloud.json"
    ["Alibaba"]="https://raw.githubusercontent.com/alibaba/alibaba-cloud-ip-ranges/main/ip-ranges.json"
    ["Oracle"]="https://docs.oracle.com/en-us/iaas/tools/public_ip_ranges.json"
    ["IBM"]="https://cloud.ibm.com/network-security/ip-ranges"
)

# 数据中心信息
declare -A DATACENTERS=(
    # 北美地区
    ["Ashburn"]="Equinix DC1-DC15|Digital Realty ACC1-ACC4|CoreSite VA1-VA2"
    ["Santa Clara"]="Equinix SV1-SV17|Digital Realty SCL1-SCL3|CoreSite SV1-SV8"
    ["New York"]="Equinix NY1-NY9|Digital Realty NYC1-NYC3|CoreSite NY1-NY2"
    
    # 亚太地区
    ["Tokyo"]="Equinix TY1-TY12|@Tokyo CC1-CC2|NTT Communications"
    ["Singapore"]="Equinix SG1-SG5|Digital Realty SIN1-SIN3|NTT SIN1"
    ["Hong Kong"]="Equinix HK1-HK5|MEGA-i|SUNeVision"
    
    # 欧洲地区
    ["London"]="Equinix LD1-LD8|Digital Realty LHR1-LHR3|Telehouse"
    ["Frankfurt"]="Equinix FR1-FR7|Digital Realty FRA1-FRA3|Interxion"
    ["Amsterdam"]="Equinix AM1-AM8|Digital Realty AMS1-AMS3|Nikhef"
)

# 安装必要工具
install_requirements() {
    echo "正在安装必要工具..."
    apt-get update
    apt-get install -y curl mtr traceroute bc jq whois geoip-bin dnsutils hping3 iperf3

    # 创建临时目录存储IP范围数据
    mkdir -p /tmp/cloud_ranges
    
    # 下载云服务提供商的IP范围数据
    echo "正在更新云服务提供商IP范围数据..."
    for provider in "${!CLOUD_PROVIDERS[@]}"; do
        local url="${CLOUD_PROVIDERS[$provider]}"
        local file="/tmp/cloud_ranges/${provider,,}.json"
        curl -s "$url" > "$file" 2>/dev/null || echo "无法下载 $provider 的IP范围数据"
    done

    # 安装 Solana CLI 如果没有安装的话
    if ! command -v solana &> /dev/null; then
        echo "安装 Solana CLI..."
        sh -c "$(curl -sSfL https://release.solana.com/stable/install)"
        export PATH="/root/.local/share/solana/install/active_release/bin:$PATH"
        echo 'export PATH="/root/.local/share/solana/install/active_release/bin:$PATH"' >> ~/.bashrc
    fi
}

# 优化的延迟测试函数
test_connection() {
    local ip=$1
    local results=""
    local min_latency=999.999
    
    echo -e "${YELLOW}正在进行高精度延迟测试: $ip${NC}"
    
    # 使用 hping3 进行高精度延迟测试
    for i in {1..10}; do
        # -i u100 设置每次发包间隔为100微秒，提高精度
        local hping_result=$(sudo hping3 -c 1 -S -p 80 -i u100 $ip 2>/dev/null | grep "rtt" | cut -d '/' -f 4)
        if [ ! -z "$hping_result" ]; then
            results="$results $hping_result"
            # 更新最小延迟，使用 bc 保持精度
            if (( $(echo "$hping_result < $min_latency" | bc -l) )); then
                min_latency=$hping_result
            fi
        fi
        sleep 0.2
    done
    
    # 计算平均延迟，保持精度
    local avg_latency=$(echo "$results" | tr ' ' '\n' | awk '{ total += $1; count++ } END { printf "%.3f", total/count }')
    
    # 计算抖动（延迟标准差）
    local jitter=$(echo "$results" | tr ' ' '\n' | awk -v avg=$avg_latency '
        BEGIN { sum = 0; count = 0; }
        { sum += ($1 - avg)^2; count++; }
        END { printf "%.3f", sqrt(sum/count) }
    ')
    
    # 获取路由信息
    local mtr_result=$(mtr -n -c 1 -r $ip 2>/dev/null | tail -1 | awk '{printf "%.3f", $3}')
    local hop_count=$(mtr -n -c 1 -r $ip 2>/dev/null | wc -l)
    
    echo "$min_latency|$avg_latency|$jitter|$mtr_result|$hop_count"
}


# 查找附近可用的数据中心
find_nearby_datacenters() {
    local city=$1
    local country=$2
    local found=false
    
    echo -e "\n${BLUE}附近可用数据中心:${NC}"
    
    # 检查预定义的数据中心信息
    for dc_city in "${!DATACENTERS[@]}"; do
        if [[ "$city" == *"$dc_city"* ]] || [[ "$dc_city" == *"$city"* ]]; then
            IFS='|' read -ra dc_list <<< "${DATACENTERS[$dc_city]}"
            for dc in "${dc_list[@]}"; do
                echo -e "${DC_ICON} $dc"
                echo -e "   └─ 城市: $dc_city"
                echo -e "   └─ 联系方式: https://www.${dc%%[0-9]*}.com/contact"
                echo -e "   └─ 机柜预估价格: $(get_datacenter_price "$dc")"
            done
            found=true
        fi
    done
    
    if [ "$found" = false ]; then
        echo -e "${WARNING_ICON} 未找到预定义的数据中心信息，尝试在线查询..."
        local nearby_dcs=$(curl -s "https://api.datacentermap.com/v1/datacenters/near/$city,$country" 2>/dev/null)
        if [ ! -z "$nearby_dcs" ]; then
            echo "$nearby_dcs" | jq -r '.[] | "     • \(.name) (\(.provider))"'
        else
            echo "     • 请手动查询该地区的数据中心：https://www.datacentermap.com"
        fi
    fi
}

# 获取数据中心预估价格
get_datacenter_price() {
    local dc=$1
    case "$dc" in
        *"Equinix"*)
            echo "机柜: $2000-3500/月, 带宽: $500-1000/Mbps/月"
            ;;
        *"Digital Realty"*)
            echo "机柜: $1800-3000/月, 带宽: $400-900/Mbps/月"
            ;;
        *"CoreSite"*)
            echo "机柜: $1500-2800/月, 带宽: $300-800/Mbps/月"
            ;;
        *)
            echo "价格需要询问"
            ;;
    esac
}

# 获取本机信息
get_local_info() {
    echo -e "\n${BLUE}=== 本机网络环境信息 ===${NC}"
    local_ip=$(curl -s ifconfig.me)
    local_geo=$(curl -s "https://ipinfo.io/$local_ip/json")
    
    echo -e "${INFO_ICON} IP地址: $local_ip"
    echo -e "${INFO_ICON} 位置: $(echo $local_geo | jq -r '.city + ", " + .country')"
    echo -e "${INFO_ICON} ISP: $(echo $local_geo | jq -r '.org')"
    
    # 测试基础网络性能
    echo -e "\n${BLUE}基础网络性能测试:${NC}"
    echo -e "${NETWORK_ICON} MTU: $(ip link show | grep mtu | head -1 | grep -oP 'mtu \K\d+')"
    echo -e "${NETWORK_ICON} TCP BBR: $(sysctl net.ipv4.tcp_congestion_control | cut -d ' ' -f 3)"
    
    # 显示网络接口速率
    echo -e "${NETWORK_ICON} 网络接口速率:"
    for interface in $(ls /sys/class/net/); do
        if [ "$interface" != "lo" ]; then
            speed=$(cat /sys/class/net/$interface/speed 2>/dev/null)
            if [ ! -z "$speed" ]; then
                echo "   └─ $interface: ${speed}Mbps"
            fi
        fi
    done
}

# 识别云服务提供商和数据中心
identify_provider() {
    local ip=$1
    local whois_info=$(whois $ip 2>/dev/null)
    local asn_info=$(curl -s "https://ipinfo.io/$ip/org")
    local provider="Unknown"
    local datacenter="Unknown"
    local region="Unknown"

    # 检查所有云服务提供商
    for provider_name in "${!CLOUD_PROVIDERS[@]}"; do
        if echo "$whois_info" | grep -qi "$provider_name"; then
            provider=$provider_name
            case $provider_name in
                "AWS")
                    region=$(curl -s "https://ip-ranges.amazonaws.com/ip-ranges.json" | \
                            jq -r ".prefixes[] | select(.ip_prefix == \"$ip/32\" or contains(\"$ip\")) | .region")
                    ;;
                "Azure")
                    region=$(curl -s "${CLOUD_PROVIDERS[$provider_name]}" | \
                            jq -r ".values[] | select(.properties.region != null) | .properties.region")
                    ;;
                "GCP")
                    region=$(curl -s "${CLOUD_PROVIDERS[$provider_name]}" | \
                            jq -r ".prefixes[] | select(.ipv4prefix != null) | .scope")
                    ;;
            esac
            break
        fi
    done

        # 检查数据中心特征
    local dc_indicators=$(echo "$whois_info" | grep -i "data center\|colocation\|hosting\|idc")
    if [ ! -z "$dc_indicators" ]; then
        datacenter=$(echo "$dc_indicators" | head -1)
    fi

    # 使用 ASN 信息补充
    if [ "$provider" == "Unknown" ]; then
        provider=$(echo "$asn_info" | cut -d' ' -f1)
    fi

    # 获取更详细的地理位置信息
    local geo_info=$(curl -s "https://ipinfo.io/$ip/json")
    local city=$(echo "$geo_info" | jq -r '.city // "Unknown"')
    local country=$(echo "$geo_info" | jq -r '.country // "Unknown"')
    local org=$(echo "$geo_info" | jq -r '.org // "Unknown"')

    echo "$provider|$region|$datacenter|$city|$country|$org"
}

# 分析验证者节点
analyze_validators() {
    echo -e "${YELLOW}正在获取验证者节点信息...${NC}"
    local validators=$(solana gossip --url https://api.mainnet-beta.solana.com 2>/dev/null)
    local results_file="/tmp/validator_analysis.txt"
    > $results_file

    echo -e "\n${BLUE}=== 正在分析验证者节点部署情况 ===${NC}"
    echo -e "特别关注延迟低于1ms的节点...\n"
    
    # 获取并分析验证者IP
    local total_validators=0
    local low_latency_count=0
    
    echo "$validators" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | while read ip; do
        echo -e "${YELLOW}分析节点: $ip${NC}"
        
        local connection_info=$(test_connection $ip)
        local min_latency=$(echo "$connection_info" | cut -d'|' -f1)
        local avg_latency=$(echo "$connection_info" | cut -d'|' -f2)
        local jitter=$(echo "$connection_info" | cut -d'|' -f3)
        local mtr_latency=$(echo "$connection_info" | cut -d'|' -f4)
        local hop_count=$(echo "$connection_info" | cut -d'|' -f5)
        local provider_info=$(identify_provider $ip)
        
        # 记录结果
        echo "$ip|$min_latency|$avg_latency|$jitter|$mtr_latency|$hop_count|$provider_info" >> $results_file
        ((total_validators++))
        
        # 实时显示低延迟节点
        if (( $(echo "$min_latency <= 1" | bc -l) )); then
            ((low_latency_count++))
            echo -e "${GREEN}发现低延迟节点！${NC}"
            echo -e "IP: $ip"
            echo -e "最小延迟: ${min_latency}ms"
            echo -e "平均延迟: ${avg_latency}ms"
            echo -e "抖动: ${jitter}ms"
            echo -e "跳数: $hop_count"
        fi
    done

    # 显示低延迟节点详细信息
    echo -e "\n${BLUE}=== 低延迟验证者节点 (≤1ms) ===${NC}"
    echo -e "IP地址            延迟(ms)    平均(ms)   抖动(ms)   提供商        数据中心"
    echo -e "   └─ 延迟精确到0.001ms"
    echo -e "------------------------------------------------------------------------"

    sort -t'|' -k2 -n "$results_file" | while IFS='|' read -r ip min_lat avg_lat jitter mtr_lat hops provider region datacenter city country org; do
        if (( $(echo "$min_lat <= 1" | bc -l) )); then
            printf "${GREEN}%-15s %8.3f %8.3f %8.3f  %-13s %-14s${NC}\n" \
                "$ip" "$min_lat" "$avg_lat" "$jitter" "$provider" "$datacenter"
            
            # 显示详细信息
            echo -e "  └─ 位置: $city, $country"
            echo -e "  └─ 网络: $org"
            echo -e "  └─ 跳数: $hops"
            
            # 延迟评级
            if (( $(echo "$min_lat < 0.1" | bc -l) )); then
                echo -e "  └─ 延迟评级: ${GREEN}极佳 (低于0.1ms)${NC}"
            elif (( $(echo "$min_lat < 0.3" | bc -l) )); then
                echo -e "  └─ 延迟评级: ${GREEN}优秀 (低于0.3ms)${NC}"
            elif (( $(echo "$min_lat < 0.5" | bc -l) )); then
                echo -e "  └─ 延迟评级: ${GREEN}良好 (低于0.5ms)${NC}"
            else
                echo -e "  └─ 延迟评级: ${YELLOW}一般 (0.5-1.0ms)${NC}"
            fi
            
            # 查找附近可用的数据中心
            find_nearby_datacenters "$city" "$country"
            echo -e "----------------------------------------"
        fi
    done

    # 生成建议
    echo -e "\n${YELLOW}=== 部署建议 ===${NC}"
    echo -e "要达到1ms以内的延迟，建议："
    echo -e "1. ${CHECK_ICON} 选择与验证者节点相同的数据中心"
    echo -e "2. ${CHECK_ICON} 如果选择不同数据中心，确保："
    echo -e "   └─ 在同一园区内"
    echo -e "   └─ 使用同一个网络服务商"
    echo -e "   └─ 通过专线或直连方式连接"
    echo -e "3. ${CHECK_ICON} 网络配置建议："
    echo -e "   └─ 使用10Gbps+网络接口"
    echo -e "   └─ 开启网卡优化（TSO, GSO, GRO）"
    echo -e "   └─ 使用TCP BBR拥塞控制"
    echo -e "   └─ 调整系统网络参数"
    
    # 保存报告
    local report_file="/tmp/validator_deployment_report.txt"
    {
        echo "=== Solana 验证者节点部署分析报告 ==="
        echo "生成时间: $(date)"
        echo "分析节点总数: $total_validators"
        echo "低延迟节点数(≤1ms): $low_latency_count"
        echo ""
        echo "详细分析结果已保存到: $results_file"
    } > "$report_file"
}

# 显示主菜单
show_menu() {
    clear
    echo -e "${BLUE}=== Solana 验证者节点分析工具 ===${NC}"
    echo -e "${YELLOW}【首次使用请先选择 1 进行初始化和完整分析】${NC}"
    echo
    echo -e "${YELLOW}1.${NC} 运行完整分析 (包含初始化和依赖安装)"
    echo -e "${YELLOW}2.${NC} 显示所有验证者节点清单"
    echo -e "${YELLOW}3.${NC} 查看最近的分析结果"
    echo -e "${YELLOW}4.${NC} 查看特定IP的详细信息"
    echo -e "${YELLOW}5.${NC} 导出分析报告"
    echo -e "${YELLOW}6.${NC} 系统环境检查"
    echo -e "${YELLOW}7.${NC} 查看帮助信息"
    echo -e "${YELLOW}0.${NC} 退出"
    echo
    echo -e "当前状态:"
    if [ -f "/tmp/validator_analysis.txt" ]; then
        echo -e "${GREEN}✓${NC} 已有分析结果"
        echo -e "   └─ 最后分析时间: $(stat -c %y /tmp/validator_analysis.txt | cut -d. -f1)"
    else
        echo -e "${RED}✗${NC} 暂无分析结果 ${YELLOW}请先选择选项 1 运行完整分析${NC}"
    fi
    echo
}

# 显示验证者清单
show_validators_list() {
    echo -e "\n${BLUE}=== Solana 验证者节点清单 ===${NC}"
    echo -e "正在获取验证者信息..."
    
    local validators=$(solana gossip --url https://api.mainnet-beta.solana.com 2>/dev/null)
    local total=0
    local output_file="/tmp/validators_list.txt"
    
    echo -e "IP地址            身份标识        投票账户        状态        版本" > "$output_file"
    echo -e "----------------------------------------------------------------" >> "$output_file"
    
    echo "$validators" | while read -r line; do
        if [[ $line =~ ([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+):([0-9]+)[[:space:]]+([A-Za-z0-9]+)[[:space:]]+([A-Za-z0-9]+) ]]; then
            local ip="${BASH_REMATCH[1]}"
            local port="${BASH_REMATCH[2]}"
            local identity="${BASH_REMATCH[3]}"
            local vote_account="${BASH_REMATCH[4]}"
            local status="活跃"
            local version=$(echo "$line" | grep -oP "version: \K[0-9\.]+")
            
            printf "%-15s %-14s %-14s %-10s %-8s\n" \
                "$ip" "${identity:0:12}.." "${vote_account:0:12}.." "$status" "${version:-未知}" >> "$output_file"
            ((total++))
        fi
    done
    
    echo -e "\n共找到 $total 个验证者节点"
    echo -e "按 q 退出查看\n"
    less -R "$output_file"
}

# 主函数
main() {
    echo -e "${BLUE}=== 开始 Solana 验证者节点部署分析 ===${NC}"
    
    # 检查运行环境
    check_environment
    
    # 获取本机信息
    get_local_info
    
    # 安装必要工具
    install_requirements
    
    # 分析验证者节点
    analyze_validators
    
    echo -e "\n${GREEN}分析完成！${NC}"
    echo -e "${INFO_ICON} 详细分析结果已保存到 /tmp/validator_analysis.txt"
    echo -e "${INFO_ICON} 完整报告已保存到 /tmp/validator_deployment_report.txt"
}

# 主菜单函数
menu_main() {
    while true; do
        show_menu
        read -p "请选择功能 (0-7): " choice
        case $choice in
            1) 
                echo -e "\n${BLUE}=== 开始初始化和完整分析 ===${NC}"
                main  # 调用原来的main函数执行完整分析
                ;;
            2) 
                if [ ! -f "/tmp/validator_analysis.txt" ]; then
                    echo -e "${RED}错误: 请先运行选项 1 进行完整分析${NC}"
                else
                    show_validators_list
                fi
                ;;
            3) 
                if [ ! -f "/tmp/validator_analysis.txt" ]; then
                    echo -e "${RED}错误: 请先运行选项 1 进行完整分析${NC}"
                else
                    echo -e "\n${BLUE}=== 分析结果 ===${NC}"
                    less "/tmp/validator_analysis.txt"
                fi
                ;;
            4)
                if [ ! -f "/tmp/validator_analysis.txt" ]; then
                    echo -e "${RED}错误: 请先运行选项 1 进行完整分析${NC}"
                else
                    read -p "请输入要查看的IP地址: " ip
                    grep "^$ip" "/tmp/validator_analysis.txt" | less
                fi
                ;;
            5) 
                if [ ! -f "/tmp/validator_analysis.txt" ]; then
                    echo -e "${RED}错误: 请先运行选项 1 进行完整分析${NC}"
                else
                    local report_file="$HOME/solana_analysis_$(date +%Y%m%d_%H%M%S).txt"
                    cp /tmp/validator_analysis.txt "$report_file"
                    echo "报告已导出到: $report_file"
                fi
                ;;
            6) check_environment ;;
            7)
                echo -e "${BLUE}=== 帮助信息 ===${NC}"
                echo -e "${YELLOW}首次使用必须先运行选项 1 进行初始化和完整分析！${NC}"
                echo
                echo "1. 运行完整分析: 初始化系统并进行完整的延迟测试"
                echo "2. 显示验证者清单: 列出所有活跃的验证者节点"
                echo "3. 查看分析结果: 显示最近一次的分析结果"
                echo "4. 查看IP详情: 查看特定IP的详细信息"
                echo "5. 导出报告: 将分析结果导出到文件"
                echo "6. 环境检查: 检查系统运行环境"
                echo "0. 退出程序"
                ;;
            0) 
                echo "感谢使用！"
                exit 0
                ;;
            *) echo "无效选择" ;;
        esac
        
        echo -e "\n按回车键继续..."
        read
    done
}

# 启动程序
menu_main
