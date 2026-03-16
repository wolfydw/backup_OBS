# backup_OBS

基于 `bash + obsutil` 的 OBS 备份脚本，包含备份上传和历史清理两个入口：

- `backup.sh`：打包目录、生成 `sha256`、上传到 OBS、下载远端校验文件做一致性校验
- `clean_backups.sh`：按文件名日期清理旧备份
- `lib/obsutil.sh`：下载或更新仓库根目录下的 `./obsutil`
- `lib/telegram.sh`：统一处理 Telegram 通知模板和发送逻辑

## 配置

先复制模板并填写实际配置：

```bash
cp env.conf.example env.conf
cp exclude.user.list.example exclude.user.list
```

重点配置项：

- `OBS_BUCKET`：OBS 桶名
- `LABEL`：机器或业务标识
- `BACKUP_DIRS`：要备份的目录，使用多行格式，每行一个目录
- `TG_BOT_TOKEN` / `TG_USER_ID`：Telegram 通知配置，可留空

`BACKUP_DIRS` 示例：

```bash
BACKUP_DIRS=$(cat <<'EOF'
/root/data
/root/.openclaw
/root/myapp
EOF
)
```

不再建议使用空格分隔的目录列表，因为路径中一旦包含空格，Shell 会把它拆坏。

## 使用方式

备份：

```bash
./backup.sh
```

仅做打包自检，不上传：

```bash
./backup.sh --dry-run
```

仅做自检，且不保留本地归档：

```bash
./backup.sh --self-check
```

检查远端前缀是否可访问：

```bash
./backup.sh --verify
```

清理旧备份：

```bash
./clean_backups.sh --retain-days=5
```

## 首次部署

新机器首次部署推荐流程：

```bash
git clone <你的仓库地址> /root/backup_OBS
cd /root/backup_OBS
./install.sh
```

`install.sh` 会自动完成：

- 如果未检测到仓库根目录下的 `./obsutil`，则自动调用 `./lib/obsutil.sh`
- 如果不存在，则创建 `env.conf`
- 如果不存在，则创建 `exclude.user.list`
- 修正脚本执行权限
- 安装 `systemd` 更新任务
- 启用 `backup-obs-update.timer`
- 为目标用户写入每天 `03:00` 执行一次的备份 `cron`
- 执行一次 `./backup.sh --self-check` 安装自检

默认使用 system 模式，也就是安装到 `/etc/systemd/system`。

可选参数：

```bash
./install.sh --mode=system
./install.sh --mode=user --user=root
```

说明：

- `system` 模式需要 root 权限
- `user` 模式会安装到 `~/.config/systemd/user`
- 安装脚本不会覆盖已有的 `env.conf` 和 `exclude.user.list`
- `install.sh` 和后续脚本都只使用仓库根目录下的 `./obsutil`
- `obsutil` 安装完成后，首次仍需手动执行 `./obsutil config -interactive`

如果你想手动安装或更新仓库根目录下的 `./obsutil`，可以直接执行：

```bash
./lib/obsutil.sh
```

常用查看命令：

```bash
systemctl status backup-obs-update.timer
journalctl -u backup-obs-update.service -n 100
crontab -l
```

## 自动更新

仓库内提供了一个统一更新脚本：

```bash
./update.sh
```

它会执行：

- `git fetch --tags origin`
- 默认更新 `stable` 分支，或切换到你指定的 tag / 分支
- 修正脚本执行权限

也可以手动指定版本：

```bash
./update.sh
./update.sh stable
./update.sh main
./update.sh v1.2.0
```

配合 `systemd timer` 后，机器会定时自动执行 `update.sh`。

当前默认策略是：

- `systemd timer`：负责定时执行 `./update.sh stable`
- `cron`：负责每天 `03:00` 执行一次 `./backup.sh`

## GitHub 多机发布流程

推荐流程：

1. 在一台测试机或开发环境修改脚本并提交到 GitHub。
2. 在测试机手动运行：
   - `./update.sh main`
   - `./backup.sh --dry-run`
   - `./backup.sh`
   - `./clean_backups.sh --retain-days=100000`
3. 确认备份、清理、Telegram 通知都正常。
4. 打稳定版本标签，例如：

```bash
git tag v1.2.0
git push origin v1.2.0
```

5. 生产机器可以手动执行：

```bash
./update.sh v1.2.0
```

或者让 `systemd` 定时器长期跟随 `stable` 分支。

更稳的做法是：

- `main` 用来持续迭代
- `stable` 用来给其他机器自动更新
- tag 用来留档和回滚

推荐的发布方式：

1. 日常修改提交到 `main`
2. 测试机验证 `main`
3. 验证通过后，把 `main` 合并到 `stable`
4. 其他机器的 `systemd timer` 自动执行 `./update.sh stable`

## 排除规则

脚本会同时读取两个排除文件：

- `exclude.list`：默认排除规则，一般不用修改，可以提交 Git
- `exclude.user.list`：用户自定义排除规则，不提交 Git
- `exclude.user.list.example`：用户规则示例文件，可以提交 Git

默认规则仍然走 `tar --exclude-from`。
用户自定义规则现在会在实际备份目录里先做一次解析，再自动换算成归档路径，所以不需要你手动猜 tar 看到的相对路径。
如果某条用户规则当前没有命中任何实际路径，脚本会记录 `WARN`，但不会因此中止备份。

推荐写法 1：绝对路径

```text
/root/data/dify
```

推荐写法 2：通配模式

```text
*/.halo
```

对于 `*/xxxx` 这类规则，程序会在实际备份目录中先匹配命中的对象，再自动判断命中的是文件还是目录，因此用户不需要额外写一行 `/*` 来区分目录内容。

默认规则放在 `exclude.list`，业务自定义规则建议只写到 `exclude.user.list`。

更完整的默认规则、用户规则示例和配置模板，请直接查看：

- `exclude.list`
- `exclude.user.list.example`
- `env.conf.example`
