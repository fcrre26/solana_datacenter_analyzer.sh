#!/bin/bash

<<'COMMENT'
Solana 验证者节点部署分析工具 v1.0

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
3. 识别验证者节点的部署位置和服务商
4. 计算网络延迟和路由质量
5. 提供最优部署位置建议

【注意事项】
- 首次运行需要安装依赖工具，可能需要5-10分钟
- 分析过程可能持续10-30分钟，取决于网络状况
- 建议在不同时段多次运行，以获得更准确的结果
- 某些云服务商的信息可能因API限制无法获取
- 结果仅供参考，实际部署时还需考虑成本等因素

【输出结果】
- 验证者节点分布统计
- 云服务商使用情况
- 数据中心分布
- 网络延迟分析
- 具体部署建议

【作者】
Created by: Claude
Version: 1.0
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

# 检查运行环境
check_environment() {
    echo "正在检查运行环境..."
    
    # 检查操作系统
    if ! grep -q "Ubuntu\|Debian" /etc/os-release; then
        echo "警告: 推荐使用 Ubuntu 20.04+ 或 Debian 11+"
    fi
    
    # 检查CPU核心数
    cpu_cores=$(nproc)
    if [ "$cpu_cores" -lt 2 ]; then
        echo "警告: CPU核心数小于推荐值(2核)"
    fi
    
    # 检查内存
    total_mem=$(free -m | awk '/^Mem:/{print $2}')
    if [ "$total_mem" -lt 4000 ]; then
        echo "警告: 内存小于推荐值(4GB)"
    fi
    
    # 检查磁盘空间
    free_space=$(df -m / | awk 'NR==2 {print $4}')
    if [ "$free_space" -lt 20000 ]; then
        echo "警告: 可用磁盘空间小于推荐值(20GB)"
    fi
    
    # 检查网络连接
    if ! ping -c 1 google.com >/dev/null 2>&1; then
        echo "警告: 网络连接可能不稳定"
    fi
    
    # 检查root权限
    if [ "$EUID" -ne 0 ]; then 
        echo "错误: 请使用root权限运行此脚本"
        exit 1
    fi
}
# 云服务提供商IP范围和数据中心信息
declare -A CLOUD_PROVIDERS=(
    # 主流云服务商
    ["AWS"]="https://ip-ranges.amazonaws.com/ip-ranges.json"
    ["Azure"]="https://download.microsoft.com/download/7/1/D/71D86715-5596-4529-9B13-DA13A5DE5B63/ServiceTags_Public_20231127.json"
    ["GCP"]="https://www.gstatic.com/ipranges/cloud.json"
    ["Alibaba"]="https://raw.githubusercontent.com/alibaba/alibaba-cloud-ip-ranges/main/ip-ranges.json"
    
    # 其他大型云服务商
    ["Oracle"]="https://docs.oracle.com/en-us/iaas/tools/public_ip_ranges.json"
    ["IBM"]="https://cloud.ibm.com/network-security/ip-ranges"
    ["Tencent"]="https://ip-ranges.tencentcloud.com/ip-ranges.json"
    ["Huawei"]="https://ip-ranges.huaweicloud.com/ip-ranges.json"
    
    # 专业主机服务商
    ["DigitalOcean"]="https://digitalocean.com/geo/google.csv"
    ["Vultr"]="https://api.vultr.com/v2/regions"
    ["Linode"]="https://api.linode.com/v4/regions"
    ["OVH"]="https://ip-ranges.ovh.net/ip-ranges.json"
    ["Hetzner"]="https://ipv4.hetzner.com/ip-ranges.json"
    
    # 专业数据中心
    ["Equinix"]="https://ip-ranges.equinix.com"
    ["EdgeConneX"]="https://www.edgeconnex.com/locations"
    ["CyrusOne"]="https://cyrusone.com/data-center-locations"
    ["NTT"]="https://www.ntt.com/en/services/network/gin/ip-addresses.html"
    
    # 亚洲数据中心
    ["SingTel"]="https://singtel.com/data-centres"
    ["KDDI"]="https://global.kddi.com/business/data-center"
    ["ChinaMobile"]="https://www.chinamobileltd.com/en/business/int_dc.php"
    ["ChinaTelecom"]="https://www.chinatelecomglobal.com/products/idc"
    
    # 欧洲数据中心
    ["InterXion"]="https://www.interxion.com/data-centres"
    ["GlobalSwitch"]="https://www.globalswitch.com/locations"
    ["Telehouse"]="https://www.telehouse.net/data-centers"
    
    # 美洲数据中心
    ["CoreSite"]="https://www.coresite.com/data-centers"
    ["QTS"]="https://www.qtsdatacenters.com/data-centers"
    ["Switch"]="https://www.switch.com/data-centers"
)

