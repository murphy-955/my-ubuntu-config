#!/bin/bash
set -e

MAVEN_VERSION=""                  # 留空 = 自动使用镜像站最新版；想固定版本填如 "3.9.11"
MAVEN_HOME="/opt/maven"

BASHRC="$HOME/.bashrc"
MARK_BEGIN="# >>> maven >>>"
MARK_END="# <<< maven <<<"

# 镜像列表：腾讯/清华只保留最新版，Apache 官方归档保留所有历史版本
MIRRORS="https://mirrors.cloud.tencent.com/apache/maven/maven-3
https://mirrors.tuna.tsinghua.edu.cn/apache/maven/maven-3
https://archive.apache.org/dist/maven/maven-3"

# 未指定版本时，自动从镜像站获取最新 3.x 版本号
if [ -z "$MAVEN_VERSION" ]; then
    echo "==> 自动获取最新 Maven 版本号"
    for BASE in $MIRRORS; do
        MAVEN_VERSION=$(curl -fsSL -m 20 "$BASE/" 2>/dev/null \
            | grep -oE 'href="3\.[0-9.]+/"' | grep -oE '3\.[0-9.]+' | sort -Vu | tail -1) || true
        [ -n "$MAVEN_VERSION" ] && break
    done
    [ -n "$MAVEN_VERSION" ] || { echo "无法从镜像站获取最新版本号"; exit 1; }
fi

TAR="apache-maven-${MAVEN_VERSION}-bin.tar.gz"
cd /tmp

echo "==> 下载 Maven ${MAVEN_VERSION}"
URL=""
for BASE in $MIRRORS; do
    candidate="${BASE}/${MAVEN_VERSION}/binaries/${TAR}"
    echo "    尝试: ${candidate}"
    if curl -fSL --connect-timeout 10 -o "$TAR" "$candidate"; then
        URL="$candidate"
        break
    fi
done
[ -n "$URL" ] || { echo "所有镜像均下载失败"; exit 1; }

echo "==> 校验 SHA-512"
if curl -fsSL -m 20 -o "${TAR}.sha512" "${URL}.sha512"; then
    echo "$(cat "${TAR}.sha512")  ${TAR}" | sha512sum -c -
else
    echo "    未获取到校验文件，跳过（tar 解压时仍会校验 gzip 完整性）"
fi

echo "==> 解压到 ${MAVEN_HOME}"
sudo rm -rf "$MAVEN_HOME"
sudo tar -xzf "$TAR" -C /opt
sudo mv "/opt/apache-maven-${MAVEN_VERSION}" "$MAVEN_HOME"

# 旧版本脚本可能写过 /etc/profile.d/maven.sh，移除以免冲突
if [ -f /etc/profile.d/maven.sh ]; then
    echo "==> 移除旧的 /etc/profile.d/maven.sh（已改为 ~/.bashrc 管理）"
    sudo rm -f /etc/profile.d/maven.sh
fi

echo "==> 写入环境变量（${BASHRC}）"
touch "$BASHRC"
# 幂等：先删除旧的管理块再追加（标记行不含正则特殊字符，可直接用作 sed 地址）
if grep -qF "$MARK_BEGIN" "$BASHRC"; then
    sed -i "/$MARK_BEGIN/,/$MARK_END/d" "$BASHRC"
fi
cat >> "$BASHRC" <<EOF

# >>> maven >>>
export MAVEN_HOME=${MAVEN_HOME}
export PATH=\$MAVEN_HOME/bin:\$PATH
# <<< maven <<<
EOF

echo "==> 当前 shell 立即生效"
export MAVEN_HOME=${MAVEN_HOME}
export PATH=$MAVEN_HOME/bin:$PATH

if command -v java > /dev/null 2>&1 || [ -n "$JAVA_HOME" ]; then
    echo "==> 验证"
    mvn -version
else
    echo "==> 跳过验证：未检测到 JDK，mvn 运行需要 Java 环境"
    echo "    请先安装 JDK（可用 jdk/install-jdk.sh），再执行 mvn -version"
fi

echo "==> 完成，清理临时文件"
rm -f "/tmp/${TAR}" "/tmp/${TAR}.sha512"
