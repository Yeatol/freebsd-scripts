#!/bin/sh

set -e

GITHUB_ID=${1:-Yeatol}

pkg_install() {
    package=$1

    if ! pkg info -e "$package" >/dev/null 2>&1; then
        pkg install -y "$package"
    fi
}

conf_set() {
    conf_file=$1
    conf_key=$2
    conf_value=$3

    case "$conf_value" in
        yes|no) ;;
        *)
            printf 'Invalid make configuration value: %s; expected yes or no\n' "$conf_value" >&2
            return 2
            ;;
    esac
    if [ -f "$conf_file" ]; then
        sed -E -i '' \
            "s/^([[:space:]]*$conf_key[[:space:]]*[?:+!]?=[[:space:]]*)(yes|no)([[:space:]]*(#.*)?)$/\\1$conf_value\\3/" \
            "$conf_file"
    fi
    if ! grep -q "^$conf_key=$conf_value$" "$conf_file" 2>/dev/null; then
        printf '\n%s=%s\n' "$conf_key" "$conf_value" >> "$conf_file"
    fi
}

git_clone() {
    repository_url=$1
    target_dir=$2
    branch=$3

    if [ -e "$target_dir/.git" ]; then
        if ! origin_url=$(git -C "$target_dir" remote get-url origin); then
            printf 'Failed to read origin URL in %s\n' "$target_dir" >&2
            return 1
        fi
        if [ "$origin_url" != "$repository_url" ]; then
            printf 'Origin URL mismatch in %s\nExpected: %s\nActual: %s\n' "$target_dir" "$repository_url" "$origin_url" >&2
            return 1
        fi

        git -C "$target_dir" config --replace-all remote.origin.fetch '+refs/heads/*:refs/remotes/origin/*'
        if ! git -C "$target_dir" fetch --prune origin '+refs/heads/*:refs/remotes/origin/*'; then
            return 1
        fi

        git -C "$target_dir" rev-parse --verify "refs/remotes/origin/$branch^{commit}" >/dev/null
        git -C "$target_dir" reset --hard --quiet HEAD
        git -C "$target_dir" clean -ffdx --quiet
        git -C "$target_dir" checkout --quiet --track -B "$branch" "origin/$branch"
    else
        git clone --depth 1 --no-single-branch --branch "$branch" "$repository_url" "$target_dir"
    fi
}

git_fetch_main() {
    exit_status=$?
    trap - 0

    if [ -e /usr/ports/.git ]; then
        if ! {
            git -C /usr/ports checkout --force --quiet main &&
            git -C /usr/ports reset --hard --quiet origin/main &&
            git -C /usr/ports clean -ffdx --quiet
        }; then
            echo "Failed to restore /usr/ports to origin/main and remove local files on script exit" >&2
            if [ "$exit_status" -eq 0 ]; then
                exit_status=1
            fi
        fi
    fi

    exit "$exit_status"
}

git_fetch_branch() {
    port=$1
    branch=${port##*/}
    target_dir=/usr/ports

    if ! git -C "$target_dir" fetch origin "$branch:refs/remotes/origin/$branch"; then
        echo "Failed to fetch branch $branch from $target_dir" >&2
        return 1
    fi

    git -C "$target_dir" reset --hard --quiet HEAD
    git -C "$target_dir" clean -ffdx --quiet
    git -C "$target_dir" checkout --quiet --track -B "$branch" "origin/$branch"
    mkdir -p "$target_dir/distfiles"
}

git_match_branch() {
    branch=$1

    case "$branch" in
        ''|.|..|-*|*[!a-zA-Z0-9_.+-]*)
            printf 'Invalid port branch name: %s\n' "$branch" >&2
            return 1
            ;;
    esac

    matched_port=
    for port_dir in /usr/ports/*/"$branch"; do
        if [ -f "$port_dir/Makefile" ]; then
            candidate_port=${port_dir#/usr/ports/}
            if [ -n "$matched_port" ]; then
                printf 'Port branch %s matches multiple origins: %s and %s\n' "$branch" "$matched_port" "$candidate_port" >&2
                return 1
            fi
            matched_port=$candidate_port
        fi
    done

    if [ -z "$matched_port" ]; then
        printf 'No port origin found for branch %s\n' "$branch" >&2
        return 1
    fi

    printf '%s\n' "$matched_port"
}

portlint_testport() {
    port=$1

    if [ ! -d "/usr/ports/$port" ] || [ ! -f "/usr/ports/$port/Makefile" ]; then
        printf 'Port directory or Makefile not found on branch %s: /usr/ports/%s\n' "${port##*/}" "$port" >&2
        return 1
    fi

    conf_set /etc/make.conf DEVELOPER yes
    conf_set /etc/make.conf ALLOW_UNSUPPORTED_SYSTEM yes

    if ! pkgname=$(make -C "/usr/ports/$port" -V PKGNAME); then
        printf 'Failed to get version from /usr/ports/%s/Makefile\n' "$port" >&2
        return 1
    fi
    printf '%s\n' "$pkgname"

    echo "portlint -A /usr/ports/$port"
    portlint -A "/usr/ports/$port"
}

