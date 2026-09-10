# 部署到阿里云函数计算（FC）· 自定义镜像

60S 是**纯 ESM + 直接 `import` `.ts` 文件**、零构建步骤的项目，运行时依赖 Node 的**原生 TypeScript 类型擦除**：

```ts
// src/app.ts
import { appRouter } from './router.ts'   // 注意：直接 .ts 后缀
```

因此对 Node 版本有硬性要求：

| Node 版本 | 行为 |
| --- | --- |
| **Node 24（本方案采用）** | `process.features.typescript === 'strip'` 且默认开启，直接运行 ✅ |
| Node 22.18 ~ 23 | 默认开启，直接运行 ✅ |
| Node 22.6 ~ 22.17 | 需加 `--experimental-strip-types` |
| Node 20 及以下 | **完全不支持** ❌ |

云函数「内置 Node 运行时」目前主流只到 20.x，**跑不起来**，所以走**自定义镜像**是最省心的路线。

---

## 1. 为什么用自定义镜像，而不是「zip 包 + 自定义运行时」

zip 包 + 自定义运行时（`bootstrap` / `scf_bootstrap` 里 `node --experimental-strip-types node.ts`）也能跑，但 ESM 下 `NODE_PATH` 对层无效，依赖必须和代码放同一目录，坑较多。自定义镜像把这些运行时细节全部固化在镜像里，行为可复现。

自定义镜像还保留了 `whois` / `maoyan` / `hash` 这几个依赖 TCP 出网、fontkit、zlib 的端点，**无需裁剪**。

---

## 2. 快速部署

前置：已安装 Docker、[Serverless Devs](https://github.com/Serverless-Devs/Serverless-Devs)（`npm i -g @serverless-devs/s`），并已在 ACR 创建命名空间 / 仓库。

```bash
# 0. 克隆仓库
git clone https://github.com/vikiboss/60S.git && cd 60S

# 1. 修改 s.yaml 中的 image 为你自己的 ACR 地址
#    image: registry.cn-hangzhou.aliyuncs.com/<namespace>/60s:latest

# 2. 配置 AK/SK（首次）
s config

# 3. 部署（s 会自动 docker build & push）
s deploy

# 4. 手动触发一次函数，看日志确认没有
#    ERR_MODULE_NOT_FOUND / ERR_UNSUPPORTED_NODE_MODULES_TYPE_STRIPPING
```

手动构建 / 本地验证：

```bash
docker build -f Dockerfile.fc -t 60s:local .
docker run -d -p 9000:9000 --name 60s 60s:local
curl -s http://127.0.0.1:9000/health      # => ok
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:9000/v2/60s   # => 200
```

一键自检：

```bash
sh scripts/check-fc-image.sh            # 仓库静态自检
sh scripts/check-fc-image.sh 60s:local  # 额外做运行时探活
```

---

## 3. 关键配置说明

相对仓库根目录的原生 `Dockerfile`，`Dockerfile.fc` 只有 3 处差异：

1. **基础镜像钉死 `node:24-alpine`**
   原生 `Dockerfile` 用 `node:lts-alpine`，当前解析到 Node 24 能跑，但 `lts` 是**浮动标签**，将来回退到 Node 20 会直接启动失败。必须钉死 `24`（本方案）或 `22.18+`。
2. **默认 `PORT=9000`**
   FC / SCF Web 函数固定要求监听 `9000`。`src/config.ts` 已支持 `process.env.PORT`，无需改代码。实测默认端口是 `4399`，不覆盖会探活失败。
3. **依赖安装阶段 `COPY .npmrc`**
   `.npmrc` 里 `@jsr:registry=https://npm.jsr.io` 是 `@oak/oak`（真实包名 `@jsr/oak__oak`）的拉取地址，不 COPY 进去装不上依赖。构建阶段需要能出公网。

另外 `TZ=Asia/Shanghai` 是**必需**的：60S 大量使用上海时区逻辑（如 `/v2/60s` 的日期、`/v2/lunar`）。

启动命令加了 `--disable-warning=ExperimentalWarning`，仅用于去掉类型擦除的实验特性告警噪音。

---

## 4. 规格建议

实测值（本地 `PORT=9000` 启动后）：

| 项 | 数值 |
| --- | --- |
| `/health` | 200（真实健康检查，返回 `ok`） |
| `/v2/60s` | 200 |
| `/v2/lunar` | 200，约 820KB JSON |
| `/v2/whois` | 200，约 1.1s（TCP 43 出网） |
| `/v2/maoyan` | 200，约 0.21s（fontkit 解析字体） |
| 端点总数 | 75（69 个 `GET` + 6 个 `ALL`，另加根路由 `/` `/health` `/endpoints`） |
| `node_modules` | 约 40MB |
| 代码本体 | 约 3.4MB（不含 `.git`） |
| 代码包（不含依赖）压缩后 | 约 907KB |
| 常驻内存 | 启动约 136MB，访问一次 `/v2/lunar` 后约 147MB |

**内存建议 512MB 起，想稳一点给 1GB。128MB 肯定不够。**

> 注意：`GET /health`（返回 `ok`）才是健康检查；`GET /v2/health` 是 BMI 健康评估计算接口，两者容易混淆。

---

## 5. 镜像体积与数据

**镜像里不要内置大 JSON 动态数据。** 60S 的动态数据（如每日 60s 新闻、摸鱼日历等）走外部 CDN / 静态仓库拉取（见 `src/common.ts` 的 `tryRepoUrl`），镜像只装代码 + 依赖即可，数据交给 OSS/COS + CDN。

---

## 6. 构建前自检清单

1. 基础镜像**钉死 Node 24**（或退而求其次 22.18+），禁用 `lts` 浮动标签
2. 装依赖阶段 `COPY .npmrc`（否则 `@oak/oak` 装不上）
3. 用 `pnpm install --prod --frozen-lockfile`，别把 devDeps（typescript / wrangler / bun）打进镜像
4. 环境变量三件套：`PORT=9000`、`TZ=Asia/Shanghai`、`NODE_ENV=production`
5. 构建完本地 `docker run -p 9000:9000` 先验 `/health` 和 `/v2/60s`
6. 推到镜像仓库后**手动触发一次函数**看日志，确认没有 `ERR_MODULE_NOT_FOUND` / `ERR_UNSUPPORTED_NODE_MODULES_TYPE_STRIPPING`
7. 生产绑**自定义域名**，不要用函数默认测试域名（有调用限制，且不利冷启动缓存）

---

## 7. 常见问题

**Q：日志报 `ERR_UNSUPPORTED_NODE_MODULES_TYPE_STRIPPING`？**
A：Node 版本过低（< 22.18 或 20 及以下）。检查基础镜像是否被浮动标签带到了 Node 20；本方案已钉死 `node:24-alpine`。

**Q：函数起来了但探活失败 / 502？**
A：端口不对。FC Web 函数只认 `9000`，且必须监听 `0.0.0.0`（`Dockerfile.fc` 已设 `HOST=0.0.0.0`）。

**Q：日期、农历结果对不上？**
A：`TZ` 没设成 `Asia/Shanghai`。

**Q：构建时 `@oak/oak` 404？**
A：`.npmrc` 没 COPY 进构建阶段，或构建环境不允许出公网（需要能访问 `npm.jsr.io`）。
