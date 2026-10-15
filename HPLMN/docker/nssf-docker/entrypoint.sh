#!/bin/bash

# Check if the first argument is "debug"
if [ "$1" == "debug" ]; then
    # Run the AMF binary in gdb for debugging
    gdb /usr/local/bin/open5gs-nssfd \
        -ex "set substitute-path ../src /usr/local/src" \
        -ex "break main" \
        -ex "run -c /etc/open5gs/default/nssf.yaml"
else
    # Container entrypoint receiving arguments from Docker CMD
    exec /usr/local/bin/open5gs-nssfd "${@}"
fi

# Keep the container running
exec /bin/bash
