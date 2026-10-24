# Codex Data Mover for Windows

Windows 环境下的数据目录迁移工具。目标是将 Codex 的工作区、配置目录、运行程序及缓存迁移至另一块本机磁盘，并通过原路径的目录联接保持兼容。

当前阶段：已加入可恢复事务、目录联接切换及保留最新数据的回滚。

## 环境

- Windows 10 / Windows 11。
- Windows PowerShell 5.1（系统自带）或 PowerShell 7，已分别运行集成测试。
- 本机 NTFS 磁盘；不面向 macOS、Linux、网络共享或云同步目录。

## 复现旧问题

```powershell
powershell.exe -NoProfile -File .\Test-Regressions.ps1
```

测试使用内存中的合成权限与进程信息，复现两类判断错误：

1. 直接比较权限字符串，将等价的合并 / 拆分 ACL 条目误判为权限不一致。
2. 按命令行中的源路径识别占用进程，将迁移程序自己启动的 Robocopy 误判为外部占用。

本阶段不会访问、复制或改动实际 Codex 数据。文件锁、权限复制失败等真实文件系统场景将在后续版本通过临时目录测试。

## 复制引擎测试

```powershell
powershell.exe -NoProfile -File .\Test-Integration.ps1
```

测试仅创建小型临时目录，验证文件锁、路径重叠、已有目标、嵌套链接、附加数据流、内容篡改与权限比较。合成目录保留供检查，不自动递归删除。

复制使用 Robocopy 的数据 / 属性 / 时间选项，随后单独恢复并核对访问权限，再对文件和附加数据流计算 SHA-256。权限比较保留允许 / 拒绝顺序、身份、访问范围和访问掩码，不把单纯合并重复条目当作权限变化。不会更改源目录权限，也不要求写入 SACL / 所有者权限。

当前自动化支持普通目录和文件，最多 240 字符路径；遇到嵌套目录联接、符号链接、云占位符、EFS 加密、异常权限和占用会停止，不会静默跳过。不保留文件硬链接关系、所有者或审计规则；如有相关依赖，请不要使用此工具。

## 改进阶段

## 事务命令

请把工具放在待迁移目录之外。默认只输出计划，不迁移数据：

```powershell
powershell.exe -NoProfile -File .\Invoke-Migration.ps1 -Mode Plan -Component Home -DestinationRoot D:\CodexData
```

先自行创建目标父目录，完全关闭 Codex 及相关辅助进程，再将 `Plan` 改成 `Migrate`。每次迁移一个组件。其他组件为 `Workspace`、`LocalRuntime`、`AppData`、`RuntimeCache`。这些是可覆盖的已知目录约定，不能代表所有 Codex 安装版本；不匹配时使用 `Custom` 并明确指定路径。

```powershell
powershell.exe -NoProfile -File .\Invoke-Migration.ps1 -Mode Migrate -Component Home -DestinationRoot D:\CodexData
powershell.exe -NoProfile -File .\Invoke-Migration.ps1 -Mode Status -Component Home -DestinationRoot D:\CodexData
powershell.exe -NoProfile -File .\Invoke-Migration.ps1 -Mode Rollback -Component Home -DestinationRoot D:\CodexData
```

`Migrate` 会先复制和校验，再把原目录改名保留为备份，在原位置创建指向新目录的联接。`Rollback` 会复制目标目录中的最新内容回原盘，因此需要额外空间，并保留旧备份及目标目录。成功迁移后再次运行相同事务不会再复制。

状态文件放在目标目录的父目录中，包含本机路径及数量，不包含文件正文或认证信息；不要公开上传状态文件。失败后保留所有副本，先查看状态并回滚，不会自动覆盖已有目标目录。

```powershell
powershell.exe -NoProfile -File .\Test-Transaction.ps1
```

此测试使用合成目录验证切换、重复运行、迁移后写入的回滚保留，以及重命名后的中断恢复。

## 改进阶段

- 第一版：最小问题复现。
- 第二版：路径预检查、数据复制、权限恢复与内容校验。
- 第三版：事务记录、目录联接切换和保留两份数据的回滚。
- 第四版：完整使用入口、故障恢复测试和公开发布检查。

本项目不能保证任何 Windows 配置都无故障。遇到无法校验的路径、权限或占用情况应停止，并保留原件和诊断状态。
