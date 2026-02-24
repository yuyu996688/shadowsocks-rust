```shell
docker pull ghcr.io/shadowsocks/ssserver-rust:latest
docker pull ghcr.io/shadowsocks/ssserver-rust:v1.24.0@sha256:b450e1a60b2f308e74a1d4c7863df6c31a1815d046fc32b35fdf94e2f6fb30a9
```
```shell
docker pull ghcr.io/shadowsocks/sslocal-rust:latest
docker pull ghcr.io/shadowsocks/sslocal-rust:v1.24.0@sha256:06dc78feb8bd3f9ae7887ade04d59641452223aced4acc974e29c2f1346173c6
```
```shell
docker tag ghcr.io/shadowsocks/ssserver-rust:latest yuyu8868/ssserver-rust:latest-arm64
docker tag ghcr.io/shadowsocks/ssserver-rust:v1.24.0@sha256:b450e1a60b2f308e74a1d4c7863df6c31a1815d046fc32b35fdf94e2f6fb30a9 yuyu8868/ssserver-rust:latest-amd64
```
```shell
docker tag ghcr.io/shadowsocks/sslocal-rust:latest yuyu8868/sslocal-rust:latest-arm64
docker tag ghcr.io/shadowsocks/sslocal-rust:v1.24.0@sha256:06dc78feb8bd3f9ae7887ade04d59641452223aced4acc974e29c2f1346173c6 yuyu8868/sslocal-rust:latest-amd64
```