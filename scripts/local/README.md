# 本地集群部署(自有 5 台机器,非 CloudLab)

自包含的本地部署脚本,**不依赖也不修改 `scripts/cloudlab/`**。针对扁平局域网、单网卡
的自有 Ubuntu 22.04 机器,建一个 k8s 集群并(可选)启用 Istio service-level 指标采集。

布局:5 台 = 1 控制节点(`nodes[0]`)+ 4 worker。一台**操作机**(笔记本即可,可在集群外)
负责 SSH 编排。

与 CloudLab 版的区别:无双网卡内网/公网分流,因此**不做 kubelet/flannel 网卡绑定**
(交给自动探测);无防火墙/SSH 加固/agent-forwarding;用共享密码配免密。

---

## 文件

| 文件 | 作用 |
|------|------|
| `config.json` | 填你的用户名 / 5 个 IP / home 路径 / 是否开 Istio |
| `bootstrap_local.sh` | 操作机上跑一次:配免密 SSH + NOPASSWD sudo(读 config.json) |
| `setup_kube.py` | 编排:建集群 +(可选)启用 Istio。从操作机运行 |
| `shell_helper.py` | SSH/scp helper(与 cloudlab 同一份,通用) |
| `kube.sh` | 每台:装 docker/kubeadm、关 swap、sysctl(无网卡绑定) |
| `init_kube.sh` | 控制节点:`kubeadm init`,API 广播在控制节点 IP |
| `after_join.sh` | 控制节点:kubeconfig + flannel + metrics-server |
| `enable_istio_metrics.sh` | 控制节点:istio + Prometheus + sidecar 注入(开关控制) |

---

## 步骤

### 1. 填 `config.json`

```json
{
    "nodes_user": "alice",
    "nodes": [
        "192.168.1.10",
        "192.168.1.11",
        "192.168.1.12",
        "192.168.1.13",
        "192.168.1.14"
    ],
    "nodes_home": "/home/alice",
    "enable_istio_metrics": true
}
```
`nodes[0]` 必须是控制节点。`enable_istio_metrics` 设 `false` 可只建集群、不装 Istio。

### 2. 配免密(操作机上跑一次)

```bash
cd scripts/local
./bootstrap_local.sh        # 读 config.json,提示输入共享密码,自动配好 5 台
```

### 3. 建集群

```bash
python3 setup_kube.py
```
依次:5 台装 docker/kubeadm → 控制节点 `kubeadm init` → 4 台 join → flannel +
metrics-server → (若开)Istio + Prometheus + sidecar 注入。

### 4. 部署 benchmark + 压测

复用仓库根的 benchmark 流程(`scripts/cloudlab/deploy.sh` 走普通 ssh,可指向本地控制节点):

```bash
cd ../cloudlab
CONTROL_HOST=192.168.1.10 SSH_USER=alice ./deploy.sh boutique --run
```
或在控制节点上手动 `kubectl apply -f k8s/boutique/yamls/` + `bash run.sh`。

### 5. 查 Istio 指标

```bash
ssh alice@192.168.1.10 -- kubectl -n istio-system port-forward svc/prometheus 9090:9090
# http://localhost:9090,查询:
#   istio_requests_total
#   histogram_quantile(0.99, sum(rate(istio_request_duration_milliseconds_bucket[1m])) by (le, destination_service))
```

---

## 注意

- **前提**:5 台 Ubuntu 22.04、单网卡同一局域网、登录用户名相同(密码相同则
  `bootstrap_local.sh` 能一键配)。
- **Istio 改变被测对象**:注入 sidecar 后每个服务多一跳 Envoy,延迟/资源开销上升,
  与裸跑不可直接对比。只要原始指标可删 `enable_istio_metrics.sh` 里的 grafana/kiali
  两行;想完全裸跑把 `enable_istio_metrics` 设 `false`。
- **kubectl** 默认在控制节点 `~/.kube/config`;想在操作机直接用就 copy 过来。
