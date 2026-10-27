# freebsd-scripts

## `port-test.sh`

On FreeBSD, this script iterates through the branches in a GitHub user's or organization's `freebsd-ports` repository and runs `portlint` and Poudriere tests for the port associated with each branch. The default GitHub ID is `Yeatol`.

### Usage

Run as root:

```sh
chmod +x port-test.sh
./port-test.sh
```

Pass the first argument to override the default GitHub ID:

```sh
./port-test.sh your_github_id
```

The script uses `https://github.com/<GITHUB_ID>/freebsd-ports.git`. If the first argument is omitted or empty, `Yeatol` is used. Additional arguments are ignored.

### Workflow

1. Install `git-lite`, `portlint`, and `poudriere` as needed (already-installed packages are skipped).
2. Fetch the repository branches, skipping `main` and the remote `HEAD`.
3. For each branch:
   - Use the branch name as the port directory name and look for a unique matching directory containing a `Makefile` under `/usr/ports/<category>/<branch>`. For example, the `ytop` branch must uniquely match a `category/ytop` port.
   - Run `portlint -A`.
   - Ensure the Poudriere `default` ports tree and a jail matching the current system version and architecture are available, then run `poudriere testport`.
4. Branches are tested sequentially. Any failed step stops testing of subsequent branches. The Poudriere command is printed before execution, but its standard output is discarded, so normal build output is not shown in the terminal. Standard error and the command's exit status are retained.
5. Once the `/usr/ports` repository has been initialized and the exit trap is set, the script attempts to restore it to `origin/main` on exit.

For example, if the `ytop` branch matches `sysutils/ytop` and the current architecture is `amd64`, using jail `151amd64`, the script runs:

Run portlint:

```sh
portlint -A /usr/ports/sysutils/ytop
```

Run the Poudriere test:

```sh
poudriere testport -j 151amd64 -p default -o sysutils/ytop
```

The actual jail name is derived from the FreeBSD version and architecture. For example, `15.1-RELEASE` and `amd64` produce `151amd64`.

Branch names must be a single path component and uniquely match a port in the ports tree. The script reports an error if no port or multiple ports match. Remote branches containing `/` are unsupported: the fetch step uses only the final path component, and the subsequent port lookup fails.

### Prerequisites and Configuration

- Run on FreeBSD with root privileges and network access.
- `freebsd-version` must report a `RELEASE` or `CURRENT` version. The script gets the architecture from `uname -p` and uses both values to derive the jail name. For example, `15.1-RELEASE` and `amd64` produce `151amd64`.
- Poudriere must be available. The script creates or reuses a `default` ports tree using method `null` and pointing to `/usr/ports`.
- If the `default` ports tree does not exist, the script creates it with:

  ```sh
  poudriere ports -c -p default -m null -M /usr/ports
  ```

  If it already exists, the script checks that its method is `null` and its path is `/usr/ports`.
- If the corresponding jail does not exist, the script creates it. If it already exists, the script checks its version and architecture. Patch levels (such as `-p3`) are ignored. A version or architecture mismatch causes the script to refuse reuse and stop. The creation command has this form:

  ```sh
  poudriere jail -c -j 151amd64 -v 15.1-RELEASE -a amd64
  ```

- On each run, the script ensures that the jail's `/usr/local/etc/poudriere.d/<jail-name>-make.conf` sets `ALLOW_UNSUPPORTED_SYSTEM=yes`. Jail creation and the first build may take a while.
- ZFS storage configuration:
  - If `/usr/local/etc/poudriere.conf` already sets `ZPOOL` or `NO_ZFS=yes`, the script uses that configuration.
  - Otherwise, the script checks for ZFS pools. If exactly one pool is available, it selects that pool and writes `ZPOOL=<pool>` to the configuration file. If multiple pools are available, it stops and requires `ZPOOL=<pool>` to be set.
  - For non-ZFS storage, set `NO_ZFS=yes` in the configuration file.

The script modifies the following configuration files and does not restore these changes on exit:

| File | Changes |
| --- | --- |
| `/etc/make.conf` | Sets `DEVELOPER=yes` and `ALLOW_UNSUPPORTED_SYSTEM=yes` |
| `/usr/local/etc/poudriere.d/<jail-name>-make.conf` | Sets `ALLOW_UNSUPPORTED_SYSTEM=yes` |
| `/usr/local/etc/poudriere.conf` | Appends `ZPOOL=<pool>` when automatically selecting the only available ZFS pool |
| `/usr/ports/.git/config` | When reusing an existing repository, updates `remote.origin.fetch` to track all remote branches |

### Notes

- **Data loss risk:** When switching branches and restoring on exit, the script runs `git reset --hard` and `git clean -ffdx` in `/usr/ports`. These commands delete uncommitted changes, untracked files, and ignored files. Do not keep data there that you need to preserve. The `origin` of an existing repository must match the GitHub ID passed to the script (or the default `Yeatol`).
- **Restoration limitations:** The script only attempts to restore `/usr/ports` to `origin/main` after the repository has been initialized and the exit trap has been set. Failures during initialization do not trigger this restoration.
- If a Poudriere ports tree error occurs, consider removing the existing ports tree configuration and rerunning the script. The script requires `default` to use method `null` and point to `/usr/ports`.
- If a jail error occurs, or its version or architecture does not match, inspect and remove the corresponding old jail before retrying. Make sure it is not used by other tasks to avoid deleting a jail used for another purpose.
- Run the script on a dedicated test machine if possible, and back up the configuration files listed above before running it.
