#!/usr/bin/env sh
# 构建前/构建后自检脚本（FC 自定义镜像）
# 用法：
#   sh scripts/check-fc-image.sh                 # 仅做仓库静态自检
#   sh scripts/check-fc-image.sh 60s:local       # 额外对镜像做运行时探活
#
# 依赖：docker（仅在传入镜像名时需要）、curl

set -eu

PASS=0
FAIL=0

ok()   { PASS=$((PASS + 1)); printf '  [PASS] %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf '  [FAIL] %s\n' "$1"; }
need() { [ -e "$1" ] && ok "$1 存在" || bad "$1 缺失"; }

echo "==> 1. 必需要素检查"
need Dockerfile.fc
need s.yaml
need .npmrc
need package.json
need pnpm-lock.yaml
need node.ts

echo "==> 2. 基础镜像不得使用浮动 lts 标签"
if grep -nE '^FROM[[:space:]]+node:lts' Dockerfile.fc >/dev/null 2>&1; then
  bad "Dockerfile.fc 使用了 node:lts（浮动标签，将来可能回退到 Node 20 直接挂）"
else
  ok "基础镜像未使用 node:lts 浮动标签"
fi
if grep -qE 'node:24-alpine' Dockerfile.fc; then
  ok "基础镜像已钉死为 Node 24"
elif grep -nE 'node:(22|24)-alpine' Dockerfile.fc >/dev/null 2>&1; then
  bad "基础镜像未钉死在 Node 24（检测到非 24 的 Node 标签）"
else
  bad "基础镜像未钉死 Node 24"
fi

echo "==> 3. 环境变量三件套"
grep -q 'PORT=9000' Dockerfile.fc && ok 'PORT=9000 已设置' || bad 'PORT=9000 未设置（FC Web 函数要求 9000）'
grep -q 'TZ=Asia/Shanghai' Dockerfile.fc && ok 'TZ=Asia/Shanghai 已设置' || bad 'TZ=Asia/Shanghai 未设置'
grep -q 'NODE_ENV=production' Dockerfile.fc && ok 'NODE_ENV=production 已设置' || bad 'NODE_ENV=production 未设置'

echo "==> 4. 依赖安装阶段必须 COPY .npmrc（否则 @jsr/oak__oak 装不上）"
if grep -nE 'COPY .*\.npmrc' Dockerfile.fc >/dev/null 2>&1; then
  ok ".npmrc 已在依赖安装前 COPY"
else
  bad ".npmrc 未 COPY，构建可能因 @jsr 作用域解析失败"
fi
grep -q -- '--prod' Dockerfile.fc && ok 'pnpm install --prod 已使用' || bad '未使用 pnpm install --prod'
grep -q -- '--frozen-lockfile' Dockerfile.fc && ok '--frozen-lockfile 已使用' || bad '未使用 --frozen-lockfile'

echo "==> 5. s.yaml 与 Dockerfile 的端口一致性"
if grep -q 'port: 9000' s.yaml && grep -q 'PORT=9000' Dockerfile.fc; then
  ok 's.yaml 与 Dockerfile 端口均为 9000'
else
  bad 's.yaml 与 Dockerfile 端口不一致'
fi

echo "==> 6. 运行时探活（可选，需传入镜像名）"
if [ "${1:-}" != "" ]; then
  IMG="$1"
  CID="$(docker run -d -p 19000:9000 "$IMG")"
  trap 'docker rm -f "$CID" >/dev/null 2>&1 || true' EXIT
  printf '    等待服务就绪'
  i=0
  while [ "$i" -lt 30 ]; do
    if curl -fsS http://127.0.0.1:19000/health >/dev/null 2>&1; then break; fi
    printf '.'; sleep 1; i=$((i + 1))
  done
  echo
  H="$(curl -fsS http://127.0.0.1:19000/health 2>/dev/null || echo '')"
  [ "$H" = "ok" ] && ok "/health 返回 ok" || bad "/health 返回异常: '$H'"
  C="$(curl -fsS -o /dev/null -w '%{http_code}' http://127.0.0.1:19000/v2/60s 2>/dev/null || echo 000)"
  [ "$C" = "200" ] && ok "/v2/60s 返回 200" || bad "/v2/60s 返回 $C"
  N="$(curl -fsS http://127.0.0.1:19000/endpoints 2>/dev/null | tr ',' '\n' | grep -c '/v2/' || true)"
  echo "    端点数量（/endpoints 中 /v2/ 路径）：$N"
  echo "==> 运行时自检完成"
else
  echo "    （跳过：未传入镜像名，仅做静态自检）"
fi

echo
echo "==> 结果：PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
