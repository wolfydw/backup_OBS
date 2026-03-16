# backup_OBS

基于 `bash + obsutil` 的 OBS 备份脚本，包含备份上传和历史清理两个入口：

- `backup.sh`：打包目录、生成 `sha256`、上传到 OBS、下载远端校验文件做一致性校验
- `clean_backups.sh`：按文件名日期清理旧备份

## 配置

先复制模板并填写实际配置：

```bash
cp env.conf.example env.conf
```

重点配置项：

- `OBS_BUCKET`：OBS 桶名
- `LABEL`：机器或业务标识
- `BACKUP_DIR`：要备份的目录，当前格式为以空格分隔的路径列表
- `TG_BOT_TOKEN` / `TG_USER_ID`：Telegram 通知配置，可留空

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

## exclude.list 规则

`exclude.list` 由 `tar --exclude-from` 读取，匹配的是归档内的相对路径，不是磁盘上的绝对路径。

不要写：

```text
/root/data/project/src/main.js
cache/
```

应该写相对路径或通配规则。

排除单个文件：

```text
project/src/main.js
```

或者：

```text
*/project/src/main.js
```

排除某类文件：

```text
*.log
*.tmp
```

排除一个目录，建议写两行：

```text
*/node_modules
*/node_modules/*
```

例如排除 `project/cache`：

```text
*/project/cache
*/project/cache/*
```

当前自带的 `exclude.list` 已对常见目录采用这种写法，避免 `.cache/`、`node_modules/` 这类规则匹配不到的问题。
