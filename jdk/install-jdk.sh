#!/bin/bash
set -e

# ============================================================
# 多版本 JDK 安装脚本（Temurin/Adoptium 发行版，自带 src.zip）
# 安装 JDK 8 / 17 / 21 / 25 到 /opt/java/jdk-<版本>
# 切换配置写入 ~/.bashrc，默认 JDK 25
# 命令行切换: jdk8 / jdk17 / jdk21 / jdk25，查看版本: jdk
# ============================================================

VERSIONS="8 17 21 25"             # 想增删版本改这里
DEFAULT_VERSION="25"              # 默认启用的版本
JDK_DIR="/opt/java"               # 安装目录

TUNA="https://mirrors.tuna.tsinghua.edu.cn/Adoptium"
ADOPTIUM_API="https://api.adoptium.net/v3/binary/latest"

BASHRC="$HOME/.bashrc"
MARK_BEGIN="# >>> jdk multi-version >>>"
MARK_END="# <<< jdk multi-version <<<"

# 解析某个大版本的最新 tarball 下载地址（优先清华镜像，失败回退官方 API）
resolve_url() {
    local v=$1
    local file
    file=$(curl -fsSL -m 20 "${TUNA}/${v}/jdk/x64/linux/" \
        | grep -oE "OpenJDK${v}U-jdk_x64_linux_hotspot_[^\"]+\.tar\.gz" \
        | grep -v "_ea_" | sort -Vu | tail -1) || true
    if [ -n "$file" ]; then
        echo "${TUNA}/${v}/jdk/x64/linux/${file}"
    else
        echo "${ADOPTIUM_API}/${v}/ga/linux/x64/jdk/hotspot/normal/eclipse"
    fi
}

# 返回 JDK 内 src.zip 的路径（8 在根目录，9+ 在 lib/ 下）
src_zip_path() {
    if [ -f "$1/src.zip" ]; then echo "$1/src.zip"
    elif [ -f "$1/lib/src.zip" ]; then echo "$1/lib/src.zip"
    fi
}

echo "==> 准备安装目录 ${JDK_DIR}"
sudo mkdir -p "$JDK_DIR"

cd /tmp
for v in $VERSIONS; do
    home="${JDK_DIR}/jdk-${v}"
    if [ -x "${home}/bin/java" ]; then
        echo "==> JDK ${v} 已存在于 ${home}，跳过"
        continue
    fi

    url=$(resolve_url "$v")
    tar="jdk-${v}.tar.gz"
    echo "==> 下载 JDK ${v}"
    echo "    ${url}"
    curl -fSL -o "$tar" "$url"

    echo "==> 解压 JDK ${v} 到 ${home}"
    topdir=$(tar -tzf "$tar" | head -1 | cut -d/ -f1)
    sudo rm -rf "$home" "/tmp/${topdir}"
    tar -xzf "$tar" -C /tmp
    sudo mv "/tmp/${topdir}" "$home"
    rm -f "$tar"

    src=$(src_zip_path "$home")
    if [ -n "$src" ]; then
        echo "    源码包已内置: ${src}"
    else
        echo "    警告: 未找到 src.zip，IDEA 中将无法直接阅读带注释的源码" >&2
    fi
done

# 旧版本脚本可能写过 /etc/profile.d/jdk.sh，移除以免冲突
if [ -f /etc/profile.d/jdk.sh ]; then
    echo "==> 移除旧的 /etc/profile.d/jdk.sh（已改为 ~/.bashrc 管理）"
    sudo rm -f /etc/profile.d/jdk.sh
fi

echo "==> 写入版本切换配置（${BASHRC}，默认 JDK ${DEFAULT_VERSION}）"
touch "$BASHRC"
# 幂等：先删除旧的管理块再追加
if grep -qF "$MARK_BEGIN" "$BASHRC"; then
    sed -i "/$(printf '%s' "$MARK_BEGIN" | sed 's/[][\.*^$/]/\\&/g')/,/$(printf '%s' "$MARK_END" | sed 's/[][\.*^$/]/\\&/g')/d" "$BASHRC"
fi
cat >> "$BASHRC" <<'EOF'

# >>> jdk multi-version >>>
export JDK_DIR=__JDK_DIR__

# 切换当前 shell 的 JDK（内部函数）
_jdk_switch() {
    local target="$JDK_DIR/jdk-$1"
    if [ ! -x "$target/bin/java" ]; then
        echo "未安装 JDK $1（$target 不存在）"
        return 1
    fi
    export JAVA_HOME="$target"
    PATH=$(echo "$PATH" | tr ':' '\n' | grep -v "$JDK_DIR/jdk-" | tr '\n' ':')
    export PATH="$JAVA_HOME/bin:${PATH%:}"
    echo "已切换到 JDK $1（$JAVA_HOME）"
    java -version
}

jdk8()  { _jdk_switch 8;  }
jdk17() { _jdk_switch 17; }
jdk21() { _jdk_switch 21; }
jdk25() { _jdk_switch 25; }

# 查看已安装版本
jdk() {
    echo "已安装的 JDK:"
    for d in "$JDK_DIR"/jdk-*; do
        [ -x "$d/bin/java" ] || continue
        local v=${d##*/jdk-}
        if [ "$JAVA_HOME" = "$d" ]; then
            echo "  * $v (当前)"
        else
            echo "    $v"
        fi
    done
    echo "切换: jdk8 / jdk17 / jdk21 / jdk25"
}

_jdk_switch __DEFAULT_VERSION__ > /dev/null   # 每个新终端默认启用
# <<< jdk multi-version <<<
EOF
sed -i "s|__JDK_DIR__|${JDK_DIR}|g; s|__DEFAULT_VERSION__|${DEFAULT_VERSION}|g" "$BASHRC"

echo "==> 当前 shell 立即生效"
sed -n "/$(printf '%s' "$MARK_BEGIN" | sed 's/[][\.*^$/]/\\&/g')/,/$(printf '%s' "$MARK_END" | sed 's/[][\.*^$/]/\\&/g')/p" "$BASHRC" > /tmp/.jdk-block
. /tmp/.jdk-block
rm -f /tmp/.jdk-block

echo "==> 验证默认版本（JDK ${DEFAULT_VERSION}）"
java -version

cat <<'TIP'

============================================================
完成！使用说明：

1. 命令行切换版本（新开终端自动生效，默认 JDK 25）：
     jdk            # 查看已安装版本
     jdk8           # 切换到 JDK 8
     jdk17          # 切换到 JDK 17
     jdk21          # 切换到 JDK 21
     jdk25          # 切换到 JDK 25

   当前已打开的终端请执行:  source ~/.bashrc

2. IDEA 阅读 JDK 源码（带注释，非反编译）：
   Temurin 已内置 src.zip，无需额外下载源码包：
     JDK 8        : /opt/java/jdk-8/src.zip
     JDK 17/21/25 : /opt/java/jdk-*/lib/src.zip
   IDEA 中 File -> Project Structure -> SDKs -> + 选择
   /opt/java/jdk-<版本>，Sourcepath 标签页会自动关联 src.zip；
   若未关联，手动添加对应 src.zip 即可。
============================================================
TIP
