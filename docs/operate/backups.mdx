# Backups with Litestream

Meridian keeps everything in SQLite under `/rails/storage`, in the `meridian_storage` volume. Git already holds your configs and history. A backup protects the audit trail, users and agent tokens.

[Litestream](https://litestream.io) streams SQLite changes continuously to any S3-compatible bucket (AWS S3, Backblaze B2, Cloudflare R2, MinIO…).

## As a Kamal accessory

Add to Meridian's `config/deploy.yml`:

```yaml
accessories:
  litestream:
    image: litestream/litestream:0.3.13
    host: meridian.internal.example.com
    cmd: replicate
    files:
      - config/litestream.yml:/etc/litestream.yml
    volumes:
      - "meridian_storage:/rails/storage"
    env:
      secret:
        - LITESTREAM_ACCESS_KEY_ID
        - LITESTREAM_SECRET_ACCESS_KEY
```

And `config/litestream.yml`:

```yaml
dbs:
  - path: /rails/storage/production.sqlite3
    replicas:
      - url: s3://your-bucket/meridian/production
        endpoint: https://s3.example.com   # omit for AWS
  - path: /rails/storage/production_queue.sqlite3
    replicas:
      - url: s3://your-bucket/meridian/queue
        endpoint: https://s3.example.com
```

The cache and cable databases are disposable and need no backup.

Then:

```bash
kamal accessory boot litestream
```

## Restore

Stop the app, move the old database aside (Litestream won't overwrite a file), restore, and boot:

```bash
kamal app stop
kamal app exec --reuse "mv storage/production.sqlite3 storage/production.sqlite3.old"
kamal accessory exec litestream "litestream restore -o /rails/storage/production.sqlite3 s3://your-bucket/meridian/production"
kamal app boot
```
