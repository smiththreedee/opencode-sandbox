Script to sandbox opencode and monitor it externally.

How to run:
First 
```
mitmweb --listen-port 8085 --web-port 8081
```

then:
```
./run_opencode.sh                              # proxy at 127.0.0.1:8085 (default, as before)
./run_opencode.sh --proxy 127.0.0.1:9000 proj  # proxy listening on another address
./run_opencode.sh --network proj               # host network, no proxy
./run_opencode.sh --network --bluetooth proj   # flags combine freely
```

TODO:
Add Bluetooth raw socket.
Fix socat error - connection reset by peer.
Test more and write a good usage and readme.
Add automatic mitm proxy starting and logging as a argument.
....
many more, this script is in very early development
