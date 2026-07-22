#!/bin/bash

# BSF entrypoint


# Check if the first argument is "debug"
if [ "$1" == "debug" ]; then
    # Run the AMF binary in gdb for debugging
    gdb /usr/local/bin/open5gs-bsfd \
        -ex "set substitute-path ../src /usr/local/src" \
        -ex "break main" \
        -ex "run -c /etc/open5gs/default/bsf.yaml"
else
    # Container entrypoint receiving arguments from Docker CMD
    exec /usr/local/bin/open5gs-bsfd "${@}"
fi

# Keep the container running
exec /bin/bash
