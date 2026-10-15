#!/bin/bash

# Check if the first argument is "debug"
if [ "$1" == "debug" ]; then
    # Run the NRF binary in gdb for debugging
    gdb /usr/local/bin/open5gs-nrfd \
        -ex "set substitute-path ../src /usr/local/src" \
        -ex "break main" \
        -ex "run -c /etc/open5gs/default/nrf.yaml"
else
    # Container entrypoint receiving arguments from Docker CMD
    exec /usr/local/bin/open5gs-nrfd "${@}"
fi

# Keep the container running
exec /bin/bash
