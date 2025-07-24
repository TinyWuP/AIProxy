# VictoriaMetrics 集成升级

## 概述

本项目已成功集成 VictoriaMetrics 时序数据库，提供更强大的统计分析和数据持久化能力。

## 新增功能

### 1. 数据持久化
- ✅ 统计数据自动持久化到 VictoriaMetrics
- ✅ 容器重启后数据不丢失
- ✅ 12个月数据保留期

### 2. 高级监控仪表板
- ✅ Grafana 专业仪表板
- ✅ 实时指标可视化
- ✅ 多维度数据分析
- ✅ 自动刷新和告警

### 3. 增强的API接口
- ✅ 基于 VictoriaMetrics 的统计API (`/stats`)
- ✅ 健康检查端点 (`/health/vm`)
- ✅ 兼容传统API (`/stats/legacy`)
- ✅ 优雅降级机制

## 部署指南

### 快速启动
```bash
# 运行部署脚本
./deploy_vm.sh
```

### 手动部署
```bash
# 1. 启动服务
docker-compose up -d

# 2. 验证服务状态
docker-compose ps

# 3. 查看日志
docker-compose logs victoriametrics
docker-compose logs grafana
```

## 访问地址

| 服务 | 地址 | 说明 |
|-----|------|------|
| 统计仪表板 | https://aiproxy.bwton.cn/dashboard | 原有HTML仪表板（支持VM数据） |
| Grafana | http://localhost:3000 | 专业监控仪表板 |
| VictoriaMetrics | http://localhost:8428 | 时序数据库管理界面 |
| JSON API | https://aiproxy.bwton.cn/stats | 统计数据API |
| 健康检查 | https://aiproxy.bwton.cn/health/vm | VictoriaMetrics连接状态 |

**默认账号:**
- Grafana: admin / admin123

## 指标说明

### 核心指标

| 指标名称 | 类型 | 说明 | 标签 |
|---------|------|------|------|
| `aiproxy_requests_total` | Counter | 请求总数 | channel, user_name, model, status, protocol |
| `aiproxy_response_time_seconds` | Histogram | 响应时间 | channel, model, protocol |
| `aiproxy_request_size_bytes` | Gauge | 请求大小 | channel, user_name |
| `aiproxy_response_size_bytes` | Gauge | 响应大小 | channel, user_name |
| `aiproxy_websocket_connections_total` | Counter | WebSocket连接数 | channel |
| `aiproxy_uptime_seconds` | Gauge | 系统运行时间 | - |
| `aiproxy_api_keys_total` | Gauge | API密钥数量 | - |

### 常用查询

```promql
# 5分钟请求速率
sum(rate(aiproxy_requests_total[5m]))

# 按渠道的成功率
sum(rate(aiproxy_requests_total{status="success"}[5m])) by (channel) / 
sum(rate(aiproxy_requests_total[5m])) by (channel) * 100

# P95响应时间
histogram_quantile(0.95, rate(aiproxy_response_time_seconds_bucket[5m]))

# Top 10 用户
topk(10, sum(increase(aiproxy_requests_total[1h])) by (user_key))
```

## 数据迁移和兼容性

### 兼容性保证
- ✅ 原有共享内存统计继续工作
- ✅ 传统API接口保持不变
- ✅ 原仪表板功能完全保留
- ✅ 优雅降级：VM不可用时自动使用内存数据

### 数据一致性
- 新旧统计数据并行运行
- VictoriaMetrics 作为主数据源
- 共享内存作为备用数据源

## 故障排除

### 常见问题

1. **VictoriaMetrics 连接失败**
   ```bash
   # 检查服务状态
   docker-compose logs victoriametrics
   
   # 测试连接
   curl http://localhost:8428/api/v1/query?query=up
   ```

2. **Grafana 无法访问**
   ```bash
   # 检查端口占用
   netstat -tulpn | grep 3000
   
   # 重启服务
   docker-compose restart grafana
   ```

3. **指标数据为空**
   ```bash
   # 检查指标收集
   curl https://aiproxy.bwton.cn/health/vm -k
   
   # 查看 nginx 日志
   docker-compose logs openresty
   ```

### 性能调优

1. **VictoriaMetrics 参数**
   ```yaml
   # 在 docker-compose.yml 中调整
   command:
     - '--retentionPeriod=12'      # 数据保留期
     - '--maxConcurrentInserts=16' # 并发插入数
     - '--maxInsertRequestSize=64MB' # 最大请求大小
   ```

2. **Grafana 优化**
   ```yaml
   environment:
     - GF_DATABASE_TYPE=postgres  # 使用PostgreSQL替代SQLite
     - GF_SESSION_PROVIDER=redis  # 使用Redis存储会话
   ```

## 下一步计划

- [ ] 添加更多业务指标（Token统计、费用分析）
- [ ] 实现告警规则和通知
- [ ] 支持多实例数据聚合
- [ ] 添加数据备份和恢复功能
- [ ] 集成分布式追踪

## 技术架构

```
┌─────────────────┐    ┌──────────────────┐    ┌─────────────────┐
│                 │    │                  │    │                 │
│   OpenResty     │───▶│  VictoriaMetrics │◀───│    Grafana      │
│                 │    │                  │    │                 │
│ ┌─────────────┐ │    │  ┌─────────────┐ │    │ ┌─────────────┐ │
│ │ vm_metrics  │ │    │  │    数据    │ │    │ │   仪表板    │ │
│ │    .lua     │ │    │  │    存储    │ │    │ │    可视化   │ │
│ └─────────────┘ │    │  └─────────────┘ │    │ └─────────────┘ │
│                 │    │                  │    │                 │
│ ┌─────────────┐ │    │  ┌─────────────┐ │    └─────────────────┘
│ │ 共享内存    │ │    │  │   PromQL    │ │              │
│ │ (备用)      │ │    │  │   查询引擎  │ │              │
│ └─────────────┘ │    │  └─────────────┘ │              │
│                 │    │                  │              │
└─────────────────┘    └──────────────────┘              │
         │                       │                       │
         │                       │                       │
         ▼                       ▼                       ▼
┌─────────────────────────────────────────────────────────────┐
│                    Docker Compose                          │
│                     统一管理                               │
└─────────────────────────────────────────────────────────────┘
```

---

*升级完成！现在您拥有企业级的监控和分析能力。*