# 安装必要工具
install_requirements() {
    echo "正在安装必要工具..."
    apt-get update
    apt-get install -y curl mtr traceroute bc jq whois geoip-bin dnsutils

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

# 获取本机信息
get_local_info() {
    local_ip=$(curl -s ifconfig.me)
    local_geo=$(geoiplookup $local_ip 2>/dev/null)
    echo -e "${BLUE}本机信息:${NC}"
    echo -e "IP: $local_ip"
    echo -e "位置: $local_geo"
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
        case $provider_name in
            "AWS")
                if echo "$whois_info" | grep -qi "amazon"; then
                    provider="AWS"
                    region=$(curl -s "https://ip-ranges.amazonaws.com/ip-ranges.json" | \
                            jq -r ".prefixes[] | select(.ip_prefix == \"$ip/32\" or contains(\"$ip\")) | .region")
                fi
                ;;
            "Azure")
                if echo "$whois_info" | grep -qi "microsoft"; then
                    provider="Azure"
                    region=$(curl -s "${CLOUD_PROVIDERS[$provider_name]}" | \
                            jq -r ".values[] | select(.properties.region != null) | .properties.region")
                fi
                ;;
            "GCP")
                if echo "$whois_info" | grep -qi "google"; then
                    provider="Google Cloud"
                    region=$(curl -s "${CLOUD_PROVIDERS[$provider_name]}" | \
                            jq -r ".prefixes[] | select(.ipv4prefix != null) | .scope")
                fi
                ;;
            *)
                if echo "$whois_info" | grep -qi "$provider_name"; then
                    provider=$provider_name
                    region=$(echo "$whois_info" | grep -i "location\|region\|city" | head -1 | cut -d':' -f2)
                fi
                ;;
        esac
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

# 测试连接质量
test_connection() {
    local ip=$1
    local ping_result=$(ping -c 3 $ip 2>/dev/null | tail -1 | awk '{print $4}' | cut -d '/' -f 2)
    local mtr_result=$(mtr -n -c 1 -r $ip 2>/dev/null | tail -1 | awk '{print $3}')
    echo "${ping_result:-999}|${mtr_result:-999}"
}

# 显示数据中心统计信息
show_datacenter_stats() {
    local results_file=$1
    echo -e "\n${BLUE}=== 数据中心和云服务提供商分布 ===${NC}"
    
    # 统计提供商分布
    declare -A provider_stats
    declare -A region_stats
    declare -A datacenter_stats
    
    while IFS='|' read -r ip latency provider region datacenter city country org; do
        ((provider_stats[$provider]++))
        ((region_stats[$region]++))
        ((datacenter_stats[$datacenter]++))
    done < "$results_file"

    # 显示提供商统计
    echo -e "\n${YELLOW}云服务提供商分布:${NC}"
    for provider in "${!provider_stats[@]}"; do
        local count=${provider_stats[$provider]}
        local total=$(wc -l < "$results_file")
        local percentage=$(echo "scale=2; $count * 100 / $total" | bc)
        printf "${CLOUD_ICON} %-25s: %3d 节点 (%5.2f%%)\n" "$provider" "$count" "$percentage"
    done

    # 显示区域统计
    echo -e "\n${YELLOW}区域分布:${NC}"
    for region in "${!region_stats[@]}"; do
        local count=${region_stats[$region]}
        local total=$(wc -l < "$results_file")
        local percentage=$(echo "scale=2; $count * 100 / $total" | bc)
        printf "🌎 %-25s: %3d 节点 (%5.2f%%)\n" "$region" "$count" "$percentage"
    done

    # 显示数据中心统计
    echo -e "\n${YELLOW}数据中心分布:${NC}"
    for datacenter in "${!datacenter_stats[@]}"; do
        if [ "$datacenter" != "Unknown" ]; then
            local count=${datacenter_stats[$datacenter]}
            local total=$(wc -l < "$results_file")
            local percentage=$(echo "scale=2; $count * 100 / $total" | bc)
            printf "🏢 %-25s: %3d 节点 (%5.2f%%)\n" "$datacenter" "$count" "$percentage"
        fi
    done
}

