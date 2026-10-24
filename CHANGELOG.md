# Change log

## 1.0.0

- Add standalone Windows launcher with explicit success / failure messages.
- Add bounded waiting and a quiet period, with progress messages for long operations.
- Recover interruptions before and after installing restored data.
- Bind copy-process ownership to PID, parent, executable and creation time.
- Check an actual owned Robocopy child and reject process-identifier reuse.
- Reject ambiguous Windows path aliases and state files inside data trees.
- Add a narrowly scoped, optional Codex service helper; default to read-only status.
- Test cross-volume recovery on Windows PowerShell 5.1 and PowerShell 7.
- Document supported data, limitations, retained backups and validation evidence.

## 0.3.0

- Journal transaction intent before filesystem changes and save state atomically.
- Install compatibility junctions only after content and access verification.
- Recover an interruption between source rename and junction creation.
- Copy the latest destination data back during rollback; retain both existing copies.
- Validate journal paths and serialize operations with source mutex and state-file locks.
- Add explicit Plan, Migrate, Status, Verify and Rollback commands.

## 0.2.0

- Separate Robocopy data copying from access-rule preservation.
- Compare equivalent ACLs while preserving deny blocks and applicability.
- Exempt only the owned Robocopy process with matching identity.
- Add NTFS, sync-root, overlap, existing-target and file-lock checks.
- Verify file contents and named streams on Windows PowerShell 5.1 and PowerShell 7.
- Reject unsupported links, placeholders and long paths before switching anything.

## 0.1.0

- Add isolated reproductions for equivalent ACL comparisons and the owned-copy process false positive.
- Define Windows-only support and the migration safety requirements.
