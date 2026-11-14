# Backup trial: stronger compression and incremental copies

2026-11-14. The owner asked to try both on a throwaway server before adopting either (D186). Nothing here is
adopted yet: LeafJuice still makes a gzip tar of each backup.

## How it was run

`leafjuice-check --trial-backups --i-accept-the-minecraft-eula` started a real Paper 26.3 server on 127.0.0.1, made
up a world by force-loading six areas of 256 × 256 blocks, and stopped it. It then archived the world six ways, and
deleted the server and every copy afterwards. The world came to 35.2 MB.

| Method | Size | Share of the world | Time |
| --- | --- | --- | --- |
| gzip, as today | 15.9 MB | 45.2% | 0.6 s |
| gzip level 9 | 15.9 MB | 45.1% | 0.5 s |
| xz | 15.3 MB | 43.5% | 3.8 s |
| xz level 9 | 15.3 MB | 43.5% | 4.3 s |
| zstd | 15.4 MB | 43.8% | 0.5 s |
| lz4 | 15.9 MB | 45.2% | 0.1 s |

zstd and lz4 only worked because Homebrew's tools are on this Mac. macOS's own tar has gzip, bzip2 and xz built in.

For the incremental copy, it made a plain copy of the world with rsync, played a second session that explored one
more area, then made a second copy with `--link-dest`, which hard-links every file that hadn't changed. The second
copy added 24.3 MB of a 44.1 MB world (55%): 41 files changed and 33 were shared. A byte-for-byte comparison
showed the linked copy matched the world exactly.

## What it means

- **Stronger compression isn't worth it.** Minecraft already compresses each chunk inside its region files, so
  there's little left to squeeze. xz saves about 4% and takes six times as long. The real server's whole-folder backup
  bears this out: 62 GB of files made a 47 GB archive.
- **Incremental copies are where the room is.** Each session rewrites only the regions that were loaded. This trial
  world was small and nearly all of it was loaded, so over half changed. A large world with most regions untouched
  would add only what was played in. Restoring is a plain copy back, with no unpacking.
- **What it would cost:** copies would be folders instead of single files. Every copy needs the drive to support hard
  links, which APFS and HFS+ do and exFAT doesn't. The drill, the backup comparison and the restore steps would each
  need a folder path alongside the archive path.

## Recommendation

Keep gzip archives. Trial incremental copies next on a larger made-up world, with the drill and restore working from
the copy, before offering them as a choice per storage target. Both need the owner's yes.

The trial printed "0 region files" because 26.x keeps region files deeper in the world folder. The count has been
fixed for the next run; the sizes above are unaffected.