poudriere_zpool() {
    poudriere_conf="/usr/local/etc/poudriere.conf"
    if ! storage_configured=$(
        unset ZPOOL NO_ZFS
        if [ -f "$poudriere_conf" ]; then
            . "$poudriere_conf" || exit 1
        fi
        if [ -n "${ZPOOL:-}" ] || [ "${NO_ZFS:-no}" = yes ]; then
            printf '%s' yes
        fi
    ); then
        echo "Failed to read $poudriere_conf" >&2
        return 1
    fi

    if [ "$storage_configured" = yes ]; then
        return 0
    fi

    if ! pools=$(zpool list -H -o name); then
        echo "Failed to list ZFS pools; configure ZPOOL or NO_ZFS=yes in $poudriere_conf" >&2
        return 1
    fi
    if [ -z "$pools" ]; then
        echo "No ZFS pools found; configure storage in $poudriere_conf" >&2
        return 1
    fi

    if [ -n "${ZPOOL:-}" ]; then
        selected_pool=$ZPOOL
    elif [ "$(printf '%s\n' "$pools" | wc -l)" -eq 1 ]; then
        selected_pool=$pools
    else
        printf 'Multiple ZFS pools found:\n%s\nRun with ZPOOL=<pool> to select one.\n' "$pools" >&2
        return 1
    fi

    if ! printf '%s\n' "$pools" | grep -Fxq -- "$selected_pool"; then
        printf 'ZFS pool not found: %s\n' "$selected_pool" >&2
        return 1
    fi

    printf '\nZPOOL=%s\n' "$selected_pool" >> "$poudriere_conf"
}

poudriere_testport() {
    port=$1
    arch=$(uname -p)
    freebsd_version=$(freebsd-version)
    if ! printf '%s\n' "$freebsd_version" | grep -Eq '^[0-9]+\.[0-9]+-(RELEASE(-p[0-9]+)?|CURRENT)$'; then
        printf 'Unsupported FreeBSD version: %s; only RELEASE and CURRENT systems are supported for jail selection and creation\n' "$freebsd_version" >&2
        return 1
    fi
    jail_version=$(printf '%s\n' "$freebsd_version" | cut -d'-' -f1,2)
    jail_name=$(printf '%s' "$jail_version" | sed 's/-RELEASE.*$//; s/-CURRENT.*$//; s/\.//g')"$arch"

    poudriere_zpool

    if ! ports_output=$(poudriere ports -l -q); then
        echo "poudriere ports -l -q" >&2
        exit 1
    fi

    if printf '%s\n' "$ports_output" | awk -v name="default" '$1 == name { found=1 } END { exit !found }'; then
        if ! printf '%s\n' "$ports_output" | awk '$1 == "default" && $2 == "null" && NF >= 3 && $NF == "/usr/ports" { found=1 } END { exit !found }'; then
            echo "Existing poudriere ports tree default must use method null and path /usr/ports; refusing to test a different tree" >&2
            return 1
        fi
    else
        echo "poudriere ports -c -p default -m null -M /usr/ports"
        poudriere ports -c -p default -m null -M /usr/ports
    fi

    if ! jail_output=$(poudriere jail -l); then
        echo "poudriere jail -l" >&2
        exit 1
    fi

    if printf '%s\n' "$jail_output" | awk -v name="$jail_name" '$1 == name { found=1 } END { exit !found }'; then
        if ! printf '%s\n' "$jail_output" | awk -v name="$jail_name" -v version="$jail_version" -v arch="$arch" '
            $1 == name {
                actual_version = $2
                sub(/-p[0-9]+$/, "", actual_version)
                if (actual_version == version && $3 == arch) found=1
            }
            END { exit !found }
        '; then
            printf 'Existing jail %s does not match required version %s and architecture %s; refusing to reuse or modify it\n' "$jail_name" "$jail_version" "$arch" >&2
            return 1
        fi
    else
        echo "poudriere jail -c -j $jail_name -v $jail_version -a $arch"
        poudriere jail -c -j "$jail_name" -v "$jail_version" -a "$arch"
    fi

    mkdir -p /usr/local/etc/poudriere.d
    conf_set "/usr/local/etc/poudriere.d/$jail_name-make.conf" ALLOW_UNSUPPORTED_SYSTEM yes

    echo "poudriere testport -j $jail_name -p default -o $port"
    poudriere testport -j "$jail_name" -p default -o "$port" >/dev/null
}

git_ports_trap() {
    trap git_fetch_main 0
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM
}

pkg_install git-lite

pkg_install portlint

pkg_install poudriere

git_clone "https://github.com/$GITHUB_ID/freebsd-ports.git" /usr/ports main

git_ports_trap

branches=$(git -C /usr/ports for-each-ref --format='%(refname:strip=3)' refs/remotes/origin)

for branch in $branches; do
    case "$branch" in
        HEAD|main) continue ;;
    esac

    git_fetch_branch "$branch"
    port=$(git_match_branch "$branch")
    portlint_testport "$port"
    poudriere_testport "$port"
done
