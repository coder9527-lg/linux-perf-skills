# 案例：用 tc netem 注入网络故障并观测 TCP 反应

## 目标

不依赖真实坏网络，用 Linux 自带的 `tc netem` 在容器网卡上精确注入
丢包、延迟、乱序、比特错误，练习对应观测手段。容器用最小 capability
（`NET_ADMIN` + `NET_RAW`）而非 `--privileged`，符合最小权限实践。

## 复现

```sh
make build && make run
make shell        # 进入容器，或直接用 make 目标

# 终端 A：持续 ping 观测
docker exec -it netem-lab ping -i0.2 8.8.8.8

# 终端 B：注入 30% 丢包
make loss
make observe      # qdisc 统计 + nstat 重传计数 + tcpretrans 实时事件
make clear        # 清理
```

## 四类故障与观测点

| 注入命令 | 现象 | 观测 |
|---|---|---|
| `netem loss 30%` | RTT 抖动、重传、吞吐跌 | `nstat` 的 TcpRetransSegs、`tcpretrans-bpfcc`、mtr |
| `netem delay 100ms 20ms` | 建连与首包变慢 | `curl -w` 分阶段计时、`tcpconnlat-bpfcc`、`tcprtt-bpfcc` |
| `netem delay 50ms reorder 25%` | 乱序触发 SACK/虚假重传 | `ss -ti` 的 reordering、抓包看 SACK |
| `netem corrupt 5%` | 校验失败丢包 | `ip -s link` 的 RX errors、抓包 |

## 关键判定

- **确认重传**：`nstat -az | grep TcpRetransSegs` 两次采样计数增长，是丢包的硬证据。
- **区分慢在哪一段**：
  ```sh
  curl -o /dev/null -sw 'dns:%{time_namelookup} connect:%{time_connect} ttfb:%{time_starttransfer} total:%{time_total}\n' <url>
  ```
  connect 大→网络/建连；ttfb 大→服务端处理。
- **连接级 TCP 详情**：`ss -ti` 输出 rtt、rttvar、cwnd、retrans、rcv_space。
- **内核视角丢包原因**：`tcpdrop-bpfcc`（比应用层报错更靠近根因）。

## 清理（重要）

netem 规则留在 qdisc 上会持续影响该网卡，实验结束必须 `make clear`，
或直接 `make stop` 销毁容器。生产环境操作前先 `tc qdisc show` 备份现状。
