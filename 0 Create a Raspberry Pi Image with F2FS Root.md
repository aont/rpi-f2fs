# Create a Raspberry Pi Image with F2FS Root

```bash
sudo unshare --mount --fork /bin/bash
```

```
mount --make-rprivate /
bash main.bash
```