# 分析验证者节点
analyze_validators() {
    echo -e "${YELLOW}正在获取验证者节点信息...${NC}"
    local validators=$(solana gossip --url https://api.mainnet-beta.solana.com 2>/dev/null)
    local results_file="/tmp/validator_analysis.txt"
    > $results_file

    echo -e "\n${BLUE}=== 正在分析验证者节点部署情况 ===${NC}"
    
    # 获取并分析验证者IP
    local total_validators=0
    echo "$validators" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | while read ip; do
        echo -e "${YELLOW}分析节点: $ip${NC}"
        
        local connection_info=$(test_connection $ip)
        local latency=$(echo "$connection_info" | cut -d'|' -f1)
        local mtr_latency=$(echo "$connection_info" | cut -d'|' -f2)
        local provider_info=$(identify_provider $ip)
        
        # 记录结果
        echo "$ip|$latency|$provider_info" >> $results_file
        ((total_validators++))
    done

      # 显示结果
    echo -e "\n${BLUE}=== 验证者节点分析结果 ===${NC}"
    echo -e "IP地址            延迟(ms)  提供商        区域           数据中心"
    echo -e "------------------------------------------------------------------------"

    # 排序并显示结果（按延迟排序）
    sort -t'|' -k2 -n "$results_file" | while IFS='|' read -r ip latency provider region datacenter city country org; do
        if (( $(echo "$latency < 50" | bc -l) )); then
            if (( $(echo "$latency < 1" | bc -l) )); then
                printf "${GREEN}%-15s %-8s %-13s %-14s %s${NC}\n" \
                    "$ip" "$latency" "$provider" "$region" "$datacenter"
            else
                printf "%-15s %-8s %-13s %-14s %s\n" \
                    "$ip" "$latency" "$provider" "$region" "$datacenter"
            fi
            
            # 显示详细地理信息
            echo -e "  └─ 位置: $city, $country"
            [ "$org" != "Unknown" ] && echo -e "  └─ 网络: $org"
        fi
    done

    # 显示统计信息
    show_datacenter_stats "$results_file"

    # 生成建议
    echo -e "\n${YELLOW}=== 部署建议 ===${NC}"
    echo "基于分析结果，推荐以下部署选择："
    
    # 找出最佳部署位置
    local best_locations=$(sort -t'|' -k2 -n "$results_file" | head -n 5)
    echo -e "\n最佳部署位置 (基于延迟和集中度):"
    echo "$best_locations" | while IFS='|' read -r ip latency provider region datacenter city country org; do
        echo -e "${CHECK_ICON} $provider - $region"
        echo "   位置: $city, $country"
        echo "   数据中心: $datacenter"
        echo "   延迟: ${latency}ms"
        echo "   网络: $org"
        echo ""
    done

    # 保存详细报告
    local report_file="/tmp/validator_deployment_report.txt"
    {
        echo "=== Solana 验证者节点部署分析报告 ==="
        echo "生成时间: $(date)"
        echo "分析节点总数: $total_validators"
        echo ""
        echo "详细分析结果已保存到: $results_file"
        echo "完整统计信息已保存到: $report_file"
    } > "$report_file"
}

# 主函数
main() {
    echo "开始 Solana 验证者节点部署分析..."
    
    # 显示脚本说明
    echo -e "${BLUE}=== Solana 验证者节点部署分析工具 ===${NC}"
    echo -e "${YELLOW}此工具将帮助您找到最优的验证者节点部署位置${NC}"
    echo -e "详细说明请查看脚本开头的注释\n"
    
    # 检查运行环境
    check_environment
    
    # 询问是否继续
    read -p "环境检查完成，是否继续？(y/n) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
    
    # 获取本机信息
    get_local_info
    
    # 安装必要工具
    install_requirements
    
    # 分析验证者节点
    analyze_validators
    
    echo -e "\n${YELLOW}分析完成！请根据以上信息选择合适的部署位置。${NC}"
    echo -e "${INFO_ICON} 详细分析结果已保存到 /tmp/validator_analysis.txt"
    echo -e "${INFO_ICON} 完整报告已保存到 /tmp/validator_deployment_report.txt"
}

# 运行主函数
main
