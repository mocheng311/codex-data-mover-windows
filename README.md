# Codex Data Mover for Windows

一个使用 PowerShell 编写的 Windows 数据迁移工具。把选定的 Codex 数据目录复制到另一位置，校验内容与访问权限，再在原路径建立目录联接。支持查看计划、状态核对，以及保留最新数据的回滚。

## 运行环境

- **仅支持 Windows**，使用本机固定 NTFS 磁盘。
- Windows PowerShell 5.1 或 PowerShell 7。
- 已在 Windows 10 22H2 上测试两种 PowerShell；Windows 11 尚未实机验证。
- 工具应放在待迁移目录以外，迁移过程使用原用户的普通权限。
- 不是 OpenAI 官方迁移工具；不同 Codex 版本的数据位置可能变化，先检查计划。

## 快速开始

1. 下载仓库，把工具放在独立目录，例如 `D:\Tools\CodexDataMover`。
2. 自行创建目标父目录，例如 `D:\CodexData`。
3. 在工具目录中打开 PowerShell，先只查看计划：

```powershell
.\Start-Migration.cmd -Mode Plan -Component Home -DestinationRoot D:\CodexData
```

4. 保存工作后，从独立的终端启动迁移，并正常退出 Codex、相关浏览器插件和辅助进程：

```powershell
.\Start-Migration.cmd -Mode Migrate -Component Home -DestinationRoot D:\CodexData -WaitForExit
```

迁移窗口会列出仍在使用相关目录的进程名称、PID 及父 PID，等待它们退出并保持 15 秒安静期，最多等待 15 分钟。不会自动结束用户应用。迁移期间保持应用关闭、电脑开机，保留迁移窗口。进程若重新启动，操作会停止。

看到 **`MIGRATION COMPLETE`** 才代表迁移和切换完成。窗口最后的“按任意键”仅表示命令结束，查看计划或状态也会出现它。

## 选择数据目录

每次处理一个组件，验证后再处理下一项。工具根据当前用户环境生成以下候选路径：

| 组件 | 候选源目录 | 目标目录 |
| --- | --- | --- |
| `Home` | `CODEX_HOME`，未设置时为用户目录下的 `.codex` | `<DestinationRoot>\Home` |
| `Workspace` | Windows“文档”目录下的 `Codex` | `<DestinationRoot>\Workspace` |
| `LocalRuntime` | `%LOCALAPPDATA%\OpenAI\Codex` | `<DestinationRoot>\LocalRuntime` |
| `AppData` | `%APPDATA%\Codex` | `<DestinationRoot>\AppData` |
| `RuntimeCache` | 用户目录下的 `.cache\codex-runtimes` | `<DestinationRoot>\RuntimeCache` |

这些是候选目录约定，并非完整的安装目录发现机制。不存在的目录不会凭空创建。若位置不同，明确指定自定义路径：

```powershell
.\Start-Migration.cmd -Mode Plan -Component Custom -SourcePath C:\Example\Data -DestinationPath D:\Example\Data -StatePath D:\Example\migration-state.json
```

确认路径后将 `Plan` 改为 `Migrate`。目标目录必须尚不存在，其父目录和状态文件父目录必须已存在。工具拒绝合并已有目标、源目标重叠、整个用户目录及系统目录。已有目录联接需要先核对原迁移，不能再次当作普通源目录搬迁。

## 核验和回滚

保持应用关闭，通过相同参数查询：

```powershell
.\Start-Migration.cmd -Mode Status -Component Home -DestinationRoot D:\CodexData
.\Start-Migration.cmd -Mode Verify -Component Home -DestinationRoot D:\CodexData
```

`Status` 显示最近的事务记录，不等于后台进程仍在运行。`Verify` 核对联接、原件备份是否存在、当前树是否可枚举；它不是对迁移后全部文件重新建立可信基线。迁移时已逐项验证文件内容、文件时间、普通文件的附加数据流与访问权限。

完成后先重开应用验证历史聊天、常用项目、插件和文件读写。如果需要回滚，再退出应用并运行：

```powershell
.\Start-Migration.cmd -Mode Rollback -Component Home -DestinationRoot D:\CodexData -WaitForExit
```

正常完成迁移后，回滚会把**目标目录的最新数据**复制回原盘的独立暂存目录，校验后才移除原路径联接并安装恢复目录。旧备份和目标数据都保留，因此回滚需要原盘有足够的额外空间。不会用旧备份覆盖迁移后的新增内容。

