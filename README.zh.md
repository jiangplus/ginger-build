# ginger

用 Gleam 编写的容器部署工具，运行在 Erlang/BEAM 上。对标 [Kamal](https://kamal-deploy.org)：构建镜像、推送到镜像仓库，通过 SSH 零停机滚动部署到服务器，流量切换由 [kamal-proxy](https://github.com/basecamp/kamal-proxy) 完成。

与 Kamal 相比，ginger 做了四项有意为之的设计选择：

1. **复用 kamal-proxy** — 检测宿主机上已运行的代理并共享，而不是另起一个。
2. **多主机滚动更新** — 按批次逐步部署，可配置批大小和批间等待时间。
3. **YAML 显式流水线** — 部署、重部署、回滚、移除等操作序列在 YAML 中声明为命名 *pipeline*，而非硬编码逻辑。
4. **内联 hook** + **自动注入密钥** — hook 是 YAML 里的 shell 字符串；密钥从进程环境和 `.env` 合并，写入临时文件后以 `--env-file` 传给容器，不会出现在进程参数中。

## 安装

### 第一步：安装 Erlang/OTP

ginger 打包为单文件 escript，运行时只依赖 **Erlang/OTP 27 或更高版本**。Ubuntu/Debian 系统自带的 `erlang` 包通常是 OTP 24 或更旧，请勿直接使用，改用 Erlang Solutions 官方源。

#### macOS

```sh
brew install erlang        # 安装 OTP 27+
```

验证：

```sh
erl -eval 'erlang:display(erlang:system_info(otp_release)), halt().' -noshell
# 必须输出 "27"、"28" 或 "29"
```

#### Ubuntu / Debian

系统 `apt` 自带包版本过旧，必须使用 Erlang Solutions 官方源：

```sh
wget -qO- https://packages.erlang-solutions.com/ubuntu/erlang_solutions.asc \
  | sudo gpg --dearmor -o /usr/share/keyrings/erlang-solutions.gpg
echo "deb [signed-by=/usr/share/keyrings/erlang-solutions.gpg] \
  https://packages.erlang-solutions.com/ubuntu $(lsb_release -cs) contrib" \
  | sudo tee /etc/apt/sources.list.d/erlang-solutions.list
sudo apt update && sudo apt install -y esl-erlang
```

验证：

```sh
erl -eval 'erlang:display(erlang:system_info(otp_release)), halt().' -noshell
# 必须输出 "27"、"28" 或 "29"
```

#### Windows

从 [Erlang/OTP 官网](https://www.erlang.org/downloads) 下载 OTP 27+ 的 `.exe` 安装包，按向导完成安装。

> **注意**：ginger 的 SSH 功能需要在 WSL2（Ubuntu）环境中运行，原生 CMD/PowerShell 暂不支持。请在 WSL2 内按上文 Ubuntu 步骤安装 Erlang，并在 WSL2 终端中使用 ginger。

### 第二步：安装 ginger

从 [Releases](https://github.com/jiangplus/ginger-build/releases) 页面下载最新的 `ginger` escript 文件，放到 PATH 中的任意目录：

```sh
# macOS / Linux
curl -fsSL https://github.com/jiangplus/ginger-build/releases/latest/download/ginger \
  -o ~/.local/bin/ginger
chmod +x ~/.local/bin/ginger
ginger version
```

或者从源码构建（需安装 [Gleam](https://gleam.run/getting-started/installing/) 和 [just](https://just.systems)）：

```sh
git clone https://github.com/jiangplus/ginger.git
cd ginger
just install   # 构建 escript 并复制到 ~/bin/ginger
```

验证安装：

```sh
ginger version
# ginger 0.1.6
```

## 命令

```sh
ginger deploy                   # 构建、推送并零停机部署
ginger deploy --skip-push       # 跳过构建，直接部署仓库中的镜像
ginger deploy --tag v1          # 固定镜像标签，跳过 git SHA 解析
ginger redeploy                 # 部署但不启动代理、不执行清理
ginger rollback <version>       # 将流量切回指定版本的旧容器
ginger remove                   # 从代理注销并删除所有容器
ginger status                   # 显示各主机运行版本及代理状态
ginger lock release             # 释放卡住的部署锁
ginger lock status              # 查看当前锁持有者
ginger config                   # 打印解析后的配置（密钥已脱敏）
ginger version
ginger help
```

全局选项：

| 标志 | 默认值 | 说明 |
|------|--------|------|
| `-c, --config <文件>` | `ginger.yml` | 配置文件路径 |
| `-P, --skip-push` | false | 跳过构建和推送 |
| `-t, --tag <版本>` | git SHA | 固定镜像标签 |

## 配置文件（`ginger.yml`）

```yaml
service: blog                   # 容器名前缀，只能包含 [a-z0-9_-]
image: ghcr.io/acme/blog        # 镜像名（不含标签，标签 = 版本号）

servers:
  web:
    hosts: [10.0.0.1, 10.0.0.2, 10.0.0.3]
    primary: true               # 屏障守门角色，其他角色等待此角色就绪
  worker:
    hosts: [10.0.0.4]
    cmd: bundle exec sidekiq    # 覆盖容器的 CMD

registry:
  server: ghcr.io
  username: acme-ci
  password: GITHUB_TOKEN        # 密钥名，部署时从密钥映射表中解析

proxy:
  hosts: [blog.example.com, www.example.com]  # 一个或多个虚拟主机域名
  app_port: 3000
  ssl: true                     # 由 kamal-proxy 处理 Let's Encrypt 证书
  health_check_path: /up
  deploy_timeout: 30            # kamal-proxy 等待健康检查的秒数
  drain_timeout: 30

ssh:
  user: root                    # 默认：root

builder:
  arch: amd64
  remote: ssh://docker@builder  # 省略则在本机用 docker buildx 构建

env:                            # 写入每个容器的普通环境变量
  RAILS_ENV: production

secrets:
  load: [.env]                  # 合并到进程环境的 dotenv 文件列表
  inject:                       # 以 --env-file 注入容器的键名或通配符
    - RAILS_MASTER_KEY
    - "STRIPE_*"

rolling:
  limit: 25%                    # 每批主机数：整数或百分比
  wait: 5                       # 批次间等待秒数
  parallel_roles: false         # true = 非主角色并发启动

retain_containers: 5            # 清理时保留的旧容器数量

# 显式流水线（可选，省略则使用内置默认值）
pipelines:
  deploy:
    - build
    - push
    - lock: acquire
    - hook: ./bin/check-db                        # 本地 shell hook
    - boot-proxy
    - hook: { run: 'notify-slack deployed', local: true }
    - boot-app: { rolling: true }
    - prune
    - lock: release
    - hook: { run: 'echo done >> /var/log/deploys', local: false }
```

### 流水线步骤

| 步骤 | 说明 |
|------|------|
| `build` | 本机或远程构建器执行 `docker buildx build --push`；构建日志实时输出 |
| `push` | buildx 已推送时为空操作；显式声明以提高可读性 |
| `boot-proxy` | 确保代理运行；检测到已有 kamal-proxy 则复用 |
| `boot-app` | 零停机容器切换；选项：`rolling: bool`、`version: string` |
| `remove-app` | 从代理注销，停止并删除所有服务容器 |
| `prune` | 删除旧的已停止容器和悬空镜像 |
| `lock: acquire\|release\|status` | 基于 mkdir 的部署互斥锁，运行在主节点上 |
| `hook: <命令>` | 内联 shell；`local: true` = 在操作机执行，`local: false` = 在每台主机执行 |
| `healthcheck` | （预留） |

### 密钥处理

ginger 将进程环境与 `secrets.load` 中的每个文件（默认 `[.env]`）合并。部署前校验 `secrets.inject` 中所有精确匹配的键存在且非空，然后将解析后的值写入每个容器专属的临时文件（`/tmp/.ginger-<服务>-<角色>-<版本>.env`），以 `--env-file` 传给 `docker run`。密钥值不会出现在进程参数或 `ps` 输出中。

`registry.password` 以及配置中的裸键名均从同一合并映射表解析。

### 代理复用

ginger 检测宿主机上任何正在运行的 `kamal-proxy` 容器，将新服务注册到该代理并自动加入其 Docker 网络。只有在没有代理时才会启动新的 `ginger-proxy`。共享代理上已注册的其他应用不受影响。

### 多域名代理

`proxy.hosts` 接受域名列表，每个域名对应 kamal-proxy 的一个 `--host` 参数，同一服务可响应多个域名：

```yaml
proxy:
  hosts: [blog.example.com, www.example.com]
  app_port: 3000
```

也可以用标量简写（单域名）：

```yaml
proxy:
  host: blog.example.com
  app_port: 3000
```

## 开发

```sh
gleam run -- <命令>           # 不安装直接运行
gleam test                    # 运行测试套件（73 个测试）
gleam format src test         # 格式化代码
just build                    # gleam build
just escript                  # gleam export escript → ./ginger（单文件二进制）
just install                  # 构建 escript 并复制到 ~/bin/ginger
```
