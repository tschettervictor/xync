# xync

A POSIX shell script to automate ZFS Replication on XigmaNAS systems, but
can be used on any system with a POSIX compliant shell.

This project was forked from https://github.com/aaronhurt/zfs-replicate.
A special thanks to him for creating the original script.

The biggest difference is that this script will only replicate data for the
snapshots it creates, as opposed to a full replication that includes all snapshots.
It only uses `-i` for incremental sends, and no flags for initial sends. This means
you are free to create/destroy/manage snapshots on either side, as long as you stay
away from the `autorep-*` naming scheme.

It does the above on a per-dataset basis. Meaning that if you encounter a network hiccup,
it will only affect that one dataset. The rest will be able to pick up where the script
left off. The original script uses `-R` to replicate, and I often found my self having to
replicate terabytes of data from scratch because of a network hiccup. Granted, I could have
just manually fixed it, but I want to automate this as much as possible.

It is possible to replicate using `-I`, but I chose not to becasue XigmaNAS snapshots
have a certain naming scheme that (if used on both systems) coud interfere. If the same
snapshot name exists on both sides, then using `-I` will fail.

## Features

- The script follows strict POSIX standards and should be usable on any host with a POSIX compliant shell.
- Source pools and datasets are always authoritative, the script will always defer to the source.
- Supports push and pull replication with local and remote datasets.
- Supports multiple pool/dataset pairs to replicate.
- Supports divergence detection and reconciliation of destination datasets.
- Logging leverages syslog (via logger) by default, but local logging may be configured.
- Includes a well documented `config.sh` file that may be used as configuration or as reference for environment
  variables passed to the script.
- May be run on any schedule using cron or similar mechanism.
- Fully source compliant and may be used by other scripts.
- Includes a `--status` option for XigmaNAS that can be used to email the last log output at your preferred schedule.
  Simply add it as a custom script in the email settings under "System > Advanced > Email Reports"

## Warning

Replicating to a root dataset will rewrite the remote pool with forced replication.
This script will create a true 1:1 copy of the source dataset in the destination dataset with default options.

The configuration `REPLICATE_SETS="zpoolOne:zpoolTwo"` will result in `zpoolTwo` being a 1:1 copy of `zpoolOne` and may
result in data loss on `zpoolTwo`.

To replicate a root dataset safely to another pool consider `REPLICATE_SETS="zpoolOne:zpoolTwo/zpoolOne"` instead.

This will result in a 1:1 copy of `zpoolOne` in a separate dataset of `zpoolTwo` and will not affect other datasets
currently present on the destination.

## Configuration

Configuration is done via an optional config file as environment variables. Most options have sane
defaults to keep configuration to a minimum. The script will attempt to locate a file called `config.sh` in the same
directory as the script if one is not passed via the command line.

The config file is very well commented and the contents of the sample config are shown below. The only required
setting without a default is the `REPLICATE_SETS` option. The script will error out on launch if required configuration
is not met.

### Available Command Line Options

```text
Usage: ./xync.sh [config] [options]

POSIX shell script to automate ZFS Replication

Options:
  -c, --config <configFile>    configuration file
  -s, --status                 print most recent log messages to stdout
  -h, --help                   show this message
```

## Notes

If you use this script, let me know. Report issues via GitHub so they may be resolved.
