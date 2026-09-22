# v16

- Update compatibility for game build 25327279.
- Keep existing addon discovery, shared logs and audio callbacks working.

# v15

- Discovers explicitly declared addon entries across author namespaces without registry edits.
- Preserves API 1, legacy module order, shared logs and manager package identity.
- Adds a single-script author packaging helper and discovery regression coverage.
- Includes a minimal example mod and author documentation.

# v14

- Creates one shared folder for all updated CowboyBingus mod logs.
- Keeps mod startup working if the log folder or a log file cannot be written.
- Stores logs in `%LOCALAPPDATA%\CowboyBingus\Helldivers2\Logs`.
