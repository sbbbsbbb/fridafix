# Fridafix

Frida iOS deb builder - 自动构建魔改版 Frida iOS deb 包的 GitHub Action。

通过修改二进制文件中的特征字符串来绑过越狱检测。

## 功能

- 自动下载指定版本的 Frida iOS deb
- 修改 frida-server 和 frida-agent.dylib 二进制文件
- 自定义替换名称（5位小写字母）
- 自定义端口号
- 支持 arm 和 arm64 架构
- 自动打包为 deb 安装包

## 使用方法

### GitHub Action（推荐）

1. Fork 本仓库
2. 进入 Actions 页面
3. 选择 "Build Frida iOS deb" workflow
4. 点击 "Run workflow"
5. 填写参数：
   - `frida_version`: Frida 版本号或 `latest`
   - `frida_name`: 自定义名称（5个小写字母，留空随机生成）
   - `frida_port`: 端口号（默认 8899）
6. 等待构建完成，下载 Artifacts

### 本地构建

#### 依赖

- macOS
- Go 1.21+
- dpkg (`brew install dpkg`)

#### 运行

```bash
# 使用最新版本，随机名称
./scripts/build-deb.sh -v latest

# 指定版本和名称
./scripts/build-deb.sh -v 16.5.2 -n abcde -p 9999

# 查看帮助
./scripts/build-deb.sh -h
```

#### 输出

构建完成后，deb 包位于 `dist/` 目录：

```
dist/
├── abcde_16.5.2_iphoneos-arm.deb    # 32位版本
└── abcde_16.5.2_iphoneos-arm64.deb  # 64位版本（rootless）
```

## 安装到设备

```bash
# 传输到设备
scp dist/*.deb root@<设备IP>:/var/root/

# SSH 登录设备
ssh root@<设备IP>

# 安装
dpkg -i /var/root/*.deb
```

## 连接使用

```bash
# 网络连接
frida -H <设备IP>:8899 -f <目标App>
frida-ps -H <设备IP>:8899

# USB 连接
frida -U -f <目标App>
frida-ps -U
```

## 项目结构

```
fridafix/
├── .github/workflows/
│   └── build.yml           # GitHub Action
├── hexreplace/
│   ├── main.go             # 二进制替换工具
│   └── go.mod
├── scripts/
│   └── build-deb.sh        # 构建脚本
├── templates/deb/          # deb 模板
└── README.md
```

## 原理

1. 下载官方 Frida iOS deb 包
2. 解包 deb
3. 使用 hexreplace 修改二进制文件中的特征字符串：
   - `frida` -> 自定义名称
   - `frida-server` -> `<name>`
   - `frida-agent.dylib` -> `<name>-agent.dylib`
   - `frida:rpc` -> `<name>:rpc`
   - 等等...
4. 修改 plist 和 DEBIAN 脚本中的引用
5. 重新打包 deb

## 许可证

MIT License

## 致谢

基于 [fridare](https://github.com/suifei/fridare) 项目精简而来。