## 中断、失败和重复运行

- 状态文件在目标父目录，默认名为 `<Component>.migration-state.json`，可用 `-StatePath` 明确指定。
- 事务在复制、原目录重命名和恢复安装之前记录操作意图，以临时文件和原子替换保存状态。
- 同一源目录有互斥锁，状态文件另有文件锁；重复执行已完成的相同迁移不会再次复制。
- 已有未完成事务时，工具拒绝盲目重跑。先用同样参数查看 `Status`，再用 `Rollback` 恢复。
- 在原目录重命名后、联接创建前中断，回滚可把原件恢复到原路径。
- 回滚复制或安装中断时，重新运行回滚会核对实际目录状态，保留失败暂存副本；遇到不明目录或不同目标的联接会拒绝操作。
- 不自动删除原件、失败副本或旧备份，也不提供一键递归清理。确认应用和备份正常后，由使用者另行管理空间。

原路径在成功迁移后是兼容入口，不是重复数据目录。不要把它当作旧副本删除。保留原件备份期间，源盘空间尚未释放。

## Codex 后台服务

某些 Windows 安装带有 `CodexSandboxService.OpenAI.Codex`，退出窗口后仍可能占用文件。可先查看状态：

```powershell
powershell.exe -NoProfile -File .\Set-CodexService.ps1 -Action Status
```

如果迁移窗口明确列出该服务，应先正常退出相关应用，再在**单独的管理员 PowerShell**中运行 `-Action Stop`。迁移主程序仍以原用户的普通权限运行。迁移结束后，如果服务原本是运行状态，再用 `-Action Start` 恢复。

服务助手只接受上述固定服务名称，核对二进制文件名与有效签名，拒绝有运行中依赖项的停止操作。它不修改服务启动类型、系统执行策略或安全软件。身份检查失败时停止，不自动选择其他服务。遵循本机或组织的脚本执行策略，不需要关闭安全防护。

## 支持范围与数据保护

采用“复制 → 单独恢复访问规则 → 校验 → 改名保留原件 → 建立联接”的顺序。复制不让 Robocopy 同时写入 DACL，避免将数据复制和权限写入失败混为一谈。权限比较识别等价的重复条目，保留拒绝顺序、身份、作用范围和访问掩码；不会修改源权限或扩大访问授权。

自动迁移支持普通目录、普通文件及文件的 NTFS 附加数据流，路径最多 240 字符。遇到嵌套目录联接、符号链接、EFS 加密、云占位符、非规范 ACL、网络路径或无法读取的文件会停止，不会静默跳过。会排除检测到的注册云同步根，但不能识别所有第三方同步软件，使用者仍须确认目标不被同步。

不保留硬链接关系、文件所有者、SACL 审计规则、目录附加数据流和全部 NTFS 特性；存在此类依赖时请勿使用。目标访问权限以源目录的有效访问规则固定，未来不会自动继承原父目录的新权限变更。

本工具不上传数据，不输出文件正文或哈希值。迁移目录可能包含登录配置；复制与校验仅在本机运行。状态文件和终端可能显示本机路径、数量、错误码及进程编号，不应上传公开仓库。测试输出和实际数据都不属于发布文件。

目录联接只兼容本工具处理的旧路径，不会改变 Windows 或其他软件的全部写入位置，也不会自动改变 Codex 创建新项目时选择的目录。

## 测试

```powershell
powershell.exe -NoProfile -File .\Test-Regressions.ps1
powershell.exe -NoProfile -File .\Test-Integration.ps1
powershell.exe -NoProfile -File .\Test-Transaction.ps1
powershell.exe -NoProfile -File .\Test-Recovery.ps1 -DestinationFixtureRoot D:\Scratch
```

`D:\Scratch` 需自行创建。测试仅使用临时合成数据，保留小型测试目录以供检查；不迁移真实 Codex 数据，也不停止真实服务。`Test-Integration.ps1` 会启动并停止它自己创建的 Robocopy 合成监测进程，以验证进程身份判断。可将 `powershell.exe` 换成 `pwsh.exe` 验证 PowerShell 7。

验证范围见 [VALIDATION.md](VALIDATION.md)，分阶段改进见 [CHANGELOG.md](CHANGELOG.md)。无工具能保证所有 Windows 安装、硬件故障和外部并发修改下都不出错；本工具对已识别的异常停止并保留数据，不声称覆盖所有故障。
