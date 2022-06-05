Original repo:

https://github.com/pardahlman/docker-rabbitmq-cluster

Setup dirs:

```
for ((i=0;i<=2;i++)); do for DIR in data log; do mkdir -p $DIR/rmq$i; touch $DIR/rmq$i/.gitkeep; git add -f $DIR/rmq$i/.gitkeep; done; done
sudo chown -R 999 log data
```

Clean data:

```
sudo chown -R "$USER" log data
git clean -xffd
```
