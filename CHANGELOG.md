# Change log

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
