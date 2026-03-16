# backup_OBS

基于 `bash + obsutil` 的 OBS 备份脚本，包含备份上传和历史清理两个入口：

- `backup.sh`：打包目录、生成 `sha256`、上传到 OBS、下载远端校验文件做一致性校验
- `clean_backups.sh`：按文件名日期清理旧备份
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

检查远端前缀是否可访问：

```bash
./backup.sh --verify
```

清理旧备份：

```bash
./clean_backups.sh --retain-days=5
```

## 排除规则

脚本会同时读取两个排除文件：

- `exclude.list`：默认排除规则，一般不用修改，可以提交 Git
- `exclude.user.list`：用户自定义排除规则，不提交 Git
- `exclude.user.list.example`：用户规则示例文件，可以提交 Git

排除规则由 `tar --exclude-from` 读取，匹配的是归档内的相对路径，不是磁盘上的绝对路径。

排除单个文件：

```text
project/src/main.js
```

或者：

```text
*/project/src/main.js
```

排除一个目录，建议写两行：

```text
*/project/cache
*/project/cache/*
```

默认规则放在 `exclude.list`，业务自定义规则建议只写到 `exclude.user.list`。

更完整的默认规则、用户规则示例和配置模板，请直接查看：

- `exclude.list`
- `exclude.user.list.example`
- `env.conf.example`
