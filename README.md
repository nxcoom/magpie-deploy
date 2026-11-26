# magpie + SSH + Cloudflare Tunnel（orkestr 部署胶水）

在 [yetone/magpie](https://github.com/yetone/magpie) 官方镜像上叠一层胶水：

- **magpie**：单端口模式 `magpie serve --web=0.0.0.0:8080`。页面（`/?k=<MAGPIE_WEB_KEY>`）与网关 `/v1/*` 共用 8080，因为 orkestr 只映射一个端口。
- **sshd**：构建期用用户给的一键脚本 `ssh.sh` 配置（`docker/ssh.sh`，原样带进来），启动期写入公钥。
- **cloudflared**：构建期用 `tunc.sh`（`docker/tunc.sh`）安装二进制与管理器，启动期按 `CF_TUNNEL_TOKEN` 起隧道。

## 环境变量

| 变量 | 说明 |
| --- | --- |
| `MAGPIE_WEB_KEY` | 页面 key（16+ 位字母数字 `-._~`）；不给则每次启动随机生成并打进日志 |
| `MAGPIE_PORT` | 对外端口，默认 `8080` |
| `MAGPIE_GATEWAY_KEY` | 可选；启动时若 `orkestr` 这个 key 不存在就按此值创建 |
| `SSH_AUTHORIZED_KEY` | 启动时写入 `/root/.ssh/authorized_keys` 的公钥（可多个，换行分隔） |
| `SSH_ROOT_PASSWORD` | 可选，root 密码 |
| `CF_TUNNEL_TOKEN` | cloudflared 隧道 token；不给就不起隧道 |

## 本地验证要点

```sh
# 页面：不带头 → 401；带 ?k=<key> → 签到 cookie 并 303
curl -s -o /dev/null -w '%{http_code}\n' 'http://127.0.0.1:8080/'
# 网关：需要 gateway key（页面端口对非本机请求按「远程」处理）
curl -s -H "Authorization: Bearer $GW_KEY" http://127.0.0.1:8080/v1/models
```

## 注意

- orkestr 免费档 0.25 vCPU / 512 MB：magpie 常驻约 95 MB，sshd + cloudflared 约 30 MB，够用但构建会慢。
- 容器里没有 systemd，`ssh.sh` 与 `tunc.sh` 都自动退化为「无 init，手动模式」。
- 隧道 ingress 由 Cloudflare 控制台托管，容器侧无法覆盖；控制台里把主机名指向 `http://localhost:8080`（页面 + `/v1`）或 `ssh://localhost:22` 即可。
