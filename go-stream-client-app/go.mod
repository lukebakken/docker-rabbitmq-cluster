module go-stream-client-app

go 1.24.0

require github.com/rabbitmq/rabbitmq-stream-go-client v1.4.8

replace github.com/rabbitmq/rabbitmq-stream-go-client => /home/lrbakken/development/rabbitmq/rabbitmq-stream-go-client // 79cd81e

require (
	github.com/golang/snappy v1.0.0 // indirect
	github.com/klauspost/compress v1.18.1 // indirect
	github.com/kr/pretty v0.3.1 // indirect
	github.com/pierrec/lz4 v2.6.1+incompatible // indirect
	github.com/pkg/errors v0.9.1 // indirect
	github.com/spaolacci/murmur3 v1.1.0 // indirect
)
